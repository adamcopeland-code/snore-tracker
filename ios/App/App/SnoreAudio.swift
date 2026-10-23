import Foundation
import AVFoundation
import Accelerate

// Audio helpers for SnoreMicPlugin. Nothing here talks to Capacitor.
// Threading: BandAnalyzer and SegmentStore are not thread safe. SnoreMicPlugin only uses them on its serial queue.

/// Computes the same two numbers as AudioInput.read() in index.html, so the SnoreDetector thresholds still match.
///  - db        = 20*log10(RMS of the last 2048 float samples), clamped at -100
///  - bandRatio = energy in 60..1200 Hz / total energy, from a 2048 point FFT.
/// The FFT follows the Web Audio AnalyserNode: Blackman window (alpha 0.16), magnitude divided by the FFT size,
/// smoothing constant 0.2 between frames, bins 1...1023, and bins at or below -200 dB skipped.
final class BandAnalyzer {
    static let size = 2048
    let sampleRate: Double

    private let half = BandAnalyzer.size / 2
    private let log2n = vDSP_Length(11)
    private let setup: FFTSetup
    private let window: [Float]
    private let loBin: Int
    private let hiBin: Int
    private let smoothing: Float = 0.2

    private var ring = [Float](repeating: 0, count: BandAnalyzer.size)
    private var writePos = 0 // index of the oldest sample
    private var windowed = [Float](repeating: 0, count: BandAnalyzer.size)
    private var smoothed = [Float](repeating: 0, count: BandAnalyzer.size / 2)
    private var re = [Float](repeating: 0, count: BandAnalyzer.size / 2)
    private var im = [Float](repeating: 0, count: BandAnalyzer.size / 2)

    init?(sampleRate: Double) {
        guard sampleRate > 0, let s = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2)) else { return nil }
        self.sampleRate = sampleRate
        self.setup = s
        let n = BandAnalyzer.size
        var w = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let x = 2.0 * Double.pi * Double(i) / Double(n)
            w[i] = Float(0.42 - 0.5 * cos(x) + 0.08 * cos(2.0 * x))
        }
        self.window = w
        let binHz = sampleRate / Double(n)
        self.loBin = max(1, Int((60.0 / binHz).rounded(.up)))
        self.hiBin = min(n / 2 - 1, Int((1200.0 / binHz).rounded(.down)))
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func append(_ samples: [Float], _ range: Range<Int>) {
        let n = BandAnalyzer.size
        for i in range {
            ring[writePos] = samples[i]
            writePos += 1
            if writePos == n { writePos = 0 }
        }
    }

    func analyze() -> (db: Float, ratio: Float) {
        let n = BandAnalyzer.size
        var sumSq = 0.0
        for i in 0..<n {
            let v = ring[(writePos + i) & (n - 1)]
            sumSq += Double(v) * Double(v)
            windowed[i] = v * window[i]
        }
        let rms = (sumSq / Double(n)).squareRoot()
        let db: Float = rms > 0 ? Float(max(-100.0, 20.0 * log10(rms))) : -100

        var total = 0.0
        var band = 0.0
        windowed.withUnsafeBufferPointer { wp in
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    // vDSP real FFT output is 2x the DFT, so the magnitude is hypot / (2 * n).
                    // Index 0 packs DC and Nyquist, so start at bin 1 like the web code.
                    for k in 1..<half {
                        let r = Double(rp[k]), i = Double(ip[k])
                        let mag = Float((r * r + i * i).squareRoot() / (2.0 * Double(n)))
                        let s = smoothing * smoothed[k] + (1 - smoothing) * mag
                        smoothed[k] = s
                        let p = Double(s) * Double(s)
                        if p > 1e-20 {
                            total += p
                            if k >= loBin && k <= hiBin { band += p }
                        }
                    }
                }
            }
        }
        return (db, total > 0 ? Float(band / total) : 0)
    }
}

/// A finished audio segment.
struct SegmentInfo {
    let id: Int64        // start time in ms
    let t0: Double       // wall clock ms of the first sample
    let t1: Double       // wall clock ms of the end
    var url: URL
    var kept: Bool
}

enum KeepError: Error { case noSegment }

/// Writes rolling 10 s AAC (.m4a) segments to Documents/segments and keeps a short ring of finished ones.
/// A segment that is kept moves to Documents/clips. Segments that are not kept are deleted.
final class SegmentStore {
    static let segmentSeconds = 10.0
    static let ringSize = 3          // finished, not kept segments held for late keep requests
    static let toleranceMs = 250.0   // slack when matching a timestamp to a segment

    let documents: URL
    let segmentsDir: URL
    let clipsDir: URL
    var onError: ((String) -> Void)?

    private let fm = FileManager.default
    private var sampleRate = 0.0
    private var segFrames = 0
    private var monoFormat: AVAudioFormat?
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var fileT0 = 0.0
    private var fileFrames = 0
    private var finished: [SegmentInfo] = []
    private var pending: [(t: Double, done: (Result<[String: Any], KeepError>) -> Void)] = []

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        documents = docs
        segmentsDir = docs.appendingPathComponent("segments", isDirectory: true)
        clipsDir = docs.appendingPathComponent("clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)
        purgeSegments()
    }

    /// Removes leftover rolling segments, for example after a crash. Kept clips are not touched.
    func purgeSegments() {
        try? fm.removeItem(at: segmentsDir)
        try? fm.createDirectory(at: segmentsDir, withIntermediateDirectories: true)
    }

    /// Call when the input format is known, and again after every engine restart.
    func configure(sampleRate sr: Double) {
        finishCurrent()
        sampleRate = sr
        segFrames = Int(sr * SegmentStore.segmentSeconds)
        monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)
    }

    /// timeMs is the wall clock time of samples[0].
    func append(_ samples: [Float], timeMs: Double) {
        var off = 0
        let n = samples.count
        while off < n {
            if file == nil {
                guard openSegment(t0: timeMs + Double(off) / sampleRate * 1000.0) else { return }
            }
            let take = min(segFrames - fileFrames, n - off)
            guard write(samples, off, take) else { abortCurrent(); return }
            fileFrames += take
            off += take
            if fileFrames >= segFrames { finishCurrent() }
        }
    }

    private func openSegment(t0: Double) -> Bool {
        guard sampleRate > 0, monoFormat != nil else { return false }
        let id = Int64(t0.rounded())
        let url = segmentsDir.appendingPathComponent("seg-\(id).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48000
        ]
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            onError?("Could not open a segment file: \(error.localizedDescription)")
            return false
        }
        fileURL = url
        fileT0 = t0
        fileFrames = 0
        return true
    }

    private func write(_ samples: [Float], _ off: Int, _ count: Int) -> Bool {
        guard let fmt = monoFormat, let f = file,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(count)),
              let dst = buf.floatChannelData?[0] else { return false }
        buf.frameLength = AVAudioFrameCount(count)
        for i in 0..<count { dst[i] = samples[off + i] }
        do {
            try f.write(from: buf)
            return true
        } catch {
            onError?("Could not write audio: \(error.localizedDescription)")
            return false
        }
    }

    private func abortCurrent() {
        file = nil
        if let u = fileURL { try? fm.removeItem(at: u) }
        fileURL = nil
        fileFrames = 0
    }

    /// Closes the current segment, which finalizes the file, and answers waiting keep requests.
    func finishCurrent() {
        guard file != nil, let url = fileURL else { return }
        file = nil // releasing AVAudioFile finalizes the m4a
        let durMs = Double(fileFrames) / sampleRate * 1000.0
        let t0 = fileT0
        fileURL = nil
        fileFrames = 0
        if durMs < 500 {
            try? fm.removeItem(at: url)
        } else {
            finished.append(SegmentInfo(id: Int64(t0.rounded()), t0: t0, t1: t0 + durMs, url: url, kept: false))
        }
        servePending()
        prune()
    }

    /// Resolves with the clip info of the segment that covers time t (ms). A segment still being written
    /// answers when it is finished, at most about 10 s later.
    func requestKeep(t: Double, done: @escaping (Result<[String: Any], KeepError>) -> Void) {
        pending.append((t, done))
        servePending()
    }

    private func servePending() {
        var rest: [(t: Double, done: (Result<[String: Any], KeepError>) -> Void)] = []
        let horizon: Double = file != nil ? fileT0 : (finished.last?.t1 ?? 0)
        for p in pending {
            if let i = finished.firstIndex(where: { p.t >= $0.t0 - SegmentStore.toleranceMs && p.t <= $0.t1 + SegmentStore.toleranceMs }) {
                if let info = keep(at: i) { p.done(.success(info)) } else { p.done(.failure(.noSegment)) }
            } else if p.t < horizon - SegmentStore.toleranceMs {
                p.done(.failure(.noSegment)) // older than everything we hold
            } else {
                rest.append(p)
            }
        }
        pending = rest
    }

    private func keep(at i: Int) -> [String: Any]? {
        var seg = finished[i]
        let name = "clip-\(seg.id).m4a"
        if !seg.kept {
            let dest = clipsDir.appendingPathComponent(name)
            try? fm.removeItem(at: dest)
            do { try fm.moveItem(at: seg.url, to: dest) } catch { return nil }
            seg.url = dest
            seg.kept = true
            finished[i] = seg
        }
        return [
            "path": seg.url.path,
            "rel": "clips/" + name,
            "t0": seg.t0,
            "t1": seg.t1,
            "durationMs": seg.t1 - seg.t0,
            "mime": "audio/mp4"
        ]
    }

    private func prune() {
        var unkept = finished.filter { !$0.kept }
        while unkept.count > SegmentStore.ringSize {
            let old = unkept.removeFirst()
            try? fm.removeItem(at: old.url)
            finished.removeAll { $0.id == old.id && !$0.kept }
        }
    }

    /// Ends the recording: closes the open segment, fails requests that cannot be answered, deletes unkept segments.
    func stopAndFlush() {
        finishCurrent()
        for p in pending { p.done(.failure(.noSegment)) }
        pending = []
        for s in finished where !s.kept { try? fm.removeItem(at: s.url) }
        finished.removeAll { !$0.kept }
        purgeSegments()
    }

    /// Deletes a kept clip. rel looks like "clips/clip-123.m4a". Anything outside Documents/clips is refused.
    @discardableResult
    func deleteClip(rel: String) -> Bool {
        let url = documents.appendingPathComponent(rel)
        finished.removeAll { $0.url.path == url.path }
        return SegmentStore.removeClipFile(rel: rel, documents: documents)
    }

    static func removeClipFile(rel: String, documents: URL) -> Bool {
        let name = (rel as NSString).lastPathComponent
        guard rel == "clips/" + name, !name.contains("..") else { return false }
        let url = documents.appendingPathComponent("clips", isDirectory: true).appendingPathComponent(name)
        do { try FileManager.default.removeItem(at: url); return true } catch { return false }
    }
}
