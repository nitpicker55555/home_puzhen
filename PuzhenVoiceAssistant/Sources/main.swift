import Foundation
import AppKit
import AVFoundation
import Speech

// ============================================================================
// Puzhen Voice Assistant — a native macOS menu-bar voice assistant.
//
//  • Wake word .............. Apple Speech framework (SFSpeechRecognizer)
//  • Speech-to-text ......... Apple Speech framework
//  • LLM .................... AiHubMix (OpenAI-compatible, streaming)
//  • Text-to-speech ......... Apple AVSpeechSynthesizer  (built-in voices)
//  • Chime / audio .......... NSSound (built-in system sounds)
//
//  Say "puzhen puzhen" -> chime -> ask your question -> spoken answer.
// ============================================================================

// MARK: - Small helpers

func env(_ key: String, _ fallback: String) -> String {
    if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return v }
    return fallback
}

/// True if the string contains any CJK (Chinese) character.
func containsCJK(_ s: String) -> Bool {
    for u in s.unicodeScalars {
        switch u.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2A6DF:
            return true
        default:
            continue
        }
    }
    return false
}

func logLine(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

/// Loads KEY=VALUE pairs from a local `.env` file into the environment so the
/// app works both from the terminal and when double-clicked. Real environment
/// variables always win; the first `.env` found is used. The file is never
/// committed (see .gitignore).
func loadDotEnv() {
    var paths: [String] = []
    if let p = ProcessInfo.processInfo.environment["AIHUBMIX_ENV_FILE"], !p.isEmpty { paths.append(p) }
    paths.append(FileManager.default.currentDirectoryPath + "/.env")
    paths.append(("~/.puzhen-assistant.env" as NSString).expandingTildeInPath)
    paths.append(("~/.config/puzhen-assistant/.env" as NSString).expandingTildeInPath)

    for path in paths {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        for raw in content.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if val.count >= 2,
               (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                val = String(val.dropFirst().dropLast())
            }
            if !key.isEmpty { setenv(key, val, 0) }   // 0 = never override a real env var
        }
        logLine("🔑 已从 \(path) 读取配置")
        return
    }
}

// MARK: - Configuration (all overridable via environment variables)

enum Config {
    // The API key is read from the environment (or a local .env file loaded at
    // launch). It is NEVER hardcoded here, so the source is safe to commit.
    static let apiKey  = env("AIHUBMIX_API_KEY",  "")
    static let baseURL = env("AIHUBMIX_BASE_URL", "https://aihubmix.com/v1")
    // A fast, low-latency model (verified working on AiHubMix).
    // Alternatives: gemini-2.5-flash, gpt-4o-mini, qwen-turbo, deepseek-chat.
    static let model   = env("ASSISTANT_MODEL",   "gpt-4.1-nano")
    // Speech-recognition locale. zh-CN works best for the Chinese name "普真".
    // Use en-US if you speak to it mostly in English.
    static let locale  = env("ASSISTANT_LOCALE",  "zh-CN")
    // Optional: force a TTS voice language (e.g. zh-CN or en-US). Empty = auto.
    static let voiceOverride = env("ASSISTANT_VOICE", "")

    static let systemPrompt = """
    你是 Puzhen（普真）的私人语音助手。用户通过语音和你交流，你的回答会被立刻朗读出来。
    要求：回答要简洁、口语化、自然，一般只用 1 到 3 句话；不要使用 Markdown、编号列表、\
    代码块或表情符号，因为这些不适合朗读。默认用中文回答，除非用户明显在用其他语言提问。
    """

    // Wake-word matching. The English regex covers common ways Apple's
    // recognizer transcribes "puzhen": puzhen / pu zhen / pujen / puchen ...
    static let wakeRegex = "pu\\s*(zh|j|ch|z|sh)e?n"
    // Chinese candidate spellings (recognizer output for 普真 varies).
    static let chineseWake = ["普真普真", "普真", "普珍", "菩真", "布真", "不真", "普震", "浦真", "普阵"]
}

// MARK: - Wake-word utilities

func containsWakeWord(_ text: String) -> Bool {
    let lower = text.lowercased()
    if lower.range(of: Config.wakeRegex, options: .regularExpression) != nil { return true }
    for w in Config.chineseWake where text.contains(w) { return true }
    return false
}

/// Returns everything the user said *after* the wake word (the actual question).
func extractQueryAfterWake(_ text: String) -> String {
    var lastEnd: String.Index?

    if let regex = try? NSRegularExpression(pattern: Config.wakeRegex, options: [.caseInsensitive]) {
        let range = NSRange(text.startIndex..., in: text)
        if let m = regex.matches(in: text, range: range).last,
           let r = Range(m.range, in: text) {
            lastEnd = r.upperBound
        }
    }
    for w in Config.chineseWake {
        if let r = text.range(of: w, options: .backwards) {
            if lastEnd == nil || r.upperBound > lastEnd! { lastEnd = r.upperBound }
        }
    }
    guard let end = lastEnd else { return "" }
    let tail = String(text[end...])
    return tail.trimmingCharacters(in: CharacterSet(charactersIn: " ,，。.!！?？、;；:：\n\t"))
}

// MARK: - The assistant

final class VoiceAssistant: NSObject, AVSpeechSynthesizerDelegate {

    enum State: String {
        case starting, listening, capturing, thinking, speaking, denied
    }

    // Speech recognition
    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var sessionID = 0                 // invalidates stale task callbacks
    private var isCapturingAudio = false      // gate for the mic tap
    private var tapInstalled = false

    // TTS
    private let synth = AVSpeechSynthesizer()

    // State
    private(set) var state: State = .starting
    var onStateChange: ((State) -> Void)?

    // Capture timers
    private var silenceTimer: Timer?
    private var noSpeechTimer: Timer?
    private var maxCaptureTimer: Timer?
    private var wakeRestartTimer: Timer?
    private var triggered = false
    private var currentQuery = ""

    // Conversation history
    private var messages: [[String: String]] = [["role": "system", "content": Config.systemPrompt]]

    // Streaming-TTS coordination
    private var ttsBuffer = ""
    private var enqueuedCount = 0
    private var finishedCount = 0
    private var streamEnded = false
    private var spokeAnything = false

    override init() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: Config.locale))
        super.init()
        synth.delegate = self
    }

    // MARK: Lifecycle

    func start() {
        requestPermissions { [weak self] granted in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard granted else {
                    self.setState(.denied)
                    logLine("⚠️  未获得麦克风或语音识别权限。请到「系统设置 › 隐私与安全性 › 麦克风 / 语音识别」中允许本程序后重新启动。")
                    return
                }
                self.configureAudio()
                self.greet()
            }
        }
    }

    private func requestPermissions(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechAuth in
            let speechOK = speechAuth == .authorized
            let finish: (Bool) -> Void = { micOK in
                DispatchQueue.main.async { completion(speechOK && micOK) }
            }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                finish(true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { finish($0) }
            default:
                finish(false)
            }
        }
    }

    private func configureAudio() {
        guard !tapInstalled else { return }
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self, self.isCapturingAudio, let req = self.request else { return }
            req.append(buffer)
        }
        tapInstalled = true
        audioEngine.prepare()
        do { try audioEngine.start() }
        catch { logLine("❌ 音频引擎启动失败：\(error.localizedDescription)") }
    }

    private func greet() {
        resetResponse()
        feedResponse("你好，我是普真语音助手，叫我「普真普真」就可以了。")
        endResponse()
    }

    // MARK: State + status bar

    private func setState(_ s: State) {
        state = s
        onStateChange?(s)
    }

    private func playChime() {
        NSSound(named: NSSound.Name("Ping"))?.play()
    }

    // MARK: Listening / wake word

    /// Public entry — always hops to main.
    func startListening() { DispatchQueue.main.async { self._startListening() } }

    private func _startListening() {
        cancelTask()
        resetCaptureState()

        guard let recognizer = recognizer else {
            setState(.denied)
            logLine("❌ 语音识别不支持 locale「\(Config.locale)」。请用 ASSISTANT_LOCALE 换成 en-US 或 zh-CN。")
            return
        }
        guard recognizer.isAvailable else {
            logLine("… 语音识别暂不可用，2 秒后重试。")
            Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in self?._startListening() }
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        isCapturingAudio = true
        setState(.listening)

        let myID = sessionID
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard myID == self.sessionID else { return }
                if let result = result {
                    self.handleTranscript(result.bestTranscription.formattedString, isFinal: result.isFinal)
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.handleTaskEnd()
                }
            }
        }
        // Periodically refresh the task so the transcript never grows unbounded
        // and we stay under any server-side time limit.
        wakeRestartTimer?.invalidate()
        wakeRestartTimer = Timer.scheduledTimer(withTimeInterval: 40, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.state == .listening && !self.triggered { self._startListening() }
        }
    }

    private func handleTranscript(_ text: String, isFinal: Bool) {
        switch state {
        case .listening:
            if !triggered, containsWakeWord(text) {
                triggered = true
                beginCapture(initialTranscript: text)
            }
        case .capturing:
            let q = extractQueryAfterWake(text)
            currentQuery = q
            if !q.isEmpty {
                noSpeechTimer?.invalidate(); noSpeechTimer = nil
                armSilenceTimer()
            }
        default:
            break
        }
    }

    private func handleTaskEnd() {
        if state == .listening && !triggered {
            _startListening()
        } else if state == .capturing {
            finalizeCapture()
        }
        // thinking / speaking: task ended because we stopped it — ignore.
    }

    // MARK: Capturing the question

    private func beginCapture(initialTranscript: String) {
        setState(.capturing)
        playChime()
        wakeRestartTimer?.invalidate(); wakeRestartTimer = nil
        currentQuery = extractQueryAfterWake(initialTranscript)
        armMaxCaptureTimer()
        if currentQuery.isEmpty {
            armNoSpeechTimer()          // wait for the actual question
        } else {
            armSilenceTimer()           // question already started in one breath
        }
    }

    private func armSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            self?.finalizeCapture()
        }
    }
    private func armNoSpeechTimer() {
        noSpeechTimer?.invalidate()
        noSpeechTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            self?.abortCapture()
        }
    }
    private func armMaxCaptureTimer() {
        maxCaptureTimer?.invalidate()
        maxCaptureTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            self?.finalizeCapture()
        }
    }
    private func invalidateCaptureTimers() {
        silenceTimer?.invalidate();    silenceTimer = nil
        noSpeechTimer?.invalidate();   noSpeechTimer = nil
        maxCaptureTimer?.invalidate(); maxCaptureTimer = nil
    }

    private func abortCapture() {
        guard state == .capturing else { return }
        logLine("… 没听到问题，继续待命。")
        _startListening()
    }

    private func finalizeCapture() {
        guard state == .capturing else { return }
        invalidateCaptureTimers()
        let q = currentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelTask()
        if q.isEmpty { _startListening(); return }
        handleQuery(q)
    }

    private func resetCaptureState() {
        triggered = false
        currentQuery = ""
        invalidateCaptureTimers()
    }

    private func cancelTask() {
        sessionID += 1               // stale callbacks now ignored
        isCapturingAudio = false
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        wakeRestartTimer?.invalidate(); wakeRestartTimer = nil
    }

    // MARK: LLM

    private func handleQuery(_ q: String) {
        setState(.thinking)
        logLine("👤 \(q)")
        messages.append(["role": "user", "content": q])
        resetResponse()
        let snapshot = messages
        Task { await self.streamLLM(messages: snapshot) }
    }

    private func streamLLM(messages: [[String: String]]) async {
        if Config.apiKey.isEmpty {
            logLine("⚠️  未配置 API key。请在 .env 里设置 AIHUBMIX_API_KEY。")
            await MainActor.run {
                self.feedResponse("还没有配置 A P I 密钥，请在 .env 文件里设置后重新启动。")
                self.endResponse()
            }
            return
        }
        var assistantText = ""
        do {
            guard let url = URL(string: Config.baseURL + "/chat/completions") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 60
            req.setValue("Bearer \(Config.apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "model": Config.model,
                "stream": true,
                "temperature": 0.6,
                "messages": messages,
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (bytes, response) = try await URLSession.shared.bytes(for: req)

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                var errBody = ""
                for try await line in bytes.lines { errBody += line; if errBody.count > 1500 { break } }
                logLine("❌ HTTP \(http.statusCode)：\(errBody)")
                await MainActor.run {
                    self.feedResponse("请求出错了，状态码 \(http.statusCode)。请检查模型名称或网络。")
                    self.endResponse()
                }
                return
            }

            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let first = choices.first,
                      let delta = first["delta"] as? [String: Any],
                      let content = delta["content"] as? String,
                      !content.isEmpty
                else { continue }
                assistantText += content
                await MainActor.run { self.feedResponse(content) }
            }

            let finalText = assistantText
            await MainActor.run {
                if !finalText.isEmpty {
                    self.messages.append(["role": "assistant", "content": finalText])
                    self.trimHistory()
                    logLine("🤖 \(finalText)")
                }
                self.endResponse()
            }
        } catch {
            logLine("❌ 网络错误：\(error.localizedDescription)")
            await MainActor.run {
                self.feedResponse("抱歉，网络好像出问题了。")
                self.endResponse()
            }
        }
    }

    private func trimHistory() {
        let maxMessages = 13   // system + last 12 turns
        if messages.count > maxMessages {
            messages = [messages[0]] + messages.suffix(maxMessages - 1)
        }
    }

    // MARK: Text-to-speech (streamed, sentence by sentence)

    private func resetResponse() {
        ttsBuffer = ""
        enqueuedCount = 0
        finishedCount = 0
        streamEnded = false
        spokeAnything = false
    }

    private func feedResponse(_ chunk: String) {
        ttsBuffer += chunk
        flushCompleteSentences()
    }

    private func flushCompleteSentences() {
        let enders: Set<Character> = ["。", "！", "？", "!", "?", "\n", "；", ";", "…"]
        while let idx = ttsBuffer.firstIndex(where: { enders.contains($0) }) {
            let upto = ttsBuffer.index(after: idx)
            let sentence = String(ttsBuffer[..<upto]).trimmingCharacters(in: .whitespacesAndNewlines)
            ttsBuffer.removeSubrange(ttsBuffer.startIndex..<upto)
            if !sentence.isEmpty { enqueueSpeech(sentence) }
        }
    }

    private func enqueueSpeech(_ text: String) {
        if state != .speaking { setState(.speaking) }
        spokeAnything = true
        let u = AVSpeechUtterance(string: text)
        let lang = !Config.voiceOverride.isEmpty ? Config.voiceOverride
                    : (containsCJK(text) ? "zh-CN" : "en-US")
        u.voice = AVSpeechSynthesisVoice(language: lang)
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        enqueuedCount += 1
        synth.speak(u)
    }

    private func endResponse() {
        let rest = ttsBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        ttsBuffer = ""
        if !rest.isEmpty { enqueueSpeech(rest) }
        if !spokeAnything { enqueueSpeech("抱歉，我暂时没有想到答案。") }
        streamEnded = true
        maybeFinishSpeaking()
    }

    private func maybeFinishSpeaking() {
        if streamEnded && finishedCount >= enqueuedCount {
            startListening()   // back to waiting for the wake word
        }
    }

    // AVSpeechSynthesizerDelegate
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finishedCount += 1
        maybeFinishSpeaking()
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finishedCount += 1
        maybeFinishSpeaking()
    }
}

// MARK: - App delegate + menu bar

final class AppDelegate: NSObject, NSApplicationDelegate {
    let assistant = VoiceAssistant()
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        let header = NSMenuItem(title: "Puzhen 语音助手", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        updateTitle(.starting)
        assistant.onStateChange = { [weak self] s in
            DispatchQueue.main.async { self?.updateTitle(s) }
        }
        assistant.start()
    }

    private func updateTitle(_ s: VoiceAssistant.State) {
        let icon: String
        switch s {
        case .starting:  icon = "🎙️…"
        case .listening: icon = "🎙️"
        case .capturing: icon = "🔴"
        case .thinking:  icon = "💭"
        case .speaking:  icon = "🗣️"
        case .denied:    icon = "🚫"
        }
        statusItem.button?.title = icon
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
}

// MARK: - Bootstrap

loadDotEnv()                          // pull AIHUBMIX_API_KEY etc. from .env
let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
