#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Checks the live demos of the docs site in a headless browser. It builds
# the site with the web build, opens the landing page, and makes each
# card go live. Each card must run its script, and its first frame must
# equal its poster (the screenshot in docs/site/shots, scale 2): at most 2
# levels in each channel, in all but 0.5 % of the pixels. The demo card
# gets a click on Count and typed text, and the gallery card gets a click
# on a checkbutton.
# The size check then opens the playground with each example and the
# landing page at the window sizes 1440x900, 1280x800, and 390x844 and
# at devicePixelRatio 1, 2, and 3, in light and dark. Each canvas must
# show its window at the size of its poster (in CSS pixels, half the
# poster in pixels) or, for a card, with the aspect ratio of the poster,
# and its backing store must be the CSS size times devicePixelRatio. At
# ratio 2 the image of the playground must equal the poster.
# Use: tests/site.sh      (after: zig build wasm)
# Exit status: 0 pass, 1 fail, 77 when a tool or the build is missing.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
browser=""
for b in chromium chromium-browser google-chrome; do
    command -v "$b" >/dev/null 2>&1 && { browser="$b"; break; }
done
[ -n "$browser" ] || { echo "SKIP: no headless browser (chromium) on the path"; exit 77; }
[ -f "$root/zig-out/web/ztk.wasm" ] || { echo "SKIP: build the web files first: zig build wasm"; exit 77; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node is not on the path (tests/browser.mjs needs it)"; exit 77; }
py="${PYTHON:-python3}"
"$py" -c 'import PIL, markdown_it' 2>/dev/null || { echo "SKIP: python needs PIL and markdown-it-py (PYTHON=...)"; exit 77; }
work="$(mktemp -d)"
"$py" "$root/tools/build-docs.py" "$work/site" --live "$root/zig-out/web" >/dev/null || { echo "FAIL: the site build"; exit 1; }
port=$("$py" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
"$py" -m http.server "$port" --bind 127.0.0.1 --directory "$work/site" >/dev/null 2>&1 &
server=$!
trap 'kill $server 2>/dev/null; rm -rf "$work"' EXIT
sleep 1
for scheme in light dark; do
    flag=""
    [ "$scheme" = dark ] && flag="--force-dark-mode --blink-settings=preferredColorScheme=0"
    # $flag has two flags or none.
    # shellcheck disable=SC2086
    ZTK_BROWSER_VIEWPORT=1400x3000x1 ZTK_BROWSER_TIMEOUT_MS=170000 timeout 180 node "$root/tests/browser.mjs" "$browser" "$work/profile-$scheme" \
        "http://127.0.0.1:$port/index.html?livetest&livescale=2" --use-angle=swiftshader --enable-unsafe-swiftshader $flag \
        > "$work/$scheme.json"
    "$py" - "$work/$scheme.json" "$root/docs/site/shots" "$scheme" <<'PY' || exit 1
import json, sys, base64, io
from PIL import Image
r = json.load(open(sys.argv[1]))
shots, scheme = sys.argv[2], sys.argv[3]
fail = 0
live = r.get("live", [])
if not live:
    print(f"FAIL ({scheme}): the page gave no result"); sys.exit(1)
for item in live:
    name, state = item.split(":")
    if state != "1":
        print(f"FAIL ({scheme}): the card {name} did not go live ({state})"); fail = 1; continue
    web = Image.open(io.BytesIO(base64.b64decode(r["png"][name].split(",", 1)[1]))).convert("RGB")
    ref = Image.open(f"{shots}/{name}-{scheme}.png").convert("RGB")
    if web.size != ref.size:
        print(f"FAIL ({scheme}): {name}: the size {web.size} is not the poster size {ref.size}"); fail = 1; continue
    a, b = web.load(), ref.load()
    bad = worst = 0
    for y in range(web.size[1]):
        for x in range(web.size[0]):
            d = max(abs(p - q) for p, q in zip(a[x, y], b[x, y]))
            worst = max(worst, d)
            bad += d > 2
    share = bad / (web.size[0] * web.size[1])
    ok = share <= 0.005
    fail |= not ok
    print(("ok" if ok else "FAIL") + f" ({scheme}): {name} is live and equals its poster: {share*100:.3f} % of the pixels differ by more than 2 levels, worst {worst}")
c = r.get("checks", {})
for key, want in (("count", "1"), ("name", None), ("notify", "1")):
    got = c.get(key)
    ok = got is not None and (want is None and got.endswith("Ada") or got == want)
    fail |= not ok
    print(("ok" if ok else "FAIL") + f" ({scheme}): the live demo answers input: {key} = {got!r}")
sys.exit(fail)
PY
done
# The size check.
cp "$root/tests/aspect.html" "$work/site/aspect.html"
fail=0
for scheme in light dark; do
    flag=""
    [ "$scheme" = dark ] && flag="--force-dark-mode --blink-settings=preferredColorScheme=0"
    for win in 1440,900 1280,800 390,844; do
        for dpr in 1 2 3; do
            # The flags stay unquoted on purpose: $flag has two flags or none.
            # shellcheck disable=SC2086
            ZTK_BROWSER_VIEWPORT="$(echo "$win" | tr , x)x$dpr" ZTK_BROWSER_TIMEOUT_MS=290000 timeout 300 node "$root/tests/browser.mjs" "$browser" "$work/profile-$scheme-$win-$dpr" "http://127.0.0.1:$port/aspect.html" \
                --use-angle=swiftshader --enable-unsafe-swiftshader --window-size="$win" $flag \
                > "$work/size.json"
            "$py" - "$work/size.json" "$root/docs/site/shots" "$scheme" "$win" "$dpr" <<'PY' || fail=1
import json, sys, base64, io
from PIL import Image
r = json.load(open(sys.argv[1]))
shots, scheme, win, dpr = sys.argv[2], sys.argv[3], sys.argv[4], float(sys.argv[5])
tag = f"({scheme}, {win.replace(',', 'x')}, ratio {dpr:g})"
bad = []
def near(a, b, tol):
    return abs(a - b) <= tol
def compare(png, poster):
    web = Image.open(io.BytesIO(base64.b64decode(png.split(",", 1)[1]))).convert("RGB")
    ref = Image.open(poster).convert("RGB")
    if web.size != ref.size:
        return 1.0
    a, b = web.load(), ref.load()
    n = sum(max(abs(p - q) for p, q in zip(a[x, y], b[x, y])) > 2 for y in range(web.size[1]) for x in range(web.size[0]))
    return n / (web.size[0] * web.size[1])
play = r.get("play") or {}
if not play:
    bad.append("the page gave no result")
for name, p in play.items():
    if not p:
        bad.append(f"play {name}: no result"); continue
    pw, ph = Image.open(f"{shots}/{name}-{scheme}.png").size
    cw, ch = p["css"]
    sw, sh = p["store"]
    if not (near(cw, pw / 2, 1) and near(ch, ph / 2, 1)):
        bad.append(f"play {name}: CSS size {cw:g}x{ch:g}, poster {pw // 2}x{ph // 2}")
    if not (near(sw, cw * dpr, 1.5) and near(sh, ch * dpr, 1.5)):
        bad.append(f"play {name}: backing store {sw}x{sh} for CSS {cw:g}x{ch:g} at ratio {dpr:g}")
    if dpr == 2 and not bad:
        share = compare(p["png"], f"{shots}/{name}-{scheme}.png")
        if share > 0.005:
            bad.append(f"play {name}: {share * 100:.2f} % of the pixels differ from the poster")
cards = (r.get("cards") or {}).get("geom") or {}
if not cards:
    bad.append("the landing page gave no card")
for name, g in cards.items():
    pw, ph = g["poster"]
    cw, ch = g["css"]
    sw, sh = g["store"]
    if cw <= 0 or ch <= 0 or not near(cw / ch, pw / ph, 0.01 * pw / ph):
        bad.append(f"card {name}: CSS size {cw:g}x{ch:g} has another aspect ratio than the poster {pw}x{ph}")
    if cw > int(win.split(",")[0]):
        bad.append(f"card {name}: CSS width {cw:g} is wider than the page")
    if not (near(sw, cw * dpr, 1.5) and near(sh, ch * dpr, 1.5)):
        bad.append(f"card {name}: backing store {sw}x{sh} for CSS {cw:g}x{ch:g} at ratio {dpr:g}")
for b in bad:
    print(f"FAIL {tag}: {b}")
if not bad:
    print(f"ok {tag}: {len(play)} playground windows and {len(cards)} cards have the size and the aspect ratio of their posters")
sys.exit(1 if bad else 0)
PY
        done
    done
done
exit "$fail"
