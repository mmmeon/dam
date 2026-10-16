import XCTest
@testable import DAM

/// Slices from a stream of this Intel Mac's low-latency encoder at 1920×1080 (the last slice
/// of each frame, the others' headers alike), and the same rewritten by another program.
final class H264OneReferenceTests: XCTestCase {

    private func unit(_ base64: String) -> Data { Data(base64Encoded: base64)! }

    private lazy var sps = unit("J2QAKqwTFlAeAIn5cADAwAF3AABdwXvfB8IhGWA=")
    private lazy var pps = unit("KO8fLA==")
    /// A keyframe's slice, cut short: only its header is read.
    private lazy var keyFrame = unit("JbgAMAAP7IN5qj/BVo3XhKp6cN/QmICz6R6LfiYXWIeZQWD6dUURjp+MCWTu9vjL")
    /// The frame after it, which the encoder marks long-term (index 0).
    private lazy var markedLongTerm = unit("IQAL9OACABBzkpT6N4cANOTOjDePDaJoheMK/IAb/vANDFLTletZcAAAAwIHHAbE6UPPSXhveg==")
    private lazy var markedLongTermRewritten = unit("IQAL9OACABBzhG+HADTkzow3jw2iaIXjCvyAG/7wDQxS05XrWXAAAAMCBxwGxOlDz0l4b3o=")
    /// The next, which predicts from long-term index 0.
    private lazy var fromLongTerm = unit(
        "IQAL9OAEACLkOcJ/+lgCg5vbNEUh0RLqgvgVRTU8xLtkYEx94BJomGCN/b+Pde9eLnL/YkUgAA0Kml8kDNq2XvG/O6amsSqBmvjjarrngOLh" +
        "K8fnPtl1iYQDw17ntZYn+oTJaPIbRZ7BVJFM92MIZBS9W8ycCz2L7QZgN1LYS97u41wSldMCaCS42i3cNNzcKSnWQoO1AI0tweOysyTPYxcH" +
        "3aA1bx6grdQmN4S44G5HroMMXyzavzSA")
    private lazy var fromLongTermRewritten = unit(
        "IQAL9OAEACBzhP/6WAKDm9s0RSHREuqC+BVFNTzEu2RgTH3gEmiYYI39v491714ucv9iRSAADQqaXyQM2rZe8b87pqaxKoGa+ONquueA4uEr" +
        "x+c+2XWJhAPDXue1lif6hMlo8htFnsFUkUz3YwhkFL1bzJwLPYvtBmA3UthL3u7jXBKV0wJoJLjaLdw03NwpKdZCg7UAjS3B47KzJM9jFwfd" +
        "oDVvHqCt1CY3hLjgbkeugwxfLNq/NIA=")
    /// A plain frame, predicting from the latest short-term frame; cut short.
    private lazy var plain = unit("IeAGADBzhC//2za3v/u7FXsHfaxX2hwHyRAweJ2PAR5/BA/lFcZXnLB2sLZmNdoo")

    func testLongTermFramesAreRewrittenAsPlainOnes() {
        let rewriter = H264OneReference()
        let first = rewriter.rewrite([sps, pps, keyFrame])
        XCTAssertEqual(first.units, [sps, pps, keyFrame])
        XCTAssertFalse(first.broken)
        let marked = rewriter.rewrite([markedLongTerm])
        XCTAssertEqual(marked.units, [markedLongTermRewritten])
        XCTAssertFalse(marked.broken)
        let predicted = rewriter.rewrite([fromLongTerm])
        XCTAssertEqual(predicted.units, [fromLongTermRewritten])
        XCTAssertFalse(predicted.broken)
        let after = rewriter.rewrite([plain])
        XCTAssertEqual(after.units, [plain])
        XCTAssertFalse(after.broken)
    }

    func testAFrameNotPredictingFromTheOneBeforeBreaksTheStreamOnce() {
        let rewriter = H264OneReference()
        _ = rewriter.rewrite([sps, pps, keyFrame])
        _ = rewriter.rewrite([markedLongTerm])
        // With the frame before long-term, a plain list starts with the keyframe.
        XCTAssertTrue(rewriter.rewrite([plain]).broken)
        XCTAssertFalse(rewriter.rewrite([fromLongTerm]).broken, "said once, until a keyframe")
        _ = rewriter.rewrite([sps, pps, keyFrame])
        XCTAssertFalse(rewriter.rewrite([markedLongTerm]).broken)
    }

    func testEmulationPreventionRoundTrips() {
        let bytes: [UInt8] = [0x25, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0x80, 0, 0]
        let escaped = H264OneReference.escape(bytes)
        XCTAssertEqual(escaped, [0x25, 0, 0, 3, 1, 0, 0, 3, 0, 0, 3, 0, 2, 0x80, 0, 0, 3])
        XCTAssertEqual(H264OneReference.unescape(escaped), bytes)
    }
}
