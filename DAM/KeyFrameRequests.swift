//
//  KeyFrameRequests.swift
//
//  When a stream's encoder is asked for a keyframe: shared by Moonlight's streams, the
//  browser's and OpenDisplay's, in DAM and in the login window agent.
//

import CoreMedia
import CoreVideo
import Foundation

/// Answers Moonlight's keyframe requests with at most one keyframe per interval. On a lossy
/// link requests come in bursts, one per frame lost; a keyframe for each is a run of large
/// frames, each likelier to be lost again. The first request is answered at once; any more
/// within the interval are answered together once it is over, so none goes unanswered.
struct MoonlightKeyFrameThrottle {
    enum Decision: Equatable {
        case now
        /// After this many nanoseconds, asking again.
        case later(UInt64)
        /// One is already due later.
        case alreadyDue
    }

    let interval: UInt64
    private var last: UInt64?
    private var due = false

    init(interval: UInt64 = 250_000_000) {
        self.interval = interval
    }

    mutating func request(at now: UInt64) -> Decision {
        if let last, now &- last < interval {
            if due { return .alreadyDue }
            due = true
            return .later(interval - (now &- last))
        }
        last = now
        due = false
        return .now
    }

    /// The request held for later was answered otherwise: the next within the interval is
    /// held again rather than taken as due already.
    mutating func forgetDue() {
        due = false
    }
}

/// Moonlight's keyframe requests, less those a keyframe already on its way answers. While
/// Moonlight waits for a keyframe it asks again for every frame it loses, and those requests
/// reach the host after the keyframe went out: each answered with another keyframe, a lossy
/// link stays in a run of keyframes and never recovers. A request is covered while the
/// keyframe asked for is still to be sent, and when it arrives less than a round trip after
/// one finished going out, as the client sent it before it had that keyframe. A client that
/// then lost the keyframe asks again with the next frame it gets, and is answered. A request
/// held for later is answered by any keyframe that goes out before it is made again.
struct MoonlightKeyFrameRequests {
    enum Decision: Equatable {
        case now
        /// After this many nanoseconds, asking again.
        case later(UInt64)
        /// One is already due later.
        case alreadyDue
        /// A keyframe on its way answers it.
        case covered
    }

    /// How long a keyframe asked for is waited for before another may be: the encoder can
    /// leave one out, and the screen be still for half a second.
    static let patience: UInt64 = 1_000_000_000
    /// The longest round trip a request is held to, so a stale estimate (ENet starts at
    /// half a second) never holds off a client that lost the keyframe for long.
    static let longestRoundTrip: UInt64 = 300_000_000

    private var throttle: MoonlightKeyFrameThrottle
    /// When the keyframe asked for was asked for, until one is sent.
    private var asked: UInt64?
    /// When the last keyframe finished going out.
    private var sent: UInt64?
    /// When the latest request held for later came, until one is made.
    private var held: UInt64?

    init(interval: UInt64 = 250_000_000) {
        throttle = MoonlightKeyFrameThrottle(interval: interval)
    }

    /// A request at `now`; `roundTrip` is the client's in nanoseconds, nil for one of the host's
    /// own (a frame it could not send), which no keyframe already sent answers.
    mutating func request(at now: UInt64, roundTrip: UInt64?) -> Decision {
        if let asked, now &- asked < Self.patience { return .covered }
        if let roundTrip, let sent, now &- sent < min(roundTrip, Self.longestRoundTrip) { return .covered }
        switch throttle.request(at: now) {
        case .now:
            asked = now
            held = nil
            return .now
        case .later(let wait):
            held = now
            return .later(wait)
        case .alreadyDue:
            held = now
            return .alreadyDue
        }
    }

    /// A request held for later, made again at `now` as `.later` said: covered when a
    /// keyframe went out after the latest one held came, as that answers them all.
    mutating func retry(at now: UInt64, roundTrip: UInt64?) -> Decision {
        if let held, let sent, sent >= held {
            self.held = nil
            throttle.forgetDue()
            return .covered
        }
        return request(at: now, roundTrip: roundTrip)
    }

    /// A keyframe finished going out at `now`, asked for or not.
    mutating func keyFrameSent(at now: UInt64) {
        asked = nil
        sent = now
    }

    /// A keyframe could not be sent, as too large: the one asked for no longer covers
    /// requests, so the next is made, after the interval.
    mutating func keyFrameDropped() {
        asked = nil
    }
}

/// Asks a stream's encoder for keyframes, for whoever needs one: a client that lost packets,
/// a viewer joining or catching up, the stream itself. Requests go through
/// MoonlightKeyFrameRequests: at most one keyframe a quarter second, none for a request a
/// keyframe on its way answers, and none for one held for later that a keyframe answered
/// meanwhile. A keyframe is made from the picture the caller gives at once, such as the last
/// one while the screen is still, which brings no next frame; else from the next frame.
final class MoonlightKeyFrameRequester {
    /// The encoder, and the picture to make the keyframe from now, nil for the next frame.
    /// Called once for each keyframe asked of the encoder.
    typealias Source = () -> (encoder: MoonlightVideoEncoder?, picture: (buffer: CVPixelBuffer, time: CMTime)?)

    private let lock = NSLock()
    private var requests = MoonlightKeyFrameRequests()
    /// Where requests held for later are made again.
    private let queue: DispatchQueue

    init(retryingOn queue: DispatchQueue) {
        self.queue = queue
    }

    /// A request now; `roundTrip` is the client's in nanoseconds, nil for any other (see
    /// MoonlightKeyFrameRequests). `source` is called with no lock held.
    @discardableResult
    func request(roundTrip: UInt64? = nil, from source: @escaping Source) -> MoonlightKeyFrameRequests.Decision {
        handle(roundTrip: roundTrip, retry: false, source: source)
    }

    /// A keyframe came out, asked for or not.
    func keyFrameSent() {
        lock.lock()
        requests.keyFrameSent(at: DispatchTime.now().uptimeNanoseconds)
        lock.unlock()
    }

    /// A keyframe could not be sent; the next request is not covered by it.
    func keyFrameDropped() {
        lock.lock()
        requests.keyFrameDropped()
        lock.unlock()
    }

    @discardableResult
    private func handle(roundTrip: UInt64?, retry: Bool, source: @escaping Source) -> MoonlightKeyFrameRequests.Decision {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let decision = retry ? requests.retry(at: now, roundTrip: roundTrip) : requests.request(at: now, roundTrip: roundTrip)
        lock.unlock()
        switch decision {
        case .now:
            let (encoder, picture) = source()
            encoder?.requestKeyFrame()
            if let picture { encoder?.encode(picture.buffer, at: picture.time) }
        case .later(let wait):
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(wait))) { [weak self] in
                self?.handle(roundTrip: roundTrip, retry: true, source: source)
            }
        case .alreadyDue, .covered:
            break
        }
        return decision
    }
}
