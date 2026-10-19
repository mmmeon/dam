# Slow removal of streaming displays

*Note, 2026-10-19. Not fixed yet. Found by `tools/sessiontest` (branch
`test/remote-session-layout`), but it affects every streaming display, Moonlight's included.*

## Summary

After a stream or remote session ends, its streaming display can stay up for 7–10 s before
DAM removes it. Meanwhile the Mac's own displays stay as the session left them, mirrored or
moved. The removal isn't lost; it waits in the request queue behind a display commit that
takes about 10 s.

## What was seen

On this Mac (Intel, macOS 13.7.8, the Lenovo T24i on its own at 1600×900@50):

- `sessiontest run mirror`: the display went 7 s after the session ended. In an earlier run
  it was 9.5 s (ended 09:30:13.261, `remove 0` at 09:30:22.821).
- `sessiontest run overlap` (two sessions, ended in turn): the second display went 10 s
  after its session ended. In DAM's log the second session ended at 09:42:06.251, a
  `reassert: CompleteDisplayConfiguration` returned at 09:42:15.288, and `remove 1` came
  in the same millisecond.
- Adding can be slow the same way: once a display was online at 09:42:21.015, and its
  `place: CompleteDisplayConfiguration` returned at 09:42:32.669.
- Around these slow commits the Lenovo dropped out of the online list for a few seconds.
  Once a display with another ID (1104977159, 1280×720) was the only one online, and a run
  ended with the Lenovo at 1920×1080@60 instead of 1600×900@50.

## Why

- `removeStreamingDisplay(id:)` queues a `.remove`, and `processStreamingRequests` starts it
  only when neither `streamingChangeInFlight` nor `streamingReassertInFlight` is set.
- After each change, `reassertStreamingLayout` commits the kept layout `.permanently`, one
  commit at a time, until the settle expires.
- WindowServer has saved a layout for the streaming displays' IDs (4128834 and 4128835)
  that mirrors the Lenovo onto them, left over from mirror tests. So each new set mirrors
  the Lenovo, and DAM's commit undoes it (`restore: display 731413954 mirror master 4128834 → 0`).
  Changing an external monitor's mirroring makes it resync, and the commit doesn't return
  until it has, which takes about 10 s here.

*Not yet confirmed:* whether a Mac without the saved mirror layout has the delay; and
whether the dropouts are the HDMI resync itself or WindowServer re-enumerating.

## Directions

1. Let a removal go ahead of a reassert still to run, and drop the settle for the display
   being removed: the layout is restored without it anyway.
2. Find WindowServer's saved layouts (`/Library/Preferences/com.apple.windowserver.displays.plist`
   and the per-user ByHost copy) and see whether DAM's mirror placements are what save the
   mirroring for its IDs. If so, commit those `.forSession` instead.
3. Time each `CGCompleteDisplayConfiguration`, and log which displays and mirror changes it
   carries, to see which commits are slow.

## Reproducing

`tools/sessiontest/sessiontest run mirror overlap` (on `test/remote-session-layout`) notes
"DAM's display took N s to go" for each case. Moonlight's New Display shows it too:
cancel the stream and time how long the display stays.
