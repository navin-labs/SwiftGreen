import AppKit
import AVFoundation

/// SwiftGreen's sounds: the ones macOS already ships (/System/Library/Sounds), at full
/// volume, one distinct sound per kind of event (a received notification's Glass rides on its banner), so success and failure are told apart
/// without looking. The system output volume and the Sounds toggle in Settings are the
/// only controls. Keypad digits play real DTMF tones, like a phone's keypad.
enum SGSound {
    enum Cue: Equatable {
        case key(String)    // dialer digit: DTMF
        case sent           // SMS or notification reply sent: Pop
        case transfer       // file transfer complete, either direction: Hero
        case connected      // paired, or the phone connected: Blow
        case failed         // anything failed: Basso

        var systemSound: String? {
            switch self {
            case .key:       return nil
            case .sent:      return "Pop"
            case .transfer:  return "Hero"
            case .connected: return "Blow"
            case .failed:    return "Basso"
            }
        }
    }

    private static let enabledKey = "swiftgreen_sound_enabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// The last cue and when it played. The same cue again within `repeatGap` is
    /// dropped: pairing is followed at once by the connection, and a burst of copies or
    /// notifications should read as one event, not a rattle.
    private static var last: (cue: Cue, at: Date)?
    private static let repeatGap: TimeInterval = 1.5

    /// Main thread.
    static func play(_ cue: Cue) {
        guard isEnabled else { return }
        guard let name = cue.systemSound else {
            if case .key(let d) = cue { DTMF.shared.play(d) }
            return
        }
        if let prev = last, prev.cue == cue, Date().timeIntervalSince(prev.at) < repeatGap { return }
        last = (cue, Date())
        system(name)
    }

    /// The one system sound playing now; a new cue cuts it off, so cues never stack.
    private static var current: NSSound?

    /// A sound from /System/Library/Sounds, at full volume. A missing file plays nothing.
    private static func system(_ name: String) {
        current?.stop()
        guard let sound = NSSound(named: NSSound.Name(name)) else { current = nil; return }
        sound.volume = 1.0
        sound.play()
        current = sound
    }

    /// Standard DTMF: each key is one low (row) and one high (column) tone together,
    /// ~120 ms with a short fade in and out, so it never clicks. Each tone at 0.35, so
    /// the pair peaks at 0.7: clearly audible, never clipping.
    private final class DTMF {
        static let shared = DTMF()
        private static let pairs: [Character: (Double, Double)] = [
            "1": (697, 1209), "2": (697, 1336), "3": (697, 1477),
            "4": (770, 1209), "5": (770, 1336), "6": (770, 1477),
            "7": (852, 1209), "8": (852, 1336), "9": (852, 1477),
            "*": (941, 1209), "0": (941, 1336), "#": (941, 1477),
        ]
        private let engine = AVAudioEngine()
        private let player = AVAudioPlayerNode()
        private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        private let level = 0.35
        private let length = 0.12, fade = 0.008

        init() {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }

        func play(_ digit: String) {
            guard let c = digit.first, let pair = Self.pairs[c] else { return }
            let (low, high) = pair
            let sr = format.sampleRate
            let frames = AVAudioFrameCount(length * sr)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let out = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = frames
            for i in 0..<Int(frames) {
                let t = Double(i) / sr
                let env = min(1, t / fade, (length - t) / fade)
                out[i] = Float((sin(2 * .pi * low * t) + sin(2 * .pi * high * t)) * env * level)
            }
            do {
                if !engine.isRunning { try engine.start() }
                player.scheduleBuffer(buffer, at: nil, options: .interrupts)
                if !player.isPlaying { player.play() }
            } catch {
                // No output device or the engine is busy: feedback is optional, stay silent.
            }
        }
    }
}

/// Rings on the Mac while the phone rings, so a call never sounds like a message.
/// Plays one of the ringtones macOS already ships (the iPhone set: Reflection, Opening…),
/// looped until the call is answered, declined, ends or the phone disconnects.
///
/// ponytail: the tones live in a private framework folder; if a macOS update moves it,
/// the list falls back to the public alert sounds and a missing pick plays nothing.
enum CallRinger {
    static let none = "None"
    private static let key = "swiftgreen_ringtone"
    private static let dirs = ["/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones",
                               "/System/Library/Sounds"]
    // Longer than any carrier's ring; ends a ring whose end never reached the Mac.
    private static let maxRing: TimeInterval = 60

    /// Ringtone file names (no extension), sorted; the first folder that has any wins.
    static let available: [String] = {
        for dir in dirs {
            let all = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasSuffix(".m4r") || $0.hasSuffix(".aiff") }
                .map { ($0 as NSString).deletingPathExtension }
            // Some tones come twice, classic and the newer "-EncoreInfinitum" remaster; keep the remaster.
            let names = all.filter { !all.contains($0 + "-EncoreInfinitum") }
                .sorted { displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending }
            if !names.isEmpty { return names }
        }
        return []
    }()

    static func displayName(_ name: String) -> String {
        name.replacingOccurrences(of: "-EncoreInfinitum", with: "")
    }

    static var selected: String {
        get {
            UserDefaults.standard.string(forKey: key)
                ?? available.first { displayName($0) == "Reflection" } ?? available.first ?? none
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var isOn: Bool { selected != none && url(selected) != nil }

    private static var player: AVAudioPlayer?
    private static var cap: DispatchWorkItem?

    /// Start ringing (main thread). Repeats while already ringing are ignored.
    static func start() {
        guard player == nil, isOn else { return }
        play(selected, loops: -1)
        let work = DispatchWorkItem { stop() }
        cap = work
        DispatchQueue.main.asyncAfter(deadline: .now() + maxRing, execute: work)
    }

    static func stop() {
        cap?.cancel(); cap = nil
        player?.stop(); player = nil
    }

    /// One pass of a ringtone, for choosing in Settings.
    static func preview(_ name: String) {
        stop()
        if name != none { play(name, loops: 0) }
    }

    private static func play(_ name: String, loops: Int) {
        guard let url = url(name), let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.numberOfLoops = loops
        p.play()
        player = p
    }

    private static func url(_ name: String) -> URL? {
        for dir in dirs {
            for ext in ["m4r", "aiff"] {
                let path = "\(dir)/\(name).\(ext)"
                if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }
}
