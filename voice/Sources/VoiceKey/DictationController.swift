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
    private var starting = false   // start() 到拿到权限回调之间的过渡态，防重入
    private var doneHideWork: DispatchWorkItem?

    private init() {}

    // MARK: - 对外入口

    /// 地球键 / 快捷键触发：没在录就开始，正在录就结束并转写。
    func toggle() {
        DispatchQueue.main.async {
            if self.isRecording { self.finish(cancelled: false) }
            else if self.starting { return }   // 正在起（等权限回调），别重入起第二套引擎
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
                self.starting = false
                guard ok else {
                    self.showError(reason ?? "没有麦克风 / 语音识别权限")
                    return
                }
                guard self.phase == .listening, !self.isRecording else { return }  // 期间被取消/已在录就别再起
                self.beginLocalASR()
            }
        }
    }

    private func requestPermissions(_ done: @escaping (Bool, String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            Diag.log("语音识别授权 = \(speechStatus.rawValue)（3=authorized）")
            guard speechStatus == .authorized else {
                done(false, "语音识别未授权（系统设置→隐私→语音识别）"); return
            }
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                Diag.log("麦克风授权 = \(micGranted)")
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
        Diag.log("beginLocalASR：inputFormat sampleRate=\(fmt.sampleRate) ch=\(fmt.channelCount)")
        guard fmt.sampleRate > 0 else { showError("拿不到麦克风输入"); return }

        // 同一路 tap：原始 buffer 直接喂实时识别 + 原样落 WAV（麦克风原格式，别在实时音频
        // 线程上做采样率/声道转换——AVAudioConverter 在 RT 线程会崩）。单声道转换等录完离线做。
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
            Diag.log("audioEngine.start 失败：\(error.localizedDescription)")
            showError("录音启动失败：\(error.localizedDescription)"); return
        }
        Diag.log("录音已开始，WAV=\(url.lastPathComponent)")

        isRecording = true
        phase = .listening
        statusLine = "正在聆听 · 再按一下结束"
    }

    /// 用系统 afconvert 把录音离线转成 16k 单声道 16-bit WAV（GLM-ASR 只收单声道）。
    /// 离线跑、不在实时音频线程，稳。失败返回 nil，调用方回退用原文件。
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

    /// 起一段本地识别任务。停顿会让系统把当前段判 final（或报错结束），
    /// 这里把该段文字并入 committedText 后自动续新任务，前面识别的字不丢。
    private func startRecognitionTask() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // 不强制 on-device：macOS 上中文本地模型常没就绪，硬走 on-device 会一个字都不出。
        // 让苹果自己挑（有网就云端），实在不行还有 GLM-ASR 兜底。
        Diag.log("recognitionTask 起：locale=\(localeID) onDeviceSupported=\(recognizer?.supportsOnDeviceRecognition ?? false)")
        request = req
        currentPiece = ""

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            guard self.request === req else { return }   // 旧任务迟到回调，忽略
            if let error, self.currentPiece.isEmpty, self.committedText.isEmpty {
                Diag.log("识别回调 error（暂无文字）：\(error.localizedDescription)")
            }
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

        let wavSize = wav.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size]) as? Int } ?? 0
        let key = AITextPolisher.shared.apiKey
        Diag.log("finish：cancelled=\(cancelled) 本地文字=\"\(text.prefix(40))\"(\(text.count)) WAV=\(wavSize)B GLMkey=\(key.isEmpty ? "无" : "有")")

        if cancelled {
            if let wav { try? FileManager.default.removeItem(at: wav) }
            hideDone()
            return
        }

        // 本地没识别出文字时：只要录到了真实音频 + 有 GLM key，照样送 GLM-ASR 兜底，别直接判「没内容」。
        let haveAudio = wavSize > 8000   // 44 字节头 + 一点点采样都算不上，8KB≈几百 ms
        if text.isEmpty && !(haveAudio && !key.isEmpty) {
            if let wav { try? FileManager.default.removeItem(at: wav) }
            showError(haveAudio ? "没听到内容（填 GLM key 可提升识别）" : "没听到内容")
            return
        }

        phase = .transcribing
        statusLine = text.isEmpty ? "转写中（GLM）…" : "转写中…"
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
            let b = base.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !b.isEmpty else { finish(""); return }   // 空串绝不润色，交给 commit 报「没内容」
            let key = AITextPolisher.shared.apiKey
            guard AITextPolisher.shared.enabled, !key.isEmpty else { finish(b); return }
            AITextPolisher.shared.polish(b) { result in
                switch result {
                case .success(let p): finish(p)
                case .failure: finish(b)
                }
            }
        }
        let key = AITextPolisher.shared.apiKey
        if let wav, !key.isEmpty {
            // 离线转单声道（afconvert）再上传，别在实时线程转。
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
                        case .success(let asr):
                            Diag.log("GLM-ASR 返回空（\"\(asr)\"），回退本地文字=\"\(local.prefix(30))\"")
                            polishThen(local)
                        case .failure(let e):
                            Diag.log("GLM-ASR 失败：\(e.localizedDescription)，回退本地文字=\"\(local.prefix(30))\"")
                            polishThen(local)
                        }
                    }
                }
            }
        } else {
            polishThen(local)
        }
    }

    /// 最终文字：记进历史（喂给润色器学习）→ 粘到当前光标处 → done 态短暂展示后隐藏。
    private func commit(_ text: String) {
        // 防御：万一润色模型回吐了 <asr> 包裹标签，剥掉。
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
