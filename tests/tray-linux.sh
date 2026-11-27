#!/bin/sh
# Shows a tray icon (StatusNotifierItem) on a private session bus, with
# ztk on a private headless sway. busctl reads the properties of the
# icon and calls Activate, SecondaryActivate, and ContextMenu, and
# dbus-monitor sees the call to the watcher.
# Use: tests/tray-linux.sh [ztk program]
# Exit status: 0 passed, 1 failed, 77 when a tool is missing.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
ztk="${1:-$root/zig-out/bin/ztk}"
for tool in sway dbus-run-session busctl dbus-monitor; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool is not on the path"; exit 77; }
done
[ -x "$ztk" ] || { echo "SKIP: build ztk first: zig build"; exit 77; }
# A private bus with no services to start: the portals and the other
# services of the desktop stay off.
if [ -z "${ZTK_TRAY_INNER:-}" ]; then
    rt="$(mktemp -d /tmp/ztkrt.XXXX)"
    chmod 700 "$rt"
    mkdir "$rt/services"
    cat >"$rt/bus.conf" <<CONF
<busconfig>
  <type>session</type>
  <listen>unix:path=$rt/bus</listen>
  <auth>EXTERNAL</auth>
  <servicedir>$rt/services</servicedir>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
CONF
    env -u WAYLAND_DISPLAY -u DISPLAY ZTK_TRAY_INNER="$rt" \
        dbus-run-session --config-file="$rt/bus.conf" -- sh "$0" "$ztk"
    status=$?
    rm -rf "$rt"
    exit "$status"
fi
rt="$ZTK_TRAY_INNER"
printf 'output HEADLESS-1 resolution 800x600\n' >"$rt/sway.conf"
env XDG_RUNTIME_DIR="$rt" WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
    sway -c "$rt/sway.conf" >"$rt/sway.log" 2>&1 &
pid=$!
mpid=""
zpid=""
cleanup() {
    [ -n "$zpid" ] && kill "$zpid" 2>/dev/null
    [ -n "$mpid" ] && kill "$mpid" 2>/dev/null
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
}
trap cleanup EXIT
n=0
while [ ! -S "$rt/wayland-1" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
[ -S "$rt/wayland-1" ] || { echo "FAIL: the compositor has no socket"; exit 1; }
export XDG_RUNTIME_DIR="$rt" WAYLAND_DISPLAY=wayland-1
dbus-monitor --session "interface='org.kde.StatusNotifierWatcher'" >"$rt/mon" 2>&1 &
mpid=$!
sleep 0.3
"$ztk" "$root/tests/scripts/tray.tcl" >"$rt/out" 2>"$rt/err" &
zpid=$!
name="org.kde.StatusNotifierItem-$zpid-1"
item=/StatusNotifierItem
iface=org.kde.StatusNotifierItem
prop() { busctl --user get-property "$name" "$item" "$iface" "$1" 2>&1; }
# Wait for the change of the tooltip.
n=0
while [ "$(prop Title)" != 's "second tip"' ] && [ "$n" -lt 30 ]; do sleep 0.1; n=$((n + 1)); done
{
    echo "Title $(prop Title)"
    echo "Status $(prop Status)"
    echo "ToolTip $(prop ToolTip)"
    echo "IconPixmap $(prop IconPixmap | cut -c1-40)"
    echo "Menu $(prop Menu)"
} >"$rt/props"
for m in Activate SecondaryActivate ContextMenu; do
    busctl --user call "$name" "$item" "$iface" "$m" ii 10 20 >/dev/null 2>&1 || echo "FAIL: the call of $m"
done
wait "$zpid" 2>/dev/null
zpid=""
cat "$rt/props" "$rt/out"
fail=0
check() { grep -q "$2" "$rt/$1" || { echo "FAIL: $1 has no line with: $2"; fail=1; }; }
check out '^tray created .* 1$'
check out '^tray click$'
check out '^tray double$'
check out '^tray menu$'
check props '^Title s "second tip"$'
check props '^Status s "Active"$'
check props '^ToolTip (sa(iiay)ss) "" 0 "second tip" ""$'
check props '^IconPixmap a(iiay) 1 4 4 64 255 '
check props '^Menu o "/NO_DBUSMENU"$'
check mon "RegisterStatusNotifierItem"
grep -v "CPU renderer" "$rt/err"
[ "$fail" -eq 0 ] && echo "PASS: a tray icon on the session bus"
exit "$fail"
