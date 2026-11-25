// Types of ztk.js: Tk widgets in a browser, drawn by ztk.wasm.
// SPDX-License-Identifier: BSD-2-Clause

/** A renderer. "auto" selects the first one that the browser has, in the order of {@link renderers}. */
export type Renderer = "auto" | "webgpu" | "webgl2" | "cpu";

/** The color scheme of the app. "auto" follows `prefers-color-scheme` of the page. */
export type Theme = "auto" | "light" | "dark";

/**
 * The size of the window of the script, in logical pixels.
 *
 * - "auto": the size of the element at the start. Then the window gets
 *   the size of its widgets, as a Tk toplevel does.
 * - "fill": the window follows the size of the element. Give the element a size.
 * - `[width, height]` or `{ width, height }`: a fixed logical size. The
 *   canvas shows the window at the CSS size that the page gives it.
 */
export type Size = "auto" | "fill" | [number, number] | { width: number; height: number };

/** The result of one `eval`. */
export interface EvalResult {
  /** True when the script ended with no error. */
  ok: boolean;
  /** The value of the script, or the error message when `ok` is false. */
  result: string;
}

/** The options of {@link mount}. */
export interface MountOptions {
  /** Tcl text with Tk commands. It runs after `files` are added. */
  script?: string;
  /** Files by name for `ztk::style load`, for example `{ "app.css": text }`. */
  files?: Record<string, string>;
  /** The color scheme. The default is "auto". */
  theme?: Theme;
  /** The size of the window. The default is "auto". */
  size?: Size;
  /** The renderer. The default is "auto": WebGPU, else WebGL 2, else the CPU renderer. */
  renderer?: Renderer;
  /** The device pixels in one logical pixel. The default is `devicePixelRatio`. */
  scale?: number;
  /** A module from {@link compileModule}, so that many apps compile `ztk.wasm` one time. */
  module?: WebAssembly.Module;
  /** The URL of `ztk.wasm`. The default is {@link wasmURL}. */
  wasm?: string | URL;
  /** Gets the text of `puts` and the error messages. The default is `console.log`. */
  log?: (text: string) => void;
}

/** The options of {@link start}. */
export interface StartOptions {
  module?: WebAssembly.Module;
  wasm?: string | URL;
  renderer?: Renderer;
  /** True for dark, false for light, undefined for the color scheme of the page. */
  dark?: boolean;
  /** A fixed logical width. Give it with `height`. */
  width?: number;
  /** A fixed logical height. Give it with `width`. */
  height?: number;
  scale?: number;
  log?: (text: string) => void;
}

/** A running ztk app on a canvas. */
export interface App {
  /** Runs Tcl text in the interpreter of the app. The next frame shows the change. */
  eval(script: string): EvalResult;
  /** Adds a file by name for `ztk::style load`. */
  addFile(name: string, text: string): boolean;
  /** Gives the window of the script a new logical size. */
  resize(width: number, height: number): void;
  /** Sets the color scheme. */
  setTheme(theme: Theme): void;
  /**
   * Stops the frame loop, removes the event listeners and the elements
   * that the app added, and frees the renderer. Drop the object after this call.
   */
  destroy(): void;
  /** Runs the events and draws one frame now, at the time `ms`. Returns the count of quads, or -1 when no frame was drawn. */
  frame(ms: number): number;
  /** The canvas of the app. */
  readonly canvas: HTMLCanvasElement;
  /** The renderer in use. */
  readonly renderer: "webgl2" | "cpu";
  /** The hidden elements with ARIA roles that follow the widgets. */
  readonly tree: HTMLDivElement;
  /** Aborts when the app is destroyed. */
  readonly signal: AbortSignal;
  /** The exports of the WebAssembly instance, for tests and tools. */
  readonly exports: WebAssembly.Exports;
}

/**
 * Mounts a ztk app on an element.
 * @param el A canvas, or an element that gets a new canvas.
 * @returns The app, after the script ran and the first frame is drawn.
 * A script error destroys the app and rejects with the error message,
 * and the error has the field `result`.
 *
 * @example
 * const app = await mount(document.getElementById("app"), {
 *   script: "button .b -text Hello; pack .b",
 * });
 * app.eval(".b configure -text Bye");
 * app.destroy();
 */
export function mount(el: HTMLElement, options?: MountOptions): Promise<App>;

/** Starts ztk.wasm on a canvas. {@link mount} is the API for a page. */
export function start(canvas: HTMLCanvasElement, options?: StartOptions): Promise<App>;

/** Compiles `ztk.wasm` one time for each URL. The default is {@link wasmURL}. */
export function compileModule(url?: string | URL): Promise<WebAssembly.Module>;

/** The URL of the `ztk.wasm` file next to `ztk.js`. */
export function wasmURL(): URL;

/** The renderers of this version, in the order of "auto". */
export const renderers: readonly ("webgl2" | "cpu")[];
