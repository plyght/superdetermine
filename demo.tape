# Record with: vhs demo.tape   (run from the repo root, after `zig build`)
# Everything on screen is real output from the real binary.
#
# The edits themselves happen in Hide blocks, the way they would if an agent
# were making them. What the viewer sees is what a developer sees afterwards:
# a diff, a verdict, and a way back.

Output demo.gif

Set Shell "bash"
Set Theme "Catppuccin Mocha"
Set FontSize 17
Set Width 1200
Set Height 820
Set Padding 20
Set Framerate 24
Set TypingSpeed 25ms

# --- setup -----------------------------------------------------------------
# A tiny python project with a real test suite, plus three shell functions so
# the off-screen edits are one short line each. `q` runs a command silently and
# erases the line it was typed on, so nothing from a Hide block survives into
# the visible buffer. The tape-level Sleeps around those calls let the launchd
# grader settle, and cost nothing: Hide records no frames.
Hide
Set TypingSpeed 1ms
Type `export PATH="$PWD/zig-out/bin:$PATH"` Enter
Type `export PS1="❯ "` Enter
Type `rm -rf /tmp/sdt-demo && mkdir -p /tmp/sdt-demo && cd /tmp/sdt-demo` Enter
Type "printf '%s\n' 'def total(items):' '    return sum(price * qty for price, qty in items)' '' '' 'def discount(subtotal, pct):' '    return subtotal - subtotal * pct / 100' > cart.py" Enter
Type "printf '%s\n' 'import unittest' '' 'import cart' '' '' 'class TestCart(unittest.TestCase):' '    def test_total(self):' '        self.assertEqual(cart.total([(250, 2), (100, 1)]), 600)' '' '    def test_discount(self):' '        self.assertEqual(cart.discount(600, 10), 540)' > test_cart.py" Enter
Type `q() { "$@" > /dev/null 2>&1; printf '\e[1A\e[J'; }` Enter
Type `base() { sdt config checks.battery_floor 0; sdt save -m "cart totals"; sdt grade; }` Enter
Type "feature() { echo 'def shipping(subtotal): return 0 if subtotal >= 500 else 25' >> cart.py; echo '    def test_shipping(self): self.assertEqual(cart.shipping(600), 0)' >> test_cart.py; }" Enter
Type `bug() { sdt save -m "free shipping"; sed -i '' 's/subtotal \* pct/pct/' cart.py; }` Enter
Type "clear" Enter
Set TypingSpeed 25ms
Show

Type "sdt init" Sleep 300ms Enter
Sleep 2s

Type `sdt config checks.full "python3 -m unittest -q"` Sleep 300ms Enter
Sleep 1500ms

# A baseline grade, then the edit that adds free shipping over 500 and the
# test that covers it.
Hide
Type "q base" Enter
Sleep 6s
Type "q feature" Enter
Sleep 9s
Show

# --- that state works ------------------------------------------------------
Type "sdt grade" Sleep 300ms Enter
Sleep 2s

# Then something changes the discount maths.
Hide
Type "q bug" Enter
Sleep 9s
Show

Type "sdt diff" Sleep 300ms Enter
Sleep 3500ms

Type "sdt grade" Sleep 300ms Enter
Sleep 3s

Type "sdt moments" Sleep 300ms Enter
Sleep 3500ms

# --- back to the last state that actually passed ---------------------------
Type "sdt green" Sleep 300ms Enter
Sleep 2500ms

Type "python3 -m unittest -q" Sleep 300ms Enter
Sleep 3s

# --- teardown: no launchd agent, no scratch repo left behind ---------------
Hide
Set TypingSpeed 1ms
Type "sdt grade --off > /dev/null; cd /; rm -rf /tmp/sdt-demo" Enter
Show
