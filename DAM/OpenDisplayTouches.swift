//
//  OpenDisplayTouches.swift
//
//  A receiver's touches and scrolls as mouse events. In DAM only: the login window agent
//  takes no input.
//

import Foundation

/// A receiver's touches and scrolls as the mouse events DAM's injector posts.
enum OpenDisplayTouches {
    /// The grid the injector maps normalized points through.
    static let grid = 10_000

    /// The pointer moved to `x`, `y`, from 0 to 1 across the display.
    static func move(_ x: Double, _ y: Double) -> MoonlightInput {
        func clamp(_ v: Double) -> Int { Int((min(max(v, 0), 1) * Double(Self.grid - 1)).rounded()) }
        return .moveTo(x: clamp(x), y: clamp(y), width: Self.grid, height: Self.grid)
    }

    /// A scroll of `dx`, `dy` across the stream's picture, the display's way up: turned back
    /// as frames turned clockwise by `rotation` are.
    static func scroll(dx: Double, dy: Double, rotation: DisplayRotation) -> (dx: Double, dy: Double) {
        switch rotation {
        case .standard:      return (dx, dy)
        case .quarter:       return (dy, -dx)
        case .half:          return (-dx, -dy)
        case .threeQuarters: return (-dy, dx)
        }
    }

    static func events(for message: OpenDisplayMessage) -> [MoonlightInput] {
        let at = move
        switch message {
        case let .touch(phase, x, y, _):
            switch phase {
            case .began: return [at(x, y), .button(1, down: true)]
            case .moved: return [at(x, y)]
            case .ended: return [at(x, y), .button(1, down: false)]
            case .cancelled: return [.button(1, down: false)]
            }
        case let .pencil(phase, x, y, _):
            // As a finger, the stylus hovering moving the pointer only.
            switch phase {
            case "down":
                return [at(x, y), .button(1, down: true)]
            case "up":
                return [at(x, y), .button(1, down: false)]
            default:
                return [at(x, y)]
            }
        default:
            return []
        }
    }
}
