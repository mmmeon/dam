# AirPlay display connection — API research notes

*Investigated 2026-09-29 on macOS 13.7.8 (Ventura). Revisit if a future macOS changes
the entitlement story or exposes a public screen-routing API.*

## TL;DR

- The Touch Bar "AirPlay" item and Control Center's Screen Mirroring both use a **private
  AVFoundation routing API** that is exactly what DAM would want: a named device list, a
  one-call connect, and change notifications.
- It is **gated by Apple-only restricted entitlements**. Without them the API is inert
  (nil context, empty device list); forging them gets the process SIGKILLed by AMFI.
  **A third-party app cannot use it on stock macOS.**
- Driving Control Center's Screen Mirroring panel through Accessibility is the only
  route available to non-Apple apps. DAM does that; the mechanism (not the category)
  is what can be improved.

## What the Touch Bar item actually is

`/System/Library/CoreServices/ControlStrip.app/Contents/XPCServices/com.apple.DFRSystemExtra.AirPlay.xpc`
— class `DFRAirPlayController`. From its disassembly:

```objc
// init
_avContext = [AVOutputContext sharedSystemScreenContext];
[_avContext setApplicationProcessID:getpid()];
_avSession = [[AVOutputDeviceDiscoverySession alloc] initWithDeviceFeatures:2]; // 2 = screen
[_avSession setDiscoveryMode:1];   // 2 while the popover is open
// notifications observed:
//   AVOutputContextOutputDeviceDidChangeNotification                  (object: _avContext)
//   AVOutputDeviceDiscoverySessionAvailableOutputDevicesDidChangeNotification (object: _avSession)

// device list
_avSession.availableOutputDevicesObject.recentlyUsedDevices + .otherDevices
    minus [AVOutputDevice sharedLocalDevice]

// tap a device (toggle: tapping the current device passes nil = disconnect)
AVOutputDevice *target = [device isEqualTo:_avContext.outputDevice] ? nil : device;
[_avContext setOutputDevice:target forFeatures:2];
// then a 30 s "connect failed" timer, cleared by the OutputDeviceDidChange notification
```

Connected state = `_avContext.outputDevice`. ControlCenter.app's `ScreenMirroringController`
uses the same classes (plus `AVOutputContextOutputDevicesDidChangeNotification`).

Useful selectors (dumped via the ObjC runtime): `AVOutputContext` —
`sharedSystemScreenContext`, `outputDevice`, `outputDevices`, `setOutputDevice:forFeatures:`,
`setOutputDevice:options:completionHandler:`, `addOutputDevice:`, `removeOutputDevice:`.
`AVOutputDevice` — `name`, `deviceID`, `ID`, `deviceType`, `deviceSubType`, `deviceFeatures`,
`modelID`, `manufacturer`. `AVOutputDeviceDiscoverySession` — `initWithDeviceFeatures:`,
`setDiscoveryMode:`, `availableOutputDevices`, `availableOutputDevicesObject`.

## Why it's unusable

Both the DFR service and ControlCenter carry:

```
com.apple.avfoundation.allow-system-wide-context
com.apple.avfoundation.allows-access-to-device-list
com.apple.avfoundation.allows-set-output-device
```

Empirical results from an unentitled probe (Swift, ObjC runtime, `Apple Development`-style
plain signing):

| Call | Result |
|---|---|
| `+[AVOutputContext sharedSystemScreenContext]` | **nil** |
| `sharedSystemAudioContext`, `sharedSystemRemotePoolContext` | nil |
| `defaultSharedOutputContext`, `outputContext` (app-scoped audio/video) | work — but don't route the desktop |
| `AVOutputDeviceDiscoverySession` features 1/2/3, mode 2, 8 s | **0 devices** (Bonjour saw the "tv" the whole time) |
| `+[AVOutputDevice sharedLocalDevice]` | works |
| ad-hoc-sign the three entitlements onto the probe | **SIGKILL at launch (exit 137)** — AMFI |

The checks are server-side (the routing daemon inspects the caller's entitlements) *and*
kernel-side (restricted entitlements need an Apple-issued profile; AMFI kills forgeries).
No cert you can generate — self-signed, Apple Development, Developer ID — changes this.
Only `amfi_get_out_of_my_way=1` + SIP off would, which is not shippable.

Contrast: `CGVirtualDisplay` (DAM's virtual anchor) is *undocumented but unguarded* —
nothing checks the caller. That's why it works with ordinary signing and no entitlements.

## Other options considered

| Option | Verdict |
|---|---|
| MediaRemote routing | Wraps the same `AVOutputContext`; same daemon check. |
| Public `AVRoutePickerView` / `AVPlayer` external playback | Routes *the app's media* to an Apple TV via URL handoff. LAN-only is fine (TV fetches the URL from the Mac; use the `.local` hostname; macOS firewall will prompt). `file://` assets are served by AVPlayer's internal HTTP server. Cannot mirror the desktop: no `AVSampleBufferDisplayLayer` / generated frames. Screen → HLS → handoff is possible but multi-second latency, mirror-only, no input. |
| `AVRouteDetector` (public) | Only `multipleRoutesDetected` bool, scoped to the app's player. No names. |
| CoreAudio | AirPlay **speakers** are public output devices (`kAudioDeviceTransportTypeAirPlay` = `'airp'`). Audio only; clean if ever wanted. |
| Shortcuts | No screen-mirroring action on macOS 13 (audio "Set Playback Destination" is iOS-only). |
| Own AirPlay sender | Mirroring to a real Apple TV needs FairPlay pairing; no open-source sender does it. OSS projects are receivers. |
| CLI / `defaults` / URL scheme | Nothing initiates a connection. `"NSStatusItem Visible ScreenMirroring"` in `com.apple.controlcenter` only shows/hides the menu-bar extra (which is DAM's fast path). |
| Sidecar (`SidecarCore`) | Adjacent, iPad-only; reportedly unguarded like `CGVirtualDisplay`. |

## Improvements to the AX approach

1. **Done** (`ScreenMirroringPanel.swift`): drive Control Center with `AXUIElement`
   directly from Swift instead of `NSAppleScript` → System Events. Same panel, same
   Accessibility permission, but no Automation ("control System Events") permission,
   no `-1743` failure path, and real error values. The `apple-events` entitlement and
   usage string are gone.
2. **Done**: each step waits on `AXObserver` notifications (window created / layout
   changed / element created / destroyed) with a 250 ms poll as a safety net, instead
   of fixed `delay`s. Gotcha found on the way: Control Center keeps a window open even
   when nothing is showing, so "wait for a window" is wrong — each step searches every
   window for the thing it needs (tile, device checkbox) instead.
3. Not done: detect when the Screen Mirroring menu-bar extra is hidden and offer to
   enable it (the extra is a shorter, more reliable path than the Control Center tile).
   The tile path is implemented (first action on the tile, as before) but was not
   exercised in testing — the extra was visible.

## Scratch tooling used

Probe/disassembly tooling lived in the session scratchpad (not committed). Recipe:
`lipo -thin x86_64`, `dyld_info -fixups`, `llvm-objdump --macho -d` (annotates selector
refs), `otool -oV` for method → address, `codesign -d --entitlements :-` for entitlements,
and a Swift tool calling the classes through `objc_msgSend` with `value(forKey:)` dumps.
