//! The Direct3D 12 renderer. It draws a scene with one instanced draw
//! call: each `Quad` is one instance of a triangle strip of four
//! vertices. The quads and the atlas page are buffers in an upload heap,
//! and the shaders read them as root shader resource views, so the root
//! signature has no descriptor table and the renderer has no shader
//! descriptor heap. The root signature has two constants (the target
//! size), the quad buffer, and the atlas buffer. The shaders are the HLSL
//! source of `shaders/quad.hlsl`, compiled at `init` with `D3DCompile`.
//!
//! A draw records one command list, submits it, and waits on a fence, so
//! the CPU and the GPU never share a buffer, as in the Vulkan renderer.
//! The quad buffer grows by a factor of two. The atlas buffer has one
//! page and gets the page again when the generation of the atlas
//! changes. An offscreen target is a texture in `R8G8B8A8_UNORM` with its
//! own render target view. Between draws it is in the copy source state,
//! so `readPixels` copies it to a readback buffer with no barrier.
//!
//! The device is on the first adapter of `EnumAdapterByGpuPreference`.
//! When that adapter has no Direct3D 12 device, or with `warp` set, it is
//! on the WARP adapter, the software rasterizer of Windows. Image quads
//! (kind 3) are discarded in the pixel shader, as in the Vulkan renderer.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const api = @import("d3d12_api.zig");
const scene_mod = @import("../scene.zig");
const renderer_mod = @import("renderer.zig");
const host = @import("../sys/host.zig");
const Atlas = @import("../text/atlas.zig").Atlas;
const Scene = scene_mod.Scene;
const Quad = scene_mod.Quad;
const Image = renderer_mod.Image;
const slot = api.slot;
const call = api.call;
const check = api.check;

pub const available = true;

const shader_source = @embedFile("shaders/quad.hlsl");
const page_bytes: usize = Atlas.page_size * Atlas.page_size;

comptime {
    // quad.hlsl reads the atlas with a page size of 1024 and the quads with a stride of 160.
    std.debug.assert(Atlas.page_size == 1024);
    std.debug.assert(@sizeOf(Quad) == 160);
}

pub const Options = struct {
    /// Use the WARP adapter even when a hardware adapter exists.
    warp: bool = false,
    /// Turn on the debug layer when the machine has it.
    debug: bool = false,
};

pub const Target = struct {
    /// The texture that the next draw writes: the offscreen texture, or
    /// the current back buffer of the swapchain.
    texture: *api.Resource,
    rtv_heap: *api.DescriptorHeap,
    rtv: api.CPU_DESCRIPTOR_HANDLE,
    width: u32,
    height: u32,
    /// The state of the texture between draws.
    rest: u32 = api.RESOURCE_STATE_COPY_SOURCE,
    swap: ?*api.SwapChain3 = null,
    buffers: [2]*api.Resource = undefined,
    rtvs: [2]api.CPU_DESCRIPTOR_HANDLE = undefined,
};

const Buffer = struct {
    res: ?*api.Resource = null,
    mapped: ?[*]u8 = null,
    size: usize = 0,
};

pub const D3D12 = struct {
    gpa: std.mem.Allocator,
    lib: api.Lib,
    factory: *api.Factory6,
    device: *api.Device,
    queue: *api.CommandQueue,
    allocator: *api.CommandAllocator,
    list: *api.GraphicsCommandList,
    fence: *api.Fence,
    fence_value: u64 = 0,
    event: api.HANDLE,
    root: *api.RootSignature,
    pipeline: *api.PipelineState,
    instances: Buffer = .{},
    atlas: Buffer = .{},
    readback: Buffer = .{},
    atlas_generation: ?u32 = null,
    target: ?*Target = null,
    name_buf: [128]u8 = undefined,
    name_len: usize = 0,
    warp: bool = false,
    /// True for an adapter that draws on the CPU.
    software: bool = false,

    pub fn init(gpa: std.mem.Allocator, opts: Options) !*D3D12 {
        const lib = try api.load();
        if (opts.debug) {
            var dbg: ?*anyopaque = null;
            if (lib.D3D12GetDebugInterface(&api.IID_ID3D12Debug, &dbg) >= 0) {
                _ = call(void, dbg.?, slot.debug_enable, .{});
                api.release(dbg.?);
            }
        }
        var factory_raw: ?*anyopaque = null;
        check(lib.CreateDXGIFactory2(0, &api.IID_IDXGIFactory6, &factory_raw)) catch return error.NoD3D12;
        const factory: *api.Factory6 = @ptrCast(factory_raw.?);
        errdefer api.release(factory);

        const v = try gpa.create(D3D12);
        errdefer gpa.destroy(v);
        v.* = .{
            .gpa = gpa,
            .lib = lib,
            .factory = factory,
            .device = undefined,
            .queue = undefined,
            .allocator = undefined,
            .list = undefined,
            .fence = undefined,
            .event = undefined,
            .root = undefined,
            .pipeline = undefined,
        };
        v.device = v.openDevice(opts.warp) orelse return error.NoD3D12;
        errdefer api.release(v.device);
        try v.createQueue();
        errdefer v.releaseQueue();
        try v.createPipeline();
        errdefer {
            api.release(v.pipeline);
            api.release(v.root);
        }
        try v.createBuffer(&v.instances, 64 * 1024, api.HEAP_TYPE_UPLOAD);
        errdefer v.destroyBuffer(&v.instances);
        try v.createBuffer(&v.atlas, page_bytes, api.HEAP_TYPE_UPLOAD);
        return v;
    }

    pub fn deinit(v: *D3D12) void {
        v.waitIdle();
        v.destroyBuffer(&v.instances);
        v.destroyBuffer(&v.atlas);
        v.destroyBuffer(&v.readback);
        api.release(v.pipeline);
        api.release(v.root);
        v.releaseQueue();
        api.release(v.device);
        api.release(v.factory);
        v.gpa.destroy(v);
    }

    /// The name of the adapter, in UTF-8.
    pub fn deviceName(v: *const D3D12) []const u8 {
        return v.name_buf[0..v.name_len];
    }

    /// Makes a device on the first adapter by preference, or on WARP.
    fn openDevice(v: *D3D12, warp: bool) ?*api.Device {
        if (!warp) {
            var adapter: ?*anyopaque = null;
            if (call(api.HRESULT, v.factory, slot.factory_enum_by_preference, .{ @as(u32, 0), api.DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE, &api.IID_IDXGIAdapter1, &adapter }) >= 0) {
                defer api.release(adapter.?);
                if (v.deviceOn(adapter.?)) |d| return d;
            }
        }
        var adapter: ?*anyopaque = null;
        if (call(api.HRESULT, v.factory, slot.factory_enum_warp, .{ &api.IID_IDXGIAdapter1, &adapter }) < 0) return null;
        defer api.release(adapter.?);
        return v.deviceOn(adapter.?);
    }

    fn deviceOn(v: *D3D12, adapter: *anyopaque) ?*api.Device {
        var dev: ?*anyopaque = null;
        if (v.lib.D3D12CreateDevice(adapter, api.D3D_FEATURE_LEVEL_11_0, &api.IID_ID3D12Device, &dev) < 0) return null;
        var desc: api.ADAPTER_DESC1 = undefined;
        if (call(api.HRESULT, adapter, slot.adapter_desc1, .{&desc}) >= 0) {
            const end = std.mem.indexOfScalar(u16, &desc.Description, 0) orelse desc.Description.len;
            var it = std.unicode.Utf16LeIterator.init(desc.Description[0..end]);
            var n: usize = 0;
            while (it.nextCodepoint() catch null) |cp| {
                var b: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &b) catch break;
                if (n + len > v.name_buf.len) break;
                @memcpy(v.name_buf[n..][0..len], b[0..len]);
                n += len;
            }
            v.name_len = n;
            v.warp = desc.Flags & api.DXGI_ADAPTER_FLAG_SOFTWARE != 0;
            // WARP and the Basic Render Driver of a machine with no GPU have the vendor ID of Microsoft.
            v.software = v.warp or desc.VendorId == 0x1414;
        }
        return @ptrCast(dev.?);
    }

    fn createQueue(v: *D3D12) !void {
        const qd: api.COMMAND_QUEUE_DESC = .{};
        var q: ?*anyopaque = null;
        try check(call(api.HRESULT, v.device, slot.device_create_command_queue, .{ &qd, &api.IID_ID3D12CommandQueue, &q }));
        v.queue = @ptrCast(q.?);
        errdefer api.release(v.queue);
        var a: ?*anyopaque = null;
        try check(call(api.HRESULT, v.device, slot.device_create_command_allocator, .{ api.COMMAND_LIST_TYPE_DIRECT, &api.IID_ID3D12CommandAllocator, &a }));
        v.allocator = @ptrCast(a.?);
        errdefer api.release(v.allocator);
        var l: ?*anyopaque = null;
        try check(call(api.HRESULT, v.device, slot.device_create_command_list, .{ @as(u32, 0), api.COMMAND_LIST_TYPE_DIRECT, v.allocator, @as(?*anyopaque, null), &api.IID_ID3D12GraphicsCommandList, &l }));
        v.list = @ptrCast(l.?);
        errdefer api.release(v.list);
        try check(call(api.HRESULT, v.list, slot.list_close, .{}));
        var f: ?*anyopaque = null;
        try check(call(api.HRESULT, v.device, slot.device_create_fence, .{ @as(u64, 0), @as(u32, 0), &api.IID_ID3D12Fence, &f }));
        v.fence = @ptrCast(f.?);
        errdefer api.release(v.fence);
        v.event = api.CreateEventW(null, 0, 0, null) orelse return error.NoEvent;
    }

    fn releaseQueue(v: *D3D12) void {
        _ = api.CloseHandle(v.event);
        api.release(v.fence);
        api.release(v.list);
        api.release(v.allocator);
        api.release(v.queue);
    }

    fn compile(v: *D3D12, entry: [*:0]const u8, profile: [*:0]const u8) !*api.Blob {
        var code: ?*api.Blob = null;
        var errors: ?*api.Blob = null;
        const hr = v.lib.D3DCompile(shader_source.ptr, shader_source.len, "quad.hlsl", null, null, entry, profile, api.D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code, &errors);
        if (errors) |e| {
            const p: [*]const u8 = @ptrCast(call(*anyopaque, e, slot.blob_pointer, .{}));
            const n = call(usize, e, slot.blob_size, .{});
            if (hr < 0) host.writeStderr(p[0..n]);
            api.release(e);
        }
        try check(hr);
        return code.?;
    }

    fn bytecode(b: *api.Blob) api.SHADER_BYTECODE {
        return .{ .pShaderBytecode = call(*anyopaque, b, slot.blob_pointer, .{}), .BytecodeLength = call(usize, b, slot.blob_size, .{}) };
    }

    fn createPipeline(v: *D3D12) !void {
        const params = [_]api.ROOT_PARAMETER{
            .{ .ParameterType = api.ROOT_PARAMETER_TYPE_32BIT_CONSTANTS, .u = .{ .Constants = .{ .ShaderRegister = 0, .Num32BitValues = 2 } } },
            .{ .ParameterType = api.ROOT_PARAMETER_TYPE_SRV, .u = .{ .Descriptor = .{ .ShaderRegister = 0 } } },
            .{ .ParameterType = api.ROOT_PARAMETER_TYPE_SRV, .u = .{ .Descriptor = .{ .ShaderRegister = 1 } } },
        };
        const rs_desc: api.ROOT_SIGNATURE_DESC = .{ .NumParameters = params.len, .pParameters = &params };
        var blob: ?*api.Blob = null;
        var err_blob: ?*api.Blob = null;
        const hr = v.lib.D3D12SerializeRootSignature(&rs_desc, api.D3D_ROOT_SIGNATURE_VERSION_1, &blob, &err_blob);
        if (err_blob) |e| api.release(e);
        try check(hr);
        defer api.release(blob.?);
        var root: ?*anyopaque = null;
        try check(call(api.HRESULT, v.device, slot.device_create_root_signature, .{
            @as(u32, 0),
            call(*anyopaque, blob.?, slot.blob_pointer, .{}),
            call(usize, blob.?, slot.blob_size, .{}),
            &api.IID_ID3D12RootSignature,
            &root,
        }));
        v.root = @ptrCast(root.?);
        errdefer api.release(v.root);

        const vs = try v.compile("vs_main", "vs_5_0");
        defer api.release(vs);
        const ps = try v.compile("ps_main", "ps_5_0");
        defer api.release(ps);
        var desc: api.GRAPHICS_PIPELINE_STATE_DESC = .{ .pRootSignature = v.root, .VS = bytecode(vs), .PS = bytecode(ps) };
        desc.BlendState.RenderTarget[0] = .{
            .BlendEnable = 1,
            .SrcBlend = api.BLEND_ONE,
            .DestBlend = api.BLEND_INV_SRC_ALPHA,
            .SrcBlendAlpha = api.BLEND_ONE,
            .DestBlendAlpha = api.BLEND_INV_SRC_ALPHA,
        };
        var pso: ?*anyopaque = null;
        try check(call(api.HRESULT, v.device, slot.device_create_graphics_pipeline_state, .{ &desc, &api.IID_ID3D12PipelineState, &pso }));
        v.pipeline = @ptrCast(pso.?);
    }

    fn createResource(v: *D3D12, heap: i32, desc: *const api.RESOURCE_DESC, state: u32) !*api.Resource {
        const props: api.HEAP_PROPERTIES = .{ .Type = heap };
        var res: ?*anyopaque = null;
        try check(call(api.HRESULT, v.device, slot.device_create_committed_resource, .{ &props, @as(u32, 0), desc, state, @as(?*anyopaque, null), &api.IID_ID3D12Resource, &res }));
        return @ptrCast(res.?);
    }

    /// Makes a buffer in an upload or a readback heap, mapped until it is destroyed.
    fn createBuffer(v: *D3D12, b: *Buffer, size: usize, heap: i32) !void {
        const desc: api.RESOURCE_DESC = .{ .Dimension = api.RESOURCE_DIMENSION_BUFFER, .Width = size, .Layout = api.TEXTURE_LAYOUT_ROW_MAJOR };
        const state = if (heap == api.HEAP_TYPE_READBACK) api.RESOURCE_STATE_COPY_DEST else api.RESOURCE_STATE_GENERIC_READ;
        const res = try v.createResource(heap, &desc, state);
        errdefer api.release(res);
        var p: ?*anyopaque = null;
        const none: api.RANGE = .{};
        try check(call(api.HRESULT, res, slot.resource_map, .{ @as(u32, 0), if (heap == api.HEAP_TYPE_READBACK) @as(?*const api.RANGE, null) else &none, &p }));
        b.* = .{ .res = res, .mapped = @ptrCast(p.?), .size = size };
    }

    fn destroyBuffer(_: *D3D12, b: *Buffer) void {
        if (b.res) |r| {
            _ = call(void, r, slot.resource_unmap, .{ @as(u32, 0), @as(?*const api.RANGE, null) });
            api.release(r);
        }
        b.* = .{};
    }

    fn gpuAddress(b: *const Buffer) u64 {
        return call(u64, b.res.?, slot.resource_gpu_address, .{});
    }

    /// Makes an offscreen target with its own render target view.
    pub fn createOffscreen(v: *D3D12, width: u32, height: u32) !*Target {
        const desc: api.RESOURCE_DESC = .{
            .Dimension = api.RESOURCE_DIMENSION_TEXTURE2D,
            .Width = width,
            .Height = height,
            .Format = api.DXGI_FORMAT_R8G8B8A8_UNORM,
            .Flags = api.RESOURCE_FLAG_ALLOW_RENDER_TARGET,
        };
        const tex = try v.createResource(api.HEAP_TYPE_DEFAULT, &desc, api.RESOURCE_STATE_COPY_SOURCE);
        errdefer api.release(tex);
        const hd: api.DESCRIPTOR_HEAP_DESC = .{ .Type = api.DESCRIPTOR_HEAP_TYPE_RTV, .NumDescriptors = 1 };
        var heap: ?*anyopaque = null;
        try check(call(api.HRESULT, v.device, slot.device_create_descriptor_heap, .{ &hd, &api.IID_ID3D12DescriptorHeap, &heap }));
        errdefer api.release(heap.?);
        var rtv: api.CPU_DESCRIPTOR_HANDLE = undefined;
        _ = call(*api.CPU_DESCRIPTOR_HANDLE, heap.?, slot.heap_cpu_start, .{&rtv});
        call(void, v.device, slot.device_create_render_target_view, .{ tex, @as(?*const anyopaque, null), rtv });
        const t = try v.gpa.create(Target);
        t.* = .{ .texture = tex, .rtv_heap = @ptrCast(heap.?), .rtv = rtv, .width = width, .height = height };
        return t;
    }

    /// Makes a flip-model swapchain with two buffers for a window. `hwnd`
    /// is the handle of the window.
    pub fn createSwapchain(v: *D3D12, hwnd: *anyopaque, width: u32, height: u32) !*Target {
        const desc: api.SWAP_CHAIN_DESC1 = .{ .Width = width, .Height = height };
        var sc1: ?*anyopaque = null;
        try check(call(api.HRESULT, v.factory, slot.factory_create_swapchain_for_hwnd, .{ @as(*anyopaque, @ptrCast(v.queue)), hwnd, &desc, @as(?*const anyopaque, null), @as(?*anyopaque, null), &sc1 }));
        defer api.release(sc1.?);
        var sc3: ?*anyopaque = null;
        try check(call(api.HRESULT, sc1.?, slot.unknown_query, .{ &api.IID_IDXGISwapChain3, &sc3 }));
        const swap: *api.SwapChain3 = @ptrCast(sc3.?);
        errdefer api.release(swap);
        // Alt+Enter is a key of the script, and ztk has no full screen mode.
        _ = call(api.HRESULT, v.factory, slot.factory_make_window_association, .{ hwnd, api.DXGI_MWA_NO_ALT_ENTER });
        const hd: api.DESCRIPTOR_HEAP_DESC = .{ .Type = api.DESCRIPTOR_HEAP_TYPE_RTV, .NumDescriptors = 2 };
        var heap: ?*anyopaque = null;
        try check(call(api.HRESULT, v.device, slot.device_create_descriptor_heap, .{ &hd, &api.IID_ID3D12DescriptorHeap, &heap }));
        errdefer api.release(heap.?);
        var start: api.CPU_DESCRIPTOR_HANDLE = undefined;
        _ = call(*api.CPU_DESCRIPTOR_HANDLE, heap.?, slot.heap_cpu_start, .{&start});
        const step = call(u32, v.device, slot.device_descriptor_size, .{api.DESCRIPTOR_HEAP_TYPE_RTV});
        const t = try v.gpa.create(Target);
        errdefer v.gpa.destroy(t);
        t.* = .{
            .texture = undefined,
            .rtv_heap = @ptrCast(heap.?),
            .rtv = start,
            .width = width,
            .height = height,
            .rest = api.RESOURCE_STATE_PRESENT,
            .swap = swap,
            .rtvs = .{ start, .{ .ptr = start.ptr + step } },
        };
        try v.getBuffers(t);
        return t;
    }

    fn getBuffers(v: *D3D12, t: *Target) !void {
        for (0..2) |i| {
            var buf: ?*anyopaque = null;
            try check(call(api.HRESULT, t.swap.?, slot.swap_get_buffer, .{ @as(u32, @intCast(i)), &api.IID_ID3D12Resource, &buf }));
            t.buffers[i] = @ptrCast(buf.?);
            call(void, v.device, slot.device_create_render_target_view, .{ t.buffers[i], @as(?*const anyopaque, null), t.rtvs[i] });
        }
        t.texture = t.buffers[0];
    }

    /// Gives the swapchain of a window a new size in device pixels.
    pub fn resizeSwapchain(v: *D3D12, t: *Target, width: u32, height: u32) !void {
        v.waitIdle();
        for (t.buffers) |b| api.release(b);
        try check(call(api.HRESULT, t.swap.?, slot.swap_resize_buffers, .{ @as(u32, 0), width, height, api.DXGI_FORMAT_UNKNOWN, @as(u32, 0) }));
        t.width = width;
        t.height = height;
        try v.getBuffers(t);
    }

    /// Shows the last draw of a swapchain at the next refresh.
    pub fn present(_: *D3D12, t: *Target) !void {
        try check(call(api.HRESULT, t.swap.?, slot.swap_present, .{ @as(u32, 1), @as(u32, 0) }));
    }

    pub fn destroyTarget(v: *D3D12, t: *Target) void {
        v.waitIdle();
        if (v.target == t) v.target = null;
        if (t.swap) |sc| {
            for (t.buffers) |b| api.release(b);
            api.release(sc);
        } else api.release(t.texture);
        api.release(t.rtv_heap);
        v.gpa.destroy(t);
    }

    pub fn setTarget(v: *D3D12, t: *Target) void {
        v.target = t;
    }

    fn begin(v: *D3D12) !void {
        try check(call(api.HRESULT, v.allocator, slot.allocator_reset, .{}));
        try check(call(api.HRESULT, v.list, slot.list_reset, .{ v.allocator, v.pipeline }));
    }

    fn barrier(v: *D3D12, res: *api.Resource, before: u32, after: u32) void {
        const b: api.RESOURCE_BARRIER = .{ .Transition = .{ .pResource = res, .StateBefore = before, .StateAfter = after } };
        call(void, v.list, slot.list_barrier, .{ @as(u32, 1), &b });
    }

    fn submitAndWait(v: *D3D12) !void {
        try check(call(api.HRESULT, v.list, slot.list_close, .{}));
        const lists = [_]*api.GraphicsCommandList{v.list};
        call(void, v.queue, slot.queue_execute, .{ @as(u32, 1), &lists });
        v.waitIdle();
        try check(call(api.HRESULT, v.device, slot.device_removed_reason, .{}));
    }

    fn waitIdle(v: *D3D12) void {
        v.fence_value += 1;
        if (call(api.HRESULT, v.queue, slot.queue_signal, .{ v.fence, v.fence_value }) < 0) return;
        if (call(u64, v.fence, slot.fence_completed, .{}) >= v.fence_value) return;
        if (call(api.HRESULT, v.fence, slot.fence_set_event, .{ v.fence_value, v.event }) < 0) return;
        _ = api.WaitForSingleObject(v.event, 0xFFFFFFFF);
    }

    /// Copies the atlas page to its buffer when its generation changed.
    fn syncAtlas(v: *D3D12, atlas: *const Atlas) void {
        if (v.atlas_generation) |g| if (g == atlas.generation) return;
        const page = atlas.page();
        if (page.len > 0) @memcpy(v.atlas.mapped.?[0..page.len], page);
        v.atlas_generation = atlas.generation;
    }

    /// Draws a scene to the current target.
    pub fn draw(v: *D3D12, scene: *const Scene, atlas: *const Atlas) !void {
        const t = v.target orelse return error.NoTarget;
        const n = scene.quads.items.len;
        const need = n * @sizeOf(Quad);
        if (need > v.instances.size) {
            var size = v.instances.size;
            while (size < need) size *= 2;
            v.destroyBuffer(&v.instances);
            try v.createBuffer(&v.instances, size, api.HEAP_TYPE_UPLOAD);
        }
        if (n > 0) @memcpy(v.instances.mapped.?[0..need], std.mem.sliceAsBytes(scene.quads.items));
        v.syncAtlas(atlas);
        if (t.swap) |sc| {
            const i = call(u32, sc, slot.swap_current_index, .{});
            t.texture = t.buffers[i];
            t.rtv = t.rtvs[i];
        }
        try v.begin();
        v.barrier(t.texture, t.rest, api.RESOURCE_STATE_RENDER_TARGET);
        call(void, v.list, slot.list_set_render_targets, .{ @as(u32, 1), &t.rtv, @as(api.BOOL, 0), @as(?*const anyopaque, null) });
        call(void, v.list, slot.list_clear_rtv, .{ t.rtv, &scene.clear, @as(u32, 0), @as(?*const anyopaque, null) });
        if (n > 0) {
            call(void, v.list, slot.list_set_root_signature, .{v.root});
            const size = [2]f32{ @floatFromInt(t.width), @floatFromInt(t.height) };
            call(void, v.list, slot.list_set_root_constants, .{ @as(u32, 0), @as(u32, 2), &size, @as(u32, 0) });
            call(void, v.list, slot.list_set_root_srv, .{ @as(u32, 1), gpuAddress(&v.instances) });
            call(void, v.list, slot.list_set_root_srv, .{ @as(u32, 2), gpuAddress(&v.atlas) });
            const vp: api.VIEWPORT = .{ .Width = @floatFromInt(t.width), .Height = @floatFromInt(t.height) };
            call(void, v.list, slot.list_set_viewports, .{ @as(u32, 1), &vp });
            const sc: api.RECT = .{ .right = @intCast(t.width), .bottom = @intCast(t.height) };
            call(void, v.list, slot.list_set_scissors, .{ @as(u32, 1), &sc });
            call(void, v.list, slot.list_set_topology, .{api.D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP});
            call(void, v.list, slot.list_draw_instanced, .{ @as(u32, 4), @as(u32, @intCast(n)), @as(u32, 0), @as(u32, 0) });
        }
        v.barrier(t.texture, api.RESOURCE_STATE_RENDER_TARGET, t.rest);
        try v.submitAndWait();
    }

    /// Copies the pixels of an offscreen target to an image of the same size.
    pub fn readPixels(v: *D3D12, t: *Target, out: *Image) !void {
        const row: u32 = t.width * 4;
        const pitch: u32 = std.mem.alignForward(u32, row, 256);
        const bytes: usize = @as(usize, pitch) * t.height;
        if (v.readback.size < bytes) {
            v.destroyBuffer(&v.readback);
            try v.createBuffer(&v.readback, bytes, api.HEAP_TYPE_READBACK);
        }
        try v.begin();
        const dst: api.TEXTURE_COPY_LOCATION = .{ .pResource = v.readback.res.?, .Type = api.TEXTURE_COPY_TYPE_PLACED_FOOTPRINT, .u = .{ .PlacedFootprint = .{ .Footprint = .{
            .Format = api.DXGI_FORMAT_R8G8B8A8_UNORM,
            .Width = t.width,
            .Height = t.height,
            .RowPitch = pitch,
        } } } };
        const src: api.TEXTURE_COPY_LOCATION = .{ .pResource = t.texture, .Type = api.TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX, .u = .{ .SubresourceIndex = 0 } };
        call(void, v.list, slot.list_copy_texture_region, .{ &dst, @as(u32, 0), @as(u32, 0), @as(u32, 0), &src, @as(?*const anyopaque, null) });
        try v.submitAndWait();
        const base = v.readback.mapped.?;
        for (0..t.height) |y| @memcpy(out.pixels[y * row ..][0..row], base[y * pitch ..][0..row]);
        out.width = t.width;
        out.height = t.height;
    }

    // ---- The Renderer interface ----

    fn rDeinit(ptr: *anyopaque) void {
        const v: *D3D12 = @ptrCast(@alignCast(ptr));
        v.deinit();
    }

    fn rDraw(ptr: *anyopaque, scene: *const Scene, atlas: *const Atlas) anyerror!void {
        const v: *D3D12 = @ptrCast(@alignCast(ptr));
        return v.draw(scene, atlas);
    }

    const vtable: renderer_mod.Renderer.VTable = .{ .deinit = rDeinit, .draw = rDraw };

    pub fn renderer(v: *D3D12) renderer_mod.Renderer {
        return .{ .ptr = v, .vtable = &vtable };
    }
};
