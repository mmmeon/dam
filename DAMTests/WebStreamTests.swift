import XCTest
import CoreMedia
import Network
@testable import DAM

final class WebStreamTests: XCTestCase {

    // MARK: - Requests and profiles

    func testRequestDefaultsFollowThePreferredProfile() {
        let request = WebStreamRequest.parse([:], preferred: .balanced)
        XCTAssertEqual(request.profile, .balanced)
        XCTAssertEqual(request.bitrateKbps, 30_000)
        XCTAssertNil(request.app)
        XCTAssertNil(request.fps)
        XCTAssertNil(request.width)
        XCTAssertTrue(request.newDisplay == (1920, 1080, 60))
    }

    func testRequestTakesItsOwnSettings() {
        let request = WebStreamRequest.parse(["profile": "viewing", "bitrate": "5000", "fps": "30", "width": "1280",
                                              "height": "720", "app": "2", "mode": "2560x1440x60"], preferred: .interactive)
        XCTAssertEqual(request.profile, .viewing)
        XCTAssertEqual(request.bitrateKbps, 5000)
        XCTAssertEqual(request.fps, 30)
        XCTAssertEqual(request.width, 1280)
        XCTAssertEqual(request.height, 720)
        XCTAssertEqual(request.app, 2)
        XCTAssertTrue(request.newDisplay == (2560, 1440, 60))
        XCTAssertTrue(request.audio, "sound unless turned off")
        XCTAssertFalse(WebStreamRequest.parse(["audio": "0"], preferred: .interactive).audio)
        XCTAssertFalse(WebStreamRequest.parse(["audio": "no"], preferred: .interactive).audio)
        XCTAssertTrue(WebStreamRequest.parse(["audio": "1"], preferred: .interactive).audio)
    }

    func testLowLatencyOnlyWhenAskedForAndNotForViewing() {
        XCTAssertFalse(WebStreamRequest.parse([:], preferred: .interactive).lowLatency)
        XCTAssertTrue(WebStreamRequest.parse(["lowlatency": "1"], preferred: .interactive).lowLatency)
        XCTAssertTrue(WebStreamRequest.parse(["lowlatency": "on", "profile": "balanced"], preferred: .interactive).lowLatency)
        XCTAssertFalse(WebStreamRequest.parse(["lowlatency": "0"], preferred: .interactive).lowLatency)
        XCTAssertFalse(WebStreamRequest.parse(["lowlatency": "1", "profile": "viewing"], preferred: .interactive).lowLatency)
        XCTAssertNotEqual(WebStreamRequest.parse(["lowlatency": "1"], preferred: .interactive),
                          WebStreamRequest.parse([:], preferred: .interactive))
    }

    func testRequestKeepsNonsenseWithinBounds() {
        let request = WebStreamRequest.parse(["profile": "fast", "bitrate": "1", "fps": "1000", "width": "1281",
                                              "height": "721", "mode": "9000x9000x60"], preferred: .interactive)
        XCTAssertEqual(request.profile, .interactive, "an unknown profile is the preferred one")
        XCTAssertEqual(request.bitrateKbps, 1000)
        XCTAssertEqual(request.fps, 120)
        XCTAssertEqual(request.width, 1280, "even sizes")
        XCTAssertEqual(request.height, 720)
        XCTAssertTrue(request.newDisplay == (1920, 1080, 60), "a display too big is not made")
        XCTAssertNil(WebStreamRequest.parse(["width": "8000", "height": "6000"], preferred: .interactive).width)
    }

    func testRequestWithHugeSizesIsRefusedRatherThanOverflowing() {
        let huge = String(Int.max / 2)
        let request = WebStreamRequest.parse(["width": huge, "height": huge, "mode": "\(huge)x\(huge)x60"],
                                             preferred: .interactive)
        XCTAssertNil(request.width)
        XCTAssertTrue(request.newDisplay == (1920, 1080, 60))
        XCTAssertNil(WebStreamRequest.parse(["width": "1280", "height": huge], preferred: .interactive).width)
        let exact = WebStreamRequest.parse(["width": "2560", "height": "1600", "mode": "2560x1600x60"], preferred: .interactive)
        XCTAssertEqual(exact.width, 2560, "the most pixels still fit")
        XCTAssertTrue(exact.newDisplay == (2560, 1600, 60))
    }

    func testAViewerMayHoldAsMuchAsTheEncoderBursts() {
        XCTAssertEqual(StreamProfile.interactive.maxInFlight(bitrateKbps: 20_000), 2_500_000, "a second of the stream")
        XCTAssertEqual(StreamProfile.balanced.maxInFlight(bitrateKbps: 30_000), 7_500_000, "twice the rate for a second")
        XCTAssertEqual(StreamProfile.viewing.maxInFlight(bitrateKbps: 40_000), 30_000_000, "three times for two seconds")
        XCTAssertEqual(StreamProfile.viewing.maxInFlight(bitrateKbps: 150_000), 64 << 20)
    }

    func testProfilesSetTheEncoderApart() {
        let interactive = StreamProfile.interactive.encoderSettings(width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000)
        XCTAssertFalse(interactive.reordering)
        XCTAssertTrue(interactive.steady, "the stream fills its grid itself")
        XCTAssertTrue(interactive.prioritizeSpeed)
        XCTAssertEqual(interactive.keyFrameInterval, 0)
        XCTAssertEqual(interactive.rateLimitWindow, 0.25)
        let viewing = StreamProfile.viewing.encoderSettings(width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000)
        XCTAssertTrue(viewing.reordering)
        XCTAssertFalse(viewing.prioritizeSpeed)
        XCTAssertEqual(viewing.keyFrameInterval, 2)
        XCTAssertGreaterThan(viewing.rateLimitWindow, interactive.rateLimitWindow)
        XCTAssertGreaterThan(StreamProfile.viewing.bufferSeconds, StreamProfile.interactive.bufferSeconds)
    }

    func testPreferredProfileIsKept() {
        XCTAssertEqual(StreamProfile.preferred, .interactive, "to begin with")
        StreamProfile.preferred = .viewing
        XCTAssertEqual(StreamProfile.preferred, .viewing)
        StreamProfile.preferred = .interactive
    }

    // MARK: - The frame grid

    private func seconds(_ time: CMTime) -> Double { CMTimeGetSeconds(time) }

    func testFramesSnapToTheGridAndNeverShareASlot() {
        var grid = FrameGrid(fps: 60)
        let origin = CMTime(value: 1_000_000_000_000, timescale: 1_000_000_000)
        XCTAssertEqual(grid.snap(origin), origin, "the first frame is the origin")
        XCTAssertEqual(grid.lastSlot, 0)
        let jittered = CMTimeAdd(origin, CMTime(value: 15_000_000, timescale: 1_000_000_000))
        XCTAssertEqual(seconds(grid.snap(jittered)), seconds(origin) + 1.0 / 60, accuracy: 1e-6,
                       "a frame a bit early still takes the next slot")
        XCTAssertEqual(grid.lastSlot, 1)
        let same = CMTimeAdd(origin, CMTime(value: 20_000_000, timescale: 1_000_000_000))
        XCTAssertEqual(seconds(grid.snap(same)), seconds(origin) + 2.0 / 60, accuracy: 1e-6,
                       "a frame in a taken slot moves to the one after")
        let later = CMTimeAdd(origin, CMTime(value: 500_000_000, timescale: 1_000_000_000))
        XCTAssertEqual(grid.lastSlot, 2)
        XCTAssertEqual(seconds(grid.snap(later)), seconds(origin) + 30.0 / 60, accuracy: 1e-6, "slots may be skipped")
        XCTAssertEqual(grid.lastSlot, 30)
        XCTAssertEqual(seconds(grid.snap(later)), seconds(origin) + 31.0 / 60, accuracy: 1e-6, "but never doubled up")
    }

    func testSlotsGoneByAreTakenOneAtATime() throws {
        var grid = FrameGrid(fps: 60)
        XCTAssertNil(grid.nextSlot(before: CMTime(value: 1, timescale: 1)), "nothing before the origin")
        let origin = CMTime(value: 5, timescale: 1)
        _ = grid.snap(origin)
        XCTAssertNil(grid.nextSlot(before: CMTimeAdd(origin, CMTime(value: 10, timescale: 1000))), "slot 1 is still to come")
        let later = CMTimeAdd(origin, CMTime(value: 40, timescale: 1000))
        XCTAssertEqual(seconds(try XCTUnwrap(grid.nextSlot(before: later))), seconds(origin) + 1.0 / 60, accuracy: 1e-6)
        XCTAssertEqual(seconds(try XCTUnwrap(grid.nextSlot(before: later))), seconds(origin) + 2.0 / 60, accuracy: 1e-6)
        XCTAssertNil(grid.nextSlot(before: later), "slot 3 is at 50 ms")
        XCTAssertEqual(grid.lastSlot, 2)
    }

    func testTheGridFollowsTheClockWhenRepeatsFillIt() {
        var grid = FrameGrid(fps: 60)
        let origin = CMTime(value: 7, timescale: 1)
        _ = grid.snap(origin)
        // A timer firing every interval, each time a little later than the slot's own time.
        for i in 1...600 {
            let now = CMTimeAdd(origin, CMTime(value: Int64(i) * 16_666_667 + 8_000_000, timescale: 1_000_000_000))
            let slot = grid.snap(now)
            XCTAssertEqual(grid.lastSlot, Int64(i), "one slot a firing, none missed")
            XCTAssertLessThanOrEqual(abs(seconds(slot) - seconds(now)), 1.0 / 60)
        }
    }

    func testFramesFasterThanTheGridDoNotRunAheadOfTheClock() {
        var grid = FrameGrid(fps: 60)
        let origin = CMTime(value: 3, timescale: 1)
        var encoded = 0
        // A second of a 120 Hz display, each frame handled a millisecond after it was captured.
        for i in 0..<120 {
            let time = CMTimeAdd(origin, CMTime(value: Int64(i) * 8_333_333, timescale: 1_000_000_000))
            let now = CMTimeAdd(time, CMTime(value: 1, timescale: 1000))
            guard let slot = grid.snap(time, now: now) else { continue }
            encoded += 1
            XCTAssertLessThanOrEqual(seconds(slot), seconds(now) + 1.0 / 60 + 1e-9, "frame \(i)")
        }
        XCTAssertLessThanOrEqual(grid.lastSlot, 61, "no further ahead after a second than at first")
        XCTAssertGreaterThanOrEqual(encoded, 59)
        XCTAssertLessThanOrEqual(encoded, 62, "the rest are kept as the last picture")
    }

    // MARK: - Sound

    func testSoundIsKeptInTimeWithTheTrack() {
        XCTAssertEqual(WebStreamSession.alignment(gap: 0), .asIs)
        XCTAssertEqual(WebStreamSession.alignment(gap: 1000), .asIs, "a few milliseconds late is let be")
        XCTAssertEqual(WebStreamSession.alignment(gap: -1000), .asIs, "as is early")
        XCTAssertEqual(WebStreamSession.alignment(gap: 4800), .silence(4800), "a gap is filled")
        XCTAssertEqual(WebStreamSession.alignment(gap: -4800), .drop(4800),
                       "sound overlapping silence put in for it loses as much")
        XCTAssertEqual(WebStreamSession.alignment(gap: 3 * 48_000), .restart)
    }

    func testAACEncoderGivesPacketsOfItsFrameLength() throws {
        var packets: [Data] = []
        let encoder = try MoonlightAudioEncoder(codec: .aac, bitrate: 192_000) { packets.append($0) }
        XCTAssertEqual(encoder.frameCount, MP4Fragmenter.aacFrameLength)
        let samples = [Float](repeating: 0.1, count: 1024 * MoonlightAudioEncoder.channels)
        var afterEach: [Int] = []
        for _ in 0..<12 {
            samples.withUnsafeBufferPointer { encoder.encode(interleaved: $0) }
            afterEach.append(packets.count)
        }
        NSLog("AAC packets after each 1024 samples: \(afterEach)")
        XCTAssertGreaterThanOrEqual(packets.count, 9, "a packet for most frames of samples given")
        XCTAssertLessThanOrEqual(packets.count, 12, "never more packets than frames given")
        XCTAssertTrue(packets.allSatisfy { !$0.isEmpty })
    }

    // MARK: - A viewer

    /// A loopback connection: the server's side is what a viewer is made of, the client's
    /// side reads what it sends.
    private final class Loopback {
        let listener: NWListener
        let client: NWConnection
        var server: NWConnection?
        let lock = NSLock()
        var received = Data()

        /// A client that does not read takes nothing once the system's buffers are full.
        init(reads: Bool = true) throws {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let port = NWEndpoint.Port(rawValue: UInt16.random(in: 40000...59000))!
            let listener = try NWListener(using: parameters, on: port)
            self.listener = listener
            client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
            var listening = false
            listener.stateUpdateHandler = { if case .ready = $0 { listening = true } }
            // The handler must be there before the listener starts.
            listener.newConnectionHandler = { [self] connection in
                server = connection
                connection.start(queue: .main)
            }
            listener.start(queue: .main)
            Self.spin(until: { listening })
            client.start(queue: .global())
            if reads { read() }
            Self.spin(until: { [self] in server != nil })
        }

        static func spin(until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        private func read() {
            client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, _ in
                lock.lock()
                if let data { received.append(data) }
                lock.unlock()
                if !complete { read() }
            }
        }

        func receivedSoFar() -> Data {
            lock.lock(); defer { lock.unlock() }
            return received
        }

        func waitForBytes(_ count: Int) {
            let deadline = Date().addingTimeInterval(5)
            while receivedSoFar().count < count, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
    }

    func testViewerStartsAtAKeyFrameWithTheHeadAndInitSegment() throws {
        let loopback = try Loopback()
        let viewer = WebStreamViewer(connection: try XCTUnwrap(loopback.server), maxInFlight: 1 << 20)
        let initSegment = Data("INIT".utf8)
        let codecs = "avc1.640033,mp4a.40.2"
        XCTAssertEqual(viewer.take(video: Data("P1".utf8), keyFrame: false, codecs: codecs, initSegment: initSegment),
                       .waitingForKeyFrame)
        viewer.take(audio: Data("A0".utf8))
        XCTAssertEqual(viewer.take(video: Data("K2".utf8), keyFrame: true, codecs: codecs, initSegment: initSegment), .taken)
        XCTAssertEqual(viewer.take(video: Data("P3".utf8), keyFrame: false, codecs: codecs, initSegment: initSegment), .taken)
        viewer.take(audio: Data("A4".utf8))
        let head = WebStreamViewer.head(codecs: codecs)
        let expected = head + "INITK2P3A4"
        loopback.waitForBytes(expected.utf8.count)
        XCTAssertEqual(String(decoding: loopback.receivedSoFar(), as: UTF8.self), expected)
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(head.contains("Content-Type: video/mp4\r\n"))
        XCTAssertTrue(head.contains("X-Codecs: \(codecs)\r\n"))
        XCTAssertFalse(head.contains("Content-Length"), "the body ends with the connection")

        let closed = expectation(description: "closed")
        viewer.onClose = { closed.fulfill() }
        viewer.watch()
        loopback.client.cancel()
        wait(for: [closed], timeout: 5)
    }

    func testViewerWithoutSoundTakesNoSound() throws {
        let loopback = try Loopback()
        let viewer = WebStreamViewer(connection: try XCTUnwrap(loopback.server), maxInFlight: 1 << 20, audio: false)
        XCTAssertFalse(viewer.audio)
        XCTAssertEqual(viewer.take(video: Data("K1".utf8), keyFrame: true, codecs: "avc1.640033", initSegment: Data("INIT".utf8)),
                       .taken)
        viewer.take(audio: Data("A2".utf8))
        XCTAssertEqual(viewer.take(video: Data("P3".utf8), keyFrame: false, codecs: "avc1.640033", initSegment: Data("INIT".utf8)),
                       .taken)
        let expected = WebStreamViewer.head(codecs: "avc1.640033") + "INITK1P3"
        loopback.waitForBytes(expected.utf8.count)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(String(decoding: loopback.receivedSoFar(), as: UTF8.self), expected)
        viewer.close()
    }

    func testViewerFallenBehindSkipsToTheNextKeyFrame() throws {
        let loopback = try Loopback()
        // Everything sent counts as in flight until the network takes it, which the
        // client never lets it: it stops reading.
        let viewer = WebStreamViewer(connection: try XCTUnwrap(loopback.server), maxInFlight: 256 * 1024)
        let initSegment = Data(count: 16)
        let big = Data(count: 300 * 1024)
        XCTAssertEqual(viewer.take(video: big, keyFrame: true, codecs: "avc1", initSegment: initSegment), .taken)
        // Big enough that the send queue is still holding it.
        var outcomes: [WebStreamViewer.Outcome] = []
        for _ in 0..<40 {
            outcomes.append(viewer.take(video: big, keyFrame: false, codecs: "avc1", initSegment: initSegment))
            if outcomes.last == .behind { break }
        }
        XCTAssertEqual(outcomes.last, .behind, "with megabytes unsent, the viewer is behind")
        XCTAssertEqual(viewer.take(video: Data(count: 10), keyFrame: false, codecs: "avc1", initSegment: initSegment),
                       .behind)
        XCTAssertEqual(viewer.take(video: Data(count: 10), keyFrame: true, codecs: "avc1", initSegment: initSegment),
                       .behind, "a keyframe would only queue behind what it has unsent")
        // The client reads on; once most has gone out, the next keyframe resumes it.
        var outcome = WebStreamViewer.Outcome.behind
        let deadline = Date().addingTimeInterval(10)
        while outcome == .behind, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            outcome = viewer.take(video: Data(count: 10), keyFrame: false, codecs: "avc1", initSegment: initSegment)
        }
        XCTAssertEqual(outcome, .catchingUp)
        XCTAssertEqual(viewer.take(video: Data("K".utf8), keyFrame: true, codecs: "avc1", initSegment: initSegment), .taken)
        XCTAssertEqual(viewer.take(video: Data("P".utf8), keyFrame: false, codecs: "avc1", initSegment: initSegment), .taken)
        viewer.close()
    }

    /// A viewer that takes nothing, as a tab in the background, gets no keyframes, and is
    /// let go once it has been behind for its patience.
    func testViewerThatTakesNothingIsLetGo() throws {
        let loopback = try Loopback(reads: false)
        let viewer = WebStreamViewer(connection: try XCTUnwrap(loopback.server), maxInFlight: 256 * 1024, patience: 0.5)
        let closed = expectation(description: "let go")
        viewer.onClose = { closed.fulfill() }
        // More than the system buffers between the two ends.
        XCTAssertEqual(viewer.take(video: Data(count: 32 << 20), keyFrame: true, codecs: "avc1", initSegment: Data()),
                       .taken)
        XCTAssertEqual(viewer.take(video: Data(count: 10), keyFrame: false, codecs: "avc1", initSegment: Data()), .behind)
        let behindAt = Date()
        Loopback.spin(until: { Date() > behindAt.addingTimeInterval(0.2) })
        XCTAssertEqual(viewer.take(video: Data(count: 10), keyFrame: true, codecs: "avc1", initSegment: Data()), .behind)
        Loopback.spin(until: { Date() > behindAt.addingTimeInterval(0.7) })
        _ = viewer.take(video: Data(count: 10), keyFrame: false, codecs: "avc1", initSegment: Data())
        wait(for: [closed], timeout: 2)
    }

    /// A session that has ended takes no viewer, so the server makes another for it.
    func testEndedSessionTakesNoViewer() throws {
        let loopback = try Loopback()
        let session = try WebStreamSession(key: .init(displayID: 1, profile: .interactive, bitrateKbps: 10_000, fps: 30,
                                                      width: 640, height: 360, lowLatency: false))
        session.stop()
        let viewer = WebStreamViewer(connection: try XCTUnwrap(loopback.server), maxInFlight: 1 << 20)
        XCTAssertFalse(session.add(viewer))
        XCTAssertEqual(session.viewerCount, 0)
        viewer.close()
    }

    /// Forgetting a device cuts off its viewers alone.
    func testCuttingADeviceLeavesOtherViewersWatching() throws {
        let (phone, laptop) = (try Loopback(), try Loopback())
        let session = try WebStreamSession(key: .init(displayID: 1, profile: .interactive, bitrateKbps: 10_000, fps: 30,
                                                      width: 640, height: 360, lowLatency: false))
        defer { session.stop() }
        XCTAssertTrue(session.add(WebStreamViewer(connection: try XCTUnwrap(phone.server), maxInFlight: 1 << 20,
                                                  device: "phone")))
        XCTAssertTrue(session.add(WebStreamViewer(connection: try XCTUnwrap(laptop.server), maxInFlight: 1 << 20,
                                                  device: "laptop")))
        session.cut(device: "phone")
        XCTAssertEqual(session.viewerCount, 1)
        session.cut(device: "tablet")
        XCTAssertEqual(session.viewerCount, 1)
    }

    // MARK: - The host's routes

    /// GETs without following redirects, trusting `authority` for HTTPS.
    private final class Client: NSObject, URLSessionTaskDelegate {
        var authority: Data?

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard let trust = challenge.protectionSpace.serverTrust, let authority,
                  let root = SecCertificateCreateWithData(nil, authority as CFData) else {
                return completionHandler(.performDefaultHandling, nil)
            }
            SecTrustSetAnchorCertificates(trust, [root] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            completionHandler(SecTrustEvaluateWithError(trust, nil) ? .useCredential : .cancelAuthenticationChallenge,
                              URLCredential(trust: trust))
        }
    }

    private let client = Client()
    private lazy var session = URLSession(configuration: .ephemeral, delegate: client, delegateQueue: nil)

    private func get(_ path: String, port: NWEndpoint.Port, secure: Bool = false, cookie: String? = nil)
        throws -> (status: Int, body: Data, headers: [String: String]) {
        var request = URLRequest(url: URL(string: "\(secure ? "https" : "http")://localhost:\(port.rawValue)\(path)")!)
        request.httpShouldHandleCookies = false
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let done = expectation(description: path)
        var result: (Int, Data, [String: String])?
        session.dataTask(with: request) { data, response, _ in
            let http = response as? HTTPURLResponse
            result = (http?.statusCode ?? 0, data ?? Data(),
                      (http?.allHeaderFields as? [String: String]) ?? [:])
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(result)
    }

    private func json(_ data: Data) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    /// The stream is served on its own ports, with Moonlight hosting off, to devices it knows.
    func testServesKnownDevicesOnItsOwnPorts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let port = NWEndpoint.Port(rawValue: UInt16.random(in: 40000...48000) & ~1)!
        let server = WebStreamServer(port: port, directory: directory)
        defer { server.stop() }
        server.apps = { [MoonlightApp(id: 1, title: "Streaming Display 1", displayID: 7)] }
        // The prompt on the Mac, answered once the test has read the code, as the user would.
        var prompt: ((String?) -> Void)?
        server.requestCode = { _, _, answer in prompt = answer }
        server.start()
        let deadline = Date().addingTimeInterval(5)
        while !server.isListening, server.lastError == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(server.isListening, server.lastError ?? "")
        func get(_ path: String, cookie: String? = nil) throws -> (status: Int, body: Data, headers: [String: String]) {
            try self.get(path, port: port, cookie: cookie)
        }

        // The page is for anyone in reach; the displays and the stream only for devices it knows.
        let page = try get("/watch")
        XCTAssertEqual(page.status, 200)
        let html = String(decoding: page.body, as: UTF8.self)
        XCTAssertTrue(html.contains("<video"))
        XCTAssertTrue(html.contains("ManagedMediaSource"), "iPhones have only the managed kind")
        XCTAssertTrue(html.contains("/pair/begin"))
        for path in ["/apps.json", "/stream.mp4", "/apps.json?token=0123"] {
            XCTAssertEqual(try get(path).status, 401, path)
        }
        XCTAssertEqual(try get("/serverinfo").status, 404, "Moonlight's requests are not this server's")
        XCTAssertEqual(server.watchURL.path, "/watch")
        XCTAssertEqual(server.watchURL.port, Int(port.rawValue))

        // A player's link.
        let link = server.addLink(named: "mpv")
        XCTAssertEqual(server.links(for: link).stream.query, "token=\(link.token)")
        let apps = try get("/apps.json?token=\(link.token)")
        XCTAssertEqual(apps.status, 200)
        let listed = try XCTUnwrap(JSONSerialization.jsonObject(with: apps.body) as? [String: Any])
        XCTAssertEqual((listed["apps"] as? [[String: Any]])?.first?["title"] as? String, "Streaming Display 1")
        XCTAssertEqual(try get("/stream.mp4?app=9&token=\(link.token)").status, 404, "no such display")
        XCTAssertEqual(server.localWatchURL.query, "token=\(server.devices.thisMac.token)")

        // A browser pairs with a code typed on the Mac, and has a cookie of its own from then.
        var begun = try json(try get("/pair/begin").body)
        XCTAssertEqual(begun["state"], "waiting")
        XCTAssertEqual(try json(try get("/pair/wait?id=\(begun["id"]!)").body)["state"], "waiting")
        prompt?(begun["code"] == "0000" ? "1111" : "0000")
        XCTAssertEqual(try json(try get("/pair/wait?id=\(begun["id"]!)").body)["state"], "declined")
        begun = try json(try get("/pair/begin").body)
        prompt?(begun["code"])
        let waited = try get("/pair/wait?id=\(begun["id"]!)")
        XCTAssertEqual(try json(waited.body)["state"], "paired")
        let setCookie = try XCTUnwrap(waited.headers["Set-Cookie"])
        XCTAssertTrue(setCookie.contains("HttpOnly"))
        XCTAssertFalse(setCookie.contains("Secure"), "paired over HTTP")
        let cookie = try XCTUnwrap(setCookie.components(separatedBy: ";").first)
        XCTAssertEqual(try get("/apps.json", cookie: cookie).status, 200)
        let browser = try XCTUnwrap(server.devices.all.first { $0.kind == .browser })

        // A QR code pairs once.
        let qr = try XCTUnwrap(URLComponents(url: server.makeQRLink(), resolvingAgainstBaseURL: false))
        let scanned = try get("/watch?\(qr.query!)")
        XCTAssertEqual(scanned.status, 303)
        XCTAssertEqual(scanned.headers["Location"], "/watch")
        XCTAssertNotNil(scanned.headers["Set-Cookie"])
        XCTAssertEqual(try get("/watch?\(qr.query!)").status, 403, "once")

        // Forgotten, a device is turned away.
        server.forget(browser)
        XCTAssertEqual(try get("/apps.json", cookie: cookie).status, 401)
        server.forget(link)
        XCTAssertEqual(try get("/apps.json?token=\(link.token)").status, 401)

        // Pairing off: a browser is told so.
        let allowed = WebStreamServer.allowsPairing
        WebStreamServer.allowsPairing = false
        XCTAssertEqual(try json(try get("/pair/begin").body)["state"], "refused")
        WebStreamServer.allowsPairing = allowed

        // HTTPS, trusting DAM's authority, which /ca.cer hands out.
        let authority = try get("/ca.cer")
        XCTAssertEqual(authority.status, 200)
        XCTAssertEqual(authority.body, server.certificates?.authority)
        client.authority = authority.body
        let secure = try self.get("/apps.json?token=\(server.devices.thisMac.token)", port: server.securePort, secure: true)
        XCTAssertEqual(secure.status, 200)

        // Stopped, it answers nothing.
        server.stop()
        XCTAssertEqual(try get("/watch").status, 0)
    }

    /// A server on ports of its own, listening.
    private func startedServer(directory: URL) -> WebStreamServer {
        let port = NWEndpoint.Port(rawValue: UInt16.random(in: 40000...48000) & ~1)!
        let server = WebStreamServer(port: port, directory: directory)
        server.start()
        let deadline = Date().addingTimeInterval(5)
        while !server.isListening, server.lastError == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(server.isListening, server.lastError ?? "")
        return server
    }

    func testConnectionThatSendsNoRequestIsClosed() throws {
        let saved = WebStreamServer.requestTimeout
        WebStreamServer.requestTimeout = 0.3
        defer { WebStreamServer.requestTimeout = saved }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = startedServer(directory: directory)
        defer { server.stop() }
        let client = NWConnection(host: "127.0.0.1", port: server.port, using: .tcp)
        defer { client.cancel() }
        let closed = expectation(description: "closed")
        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            client.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, complete, error in
                if complete || error != nil { closed.fulfill() }
            }
        }
        client.start(queue: .global())
        wait(for: [closed], timeout: 5)
    }

    /// One display is made at a time; one that comes once everyone who wanted it was
    /// stopped is removed, and one a request after the stop waited for is kept.
    func testDisplaysMadeForStreamsAreNeverLeftBehind() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = startedServer(directory: directory)
        defer { server.stop() }
        var made: [(CGDirectDisplayID?) -> Void] = []
        var removed: [CGDirectDisplayID] = []
        server.makeDisplay = { _, _, _, done in made.append(done) }
        server.removeDisplay = { removed.append($0) }
        let url = URL(string: "http://localhost:\(server.port.rawValue)/stream.mp4?token=\(server.devices.thisMac.token)")!
        func ask() { session.dataTask(with: url).resume() }
        func spin(_ seconds: TimeInterval) {
            let until = Date().addingTimeInterval(seconds)
            Loopback.spin(until: { Date() > until })
        }

        ask()
        Loopback.spin(until: { made.count == 1 })
        ask()
        spin(0.3)
        XCTAssertEqual(made.count, 1, "the second waits for the display being made")
        server.stopAll()
        made[0](42)
        XCTAssertEqual(removed, [42], "no one wants it now")

        ask()
        Loopback.spin(until: { made.count == 2 })
        XCTAssertEqual(made.count, 2, "the one removed is not the stream's")
        server.stopAll()
        ask()
        spin(0.3)
        XCTAssertEqual(made.count, 2)
        made[1](43)
        XCTAssertEqual(removed, [42], "the request after the stop has it")
        server.stop()
        XCTAssertEqual(removed, [42, 43])
    }

    /// Moonlight's HTTP port no longer serves the stream.
    func testMoonlightsPortDoesNotServeTheStream() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = UInt16.random(in: 40000...48000)
        let host = MoonlightHost(httpPort: NWEndpoint.Port(rawValue: base)!, httpsPort: NWEndpoint.Port(rawValue: base + 1)!,
                                 rtspPort: NWEndpoint.Port(rawValue: base + 2)!, directory: directory, advertises: false)
        defer { host.stop() }
        host.start()
        let deadline = Date().addingTimeInterval(5)
        while !host.isListening, host.lastError == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(host.isListening, host.lastError ?? "")
        XCTAssertEqual(try get("/watch", port: host.httpPort).status, 404)
        XCTAssertEqual(try get("/serverinfo", port: host.httpPort).status, 200)
    }
}
