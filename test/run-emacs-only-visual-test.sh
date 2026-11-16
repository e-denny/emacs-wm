#!/bin/bash
# Visual confirmation of compositor-drawn borders.
#
#   test/run-emacs-only-visual-test.sh
#
# Two tiled app windows; a screenshot of each focus state taken by
# test/tools/screenshot (zwlr_screencopy, which needs an fd and therefore
# cannot live in the Elisp WM).  The PPM is sampled at the expected border
# pixels and converted to PNG so a human can look at it too.
set -u
. "$(dirname "$0")/lib.sh"
cd "$REPO"
require_river

need_tool screenshot

bash test/cleanup-ours.sh >/dev/null 2>&1
rm -f /tmp/visual-*.ppm /tmp/visual-*.png /tmp/visual-tool.log \
      /tmp/emacs-wm-elisp.log /tmp/emacs-wm-be.log
clear_sockets

( WLR_WL_OUTPUTS=1 EMACS_WM_TEST_EL=elisp-visual.el \
  EMACS_WM_BE_LOG_LEVEL=debug \
  timeout 60 "$RIVER" -log-level debug -log-scopes wm \
     -c "$SESSION_SCRIPT" \
     >/tmp/visual-river.log 2>&1 & )
sleep 36

echo "=== layout: two tiled windows and which is focused ==="
grep -E "window [0-9]+ on output .*rect=" /tmp/emacs-wm-elisp.log | tail -6
echo
echo "=== captures ==="
ls -la /tmp/visual-*.ppm 2>/dev/null

for f in /tmp/visual-*.ppm; do
    [ -e "$f" ] || continue
    png="${f%.ppm}.png"
    ffmpeg -loglevel error -y -i "$f" "$png" 2>/dev/null && echo "converted $png"
done

echo "=== border pixels (expected: focused #7aa2f7, unfocused #3b4261) ==="
python3 - <<'PY'
import re, sys

def read_ppm(path):
    with open(path, 'rb') as f:
        assert f.readline().strip() == b'P6'
        w, h = map(int, f.readline().split())
        assert int(f.readline()) == 255
        return w, h, f.read()

def pixel(img, x, y):
    w, h, data = img
    i = (y * w + x) * 3
    return tuple(data[i:i+3])

focused_rgb   = (0x7a, 0xa2, 0xf7)
unfocused_rgb = (0x3b, 0x42, 0x61)

# Walk the log chronologically: keep the current window state, and snapshot it
# whenever a screenshot is taken.  Sampling a capture against a *later* focus
# state would compare the wrong thing.
current = {}
shots = {}
for line in open('/tmp/emacs-wm-elisp.log', errors='replace'):
    m = re.search(r'window (\d+) on output .*rect=\((\d+) (\d+) (\d+) (\d+)\).*focused=(\w+)', line)
    if m:
        wid, x, y, w, h, focused = m.groups()
        current[int(wid)] = (int(x), int(y), int(w), int(h), focused == 't')
        continue
    m = re.search(r'--- screenshot (\S+)', line)
    if m:
        shots[m.group(1)] = dict(current)

if not shots:
    print("no screenshot markers in the log"); sys.exit(1)

ok = True
for name, rects in shots.items():
    path = f"/tmp/visual-{name}.ppm"
    try:
        img = read_ppm(path)
    except Exception as e:
        print(f"{name}: cannot read {path}: {e}"); ok = False; continue
    print(f"--- {name}: {img[0]}x{img[1]}, {len(rects)} window(s) at capture time")
    for wid, (x, y, w, h, focused) in sorted(rects.items()):
        want = focused_rgb if focused else unfocused_rgb
        # river draws borders *outside* the window box: x-2..x, y-2..y.
        samples = [("left", (x - 1, y + h // 2)),
                   ("right", (x + w, y + h // 2)),
                   ("bottom", (x + w // 2, y + h))]
        if y >= 2:
            samples.append(("top", (x + w // 2, y - 1)))
        samples = [(where, (sx, sy)) for where, (sx, sy) in samples
                   if 0 <= sx < img[0] and 0 <= sy < img[1]]
        for where, (sx, sy) in samples:
            px = pixel(img, sx, sy)
            good = px == want
            ok = ok and good
            print(f"    wid {wid} focused={focused} {where} border at ({sx},{sy}) "
                  f"pixel={px} want={want} {'OK' if good else 'MISMATCH'}")

sys.exit(0 if ok else 1)
PY
PIXELS=$?

echo "=== verdict ==="
FAILED=0
verdict () {
    name=$1; shift
    if "$@" >/dev/null 2>&1; then echo "OK       $name"; else echo "MISMATCH $name"; FAILED=1; fi
}
verdict "focused-a capture exists" test -s /tmp/visual-focused-a.ppm
verdict "focused-b capture exists" test -s /tmp/visual-focused-b.ppm
verdict "every sampled border pixel matched" test "$PIXELS" = 0
if [ "$FAILED" != 0 ]; then
    echo "note: a missing capture means the nested host never presented a frame"
    echo "note: (screencopy needs a render; see test/tools/src/bin/screenshot.rs)"
fi
echo "=== river panics: $(grep -c panic /tmp/visual-river.log 2>/dev/null) ==="
echo "=== leftovers ==="
bash test/cleanup-ours.sh
exit "$FAILED"
