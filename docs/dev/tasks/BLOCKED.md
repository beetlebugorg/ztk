# Blocked steps

## Task 10: two rules of the grid solver that the oracle does not confirm

Step: "Both oracle commands print no difference for 200 layouts each."

Result on 2026-11-23 (command: `tools/oracle.sh tools/oracle-grid.tcl <seed> 200`, wish 8.6.16 under Xvfb): the outputs differ in 2 to 5 layouts of 200. Seeds 1, 2, 99, 5, and 6 gave 2, 5, 4, 3, and 5 layouts. With `nospan` as the third argument (no row span and no column span), seeds 1 to 6 gave 2, 2, 2, 1, 0, and 4 layouts of 300.

What was tried: many runs of `wish` with one container, and a fit of candidate rules in a script against 120 random cases of spans. The cases without a span, and the cases with one span, are equal. The model that is in `src/grid.zig` matches 109 of 120 random span cases.

The two kinds of difference:

1. A container that is smaller than its layout, when a weighted line reaches its minimum. `wish` keeps a line at a size of 1 where ztk gives 0. The smallest script is `tests/oracle/grid-shrink.tcl`. `wish` prints `1 24` and ztk prints `0 25`. A rule of "a weighted line keeps at least 1" gives 15 percent more differences, so it is not that simple. Another case: a line with `-minsize 32` ends at 33 in `wish`, where ztk gives 32.
2. Three or more spans that overlap on empty lines. The order of two spans of the same size is not found. The rule for the order of equal spans changes which layouts differ, and no order gives zero differences.

The reviewer decides. These cases are rare in a real script: each needs a small container with weights, or three overlapping spans.

## Task 17: the Vulkan swapchain on Wayland, and the live check

Steps: 6 (the Vulkan surface and the swapchain), 8 (a new swapchain after a resize), and 19 (the manual check on the live session).

What was done: the Wayland backend (`src/platform/wayland.zig`) draws with the CPU renderer into a `wl_shm` buffer. `zig-out/bin/ztk` always takes this path. The flag `--cpu` has no other effect in Stage 1.

Why the swapchain is not done: the run on the private compositor (sway, headless backend, pixman renderer) has no `linux-dmabuf` global, so a Vulkan swapchain on its surface cannot work there. The live desktop is not a test target for this run. No other Wayland compositor with GPU buffers was available, so the code could not be tested. Code for a swapchain that no run checked would be an unchecked claim, so it is not in the commit.

The exact fact that was checked: `ls /usr/share/vulkan/icd.d` has the Intel and the NVIDIA driver, and the offscreen renderer of task 16 works on both. The private compositor has `wl_shm` and no dmabuf.

Step 19 (a window on the live session for 3 seconds) is not done, as the instructions of this run say.

## Task 20: the Vulkan output on a display, the ARM build, and the run on a device

- The Vulkan output on a display (steps 8 to 11): not done. `vkdisplay.list` lists the displays and the modes with `VK_KHR_display`, and it changes no state. It found 0 displays on the Intel device and 1 display with 36 modes on the NVIDIA device of the development machine (2026-11-23). The swapchain on a display plane is not written, because the run instructions forbid a display surface on this machine, and code that no run checked is not added. `--output vulkan` gives `error.VulkanOutputNotAvailable`, and `--output auto` uses the framebuffer.
- The ARM build (`-Dtarget=aarch64-linux`): not done. `zig build -Dbackends=direct,headless -Dvulkan=false -Dtarget=aarch64-linux` needs more than 4 GiB of memory and the kernel killed it at the 4 GiB cap (`journalctl --user` says `oom-kill`, 4G peak, 2026-11-23). The x86-64 static build was checked (`file` says `statically linked`).
- Ownership of the VT: not done. ztk has no `KDSKBMODE`, termios change, `VT_SETMODE`, or VT switch handling, and these calls cannot be tested on this machine. `Direct.init` returns `error.DirectNotEnabled`, and the program stops, without `--direct-unsafe-test-device`.
- The run on a real device (the manual check): not done. No test opened `/dev/fb*`, a terminal, or `/dev/input/*` on this machine. `Fbdev.open` has tests with a fake device. Its real ioctl and mmap calls and `Input.discover` have no automatic test. They compile, and a person has to run them. The console checks (`console.check`), the console mode changes, the restore on each signal that ends the program, and the failure paths of `Direct.initOn` have tests with a fake host (round 1 of the review, 2026-11-23). The real host (`/proc/self/fd/0`, `/sys/class/tty/tty0/active`, and the `KDGETMODE` and `KDSETMODE` calls) has no test.
