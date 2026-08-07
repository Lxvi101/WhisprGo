# WhisprGo 1.2.2

This patch makes automatic paste delivery substantially more reliable across web apps, rich editors, and clipboard managers.

## More reliable pasting

- Sends Command-V as a complete, carefully timed keyboard sequence for editors that ignore instantaneous synthetic shortcuts.
- Keeps the transcript available long enough for editors that consume the clipboard asynchronously.
- Removes false paste warnings caused by delayed or incomplete Accessibility values in Chromium, WebKit, and rich-text editors.
- Preserves every representation of the previous clipboard without overwriting anything copied after dictation.
- Handles rapid consecutive dictations without losing the clipboard state from before the first paste.
- Prevents WhisprGo's synthetic Command-V from triggering user-configured global shortcuts.

## Latency

The unreliable 45–125 ms post-paste Accessibility wait has been removed. The replacement key sequence takes 15 ms, while clipboard restoration remains fully asynchronous.

WhisprGo 1.2.2 is signed with Developer ID, notarized by Apple, and available through automatic updates or the DMG below.
