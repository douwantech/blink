import Foundation
import AVFoundation
import Speech
import AppKit

/// 语音听写核心：用 AVCaptureSession + AVCaptureAudioDataOutput 实时采音（AVAudioEngine 的
/// inputNode 在本机给这个 app 的是纯静音缓冲，换成和相机/麦克风 app 同一条、直接对应
/// AVCaptureDevice 授权的采集路径），把音频缓冲边采边喂给 SFSpeechRecognizer 做**流式识别**
/// （边说边出字，进 liveText），松手拿最终文本 →（可选）GLM 润色 → 把文字粘到当前光标处。
final class DictationController: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let shared = DictationController()

    enum Phase: Equatable { case idle, listening, transcribing, done }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveText: String = ""     // 流式识别的实时文字（边说边更新）
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
    private var audioOutput: AVCaptureAudioDataOutput?
    private var isRecording = false
    private var starting = false
    private var doneHideWork: DispatchWorkItem?

    // 流式识别状态（主线程访问）
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var committedText = ""        // 已定稿的段落（分段续跑时累加）
    private var currentPiece = ""         // 当前段的实时 partial
    private var finishing = false         // 松手后等最终结果
    private var didFinalize = false       // 防重复收尾
    private var finalizeGuard: DispatchWorkItem?  // 最终结果迟迟不来的兜底
    private var epoch = 0                  // 段序号：防旧段迟到回调串扰

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
        finalizeGuard?.cancel()
        isError = false
        finalText = ""
        liveText = ""
        committedText = ""
        currentPiece = ""
        finishing = false
        didFinalize = false
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
        // 先起流式识别任务（主线程建 request/task），再起采集把缓冲喂进去。
        guard startRecognition() else {
            starting = false
            showError("本机识别不可用（系统设置→隐私→语音识别，或缺对应语言包）")
            return
        }
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
            let out = AVCaptureAudioDataOutput()
            out.setSampleBufferDelegate(self, queue: self.sessionQueue)
            guard session.canAddOutput(out) else { self.failOnMain("录音输出不可用"); return }
            session.addOutput(out)
            session.startRunning()
            Diag.log("AVCaptureSession 起（流式）：device=\(device.localizedName)")

            self.captureSession = session
            self.audioOutput = out

            DispatchQueue.main.async {
                self.starting = false
                guard self.phase == .listening else {
                    // 起录期间被取消：直接停
                    self.teardownSession()
                    self.abortRecognition()
                    self.hideDone()
                    return
                }
                self.isRecording = true
                self.statusLine = "正在聆听 · 再按一下结束"
            }
        }
    }

    /// AVCaptureAudioDataOutput 实时回调：把音频缓冲喂给流式识别请求。
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        recognitionRequest?.appendAudioSampleBuffer(sampleBuffer)
    }

    private func failOnMain(_ msg: String) {
        DispatchQueue.main.async {
            self.starting = false
            self.teardownSession()
            self.abortRecognition()
            self.showError(msg)
        }
    }

    // MARK: - 流式识别

    /// 建识别器 + 起第一段流式任务。返回 false = 本机识别不可用。
    private func startRecognition() -> Bool {
        let rec = SFSpeechRecognizer(locale: Locale(identifier: localeID)) ?? SFSpeechRecognizer()
        guard let rec, rec.isAvailable else { return false }
        recognizer = rec
        Diag.log("流式识别：locale=\(localeID) onDevice=\(rec.supportsOnDeviceRecognition)")
        startStreamingTask()
        return true
    }

    /// 起一段新的流式任务（request/task 的建立与置空全在 sessionQueue，和采集回调 append 同队列串行，
    /// 避免「endAudio 后再 append」崩溃）。文字状态更新回主线程。epoch 防旧段迟到回调串扰。
    private func startStreamingTask() {
        epoch += 1
        let myEpoch = epoch
        currentPiece = ""
        sessionQueue.async { [weak self] in
            guard let self, let rec = self.recognizer else { return }
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            self.recognitionRequest = req
            self.recognitionTask = rec.recognitionTask(with: req) { [weak self] result, error in
                DispatchQueue.main.async { self?.handle(result: result, error: error, epoch: myEpoch) }
            }
        }
    }

    /// 识别回调（主线程）：更新实时文字；分段收尾并入 committedText；录音中续跑，松手后收尾。
    private func handle(result: SFSpeechRecognitionResult?, error: Error?, epoch: Int) {
        guard epoch == self.epoch else { return }   // 旧段迟到回调，忽略
        if let result {
            let piece = result.bestTranscription.formattedString
            if result.speechRecognitionMetadata != nil || result.isFinal {
                if !piece.isEmpty { committedText += piece }
                currentPiece = ""
                liveText = committedText
                if result.isFinal {
                    if isRecording { startStreamingTask() }        // 段内自动收尾但还在录 → 续新段
                    else if finishing { finalizeStreaming() }      // 松手后的最终段 → 收尾
                }
            } else {
                currentPiece = piece
                liveText = committedText + piece
            }
        } else if error != nil {
            if isRecording {
                if !currentPiece.isEmpty { committedText += currentPiece; currentPiece = "" }
                liveText = committedText
                startStreamingTask()
            } else if finishing {
                finalizeStreaming()
            }
        }
    }

    /// 取消/失败时把识别整个丢掉，不收尾。
    private func abortRecognition() {
        epoch += 1   // 让残留回调作废
        finishing = false
        sessionQueue.async { [weak self] in
            self?.recognitionTask?.cancel()
            self?.recognitionRequest = nil
            self?.recognitionTask = nil
        }
    }

    // MARK: - 结束

    private func finish(cancelled: Bool) {
        guard isRecording else { return }
        isRecording = false
        teardownSession()   // 停采集 → 不再有新缓冲喂进来

        if cancelled {
            abortRecognition()
            hideDone()
            return
        }
        phase = .transcribing
        statusLine = "识别收尾中…"
        finishing = true
        // 停采集后 endAudio，让当前段吐出最终结果（在 sessionQueue，和 append 串行）。
        sessionQueue.async { [weak self] in self?.recognitionRequest?.endAudio() }
        // 兜底：最终结果迟迟不来（1.5s）就用手上已有的文字收尾。
        finalizeGuard?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.finalizeStreaming() }
        finalizeGuard = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    private func teardownSession() {
        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
            self?.captureSession = nil
            self?.audioOutput = nil
        }
    }

    // MARK: - 收尾：最终文本 →（可选）GLM 润色 → 插入

    /// 松手后拿最终识别文本，（可选）交 GLM 润色，再插入光标处。只收尾一次。
    private func finalizeStreaming() {
        guard finishing, !didFinalize else { return }
        didFinalize = true
        finishing = false
        finalizeGuard?.cancel()
        let raw = (committedText + currentPiece).trimmingCharacters(in: .whitespacesAndNewlines)
        abortRecognition()

        guard !raw.isEmpty else { showError("没听到内容"); return }
        Diag.log("流式识别最终：\"\(raw.prefix(60))\"")

        let key = AITextPolisher.shared.apiKey
        guard AITextPolisher.shared.enabled, !key.isEmpty else { commit(raw); return }
        statusLine = "AI 优化中…"
        AITextPolisher.shared.polish(raw) { [weak self] result in
            switch result {
            case .success(let p): self?.commit(p)
            case .failure: self?.commit(raw)
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
