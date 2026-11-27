//! The Vulkan renderer. It draws a scene with one instanced draw call:
//! each `Quad` is one instance, and the vertex shader makes the four
//! corners of a triangle strip. The program does not link the Vulkan
//! loader. `init` opens `libvulkan.so.1` with `DynLib`, or in a static
//! program with the ELF loader of `src/sys/elf/loader.zig`, reads
//! `vkGetInstanceProcAddr`, and reads each other function from it and
//! from `vkGetDeviceProcAddr` into two tables. Without the loader, `init`
//! gives `error.NoVulkan`, and `reason` gives the cause. The code uses Vulkan 1.0 core only. A draw
//! submits one command buffer and waits for the queue, so the CPU and the
//! GPU never share a buffer. The instance buffer grows by a factor of two.
//! The atlas page is one R8 image that uploads again when the generation
//! of the atlas changes. With validation on, a debug messenger counts the
//! messages, and the tests expect zero.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const scene_mod = @import("../scene.zig");
const renderer_mod = @import("renderer.zig");
const Atlas = @import("../text/atlas.zig").Atlas;
const Scene = scene_mod.Scene;
const Quad = scene_mod.Quad;
const Image = renderer_mod.Image;

pub const c = @import("vulkan_c");

pub const available = true;

const elfload = @import("../sys/elf/loader.zig");

var reason_buf: [512]u8 = undefined;
var reason_len: usize = 0;

/// The cause of the last `error.NoVulkan` of `init`.
pub fn reason() []const u8 {
    return reason_buf[0..reason_len];
}

fn setReason(comptime fmt: []const u8, args: anytype) void {
    const out: []u8 = std.fmt.bufPrint(&reason_buf, fmt, args) catch &reason_buf;
    reason_len = out.len;
}

/// The Vulkan loader: `std.DynLib`, or the ELF loader in a static program.
const Lib = if (elfload.supported) struct {
    h: elfload.Handle,

    fn open(name: []const u8) !Lib {
        const h = elfload.open(name) catch |e| {
            setReason("{s}", .{elfload.lastError()});
            return e;
        };
        return .{ .h = h };
    }

    fn lookup(l: *Lib, comptime T: type, name: [:0]const u8) ?T {
        return @ptrCast(@alignCast(elfload.sym(l.h, name) orelse return null));
    }

    fn close(_: *Lib) void {}
} else struct {
    d: std.DynLib,

    fn open(name: []const u8) !Lib {
        const d = std.DynLib.open(name) catch |e| {
            setReason("{s}: {s}", .{ name, @errorName(e) });
            return e;
        };
        return .{ .d = d };
    }

    fn lookup(l: *Lib, comptime T: type, name: [:0]const u8) ?T {
        return l.d.lookup(T, name);
    }

    fn close(l: *Lib) void {
        l.d.close();
    }
};

const vert_spv = @embedFile("quad_vert_spv");
const frag_spv = @embedFile("quad_frag_spv");

pub const Options = struct {
    /// The index of the physical device, or null for the default.
    device_index: ?u32 = null,
    /// The name of the Vulkan loader. A name that does not exist gives `error.NoVulkan`.
    library_name: []const u8 = "libvulkan.so.1",
    /// Instance extensions that the backend needs for its surface.
    instance_extensions: []const [*:0]const u8 = &.{},
    validate: bool = false,
};

const GetProc = *const fn (c.VkInstance, [*c]const u8) callconv(.c) c.PFN_vkVoidFunction;

const Error = error{ NoVulkan, VulkanFailed, NoDevice, NoMemoryType, OutOfMemory };

fn check(r: c.VkResult) Error!void {
    if (r != c.VK_SUCCESS) return error.VulkanFailed;
}

fn zero(comptime T: type, stype: c_uint) T {
    var v = std.mem.zeroes(T);
    v.sType = @intCast(stype);
    return v;
}

/// The functions of the loader and the instance.
const InstanceFns = struct {
    vkDestroyInstance: c.PFN_vkDestroyInstance = null,
    vkEnumeratePhysicalDevices: c.PFN_vkEnumeratePhysicalDevices = null,
    vkGetPhysicalDeviceProperties: c.PFN_vkGetPhysicalDeviceProperties = null,
    vkGetPhysicalDeviceQueueFamilyProperties: c.PFN_vkGetPhysicalDeviceQueueFamilyProperties = null,
    vkGetPhysicalDeviceMemoryProperties: c.PFN_vkGetPhysicalDeviceMemoryProperties = null,
    vkCreateDevice: c.PFN_vkCreateDevice = null,
    vkGetDeviceProcAddr: c.PFN_vkGetDeviceProcAddr = null,
    vkGetPhysicalDeviceDisplayPropertiesKHR: c.PFN_vkGetPhysicalDeviceDisplayPropertiesKHR = null,
    vkGetDisplayModePropertiesKHR: c.PFN_vkGetDisplayModePropertiesKHR = null,
    vkCreateDebugUtilsMessengerEXT: c.PFN_vkCreateDebugUtilsMessengerEXT = null,
    vkDestroyDebugUtilsMessengerEXT: c.PFN_vkDestroyDebugUtilsMessengerEXT = null,
};

const DeviceFns = struct {
    vkDestroyDevice: c.PFN_vkDestroyDevice = null,
    vkGetDeviceQueue: c.PFN_vkGetDeviceQueue = null,
    vkCreateCommandPool: c.PFN_vkCreateCommandPool = null,
    vkDestroyCommandPool: c.PFN_vkDestroyCommandPool = null,
    vkAllocateCommandBuffers: c.PFN_vkAllocateCommandBuffers = null,
    vkBeginCommandBuffer: c.PFN_vkBeginCommandBuffer = null,
    vkEndCommandBuffer: c.PFN_vkEndCommandBuffer = null,
    vkResetCommandBuffer: c.PFN_vkResetCommandBuffer = null,
    vkQueueSubmit: c.PFN_vkQueueSubmit = null,
    vkQueueWaitIdle: c.PFN_vkQueueWaitIdle = null,
    vkDeviceWaitIdle: c.PFN_vkDeviceWaitIdle = null,
    vkAllocateMemory: c.PFN_vkAllocateMemory = null,
    vkFreeMemory: c.PFN_vkFreeMemory = null,
    vkMapMemory: c.PFN_vkMapMemory = null,
    vkUnmapMemory: c.PFN_vkUnmapMemory = null,
    vkCreateBuffer: c.PFN_vkCreateBuffer = null,
    vkDestroyBuffer: c.PFN_vkDestroyBuffer = null,
    vkGetBufferMemoryRequirements: c.PFN_vkGetBufferMemoryRequirements = null,
    vkBindBufferMemory: c.PFN_vkBindBufferMemory = null,
    vkCreateImage: c.PFN_vkCreateImage = null,
    vkDestroyImage: c.PFN_vkDestroyImage = null,
    vkGetImageMemoryRequirements: c.PFN_vkGetImageMemoryRequirements = null,
    vkBindImageMemory: c.PFN_vkBindImageMemory = null,
    vkCreateImageView: c.PFN_vkCreateImageView = null,
    vkDestroyImageView: c.PFN_vkDestroyImageView = null,
    vkCreateRenderPass: c.PFN_vkCreateRenderPass = null,
    vkDestroyRenderPass: c.PFN_vkDestroyRenderPass = null,
    vkCreateFramebuffer: c.PFN_vkCreateFramebuffer = null,
    vkDestroyFramebuffer: c.PFN_vkDestroyFramebuffer = null,
    vkCreateShaderModule: c.PFN_vkCreateShaderModule = null,
    vkDestroyShaderModule: c.PFN_vkDestroyShaderModule = null,
    vkCreateDescriptorSetLayout: c.PFN_vkCreateDescriptorSetLayout = null,
    vkDestroyDescriptorSetLayout: c.PFN_vkDestroyDescriptorSetLayout = null,
    vkCreateDescriptorPool: c.PFN_vkCreateDescriptorPool = null,
    vkDestroyDescriptorPool: c.PFN_vkDestroyDescriptorPool = null,
    vkAllocateDescriptorSets: c.PFN_vkAllocateDescriptorSets = null,
    vkUpdateDescriptorSets: c.PFN_vkUpdateDescriptorSets = null,
    vkCreatePipelineLayout: c.PFN_vkCreatePipelineLayout = null,
    vkDestroyPipelineLayout: c.PFN_vkDestroyPipelineLayout = null,
    vkCreateGraphicsPipelines: c.PFN_vkCreateGraphicsPipelines = null,
    vkDestroyPipeline: c.PFN_vkDestroyPipeline = null,
    vkCmdBeginRenderPass: c.PFN_vkCmdBeginRenderPass = null,
    vkCmdEndRenderPass: c.PFN_vkCmdEndRenderPass = null,
    vkCmdBindPipeline: c.PFN_vkCmdBindPipeline = null,
    vkCmdBindDescriptorSets: c.PFN_vkCmdBindDescriptorSets = null,
    vkCmdBindVertexBuffers: c.PFN_vkCmdBindVertexBuffers = null,
    vkCmdPushConstants: c.PFN_vkCmdPushConstants = null,
    vkCmdSetViewport: c.PFN_vkCmdSetViewport = null,
    vkCmdSetScissor: c.PFN_vkCmdSetScissor = null,
    vkCmdDraw: c.PFN_vkCmdDraw = null,
    vkCmdCopyImageToBuffer: c.PFN_vkCmdCopyImageToBuffer = null,
    vkCmdCopyBufferToImage: c.PFN_vkCmdCopyBufferToImage = null,
    vkCmdPipelineBarrier: c.PFN_vkCmdPipelineBarrier = null,
};

const GlobalFns = struct {
    vkCreateInstance: c.PFN_vkCreateInstance = null,
    vkEnumerateInstanceLayerProperties: c.PFN_vkEnumerateInstanceLayerProperties = null,
    vkEnumerateInstanceExtensionProperties: c.PFN_vkEnumerateInstanceExtensionProperties = null,
};

/// An offscreen target: an RGBA 8-bit UNORM image with a framebuffer and a buffer to read it.
pub const Target = struct {
    width: u32,
    height: u32,
    image: c.VkImage = null,
    memory: c.VkDeviceMemory = null,
    view: c.VkImageView = null,
    framebuffer: c.VkFramebuffer = null,
};

const Buffer = struct {
    buf: c.VkBuffer = null,
    mem: c.VkDeviceMemory = null,
    size: u64 = 0,
    mapped: ?[*]u8 = null,
};

const atlas_size: u32 = Atlas.page_size;

pub const Vulkan = struct {
    gpa: std.mem.Allocator,
    lib: Lib,
    get_instance_proc: GetProc,
    global: GlobalFns = .{},
    ifn: InstanceFns = .{},
    dfn: DeviceFns = .{},
    instance_h: c.VkInstance = null,
    messenger: c.VkDebugUtilsMessengerEXT = null,
    /// Counts the messages of the validation layer.
    validation_messages: u32 = 0,
    phys: c.VkPhysicalDevice = null,
    mem_props: c.VkPhysicalDeviceMemoryProperties = undefined,
    device: c.VkDevice = null,
    queue: c.VkQueue = null,
    queue_family: u32 = 0,
    pool: c.VkCommandPool = null,
    cmd: c.VkCommandBuffer = null,
    render_pass: c.VkRenderPass = null,
    set_layout: c.VkDescriptorSetLayout = null,
    desc_pool: c.VkDescriptorPool = null,
    desc_set: c.VkDescriptorSet = null,
    pipe_layout: c.VkPipelineLayout = null,
    pipeline: c.VkPipeline = null,
    vert_module: c.VkShaderModule = null,
    frag_module: c.VkShaderModule = null,
    atlas_image: c.VkImage = null,
    atlas_mem: c.VkDeviceMemory = null,
    atlas_view: c.VkImageView = null,
    atlas_staging: Buffer = .{},
    atlas_generation: ?u32 = null,
    /// The RGBA image page of the atlas, at binding 1.
    image_image: c.VkImage = null,
    image_mem: c.VkDeviceMemory = null,
    image_view: c.VkImageView = null,
    image_staging: Buffer = .{},
    image_generation: ?u32 = null,
    instances: Buffer = .{},
    readback: Buffer = .{},
    target: ?*Target = null,
    name_buf: [256]u8 = undefined,
    name_len: usize = 0,
    debug_extension: bool = false,

    pub fn init(gpa: std.mem.Allocator, opts: Options) !*Vulkan {
        var lib = Lib.open(opts.library_name) catch return error.NoVulkan;
        errdefer lib.close();
        const get_proc = lib.lookup(GetProc, "vkGetInstanceProcAddr") orelse {
            setReason("{s}: no vkGetInstanceProcAddr", .{opts.library_name});
            return error.NoVulkan;
        };
        const v = try gpa.create(Vulkan);
        errdefer gpa.destroy(v);
        v.* = .{ .gpa = gpa, .lib = lib, .get_instance_proc = get_proc };
        errdefer v.teardown();
        loadFns(GlobalFns, &v.global, get_proc, null);
        try v.createInstance(opts);
        try v.pickDevice(opts);
        try v.createDevice();
        try v.createSwapIndependent();
        return v;
    }

    pub fn deinit(v: *Vulkan) void {
        const gpa = v.gpa;
        var lib = v.lib;
        v.teardown();
        gpa.destroy(v);
        lib.close();
    }

    fn teardown(v: *Vulkan) void {
        if (v.device != null) {
            _ = v.dfn.vkDeviceWaitIdle.?(v.device);
            v.destroyBuffer(&v.instances);
            v.destroyBuffer(&v.readback);
            v.destroyBuffer(&v.atlas_staging);
            v.destroyBuffer(&v.image_staging);
            if (v.image_view != null) v.dfn.vkDestroyImageView.?(v.device, v.image_view, null);
            if (v.image_image != null) v.dfn.vkDestroyImage.?(v.device, v.image_image, null);
            if (v.image_mem != null) v.dfn.vkFreeMemory.?(v.device, v.image_mem, null);
            if (v.atlas_view != null) v.dfn.vkDestroyImageView.?(v.device, v.atlas_view, null);
            if (v.atlas_image != null) v.dfn.vkDestroyImage.?(v.device, v.atlas_image, null);
            if (v.atlas_mem != null) v.dfn.vkFreeMemory.?(v.device, v.atlas_mem, null);
            if (v.pipeline != null) v.dfn.vkDestroyPipeline.?(v.device, v.pipeline, null);
            if (v.pipe_layout != null) v.dfn.vkDestroyPipelineLayout.?(v.device, v.pipe_layout, null);
            if (v.vert_module != null) v.dfn.vkDestroyShaderModule.?(v.device, v.vert_module, null);
            if (v.frag_module != null) v.dfn.vkDestroyShaderModule.?(v.device, v.frag_module, null);
            if (v.desc_pool != null) v.dfn.vkDestroyDescriptorPool.?(v.device, v.desc_pool, null);
            if (v.set_layout != null) v.dfn.vkDestroyDescriptorSetLayout.?(v.device, v.set_layout, null);
            if (v.render_pass != null) v.dfn.vkDestroyRenderPass.?(v.device, v.render_pass, null);
            if (v.pool != null) v.dfn.vkDestroyCommandPool.?(v.device, v.pool, null);
            v.dfn.vkDestroyDevice.?(v.device, null);
            v.device = null;
        }
        if (v.messenger != null) v.ifn.vkDestroyDebugUtilsMessengerEXT.?(v.instance_h, v.messenger, null);
        if (v.instance_h != null) v.ifn.vkDestroyInstance.?(v.instance_h, null);
        v.instance_h = null;
    }

    fn loadFns(comptime T: type, table: *T, getter: anytype, handle: anytype) void {
        inline for (@typeInfo(T).@"struct".field_names) |f_name| {
            const name: [:0]const u8 = f_name;
            const p = if (@TypeOf(handle) == @TypeOf(null)) getter(null, name.ptr) else getter(handle, name.ptr);
            @field(table, f_name) = @ptrCast(p);
        }
    }

    fn hasLayer(v: *Vulkan, name: []const u8) bool {
        var n: u32 = 0;
        _ = v.global.vkEnumerateInstanceLayerProperties.?(&n, null);
        if (n == 0) return false;
        const list = v.gpa.alloc(c.VkLayerProperties, n) catch return false;
        defer v.gpa.free(list);
        _ = v.global.vkEnumerateInstanceLayerProperties.?(&n, list.ptr);
        for (list[0..n]) |lp| {
            const ln = std.mem.sliceTo(&lp.layerName, 0);
            if (std.mem.eql(u8, ln, name)) return true;
        }
        return false;
    }

    fn debugCallback(severity: c.VkDebugUtilsMessageSeverityFlagBitsEXT, _: c.VkDebugUtilsMessageTypeFlagsEXT, data: [*c]const c.VkDebugUtilsMessengerCallbackDataEXT, user: ?*anyopaque) callconv(.c) c.VkBool32 {
        const v: *Vulkan = @ptrCast(@alignCast(user.?));
        if (severity & (c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) != 0) {
            v.validation_messages += 1;
            std.debug.print("vulkan validation: {s}\n", .{data.*.pMessage});
        }
        return c.VK_FALSE;
    }

    fn createInstance(v: *Vulkan, opts: Options) !void {
        var validate = opts.validate;
        if (std.c.getenv("ZTK_VK_VALIDATE")) |e| {
            if (std.mem.eql(u8, std.mem.span(e), "1")) validate = true;
        }
        const layer: [*:0]const u8 = "VK_LAYER_KHRONOS_validation";
        const use_layer = validate and v.hasLayer("VK_LAYER_KHRONOS_validation");
        var app = zero(c.VkApplicationInfo, c.VK_STRUCTURE_TYPE_APPLICATION_INFO);
        app.pApplicationName = "ztk";
        app.apiVersion = 1 << 22;
        var exts: [8][*:0]const u8 = undefined;
        var n_ext: usize = 0;
        for (opts.instance_extensions) |e| {
            exts[n_ext] = e;
            n_ext += 1;
        }
        if (use_layer) {
            exts[n_ext] = "VK_EXT_debug_utils";
            n_ext += 1;
            v.debug_extension = true;
        }
        var ci = zero(c.VkInstanceCreateInfo, c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO);
        ci.pApplicationInfo = &app;
        ci.enabledExtensionCount = @intCast(n_ext);
        ci.ppEnabledExtensionNames = @ptrCast(&exts);
        if (use_layer) {
            ci.enabledLayerCount = 1;
            ci.ppEnabledLayerNames = @ptrCast(&layer);
        }
        check(v.global.vkCreateInstance.?(&ci, null, &v.instance_h)) catch return error.NoVulkan;
        loadFns(InstanceFns, &v.ifn, v.get_instance_proc, v.instance_h);
        if (use_layer and v.ifn.vkCreateDebugUtilsMessengerEXT != null) {
            var mi = zero(c.VkDebugUtilsMessengerCreateInfoEXT, c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT);
            mi.messageSeverity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
            mi.messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
            mi.pfnUserCallback = debugCallback;
            mi.pUserData = v;
            try check(v.ifn.vkCreateDebugUtilsMessengerEXT.?(v.instance_h, &mi, null, &v.messenger));
        }
    }

    fn pickDevice(v: *Vulkan, opts: Options) !void {
        var n: u32 = 0;
        try check(v.ifn.vkEnumeratePhysicalDevices.?(v.instance_h, &n, null));
        if (n == 0) return error.NoDevice;
        const list = try v.gpa.alloc(c.VkPhysicalDevice, n);
        defer v.gpa.free(list);
        try check(v.ifn.vkEnumeratePhysicalDevices.?(v.instance_h, &n, list.ptr));
        var want: ?u32 = opts.device_index;
        if (std.c.getenv("ZTK_GPU")) |e| want = std.fmt.parseInt(u32, std.mem.span(e), 10) catch want;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (want) |w| if (w != i) continue;
            var qn: u32 = 0;
            v.ifn.vkGetPhysicalDeviceQueueFamilyProperties.?(list[i], &qn, null);
            const qs = try v.gpa.alloc(c.VkQueueFamilyProperties, qn);
            defer v.gpa.free(qs);
            v.ifn.vkGetPhysicalDeviceQueueFamilyProperties.?(list[i], &qn, qs.ptr);
            for (qs[0..qn], 0..) |q, qi| {
                if (q.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0) {
                    v.phys = list[i];
                    v.queue_family = @intCast(qi);
                    var props: c.VkPhysicalDeviceProperties = undefined;
                    v.ifn.vkGetPhysicalDeviceProperties.?(v.phys, &props);
                    const nm = std.mem.sliceTo(&props.deviceName, 0);
                    v.name_len = @min(nm.len, v.name_buf.len);
                    @memcpy(v.name_buf[0..v.name_len], nm[0..v.name_len]);
                    v.ifn.vkGetPhysicalDeviceMemoryProperties.?(v.phys, &v.mem_props);
                    return;
                }
            }
        }
        return error.NoDevice;
    }

    fn createDevice(v: *Vulkan) !void {
        const prio: f32 = 1;
        var qi = zero(c.VkDeviceQueueCreateInfo, c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO);
        qi.queueFamilyIndex = v.queue_family;
        qi.queueCount = 1;
        qi.pQueuePriorities = &prio;
        var ci = zero(c.VkDeviceCreateInfo, c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO);
        ci.queueCreateInfoCount = 1;
        ci.pQueueCreateInfos = &qi;
        try check(v.ifn.vkCreateDevice.?(v.phys, &ci, null, &v.device));
        const getter = v.ifn.vkGetDeviceProcAddr.?;
        loadFns(DeviceFns, &v.dfn, getter, v.device);
        v.dfn.vkGetDeviceQueue.?(v.device, v.queue_family, 0, &v.queue);
    }

    /// One mode of a display: the size in pixels and the refresh rate in millihertz.
    pub const DisplayMode = struct { width: u32, height: u32, refresh_mhz: u32 };
    pub const DisplayEntry = struct { name: []const u8, modes: []DisplayMode };

    /// Lists the displays of the physical device and their modes. It needs the instance
    /// extensions `VK_KHR_surface` and `VK_KHR_display`. It changes no state. The caller
    /// frees the result with `freeDisplays`.
    pub fn displays(v: *Vulkan, gpa: std.mem.Allocator) ![]DisplayEntry {
        const get_props = v.ifn.vkGetPhysicalDeviceDisplayPropertiesKHR orelse return error.NoDisplayExtension;
        const get_modes = v.ifn.vkGetDisplayModePropertiesKHR orelse return error.NoDisplayExtension;
        var n: u32 = 0;
        try check(get_props(v.phys, &n, null));
        const props = try gpa.alloc(c.VkDisplayPropertiesKHR, n);
        defer gpa.free(props);
        try check(get_props(v.phys, &n, props.ptr));
        var out = try gpa.alloc(DisplayEntry, n);
        var made: usize = 0;
        errdefer {
            for (out[0..made]) |e| {
                gpa.free(e.name);
                gpa.free(e.modes);
            }
            gpa.free(out);
        }
        for (props[0..n]) |p| {
            const name = if (p.displayName) |nm| try gpa.dupe(u8, std.mem.span(nm)) else try gpa.dupe(u8, "display");
            errdefer gpa.free(name);
            var mn: u32 = 0;
            try check(get_modes(v.phys, p.display, &mn, null));
            const mprops = try gpa.alloc(c.VkDisplayModePropertiesKHR, mn);
            defer gpa.free(mprops);
            try check(get_modes(v.phys, p.display, &mn, mprops.ptr));
            const modes = try gpa.alloc(DisplayMode, mn);
            for (mprops[0..mn], modes) |mp, *m| m.* = .{ .width = mp.parameters.visibleRegion.width, .height = mp.parameters.visibleRegion.height, .refresh_mhz = mp.parameters.refreshRate };
            out[made] = .{ .name = name, .modes = modes };
            made += 1;
        }
        return out;
    }

    pub fn freeDisplays(gpa: std.mem.Allocator, list: []DisplayEntry) void {
        for (list) |e| {
            gpa.free(e.name);
            gpa.free(e.modes);
        }
        gpa.free(list);
    }

    pub fn deviceName(v: *const Vulkan) []const u8 {
        return v.name_buf[0..v.name_len];
    }

    /// The instance handle, for the backend that makes a surface.
    pub fn instance(v: *const Vulkan) *anyopaque {
        return @ptrCast(v.instance_h.?);
    }

    // ---- Memory ----

    fn memoryType(v: *const Vulkan, bits: u32, flags: c.VkMemoryPropertyFlags) !u32 {
        var i: u32 = 0;
        while (i < v.mem_props.memoryTypeCount) : (i += 1) {
            if (bits & (@as(u32, 1) << @intCast(i)) != 0 and v.mem_props.memoryTypes[i].propertyFlags & flags == flags) return i;
        }
        return error.NoMemoryType;
    }

    fn createBuffer(v: *Vulkan, b: *Buffer, size: u64, usage: c.VkBufferUsageFlags) !void {
        var bi = zero(c.VkBufferCreateInfo, c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO);
        bi.size = size;
        bi.usage = usage;
        bi.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        try check(v.dfn.vkCreateBuffer.?(v.device, &bi, null, &b.buf));
        errdefer v.dfn.vkDestroyBuffer.?(v.device, b.buf, null);
        var req: c.VkMemoryRequirements = undefined;
        v.dfn.vkGetBufferMemoryRequirements.?(v.device, b.buf, &req);
        var ai = zero(c.VkMemoryAllocateInfo, c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO);
        ai.allocationSize = req.size;
        ai.memoryTypeIndex = try v.memoryType(req.memoryTypeBits, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        try check(v.dfn.vkAllocateMemory.?(v.device, &ai, null, &b.mem));
        errdefer v.dfn.vkFreeMemory.?(v.device, b.mem, null);
        try check(v.dfn.vkBindBufferMemory.?(v.device, b.buf, b.mem, 0));
        var p: ?*anyopaque = null;
        try check(v.dfn.vkMapMemory.?(v.device, b.mem, 0, std.math.maxInt(u64), 0, &p));
        b.mapped = @ptrCast(p);
        b.size = size;
    }

    fn destroyBuffer(v: *Vulkan, b: *Buffer) void {
        if (b.buf == null) return;
        v.dfn.vkUnmapMemory.?(v.device, b.mem);
        v.dfn.vkDestroyBuffer.?(v.device, b.buf, null);
        v.dfn.vkFreeMemory.?(v.device, b.mem, null);
        b.* = .{};
    }

    fn createImage(v: *Vulkan, w: u32, h: u32, format: c.VkFormat, usage: c.VkImageUsageFlags, image: *c.VkImage, mem: *c.VkDeviceMemory) !void {
        var ii = zero(c.VkImageCreateInfo, c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO);
        ii.imageType = c.VK_IMAGE_TYPE_2D;
        ii.format = format;
        ii.extent = .{ .width = w, .height = h, .depth = 1 };
        ii.mipLevels = 1;
        ii.arrayLayers = 1;
        ii.samples = c.VK_SAMPLE_COUNT_1_BIT;
        ii.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        ii.usage = usage;
        ii.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        ii.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        try check(v.dfn.vkCreateImage.?(v.device, &ii, null, image));
        errdefer v.dfn.vkDestroyImage.?(v.device, image.*, null);
        var req: c.VkMemoryRequirements = undefined;
        v.dfn.vkGetImageMemoryRequirements.?(v.device, image.*, &req);
        var ai = zero(c.VkMemoryAllocateInfo, c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO);
        ai.allocationSize = req.size;
        ai.memoryTypeIndex = try v.memoryType(req.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        try check(v.dfn.vkAllocateMemory.?(v.device, &ai, null, mem));
        errdefer v.dfn.vkFreeMemory.?(v.device, mem.*, null);
        try check(v.dfn.vkBindImageMemory.?(v.device, image.*, mem.*, 0));
    }

    fn createView(v: *Vulkan, image: c.VkImage, format: c.VkFormat) !c.VkImageView {
        var vi = zero(c.VkImageViewCreateInfo, c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO);
        vi.image = image;
        vi.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        vi.format = format;
        vi.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        var view: c.VkImageView = null;
        try check(v.dfn.vkCreateImageView.?(v.device, &vi, null, &view));
        return view;
    }

    // ---- The fixed objects ----

    fn shaderModule(v: *Vulkan, code: []const u8) !c.VkShaderModule {
        var mi = zero(c.VkShaderModuleCreateInfo, c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO);
        mi.codeSize = code.len;
        // The embedded file has the alignment of a byte, so copy it to aligned memory.
        const words = try v.gpa.alloc(u32, code.len / 4);
        defer v.gpa.free(words);
        @memcpy(std.mem.sliceAsBytes(words), code);
        mi.pCode = words.ptr;
        var m: c.VkShaderModule = null;
        try check(v.dfn.vkCreateShaderModule.?(v.device, &mi, null, &m));
        return m;
    }

    fn createSwapIndependent(v: *Vulkan) !void {
        // The command pool and the command buffer.
        var pi = zero(c.VkCommandPoolCreateInfo, c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO);
        pi.queueFamilyIndex = v.queue_family;
        pi.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        try check(v.dfn.vkCreateCommandPool.?(v.device, &pi, null, &v.pool));
        var ai = zero(c.VkCommandBufferAllocateInfo, c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO);
        ai.commandPool = v.pool;
        ai.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        ai.commandBufferCount = 1;
        try check(v.dfn.vkAllocateCommandBuffers.?(v.device, &ai, &v.cmd));

        // The render pass: clear, draw, and leave the image ready to copy.
        var att = std.mem.zeroes(c.VkAttachmentDescription);
        att.format = c.VK_FORMAT_R8G8B8A8_UNORM;
        att.samples = c.VK_SAMPLE_COUNT_1_BIT;
        att.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        att.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        att.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        att.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        att.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        att.finalLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        const ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        var sub = std.mem.zeroes(c.VkSubpassDescription);
        sub.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
        sub.colorAttachmentCount = 1;
        sub.pColorAttachments = &ref;
        var rp = zero(c.VkRenderPassCreateInfo, c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO);
        rp.attachmentCount = 1;
        rp.pAttachments = &att;
        rp.subpassCount = 1;
        rp.pSubpasses = &sub;
        try check(v.dfn.vkCreateRenderPass.?(v.device, &rp, null, &v.render_pass));

        // The descriptor set of the atlas: the coverage page at binding 0
        // and the image page at binding 1.
        var bindings: [2]c.VkDescriptorSetLayoutBinding = .{ std.mem.zeroes(c.VkDescriptorSetLayoutBinding), std.mem.zeroes(c.VkDescriptorSetLayoutBinding) };
        for (&bindings, 0..) |*binding, k| {
            binding.binding = @intCast(k);
            binding.descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
            binding.descriptorCount = 1;
            binding.stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT;
        }
        var li = zero(c.VkDescriptorSetLayoutCreateInfo, c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO);
        li.bindingCount = 2;
        li.pBindings = &bindings;
        try check(v.dfn.vkCreateDescriptorSetLayout.?(v.device, &li, null, &v.set_layout));
        const psize = c.VkDescriptorPoolSize{ .type = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 2 };
        var dpi = zero(c.VkDescriptorPoolCreateInfo, c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO);
        dpi.maxSets = 1;
        dpi.poolSizeCount = 1;
        dpi.pPoolSizes = &psize;
        try check(v.dfn.vkCreateDescriptorPool.?(v.device, &dpi, null, &v.desc_pool));
        var dai = zero(c.VkDescriptorSetAllocateInfo, c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO);
        dai.descriptorPool = v.desc_pool;
        dai.descriptorSetCount = 1;
        dai.pSetLayouts = &v.set_layout;
        try check(v.dfn.vkAllocateDescriptorSets.?(v.device, &dai, &v.desc_set));

        // The atlas image, its view, and its staging buffer.
        try v.createImage(atlas_size, atlas_size, c.VK_FORMAT_R8_UNORM, c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT, &v.atlas_image, &v.atlas_mem);
        v.atlas_view = try v.createView(v.atlas_image, c.VK_FORMAT_R8_UNORM);
        try v.createBuffer(&v.atlas_staging, @as(u64, atlas_size) * atlas_size, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
        try v.createImage(atlas_size, atlas_size, c.VK_FORMAT_R8G8B8A8_UNORM, c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT, &v.image_image, &v.image_mem);
        v.image_view = try v.createView(v.image_image, c.VK_FORMAT_R8G8B8A8_UNORM);
        try v.createBuffer(&v.image_staging, @as(u64, atlas_size) * atlas_size * 4, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
        const infos = [2]c.VkDescriptorImageInfo{
            .{ .sampler = null, .imageView = v.atlas_view, .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
            .{ .sampler = null, .imageView = v.image_view, .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
        };
        var writes: [2]c.VkWriteDescriptorSet = undefined;
        for (&writes, 0..) |*wr, k| {
            wr.* = zero(c.VkWriteDescriptorSet, c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET);
            wr.dstSet = v.desc_set;
            wr.dstBinding = @intCast(k);
            wr.descriptorCount = 1;
            wr.descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
            wr.pImageInfo = &infos[k];
        }
        v.dfn.vkUpdateDescriptorSets.?(v.device, 2, &writes, 0, null);

        // The pipeline.
        v.vert_module = try v.shaderModule(vert_spv);
        v.frag_module = try v.shaderModule(frag_spv);
        var stages: [2]c.VkPipelineShaderStageCreateInfo = undefined;
        stages[0] = zero(c.VkPipelineShaderStageCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO);
        stages[0].stage = c.VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module = v.vert_module;
        stages[0].pName = "main";
        stages[1] = zero(c.VkPipelineShaderStageCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO);
        stages[1].stage = c.VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module = v.frag_module;
        stages[1].pName = "main";
        const vb = c.VkVertexInputBindingDescription{ .binding = 0, .stride = @sizeOf(Quad), .inputRate = c.VK_VERTEX_INPUT_RATE_INSTANCE };
        var attrs: [10]c.VkVertexInputAttributeDescription = undefined;
        inline for (0..9) |i| attrs[i] = .{ .location = i, .binding = 0, .format = c.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = i * 16 };
        attrs[9] = .{ .location = 9, .binding = 0, .format = c.VK_FORMAT_R32_UINT, .offset = @offsetOf(Quad, "kind") };
        var vi = zero(c.VkPipelineVertexInputStateCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO);
        vi.vertexBindingDescriptionCount = 1;
        vi.pVertexBindingDescriptions = &vb;
        vi.vertexAttributeDescriptionCount = 10;
        vi.pVertexAttributeDescriptions = &attrs;
        var ia = zero(c.VkPipelineInputAssemblyStateCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO);
        ia.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP;
        var vp = zero(c.VkPipelineViewportStateCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO);
        vp.viewportCount = 1;
        vp.scissorCount = 1;
        var rs = zero(c.VkPipelineRasterizationStateCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO);
        rs.polygonMode = c.VK_POLYGON_MODE_FILL;
        rs.cullMode = c.VK_CULL_MODE_NONE;
        rs.frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE;
        rs.lineWidth = 1;
        var ms = zero(c.VkPipelineMultisampleStateCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO);
        ms.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;
        var cba = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
        cba.blendEnable = c.VK_TRUE;
        cba.srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE;
        cba.dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        cba.colorBlendOp = c.VK_BLEND_OP_ADD;
        // The alpha of the target stays 1.
        cba.srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO;
        cba.dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE;
        cba.alphaBlendOp = c.VK_BLEND_OP_ADD;
        cba.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
        var cb = zero(c.VkPipelineColorBlendStateCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO);
        cb.attachmentCount = 1;
        cb.pAttachments = &cba;
        const dyn = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        var ds = zero(c.VkPipelineDynamicStateCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO);
        ds.dynamicStateCount = 2;
        ds.pDynamicStates = &dyn;
        const pcr = c.VkPushConstantRange{ .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT, .offset = 0, .size = 8 };
        var pl = zero(c.VkPipelineLayoutCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO);
        pl.setLayoutCount = 1;
        pl.pSetLayouts = &v.set_layout;
        pl.pushConstantRangeCount = 1;
        pl.pPushConstantRanges = &pcr;
        try check(v.dfn.vkCreatePipelineLayout.?(v.device, &pl, null, &v.pipe_layout));
        var gp = zero(c.VkGraphicsPipelineCreateInfo, c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO);
        gp.stageCount = 2;
        gp.pStages = &stages;
        gp.pVertexInputState = &vi;
        gp.pInputAssemblyState = &ia;
        gp.pViewportState = &vp;
        gp.pRasterizationState = &rs;
        gp.pMultisampleState = &ms;
        gp.pColorBlendState = &cb;
        gp.pDynamicState = &ds;
        gp.layout = v.pipe_layout;
        gp.renderPass = v.render_pass;
        gp.subpass = 0;
        try check(v.dfn.vkCreateGraphicsPipelines.?(v.device, null, 1, &gp, null, &v.pipeline));
        // The instance buffer starts with room for 1024 quads.
        try v.createBuffer(&v.instances, 1024 * @sizeOf(Quad), c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
    }

    // ---- Targets ----

    /// An offscreen target of a size. The format is RGBA 8-bit UNORM.
    pub fn createOffscreen(v: *Vulkan, width: u32, height: u32) !*Target {
        const t = try v.gpa.create(Target);
        errdefer v.gpa.destroy(t);
        t.* = .{ .width = width, .height = height };
        try v.createImage(width, height, c.VK_FORMAT_R8G8B8A8_UNORM, c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT, &t.image, &t.memory);
        errdefer {
            v.dfn.vkDestroyImage.?(v.device, t.image, null);
            v.dfn.vkFreeMemory.?(v.device, t.memory, null);
        }
        t.view = try v.createView(t.image, c.VK_FORMAT_R8G8B8A8_UNORM);
        errdefer v.dfn.vkDestroyImageView.?(v.device, t.view, null);
        var fi = zero(c.VkFramebufferCreateInfo, c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO);
        fi.renderPass = v.render_pass;
        fi.attachmentCount = 1;
        fi.pAttachments = &t.view;
        fi.width = width;
        fi.height = height;
        fi.layers = 1;
        try check(v.dfn.vkCreateFramebuffer.?(v.device, &fi, null, &t.framebuffer));
        if (v.target == null) v.target = t;
        return t;
    }

    pub fn destroyTarget(v: *Vulkan, t: *Target) void {
        _ = v.dfn.vkDeviceWaitIdle.?(v.device);
        v.dfn.vkDestroyFramebuffer.?(v.device, t.framebuffer, null);
        v.dfn.vkDestroyImageView.?(v.device, t.view, null);
        v.dfn.vkDestroyImage.?(v.device, t.image, null);
        v.dfn.vkFreeMemory.?(v.device, t.memory, null);
        if (v.target == t) v.target = null;
        v.gpa.destroy(t);
    }

    pub fn setTarget(v: *Vulkan, t: *Target) void {
        v.target = t;
    }

    // ---- Drawing ----

    fn barrier(v: *Vulkan, image: c.VkImage, old: c.VkImageLayout, new: c.VkImageLayout, src_access: c.VkAccessFlags, dst_access: c.VkAccessFlags, src_stage: c.VkPipelineStageFlags, dst_stage: c.VkPipelineStageFlags) void {
        var b = zero(c.VkImageMemoryBarrier, c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER);
        b.srcAccessMask = src_access;
        b.dstAccessMask = dst_access;
        b.oldLayout = old;
        b.newLayout = new;
        b.srcQueueFamilyIndex = std.math.maxInt(u32);
        b.dstQueueFamilyIndex = std.math.maxInt(u32);
        b.image = image;
        b.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        v.dfn.vkCmdPipelineBarrier.?(v.cmd, src_stage, dst_stage, 0, 0, null, 0, null, 1, &b);
    }

    fn submitAndWait(v: *Vulkan) !void {
        try check(v.dfn.vkEndCommandBuffer.?(v.cmd));
        var si = zero(c.VkSubmitInfo, c.VK_STRUCTURE_TYPE_SUBMIT_INFO);
        si.commandBufferCount = 1;
        si.pCommandBuffers = &v.cmd;
        try check(v.dfn.vkQueueSubmit.?(v.queue, 1, &si, null));
        try check(v.dfn.vkQueueWaitIdle.?(v.queue));
    }

    fn begin(v: *Vulkan) !void {
        try check(v.dfn.vkResetCommandBuffer.?(v.cmd, 0));
        var bi = zero(c.VkCommandBufferBeginInfo, c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO);
        bi.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try check(v.dfn.vkBeginCommandBuffer.?(v.cmd, &bi));
    }

    /// Uploads the pages of the atlas when their generation changed since
    /// the last upload: the coverage page and the RGBA image page.
    fn syncAtlas(v: *Vulkan, atlas: *const Atlas) void {
        v.syncPage(v.atlas_image, &v.atlas_staging, &v.atlas_generation, atlas.generation, atlas.page());
        v.syncPage(v.image_image, &v.image_staging, &v.image_generation, atlas.images.generation, atlas.imagePage());
    }

    fn syncPage(v: *Vulkan, image: c.VkImage, staging: *Buffer, seen: *?u32, generation: u32, page: []const u8) void {
        if (seen.*) |g| if (g == generation) return;
        if (page.len == 0) {
            // No page yet: give the image a defined layout so that the shader can read it.
            if (seen.* == null) v.barrier(image, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, 0, c.VK_ACCESS_SHADER_READ_BIT, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
            seen.* = generation;
            return;
        }
        @memcpy(staging.mapped.?[0..page.len], page);
        const first = seen.* == null;
        v.barrier(image, if (first) c.VK_IMAGE_LAYOUT_UNDEFINED else c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 0, c.VK_ACCESS_TRANSFER_WRITE_BIT, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT | c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT);
        var region = std.mem.zeroes(c.VkBufferImageCopy);
        region.imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 };
        region.imageExtent = .{ .width = atlas_size, .height = atlas_size, .depth = 1 };
        v.dfn.vkCmdCopyBufferToImage.?(v.cmd, staging.buf, image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
        v.barrier(image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, c.VK_ACCESS_TRANSFER_WRITE_BIT, c.VK_ACCESS_SHADER_READ_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
        seen.* = generation;
    }

    /// Draws a scene to the current target.
    pub fn draw(v: *Vulkan, scene: *const Scene, atlas: *const Atlas) !void {
        const t = v.target orelse return error.NoTarget;
        const n = scene.quads.items.len;
        const need: u64 = @as(u64, n) * @sizeOf(Quad);
        if (need > v.instances.size) {
            var size = v.instances.size;
            while (size < need) size *= 2;
            _ = v.dfn.vkDeviceWaitIdle.?(v.device);
            v.destroyBuffer(&v.instances);
            try v.createBuffer(&v.instances, size, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        }
        if (n > 0) @memcpy(v.instances.mapped.?[0..need], std.mem.sliceAsBytes(scene.quads.items));
        try v.begin();
        v.syncAtlas(atlas);
        var clear = c.VkClearValue{ .color = .{ .float32 = scene.clear } };
        var rb = zero(c.VkRenderPassBeginInfo, c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO);
        rb.renderPass = v.render_pass;
        rb.framebuffer = t.framebuffer;
        rb.renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = t.width, .height = t.height } };
        rb.clearValueCount = 1;
        rb.pClearValues = &clear;
        v.dfn.vkCmdBeginRenderPass.?(v.cmd, &rb, c.VK_SUBPASS_CONTENTS_INLINE);
        if (n > 0) {
            v.dfn.vkCmdBindPipeline.?(v.cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, v.pipeline);
            const viewport = c.VkViewport{ .x = 0, .y = 0, .width = @floatFromInt(t.width), .height = @floatFromInt(t.height), .minDepth = 0, .maxDepth = 1 };
            v.dfn.vkCmdSetViewport.?(v.cmd, 0, 1, &viewport);
            const sc = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = t.width, .height = t.height } };
            v.dfn.vkCmdSetScissor.?(v.cmd, 0, 1, &sc);
            v.dfn.vkCmdBindDescriptorSets.?(v.cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, v.pipe_layout, 0, 1, &v.desc_set, 0, null);
            const offset: u64 = 0;
            v.dfn.vkCmdBindVertexBuffers.?(v.cmd, 0, 1, &v.instances.buf, &offset);
            const size = [2]f32{ @floatFromInt(t.width), @floatFromInt(t.height) };
            v.dfn.vkCmdPushConstants.?(v.cmd, v.pipe_layout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, 8, &size);
            v.dfn.vkCmdDraw.?(v.cmd, 4, @intCast(n), 0, 0);
        }
        v.dfn.vkCmdEndRenderPass.?(v.cmd);
        try v.submitAndWait();
    }

    /// Copies the pixels of an offscreen target to an image of the same size.
    pub fn readPixels(v: *Vulkan, t: *Target, out: *Image) !void {
        const bytes: u64 = @as(u64, t.width) * t.height * 4;
        if (v.readback.size < bytes) {
            v.destroyBuffer(&v.readback);
            try v.createBuffer(&v.readback, bytes, c.VK_BUFFER_USAGE_TRANSFER_DST_BIT);
        }
        try v.begin();
        var region = std.mem.zeroes(c.VkBufferImageCopy);
        region.imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 };
        region.imageExtent = .{ .width = t.width, .height = t.height, .depth = 1 };
        v.dfn.vkCmdCopyImageToBuffer.?(v.cmd, t.image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, v.readback.buf, 1, &region);
        try v.submitAndWait();
        @memcpy(out.pixels[0..bytes], v.readback.mapped.?[0..bytes]);
        out.width = t.width;
        out.height = t.height;
    }

    // ---- The Renderer interface ----

    fn rDeinit(ptr: *anyopaque) void {
        const v: *Vulkan = @ptrCast(@alignCast(ptr));
        v.deinit();
    }

    fn rDraw(ptr: *anyopaque, scene: *const Scene, atlas: *const Atlas) anyerror!void {
        const v: *Vulkan = @ptrCast(@alignCast(ptr));
        return v.draw(scene, atlas);
    }

    const vtable: renderer_mod.Renderer.VTable = .{ .deinit = rDeinit, .draw = rDraw };

    pub fn renderer(v: *Vulkan) renderer_mod.Renderer {
        return .{ .ptr = v, .vtable = &vtable };
    }
};
