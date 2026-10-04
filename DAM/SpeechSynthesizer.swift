//
//  SpeechSynthesizer.swift
//
//  Uses NSSpeechSynthesizer — the native macOS speech API. AVSpeechSynthesizer
//  is an iOS API ported to macOS and initialises its audio session synchronously
//  on first use, which can stall the main thread for several seconds on Intel
//  Macs. NSSpeechSynthesizer does not have this problem.
//
//  When caption: true (the default) the spoken text is published via
//  displayText / onDisplayTextChanged so it can be shown as a caption — inline on
//  the Touch Bar, or on screen without one. The text is cleared automatically:
//  immediately on stop(), after a short linger on natural finish. While captioned text
//  is spoken, spokenLength / onSpokenLengthChanged track progress word by word.
//
//  Speech plays through the device chosen in Settings (VisibilityPreferences.speechOutputUID),
//  falling back to the system sound output when none is chosen or it isn't connected.
//

import AppKit

final class SpeechSynthesizer {

    static let shared = SpeechSynthesizer()

    private let synth    = NSSpeechSynthesizer()
    private let synthDel = SynthDelegate()
    private var clearTimer: Timer?

    /// The caption currently shown, or nil when silent / after the linger timeout.
    private(set) var displayText: String?

    /// Called on the main thread whenever displayText changes so the caption can update.
    var onDisplayTextChanged: (() -> Void)?

    /// How many characters (UTF-16) of displayText have been spoken, through the end of the
    /// word being spoken; nil when displayText isn't being spoken.
    private(set) var spokenLength: Int?

    /// Called on the main thread whenever spokenLength changes.
    var onSpokenLengthChanged: (() -> Void)?

    private init() {
        synth.delegate = synthDel
        synthDel.didFinish = { [weak self] in
            guard let self else { return }
            if let text = self.displayText { self.setSpokenLength(text.utf16.count) }
            // After natural completion keep the text visible briefly so the
            // user can finish reading, then fade it out.
            self.scheduleClear(after: 3.5)
        }
        synthDel.willSpeakWord = { [weak self] range in
            guard let self, self.displayText != nil else { return }
            self.setSpokenLength(range.location + range.length)
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
    /// Pass `caption: false` to suppress the caption — useful when the caller shows the
    /// text itself or manages its own interactive Touch Bar that must not be rebuilt.
    func speak(_ text: String, caption: Bool = true) {
        clearTimer?.invalidate()
        if synth.isSpeaking { synth.stopSpeaking() }
        routeOutput()
        synth.startSpeaking(text)
        spokenLength = caption ? 0 : nil
        setDisplayText(caption ? text : nil)
    }

    /// Reports a status message: always captioned, and also spoken when speech is enabled.
    func announce(_ text: String) {
        if VisibilityPreferences.speechEnabled {
            speak(text)
        } else {
            stop()
            setDisplayText(text)   // not spoken: spokenLength stays nil
            scheduleClear(after: 3.5)
        }
    }

    /// Stop any in-progress speech. Clears onFinish and removes the caption immediately.
    func stop() {
        synthDel.onFinish = nil
        clearTimer?.invalidate()
        synth.stopSpeaking()
        setDisplayText(nil)
    }

    // MARK: - Internal

    private static let outputDeviceProperty =
        NSSpeechSynthesizer.SpeechPropertyKey(rawValue: kSpeechOutputToAudioDeviceProperty as String)

    /// Points the synthesizer at the chosen speech device, resolved from its UID on every
    /// utterance since device IDs change across reconnects. 0 means the system sound output.
    private func routeOutput() {
        let deviceID = VisibilityPreferences.speechOutputUID.flatMap(AudioManager.deviceID(forUID:)) ?? 0
        try? synth.setObject(NSNumber(value: deviceID), forProperty: Self.outputDeviceProperty)
    }

    /// Sets the caption. Clearing it also clears spokenLength.
    private func setDisplayText(_ text: String?) {
        if text == nil { spokenLength = nil }
        displayText = text
        onDisplayTextChanged?()
    }

    private func setSpokenLength(_ length: Int) {
        guard spokenLength != length else { return }
        spokenLength = length
        onSpokenLengthChanged?()
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
    /// Fired on the main thread just before each word, with its range in the spoken text.
    var willSpeakWord: ((NSRange) -> Void)?

    func speechSynthesizer(_ sender: NSSpeechSynthesizer,
                            willSpeakWord characterRange: NSRange, of string: String) {
        DispatchQueue.main.async { [weak self] in
            self?.willSpeakWord?(characterRange)
        }
    }

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
