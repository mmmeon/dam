//
//  displays.swift
//
//  The displays streamtest needs to know about, for a shell script to read.
//
//    built by streamtest with tools/common/onlinedisplays.swift (build_swift in tools/common/common.zsh)
//    ./displays list              one line per online display:
//                                 id kind screen-index x y width height pixel-width hz main mirrors
//    ./displays streaming         the first DAM streaming display's line, or nothing
//    ./displays watch             a line each time the set, a mode, main or mirroring changes,
//                                 with seconds since it started; until killed
//
//  kind is "streaming" for DAM's streaming displays (vendor 0x3456, product 0x1236), else
//  "other". screen-index is the display's place in NSScreen.screens, which mpv's --screen and
//  --fs-screen count in; -1 when AppKit has no screen for it (a mirror). x and y are
//  CoreGraphics coordinates, from the top left of the main display.
//

import AppKit

setvbuf(stdout, nil, _IONBF, 0)

func screenIndex(_ id: CGDirectDisplayID) -> Int {
    NSScreen.screens.firstIndex {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
    } ?? -1
}

func line(_ id: CGDirectDisplayID) -> String {
    let fields: [Any] = [id, isStreaming(id) ? "streaming" : "other", screenIndex(id)] + displayFields(id)
    return fields.map { "\($0)" }.joined(separator: " ")
}

switch CommandLine.arguments.dropFirst().first ?? "list" {
case "list":
    onlineDisplays().forEach { print(line($0)) }
case "streaming":
    if let id = onlineDisplays().first(where: isStreaming) { print(line(id)) }
case "watch":
    let start = Date()
    var last = ""
    while true {
        let now = onlineDisplays().map(line).joined(separator: " | ")
        if now != last {
            print(String(format: "%.1f ", Date().timeIntervalSince(start)) + now)
            last = now
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
default:
    FileHandle.standardError.write(Data("usage: displays list|streaming|watch\n".utf8))
    exit(2)
}
