import XCTest
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

    func testProfilesSetTheEncoderApart() {
        let interactive = StreamProfile.interactive.encoderSettings(width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000)
        XCTAssertFalse(interactive.reordering)
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

    // MARK: - Sound

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

        init() throws {
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
            read()
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
            if outcomes.last == .fellBehind { break }
        }
        XCTAssertEqual(outcomes.last, .fellBehind, "with megabytes unsent, the viewer is behind")
        XCTAssertEqual(viewer.take(video: Data(count: 10), keyFrame: false, codecs: "avc1", initSegment: initSegment),
                       .waitingForKeyFrame)
        viewer.close()
    }

    // MARK: - The host's routes

    private func get(_ path: String, from host: MoonlightHost) throws -> (status: Int, body: Data) {
        let url = URL(string: "http://127.0.0.1:\(host.httpPort.rawValue)\(path)")!
        let done = expectation(description: path)
        var result: (Int, Data)?
        URLSession.shared.dataTask(with: url) { data, response, _ in
            result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(result)
    }

    func testHostServesThePageAndTheDisplays() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = UInt16.random(in: 40000...59000)
        let host = MoonlightHost(httpPort: NWEndpoint.Port(rawValue: base)!, httpsPort: NWEndpoint.Port(rawValue: base + 1)!,
                                 rtspPort: NWEndpoint.Port(rawValue: base + 2)!, directory: directory, advertises: false)
        defer { host.stop() }
        host.apps = [MoonlightApp(id: 1, title: "Streaming Display 1", displayID: 7)]
        host.start()
        let deadline = Date().addingTimeInterval(5)
        while !host.isListening, host.lastError == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(host.isListening, host.lastError ?? "")

        let page = try get("/watch", from: host)
        XCTAssertEqual(page.status, 200)
        let html = String(decoding: page.body, as: UTF8.self)
        XCTAssertTrue(html.contains("<video"))
        XCTAssertTrue(html.contains("ManagedMediaSource"), "iPhones have only the managed kind")
        XCTAssertEqual(try get("/", from: host).body, page.body)

        let apps = try get("/apps.json", from: host)
        XCTAssertEqual(apps.status, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: apps.body) as? [String: Any])
        XCTAssertEqual((json["apps"] as? [[String: Any]])?.first?["title"] as? String, "Streaming Display 1")
        XCTAssertEqual(json["profile"] as? String, StreamProfile.preferred.rawValue)
        XCTAssertEqual((json["bitrates"] as? [String: Int])?["viewing"], 40_000)

        XCTAssertEqual(try get("/stream.mp4?app=9", from: host).status, 404, "no such display")
        XCTAssertEqual(try get("/serverinfo", from: host).status, 200, "Moonlight's own requests still answered")
        XCTAssertEqual(host.watchURL.path, "/watch")
        XCTAssertEqual(host.watchURL.port, Int(base))
    }
}
