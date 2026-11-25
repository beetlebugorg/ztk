# Task 20: The direct backend

## Goal

ztk draws directly on the display of a Linux device with no display server. It uses the GPU through Vulkan when the device has it, and the CPU through the kernel framebuffer when it does not. The input comes from `evdev`. The backend uses only kernel interfaces and, for the GPU, the Vulkan loader. It has no other dependency.

This is the backend for a kiosk and for a small touch screen. The design uses what the Printdeck project learned on a Raspberry Pi. [The lessons](../../references/printdeck.md) has the facts.

The automatic tests of this task use memory and pipes in place of the devices. A run on a real device is a manual check by a person.

## Files

- `src/platform/direct.zig`: the backend, and the choice between the two outputs
- `src/platform/fbdev.zig`: the framebuffer output, the present step, the console mode
- `src/platform/vkdisplay.zig`: the Vulkan output on a display
- `src/platform/evdev.zig`: keyboard, pointer, and touch input
- `src/platform/keymap.zig`: from a key code to a key symbol, with no library
- `src/platform/touch.zig`: from raw touches to pointer events
- `src/sys/linux.zig`: the `ioctl` numbers and the kernel structures that the backend uses
- `src/main.zig`: the `--direct` flag
- `build.zig`: the `-Dbackends` and `-Dvulkan` options

## Interfaces

```zig
// src/platform/direct.zig
pub const Output = enum { auto, vulkan, framebuffer };
pub const Rotation = enum(u16) { r0 = 0, r90 = 90, r180 = 180, r270 = 270 };
pub const Options = struct {
    output: Output = .auto,          // auto: Vulkan when it works, else the framebuffer
    fb_device: []const u8 = "/dev/fb0",
    rotation: ?Rotation = null,      // null: r0 for a tall panel, r270 for a wide one
    scale: f32 = 1,
    /// The input devices. Empty: find them in /dev/input.
    input: []const []const u8 = &.{},
    touch_debounce_ms: u32 = 0,
};
pub const Direct = struct {
    pub fn init(gpa: std.mem.Allocator, opts: Options) !*Direct;
    pub fn platform(d: *Direct) Platform;
    /// "vulkan" or "framebuffer", for the log and the statistics.
    pub fn outputName(d: *const Direct) []const u8;
};

// src/platform/fbdev.zig
pub const Format = enum { rgb565, xrgb8888 };
pub const Fbdev = struct {
    pub fn open(gpa: std.mem.Allocator, device: []const u8, rotation: ?Rotation) !*Fbdev;
    /// For tests: a framebuffer in memory.
    pub fn initMemory(gpa: std.mem.Allocator, mem: []u8, width: u32, height: u32, stride: u32, format: Format, rotation: Rotation) !*Fbdev;
    /// The size of the upright image that the renderer draws.
    pub fn imageSize(f: *const Fbdev) [2]u32;
    /// Converts the changed rows of an image to the format and the
    /// rotation of the panel and writes them to the panel memory.
    /// Returns the count of rows that it wrote.
    pub fn present(f: *Fbdev, img: Image) u32;
    pub fn close(f: *Fbdev) void;
};

// src/platform/vkdisplay.zig
pub const Mode = struct { width: u32, height: u32, refresh_mhz: u32 };
pub const DisplayInfo = struct { name: []const u8, modes: []const Mode };
/// Lists the displays of a physical device. It changes no state.
pub fn list(gpa: std.mem.Allocator, vk: *Vulkan) ![]DisplayInfo;
/// Makes a swapchain target on the first display, in its first mode.
pub fn createTarget(vk: *Vulkan, rotation: Rotation) !*Target;

// src/platform/keymap.zig
pub const Level = struct { plain: u32, shift: u32 };   // key symbols
/// The key symbols of an evdev key code in the US layout, or null.
pub fn lookup(code: u16) ?Level;
/// The UTF-8 text of a key symbol with the modifiers, or an empty slice.
pub fn text(sym: u32, mods: event.Mods, buf: *[8]u8) []const u8;

// src/platform/touch.zig
pub const Raw = struct { kind: enum { down, move, up }, x: f32, y: f32, time_ms: u32 }; // x, y in 0..1 of the panel
pub const TouchOptions = struct {
    rotation: Rotation = .r0,
    /// A finger must be off the panel this long before the touch ends.
    debounce_ms: u32 = 0,
    tap_slop: f32 = 12,          // logical pixels
};
pub const Touch = struct {
    pub fn init(opts: TouchOptions, size: geom.Size) Touch;
    /// Turns one raw touch into backend events (motion and button 1).
    pub fn feed(t: *Touch, raw: Raw, out: *std.ArrayListUnmanaged(Event), gpa: std.mem.Allocator, window: *Window) !void;
    /// Ends a touch whose debounce time passed. Call it with the time.
    pub fn tick(t: *Touch, now_ms: u32, out: *std.ArrayListUnmanaged(Event), gpa: std.mem.Allocator, window: *Window) !void;
};
```

## Steps

### The rule of this backend

1. The backend calls the kernel with system calls (`open`, `read`, `mmap`, `ioctl`, `poll`) through `std.os.linux` or `std.posix`. It uses no `libdrm`, no `libinput`, no `libudev`, no `libxkbcommon`, and no `fontconfig`. Write the `ioctl` numbers and the structures that it needs in `src/sys/linux.zig`, from the kernel headers `linux/fb.h`, `linux/input.h`, `linux/kd.h`, and `linux/vt.h`. Each one has a comment with the header and the name.
2. The build options:
   - `-Dbackends=wayland,direct,headless` selects the backends. The default is all three.
   - `-Dvulkan=true|false` includes the Vulkan renderer. The default is true.
   - A build with `-Dbackends=direct,headless -Dvulkan=false` links no library and no libc. The program is a static executable. This was checked for a program with ztcl on the development machine, for x86-64 and for `-Dtarget=aarch64-linux`.
   - A build with Vulkan links libc, because the Vulkan loader is a shared library. It has no other library.

### The framebuffer output (CPU)

3. `Fbdev.open`:
   - Read the size, the stride, and the bits for each pixel from `/sys/class/graphics/<name>/virtual_size`, `stride`, and `bits_per_pixel`. Accept 16 bits (RGB565) and 32 bits (XRGB8888). Give a clear error for another depth.
   - Map the device memory with `mmap`.
4. The console (`src/platform/console.zig`): the backend fails closed. Before it opens any device, it refuses to run when `WAYLAND_DISPLAY`, `DISPLAY`, or an `XDG_SESSION_TYPE` of x11 or wayland is set, when the standard input is not a VT (or `--tty` does not name one), when that VT is not the active one, and when the console is already in graphics mode. It never opens a fixed device name such as `/dev/tty1`. Then it sets the VT to graphics mode (`KDSETMODE` with `KD_GRAPHICS`), so that the text console does not draw over the window. It sets the mode that the console had before back in `deinit`, on `SIGINT`, `SIGTERM`, and `SIGHUP`, in the `exit` command, and in the panic handler. A `SIGKILL` cannot be caught. Both outputs do this. Tests use a fake host and never open a real terminal.
5. `present`:
   - Keep the image of the last frame. Write only the rows of `changedRows` (task 06). The first frame writes all rows.
   - Convert each pixel: RGB565 is `r >> 3`, `g >> 2`, `b >> 3` in one little-endian 16-bit number with red in the high bits. XRGB8888 is the bytes B, G, R, and 0xff.
   - Map each pixel to its rotated place. For `r90` and `r270`, a changed row of the image is a column of the panel.
   - Do not allocate in `present`.
6. The renderer of this output is the CPU renderer. The window image is kept between frames.
7. Frames: the framebuffer has no frame signal. `requestFrame` gives a `frame` event when 16 666 microseconds passed after the last frame, with `Platform.wait` as the timer. With no request, no timer runs.

### The Vulkan output (GPU)

8. The surface is `VK_KHR_display`: `vkGetPhysicalDeviceDisplayPropertiesKHR`, `vkGetDisplayModePropertiesKHR`, `vkGetPhysicalDeviceDisplayPlanePropertiesKHR`, and `vkCreateDisplayPlaneSurfaceKHR`. The Vulkan loader of the development machine lists the instance extension `VK_KHR_display`. The swapchain, the renderer, and the present are those of tasks 16 and 17, with the present mode FIFO. No window system and no other library is between the program and the display.
9. Select the first display that is connected and its first mode (the preferred one), and a plane that supports the display. A flag selects another mode: `--mode WxH`.
10. The rotation: when the surface supports the transform (`supportedTransforms`), give it to the swapchain. When it does not, turn the scene: the backend gives the renderer a 2 by 2 transform and an offset for the vertex shader. The CPU output does not use this.
11. With `output = .auto`: try Vulkan first. When the loader is missing, no device has a display, or the surface fails, print one line with the reason and use the framebuffer. When both fail, exit with status 1 and both reasons.
12. Do not create a display surface on the development machine. Its compositor owns the displays, and a second owner can disturb the session of the user. The test on that machine calls only `vkdisplay.list`.

### The input

13. `evdev.zig`:
    - Find the devices: each `/dev/input/event*` with keys (a keyboard), with relative axes and a button (a mouse), or with absolute X and Y axes and `BTN_TOUCH` (a touch panel). Read the capabilities from `/sys/class/input/event*/device/capabilities/`.
    - Read `struct input_event` records without blocking. `Platform.wait` polls all devices.
    - A keyboard: `keymap.lookup` gives the key symbols. Keep the state of Shift, Control, Alt, the logo key, and Caps Lock. The key code of the event is the `evdev` code plus 8, as on X11. The backend repeats a held key with a delay of 400 ms and a rate of 25 in each second, with `Loop.addNative`.
    - A mouse: add the relative motion to a pointer position, limit it to the window, and send `motion` and `button` events. Draw a small pointer: quads that the backend adds to the scene after the widgets. A device with only a touch panel shows no pointer.
    - A touch panel: scale the absolute values to 0..1 with the minimum and the maximum of each axis (`EVIOCGABS`), and give them to `Touch.feed`.
14. `keymap.zig` has the US layout: the letters, the digits, the punctuation keys, space, Return, Tab, Escape, BackSpace, Delete, the arrows, Home, End, Page Up, Page Down, the modifiers, and F1 to F12. The key codes are the `KEY_` numbers of `linux/input-event-codes.h`. The key symbols are those of `src/keysym.zig`. Other layouts are Stage 2. Write this limit in `docs/dev/stage1-limits.md`.
15. `touch.zig`:
    - `down` sends a `motion` to the point and then a press of button 1. `move` sends a `motion`. `up` sends a release of button 1 and then a `leave`, because a finger has no hover.
    - Map the point through the rotation to logical pixels.
    - With `debounce_ms` above 0, an `up` waits. A `down` in that time continues the same touch. `tick` sends the release when the time passed. The default is 0. A resistive panel needs about 80.
    - Keep the newest `move` when the program is busy. Never drop a `down` or an `up`.
    - Scroll gestures and the fling of a list are Stage 2, with the first widget that scrolls. Write the numbers of the lessons in a comment at that place: a move of more than 12 pixels is a scroll and not a tap, and a fling starts at 250 pixels in each second and slows with a time constant of 0.35 seconds.

### The program

16. One window exists. Its logical size is the display size after the rotation, divided by the scale. A second `createWindow` gives an error.
17. `ztk --direct` selects this backend. More flags: `--output auto|vulkan|framebuffer`, `--fb DEVICE`, `--mode WxH`, `--rotate 0|90|180|270`, `--scale N`, `--tty DEVICE`, and `--touch-debounce MS`. With no access to a device, print the system error and the group that the device file belongs to, and exit with status 1.
18. `ZTK_FRAME_STATS=1` also prints the output name and, for the framebuffer, the mean count of rows that a frame wrote.

## Tests

```sh
zig build test -Dtest-filter=fbdev
zig build test -Dtest-filter=evdev
zig build test -Dtest-filter=keymap
zig build test -Dtest-filter=touch
zig build test -Dtest-filter=vkdisplay
zig build -Dbackends=direct,headless -Dvulkan=false -p zig-out-direct
file zig-out-direct/bin/ztk
zig build -Dbackends=direct,headless -Dvulkan=false -Dtarget=aarch64-linux -p zig-out-arm
file zig-out-arm/bin/ztk
zig build -Dbackends=direct,headless -p zig-out-direct-gpu && ldd zig-out-direct-gpu/bin/ztk
zig-out-direct/bin/ztk --headless --exit-after-frames 1 examples/demo.tcl
```

- The first `file` command prints `statically linked` for x86-64. The second prints `ARM aarch64` and `statically linked`.
- The `ldd` command lists libc and its loader, and no other library. The Vulkan loader is not in the list, because the program opens it at run time.
- The static program runs the demo on the headless backend.

Framebuffer tests:

- `present` to a memory framebuffer of 32 bits, with no rotation: a red pixel at (2, 1) of the image is the bytes `00 00 ff ff` at offset `1 * stride + 2 * 4`.
- RGB565: white is `ff ff`, and red is `00 f8`.
- Rotation: for `r270` on a panel of 800 by 480, the image is 480 by 800, and the pixel (0, 0) of the image is at the panel position (0, 479). For `r90` it is at (799, 0). For `r180` on a tall panel it is the last pixel. Each case has a test with one marked pixel.
- A second `present` with one changed row writes only that row: mark a byte of another row in the panel memory by hand and check that it stays. The result of `present` is 1.
- A second `present` with no change writes no byte and returns 0.
- `present` allocates no memory (a failing allocator in the test).
- The demo on a memory framebuffer of 480 by 800 with `r0`: the content of the memory, converted back, is equal to the image of the CPU renderer.
- A frame that changes the text of `.msg` in the demo writes fewer than 10 % of the rows.

Input tests:

- `keymap.lookup` of `KEY_A` (30) gives `a` and `A`. `KEY_ENTER` (28) gives `Return`. `KEY_1` (2) gives `1` and `exclam`. An unknown code gives null.
- `keymap.text` of `a` with Shift gives `A`, and with Control gives an empty slice.
- `evdev`: a test writes `input_event` records for the keys `a` and `Return` to a pipe and gives the pipe to the reader. The backend sends the key events with the key symbols `a` and `Return` and the text `a`. With `KEY_LEFTSHIFT` down, the symbol is `A`.
- A relative motion of (5, -3) from (10, 10) gives a `motion` at (15, 7), and a motion to the outside stays at the window edge.
- A held key gives repeat events on the manual clock: none before 400 ms, and then one each 40 ms.
- `Touch`: `down`, `move`, `up` give motion, press 1, motion, release 1, and leave, with the points in logical pixels. With `r90`, the point (0, 0) of the panel maps to the correct corner.
- Debounce: with 80 ms, `up` at 100 and `down` at 120 give no release and no second press. `up` at 100 and `tick` at 181 give the release.
- A tap on a button of the demo through `Touch.feed` runs its command.
- Typing "Ada" and Return through the pipe gives `Hello, Ada!` in the demo.

Vulkan display test:

- `vkdisplay.list` returns with no error. It prints the displays and the modes that it found, or `SKIP: no Vulkan device` or `no display for Vulkan`. It creates no surface.

The manual check, by a person, on a Linux device with no display server on the console (for example a Raspberry Pi with a touch display):

```sh
ZTK_FRAME_STATS=1 zig-out/bin/ztk --direct examples/demo.tcl
ZTK_FRAME_STATS=1 zig-out/bin/ztk --direct --output framebuffer examples/demo.tcl
```

- The demo shows with each output. A tap on **Count** counts. Text entry with a USB keyboard works. **Quit** returns the text console.
- The first run prints which output it used. On a device with a Vulkan driver it is `vulkan`.
- The frame statistics show 60 frames in each second with the Vulkan output during a hover transition.
- Record the device, the display, the output, the times, the rows for each frame, and the CPU use of the process when idle and when the caret blinks.

## Acceptance

- All automatic tests pass on the development machine, with no access to a real display.
- The static build has no dependency, and the build with Vulkan has only libc.
- An idle window writes no byte to the panel and wakes no timer.
- `grep -rn -E 'xkbcommon|fontconfig|libdrm|libinput|udev' src/platform/direct.zig src/platform/fbdev.zig src/platform/evdev.zig src/platform/keymap.zig src/platform/touch.zig src/platform/vkdisplay.zig` finds no line.
- The manual check is in the stage report as done, with its numbers, or as not done, with the reason. The Vulkan output has no automatic test of its picture in this stage. The report says so.
- `docs/references/printdeck.md` names each idea of this task that comes from Printdeck. The code is new: the implementer does not open the Printdeck source.

## Out of scope

- DRM and KMS through raw `ioctl` calls: dumb buffers with page flips for the CPU output, and a Vulkan image as a KMS framebuffer for a device whose driver has no `VK_KHR_display`. Stage 2 decides after the first run on a device.
- More than one display, and a change of the display while the program runs.
- Multi-touch, pinch, scroll gestures, and the fling.
- Key layouts other than US, and input methods.
- The backlight, screen blanking, and the calibration of a touch panel.
- A change of the virtual console while the program runs.
