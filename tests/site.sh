#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Checks the live demos of the docs site in a headless browser. It builds
# the site with the web build, opens the landing page, and makes each
# card go live. Each card must run its script, and its first frame must
# equal its poster (the screenshot in docs/site/shots, scale 2): at most 2
# levels in each channel, in all but 0.5 % of the pixels. The demo card
# gets a click on Count and typed text, and the gallery card gets a click
# on a checkbutton.
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
    timeout 120 "$browser" --headless=new --no-sandbox --use-angle=swiftshader --enable-unsafe-swiftshader \
        --force-device-scale-factor=1 --window-size=1400,3000 --virtual-time-budget=15000 $flag \
        --user-data-dir="$work/profile-$scheme" --dump-dom "http://127.0.0.1:$port/index.html?livetest&livescale=2" 2>/dev/null \
        | "$py" -c 'import sys,re,html; m=re.search(r"<pre id=\"result\">(.*?)</pre>", sys.stdin.read(), re.S); print(html.unescape(m.group(1)) if m else "{}")' > "$work/$scheme.json"
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
