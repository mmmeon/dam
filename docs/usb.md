# USB: streaming over a cable

*Plan, 2026-10-18. Kept apart from remote sessions (`feat/remote-sessions`).*

## Summary

Moonlight clients connect to the host, and need UDP as well as TCP: video on 47998,
control (ENet) on 47999, and audio on 48000. No stock client has a TCP-only mode. A cable
helps only when it carries a network, or when DAM has its own receiver that the Mac dials.
The options below run from least work to most.

## Options

1. **A network over the cable. No new protocol; stock Moonlight works.**
   - Mac to Mac: a Thunderbolt or USB4 cable makes a Thunderbolt Bridge network. Recent
     macOS also runs IP over a plain USB-C data cable.
   - iPhone: Personal Hotspot over USB gives the Mac a 172.20.10.x interface. *Untested;*
     it needs a carrier plan that allows hotspot. A Wi-Fi-only iPad gets a link-local IP
     link over USB-C anyway (see Results).
   - Android: USB tethering gives the Mac an NCM interface, which macOS supports natively.
     Older phones use RNDIS, which needs a driver.

   DAM's part is:
   - check that its listeners and Bonjour advertisement cover those interfaces;
   - find the links (by interface type or address range);
   - show "USB link: <address>" in Settings › Moonlight, so the client can add the host by
     address when mDNS doesn't cross the link.
2. **An Android relay pair over adb. Stock Moonlight Android works, and no tethering is needed.**
   - A small Android app runs a foreground service. It listens on 127.0.0.1 on the phone for
     Moonlight's TCP ports (47984, 47989, 48010) and UDP ports (47998–48000). It carries
     all of them, UDP datagrams included, inside one framed TCP stream.
   - The Mac reaches that stream with `adb forward`, and a relay on the Mac unwraps it onto
     DAM's own ports on 127.0.0.1.
   - DAM needs no changes. It replies to whatever address a client's UDP ping came from
     (`MoonlightStream.swift`), and its RTSP URL uses the address the client dialled.
   - In Moonlight Android, add the host as `127.0.0.1`.
   - This doesn't work on iOS: a relay app in the background gets suspended, so
     Moonlight-iOS can't reach it.
   - OpenDisplay's Android fork (gprot42/android-opendisplay) uses `adb forward tcp:9000
     tcp:9000` the same way, plus `adb reverse` for its device-dials-Mac mode.
3. **A DAM receiver app for iOS/iPadOS over usbmuxd.** This follows OpenDisplay's approach:
   - The device listens, and the Mac dials it through `/var/run/usbmuxd`
     (ListDevices, Listen, then Connect to the device's port). The socket is then a plain
     byte pipe, the same for USB and Wi-Fi.
   - It needs a new receiver app and a TCP framing of video, audio and input.
   - The receiver could be built on wiedymi/swift-moonlight, a Moonlight client in Swift.
     Unlike OpenDisplay, it is MIT, and all of its transports are protocols
     (`Dependencies/Protocols.swift`: `HTTPClient`, `RTSPTransport`, `ChannelTransport`,
     `ControlChannelTransport`, `MediaPacketSource`). Backing them with channels in one
     usbmuxd pipe keeps Moonlight's pairing, encryption and FEC on the DAM side.
     Caveats: it needs iOS 17 or macOS 14, and its README calls it experimental.
   - The Mac side of usbmuxd is small: ListDevices, Listen (attach and detach events) and
     Connect, framed as `[length, version 1, type 8 (plist), tag]` in little-endian,
     followed by an XML plist. The port in Connect is in network byte order. After an OK
     result, the socket is the pipe. DAM needs its own version; OpenDisplay's
     `Mac/Usbmux.swift` is GPL.
   - usbmuxd carries TCP only. OpenDisplay turns off its UDP cursor channel on USB for
     that reason.
   - OpenDisplay is GPL-3.0, so learn from its design and don't copy its code (see
     `docs/opendisplay-comparison.md`).
4. **Patching Moonlight clients** (moonlight-common-c) to tunnel their UDP over TCP. Each
   fork would have to carry the patch. Not planned.
5. **USB/IP device forwarding**, as in foundation-sunshine. A client's USB devices appear on
   the host. Not planned:
   - It is Windows-only upstream.
   - On macOS it would need a virtual host controller (DriverKit) plus entitlements.
   - Only Moonlight V+ clients speak it.

## How OpenDisplay does it

*Read 2026-10-19 from peetzweg/opendisplay (`PROTOCOL.md` §2.2 and §6.4, `Mac/Usbmux.swift`).*

- **The receiver listens on TCP 9000 and the Mac dials it.** `PROTOCOL.md` calls this "the
  most load-bearing decision": the Mac reaches the device through Bonjour on Wi-Fi, or
  through usbmuxd `Connect` over USB, and the same code serves both.
- **Everything runs over one TCP stream**, with a 4-byte length in front of each message.
- **Mac-to-Mac cables are ordinary networking.** A receiver lists its addresses in
  `hello.addrs`. The sender probes them with Wi-Fi forbidden, and moves the session to the
  first one that connects over a non-Wi-Fi path. This is because Bonjour alone often ends
  up on Wi-Fi.

DAM plays Moonlight's host role, so the client dials DAM. That's the reverse of what
usbmuxd allows. For stock clients, the cable has to carry IP (option 1) or be bridged by a
relay (option 2).

## Results

### iPad over USB-C (2026-10-19, macOS 13.7.8)

- Plugging in the iPad gives the Mac an IP link without Personal Hotspot. The interface is
  `en12`, which doesn't appear in `networksetup -listallhardwareports`.
  - The Mac's address on it is 169.254.223.46, plus an IPv6 link-local address.
  - The iPad's address is 169.254.187.129, and it answers ping in under 1 ms.
  - mDNS works on the link (the iPad is `pad.local`).
- The iPad also shows up in usbmuxd as a USB device.
- DAM needs no changes on the Mac side:
  - Its listeners bind every interface, so `serverinfo` answers on the cable address.
  - It advertises `_nvstream._tcp` on `en12`.
  - It reports `LocalIP` 169.254.223.46 to a client on that link.
- **Stock Moonlight on the iPad streams over the cable** with its Wi-Fi off. It was added by
  address (169.254.223.46) and paired over the link.
  - `nettop` puts DAM's video (47998), control (47999) and audio (48000) flows all on `en12`.
  - Pairing, `serverinfo` and RTSP all ran between the two 169.254 addresses.
- **Bandwidth.** The iPad enumerates at USB 2.0 speed (480 Mbit/s); the cable or the iPad
  may be the reason.
  - Raw UDP from the Mac to the iPad peaked at about 280 Mbit/s. That leaves very roughly
    220 Mbit/s of video after Moonlight's 20% FEC and headers.
  - The stream doesn't come close to that. With Moonlight-iOS's slider at its maximum, DAM
    set the encoder's target to 100 Mbit/s. Big Buck Bunny 1080p60 played fullscreen on a
    2048×1536 display came out at 8–18 Mbit/s and 60 fps, with no losses and no refused
    packets.
  - So this Mac's H.264 encoder limits the stream long before the cable does.

## Next steps

- Compare latency against Wi-Fi (streamtest's QR codes).
- Find out why the encoder makes only 8–18 Mbit/s against a 100 Mbit/s target.
- Check whether Moonlight finds the host by itself over the link (mDNS), without an address.
- Detect cable links (link-local addresses on interfaces other than Wi-Fi) and show the
  host's address on each in Settings › Moonlight.
- DAM's UDP sockets are IPv4 only (`MoonlightUDPSocket`). A link with only IPv6 link-local
  addresses would fail.
- Try Thunderbolt Bridge from the laptop. Linux's thunderbolt-net is reported to work with
  macOS's Thunderbolt Bridge.
