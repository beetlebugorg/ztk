# Python tkinter and the C API of Tk

libztk (`src/libztk.zig`, `src/libztk_tk.zig`, `packaging/libztk/include/tk.h`) has the part of the C API of Tk 8.6 that Python's `_tkinter` and common extensions call. It has no code of Tk, of CPython, or of an extension.

## The manual pages of the C API of Tk

Tk 8.6.16, `doc/Tk_Init.3`, `doc/MainWin.3`, `doc/MainLoop.3`, `doc/CrtWindow.3`, and `doc/FindPhoto.3`. https://github.com/tcltk/tk/tree/core-8-6-16/doc

**License:** Tcl/Tk License (BSD style)

**How ztk uses it:** the names, the arguments, the results, and the structure `Tk_PhotoImageBlock` of these pages. `tk.h` of libztk has its own text with the declarations of these pages. The repetition of a block in a region larger than the block, and the composite rules of `Tk_PhotoPutBlock`, come from `FindPhoto.3`.

## The manual pages of the event loop of Tcl

Tcl 8.6.16, `doc/DoOneEvent.3`, `doc/CrtTimerHdlr.3`, `doc/CrtFileHdlr.3`, `doc/Notifier.3`, `doc/Thread.3`, and `doc/tclvars.n`. https://github.com/tcltk/tcl/tree/core-8-6-16/doc

**License:** Tcl/Tk License (BSD style)

**How ztk uses it:** the flags of `Tcl_DoOneEvent` and its result, the timer and file handlers, `Tcl_ThreadQueueEvent` with its positions, the mutex, condition, and thread data functions, and the `env` array.

## The tkinter documentation of Python

https://docs.python.org/3/library/tkinter.html

**License:** the documentation of Python has the PSF license and the Zero-Clause BSD license for its examples.

**How ztk uses it:** the behavior that a tkinter program expects, and the examples of the page as test programs. The authors do not read the C source of `_tkinter` or of CPython. `nm -D` of the `_tkinter` module of the system gave the names of the functions that it imports.

## The tkinter tests of CPython

`Lib/test/test_tkinter` and `Lib/test/test_ttk` of CPython 3.14.8. https://www.python.org/ftp/python/3.14.8/

**License:** PSF License

**How ztk uses it:** the tests run as a measure of compatibility. The repository has no copy of them.

## The behavior of the photo API

The alpha rule of a block (an alpha offset equal to the offset of a color means no alpha) came from a run of Pillow's `ImageTk` on the libtk8.6 of Arch Linux, which gives the alpha 255 for an RGB image.

## SaVi

SaVi 1.6.0, satellite constellation visualization. https://savi.sourceforge.io/ Copyright 2001-2023 Lloyd Wood, and 1997 the Geometry Center, University of Minnesota.

**License:** the SaVi license in its file `COPYRIGHT`: it can be copied and changed with its notices, with no warranty. Its images must credit SaVi.

**How ztk uses it:** a test subject. `tests/apps/savi/run.sh` builds the pinned release and runs it. The repository has no code of SaVi. The images of SaVi on the apps page credit SaVi, as its `COPYRIGHT` asks.
