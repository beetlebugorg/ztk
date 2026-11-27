/*
 * tk.h of libztk: the part of the C API of Tk 8.6 that libztk has.
 *
 * The declarations follow the manual pages of Tk 8.6 (Tk_Init.3,
 * Tk_MainWin.3, MainLoop.3, FindPhoto.3). This file has no text of the
 * tk.h of Tk. A type that the manual pages name with no fields, such as
 * Tk_Window, is an opaque pointer here.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
#ifndef _TK
#define _TK

#include <tcl.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TK_MAJOR_VERSION 8
#define TK_MINOR_VERSION 6
#define TK_RELEASE_LEVEL TCL_FINAL_RELEASE
#define TK_RELEASE_SERIAL 16
#define TK_VERSION "8.6"
#define TK_PATCH_LEVEL "8.6.16"

typedef struct Tk_Window_ *Tk_Window;
typedef struct Tk_PhotoHandle_ *Tk_PhotoHandle;

/* FindPhoto.3: a block of pixels. */
typedef struct Tk_PhotoImageBlock {
    unsigned char *pixelPtr;
    int width;
    int height;
    int pitch;
    int pixelSize;
    int offset[4];
} Tk_PhotoImageBlock;

/* The composite rules of Tk_PhotoPutBlock. */
#define TK_PHOTO_COMPOSITE_OVERLAY 0
#define TK_PHOTO_COMPOSITE_SET 1

int Tk_Init(Tcl_Interp *interp);
Tk_Window Tk_MainWindow(Tcl_Interp *interp);
int Tk_GetNumMainWindows(void);
void Tk_MainLoop(void);
Tk_Window Tk_CreateWindow(Tcl_Interp *interp, Tk_Window parent,
        const char *name, const char *screenName);

Tk_PhotoHandle Tk_FindPhoto(Tcl_Interp *interp, const char *imageName);
int Tk_PhotoPutBlock(Tcl_Interp *interp, Tk_PhotoHandle handle,
        Tk_PhotoImageBlock *blockPtr, int x, int y, int width, int height,
        int compRule);
int Tk_PhotoPutZoomedBlock(Tcl_Interp *interp, Tk_PhotoHandle handle,
        Tk_PhotoImageBlock *blockPtr, int x, int y, int width, int height,
        int zoomX, int zoomY, int subsampleX, int subsampleY, int compRule);
int Tk_PhotoGetImage(Tk_PhotoHandle handle, Tk_PhotoImageBlock *blockPtr);
void Tk_PhotoBlank(Tk_PhotoHandle handle);
int Tk_PhotoExpand(Tcl_Interp *interp, Tk_PhotoHandle handle,
        int width, int height);
void Tk_PhotoGetSize(Tk_PhotoHandle handle, int *widthPtr, int *heightPtr);
int Tk_PhotoSetSize(Tcl_Interp *interp, Tk_PhotoHandle handle,
        int width, int height);

#ifdef __cplusplus
}
#endif

#endif /* _TK */
