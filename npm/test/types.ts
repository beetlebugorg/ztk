// Checks the types of the package with tsc. run.mjs puts the name of
// the package in place of the name below.
import * as ztk from "{{name}}";
import type { App, EvalResult, MountOptions } from "{{name}}";

const options: MountOptions = { script: "button .b -text Hi; pack .b", theme: "dark", size: "fill", renderer: "auto" };
const el = document.createElement("div");
const app: App = await ztk.mount(el, options);
const r: EvalResult = app.eval("winfo children .");
app.resize(400, 300);
app.setTheme("light");
const name: "webgl2" | "cpu" = app.renderer;
app.destroy();
const fixed: App = await ztk.mount(el, { size: [320, 200], files: { "a.css": "" }, module: await ztk.compileModule(ztk.wasmURL()) });
const low: App = await ztk.start(document.createElement("canvas"), { dark: true, width: 100, height: 100 });
export { r, name, fixed, low };
