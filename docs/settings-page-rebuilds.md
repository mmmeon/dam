# Settings pages rebuilt whole

*Note, 2026-10-21. Not fixed yet. Found in the review of `review/integration`; the pattern was
on `main` before it, in the Moonlight tab.*

## Summary

Settings answers a change by building the page anew and swapping it in, often from inside
the click that caused the change. Nothing has crashed, but a page rebuilt while in use jumps
to its top, loses focus, and swaps out the control being used. The OpenDisplay page does it
during every connect.

## Where

In `DAM/SettingsWindowController.swift`:

- `openDisplayDidChange()` rebuilds when `sender.receivers` differs from what is shown. A
  receiver's `status` is part of that, so every status change rebuilds it: "Connecting…",
  "Setting up…", "Streaming 2732×2048 over Wi-Fi" in turn on each connect.
- `moonlightDidChange()` and `browserStreamDidChange()` rebuild when their state changes, which
  is rarer.
- `reloadSessions()` rebuilds the Remote Sessions page. Its app page now only updates its
  status row when a session starts or ends (`sessionsDidChange()`); opening an app, adding,
  removing or learning still rebuilds.
- `AppDelegate.rebuild()`, which runs whenever the menu is rebuilt, calls the first three and
  `sessionsDidChange()` each time; the OpenDisplay sender also calls `openDisplayDidChange()`
  through its own `onChange`.

## What it does

- **Scroll:** `scrollingPage` makes a new scroll view, so a page scrolled down jumps to its top.
- **Focus:** a field or control with keyboard focus loses it.
- **Controls in use:** the switch or pop-up being used is replaced by a new copy. The bitrate
  pop-up on the OpenDisplay page can be replaced while its menu is open, as the sender's dial
  timer runs in the common modes, so through menu tracking too.
- **Torn down in its own action:** the Send switch, a receiver's switch and Forget, the Name
  field, and `ListRowView.mouseUp` rebuild their page synchronously, freeing the control while
  its action is on the stack. AppKit is expected to keep it alive through its own event
  handling, and no crash has been seen, but this wasn't checked.
- **Twice:** the Send switch rebuilds twice, as `start()`/`stop()` already fire `onChange`
  before the action calls `openDisplayDidChange()` itself. The second finds nothing changed.

## Options

- **A. Leave it.** The effects are cosmetic.
- **B. Defer and coalesce.** Rebuild on the next turn of the run loop, at most once a turn
  (a "rebuild scheduled" flag per page). It ends the torn-down-in-its-own-action question and
  merges double rebuilds. About 20 lines. Scroll, focus and controls in use stay as they are.
- **C. B, and keep the scroll position.** Carry the clip view's origin over to the new page's
  scroll view. A few lines more.
- **D. Update in place.** Rebuild only when the rows change (a receiver found or gone, sending
  turned on or off); otherwise set the existing switches and status labels, as the Remote
  Sessions app page does with its summary row. It fixes all of the above, at some work per
  page.

Suggested: C for every page, and D for the OpenDisplay page, the one rebuilt in normal use.
