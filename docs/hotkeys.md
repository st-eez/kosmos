# Hotkeys and Secure Input

- Carbon hotkeys for every binding. A mode switch re-registers only the keys that differ,
  at 8 µs per call, and a key whose command changed stays registered, since Kosmos looks
  up the command when the key is pressed. WindowServer matches the keys itself, so a
  keystroke that is no binding never reaches Kosmos, and Carbon sends no key repeats, so a
  binding fires once per press.
- Each binding names a physical key on the current keyboard layout: a key named by a
  character is the one that types it unshifted, else its key on a US keyboard. So two
  bindings of a mode can name one key; the first registers, and the log names the other
  as left out. On a French layout 6 needs Shift, so `alt-6` takes the key a US keyboard
  has 6 on, which types §, the key `alt-sectionSign` names. Keypad keys stay out of the
  layout's table: on French and Czech layouts only the keypad types a digit unshifted, so
  `alt-1` names the number row key, which a laptop has. Letters and digits name
  themselves, and punctuation takes AeroSpace's names, such as `minus` and
  `leftSquareBracket`.
- Each hotkey is registered exclusive. Another app's exclusive hotkey on the same
  combination makes the registration fail, and Kosmos reports it; a shared registration
  would give the key to both apps.
- WindowServer and the Dock take a macOS keyboard shortcut before any app's hotkey, so a
  load reports each binding that an enabled shortcut in System Settings also uses. The
  ceiling: macOS lists arrow and function keys with the fn flag, which may mean the Globe
  key or only the flag those keys always carry. Kosmos never registers fn, so those
  shortcuts never compare equal, and a clash on an arrow or function key goes unreported.
  A probe that settles what the flag means would let arrows be compared with fn masked
  out.
- Secure Input (a password field in any app) stops some hotkeys. `kosmos-probe
  secure-input` registers ten test hotkeys, and its window asks for a real press of each
  with Secure Input off and with its own password field focused. A hotkey that fires
  consumes the key; one that does not lets the key reach the probe's window. With real
  presses on the development Mac's keyboard:
  - hotkeys whose modifiers are Option or Option and Shift stopped on Y and comma;
  - Option on Space, Return and Delete still fired;
  - every hotkey with Control or Command fired.
- An earlier version of the probe posted synthetic presses, which gave the same answer in
  three runs. They also covered keys a laptop lacks (keypad 1 stopped; Page Down, F13 and
  keypad Enter fired) and Secure Input held by another, windowless process, which made no
  difference. They are no stand-in on their own: built from the HID state, every hotkey
  on a character key missed even with Secure Input off, and a press that no hotkey takes
  types into whichever app is in front.
- Kosmos states the rule as Option or Option and Shift on a letter, digit or punctuation
  key. That rule is inferred from Y, comma and keypad 1: the other keys were not each
  tested, and Space types a character too, yet its Option hotkey fired. By that rule, 34
  of the sample config's 52 bindings stop (alt and alt-shift on letters, digits, equal and
  minus), and the ctrl-alt bindings keep working. Tab and the arrows cannot be tested
  while Kosmos runs, because it holds them; like Return and Delete, they should keep
  working.
- WindowServer sends event 752 when Secure Input turns on and 753 when it turns off,
  whichever process changes it, and 753 when the last holder exits (measured September 24,
  2026 with throwaway programs that turned it on and off from other processes). Kosmos
  registers both on its own connection, then reads `IsSecureEventInputEnabled` and names
  the holder from the session dictionary. Nothing polls. The handler runs on the main
  actor when an event arrives, never inside a switch, though it can run right after one:
  an app that holds Secure Input only while it is active, such as Terminal with Secure
  Keyboard Entry, turns it off and on as a switch leaves or enters its workspace, and the
  status item image changes with it. Checks on app activation or focus reports would
  miss a password field focused inside the active app.
- The events follow the session's state. With two holders, the second enable and a
  release while the other remains send no event, so the named holder can be stale until
  Secure Input turns off and on again.
- While Secure Input is on, the status item shows a lock, names the holder and says which
  bindings wait, and the log records each change. For a holder with no windows of its own,
  WindowServer names the frontmost app instead. Showing it in the bar, for a Mac that hides
  the menu bar, is a later option: the snapshot can gain a field without a new version.
- A reload does not warn about bindings that stop. They stop only while Secure Input is
  on, and the sample config binds 34 of them on purpose by the rule above, so the warning
  would come with every reload.
