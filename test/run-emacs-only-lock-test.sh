#!/bin/bash
# Session lock: while an ext-session-lock lock is held the WM must not change
# focus, inject keys or run ordinary bindings; afterwards it must recover.
set -u
. "$(dirname "$0")/lib.sh"
cd "$REPO"
require_river
need_tool lockclient
bash test/cleanup-ours.sh >/dev/null 2>&1
rm -f /tmp/lock-app-input.txt /tmp/visual-locked.ppm /tmp/visual-unlocked.ppm \
      /tmp/lockclient.log /tmp/screenshot.log \
      /tmp/emacs-wm-elisp.log /tmp/emacs-wm-be.log
clear_sockets

( WLR_WL_OUTPUTS=1 EMACS_WM_TEST_EL=elisp-lock.el \
  EMACS_WM_BE_LOG_LEVEL=debug \
  timeout 70 "$RIVER" -log-level debug -log-scopes wm,lock,output \
     -c "$SESSION_SCRIPT" \
     >/tmp/lock-river.log 2>&1 & )
sleep 30

echo "=== frontend ==="
grep -E "lock test|taking the session|locked|unlocked|ignored|refused|screenshot|before the lock|final" \
     /tmp/emacs-wm-elisp.log 2>/dev/null | head -22
echo
echo "=== backend: lock events, focus re-asserted, injected keys ==="
grep -E "session locked|session unlocked|focus ->|injected |dropped .* injected" \
     /tmp/emacs-wm-be.log 2>/dev/null | tail -12
echo "=== lock client ==="
cat /tmp/lockclient.log 2>/dev/null | head -5
echo "=== app received (only after unlock) ==="
od -c /tmp/lock-app-input.txt 2>/dev/null | head -3 || echo "(nothing)"
echo "=== river: its own lock state changes ==="
grep -E "info\(lock\)" /tmp/lock-river.log 2>/dev/null | head -6

# Locked: the lock surface is a solid colour over everything.  Unlocked: the
# ordinary scene, borders included, must be back.
echo "=== screenshots: locked vs unlocked ==="
for f in /tmp/visual-locked.ppm /tmp/visual-unlocked.ppm; do
    [ -f "$f" ] && ffmpeg -loglevel error -y -i "$f" "${f%.ppm}.png" 2>/dev/null
done
python3 - <<'PY'
LOCK = (0x20, 0x20, 0x20)
BORDER = (0x7a, 0xa2, 0xf7)      # focused border, from the visual suite

def load(path):
    try:
        f = open(path, 'rb')
    except FileNotFoundError:
        return None
    assert f.readline().strip() == b'P6'
    w, h = map(int, f.readline().split()); f.readline()
    return w, h, f.read()

def summarise(path):
    got = load(path)
    if got is None:
        print(f"{path}: missing")
        return None
    w, h, d = got
    def px(x, y):
        i = (y * w + x) * 3; return tuple(d[i:i+3])
    lock = border = n = 0
    for y in range(0, h, 3):
        base = y * w
        for x in range(0, w, 3):
            i = (base + x) * 3
            p = (d[i], d[i+1], d[i+2])
            n += 1
            if p == LOCK: lock += 1
            elif p == BORDER: border += 1
    print(f"{path}: {w}x{h} centre={px(w//2, h//2)} corner={px(4, 4)} "
          f"lock-colour {100*lock//n}% of samples, border-colour {border} samples")
    return px(w // 2, h // 2), lock, border, n

locked = summarise('/tmp/visual-locked.ppm')
after = summarise('/tmp/visual-unlocked.ppm')
if locked and after:
    ok = (locked[0] == LOCK and locked[1] * 10 > locked[3] * 9
          and after[0] != LOCK and after[2] > 0)
    print("locked screen is solid lock colour, unlocked screen shows the scene:",
          "OK" if ok else "MISMATCH")
PY

echo "=== verdict ==="
verdict () { if eval "$2"; then echo "OK       $1"; else echo "MISMATCH $1"; fi; }
verdict "river logged session locked" \
    'grep -q "info(lock): session locked" /tmp/lock-river.log'
verdict "WM saw locked, refused injection and bindings" \
    'grep -q "session locked" /tmp/emacs-wm-elisp.log && grep -q "inject (\"x\" \"Return\") refused: session locked" /tmp/emacs-wm-elisp.log && grep -q "key \"s-2\" ignored: session locked" /tmp/emacs-wm-elisp.log'
verdict "lock client confirmed the lock" \
    'grep -qx "lockclient: locked" /tmp/lockclient.log'
verdict "lock client never hit a protocol error" \
    '! grep -q "Protocol error\|invalid_unlock\|never sent" /tmp/lockclient.log'
verdict "river logged session unlocked" \
    'grep -q "info(lock): session unlocked" /tmp/lock-river.log'
verdict "WM cleared its locked flag" \
    'grep -q "unlocked (lock released): locked=nil" /tmp/emacs-wm-elisp.log'
verdict "WM re-asserted keyboard focus after unlock" \
    'awk "/session unlocked/{seen=1} seen && /focus -> window/{found=1} END{exit !found}" /tmp/emacs-wm-be.log'
verdict "post-unlock injection reached the app" \
    'grep -q u /tmp/lock-app-input.txt 2>/dev/null'
echo "=== river panics: $(grep -c panic /tmp/lock-river.log 2>/dev/null) ==="
echo "=== leftovers ==="
bash test/cleanup-ours.sh
