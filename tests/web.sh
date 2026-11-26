#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Runs ztk in a headless browser. It serves zig-out/web, runs the demo,
# clicks the Count button and types into the entry through DOM events,
# and checks the variables and the accessible roles. It then draws the
# gallery with each renderer of the page (WebGPU, WebGL 2, and the CPU
# renderer into a 2D canvas), and with WebGPU on a display-p3 canvas. It
# compares each image with the image of the native CPU renderer for the
# same script and size, and WebGPU with WebGL 2: at most 2 levels in
# each channel, in all but 0.5 % of the pixels. It checks the automatic
# choice with WebGPU on and off, and a frame after a forced loss of the
# WebGPU device. It reports the CPU time of a frame with WebGPU and with
# WebGL 2 for the gallery and a stress scene. The browser runs in real
# time through tests/browser.mjs, with SwiftShader for Vulkan (WebGPU)
# and for ANGLE (WebGL 2). A WebGPU canvas that stays blank makes the
# page go on with WebGL 2, and that image must equal the CPU renderer.
# Use: tests/web.sh      (after: zig build wasm && zig build)
# Exit status: 0 pass, 1 fail, 77 when a tool or the build is missing.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
browser=""
for b in chromium chromium-browser google-chrome; do
    command -v "$b" >/dev/null 2>&1 && { browser="$b"; break; }
done
[ -n "$browser" ] || { echo "SKIP: no headless browser (chromium) on the path"; exit 77; }
[ -f "$root/zig-out/web/ztk.wasm" ] || { echo "SKIP: build the web files first: zig build wasm"; exit 77; }
[ -x "$root/zig-out/bin/ztk" ] || { echo "SKIP: build ztk first: zig build"; exit 77; }
python3 -I -c 'import PIL' 2>/dev/null || { echo "SKIP: python3 has no PIL"; exit 77; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node is not on the path (tests/browser.mjs needs it)"; exit 77; }
work="$(mktemp -d)"
port=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 -I -m http.server "$port" --bind 127.0.0.1 --directory "$root/zig-out/web" >/dev/null 2>&1 &
server=$!
trap 'kill $server 2>/dev/null; rm -rf "$work"' EXIT
sleep 1
# page QUERY [WEBGPU]: the result of index.html?QUERY. WEBGPU=off runs
# the browser without WebGPU. WEBGPU=blank runs it with WebGPU on
# SwiftShader with no Vulkan for the compositor: the adapter and the
# device work, and the canvas stays blank.
gpu="--use-angle=vulkan --enable-features=Vulkan --use-vulkan=swiftshader"
page() {
    flags="$gpu"
    [ "${2:-on}" = on ] && flags="$gpu --enable-unsafe-webgpu"
    [ "${2:-on}" = blank ] && flags="--use-angle=swiftshader --enable-unsafe-swiftshader --enable-unsafe-webgpu"
    n=$((n + 1))
    # $flags has several flags on purpose.
    # shellcheck disable=SC2086
    ZTK_BROWSER_VIEWPORT=900x700x1 ZTK_BROWSER_TIMEOUT_MS=170000 timeout 180 node "$root/tests/browser.mjs" "$browser" "$work/profile-$n" \
        "http://127.0.0.1:$port/index.html?$1" $flags
}
n=0
fail=0
# The demo: the Count button and the entry, through DOM input.
size=400x200
out="$(page "example=demo&light&size=$size&test=list%20\$count%20\$name%20%5Bfocus%5D&click=0,0")"
echo "$out" > "$work/demo.json"
python3 -I - "$work/demo.json" <<'PY' || fail=1
import json, sys
r = json.load(open(sys.argv[1]))
ok = r.get("ok") and r.get("frames", 0) >= 1 and "button" in r.get("roles", "") and "textbox" in r.get("roles", "")
print(("ok" if ok else "FAIL") + ": the demo runs in the browser, frames %s, roles %s" % (r.get("frames"), r.get("roles")))

sys.exit(0 if ok else 1)
PY
# A click on the Count button and typed text, through DOM events.
# The program has no `source` by default (D19), so the script is one file.
cp "$root/examples/demo.tcl" "$work/where.tcl"
cat >>"$work/where.tcl" <<'TCL'
update
set b .count
puts "[expr {[winfo rootx $b] + 5}],[expr {[winfo rooty $b] + 5}] [expr {[winfo rootx .name] + 5}],[expr {[winfo rooty .name] + 5}]"
exit
TCL
cp "$root/examples/demo.tcl" "$root/examples/demo.css" "$work/"
where="$(cd "$work" && "$root/zig-out/bin/ztk" --headless where.tcl 2>/dev/null)"
click="${where% *}"
out="$(page "example=demo&light&size=$size&click=$click&test=set%20count")"
echo "$out" > "$work/click.json"
python3 -I - "$work/click.json" <<'PY' || fail=1
import json, sys
r = json.load(open(sys.argv[1]))
ok = r.get("check") == "1"
print(("ok" if ok else "FAIL") + ": a DOM click on Count runs its command (count = %r)" % r.get("check"))
sys.exit(0 if ok else 1)
PY
entry="${where#* }"
out="$(page "example=demo&light&size=$size&click=$entry&type=Ada&test=.name%20get")"
echo "$out" > "$work/type.json"
python3 -I - "$work/type.json" <<'PY' || fail=1
import json, sys
r = json.load(open(sys.argv[1]))
ok = r.get("check", "").endswith("Ada")
print(("ok" if ok else "FAIL") + ": typed text reaches the entry through the hidden input (%r)" % r.get("check"))
sys.exit(0 if ok else 1)
PY
# The scrollbar of the gallery: a DOM wheel event over its entry scrolls the
# entry, and the scrollbar follows through -xscrollcommand.
cp "$root/examples/gallery.tcl" "$root/examples/gallery.css" "$work/"
{ cat "$root/examples/gallery.tcl"; printf '\nwm geometry . 860x680\nupdate\nset e .cols.right.scroll.e\nputs "[expr {[winfo rootx $e] + 10}],[expr {[winfo rooty $e] + 5}]"\nexit\n'; } > "$work/gwhere.tcl"
gwhere="$(cd "$work" && "$root/zig-out/bin/ztk" --headless gwhere.tcl 2>/dev/null)"
out="$(page "example=gallery&light&size=860x680&wheel=$gwhere,200,0&test=list%20%5B.cols.right.scroll.e%20xview%5D%20%5B.cols.right.scroll.s%20get%5D")"
echo "$out" > "$work/wheel.json"
python3 -I - "$work/wheel.json" <<'PY' || fail=1
import json, sys
r = json.load(open(sys.argv[1]))
c = r.get("check", "").replace("{", "").replace("}", "").split()
ok = len(c) == 4 and float(c[0]) > 0.3 and c[0:2] == c[2:4]
print(("ok" if ok else "FAIL") + ": a DOM wheel event scrolls the entry and its scrollbar (%r)" % r.get("check"))
sys.exit(0 if ok else 1)
PY
# The spinbox of the gallery: a DOM click on its up button steps the value.
# The page gives the window its requested size, so the place is from that size.
{ cat "$root/examples/gallery.tcl"; printf '\nupdate\nset s .cols.right.input.body.n\nputs "[expr {[winfo rootx $s] + [winfo width $s] - 8}],[expr {[winfo rooty $s] + 5}]"\nexit\n'; } > "$work/swhere.tcl"
swhere="$(cd "$work" && "$root/zig-out/bin/ztk" --headless swhere.tcl 2>/dev/null)"
out="$(page "example=gallery&light&size=860x680&click=$swhere&test=.cols.right.input.body.n%20get")"
echo "$out" > "$work/spin.json"
python3 -I - "$work/spin.json" <<'PY' || fail=1
import json, sys
r = json.load(open(sys.argv[1]))
ok = r.get("check") == "2"
print(("ok" if ok else "FAIL") + ": a DOM click on the up button of the spinbox steps it (%r)" % r.get("check"))
sys.exit(0 if ok else 1)
PY
# The ttk card of the gallery: a DOM click on the radiobutton "Small" sets its variable.
{ cat "$root/examples/gallery.tcl"; printf '\nupdate\nset s .cols.right.ttk.body.s\nputs "[expr {[winfo rootx $s] + 8}],[expr {[winfo rooty $s] + [winfo height $s] / 2}]"\nexit\n'; } > "$work/twhere.tcl"
twhere="$(cd "$work" && "$root/zig-out/bin/ztk" --headless twhere.tcl 2>/dev/null)"
out="$(page "example=gallery&light&size=860x680&click=$twhere&test=set%20ttkopt(size)")"
echo "$out" > "$work/ttk.json"
python3 -I - "$work/ttk.json" <<'PY' || fail=1
import json, sys
r = json.load(open(sys.argv[1]))
ok = r.get("check") == "S"
print(("ok" if ok else "FAIL") + ": a DOM click on a ttk::radiobutton sets its variable (%r)" % r.get("check"))
sys.exit(0 if ok else 1)
PY
# The canvas of the gallery: a DOM drag moves the rectangle by its item bindings.
{ cat "$root/examples/gallery.tcl"; printf '\nwm geometry . 860x680\nupdate\nset c .cols.left.canvas.body.c\nputs "[expr {[winfo rootx $c] + 40}],[expr {[winfo rooty $c] + 30}],[expr {[winfo rootx $c] + 80}],[expr {[winfo rooty $c] + 50}]"\nexit\n'; } > "$work/cwhere.tcl"
cwhere="$(cd "$work" && "$root/zig-out/bin/ztk" --headless cwhere.tcl 2>/dev/null)"
out="$(page "example=gallery&light&size=860x680&drag=$cwhere&test=.cols.left.canvas.body.c%20coords%201")"
echo "$out" > "$work/drag.json"
python3 -I - "$work/drag.json" <<'PY' || fail=1
import json, sys
r = json.load(open(sys.argv[1]))
ok = r.get("check") == "48.0 30.0 128.0 86.0"
print(("ok" if ok else "FAIL") + ": a DOM drag moves a canvas item by its bindings (%r)" % r.get("check"))
sys.exit(0 if ok else 1)
PY
# The pixels: each renderer against the CPU renderer, for the gallery at the same size.
gsize=720x440
q="example=gallery&light&size=$gsize&test=wm%20geometry%20.%20$gsize"
page "$q&renderer=webgpu&lose" > "$work/webgpu.json"
page "$q" > "$work/auto-on.json"
page "$q&renderer=webgpu&colorspace=display-p3" > "$work/p3.json"
page "$q" off > "$work/webgl2.json"
page "$q" blank > "$work/fallback.json"
page "$q&renderer=cpu" > "$work/cpu-web.json"
# The stress scene for the frame time: 1 200 labels in a grid of 30
# columns over the demo, in a window of 720 by 440. About 200 of them show.
stress="wm%20geometry%20.%20720x440;frame%20.s;place%20.s%20-x%200%20-y%200%20-relwidth%201%20-relheight%201;for%20%7Bset%20i%200%7D%20%7B%24i%3C1200%7D%20%7Bincr%20i%7D%20%7Blabel%20.s.l%24i%20-text%20%22Item%20%24i%22;grid%20.s.l%24i%20-row%20%5Bexpr%20%7B%24i/30%7D%5D%20-column%20%5Bexpr%20%7B%24i%2530%7D%5D%7D"
page "example=demo&light&size=$gsize&test=$stress&renderer=webgpu" > "$work/stress-webgpu.json"
page "example=demo&light&size=$gsize&test=$stress" off > "$work/stress-webgl2.json"
{ cat "$root/examples/gallery.tcl"; printf '\nwm geometry . %s\n' "$gsize"; } > "$work/g.tcl"
cp "$root/examples/gallery.tcl" "$root/examples/gallery.css" "$work/"
(cd "$work" && ZTK_NO_ANIMATION=1 "$root/zig-out/bin/ztk" --headless --scale 1 --exit-after-frames 2 --screenshot "$work/cpu.png" g.tcl >/dev/null 2>&1)
python3 -I - "$work" <<'PY' || fail=1
import json, sys, base64, io, os
from PIL import Image
work = sys.argv[1]
fail = 0
def load(name):
    p = os.path.join(work, name)
    try:
        return json.load(open(p))
    except Exception:
        return {}
def image(png):
    return Image.open(io.BytesIO(base64.b64decode(png.split(",", 1)[1]))).convert("RGB")
def compare(a, b):
    if a.size != b.size:
        return None
    pa, pb = a.load(), b.load()
    bad = worst = 0
    for y in range(a.size[1]):
        for x in range(a.size[0]):
            d = max(abs(p - q) for p, q in zip(pa[x, y], pb[x, y]))
            worst = max(worst, d)
            bad += d > 2
    return bad / (a.size[0] * a.size[1]), worst
def check(label, a, b):
    global fail
    r = compare(a, b)
    if r is None:
        print(f"FAIL: {label}: the sizes differ: {a.size} and {b.size}"); fail = 1; return
    ok = r[0] <= 0.005
    fail |= not ok
    print(("ok" if ok else "FAIL") + f": {label}: {r[0] * 100:.3f} % of the pixels differ by more than 2 levels, worst {r[1]}")
cpu = Image.open(os.path.join(work, "cpu.png")).convert("RGB")
runs = {"webgpu": load("webgpu.json"), "webgl2": load("webgl2.json"), "cpu": load("cpu-web.json")}
for name, r in runs.items():
    if not r.get("png", "").startswith("data:image/png;base64,"):
        print(f"FAIL: the {name} page gave no canvas image"); fail = 1
webgpu_ok = runs["webgpu"].get("renderer") == "webgpu"
for name, want in (("webgpu", "webgpu"), ("webgl2", "webgl2"), ("cpu", "cpu")):
    got = runs[name].get("renderer")
    if got != want:
        print(f"FAIL: the page with {name} drew with {got}"); fail = 1
auto = load("auto-on.json").get("renderer")
ok = auto == "webgpu"
fail |= not ok
print(("ok" if ok else "FAIL") + f": with WebGPU on, the automatic choice is {auto}; with WebGPU off, it is {runs['webgl2'].get('renderer')}")
# A blank first frame of WebGPU: the automatic choice goes on with WebGL 2.
fb = load("fallback.json")
ok = fb.get("renderer") == "webgl2" and fb.get("png", "").startswith("data:")
fail |= not ok
print(("ok" if ok else "FAIL") + f": with a WebGPU canvas that stays blank, the page renders with {fb.get('renderer')}")
if ok: check("the fallback to WebGL 2 against the CPU renderer", image(fb["png"]), cpu)
imgs = {n: image(r["png"]) for n, r in runs.items() if r.get("png", "").startswith("data:")}
if "webgpu" in imgs: check("WebGPU against the CPU renderer", imgs["webgpu"], cpu)
if "webgl2" in imgs: check("WebGL 2 against the CPU renderer", imgs["webgl2"], cpu)
if "cpu" in imgs: check("the CPU renderer in a 2D canvas against the native CPU renderer", imgs["cpu"], cpu)
if "webgpu" in imgs and "webgl2" in imgs: check("WebGPU against WebGL 2", imgs["webgpu"], imgs["webgl2"])
# Display P3: the page gives P3 values with an ICC profile. They go back to sRGB for the compare.
p3 = load("p3.json").get("png", "")
if p3.startswith("data:"):
    from PIL import ImageCms
    im = Image.open(io.BytesIO(base64.b64decode(p3.split(",", 1)[1])))
    icc = im.info.get("icc_profile")
    if not icc:
        print("FAIL: the display-p3 canvas gave no color profile"); fail = 1
    else:
        srgb = ImageCms.profileToProfile(im.convert("RGB"), ImageCms.ImageCmsProfile(io.BytesIO(icc)), ImageCms.createProfile("sRGB"), renderingIntent=1)
        check("WebGPU on a display-p3 canvas, converted to sRGB, against the CPU renderer", srgb, cpu)
else:
    print("FAIL: the display-p3 page gave no canvas image"); fail = 1
lost = runs["webgpu"].get("lost", {})
if lost.get("restored") and lost.get("png", "").startswith("data:"):
    check("WebGPU after a device loss against the CPU renderer", image(lost["png"]), cpu)
else:
    print("FAIL: the WebGPU renderer did not draw again after a device loss"); fail = 1
# The CPU time of a frame: the work of ztk and the calls of the renderer.
# The gate of 8 ms at the 99th percentile is reported. It depends on the
# load of the machine, so only a median over 8 ms fails.
for scene, prefix in (("the gallery", ""), ("1 200 labels", "stress-")):
    for name in ("webgpu", "webgl2"):
        r = runs[name] if not prefix else load(prefix + name + ".json")
        p = r.get("perf")
        if not p:
            print(f"FAIL: no frame time for {scene} with {name}"); fail = 1; continue
        # WebGPU runs here on SwiftShader, which renders on the same CPU
        # cores as the module, so its times are reported and do not fail.
        ok = p["median"] < 8 or name == "webgpu"
        fail |= not ok
        gate = "gate met" if p["p99"] < 8 else "gate of 8 ms at the 99th percentile not met"
        status = "ok" if p["median"] < 8 else ("report" if ok else "FAIL")
        print(status + f" ({gate}): CPU time of a frame for {scene} with {name}, 120 frames of pointer motion: median {p['median']:.2f} ms, 99th percentile {p['p99']:.2f} ms")
        print(f"     the module alone in the same frames: median {p['moduleMedian']:.2f} ms, 99th percentile {p['moduleP99']:.2f} ms")
        print(f"     the draw alone, 300 draws of the last scene: median {p['drawMedian']:.2f} ms, 99th percentile {p['drawP99']:.2f} ms")
sys.exit(fail)
PY
# The frame time of the module in V8 (node), with real time: the gallery and 200 frames of pointer motion.
node - "$root/zig-out/web/ztk.wasm" "$root/examples/gallery.tcl" "$root/examples/gallery.css" <<'JS' || fail=1
const fs = require("fs");
const [wasmPath, tclPath, cssPath] = process.argv.slice(2);
let ex;
const dec = new TextDecoder(), enc = new TextEncoder();
const imports = { env: { ztk_now_ms: () => performance.now(), ztk_print: () => {} } };
WebAssembly.instantiate(fs.readFileSync(wasmPath), imports).then(({ instance }) => {
  ex = instance.exports;
  const put = (s) => { const b = enc.encode(s); const p = ex.ztk_alloc(Math.max(b.length, 1)); new Uint8Array(ex.memory.buffer, p, b.length).set(b); return [p, b.length]; };
  ex.ztk_init(720, 440, 2, false, false);
  ex.ztk_add_file(...put("gallery.css"), ...put(fs.readFileSync(cssPath, "utf8")));
  if (ex.ztk_eval(...put(fs.readFileSync(tclPath, "utf8"))) !== 0) { console.log("FAIL: the gallery gave an error"); process.exit(1); }
  let t = 0;
  for (let i = 0; i < 20; i++) ex.ztk_frame(t += 16.7);
  const times = [];
  for (let i = 0; i < 200; i++) {
    ex.ztk_pointer((i * 37) % 720, (i * 23) % 440);
    const t0 = performance.now();
    ex.ztk_frame(t += 16.7);
    times.push(performance.now() - t0);
  }
  times.sort((a, b) => a - b);
  const p99 = times[Math.floor(times.length * 0.99)];
  // The gate of 8 ms at the 99th percentile is reported. It depends on the load of the machine, so only a median over 8 ms fails.
  const ok = times[100] < 8;
  console.log((ok ? "ok" : "FAIL") + (p99 < 8 ? " (gate met)" : " (gate of 8 ms at the 99th percentile not met)") + `: frame time of the module in V8 for the gallery at scale 2, 200 frames of pointer motion: median ${times[100].toFixed(2)} ms, 99th percentile ${p99.toFixed(2)} ms`);
  process.exit(ok ? 0 : 1);
});
JS
# A posted menu opens in a popup canvas above the page. A click on the
# middle of the popup invokes its one entry, and the popup goes away.
pre='menu .pm -tearoff 0; .pm add command -label Hit -command {set ::hit 1}; set ::hit 0; .pm post 20 20'
q="$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$pre")"
out="$(page "example=demo&light&size=$size&pre=$q&popclick&test=set%20hit")"
echo "$out" > "$work/popup.json"
python3 -I - "$work/popup.json" <<'PY' || fail=1
import json, sys
r = json.load(open(sys.argv[1]))
p = r.get("popup") or {}
ok = r.get("check") == "1" and p.get("alpha", [255, 0])[0] == 0 and p.get("alpha", [0, 0])[1] == 255 and p.get("after") == 0
print(("ok" if ok else "FAIL") + ": a menu opens in a popup canvas with a clear edge, and a click there invokes its entry (%r, %r)" % (r.get("check"), p))
sys.exit(0 if ok else 1)
PY
exit "$fail"
