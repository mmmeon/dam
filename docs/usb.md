# USB: streaming over a cable

*Plan, 2026-10-18. Kept apart from remote sessions (`feat/remote-sessions`).*

## Summary

Moonlight clients connect to the host, and need UDP as well as TCP. A cable helps only
when it carries a network, or when DAM has its own receiver that the Mac dials. The options
below run from least work to most.

## Options

1. **A network over the cable. No new protocol; stock Moonlight works.**
   - Mac to Mac: a Thunderbolt or USB4 cable makes a Thunderbolt Bridge network. Recent
     macOS also runs IP over a plain USB-C data cable.
   - iPhone: Personal Hotspot over USB gives the Mac a 172.20.10.x interface. *Untested;*
     it needs a carrier plan that allows hotspot, so Wi-Fi-only iPads can't do it.
   - Android: USB tethering gives the Mac an NCM interface, which macOS supports natively.
     Older phones use RNDIS, which needs a driver.

   DAM's part is:
   - check that its listeners and Bonjour advertisement cover those interfaces;
   - find the links (by interface type or address range);
   - show "USB link: <address>" in Settings › Moonlight, so the client can add the host by
     address when mDNS doesn't cross the link.
2. **A DAM receiver app for iOS/iPadOS over usbmuxd.** This follows OpenDisplay's approach:
   - The device listens, and the Mac dials it through `/var/run/usbmuxd`
     (ListDevices, Listen, then Connect to the device's port). The socket is then a plain
     byte pipe, the same for USB and Wi-Fi.
   - It needs a new receiver app and a TCP framing of video, audio and input.
   - OpenDisplay is GPL-3.0, so learn from its design and don't copy its code (see
     `docs/opendisplay-comparison.md`).
3. **Tunnelling Moonlight's UDP over a TCP pipe** (adb forward/reverse or usbmuxd). This
   needs a shim on both ends, or a forked client. Not planned.
4. **USB/IP device forwarding**, as in foundation-sunshine. A client's USB devices appear on
   the host. Not planned:
   - It is Windows-only upstream.
   - On macOS it would need a virtual host controller (DriverKit) plus entitlements.
   - Only Moonlight V+ clients speak it.

## First step

Option 1:
- detect USB and Thunderbolt network links;
- list the host's address on each in the Moonlight tab;
- test from a Mac over Thunderbolt Bridge, and from the laptop if it can do IP over USB-C.
