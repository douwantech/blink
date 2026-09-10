import Foundation
import AVFoundation
import Speech
import AppKit

/// 语音听写核心：苹果 SFSpeechRecognizer 本地实时识别 + AVAudioEngine 录音，
/// 松手（再按一下地球键）后可选走 GLM-ASR 精转 + GLM 润色，最后把文字粘到当前光标处。
/// 识别管线从 iOS 版 VoiceInputView 移植，去掉了 iOS 专有的 AVAudioSession。
final class DictationController: ObservableObject {
    static let shared = DictationController()

    enum Phase: Equatable { case idle, listening, transcribing, done }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveText: String = ""     // 本地实时识别的滚动文字
    @Published private(set) var statusLine: String = ""   // 顶部状态提示
    @Published private(set) var finalText: String = ""    // 最终插入的文字（done 态展示）
    @Published private(set) var isError: Bool = false

    // 识别语言（可在设置里改）。默认中文，识别器不支持时回退。
    private let kLocale = "VoiceKey.locale"
    var localeID: String {
        get { UserDefaults.standard.string(forKey: kLocale) ?? "zh-CN" }
        set { UserDefaults.standard.set(newValue, forKey: kLocale) }
    }

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var committedText = ""
    private var currentPiece = ""
    private var localText = ""
    private var audioFile: AVAudioFile?
    private var audioFileURL: URL?
    private var isRecording = false
    private var doneHideWork: DispatchWorkItem?

    private init() {}

    // MARK: - 对外入口

    /// 地球键 / 快捷键触发：没在录就开始，正在录就结束并转写。
    func toggle() {
        DispatchQueue.main.async {
            if self.isRecording { self.finish(cancelled: false) }
            else { self.start() }
        }
    }

    /// Esc：取消，丢弃这次录音，不插入。
    func cancel() {
        DispatchQueue.main.async {
            if self.isRecording { self.finish(cancelled: true) }
            else { self.hideDone() }
        }
    }

    // MARK: - 开始

    private func start() {
        doneHideWork?.cancel()
        isError = false
        finalText = ""
        liveText = ""
        statusLine = "准备中…"
        phase = .listening

        requestPermissions { [weak self] ok, reason in
            guard let self else { return }
            DispatchQueue.main.async {
                guard ok else {
                    self.showError(reason ?? "没有麦克风 / 语音识别权限")
                    return
                }
                self.beginLocalASR()
            }
        }
    }

    private func requestPermissions(_ done: @escaping (Bool, String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            guard speechStatus == .authorized else {
                done(false, "语音识别未授权（系统设置→隐私→语音识别）"); return
            }
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                guard micGranted else {
                    done(false, "麦克风未授权（系统设置→隐私→麦克风）"); return
                }
                done(true, nil)
            }
        }
    }

    private func beginLocalASR() {
        // 选识别器：优先用户设定的语言，失败回退默认。
        let rec = SFSpeechRecognizer(locale: Locale(identifier: localeID)) ?? SFSpeechRecognizer()
        guard let rec, rec.isAvailable else {
            showError("当前语言的识别器不可用"); return
        }
        recognizer = rec

        committedText = ""
        currentPiece = ""
        localText = ""
        startRecognitionTask()

        let input = audioEngine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { showError("拿不到麦克风输入"); return }

        // 同一路 tap：喂实时识别 + 落一份 WAV（后面走 GLM-ASR 精转）
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voicekey-\(UUID().uuidString).wav")
        audioFileURL = url
        audioFile = try? AVAudioFile(forWriting: url, settings: fmt.settings)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buffer, _ in
            self?.request?.append(buffer)
            try? self?.audioFile?.write(from: buffer)
        }

        audioEngine.prepare()
        do { try audioEngine.start() } catch {
            showError("录音启动失败：\(error.localizedDescription)"); return
        }

        isRecording = true
        phase = .listening
        statusLine = "正在聆听 · 再按一下结束"
    }

    /// 起一段本地识别任务。停顿会让系统把当前段判 final（或报错结束），
    /// 这里把该段文字并入 committedText 后自动续新任务，前面识别的字不丢。
    private func startRecognitionTask() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            req.requiresOnDeviceRecognition = true
        }
        request = req
        currentPiece = ""

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            guard self.request === req else { return }   // 旧任务迟到回调，忽略
            if let result {
                let piece = result.bestTranscription.formattedString
                if result.speechRecognitionMetadata != nil || result.isFinal {
                    if !piece.isEmpty { self.committedText += piece }
                    self.currentPiece = ""
                    self.publishLive(self.committedText)
                    if result.isFinal, self.isRecording { self.restartRecognitionTask() }
                } else {
                    if self.currentPiece.count >= 6, piece.count * 2 < self.currentPiece.count,
                       !self.currentPiece.hasPrefix(piece) {
                        self.committedText += self.currentPiece
                    }
                    self.currentPiece = piece
                    self.publishLive(self.committedText + piece)
                }
            } else if error != nil, self.isRecording {
                if !self.currentPiece.isEmpty {
                    self.committedText += self.currentPiece
                    self.currentPiece = ""
                    self.publishLive(self.committedText)
                }
                self.restartRecognitionTask()
            }
        }
    }

    private func restartRecognitionTask() {
        request?.endAudio()
        task?.cancel()
        task = nil; request = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }
            self.startRecognitionTask()
        }
    }

    private func publishLive(_ s: String) {
        DispatchQueue.main.async {
            self.localText = s
            self.liveText = s
        }
    }

    // MARK: - 结束 → 转写 → 插入

    private func finish(cancelled: Bool) {
        guard isRecording else { return }
        isRecording = false
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        request?.endAudio()
        task?.cancel()
        task = nil; request = nil

        let text = localText.trimmingCharacters(in: .whitespacesAndNewlines)
        let wav = audioFileURL
        audioFile = nil; audioFileURL = nil

        if cancelled {
            if let wav { try? FileManager.default.removeItem(at: wav) }
            hideDone()
            return
        }
        guard !text.isEmpty else {
            if let wav { try? FileManager.default.removeItem(at: wav) }
            showError("没听到内容")
            return
        }

        phase = .transcribing
        statusLine = "转写中…"
        liveText = text
        runOptimize(local: text, wav: wav)
    }

    /// 有录音 + key 就先 GLM-ASR（更准）→ 再 GLM 润色；失败逐级回退到本地文字润色 → 本地原文。
    private func runOptimize(local: String, wav: URL?) {
        let finish: (String) -> Void = { [weak self] out in
            guard let self else { return }
            if let wav { try? FileManager.default.removeItem(at: wav) }
            self.commit(out)
        }
        let polishThen: (String) -> Void = { base in
            let key = AITextPolisher.shared.apiKey
            guard AITextPolisher.shared.enabled, !key.isEmpty else { finish(base); return }
            AITextPolisher.shared.polish(base) { result in
                switch result {
                case .success(let p): finish(p)
                case .failure: finish(base)
                }
            }
        }
        let key = AITextPolisher.shared.apiKey
        if let wav, !key.isEmpty {
            GLMASRClient.transcribe(fileURL: wav, apiKey: key) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let asr) where !asr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                        polishThen(asr)
                    default:
                        polishThen(local)
                    }
                }
            }
        } else {
            polishThen(local)
        }
    }

    /// 最终文字：记进历史（喂给润色器学习）→ 粘到当前光标处 → done 态短暂展示后隐藏。
    private func commit(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { showError("没听到内容"); return }
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
