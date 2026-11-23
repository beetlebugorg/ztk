# Not used

## zslice

zslice (https://github.com/beetlebugorg/zslice) has renderers for Vulkan, Metal, Direct3D 12, and WebGL. It has the AGPL-3.0-or-later license. ztk has no code of zslice. The planner looked at the folder layout of zslice and read no renderer source. The implementer does not open the zslice source for a ztk task.

## Printdeck code

Printdeck has the AGPL-3.0 license. ztk uses ideas and measured facts of Printdeck, which [Printdeck](printdeck.md) lists, and no code.

## The C source and the library scripts of Tk

The license of Tk permits a copy. The project still forbids it, so that each line of ztk has one origin. ztk follows the manual pages and the behavior of `wish`.

## FreeType and fontconfig

The first plan had FreeType for the glyph images and fontconfig for the font search. The user asked for no dependency. ztk has its own font engine. fontconfig is only an optional library that ztk opens at run time, from Stage 2.

## libdrm, libinput, libudev

The direct backend calls the kernel with system calls. It uses none of these libraries.

## FriBidi and ICU

FriBidi has the LGPL-2.1-or-later license, which does not fit a static BSD-2-Clause library. ICU is larger than the rest of ztk. Stage 4 has its own code for the Unicode annexes.

## SDL, GLFW, and a GPU abstraction library

SDL and GLFW hide window features that Tk needs. `wgpu-native` and Dawn add a large binary. The plan gives the reasons in decisions D3 and D8.
