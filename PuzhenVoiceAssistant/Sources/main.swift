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

// Durable logs in the standard macOS location (survive reboots, append-only,
// never truncated). Full debug log + a clean conversation transcript (JSONL).
let logDir = ("~/Library/Logs" as NSString).expandingTildeInPath
let debugLogPath = logDir + "/PuzhenAssistant.log"
let chatLogPath  = logDir + "/PuzhenAssistant-chat.jsonl"
let logLock = NSLock()
let logDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

/// Appends text to a file (creating it if needed). Caller holds logLock.
func appendToFile(_ path: String, _ text: String) {
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(Data(text.utf8))
        try? fh.close()
    }
}

func logLine(_ s: String) {
    logLock.lock(); defer { logLock.unlock() }
    let line = "[\(logDateFormatter.string(from: Date()))] \(s)\n"
    FileHandle.standardError.write(Data(line.utf8))
    appendToFile(debugLogPath, line)
}

/// Writes one conversation turn to the clean JSONL transcript.
func logChat(_ role: String, _ text: String) {
    logLock.lock(); defer { logLock.unlock() }
    let obj: [String: Any] = ["time": logDateFormatter.string(from: Date()), "role": role, "text": text]
    if let d = try? JSONSerialization.data(withJSONObject: obj),
       var s = String(data: d, encoding: .utf8) {
        s += "\n"
        appendToFile(chatLogPath, s)
    }
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
    // Optional: pin an exact voice by identifier (see the list printed at launch),
    // e.g. com.apple.voice.enhanced.zh-CN.Tingting. Empty = auto-pick best quality.
    static let voiceID = env("ASSISTANT_VOICE_ID", "")
    // Speaking speed multiplier (1.0 = normal). e.g. ASSISTANT_RATE=1.05
    static let rate = Float(env("ASSISTANT_RATE", "1.0")) ?? 1.0

    // ---- TTS engine ----
    // "api"    = OpenAI neural voices via AiHubMix /audio/speech — far more
    //            natural (~$0.015 per minute of audio, i.e. ~1 分钱/句).
    // "system" = free offline AVSpeechSynthesizer.
    // API mode falls back to the system voice automatically on any error.
    static let ttsMode  = env("ASSISTANT_TTS", "api")
    static let ttsModel = env("ASSISTANT_TTS_MODEL", "gpt-4o-mini-tts")
    // Voices: nova / coral / sage / shimmer / alloy / ash / onyx / echo ...
    static let ttsVoice = env("ASSISTANT_TTS_VOICE", "nova")
    // Style hint (gpt-4o-mini-tts only).
    static let ttsInstructions = env("ASSISTANT_TTS_INSTRUCTIONS",
        "你是一个亲切的中文语音助手，说话自然、温柔、口语化，语速适中。")

    // ---- Voice-native chat (speech in -> speech out, one model) ----
    // "audio" = your recorded voice goes straight to a speech-native model
    // which replies in its own natural voice (and can use tools).
    // "text"  = the old pipeline (Apple STT text -> chat model -> TTS).
    static let chatMode   = env("ASSISTANT_CHAT", "audio")
    static let audioModel = env("ASSISTANT_AUDIO_MODEL", "gpt-audio-1.5")
    static let audioVoice = env("ASSISTANT_AUDIO_VOICE", "marin")

    // ---- Local tools (terminal access, user-granted) ----
    static let toolsOn     = env("ASSISTANT_TOOLS", "on").lowercased() != "off"
    static let recordsFile = env("RECORDS_FILE",
        "/Users/puzhen/PycharmProjects/record_me/app_switch.log")
    static let recordsAirFile = env("RECORDS_AIR_FILE",
        "/Users/puzhen/PycharmProjects/record_me/app_switch_air.log")

    // Local Codex agent as the "smart brain" for complex questions.
    static let codexOn  = env("ASSISTANT_CODEX", "on").lowercased() != "off"
    static let codexBin = env("CODEX_BIN", "/opt/homebrew/bin/codex")

    // Playback rate for the voice replies (client-side, pitch-preserving).
    static let replyRate = Float(env("ASSISTANT_REPLY_RATE", "1.0")) ?? 1.0

    // ---- Home Assistant (smart home control) ----
    static let haURL   = env("HA_URL", "http://localhost:8123")
    static let haToken = env("HA_TOKEN", "")
    static var haConfigured: Bool { !haToken.isEmpty }

    // Default interaction mode. "simple" = gpt-audio does everything itself
    // (chat + home + terminal). "thinking" = also allowed to delegate to Codex.
    static let defaultThinking = env("ASSISTANT_MODE", "simple").lowercased() == "thinking"

    static let systemPrompt = """
    你是 Puzhen（普真）的私人语音助手。用户通过语音和你交流，你的回答会被立刻朗读出来。
    要求：回答要简洁、口语化、自然，一般只用 1 到 3 句话；不要使用 Markdown、编号列表、\
    代码块或表情符号，因为这些不适合朗读。默认用中文回答，除非用户明显在用其他语言提问。
    关于普真你需要记住的事：他最爱的人是柏玮婕。
    """

    // Wake word(s), comma-separated. Can be Chinese or pinyin — everything is
    // matched by PRONUNCIATION (pinyin), so any homophone of 普真 also matches.
    static let wakeWords = env("ASSISTANT_WAKE", "puzhen")
    // Romanized fallback, in case the recognizer outputs latin for "puzhen".
    static let wakeRegex = "pu\\s*(zh|j|ch|z|sh)e?n"
}

/// Friendly Chinese name -> Home Assistant entity_id. The model only ever sees
/// the short names (in the prompt and when calling tools), and the app maps them
/// back — this keeps the per-request prompt small (~120 vs ~650 tokens) and makes
/// tool calls more reliable (no 40-char entity_ids for the model to reproduce).
let haEntities: [String: String] = [
    "客厅灯1": "light.1lou_ke_ting_ke_ting_deng_1_kai_guan",
    "客厅灯2": "light.1lou_ke_ting_ke_ting_deng_2_kai_guan",
    "客厅灯3": "light.1lou_ke_ting_ke_ting_deng_3_kai_guan",
    "楼梯灯": "light.1lou_ke_ting_lou_ti_deng_kai_guan",
    "过道灯": "light.1lou_ru_hu_guo_dao_deng_kai_guan",
    "镜前灯": "light.1lou_ru_hu_jing_qian_deng_kai_guan",
    "浴室灯": "light.1lou_ru_hu_yu_shi_deng_kai_guan",
    "卧室灯": "light.2lou_zhu_wo_wo_shi_deng_kai_guan",
    "洗墙灯": "light.2lou_zhu_wo_xi_qiang_deng_kai_guan",
    "装饰灯": "light.2lou_zhu_wo_zhuang_shi_deng_kai_guan",
    "客布帘": "cover.1lou_ke_ting_ke_bu_lian_ke_bu_lian",
    "客纱帘": "cover.1lou_ke_ting_ke_sha_lian_ke_sha_lian",
    "客厅空调": "climate.1lou_ke_ting_ke_ting_kong_diao_ke_ting_kong_diao",
    "卧室空调": "climate.2lou_zhu_wo_wo_shi_kong_diao_wo_shi_kong_diao",
    "排气扇": "fan.1lou_ru_hu_pai_qi_shan_pai_qi_shan",
    "客厅温度": "sensor.1lou_ke_ting_wen_du_zhuang_tai",
    "客厅湿度": "sensor.1lou_ke_ting_shi_du_zhuang_tai",
    "卧室温度": "sensor.2lou_zhu_wo_wen_du_zhuang_tai",
    "卧室湿度": "sensor.2lou_zhu_wo_shi_du_zhuang_tai",
    "天气": "weather.tantron_weather",
]

/// Maps a friendly name (or an already-real entity_id, or "all") to an entity_id.
func resolveEntity(_ s: String) -> String {
    let t = s.trimmingCharacters(in: .whitespaces)
    if let e = haEntities[t] { return e }
    return t   // pass through entity_ids, "all", or unknown (HA will validate)
}
func resolveEntities(_ v: Any) -> Any {
    if let s = v as? String { return resolveEntity(s) }
    if let a = v as? [Any] { return a.map { resolveEntity("\($0)") } }
    return v
}

/// Compact catalog (short names only) injected into the prompt.
let haDeviceCatalog = """
💡灯(light, turn_on/turn_off/toggle): 客厅灯1 客厅灯2 客厅灯3 楼梯灯 过道灯 镜前灯 浴室灯 卧室灯 洗墙灯 装饰灯 (关全部传"all")
🪟窗帘(cover, open_cover/close_cover/stop_cover): 客布帘 客纱帘
❄️空调(climate): 客厅空调 卧室空调 — turn_on/off; set_temperature+data{"temperature":26,"hvac_mode":"cool"}; set_hvac_mode(cool/heat/dry/fan_only/off,温度18-29); set_fan_mode(auto/low/medium/high)
🌀排气扇(fan): 排气扇 — turn_on/off; set_percentage+data{"percentage":66}(33/66/100三档)
🌡️传感器(用home_read读): 客厅温度 客厅湿度 卧室温度 卧室湿度 天气
"""

/// System prompt with live date/time, home-control catalog, and (optionally)
/// the local-data tools. `thinking` controls whether Codex may be used.
func buildSystemPrompt(includeTools: Bool = true, thinking: Bool = false) -> String {
    let df = DateFormatter()
    df.locale = Locale(identifier: "zh_CN")
    df.dateFormat = "yyyy年M月d日 EEEE HH:mm"
    var p = Config.systemPrompt + "\n现在是 \(df.string(from: Date()))。"
    p += "\n说话时语速放慢一些，从容、自然、有停顿，不要赶。"
    guard includeTools && Config.toolsOn else { return p }

    if Config.haConfigured {
        p += """


        你能控制普真家里的智能设备（泰创,通过 Home Assistant）。用 home_control 执行动作、home_read 读状态。
        调用时 entity_id 直接填下面的中文设备名（可传数组一次控制多个）：
        \(haDeviceCatalog)
        指令清楚就直接做,做完用一句话确认（如“好的,客厅灯开好了”）。
        """
    }

    p += """


    你还能查询普真的本地数据（用户已授权）：
    - run_terminal: 执行一条 bash 命令,适合简单直接的查询（grep/tail/wc）。
    """
    if thinking && Config.codexOn {
        p += """

        - ask_codex: 复杂任务交给本地 Codex 智能体（更聪明,会多步查数据、写代码分析）。跨多天统计、\
        总结规律、深度分析（如“总结我这个月去过的地方”）优先用它,把问题原样转述。
        """
    }
    p += """

    闲聊和常识问题不要用工具。用户的活动记录（JSONL）有两份,都可检索：
    1) 这台 Mac: \(Config.recordsFile)（2025年7月至今,10万行+）
    2) 旧 MacBook Air: \(Config.recordsAirFile)（2025年7月~2026年5月16日,更早历史查这份）
    字段: app_switch{timestamp,from_app{name,window_title},to_app,duration_seconds} / \
    location_detected{timestamp,location{latitude,longitude},context} / lid_opened / lid_closed。
    文件很大先 grep/tail 缩小范围。经纬度换算成城市/区域,说地名不报坐标。涉及“在哪、去过哪、\
    用什么应用”先查数据再答,不要编造。
    """
    return p
}

// MARK: - Wake-word utilities (pinyin-based, homophone-proof)

/// Transliterates any string to toneless pinyin/latin letters, e.g.
/// "濮真" / "普珍" / "朴真" all -> "puzhen".
func pinyin(_ s: String) -> String {
    let latin = s.applyingTransform(.toLatin, reverse: false) ?? s
    let noDia = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
    return noDia.lowercased().filter { $0.isLetter }
}

/// Projects pinyin into coarse PHONETIC classes so sounds that Chinese
/// speakers/recognizers commonly confuse compare as EQUAL:
/// b/p d/t g/k (aspiration pairs) · zh/ch/j/q/z/c · sh/x/s · f/h · l/n ·
/// -ang/-an -eng/-en -ing/-in -ong/-on (nasal finals).
/// "buzhen" / "puchen" / "pujen" all -> "puzen".
func phoneticKey(_ p: String) -> String {
    var s = p
    for (a, b) in [("zh","z"),("ch","z"),("sh","s"),("ang","an"),("eng","en"),("ing","in"),("ong","on")] {
        s = s.replacingOccurrences(of: a, with: b)
    }
    let m: [Character: Character] = ["b":"p","d":"t","g":"k","j":"z","q":"z","c":"z","x":"s","f":"h","l":"n"]
    return String(s.map { m[$0] ?? $0 })
}

/// Approximate substring search (Sellers' algorithm). Returns the end offset
/// in `hay` of a match of `needle` with edit distance <= maxDist, or nil.
/// preferLast picks the last such match (detection); false picks the first
/// (extraction, so the wake word never swallows part of the question).
func fuzzyFind(_ hayS: String, _ needleS: String, maxDist: Int, preferLast: Bool = true) -> Int? {
    let hay = Array(hayS), needle = Array(needleS)
    if needle.isEmpty || hay.isEmpty { return nil }
    let n = needle.count
    var col = Array(0...n)
    var best: Int? = nil
    for j in 1...hay.count {
        var nc = [0] + Array(repeating: 0, count: n)
        for i in 1...n {
            nc[i] = min(col[i-1] + (needle[i-1] == hay[j-1] ? 0 : 1), col[i] + 1, nc[i-1] + 1)
        }
        col = nc
        if col[n] <= maxDist { best = j; if !preferLast { return j } }
    }
    return best
}

/// Pinyin targets we listen for: the configured wake word(s) + any the user has
/// calibrated with the "teach my voice" button (stored in a local file).
let wakeFilePath = ("~/.puzhen-assistant.wake" as NSString).expandingTildeInPath
var wakePinyinTargets: [String] = ["puzhen"]

func loadWakeTargets() {
    var set = Set<String>()
    for w in Config.wakeWords.split(separator: ",") {
        let p = pinyin(String(w))
        if p.count >= 3 { set.insert(p) }
    }
    if let content = try? String(contentsOfFile: wakeFilePath, encoding: .utf8) {
        for line in content.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let p = pinyin(String(line))
            if p.count >= 3 { set.insert(p) }
        }
    }
    if set.isEmpty { set.insert("puzhen") }
    wakePinyinTargets = Array(set)
}

/// Appends a user-calibrated pinyin target and reloads.
func saveCalibratedTarget(_ p: String) {
    guard p.count >= 3 else { return }
    var existing = (try? String(contentsOfFile: wakeFilePath, encoding: .utf8)) ?? ""
    if !existing.split(whereSeparator: { $0 == "\n" }).contains(where: { pinyin(String($0)) == p }) {
        if !existing.isEmpty && !existing.hasSuffix("\n") { existing += "\n" }
        existing += p + "\n"
        try? existing.write(toFile: wakeFilePath, atomically: true, encoding: .utf8)
    }
    loadWakeTargets()
}

/// If the text contains an immediately-repeated word (叠词) like 普真普真 — even
/// with two different homophones (濮真普珍) — returns the pinyin of the repeated
/// unit (e.g. "puzhen"). Otherwise nil.
func reduplicatedUnitPinyin(_ text: String) -> String? {
    let letters = Array(text.filter { $0.isLetter })   // drop spaces/punctuation
    let n = letters.count
    for unit in [2, 3, 1] {                            // 2-char names first (普真)
        var i = 0
        while i + 2 * unit <= n {
            let a = pinyin(String(letters[i ..< i + unit]))
            let b = pinyin(String(letters[i + unit ..< i + 2 * unit]))
            if !a.isEmpty && a == b { return a }
            i += 1
        }
    }
    return nil
}

func containsWakeWord(_ text: String) -> Bool {
    let py = pinyin(text)
    // 1) Exact pinyin (any homophone of 普真) — a single occurrence suffices.
    for t in wakePinyinTargets where !t.isEmpty && py.contains(t) { return true }
    // 2) Exact reduplication whose unit matches a target in SOUND space
    //    (e.g. 濮真普珍, 不真不真 — two different near-homophones doubled).
    if let unit = reduplicatedUnitPinyin(text),
       wakePinyinTargets.contains(where: { phoneticKey($0) == phoneticKey(unit) }) { return true }
    // 3) Fuzzy sound-space match, edit distance <= 2 — but ONLY for the DOUBLED
    //    call ("puzhen puzhen" / "buzhen buzhen" / "puchen fuzhen"...). Single
    //    fuzzy hits are rejected so everyday near-sounds (不怎么…) can't trigger.
    let key = phoneticKey(py)
    for t in wakePinyinTargets where t.count >= 4 {
        let tk = phoneticKey(t)
        if fuzzyFind(key, tk + tk, maxDist: 2) != nil { return true }
    }
    // 4) Romanized fallback (recognizer emitted latin instead of Chinese).
    if text.lowercased().range(of: Config.wakeRegex, options: .regularExpression) != nil { return true }
    return false
}

let wakeTrimSet = CharacterSet(charactersIn: " ,，。.!！?？、;；:：\n\t")

/// Returns everything the user said *after* the wake word (the actual question).
/// The wake word is located in SOUND space — exact pinyin first, then the
/// fuzzy doubled form — and the boundary is mapped back to characters.
func extractQueryAfterWake(_ text: String) -> String {
    let chars = Array(text)
    // Per-character cumulative lengths in pinyin space and phonetic-key space
    // (each Chinese char is one syllable, so per-char keying is exact).
    var pinCum: [Int] = [], keyCum: [Int] = []
    var pin = "", key = ""
    for c in chars {
        let p = pinyin(String(c))
        pin += p;              pinCum.append(pin.count)
        key += phoneticKey(p); keyCum.append(key.count)
    }

    var lastCharEnd = 0

    // Exact pinyin matches — take the LAST occurrence.
    var lastPinEnd = 0
    for t in wakePinyinTargets where !t.isEmpty {
        var from = pin.startIndex
        while let r = pin.range(of: t, range: from..<pin.endIndex) {
            lastPinEnd = max(lastPinEnd, pin.distance(from: pin.startIndex, to: r.upperBound))
            from = r.upperBound
            if from == pin.endIndex { break }
        }
    }
    if lastPinEnd > 0, let i = pinCum.firstIndex(where: { $0 >= lastPinEnd }) {
        lastCharEnd = max(lastCharEnd, i + 1)
    }

    // Fuzzy doubled match — take the FIRST occurrence, so a near-sound inside
    // the question itself is never swallowed.
    for t in wakePinyinTargets where t.count >= 4 {
        let tk = phoneticKey(t)
        if let end = fuzzyFind(key, tk + tk, maxDist: 2, preferLast: false),
           let i = keyCum.firstIndex(where: { $0 >= end }) {
            lastCharEnd = max(lastCharEnd, i + 1)
        }
    }

    if lastCharEnd == 0 || lastCharEnd >= chars.count {
        // No sound-space boundary — latin/regex fallback.
        if let regex = try? NSRegularExpression(pattern: Config.wakeRegex, options: [.caseInsensitive]),
           let m = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
           let rr = Range(m.range, in: text) {
            return String(text[rr.upperBound...]).trimmingCharacters(in: wakeTrimSet)
        }
        return ""
    }
    return String(chars[lastCharEnd...]).trimmingCharacters(in: wakeTrimSet)
}

/// Derives a compact wake target from a calibration utterance's pinyin. If the
/// user said it twice ("puzhenpuzhen"), keep one copy ("puzhen").
func deriveWakeTarget(_ py: String) -> String {
    if py.count >= 6 && py.count % 2 == 0 {
        let half = py.count / 2
        let a = String(py.prefix(half)); let b = String(py.suffix(half))
        if a == b { return a }
    }
    return py
}

// MARK: - The assistant

final class VoiceAssistant: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {

    enum State: String {
        case starting, listening, capturing, thinking, speaking, denied, calibrating
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

    // State + UI callbacks
    private(set) var state: State = .starting
    private var stateEnteredAt = Date()
    private var watchdog: Timer?
    var onStateChange: ((State) -> Void)?      // state changed
    var onTranscript: ((String) -> Void)?      // live partial transcript
    var onLine: ((String, String) -> Void)?    // completed line: ("user"|"assistant", text)
    private var manualMode = false             // captured via the button, not the wake word

    // Capture timers
    private var silenceTimer: Timer?
    private var noSpeechTimer: Timer?
    private var maxCaptureTimer: Timer?
    private var wakeRestartTimer: Timer?
    private var triggered = false
    private var currentQuery = ""
    private var calibrationText = ""

    // Conversation history
    // Full running transcript (no system message — a fresh one is prepended each
    // request so the clock/state is current). Holds user/assistant/tool turns,
    // INCLUDING assistant tool_calls and tool results, so the model remembers
    // what it did and what tools returned across turns.
    private var messages: [[String: Any]] = []

    // Streaming-TTS coordination
    private var ttsBuffer = ""
    private var enqueuedCount = 0
    private var finishedCount = 0
    private var streamEnded = false
    private var spokeAnything = false

    // API-TTS playback queue (sentences synthesize concurrently, play in order)
    private let useAPITTS = Config.ttsMode.lowercased() != "system" && !Config.apiKey.isEmpty
    private var ttsGen = 0                        // invalidates in-flight synthesis
    private var clipData: [Int: Data] = [:]       // finished audio, keyed by sentence index
    private var clipFallback: [Int: String] = [:] // failed sentences -> system voice
    private var playIndex = 0                     // next sentence index to play
    private var playingViaSynth = false           // current item is on the system synth
    private var audioPlayer: AVAudioPlayer?

    // Interaction mode: false = 简单(gpt-audio does everything itself),
    // true = 思考(also allowed to delegate to the local Codex agent). UI-togglable.
    var thinkingMode = Config.defaultThinking

    // Voice-native chat (gpt-audio) — the user's actual voice is sent to the model
    private let audioMode = Config.chatMode.lowercased() == "audio" && !Config.apiKey.isEmpty
    private var usesClipPlayer: Bool { useAPITTS || audioMode }
    private var pendingWav: Data?

    // Question-audio recording (input -> 16 kHz mono PCM16 -> WAV)
    private var isRecordingWav = false
    private let wavLock = NSLock()
    private var captureBuf = Data()
    private var wavConverter: AVAudioConverter?

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
                logLine("✅ 权限已授予,启动监听。audioMode=\(self.audioMode) haConfigured=\(Config.haConfigured)")
                self.configureAudio()
                self.reportVoices()
                self.watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                    self?.watchdogTick()
                }
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
            guard let self = self else { return }
            if self.isCapturingAudio, let req = self.request { req.append(buffer) }
            if self.isRecordingWav { self.appendWavBuffer(buffer) }
        }
        if let out = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                   channels: 1, interleaved: true) {
            wavConverter = AVAudioConverter(from: format, to: out)
        }
        tapInstalled = true
        audioEngine.prepare()
        do { try audioEngine.start() }
        catch { logLine("❌ 音频引擎启动失败：\(error.localizedDescription)") }
    }

    private func greet() {
        let hello = "你好，我是普真语音助手，叫我「普真普真」就可以了。"
        logChat("assistant", hello)
        onLine?("assistant", hello)
        resetResponse()
        feedResponse(hello)
        endResponse()
    }

    // MARK: State + status bar

    private func setState(_ s: State) {
        state = s
        stateEnteredAt = Date()
        onStateChange?(s)
    }

    /// Safety net: guarantees the app never gets permanently stuck out of the
    /// listening state (e.g. a playback delegate that never fires, a hung reply).
    private func watchdogTick() {
        let elapsed = Date().timeIntervalSince(stateEnteredAt)
        switch state {
        case .thinking:
            // Simple turns are fast (each API call now caps at 60s); 思考模式 may
            // run Codex (~180s) so it needs more headroom.
            let limit: TimeInterval = thinkingMode ? 360 : 90
            if elapsed > limit { recover("thinking 卡了 \(Int(elapsed))s") }
        case .speaking:
            if elapsed > 60 { recover("speaking 卡了 \(Int(elapsed))s") }   // 单条回答不该超过60s
        case .capturing:
            if elapsed > 20 { logLine("🐕 capturing 超时,强制收尾"); finalizeCapture() }
        case .listening:
            // Recognition should be actively running; if it isn't, restart it.
            if !isCapturingAudio || task == nil {
                logLine("🐕 监听态但识别未运行,重启")
                _startListening()
            }
        case .calibrating:
            if elapsed > 12 { logLine("🐕 calibrating 超时,收尾"); finishCalibration() }
        case .starting, .denied:
            break
        }
    }

    private func recover(_ why: String) {
        logLine("🐕 看门狗恢复监听：\(why)")
        ttsGen += 1
        synth.stopSpeaking(at: .immediate)
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        playingViaSynth = false
        _startListening()
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

        guard recognizer != nil else {
            setState(.denied)
            logLine("❌ 语音识别不支持 locale「\(Config.locale)」。请用 ASSISTANT_LOCALE 换成 en-US 或 zh-CN。")
            return
        }
        guard startRecognitionTask() else {
            logLine("… 语音识别暂不可用，2 秒后重试。")
            Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in self?._startListening() }
            return
        }
        setState(.listening)
        // Periodically refresh the task so the transcript never grows unbounded
        // and we stay under any server-side time limit.
        // Refresh the recognition session occasionally so the transcript can't
        // grow unbounded. Kept infrequent (3 min) and SILENT: restarting too
        // often creates a brief gap that can clip a wake word, and it spammed
        // the log. On-device recognition also self-ends on silence (handleTaskEnd
        // restarts then), so this is just a long-idle backstop.
        wakeRestartTimer?.invalidate()
        wakeRestartTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.state == .listening && !self.triggered { self._startListening() }
        }
    }

    /// Creates a fresh recognition request + task feeding `handleTranscript`.
    /// Returns false if recognition isn't available yet.
    @discardableResult
    private func startRecognitionTask() -> Bool {
        guard let recognizer = recognizer, recognizer.isAvailable else { return false }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Apple's official API for out-of-vocabulary words: bias recognition
        // toward the custom name so 普真 is transcribed as-is more often.
        req.contextualStrings = ["普真", "普真普真"] + Config.wakeWords.split(separator: ",").map(String.init)
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        isCapturingAudio = true
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
        return true
    }

    /// Triggered by the "talk now" button — skip the wake word, capture the next
    /// utterance directly. Only valid while idly listening.
    func manualWake() {
        DispatchQueue.main.async {
            guard self.state == .listening else { return }
            self.cancelTask()
            self.resetCaptureState()
            guard self.startRecognitionTask() else { self._startListening(); return }
            self.triggered = true
            self.beginCapture(initialTranscript: "", manual: true)
        }
    }

    private func handleTranscript(_ text: String, isFinal: Bool) {
        switch state {
        case .listening:
            onTranscript?(text)
            if !triggered, containsWakeWord(text) {
                triggered = true
                beginCapture(initialTranscript: text)
            }
        case .capturing:
            let q = manualMode ? text.trimmingCharacters(in: .whitespacesAndNewlines)
                               : extractQueryAfterWake(text)
            currentQuery = q
            onTranscript?(q.isEmpty ? text : q)
            if !q.isEmpty {
                noSpeechTimer?.invalidate(); noSpeechTimer = nil
                armSilenceTimer()
            }
        case .calibrating:
            calibrationText = text
            onTranscript?(text)
        default:
            break
        }
    }

    private func handleTaskEnd() {
        if state == .listening && !triggered {
            _startListening()
        } else if state == .capturing {
            finalizeCapture()
        } else if state == .calibrating {
            finishCalibration()
        }
        // thinking / speaking: task ended because we stopped it — ignore.
    }

    // MARK: Calibration ("teach it your voice")

    /// Records how the recognizer hears the user say the wake word, and stores
    /// that pronunciation so it matches next time. Only valid while listening.
    func startCalibration() {
        DispatchQueue.main.async {
            guard self.state == .listening else { return }
            self.cancelTask()
            self.resetCaptureState()
            guard self.startRecognitionTask() else { self._startListening(); return }
            self.calibrationText = ""
            self.setState(.calibrating)
            self.playChime()
            self.maxCaptureTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                self?.finishCalibration()
            }
        }
    }

    private func finishCalibration() {
        guard state == .calibrating else { return }
        invalidateCaptureTimers()
        cancelTask()
        let heard = calibrationText.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = deriveWakeTarget(pinyin(heard))
        if !heard.isEmpty && target.count >= 3 {
            saveCalibratedTarget(target)
            onLine?("assistant", "记住了！我听到你叫「\(heard)」（拼音 \(target)），以后这样叫我就行。")
            resetResponse(); feedResponse("记住了，以后这样叫我就行。"); endResponse()
        } else {
            onLine?("assistant", "没太听清，请再点一次按钮，清楚地说两遍「普真普真」。")
            resetResponse(); feedResponse("没太听清，再试一次吧。"); endResponse()
        }
    }

    // MARK: Question-audio recording (WAV for the voice-native model)

    private func startWavCapture() {
        wavLock.lock(); captureBuf = Data(); wavLock.unlock()
        isRecordingWav = true
    }

    private func appendWavBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let conv = wavConverter else { return }
        let ratio = 16000.0 / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: conv.outputFormat, frameCapacity: cap) else { return }
        var fed = false
        conv.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        if out.frameLength > 0, let ch = out.int16ChannelData {
            let d = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
            wavLock.lock(); captureBuf.append(d); wavLock.unlock()
        }
    }

    /// Stops recording and returns a complete WAV file (nil if too short).
    private func finishWavCapture() -> Data? {
        isRecordingWav = false
        wavLock.lock(); let pcm = captureBuf; captureBuf = Data(); wavLock.unlock()
        guard pcm.count > 8000 else { return nil }        // < 0.25 s of audio
        var wav = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(1)
        le32(16000); le32(32000); le16(2); le16(16)       // 16 kHz mono s16le
        wav.append(contentsOf: Array("data".utf8)); le32(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }

    // MARK: Capturing the question

    private func beginCapture(initialTranscript: String, manual: Bool = false) {
        manualMode = manual
        setState(.capturing)
        playChime()
        startWavCapture()
        wakeRestartTimer?.invalidate(); wakeRestartTimer = nil
        currentQuery = manual ? "" : extractQueryAfterWake(initialTranscript)
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
        isRecordingWav = false
        logLine("… 没听到问题，继续待命。")
        _startListening()
    }

    private func finalizeCapture() {
        guard state == .capturing else { return }
        invalidateCaptureTimers()
        let q = currentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingWav = finishWavCapture()
        logLine("🎬 finalizeCapture: query=\"\(q)\" wav=\(pendingWav?.count ?? 0)字节 audioMode=\(audioMode)")
        cancelTask()
        if q.isEmpty { pendingWav = nil; _startListening(); return }
        handleQuery(q)
    }

    private func resetCaptureState() {
        triggered = false
        manualMode = false
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
        logChat("user", q)
        onLine?("user", q)
        messages.append(["role": "user", "content": q])
        resetResponse()
        let snapshot = messages
        let wav = pendingWav; pendingWav = nil
        if audioMode {
            Task { await self.audioChat(history: snapshot, query: q, wav: wav) }
        } else {
            Task { await self.streamLLM(history: snapshot) }
        }
    }

    private func streamLLM(history: [[String: Any]]) async {
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
            var msgs: [[String: Any]] = [["role": "system", "content": buildSystemPrompt(includeTools: false)]]
            msgs.append(contentsOf: history)
            let body: [String: Any] = [
                "model": Config.model,
                "stream": true,
                "temperature": 0.6,
                "messages": msgs,
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
                    logChat("assistant", finalText)
                    self.onLine?("assistant", finalText)
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

    // MARK: Voice-native chat (gpt-audio: your voice in -> its voice out, with tools)

    private func fnTool(_ name: String, _ desc: String, _ props: [String: Any], _ required: [String]) -> [String: Any] {
        ["type": "function", "function": [
            "name": name, "description": desc,
            "parameters": ["type": "object", "properties": props, "required": required] as [String: Any],
        ] as [String: Any]]
    }

    /// Tools offered to the model this turn — depends on config and the current mode.
    private var toolDefs: [[String: Any]] {
        var defs: [[String: Any]] = [
            fnTool("run_terminal", "在用户的 Mac 上执行一条 bash 命令并返回输出，适合简单直接的查询（grep/tail/统计一类）。",
                   ["command": ["type": "string", "description": "要执行的 bash 命令"]], ["command"]),
        ]
        if Config.haConfigured {
            defs.append(fnTool("home_control",
                "控制普真家里的智能设备（灯/窗帘/空调/排气扇）。domain+service+entity_id 见系统提示里的清单。",
                [
                    "domain": ["type": "string", "description": "light/cover/climate/fan"],
                    "service": ["type": "string", "description": "如 turn_on/turn_off/toggle/open_cover/close_cover/set_temperature/set_hvac_mode/set_fan_mode/set_percentage"],
                    "entity_id": ["description": "中文设备名（如 客厅灯1），可传数组一次控制多个，或 \"all\""],
                    "data": ["type": "object", "description": "额外参数，如 {\"temperature\":26,\"hvac_mode\":\"cool\"}，没有就省略"],
                ], ["domain", "service", "entity_id"]))
            defs.append(fnTool("home_read", "读取某个设备/传感器的当前状态。entity_id 用中文设备名。",
                   ["entity_id": ["type": "string", "description": "中文设备名，如 客厅温度"]], ["entity_id"]))
        }
        if thinkingMode && Config.codexOn {
            defs.append(fnTool("ask_codex",
                "把复杂问题交给本地 Codex 智能体（会自己多步查数据、写代码分析）。适合跨多天统计、总结、深度分析。耗时约30~120秒。",
                ["question": ["type": "string", "description": "要研究的问题，用中文完整描述"]], ["question"]))
        }
        return defs
    }

    private func audioChat(history: [[String: Any]], query: String, wav: Data?) async {
        let thinking = thinkingMode
        let tools = toolDefs
        logLine("🎙️→ audioChat: model=\(Config.audioModel) wav=\(wav?.count ?? 0)B tools=\(tools.count) thinking=\(thinking) 历史\(history.count)条")
        var msgs: [[String: Any]] = [["role": "system", "content": buildSystemPrompt(thinking: thinking)]]
        msgs.append(contentsOf: history)
        if let wav = wav, let last = msgs.last, (last["role"] as? String) == "user" {
            // Send the current turn as real voice; history user turns stay text.
            msgs.removeLast()
            msgs.append(["role": "user", "content": [
                ["type": "text", "text": "（下面是我的语音，转写参考：\(query)）"],
                ["type": "input_audio",
                 "input_audio": ["data": wav.base64EncodedString(), "format": "wav"]] as [String: Any],
            ]])
        }
        logLine("📜 上下文角色: " + msgs.compactMap { $0["role"] as? String }.joined(separator: ","))

        // New messages produced this turn (text form), persisted to history so the
        // model remembers its tool calls + results next time.
        var produced: [[String: Any]] = []

        for _ in 0..<6 {
            var body: [String: Any] = [
                "model": Config.audioModel,
                "modalities": ["text", "audio"],
                "audio": ["voice": Config.audioVoice, "format": "mp3"],
                "messages": msgs,
            ]
            if Config.toolsOn && !tools.isEmpty { body["tools"] = tools }

            guard let resp = await Self.postChat(body),
                  let choices = resp["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any] else {
                logLine("❌ audioChat: 没有拿到有效回复,走文字兜底")
                await MainActor.run {
                    self.feedResponse("抱歉，语音对话请求失败了。")
                    self.endResponse()
                }
                return
            }
            logLine("← 回复: tool_calls=\((msg["tool_calls"] as? [[String: Any]])?.count ?? 0) 有audio=\((msg["audio"] as? [String: Any]) != nil)")

            // Tool round: execute and continue the loop.
            if let calls = msg["tool_calls"] as? [[String: Any]], !calls.isEmpty {
                var am: [String: Any] = ["role": "assistant", "tool_calls": calls]
                am["content"] = (msg["content"] as? String) ?? ""
                msgs.append(am)
                produced.append(am)
                for c in calls {
                    let id = (c["id"] as? String) ?? ""
                    let fn = c["function"] as? [String: Any]
                    let name = (fn?["name"] as? String) ?? ""
                    let argStr = (fn?["arguments"] as? String) ?? "{}"
                    let args = (argStr.data(using: .utf8)
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
                    var output = "未知工具 \(name)"
                    if name == "run_terminal", let cmd = args["command"] as? String {
                        logLine("🖥️ \(cmd)")
                        await MainActor.run { self.onLine?("assistant", "🖥️ \(cmd)") }
                        output = await Self.runShell(cmd)
                    } else if name == "home_control",
                              let domain = args["domain"] as? String,
                              let service = args["service"] as? String {
                        let entity = args["entity_id"] ?? "all"
                        let data = (args["data"] as? [String: Any]) ?? [:]
                        logLine("🏠 \(domain).\(service) \(entity)")
                        await MainActor.run { self.onLine?("assistant", "🏠 \(domain).\(service) → \(entity)") }
                        output = await Self.haControl(domain: domain, service: service, entity: entity, data: data)
                    } else if name == "home_read", let e = args["entity_id"] as? String {
                        logLine("🏠 read \(e)")
                        output = await Self.haRead(entity: e)
                    } else if name == "ask_codex", let q = args["question"] as? String {
                        logLine("🧠 codex: \(q)")
                        await MainActor.run { self.onLine?("assistant", "🧠 正在让 Codex 研究：\(q)") }
                        output = await Self.runCodex(q)
                    }
                    msgs.append(["role": "tool", "tool_call_id": id, "content": output])
                    produced.append(["role": "tool", "tool_call_id": id, "content": String(output.prefix(800))])
                }
                continue
            }

            // Final answer: play its native speech, persist the whole exchange.
            let audioObj = msg["audio"] as? [String: Any]
            let transcript = (audioObj?["transcript"] as? String) ?? (msg["content"] as? String) ?? ""
            let audioData = (audioObj?["data"] as? String).flatMap { Data(base64Encoded: $0) }
            if !transcript.isEmpty { produced.append(["role": "assistant", "content": transcript]) }
            let persist = produced
            await MainActor.run {
                self.messages.append(contentsOf: persist)
                self.trimHistory()
                if !transcript.isEmpty {
                    logLine("🤖 \(transcript)")
                    logChat("assistant", transcript)
                    self.onLine?("assistant", transcript)
                }
                if let data = audioData {
                    self.playAudioReply(data)
                } else {
                    self.feedResponse(transcript.isEmpty ? "我没有想到答案。" : transcript)
                    self.endResponse()
                }
            }
            return
        }
        await MainActor.run {
            self.feedResponse("查询轮数太多，先停下来了，换个问法试试。")
            self.endResponse()
        }
    }

    /// Plays a complete audio reply through the clip player.
    private func playAudioReply(_ data: Data) {
        resetResponse()
        setState(.speaking)
        spokeAnything = true
        enqueuedCount = 1
        streamEnded = true
        clipData[0] = data
        tryPlayNextClip()
    }

    private static func postChat(_ body: [String: Any]) async -> [String: Any]? {
        guard let url = URL(string: Config.baseURL + "/chat/completions") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60   // a voice turn should never take this long; fail fast and recover
        req.setValue("Bearer \(Config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                logLine("❌ 语音对话 HTTP \(code)：\(String(data: data.prefix(300), encoding: .utf8) ?? "")")
                return nil
            }
            return (try JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } catch {
            logLine("❌ 语音对话网络错误：\(error.localizedDescription)")
            return nil
        }
    }

    /// Hands a complex question to the local Codex agent (read-only sandbox,
    /// 3-minute budget) and returns its final answer.
    private static func runCodex(_ question: String) async -> String {
        let outFile = NSTemporaryDirectory() + "puzhen-codex-answer.txt"
        try? FileManager.default.removeItem(atPath: outFile)
        let prompt = """
        请研究并回答下面的问题。可用数据——用户的活动记录（JSONL,每行一个JSON）：
        1) 这台 Mac: \(Config.recordsFile)（2025年7月至今）
        2) 旧 MacBook Air: \(Config.recordsAirFile)（2025年7月~2026年5月）
        字段: app_switch{timestamp,from_app{name,window_title},to_app,duration_seconds} / \
        location_detected{timestamp,location{latitude,longitude},context} / lid_opened / lid_closed。
        经纬度请换算成城市/区域名。回答要简洁口语化,适合朗读,不要用 Markdown。
        问题：\(question)
        """
        let cmd = "\(Config.codexBin) exec --skip-git-repo-check --ephemeral -s read-only " +
                  "-C \"$HOME\" -o \"\(outFile)\" - 2>&1 | tail -c 1200"
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = ["-lc", cmd]
                let inPipe = Pipe(), outPipe = Pipe()
                p.standardInput = inPipe
                p.standardOutput = outPipe
                p.standardError = outPipe
                do { try p.run() } catch {
                    cont.resume(returning: "Codex 启动失败：\(error.localizedDescription)")
                    return
                }
                inPipe.fileHandleForWriting.write(Data(prompt.utf8))
                inPipe.fileHandleForWriting.closeFile()
                var logs = Data()
                let readDone = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    logs = outPipe.fileHandleForReading.readDataToEndOfFile()
                    readDone.signal()
                }
                let exitDone = DispatchSemaphore(value: 0)
                p.terminationHandler = { _ in exitDone.signal() }
                if exitDone.wait(timeout: .now() + 180) == .timedOut {
                    p.terminate()
                    _ = exitDone.wait(timeout: .now() + 3)
                }
                _ = readDone.wait(timeout: .now() + 3)
                let ans = (try? String(contentsOfFile: outFile, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !ans.isEmpty {
                    cont.resume(returning: String(ans.prefix(4000)))
                } else {
                    let tail = String(data: logs, encoding: .utf8) ?? ""
                    cont.resume(returning: "Codex 没有给出最终答案。日志尾部：\(String(tail.suffix(600)))")
                }
            }
        }
    }

    // MARK: Home Assistant REST calls

    private static func haControl(domain: String, service: String, entity: Any, data: [String: Any]) async -> String {
        guard Config.haConfigured else { return "家居未配置（.env 里缺 HA_TOKEN）" }
        guard let url = URL(string: "\(Config.haURL)/api/services/\(domain)/\(service)") else { return "地址错误" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(Config.haToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = data
        body["entity_id"] = resolveEntities(entity)
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (respData, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code == 200 || code == 201 { return "OK,已执行 \(domain).\(service)" }
            return "失败 HTTP \(code): \(String(data: respData.prefix(300), encoding: .utf8) ?? "")"
        } catch { return "网络错误: \(error.localizedDescription)" }
    }

    private static func haRead(entity: String) async -> String {
        guard Config.haConfigured else { return "家居未配置（.env 里缺 HA_TOKEN）" }
        guard let url = URL(string: "\(Config.haURL)/api/states/\(resolveEntity(entity))") else { return "地址错误" }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Bearer \(Config.haToken)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else { return "失败 HTTP \(code)" }
            guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return String(data: data.prefix(400), encoding: .utf8) ?? "(无法解析)"
            }
            let st = (j["state"] as? String) ?? "?"
            var extra = ""
            if let attrs = j["attributes"] as? [String: Any] {
                for k in ["temperature", "current_temperature", "hvac_action", "fan_mode", "percentage", "unit_of_measurement"] {
                    if let v = attrs[k] { extra += " \(k)=\(v)" }
                }
            }
            return "state=\(st)\(extra)"
        } catch { return "网络错误: \(error.localizedDescription)" }
    }

    /// Executes a bash command (terminal access granted by the user).
    /// sudo is refused; output is truncated; 25 s timeout.
    private static func runShell(_ command: String) async -> String {
        if command.contains("sudo") { return "(已拒绝：不允许 sudo)" }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = ["-c", command]
                p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch {
                    cont.resume(returning: "启动失败：\(error.localizedDescription)")
                    return
                }
                var out = Data()
                let readDone = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    out = pipe.fileHandleForReading.readDataToEndOfFile()
                    readDone.signal()
                }
                let exitDone = DispatchSemaphore(value: 0)
                p.terminationHandler = { _ in exitDone.signal() }
                if exitDone.wait(timeout: .now() + 25) == .timedOut {
                    p.terminate()
                    _ = exitDone.wait(timeout: .now() + 2)
                }
                _ = readDone.wait(timeout: .now() + 3)
                var s = String(data: out, encoding: .utf8) ?? ""
                if s.count > 6000 { s = String(s.prefix(6000)) + "\n...(输出截断)" }
                cont.resume(returning: s.isEmpty ? "(无输出)" : s)
            }
        }
    }

    private func trimHistory() {
        let maxMessages = 30
        if messages.count > maxMessages {
            messages = Array(messages.suffix(maxMessages))
        }
        // Never let history start with an orphaned tool result (its assistant
        // tool_calls message would be missing → invalid transcript).
        while (messages.first?["role"] as? String) == "tool" {
            messages.removeFirst()
        }
    }

    // MARK: Text-to-speech (streamed, sentence by sentence)

    private func resetResponse() {
        ttsBuffer = ""
        enqueuedCount = 0
        finishedCount = 0
        streamEnded = false
        spokeAnything = false
        // API-TTS queue
        ttsGen += 1                    // drop results of any in-flight synthesis
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        playingViaSynth = false
        clipData = [:]
        clipFallback = [:]
        playIndex = 0
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

    // Best available voice per language, chosen once (premium > enhanced > compact,
    // and real voices preferred over the "eloquence" novelty set).
    private lazy var zhVoice: AVSpeechSynthesisVoice? = pickVoice(prefix: "zh")
    private lazy var enVoice: AVSpeechSynthesisVoice? = pickVoice(prefix: "en")

    private func pickVoice(prefix: String) -> AVSpeechSynthesisVoice? {
        if !Config.voiceID.isEmpty, let v = AVSpeechSynthesisVoice(identifier: Config.voiceID),
           v.language.lowercased().hasPrefix(prefix) { return v }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(prefix) }
            .sorted { a, b in
                if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
                return !a.identifier.contains("eloquence") && b.identifier.contains("eloquence")
            }
            .first
    }

    /// Prints the selected voices + how to get better ones. Called once at launch.
    func reportVoices() {
        func desc(_ v: AVSpeechSynthesisVoice?) -> String {
            guard let v = v else { return "系统默认" }
            let q = v.quality == .premium ? "高级" : (v.quality == .enhanced ? "增强" : "紧凑/compact")
            return "\(v.name)（\(q)）  id=\(v.identifier)"
        }
        if useAPITTS {
            logLine("🔊 TTS 引擎：API 人声 \(Config.ttsModel) / \(Config.ttsVoice)（失败自动回退系统声音）")
        } else {
            logLine("🔊 TTS 引擎：系统自带（免费离线）")
        }
        logLine("🔊 中文系统声音：\(desc(zhVoice))")
        logLine("🔊 英文系统声音：\(desc(enVoice))")
        if !useAPITTS, (zhVoice?.quality ?? .default) == .default {
            logLine("💡 当前是紧凑音质，声音偏机械。到「系统设置 › 辅助功能 › 朗读内容 › 系统声音 › 管理声音」下载中文的『增强』或『高级』版本，重启后会自动使用。")
        }
    }

    private func enqueueSpeech(_ text: String) {
        if state != .speaking { setState(.speaking) }
        spokeAnything = true
        if usesClipPlayer { enqueueAPISpeech(text) } else {
            enqueuedCount += 1
            speakViaSystem(text)
        }
    }

    /// Raw system-voice speak (no bookkeeping) — used directly in system mode
    /// and as the per-sentence fallback in API mode.
    private func speakViaSystem(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        let useCJK = Config.voiceOverride.isEmpty ? containsCJK(text)
                                                  : Config.voiceOverride.lowercased().hasPrefix("zh")
        u.voice = useCJK ? zhVoice : enVoice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * Config.rate
        synth.speak(u)
    }

    // MARK: API TTS (OpenAI-compatible /audio/speech via AiHubMix)

    private func enqueueAPISpeech(_ text: String) {
        let idx = enqueuedCount
        enqueuedCount += 1
        let gen = ttsGen
        Task {
            let data = await VoiceAssistant.synthesizeAPI(text: text)
            await MainActor.run {
                guard gen == self.ttsGen else { return }   // response was reset
                if let data = data {
                    self.clipData[idx] = data
                } else {
                    logLine("⚠️ TTS API 失败，这一句用系统声音兜底")
                    self.clipFallback[idx] = text
                }
                self.tryPlayNextClip()
            }
        }
    }

    private static func synthesizeAPI(text: String) async -> Data? {
        guard let url = URL(string: Config.baseURL + "/audio/speech") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(Config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": Config.ttsModel,
            "input": text,
            "voice": Config.ttsVoice,
            "response_format": "mp3",
        ]
        // Style hint is only supported by the gpt-4o family of TTS models.
        if Config.ttsModel.contains("gpt-"), !Config.ttsInstructions.isEmpty {
            body["instructions"] = Config.ttsInstructions
        }
        if Config.rate != 1.0 { body["speed"] = Config.rate }
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            // A JSON body ("{"...) or tiny payload means an error, not audio.
            guard code == 200, data.count > 500, data.first != UInt8(ascii: "{") else {
                logLine("⚠️ TTS HTTP \(code)，\(data.count) bytes")
                return nil
            }
            return data
        } catch {
            logLine("⚠️ TTS 网络错误：\(error.localizedDescription)")
            return nil
        }
    }

    /// Plays the next sentence if it's our turn and its audio (or fallback) is ready.
    private func tryPlayNextClip() {
        guard usesClipPlayer, audioPlayer == nil, !playingViaSynth else { return }
        if let data = clipData.removeValue(forKey: playIndex) {
            do {
                let p = try AVAudioPlayer(data: data)
                p.delegate = self
                if Config.replyRate != 1.0 {
                    p.enableRate = true
                    p.rate = Config.replyRate
                }
                audioPlayer = p
                p.play()
            } catch {
                logLine("⚠️ 音频解码失败，跳过一句：\(error.localizedDescription)")
                clipFinished()
            }
        } else if let text = clipFallback.removeValue(forKey: playIndex) {
            playingViaSynth = true
            speakViaSystem(text)
        }
    }

    private func clipFinished() {
        finishedCount += 1
        playIndex += 1
        maybeFinishSpeaking()
        tryPlayNextClip()
    }

    // AVAudioPlayerDelegate
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            guard player === self.audioPlayer else { return }
            self.audioPlayer = nil
            self.clipFinished()
        }
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
            logLine("🔚 回答播放完毕,恢复监听")
            startListening()   // back to waiting for the wake word
        }
    }

    // AVSpeechSynthesizerDelegate
    private func synthUtteranceDone() {
        if usesClipPlayer {
            if playingViaSynth {           // a fallback sentence just finished
                playingViaSynth = false
                clipFinished()
            }
        } else {
            finishedCount += 1
            maybeFinishSpeaking()
        }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.synthUtteranceDone() }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.synthUtteranceDone() }
    }
}

// MARK: - App delegate + window UI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let assistant = VoiceAssistant()
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var stateLabel: NSTextField!
    private var liveLabel: NSTextField!
    private var convo: NSTextView!
    private var talkButton: NSButton!
    private var learnButton: NSButton!
    private var modeControl: NSSegmentedControl!
    private var deniedShown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        buildWindow()

        assistant.onStateChange = { [weak self] s    in DispatchQueue.main.async { self?.updateState(s) } }
        assistant.onTranscript  = { [weak self] t    in DispatchQueue.main.async { self?.updateLive(t) } }
        assistant.onLine        = { [weak self] w, t in DispatchQueue.main.async { self?.appendLine(w, t) } }

        assistant.start()
    }

    // Menu-bar indicator (kept as a small always-visible status)
    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        let show = NSMenuItem(title: "显示窗口", action: #selector(showWindow), keyEquivalent: "")
        show.target = self; menu.addItem(show)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.title = "🎙️"
    }

    private func buildWindow() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 560))

        stateLabel = NSTextField(labelWithString: "🎙️ 启动中…")
        stateLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        stateLabel.alignment = .center

        let hint = NSTextField(labelWithString: "说「普真普真」唤醒，或点下面的按钮直接说话")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center

        modeControl = NSSegmentedControl(labels: ["简单模式", "思考模式"],
                                         trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        modeControl.segmentDistribution = .fillEqually
        modeControl.selectedSegment = assistant.thinkingMode ? 1 : 0
        modeControl.setToolTip("简单：全部由语音模型直接完成（含开关家里的灯/空调等）。思考：复杂问题可交给本地 Codex 深入分析。", forSegment: 0)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        convo = NSTextView()
        convo.isEditable = false
        convo.isRichText = true
        convo.font = .systemFont(ofSize: 14)
        convo.textContainerInset = NSSize(width: 10, height: 10)
        scroll.documentView = convo

        liveLabel = NSTextField(labelWithString: " ")
        liveLabel.font = .systemFont(ofSize: 12)
        liveLabel.textColor = .tertiaryLabelColor
        liveLabel.alignment = .center
        liveLabel.lineBreakMode = .byTruncatingTail
        liveLabel.maximumNumberOfLines = 1

        talkButton = NSButton(title: "🎤  直接说话（不用喊唤醒词）", target: self, action: #selector(talkNow))
        talkButton.bezelStyle = .rounded
        talkButton.controlSize = .large

        learnButton = NSButton(title: "🎯  教它认我的声音（说两遍「普真普真」）", target: self, action: #selector(learnVoice))
        learnButton.bezelStyle = .rounded
        learnButton.controlSize = .large

        let stack = NSStackView(views: [stateLabel, hint, modeControl, scroll, liveLabel, talkButton, learnButton])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 340),
        ])

        window = NSWindow(contentRect: content.frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "普真语音助手"
        window.contentView = content
        window.setContentSize(NSSize(width: 460, height: 560))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateState(_ s: VoiceAssistant.State) {
        let icon: String, desc: String
        switch s {
        case .starting:  icon = "🎙️"; desc = "启动中…"
        case .listening: icon = "🎙️"; desc = "待命中 · 说「普真普真」唤醒"
        case .capturing: icon = "🔴"; desc = "我在听，请说…"
        case .thinking:  icon = "💭"; desc = "思考中…"
        case .speaking:  icon = "🗣️"; desc = "说话中…"
        case .denied:    icon = "🚫"; desc = "需要麦克风 / 语音识别权限"
        case .calibrating: icon = "🎯"; desc = "正在学你的叫法，请说两遍「普真普真」…"
        }
        stateLabel.stringValue = "\(icon) \(desc)"
        statusItem.button?.title = icon
        talkButton.isEnabled = (s == .listening)
        learnButton.isEnabled = (s == .listening)
        if s == .listening { liveLabel.stringValue = " " }
        if s == .denied { showDeniedHelp() }
    }

    private func updateLive(_ t: String) {
        liveLabel.stringValue = t.isEmpty ? " " : "🎧 " + t
    }

    private func appendLine(_ who: String, _ text: String) {
        guard let ts = convo.textStorage else { return }
        let isUser = (who == "user")
        let title = isUser ? "🧑 你" : "🤖 普真"
        let color = isUser ? NSColor.systemBlue : NSColor.systemGreen
        ts.append(NSAttributedString(string: "\(title)\n",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: color]))
        ts.append(NSAttributedString(string: "\(text)\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]))
        convo.scrollToEndOfDocument(nil)
    }

    private func showDeniedHelp() {
        guard !deniedShown else { return }
        deniedShown = true
        appendLine("assistant", "我没拿到麦克风或语音识别权限。请在弹出的对话框里点「允许」，" +
                                "或到「系统设置 › 隐私与安全性」里打开，然后重新启动我。")
        talkButton.title = "打开系统设置授权"
        talkButton.isEnabled = true
        talkButton.action = #selector(openPrivacySettings)
    }

    @objc private func talkNow() { assistant.manualWake() }
    @objc private func learnVoice() { assistant.startCalibration() }
    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let thinking = sender.selectedSegment == 1
        assistant.thinkingMode = thinking
        appendLine("assistant", thinking
            ? "已切到「思考模式」：复杂问题我会调用本地 Codex 深入分析（会慢一点）。"
            : "已切到「简单模式」：我自己直接完成，包括开关家里的灯、空调这些。")
    }
    @objc private func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func openPrivacySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(u)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }
}

// MARK: - Bootstrap

logLine("========== 普真语音助手 启动 ==========")
loadDotEnv()                          // pull AIHUBMIX_API_KEY etc. from .env
loadWakeTargets()                     // wake word(s) + any calibrated pronunciations
let app = NSApplication.shared
app.setActivationPolicy(.regular)     // real app: Dock icon + window
let delegate = AppDelegate()
app.delegate = delegate
app.run()
