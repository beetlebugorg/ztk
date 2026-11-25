// The browser test of the package. run.mjs puts the name of the
// package, or a URL for the no-build test, in place of the name below.
import * as ztk from "{{import}}";

const script = `
button .b -text Hello -command {set clicked 1}
label .l -text World
pack .b .l -padx 8 -pady 8
`;

async function main() {
  const res = {};
  // The README example: mount, eval, destroy.
  const app = await ztk.mount(document.getElementById("app"), { script, theme: "dark" });
  res.renderer = app.renderer;
  res.children = app.eval("winfo children .").result;
  res.canvas = app.canvas.width > 0 && app.canvas.height > 0;
  // HiDPI: the backing store has devicePixelRatio device pixels for each CSS pixel.
  res.dpr = devicePixelRatio;
  res.hidpi = Math.abs(app.canvas.width / parseFloat(app.canvas.style.width) - devicePixelRatio) < 0.01;
  res.roles = [...app.tree.children].map((e) => e.getAttribute("role")).join(" ");
  // A click through the DOM runs the command of the button.
  const b = app.tree.querySelector("[role=button]");
  const r = app.canvas.getBoundingClientRect();
  const opt = { clientX: r.left + b.offsetLeft + 4, clientY: r.top + b.offsetTop + 4, button: 0, pointerId: 1, bubbles: true };
  for (const type of ["pointermove", "pointerdown", "pointerup"]) app.canvas.dispatchEvent(new PointerEvent(type, opt));
  app.frame(performance.now() + 100);
  res.clicked = app.eval("info exists clicked").result;
  app.setTheme("light");
  app.destroy();
  res.destroyed = document.getElementById("app").children.length;

  // "fill": the window follows the size of the element.
  const fillEl = document.getElementById("fill");
  const fill = await ztk.mount(fillEl, { script: "frame .f; pack .f -fill both -expand 1", size: "fill", scale: 1 });
  fillEl.style.width = "360px";
  await new Promise((r) => setTimeout(r, 200));
  fill.frame(performance.now() + 200);
  res.fill = `${fill.eval("winfo width .").result}x${fill.eval("winfo height .").result}`;
  fill.destroy();

  // The CPU renderer draws the same window with a 2D context.
  const soft = await ztk.mount(document.getElementById("soft"), { script, renderer: "cpu", theme: "light", scale: 1 });
  soft.frame(performance.now() + 100);
  res.cpu = soft.renderer;
  const px = soft.canvas.getContext("2d").getImageData(0, 0, soft.canvas.width, soft.canvas.height).data;
  const colors = new Set();
  for (let i = 0; i < px.length; i += 4 * 7) colors.add((px[i] << 16) | (px[i + 1] << 8) | px[i + 2]);
  res.cpuColors = colors.size > 10;
  soft.destroy();

  // WebGPU is not in this version: mount rejects with a clear error.
  try {
    await ztk.mount(document.getElementById("soft"), { renderer: "webgpu" });
    res.webgpu = "mounted";
  } catch (e) {
    res.webgpu = /WebGPU/.test(e.message) ? "error" : e.message;
  }
  // A script error rejects, and the element is empty again.
  try {
    await ztk.mount(document.getElementById("soft"), { script: "nosuchcommand" });
    res.scriptError = "mounted";
  } catch (e) {
    res.scriptError = e.message;
  }
  res.left = document.getElementById("soft").children.length;
  return res;
}

main().then(
  (res) => (document.getElementById("result").textContent = JSON.stringify(res)),
  (e) => (document.getElementById("result").textContent = JSON.stringify({ error: String((e && e.stack) || e) })),
);
