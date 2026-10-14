# Apple frameworks and libraries used by DAM

Grouped by what they do for the app. Links go to Apple's developer documentation; frameworks with no public documentation are marked as such.

## Display and device control (DAM's core)

| Framework                                                                         | Used for                                                                                   |
| --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| SidecarCore (private, no public docs)                                             | Using an iPad as a display and auto-connecting (`SidecarManager.swift`)                    |
| DFRFoundation (private, no public docs)                                           | Touch Bar control strip presence, loaded with `dlopen` (`ControlStripPresenter.swift`)     |
| [NSTouchBar](https://developer.apple.com/documentation/appkit/nstouchbar) (AppKit) | Touch Bar UI (`ChoicePicker.swift`, `AirPlayQuickConnect.swift`, `ArrangeTouchBar.swift`); shown system-modal via private `presentSystemModalTouchBar:` calls |
| [IOKit](https://developer.apple.com/documentation/iokit) (incl. `IOKit.graphics`) | Identifying and managing physical displays (`DisplayRegistry.swift`, `VideoManager.swift`) |
| [CoreGraphics](https://developer.apple.com/documentation/CoreGraphics)            | Display arrangement, mirroring and extending, virtual-display resolution overrides         |
| [CoreAudio](https://developer.apple.com/documentation/CoreAudio)                  | Switching audio output (`AudioManager.swift`, `AudioOutputPicker.swift`)                   |

## Moonlight and web streaming

| Framework                                                                      | Used for                                                                            |
| ------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------- |
| [ScreenCaptureKit](https://developer.apple.com/documentation/ScreenCaptureKit) | Screen capture (`MoonlightScreenCapture.swift`)                                     |
| [VideoToolbox](https://developer.apple.com/documentation/VideoToolbox)         | Video encoding (`MoonlightVideoEncoder.swift`)                                      |
| [AudioToolbox](https://developer.apple.com/documentation/AudioToolbox)         | Audio encoding (`MoonlightAudioEncoder.swift`)                                      |
| [CoreMedia](https://developer.apple.com/documentation/CoreMedia)               | Sample buffers between capture and the encoders                                     |
| [Network](https://developer.apple.com/documentation/Network)                   | RTSP, web stream and host discovery                                                 |
| [CryptoKit](https://developer.apple.com/documentation/CryptoKit)               | Moonlight pairing and stream encryption                                             |
| CommonCrypto (no public docs; superseded by CryptoKit)                         | Crypto primitives in `MoonlightCrypto.swift`                                        |
| [Security](https://developer.apple.com/documentation/Security)                 | Certificates and keys for pairing (`MoonlightPairing.swift`, `MoonlightHost.swift`) |
| enet (not Apple)                                                               | Transport for the Moonlight protocol                                                |

## Input and system integration

| Framework                                                                            | Used for                                                                          |
| ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------- |
| Carbon.HIToolbox (no public docs)                                                    | Global hotkeys and key recording (`GlobalHotkey.swift`, `HotkeyPreference.swift`) |
| [ServiceManagement](https://developer.apple.com/documentation/ServiceManagement)     | Launch at login (`VisibilityPreferences.swift`)                                   |
| [ApplicationServices](https://developer.apple.com/documentation/applicationservices) | Accessibility and application services                                            |

## Generic scaffolding

| Framework                                                          | Used for                                                             |
| ------------------------------------------------------------------ | -------------------------------------------------------------------- |
| [AppKit](https://developer.apple.com/documentation/AppKit)         | App UI (also pulled in via Cocoa, which has no docs page of its own) |
| [SwiftUI](https://developer.apple.com/documentation/SwiftUI)       | Declarative UI                                                       |
| [Foundation](https://developer.apple.com/documentation/Foundation) | Core types                                                           |
| [Combine](https://developer.apple.com/documentation/Combine)       | Reactive state                                                       |
| [os](https://developer.apple.com/documentation/os)                 | Logging (`os.log`)                                                   |
| [QuartzCore](https://developer.apple.com/documentation/QuartzCore) | Core Animation                                                       |
| [CoreVideo](https://developer.apple.com/documentation/CoreVideo)   | Pixel buffers                                                        |
| Darwin (no top-level docs page)                                    | POSIX/C APIs                                                         |
| [XCTest](https://developer.apple.com/documentation/XCTest)         | Tests only                                                           |

## Only incidental (one file each)

| Framework                                                              | Notes |
| ---------------------------------------------------------------------- | ----- |
| [Vision](https://developer.apple.com/documentation/Vision)             |       |
| [CoreImage](https://developer.apple.com/documentation/CoreImage)       |       |
| [AVFoundation](https://developer.apple.com/documentation/AVFoundation) |       |

## Tried and rejected

| Framework | What we tried | Why it failed |
| --------- | ------------- | ------------- |
| `AVOutputContext` (private part of AVFoundation, no public docs) | Driving AirPlay screen routing directly, as the built-in AirPlay Touch Bar and Control Center items do: `+sharedSystemScreenContext`, `-addOutputDevice:`, `-setOutputDevices:` (which would also allow several AirPlay screens at once) | It needs Apple-only restricted entitlements (`com.apple.avfoundation.allow-system-wide-context`, `allows-access-to-device-list`, `allows-set-output-device`). Without them `sharedSystemScreenContext` returns nil. Claiming them gets the app SIGKILLed at launch ("Taskgated Invalid Signature"), whether it is signed with an Apple Development identity or ad-hoc. DAM drives Control Center's UI instead. See [airplay-api-notes.md](airplay-api-notes.md). |

## C and POSIX headers

`string.h`, `stdlib.h`, `unistd.h`, `time.h`, `stdio.h`, `errno.h`, `fcntl.h`, `poll.h`, `netdb.h`, `sys/types.h`, `sys/time.h`, `sys/socket.h`, `sys/ioctl.h`, `netinet/tcp.h`, `netinet/in.h`, `arpa/inet.h`
