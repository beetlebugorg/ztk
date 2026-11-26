/* The C headers of the Wayland backend. The build translates this file
 * into the module `wayland_c`.
 * SPDX-License-Identifier: BSD-2-Clause */
#include <wayland-client.h>
#include <xdg-shell-client-protocol.h>
#include <xdg-decoration-unstable-v1-client-protocol.h>
#include <viewporter-client-protocol.h>
#include <fractional-scale-v1-client-protocol.h>
#include <cursor-shape-v1-client-protocol.h>
#include <xkbcommon/xkbcommon.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <poll.h>
#include <errno.h>
