#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Checks the live snippets of the docs pages (docs/site/live.js) in a
# headless browser. It builds the site with the web build and opens each
# page that has a live snippet, in light and dark. Each snippet must run.
# The first frame of a snippet with a plain shot (`shot: update`) must
# equal the shot: at most 2 levels in each channel, in all but 0.5 % of
# the pixels. The first snippet of each page then gets edits: a variable
# that the reader changed keeps its value when the code keeps its first
# value, a new first value in the code wins, and an error keeps the last
# good window.
# Use: tests/docs-live.sh [page folder ...]     (after: zig build wasm)
# The default is each page with a live snippet, for example widgets/menus.
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
pages="$*"
[ -n "$pages" ] || pages="$(cd "$work/site" && grep -l 'class="live-demo"' -r --include=index.html . | sed 's|^\./||; s|/index.html$||' | sort)"
fail=0
for page in $pages; do
    for scheme in light dark; do
        flag=""
        [ "$scheme" = dark ] && flag="--force-dark-mode --blink-settings=preferredColorScheme=0"
        # $flag has two flags or none.
        # shellcheck disable=SC2086
        ZTK_BROWSER_VIEWPORT=1400x3000x1 ZTK_BROWSER_TIMEOUT_MS=110000 timeout 120 node "$root/tests/browser.mjs" "$browser" "$work/profile-$scheme" \
            "http://127.0.0.1:$port/$page/?livetest&livescale=2" --use-angle=swiftshader --enable-unsafe-swiftshader $flag \
            > "$work/r.json"
        "$py" - "$work/r.json" "$root/docs/site/shots" "$scheme" "$page" "$work/site/$page/index.html" <<'PY' || fail=1
import json, sys, base64, io, re
from PIL import Image
r = json.load(open(sys.argv[1]))
shots, scheme, page = sys.argv[2], sys.argv[3], sys.argv[4]
still = set(re.findall(r'data-name="([^"]+)" data-still="1"', open(sys.argv[5]).read()))
tag = f"({page}, {scheme})"
fail = 0
live = r.get("live", [])
if not live:
    print(f"FAIL {tag}: the page gave no result"); sys.exit(1)
for item in live:
    name, state = item.rsplit(":", 1)
    if state != "1":
        print(f"FAIL {tag}: the snippet {name} did not run ({state})"); fail = 1; continue
    if name not in still:
        print(f"ok {tag}: {name} runs"); continue
    web = Image.open(io.BytesIO(base64.b64decode(r["png"][name].split(",", 1)[1]))).convert("RGB")
    ref = Image.open(f"{shots}/widget-{name}-{scheme}.png").convert("RGB")
    if web.size != ref.size:
        print(f"FAIL {tag}: {name}: the size {web.size} is not the shot size {ref.size}"); fail = 1; continue
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
    print(("ok" if ok else "FAIL") + f" {tag}: {name} runs and equals its shot: {share*100:.3f} % of the pixels differ by more than 2 levels, worst {worst}")
c = r.get("checks", {})
for key, want in (("kept", "2"), ("added", "5"), ("changed", "3"), ("error", "invalid command name \"no_such_command\""), ("stayed", "5")):
    got = c.get(key)
    ok = got == want
    fail |= not ok
    print(("ok" if ok else "FAIL") + f" {tag}: edit check {key} = {got!r}")
sys.exit(fail)
PY
    done
done
exit $fail
