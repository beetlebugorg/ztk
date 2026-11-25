//! The COM interfaces of Direct3D 12, DXGI, and the shader compiler that
//! the renderer calls. A COM object starts with a pointer to its table of
//! functions. `call` reads the function at a slot of that table and casts
//! it to the type of the method. The slots, the interface IDs, the
//! structures, and the constants follow the C forms in `d3d12.h`,
//! `dxgi1_6.h`, and `d3dcompiler.h` of the Windows SDK 10.0.26100.0.
//! A method that returns a structure has a pointer to the result as
//! its second argument in the C form, and is declared so.
//!
//! The DLLs open at run time with `LoadLibraryW`, so a machine without
//! Direct3D 12 gives an error from `load` and the program uses the CPU
//! renderer.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const HRESULT = i32;
pub const BOOL = c_int;
pub const UINT = u32;
pub const HANDLE = *anyopaque;

pub const GUID = extern struct {
    a: u32,
    b: u16,
    c: u16,
    d: [8]u8,

    pub fn parse(comptime s: []const u8) GUID {
        @setEvalBranchQuota(10_000);
        const hex = struct {
            fn n(comptime t: []const u8) u64 {
                return std.fmt.parseInt(u64, t, 16) catch unreachable;
            }
        }.n;
        var d: [8]u8 = undefined;
        d[0] = @intCast(hex(s[19..21]));
        d[1] = @intCast(hex(s[21..23]));
        inline for (0..6) |i| d[2 + i] = @intCast(hex(s[24 + 2 * i ..][0..2]));
        return .{ .a = @intCast(hex(s[0..8])), .b = @intCast(hex(s[9..13])), .c = @intCast(hex(s[14..18])), .d = d };
    }
};

pub const IID_ID3D12Device = GUID.parse("189819f1-1db6-4b57-be54-1821339b85f7");
pub const IID_ID3D12CommandQueue = GUID.parse("0ec870a6-5d7e-4c22-8cfc-5baae07616ed");
pub const IID_ID3D12CommandAllocator = GUID.parse("6102dee4-af59-4b09-b999-b44d73f09b24");
pub const IID_ID3D12GraphicsCommandList = GUID.parse("5b160d0f-ac1b-4185-8ba8-b3ae42a5a455");
pub const IID_ID3D12Resource = GUID.parse("696442be-a72e-4059-bc79-5b5c98040fad");
pub const IID_ID3D12Fence = GUID.parse("0a753dcf-c4d8-4b91-adf6-be5a60d95a76");
pub const IID_ID3D12DescriptorHeap = GUID.parse("8efb471d-616c-4f49-90f7-127bb763fa51");
pub const IID_ID3D12RootSignature = GUID.parse("c54a6b66-72df-4ee8-8be5-a946a1429214");
pub const IID_ID3D12PipelineState = GUID.parse("765a30f3-f624-4c6f-a828-ace948622445");
pub const IID_ID3D12Debug = GUID.parse("344488b7-6846-474b-b989-f027448245e0");
pub const IID_IDXGIFactory6 = GUID.parse("c1b6694f-ff09-44a9-b03c-77900a0a1d17");
pub const IID_IDXGIAdapter1 = GUID.parse("29038f61-3839-4626-91fd-086879011a05");
pub const IID_IDXGISwapChain3 = GUID.parse("94d99bdb-f1f8-4ab0-b236-7da0170edab1");

// Enumerations, as 32-bit integers.
pub const D3D_FEATURE_LEVEL_11_0: i32 = 0xb000;
pub const D3D_ROOT_SIGNATURE_VERSION_1: i32 = 1;
pub const D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP: i32 = 5;
pub const DXGI_FORMAT_UNKNOWN: i32 = 0;
pub const DXGI_FORMAT_R8G8B8A8_UNORM: i32 = 28;
pub const DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE: i32 = 2;
pub const DXGI_ADAPTER_FLAG_SOFTWARE: u32 = 2;
pub const COMMAND_LIST_TYPE_DIRECT: i32 = 0;
pub const DESCRIPTOR_HEAP_TYPE_RTV: i32 = 2;
pub const HEAP_TYPE_DEFAULT: i32 = 1;
pub const HEAP_TYPE_UPLOAD: i32 = 2;
pub const HEAP_TYPE_READBACK: i32 = 3;
pub const RESOURCE_DIMENSION_BUFFER: i32 = 1;
pub const RESOURCE_DIMENSION_TEXTURE2D: i32 = 3;
pub const TEXTURE_LAYOUT_UNKNOWN: i32 = 0;
pub const TEXTURE_LAYOUT_ROW_MAJOR: i32 = 1;
pub const RESOURCE_FLAG_NONE: u32 = 0;
pub const RESOURCE_FLAG_ALLOW_RENDER_TARGET: u32 = 1;
pub const RESOURCE_STATE_COMMON: u32 = 0;
pub const RESOURCE_STATE_RENDER_TARGET: u32 = 0x4;
pub const RESOURCE_STATE_COPY_DEST: u32 = 0x400;
pub const RESOURCE_STATE_COPY_SOURCE: u32 = 0x800;
pub const RESOURCE_STATE_GENERIC_READ: u32 = 0x1 | 0x2 | 0x40 | 0x80 | 0x200 | 0x800;
pub const RESOURCE_BARRIER_TYPE_TRANSITION: i32 = 0;
pub const RESOURCE_BARRIER_ALL_SUBRESOURCES: u32 = 0xffffffff;
pub const ROOT_PARAMETER_TYPE_32BIT_CONSTANTS: i32 = 1;
pub const ROOT_PARAMETER_TYPE_SRV: i32 = 3;
pub const SHADER_VISIBILITY_ALL: i32 = 0;
pub const BLEND_ONE: i32 = 2;
pub const BLEND_INV_SRC_ALPHA: i32 = 6;
pub const BLEND_OP_ADD: i32 = 1;
pub const LOGIC_OP_NOOP: i32 = 4;
pub const COLOR_WRITE_ENABLE_ALL: u8 = 15;
pub const FILL_MODE_SOLID: i32 = 3;
pub const CULL_MODE_NONE: i32 = 1;
pub const COMPARISON_FUNC_ALWAYS: i32 = 8;
pub const STENCIL_OP_KEEP: i32 = 1;
pub const PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE: i32 = 3;
pub const TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX: i32 = 0;
pub const TEXTURE_COPY_TYPE_PLACED_FOOTPRINT: i32 = 1;
pub const D3DCOMPILE_OPTIMIZATION_LEVEL3: u32 = 1 << 15;

// Structures.
pub const CPU_DESCRIPTOR_HANDLE = extern struct { ptr: usize };
pub const COMMAND_QUEUE_DESC = extern struct { Type: i32 = COMMAND_LIST_TYPE_DIRECT, Priority: i32 = 0, Flags: u32 = 0, NodeMask: u32 = 0 };
pub const DESCRIPTOR_HEAP_DESC = extern struct { Type: i32, NumDescriptors: u32, Flags: u32 = 0, NodeMask: u32 = 0 };
pub const HEAP_PROPERTIES = extern struct { Type: i32, CPUPageProperty: i32 = 0, MemoryPoolPreference: i32 = 0, CreationNodeMask: u32 = 0, VisibleNodeMask: u32 = 0 };
pub const SAMPLE_DESC = extern struct { Count: u32 = 1, Quality: u32 = 0 };
pub const RESOURCE_DESC = extern struct {
    Dimension: i32,
    Alignment: u64 = 0,
    Width: u64,
    Height: u32 = 1,
    DepthOrArraySize: u16 = 1,
    MipLevels: u16 = 1,
    Format: i32 = DXGI_FORMAT_UNKNOWN,
    SampleDesc: SAMPLE_DESC = .{},
    Layout: i32 = TEXTURE_LAYOUT_UNKNOWN,
    Flags: u32 = RESOURCE_FLAG_NONE,
};
pub const RANGE = extern struct { Begin: usize = 0, End: usize = 0 };
pub const RESOURCE_TRANSITION_BARRIER = extern struct { pResource: *Resource, Subresource: u32 = RESOURCE_BARRIER_ALL_SUBRESOURCES, StateBefore: u32, StateAfter: u32 };
pub const RESOURCE_BARRIER = extern struct { Type: i32 = RESOURCE_BARRIER_TYPE_TRANSITION, Flags: u32 = 0, Transition: RESOURCE_TRANSITION_BARRIER };
pub const SUBRESOURCE_FOOTPRINT = extern struct { Format: i32, Width: u32, Height: u32, Depth: u32 = 1, RowPitch: u32 };
pub const PLACED_SUBRESOURCE_FOOTPRINT = extern struct { Offset: u64 = 0, Footprint: SUBRESOURCE_FOOTPRINT };
pub const TEXTURE_COPY_LOCATION = extern struct {
    pResource: *Resource,
    Type: i32,
    u: extern union { PlacedFootprint: PLACED_SUBRESOURCE_FOOTPRINT, SubresourceIndex: u32 },
};
pub const VIEWPORT = extern struct { TopLeftX: f32 = 0, TopLeftY: f32 = 0, Width: f32, Height: f32, MinDepth: f32 = 0, MaxDepth: f32 = 1 };
pub const RECT = extern struct { left: i32 = 0, top: i32 = 0, right: i32, bottom: i32 };
pub const ROOT_CONSTANTS = extern struct { ShaderRegister: u32, RegisterSpace: u32 = 0, Num32BitValues: u32 };
pub const ROOT_DESCRIPTOR = extern struct { ShaderRegister: u32, RegisterSpace: u32 = 0 };
pub const ROOT_DESCRIPTOR_TABLE = extern struct { NumDescriptorRanges: u32, pDescriptorRanges: ?*const anyopaque };
pub const ROOT_PARAMETER = extern struct {
    ParameterType: i32,
    u: extern union { DescriptorTable: ROOT_DESCRIPTOR_TABLE, Constants: ROOT_CONSTANTS, Descriptor: ROOT_DESCRIPTOR },
    ShaderVisibility: i32 = SHADER_VISIBILITY_ALL,
};
pub const ROOT_SIGNATURE_DESC = extern struct { NumParameters: u32, pParameters: [*]const ROOT_PARAMETER, NumStaticSamplers: u32 = 0, pStaticSamplers: ?*const anyopaque = null, Flags: u32 = 0 };
pub const SHADER_BYTECODE = extern struct { pShaderBytecode: ?*const anyopaque = null, BytecodeLength: usize = 0 };
pub const STREAM_OUTPUT_DESC = extern struct { pSODeclaration: ?*const anyopaque = null, NumEntries: u32 = 0, pBufferStrides: ?*const u32 = null, NumStrides: u32 = 0, RasterizedStream: u32 = 0 };
pub const RENDER_TARGET_BLEND_DESC = extern struct {
    BlendEnable: BOOL = 0,
    LogicOpEnable: BOOL = 0,
    SrcBlend: i32 = BLEND_ONE,
    DestBlend: i32 = 1,
    BlendOp: i32 = BLEND_OP_ADD,
    SrcBlendAlpha: i32 = BLEND_ONE,
    DestBlendAlpha: i32 = 1,
    BlendOpAlpha: i32 = BLEND_OP_ADD,
    LogicOp: i32 = LOGIC_OP_NOOP,
    RenderTargetWriteMask: u8 = COLOR_WRITE_ENABLE_ALL,
};
pub const BLEND_DESC = extern struct { AlphaToCoverageEnable: BOOL = 0, IndependentBlendEnable: BOOL = 0, RenderTarget: [8]RENDER_TARGET_BLEND_DESC = @splat(.{}) };
pub const RASTERIZER_DESC = extern struct {
    FillMode: i32 = FILL_MODE_SOLID,
    CullMode: i32 = CULL_MODE_NONE,
    FrontCounterClockwise: BOOL = 0,
    DepthBias: i32 = 0,
    DepthBiasClamp: f32 = 0,
    SlopeScaledDepthBias: f32 = 0,
    DepthClipEnable: BOOL = 1,
    MultisampleEnable: BOOL = 0,
    AntialiasedLineEnable: BOOL = 0,
    ForcedSampleCount: u32 = 0,
    ConservativeRaster: i32 = 0,
};
pub const DEPTH_STENCILOP_DESC = extern struct { StencilFailOp: i32 = STENCIL_OP_KEEP, StencilDepthFailOp: i32 = STENCIL_OP_KEEP, StencilPassOp: i32 = STENCIL_OP_KEEP, StencilFunc: i32 = COMPARISON_FUNC_ALWAYS };
pub const DEPTH_STENCIL_DESC = extern struct {
    DepthEnable: BOOL = 0,
    DepthWriteMask: i32 = 0,
    DepthFunc: i32 = COMPARISON_FUNC_ALWAYS,
    StencilEnable: BOOL = 0,
    StencilReadMask: u8 = 0xff,
    StencilWriteMask: u8 = 0xff,
    FrontFace: DEPTH_STENCILOP_DESC = .{},
    BackFace: DEPTH_STENCILOP_DESC = .{},
};
pub const INPUT_LAYOUT_DESC = extern struct { pInputElementDescs: ?*const anyopaque = null, NumElements: u32 = 0 };
pub const CACHED_PIPELINE_STATE = extern struct { pCachedBlob: ?*const anyopaque = null, CachedBlobSizeInBytes: usize = 0 };
pub const GRAPHICS_PIPELINE_STATE_DESC = extern struct {
    pRootSignature: ?*RootSignature,
    VS: SHADER_BYTECODE,
    PS: SHADER_BYTECODE,
    DS: SHADER_BYTECODE = .{},
    HS: SHADER_BYTECODE = .{},
    GS: SHADER_BYTECODE = .{},
    StreamOutput: STREAM_OUTPUT_DESC = .{},
    BlendState: BLEND_DESC = .{},
    SampleMask: u32 = 0xffffffff,
    RasterizerState: RASTERIZER_DESC = .{},
    DepthStencilState: DEPTH_STENCIL_DESC = .{},
    InputLayout: INPUT_LAYOUT_DESC = .{},
    IBStripCutValue: i32 = 0,
    PrimitiveTopologyType: i32 = PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE,
    NumRenderTargets: u32 = 1,
    RTVFormats: [8]i32 = .{ DXGI_FORMAT_R8G8B8A8_UNORM, 0, 0, 0, 0, 0, 0, 0 },
    DSVFormat: i32 = DXGI_FORMAT_UNKNOWN,
    SampleDesc: SAMPLE_DESC = .{},
    NodeMask: u32 = 0,
    CachedPSO: CACHED_PIPELINE_STATE = .{},
    Flags: u32 = 0,
};
pub const DXGI_USAGE_RENDER_TARGET_OUTPUT: u32 = 0x20;
pub const DXGI_SWAP_EFFECT_FLIP_DISCARD: i32 = 4;
pub const DXGI_SCALING_NONE: i32 = 1;
pub const DXGI_MWA_NO_ALT_ENTER: u32 = 1 << 1;
pub const RESOURCE_STATE_PRESENT: u32 = 0;
pub const SWAP_CHAIN_DESC1 = extern struct {
    Width: u32,
    Height: u32,
    Format: i32 = DXGI_FORMAT_R8G8B8A8_UNORM,
    Stereo: BOOL = 0,
    SampleDesc: SAMPLE_DESC = .{},
    BufferUsage: u32 = DXGI_USAGE_RENDER_TARGET_OUTPUT,
    BufferCount: u32 = 2,
    Scaling: i32 = DXGI_SCALING_NONE,
    SwapEffect: i32 = DXGI_SWAP_EFFECT_FLIP_DISCARD,
    AlphaMode: i32 = 0,
    Flags: u32 = 0,
};
pub const ADAPTER_DESC1 = extern struct {
    Description: [128]u16,
    VendorId: u32,
    DeviceId: u32,
    SubSysId: u32,
    Revision: u32,
    DedicatedVideoMemory: usize,
    DedicatedSystemMemory: usize,
    SharedSystemMemory: usize,
    AdapterLuid: extern struct { LowPart: u32, HighPart: i32 },
    Flags: u32,
};

/// The function at `index` of the table of `obj`, with the type `F`.
fn method(comptime F: type, obj: anytype, comptime index: usize) F {
    const table: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    return @ptrCast(table.*[index]);
}

/// The pointer type of a method: the object, then the types of `Args`.
fn Fn(comptime Args: type, comptime R: type) type {
    const info = @typeInfo(Args).@"struct";
    var types: [info.fields.len + 1]type = undefined;
    types[0] = *anyopaque;
    for (info.fields, 0..) |f, i| types[i + 1] = f.type;
    const attrs: [types.len]std.builtin.Type.Fn.Param.Attributes = @splat(.{});
    return *const @Fn(&types, &attrs, R, .{ .@"callconv" = .winapi });
}

/// Calls the method at `index` of `obj` with `args`.
pub fn call(comptime R: type, obj: anytype, comptime index: usize, args: anytype) R {
    const f = method(Fn(@TypeOf(args), R), obj, index);
    return @call(.auto, f, .{@as(*anyopaque, @ptrCast(obj))} ++ args);
}

pub fn release(obj: anytype) void {
    _ = call(u32, obj, 2, .{});
}

pub fn check(hr: HRESULT) !void {
    if (hr < 0) return error.D3D12Call;
}

pub const Device = opaque {};
pub const CommandQueue = opaque {};
pub const CommandAllocator = opaque {};
pub const GraphicsCommandList = opaque {};
pub const Resource = opaque {};
pub const Fence = opaque {};
pub const DescriptorHeap = opaque {};
pub const RootSignature = opaque {};
pub const PipelineState = opaque {};
pub const Blob = opaque {};
pub const Factory6 = opaque {};
pub const Adapter1 = opaque {};
pub const Debug = opaque {};
pub const SwapChain3 = opaque {};

// The slots of the methods, from the C tables of the SDK headers.
pub const slot = struct {
    pub const blob_pointer = 3;
    pub const blob_size = 4;
    pub const debug_enable = 3;
    pub const device_create_command_queue = 8;
    pub const device_create_command_allocator = 9;
    pub const device_create_graphics_pipeline_state = 10;
    pub const device_create_command_list = 12;
    pub const device_create_descriptor_heap = 14;
    pub const device_descriptor_size = 15;
    pub const device_create_root_signature = 16;
    pub const device_create_render_target_view = 20;
    pub const device_create_committed_resource = 27;
    pub const device_create_fence = 36;
    pub const device_removed_reason = 37;
    pub const queue_execute = 10;
    pub const queue_signal = 14;
    pub const allocator_reset = 8;
    pub const list_close = 9;
    pub const list_reset = 10;
    pub const list_draw_instanced = 12;
    pub const list_copy_texture_region = 16;
    pub const list_set_topology = 20;
    pub const list_set_viewports = 21;
    pub const list_set_scissors = 22;
    pub const list_barrier = 26;
    pub const list_set_root_signature = 30;
    pub const list_set_root_constants = 36;
    pub const list_set_root_srv = 40;
    pub const list_set_render_targets = 46;
    pub const list_clear_rtv = 48;
    pub const resource_map = 8;
    pub const resource_unmap = 9;
    pub const resource_gpu_address = 11;
    pub const fence_completed = 8;
    pub const fence_set_event = 9;
    pub const heap_cpu_start = 9;
    pub const factory_enum_warp = 27;
    pub const factory_enum_by_preference = 29;
    pub const adapter_desc1 = 10;
    pub const unknown_query = 0;
    pub const factory_make_window_association = 8;
    pub const factory_create_swapchain_for_hwnd = 15;
    pub const swap_present = 8;
    pub const swap_get_buffer = 9;
    pub const swap_resize_buffers = 13;
    pub const swap_current_index = 36;
};

/// The functions that the DLLs export, read with `GetProcAddress`.
pub const Lib = struct {
    D3D12CreateDevice: *const fn (?*anyopaque, i32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    D3D12SerializeRootSignature: *const fn (*const ROOT_SIGNATURE_DESC, i32, *?*Blob, ?*?*Blob) callconv(.winapi) HRESULT,
    D3D12GetDebugInterface: *const fn (*const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    CreateDXGIFactory2: *const fn (u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    D3DCompile: *const fn (*const anyopaque, usize, ?[*:0]const u8, ?*const anyopaque, ?*anyopaque, [*:0]const u8, [*:0]const u8, u32, u32, *?*Blob, ?*?*Blob) callconv(.winapi) HRESULT,
};

const HMODULE = *opaque {};
extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
pub extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual: BOOL, initial: BOOL, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
pub extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;

fn open(comptime name: []const u8) !HMODULE {
    return LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral(name)) orelse error.NoD3D12;
}

fn get(comptime T: type, module: HMODULE, name: [*:0]const u8) !T {
    return @ptrCast(GetProcAddress(module, name) orelse return error.NoD3D12);
}

/// Opens `d3d12.dll`, `dxgi.dll`, and `d3dcompiler_47.dll`. A DLL or a
/// function that is missing gives `error.NoD3D12`.
pub fn load() !Lib {
    const d3d12 = try open("d3d12.dll");
    const dxgi = try open("dxgi.dll");
    const compiler = try open("d3dcompiler_47.dll");
    return .{
        .D3D12CreateDevice = try get(@FieldType(Lib, "D3D12CreateDevice"), d3d12, "D3D12CreateDevice"),
        .D3D12SerializeRootSignature = try get(@FieldType(Lib, "D3D12SerializeRootSignature"), d3d12, "D3D12SerializeRootSignature"),
        .D3D12GetDebugInterface = try get(@FieldType(Lib, "D3D12GetDebugInterface"), d3d12, "D3D12GetDebugInterface"),
        .CreateDXGIFactory2 = try get(@FieldType(Lib, "CreateDXGIFactory2"), dxgi, "CreateDXGIFactory2"),
        .D3DCompile = try get(@FieldType(Lib, "D3DCompile"), compiler, "D3DCompile"),
    };
}

test "d3d12 api: the structures have the sizes of the C headers" {
    // The sizes for x64 that `sizeof` gives in C with the headers.
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(GUID));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(RESOURCE_DESC));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(RESOURCE_BARRIER));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(TEXTURE_COPY_LOCATION));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(ROOT_PARAMETER));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(RENDER_TARGET_BLEND_DESC));
    try std.testing.expectEqual(@as(usize, 328), @sizeOf(BLEND_DESC));
    try std.testing.expectEqual(@as(usize, 656), @sizeOf(GRAPHICS_PIPELINE_STATE_DESC));
    try std.testing.expectEqual(@as(usize, 312), @sizeOf(ADAPTER_DESC1));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(ROOT_SIGNATURE_DESC));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(HEAP_PROPERTIES));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(SWAP_CHAIN_DESC1));
}

test "d3d12 api: a GUID parses in the byte order of the C form" {
    const g = GUID.parse("189819f1-1db6-4b57-be54-1821339b85f7");
    try std.testing.expectEqual(@as(u32, 0x189819f1), g.a);
    try std.testing.expectEqual(@as(u16, 0x1db6), g.b);
    try std.testing.expectEqual(@as(u16, 0x4b57), g.c);
    try std.testing.expectEqualSlices(u8, &.{ 0xbe, 0x54, 0x18, 0x21, 0x33, 0x9b, 0x85, 0xf7 }, &g.d);
}
