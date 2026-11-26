// SPDX-License-Identifier: BSD-2-Clause
// "Download your app" (docs/dev/interactive-docs.md): the page makes a
// native binary of a script, with no server. The site serves a runtime
// binary for each target in runtimes/, and runtimes/manifest.json lists
// them: {"targets": {"x86_64-linux": {"file": "...", "size": N,
// "sha256": "..."}, ...}}. A runtime has a slot (the plan of ztcl in
// docs/dev/static-build.md of the ztcl repository). The build core of
// ztcl patches the slot, adds the script as the payload, and for macOS
// writes an ad hoc signature. The page loads that core from
// ztcl-build.js, which exports build({ runtime, files, main, target })
// and gives the bytes of the output.
//
// available() is the feature check: the panel shows only when the
// manifest and the build core exist. `?download` in the URL shows the
// panel without them, for a test, with the buttons off.

export const TARGETS = [
  { id: "x86_64-linux", os: "Linux", arch: "x86-64" },
  { id: "aarch64-linux", os: "Linux", arch: "arm64" },
  { id: "x86_64-macos", os: "macOS", arch: "Intel" },
  { id: "aarch64-macos", os: "macOS", arch: "Apple silicon" },
  { id: "x86_64-windows", os: "Windows", arch: "x86-64" },
  { id: "aarch64-windows", os: "Windows", arch: "arm64" },
];

// The target of the reader's computer. A browser that gives no
// architecture gets x86-64, except a Mac, which gets arm64.
export async function detect() {
  let os = "", arch = "";
  try {
    const d = await navigator.userAgentData?.getHighEntropyValues(["platform", "architecture", "bitness"]);
    if (d) {
      os = d.platform || "";
      arch = d.architecture === "arm" ? "aarch64" : d.architecture === "x86" ? "x86_64" : "";
    }
  } catch {}
  const ua = navigator.userAgent;
  if (!os) os = /Windows/.test(ua) ? "Windows" : /Mac/.test(ua) ? "macOS" : "Linux";
  const kind = /win/i.test(os) ? "windows" : /mac/i.test(os) ? "macos" : "linux";
  if (!arch) arch = kind === "macos" || /aarch64|arm64/i.test(ua) ? "aarch64" : "x86_64";
  return `${arch}-${kind}`;
}

const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");

export async function available(base) {
  try {
    const r = await fetch(new URL("runtimes/manifest.json", base));
    if (!r.ok) return null;
    const manifest = await r.json();
    const core = await import(new URL("ztcl-build.js", base).href);
    if (typeof core.build !== "function") return null;
    return { manifest, core };
  } catch {
    return null;
  }
}

// The bytes of the app for one target.
export async function buildApp({ base, manifest, core, target, script, name }) {
  const entry = manifest.targets?.[target];
  if (!entry) throw new Error(`no runtime for ${target} on this site`);
  const r = await fetch(new URL(`runtimes/${entry.file}`, base));
  if (!r.ok) throw new Error(`the runtime for ${target} did not load (${r.status})`);
  const runtime = new Uint8Array(await r.arrayBuffer());
  const sum = hex(await crypto.subtle.digest("SHA-256", runtime));
  if (entry.sha256 && sum !== entry.sha256) throw new Error(`the runtime for ${target} has the wrong SHA-256 hash`);
  const main = `${name}.tcl`;
  return core.build({ runtime, files: { [main]: script }, main, target });
}

// The panel: a button for each target, the reader's target first.
export async function panel(el, { base, script, name = "app" }) {
  const params = new URLSearchParams(location.search);
  const ready = await available(base);
  if (!ready && !params.has("download")) return false;
  const mine = await detect();
  el.className = "download";
  el.replaceChildren();
  const h = document.createElement("strong");
  h.textContent = "Download your app";
  const note = document.createElement("p");
  note.textContent = ready
    ? "A native binary of this script, made in your browser. On Linux and macOS, run chmod +x on the file before the first start."
    : "The native build is not on this site yet. The buttons start to work when it is.";
  const row = document.createElement("div");
  const order = [...TARGETS].sort((a, b) => (b.id === mine) - (a.id === mine));
  for (const t of order) {
    const b = document.createElement("button");
    b.type = "button";
    b.dataset.target = t.id;
    b.textContent = `${t.os} ${t.arch}`;
    if (t.id === mine) b.className = "mine";
    b.disabled = !ready || !ready.manifest.targets?.[t.id];
    b.addEventListener("click", async () => {
      b.disabled = true;
      note.textContent = `Building for ${t.os} ${t.arch}...`;
      try {
        const bytes = await buildApp({ base, ...ready, target: t.id, script: script(), name });
        const file = t.id.endsWith("windows") ? `${name}.exe` : name;
        const a = document.createElement("a");
        a.href = URL.createObjectURL(new Blob([bytes], { type: "application/octet-stream" }));
        a.download = file;
        a.click();
        setTimeout(() => URL.revokeObjectURL(a.href), 10000);
        note.textContent = `${file}: ${bytes.length.toLocaleString("en-US")} bytes.`;
      } catch (e) {
        note.textContent = `The build failed: ${e.message}`;
      }
      b.disabled = false;
    });
    row.appendChild(b);
  }
  el.append(h, row, note);
  el.hidden = false;
  return true;
}
