import Foundation
import AVFoundation
import Speech
import AppKit

/// 语音听写核心：用 AVCaptureSession + AVCaptureAudioFileOutput 录音（AVAudioEngine 的
/// inputNode 在本机给这个 app 的是纯静音缓冲，换成和相机/麦克风 app 同一条、直接对应
/// AVCaptureDevice 授权的采集路径），录完 afconvert 转 16k 单声道 → GLM-ASR 精转 → GLM
/// 润色 → 把文字粘到当前光标处。
final class DictationController: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    static let shared = DictationController()

    enum Phase: Equatable { case idle, listening, transcribing, done }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveText: String = ""     // 展示用（本方案无实时识别，转写完才有）
    @Published private(set) var statusLine: String = ""
    @Published private(set) var finalText: String = ""
    @Published private(set) var isError: Bool = false

    // 识别语言（GLM-ASR 自动判语种，这里保留给设置页/未来本地识别用）。
    private let kLocale = "VoiceKey.locale"
    var localeID: String {
        get { UserDefaults.standard.string(forKey: kLocale) ?? "zh-CN" }
        set { UserDefaults.standard.set(newValue, forKey: kLocale) }
    }

    // 输入设备。空=自动（跳过 BlackHole 这类虚拟环回，选真麦克风）。
    private let kInputUID = "VoiceKey.inputUID"
    var selectedInputUID: String {
        get { UserDefaults.standard.string(forKey: kInputUID) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: kInputUID) }
    }

    /// 所有可选输入设备（给设置页列）。
    static func inputDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified).devices
    }

    /// 虚拟/环回声卡（BlackHole、Loopback、聚合设备等），录不到真人声，自动跳过。
    static func isVirtualDevice(_ d: AVCaptureDevice) -> Bool {
        let n = d.localizedName.lowercased()
        return ["blackhole", "loopback", "aggregate", "多输出", "multi-output",
                "soundflower", "vb-audio", "vb-cable", "virtual", "zoom", "ishowu",
                "聚合", "krisp"].contains { n.contains($0) }
    }

    /// 选录音设备：优先用户在设置里选的；否则自动挑第一个「非虚拟」的真麦克风。
    private func pickInputDevice() -> AVCaptureDevice? {
        let all = Self.inputDevices()
        if !selectedInputUID.isEmpty, let d = all.first(where: { $0.uniqueID == selectedInputUID }) {
            return d
        }
        let real = all.filter { !Self.isVirtualDevice($0) }
        // 优先内建麦（最稳；iPhone Continuity 会断、蓝牙耳机时好时坏）
        if let builtin = real.first(where: {
            let n = $0.localizedName.lowercased()
            return n.contains("macbook") || n.contains("built-in") || n.contains("内建") || n.contains("内置") || n.contains("imac")
        }) { return builtin }
        return real.first ?? all.first ?? AVCaptureDevice.default(for: .audio)
    }

    private let sessionQueue = DispatchQueue(label: "voicekey.capture")
    private var captureSession: AVCaptureSession?
    private var fileOutput: AVCaptureAudioFileOutput?
    private var captureURL: URL?
    private var pendingCancel = false
    private var isRecording = false
    private var starting = false
    private var doneHideWork: DispatchWorkItem?

    private override init() { super.init() }

    // MARK: - 对外入口

    func toggle() {
        DispatchQueue.main.async {
            if self.isRecording { self.finish(cancelled: false) }
            else if self.starting { return }
            else { self.start() }
        }
    }

    func cancel() {
        DispatchQueue.main.async {
            if self.isRecording { self.finish(cancelled: true) }
            else { self.hideDone() }
        }
    }

    // MARK: - 开始

    private func start() {
        guard !starting, !isRecording else { return }
        starting = true
        doneHideWork?.cancel()
        isError = false
        finalText = ""
        liveText = ""
        statusLine = "准备中…"
        phase = .listening

        requestPermissions { [weak self] ok, reason in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.starting else { return }
                guard ok else {
                    self.starting = false
                    self.showError(reason ?? "没有麦克风权限")
                    return
                }
                guard self.phase == .listening else { self.starting = false; return }
                self.beginCapture()
            }
        }
    }

    private func requestPermissions(_ done: @escaping (Bool, String?) -> Void) {
        // 语音识别权限尽量拿（本地识别用；没有也不挡 GLM），麦克风是硬要求。
        SFSpeechRecognizer.requestAuthorization { s in
            Diag.log("语音识别授权 = \(s.rawValue)")
        }
        AVCaptureDevice.requestAccess(for: .audio) { micGranted in
            Diag.log("麦克风授权 = \(micGranted)")
            done(micGranted, micGranted ? nil : "麦克风未授权（系统设置→隐私→麦克风）")
        }
    }

    private func beginCapture() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let session = AVCaptureSession()
            guard let device = self.pickInputDevice() else {
                self.failOnMain("拿不到麦克风设备"); return
            }
            if Self.isVirtualDevice(device) {
                Diag.log("⚠️ 选中的是虚拟设备 \(device.localizedName)，可能录不到人声")
            }
            guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                self.failOnMain("麦克风无法接入"); return
            }
            session.addInput(input)
            let out = AVCaptureAudioFileOutput()
            guard session.canAddOutput(out) else { self.failOnMain("录音输出不可用"); return }
            session.addOutput(out)
            session.startRunning()

            let types = AVCaptureAudioFileOutput.availableOutputFileTypes()
            let ftype: AVFileType = types.contains(.aiff) ? .aiff : (types.contains(.m4a) ? .m4a : (types.first ?? .aiff))
            let ext = (ftype == .aiff) ? "aiff" : (ftype == .m4a ? "m4a" : "caf")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("voicekey-\(UUID().uuidString).\(ext)")
            Diag.log("AVCaptureSession 起：device=\(device.localizedName) type=\(ftype.rawValue)")

            self.captureSession = session
            self.fileOutput = out
            self.captureURL = url
            out.startRecording(to: url, outputFileType: ftype, recordingDelegate: self)

            DispatchQueue.main.async {
                self.starting = false
                guard self.phase == .listening else {
                    // 起录期间被取消：直接停
                    self.pendingCancel = true
                    out.stopRecording()
                    return
                }
                self.isRecording = true
                self.statusLine = "正在聆听 · 再按一下结束"
            }
        }
    }

    private func failOnMain(_ msg: String) {
        DispatchQueue.main.async {
            self.starting = false
            self.teardownSession()
            self.showError(msg)
        }
    }

    // MARK: - 结束

    private func finish(cancelled: Bool) {
        guard isRecording else { return }
        isRecording = false
        pendingCancel = cancelled
        if !cancelled {
            phase = .transcribing
            statusLine = "转写中（GLM）…"
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let out = self.fileOutput, out.isRecording {
                out.stopRecording()   // → didFinishRecordingTo
            } else {
                DispatchQueue.main.async {
                    if cancelled { self.hideDone() } else { self.showError("没录到音频") }
                }
            }
        }
    }

    // AVCaptureAudioFileOutput 录完回调（stopRecording 后触发）。
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        teardownSession()
        let size = (try? FileManager.default.attributesOfItem(atPath: outputFileURL.path)[.size]) as? Int ?? 0
        let peak = Self.peakLevel(outputFileURL)
        // AVCapture 常在正常结束时也带一个 error（含 RecordingSuccessfullyFinished），文件有内容就当成功。
        Diag.log("录完：size=\(size)B 峰值=\(String(format: "%.4f", peak)) err=\(error?.localizedDescription ?? "无")")

        DispatchQueue.main.async {
            let key = AITextPolisher.shared.apiKey
            if self.pendingCancel {
                try? FileManager.default.removeItem(at: outputFileURL)
                self.hideDone(); return
            }
            guard size > 4000 else {
                try? FileManager.default.removeItem(at: outputFileURL)
                self.showError("没录到音频"); return
            }
            guard !key.isEmpty else {
                try? FileManager.default.removeItem(at: outputFileURL)
                self.showError("请在设置里填 GLM key"); return
            }
            self.phase = .transcribing
            self.statusLine = "转写中（GLM）…"
            self.runOptimize(local: "", wav: outputFileURL)
        }
    }

    private func teardownSession() {
        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
            self?.captureSession = nil
            self?.fileOutput = nil
            self?.captureURL = nil
        }
    }

    // MARK: - 转写 → 插入

    /// afconvert 转 16k 单声道 → GLM-ASR → GLM 润色 → 插入。
    private func runOptimize(local: String, wav: URL?) {
        let done: (String) -> Void = { [weak self] out in
            guard let self else { return }
            if let wav { try? FileManager.default.removeItem(at: wav) }
            self.commit(out)
        }
        let polishThen: (String) -> Void = { base in
            let b = base.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !b.isEmpty else { done(""); return }
            let key = AITextPolisher.shared.apiKey
            guard AITextPolisher.shared.enabled, !key.isEmpty else { done(b); return }
            AITextPolisher.shared.polish(b) { result in
                switch result {
                case .success(let p): done(p)
                case .failure: done(b)
                }
            }
        }
        let key = AITextPolisher.shared.apiKey
        guard let wav, !key.isEmpty else { polishThen(local); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let mono = Self.convertToMono(wav)
            let upload = mono ?? wav
            GLMASRClient.transcribe(fileURL: upload, apiKey: key) { result in
                DispatchQueue.main.async {
                    if let mono { try? FileManager.default.removeItem(at: mono) }
                    switch result {
                    case .success(let asr) where !asr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                        Diag.log("GLM-ASR 成功：\"\(asr.prefix(60))\"")
                        polishThen(asr)
                    case .success:
                        Diag.log("GLM-ASR 返回空")
                        polishThen(local)
                    case .failure(let e):
                        Diag.log("GLM-ASR 失败：\(e.localizedDescription)")
                        polishThen(local)
                    }
                }
            }
        }
    }

    private func commit(_ text: String) {
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        clean = clean.replacingOccurrences(of: "<asr>", with: "").replacingOccurrences(of: "</asr>", with: "")
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { showError("没听到内容"); return }
        Diag.log("最终插入：\"\(clean.prefix(60))\"")
        AITextPolisher.shared.recordHistory(clean)
        DispatchQueue.main.async {
            self.finalText = clean
            self.phase = .done
            self.statusLine = "已插入"
            self.isError = false
            TextInserter.insert(clean)
            self.scheduleHideDone(after: 1.4)
        }
    }

    // MARK: - 工具

    /// 用系统 afconvert 把录音离线转成 16k 单声道 16-bit WAV（GLM-ASR 只收单声道）。
    private static func convertToMono(_ src: URL) -> URL? {
        let dst = src.deletingPathExtension().appendingPathExtension("mono.wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", src.path, dst.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch {
            Diag.log("afconvert 起失败：\(error.localizedDescription)"); return nil
        }
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: dst.path) else {
            Diag.log("afconvert 失败 status=\(p.terminationStatus)"); return nil
        }
        return dst
    }

    /// 读录音峰值（诊断用）。
    private static func peakLevel(_ url: URL) -> Float {
        guard let f = try? AVAudioFile(forReading: url) else { return -1 }
        let fmt = f.processingFormat
        let frames = AVAudioFrameCount(f.length)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return -2 }
        do { try f.read(into: buf) } catch { return -3 }
        guard let ch = buf.floatChannelData else { return -4 }
        var peak: Float = 0
        let n = Int(buf.frameLength)
        for c in 0..<Int(fmt.channelCount) {
            let p = ch[c]
            for i in 0..<n { peak = max(peak, abs(p[i])) }
        }
        return peak
    }

    // MARK: - 收尾 / 错误

    private func showError(_ msg: String) {
        Diag.log("showError：\(msg)")
        DispatchQueue.main.async {
            self.isRecording = false
            self.isError = true
            self.phase = .done
            self.statusLine = msg
            self.scheduleHideDone(after: 2.2)
        }
    }

    private func scheduleHideDone(after: TimeInterval) {
        doneHideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.hideDone() }
        doneHideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: w)
    }

    private func hideDone() {
        doneHideWork?.cancel()
        phase = .idle
        liveText = ""
        statusLine = ""
        isError = false
    }
}
