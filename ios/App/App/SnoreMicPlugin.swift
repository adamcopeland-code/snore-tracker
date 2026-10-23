import Foundation
import AVFoundation
import UIKit
import os
import Capacitor

/// Native microphone for Snore Tracker. It owns the audio session and the AVAudioEngine input tap, so recording
/// keeps going while the screen is locked (UIBackgroundModes = audio).
///
/// JS name: "SnoreMic"
///  start({ record: Bool })       -> { sampleRate, seq, documents }
///  stop()
///  keepSegment({ t })            -> { path, rel, t0, t1, durationMs, mime }
///  deleteClip({ rel })
///  getFrames({ after, max })     -> { frames: [[seq, t, db, bandRatio], ...], last }
///  getInfo()                     -> { documents }
/// Events:
///  "frame"  { seq, t, db, bandRatio }   every 100 ms while recording (record: true)
///  "level"  { t, db }                   every 100 ms for the Settings mic test (record: false)
///  "status" { type, detail, t }         interruptions, route changes, restarts, errors
///
/// Every frame is also kept in memory (about 13 hours), so JS can fetch the frames it missed with getFrames()
/// if the web view was paused while the screen was locked.
@objc(SnoreMicPlugin)
public class SnoreMicPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "SnoreMicPlugin"
    public let jsName = "SnoreMic"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "keepSegment", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "deleteClip", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getFrames", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getInfo", returnType: CAPPluginReturnPromise)
    ]

    private struct Frame {
        let seq: Int
        let t: Double
        let db: Double
        let ratio: Double
    }

    private enum MicError: LocalizedError {
        case noInput
        case noAnalyzer
        var errorDescription: String? {
            switch self {
            case .noInput: return "No microphone input is available."
            case .noAnalyzer: return "Could not set up the audio analysis."
            }
        }
    }

    private static let maxFrames = 500_000   // about 13.9 hours at 10 frames per second
    private static let trimSlack = 5_000

    private let log = Logger(subsystem: "com.adamcopeland.snoretracker", category: "SnoreMic")

    // Everything below is touched only on `q`.
    private let q = DispatchQueue(label: "com.adamcopeland.snoretracker.mic")
    private var running = false
    private var recordMode = true
    private var interrupted = false
    private var restartScheduled = false
    private var generation = 0
    private var engine: AVAudioEngine?
    private var analyzer: BandAnalyzer?
    private var store: SegmentStore?
    private var observers: [NSObjectProtocol] = []
    private var watchdog: DispatchSourceTimer?
    private var lastBufferAt = CFAbsoluteTimeGetCurrent()

    private var seq = 0
    private var firstSeq = 1
    private var frames: [Frame] = []
    private var hop = 0
    private var sinceFrame = 0
    private var samplesTotal = 0
    private var anchored = false
    private var anchorMs = 0.0
    private var lastT = 0.0

    private var documentsURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    // MARK: - Plugin methods

    @objc func start(_ call: CAPPluginCall) {
        let record = call.getBool("record", true)
        requestMicPermission { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                call.reject("Microphone permission was denied.", "permission_denied")
                return
            }
            self.q.async { self.doStart(record: record, call: call) }
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        q.async {
            self.doStop()
            call.resolve()
        }
    }

    @objc func keepSegment(_ call: CAPPluginCall) {
        guard let t = call.getDouble("t") else {
            call.reject("Missing t.", "bad_args")
            return
        }
        q.async {
            guard let store = self.store else {
                call.reject("Not recording.", "not_recording")
                return
            }
            store.requestKeep(t: t) { result in
                switch result {
                case .success(let info): call.resolve(info)
                case .failure: call.reject("No audio segment covers that time.", "no_segment")
                }
            }
        }
    }

    @objc func deleteClip(_ call: CAPPluginCall) {
        guard let rel = call.getString("rel") else {
            call.reject("Missing rel.", "bad_args")
            return
        }
        q.async {
            let ok = self.store?.deleteClip(rel: rel) ?? SegmentStore.removeClipFile(rel: rel, documents: self.documentsURL)
            call.resolve(["deleted": ok])
        }
    }

    @objc func getFrames(_ call: CAPPluginCall) {
        let after = call.getInt("after", 0)
        let maxN = min(max(call.getInt("max", 5000), 1), 20000)
        q.async {
            let startSeq = max(after + 1, self.firstSeq)
            let startIdx = startSeq - self.firstSeq
            var out: [[Any]] = []
            if startIdx >= 0 && startIdx < self.frames.count {
                let end = min(self.frames.count, startIdx + maxN)
                out.reserveCapacity(end - startIdx)
                for f in self.frames[startIdx..<end] { out.append([f.seq, f.t, f.db, f.ratio]) }
            }
            call.resolve(["frames": out, "last": self.seq])
        }
    }

    @objc func getInfo(_ call: CAPPluginCall) {
        call.resolve(["documents": documentsURL.path])
    }

    // MARK: - Start and stop

    private func requestMicPermission(_ done: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { done($0) }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { done($0) }
        }
    }

    private func doStart(record: Bool, call: CAPPluginCall) {
        if running {
            call.reject("The microphone is already running.", "already_running")
            return
        }
        recordMode = record
        interrupted = false
        frames.removeAll()
        firstSeq = seq + 1
        lastT = 0
        do {
            try configureSession()
            if record {
                let s = SegmentStore()
                s.onError = { [weak self] msg in self?.emitStatus("recorderError", msg) }
                s.purgeSegments()
                store = s
            }
            try startEngine()
        } catch {
            log.error("start failed: \(error.localizedDescription, privacy: .public)")
            teardownEngine()
            store?.stopAndFlush()
            store = nil
            deactivateSession()
            call.reject(error.localizedDescription, "start_failed")
            return
        }
        running = true
        addObservers()
        startWatchdog()
        setIdleTimerDisabled(true)
        let sr = analyzer?.sampleRate ?? 0
        log.notice("started, record=\(record), sampleRate=\(sr)")
        call.resolve(["sampleRate": sr, "seq": seq, "documents": documentsURL.path])
    }

    private func doStop() {
        let wasRunning = running
        running = false
        removeObservers()
        watchdog?.cancel()
        watchdog = nil
        teardownEngine()
        store?.stopAndFlush()
        store = nil
        analyzer = nil
        if wasRunning { deactivateSession() }
        setIdleTimerDisabled(false)
        if wasRunning { log.notice("stopped") }
    }

    private func configureSession() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetooth])
        try s.setActive(true)
    }

    /// Leaves the session in a plain playback state, so clips play normally in the web view afterwards.
    private func deactivateSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setActive(false, options: .notifyOthersOnDeactivation)
        try? s.setCategory(.playback, mode: .default, options: [])
    }

    private func setIdleTimerDisabled(_ on: Bool) {
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = on }
    }

    // MARK: - Engine and tap

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicError.noInput }
        guard let an = BandAnalyzer(sampleRate: format.sampleRate) else { throw MicError.noAnalyzer }

        analyzer = an
        hop = max(1, Int((format.sampleRate * 0.1).rounded()))
        sinceFrame = 0
        samplesTotal = 0
        anchored = false
        store?.configure(sampleRate: format.sampleRate)

        generation += 1
        let gen = generation
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self = self, let ch = buffer.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
            let arrival = Date().timeIntervalSince1970 * 1000.0
            self.q.async { self.process(samples, arrival: arrival, generation: gen) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        lastBufferAt = CFAbsoluteTimeGetCurrent()
    }

    private func teardownEngine() {
        generation += 1 // buffers from the old tap are ignored
        if let e = engine {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }
        engine = nil
        store?.finishCurrent()
    }

    /// Runs on `q`. One tap buffer in; zero or more 100 ms frames out.
    private func process(_ samples: [Float], arrival: Double, generation gen: Int) {
        guard running, gen == generation, let an = analyzer else { return }
        let n = samples.count
        guard n > 0 else { return }
        let sr = an.sampleRate
        lastBufferAt = CFAbsoluteTimeGetCurrent()

        if !anchored {
            anchorMs = arrival - Double(n) / sr * 1000.0
            anchored = true
        }
        let bufferStartMs = anchorMs + Double(samplesTotal) / sr * 1000.0
        if recordMode { store?.append(samples, timeMs: bufferStartMs) }

        var i = 0
        while i < n {
            let take = min(hop - sinceFrame, n - i)
            an.append(samples, i..<(i + take))
            i += take
            sinceFrame += take
            samplesTotal += take
            if sinceFrame == hop {
                sinceFrame = 0
                let wall = arrival - Double(n - i) / sr * 1000.0
                emitFrame(an, wall: wall, sampleRate: sr)
            }
        }
    }

    private func emitFrame(_ an: BandAnalyzer, wall: Double, sampleRate sr: Double) {
        var t = anchorMs + Double(samplesTotal) / sr * 1000.0
        if abs(t - wall) > 500 { // the audio clock drifted from the wall clock: re-anchor
            anchorMs += wall - t
            t = wall
        }
        if t <= lastT { t = lastT + 1 }
        lastT = t

        let r = an.analyze()
        let db = (Double(r.db) * 100).rounded() / 100
        let ratio = (Double(r.ratio) * 10000).rounded() / 10000
        seq += 1

        if recordMode {
            frames.append(Frame(seq: seq, t: t, db: db, ratio: ratio))
            if frames.count > SnoreMicPlugin.maxFrames + SnoreMicPlugin.trimSlack {
                let drop = frames.count - SnoreMicPlugin.maxFrames
                frames.removeFirst(drop)
                firstSeq += drop
            }
            notifyListeners("frame", data: ["seq": seq, "t": t, "db": db, "bandRatio": ratio])
        } else {
            notifyListeners("level", data: ["t": t, "db": db])
        }
    }

    // MARK: - Interruptions, route changes, restarts

    private func addObservers() {
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] n in
            self?.onInterruption(n)
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] n in
            self?.onRouteChange(n)
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            self?.q.async {
                self?.log.error("media services were reset")
                self?.emitStatus("mediaServicesReset", "")
                self?.scheduleRestart("media services reset")
            }
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] _ in
            self?.q.async {
                self?.log.notice("engine configuration changed")
                self?.emitStatus("configurationChange", "")
                self?.scheduleRestart("engine configuration change")
            }
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.q.async {
                guard let self = self, self.running, !(self.engine?.isRunning ?? false) else { return }
                self.scheduleRestart("app became active with a stopped engine")
            }
        })
    }

    private func removeObservers() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
    }

    private func onInterruption(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        let optRaw = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume)
        q.async {
            guard self.running else { return }
            switch type {
            case .began:
                self.interrupted = true
                self.log.notice("interruption began")
                self.emitStatus("interruptionBegan", "")
            case .ended:
                self.interrupted = false
                self.log.notice("interruption ended, shouldResume=\(shouldResume)")
                self.emitStatus("interruptionEnded", shouldResume ? "shouldResume" : "")
                self.scheduleRestart("interruption ended")
            @unknown default:
                break
            }
        }
    }

    private func onRouteChange(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        let input = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "none"
        q.async {
            guard self.running else { return }
            self.log.notice("route change, reason=\(raw), input=\(input, privacy: .public)")
            self.emitStatus("routeChange", "reason=\(raw) input=\(input)")
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable, .override, .routeConfigurationChange:
                self.scheduleRestart("route change \(raw)")
            case .categoryChange:
                // Our own setCategory also lands here. Only restart if something else changed the category.
                if AVAudioSession.sharedInstance().category != .playAndRecord { self.scheduleRestart("category changed") }
            default:
                break
            }
        }
    }

    /// Debounced restart of the tap. Bursts of notifications cause one restart.
    private func scheduleRestart(_ reason: String) {
        guard running, !restartScheduled else { return }
        restartScheduled = true
        q.asyncAfter(deadline: .now() + 0.4) {
            self.restartScheduled = false
            self.restartEngine(reason)
        }
    }

    private func restartEngine(_ reason: String) {
        guard running else { return }
        log.notice("restarting the input tap: \(reason, privacy: .public)")
        teardownEngine()
        do {
            try configureSession()
            try startEngine()
            emitStatus("restarted", reason)
        } catch {
            // The watchdog tries again in a few seconds, for example while a phone call is still active.
            log.error("restart failed: \(error.localizedDescription, privacy: .public)")
            emitStatus("restartFailed", error.localizedDescription)
        }
    }

    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self = self, self.running else { return }
            let idle = CFAbsoluteTimeGetCurrent() - self.lastBufferAt
            if idle > (self.interrupted ? 30.0 : 4.0) {
                self.log.error("no audio for \(Int(idle)) s")
                self.scheduleRestart("no audio for \(Int(idle)) s")
            }
        }
        t.resume()
        watchdog = t
    }

    private func emitStatus(_ type: String, _ detail: String) {
        notifyListeners("status", data: ["type": type, "detail": detail, "t": Date().timeIntervalSince1970 * 1000.0])
    }
}
