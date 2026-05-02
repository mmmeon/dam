//
//  SpeechSynthesizer.swift
//  boar
//
//  Uses NSSpeechSynthesizer — the native macOS speech API. AVSpeechSynthesizer
//  is an iOS API ported to macOS and initialises its audio session synchronously
//  on first use, which can stall the main thread for several seconds on Intel
//  Macs. NSSpeechSynthesizer does not have this problem.
//
//  When touchBar: true (the default) the spoken text is published via
//  displayText / onDisplayTextChanged so the Touch Bar can show it inline
//  without presenting a separate system-modal overlay. The text is cleared
//  automatically: immediately on stop(), after a short linger on natural finish.
//

import AppKit

final class SpeechSynthesizer {

    static let shared = SpeechSynthesizer()

    private let synth    = NSSpeechSynthesizer()
    private let synthDel = SynthDelegate()
    private var clearTimer: Timer?

    /// The text currently being spoken, or nil when silent / after the linger timeout.
    /// Observed by the Touch Bar to display a status label.
    private(set) var displayText: String?

    /// Called on the main thread whenever displayText changes so the Touch Bar can rebuild.
    var onDisplayTextChanged: (() -> Void)?

    private init() {
        synth.delegate = synthDel
        synthDel.didFinish = { [weak self] in
            // After natural completion keep the text visible briefly so the
            // user can finish reading, then fade it out.
            self?.scheduleClear(after: 3.5)
        }
    }

    // MARK: - Public API

    /// Called on the main thread when the current utterance finishes naturally
    /// (not when stopped via stop()). Cleared automatically after firing once.
    var onFinish: (() -> Void)? {
        get { synthDel.onFinish }
        set { synthDel.onFinish = newValue }
    }

    /// Speak `text`, interrupting any in-progress speech.
    /// Pass `touchBar: false` to suppress the Touch Bar label — useful when the
    /// caller is managing its own interactive Touch Bar that must not be rebuilt.
    func speak(_ text: String, touchBar: Bool = true) {
        clearTimer?.invalidate()
        if synth.isSpeaking { synth.stopSpeaking() }
        synth.startSpeaking(text)
        setDisplayText(touchBar ? text : nil)
    }

    /// Stop any in-progress speech. Clears onFinish and removes the Touch Bar label immediately.
    func stop() {
        synthDel.onFinish = nil
        clearTimer?.invalidate()
        synth.stopSpeaking()
        setDisplayText(nil)
    }

    // MARK: - Internal

    private func setDisplayText(_ text: String?) {
        displayText = text
        onDisplayTextChanged?()
    }

    private func scheduleClear(after delay: TimeInterval) {
        clearTimer?.invalidate()
        clearTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.setDisplayText(nil)
        }
    }
}

// MARK: - NSSpeechSynthesizer delegate

private final class SynthDelegate: NSObject, NSSpeechSynthesizerDelegate {

    /// Fired on the main thread just before onFinish — used internally to start the linger timer.
    var didFinish: (() -> Void)?
    /// External one-shot callback set by callers via SpeechSynthesizer.onFinish.
    var onFinish: (() -> Void)?

    func speechSynthesizer(_ sender: NSSpeechSynthesizer,
                            didFinishSpeaking finishedSpeaking: Bool) {
        guard finishedSpeaking else { return }
        DispatchQueue.main.async { [weak self] in
            self?.didFinish?()
            let cb = self?.onFinish
            self?.onFinish = nil   // consume once
            cb?()
        }
    }
}
