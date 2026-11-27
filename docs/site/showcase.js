// SPDX-License-Identifier: BSD-2-Clause
// The showcases of a page (`<!-- showcase: WxH; narrow: WxH -->` in the
// Markdown): a ztk app in the page itself, with no example card and no
// toolbar. The app has a fixed logical size, and its canvas fills the
// width of the stage, so ztk.js renders it sharp at that scale. The stage
// is as wide as the window, less a margin, and its height follows its width, so nothing moves while the
// app animates. Below 640 CSS pixels the app gets its narrow size and
// the variable ::ztk_narrow, for a layout that fits a phone. The app
// starts when the stage comes near the view.

const base = new URL("../play/", import.meta.url);
const load = () => (globalThis.ztkDocsModule ??= import(new URL("ztk.js", base).href)
  .then(async (m) => ({ m, module: await m.compileModule(new URL("ztk.wasm", base)) })));

// The width of a stage: the window less 24 pixels at each side, at most
// 1,600 pixels, centered in the window. It goes over the sidebar while
// it is in view. On a phone it is the width of the text column.
function fit(fig) {
  fig.style.width = "";
  fig.style.marginLeft = "";
  const cw = document.documentElement.clientWidth;
  if (cw < 640) return;
  const col = fig.getBoundingClientRect();
  const width = Math.max(col.width, Math.min(1600, cw - 48));
  fig.style.width = `${width}px`;
  fig.style.marginLeft = `${(cw - width) / 2 - col.left}px`;
}

const narrow = () => matchMedia("(max-width: 639px)").matches;

async function start(fig) {
  const stage = fig.querySelector(".sc-stage");
  const code = fig.querySelector("pre code").textContent;
  const small = narrow();
  const [w, h] = (small ? fig.dataset.narrow : fig.dataset.size).split("x").map(Number);
  fig.classList.toggle("sc-narrow", small);
  const canvas = document.createElement("canvas");
  canvas.setAttribute("aria-label", "An interactive piece, running live");
  canvas.style.cssText = "display:block;width:100%;height:100%;touch-action:none";
  try {
    const { m, module } = await load();
    // The canvas is in the page before the start, so that ztk.js reads
    // its CSS size for the scale.
    const poster = stage.querySelector(".sc-poster");
    stage.append(canvas);
    poster.hidden = true;
    await m.mount(canvas, { module, size: [w, h], script: `set ::ztk_narrow ${small ? 1 : 0}\n${code}` });
    poster.remove();
    fig.classList.add("sc-live");
  } catch (e) {
    canvas.remove();
    const poster = stage.querySelector(".sc-poster");
    poster.hidden = false;
    poster.textContent = `The piece did not start: ${e.message ?? e}`;
  }
}

// A build stage (assets/stage.js) is a showcase too: it gets the same
// width. site.css gives it a larger handheld from 1,100 pixels.
for (const stage of document.querySelectorAll(".stage")) {
  fit(stage);
  addEventListener("resize", () => fit(stage));
}

for (const fig of document.querySelectorAll("figure.showcase")) {
  fit(fig);
  addEventListener("resize", () => fit(fig));
  const seen = new IntersectionObserver((entries) => {
    if (!entries.some((e) => e.isIntersecting)) return;
    seen.disconnect();
    start(fig);
  }, { rootMargin: "200px" });
  seen.observe(fig);
}
