import Foundation
import NaturalLanguage
import Translation

/// DeepL language codes <-> Apple Translation languages.
enum Lang {
    /// DeepL code -> English name (source + target codes from the DeepL docs, plus target variants).
    static let deeplNames: [String: String] = [
        "AR": "Arabic", "BG": "Bulgarian", "CS": "Czech", "DA": "Danish", "DE": "German", "EL": "Greek",
        "EN": "English", "EN-GB": "English (British)", "EN-US": "English (American)", "ES": "Spanish",
        "ET": "Estonian", "FI": "Finnish", "FR": "French", "HE": "Hebrew", "HI": "Hindi", "HU": "Hungarian",
        "ID": "Indonesian", "IT": "Italian", "JA": "Japanese", "KO": "Korean", "LT": "Lithuanian",
        "LV": "Latvian", "NB": "Norwegian Bokmål", "NL": "Dutch", "PL": "Polish", "PT": "Portuguese",
        "PT-BR": "Portuguese (Brazilian)", "PT-PT": "Portuguese (European)", "RO": "Romanian",
        "RU": "Russian", "SK": "Slovak", "SL": "Slovenian", "SV": "Swedish", "TH": "Thai", "TR": "Turkish",
        "UK": "Ukrainian", "VI": "Vietnamese", "ZH": "Chinese", "ZH-HANS": "Chinese (simplified)",
        "ZH-HANT": "Chinese (traditional)",
    ]

    /// DeepL code -> Apple language (nil if unknown).
    static func apple(_ deepl: String) -> Locale.Language? {
        let c = deepl.uppercased().replacingOccurrences(of: "_", with: "-")
        switch c {
        case "EN": return Locale.Language(identifier: "en")
        case "EN-US": return Locale.Language(identifier: "en-US")
        case "EN-GB": return Locale.Language(identifier: "en-GB")
        case "PT", "PT-BR": return Locale.Language(identifier: "pt-BR")
        case "PT-PT": return Locale.Language(identifier: "pt-PT")
        case "ZH", "ZH-HANS", "ZH-CN": return Locale.Language(identifier: "zh-Hans")
        case "ZH-HANT", "ZH-TW": return Locale.Language(identifier: "zh-Hant")
        case "NB", "NO": return Locale.Language(identifier: "nb")
        default:
            guard c.count >= 2, c.count <= 8 else { return nil }
            return Locale.Language(identifier: c.lowercased())
        }
    }

    /// Apple/NL language -> DeepL source code (what `detected_source_language` reports).
    static func deeplSource(_ l: Locale.Language) -> String {
        switch l.languageCode?.identifier ?? "" {
        case "zh": return "ZH"
        case "pt": return "PT"
        case "nb", "no": return "NB"
        case let x: return x.uppercased()
        }
    }

    static func name(_ code: String) -> String { deeplNames[code] ?? Locale(identifier: "en").localizedString(forIdentifier: code.lowercased()) ?? code }
}

struct TranslateError: Error {
    let status: Int
    let message: String
}

/// Apple Translation behind a small session pool (one session per concurrent request per pair).
/// Note: Apple's translation service processes requests serially system-wide; the pool keeps
/// sessions warm and lets many HTTP requests wait concurrently without blocking each other.
final class AppleEngine: @unchecked Sendable {
    static let shared = AppleEngine()
    private let lock = NSLock()
    private var idle: [String: [TranslationSession]] = [:]
    private let availability = LanguageAvailability()
    let cache = TranslationCache.shared
    private var supportedCache: [Locale.Language]?

    func supportedLanguages() async -> [Locale.Language] {
        if let c = lock.withLock({ supportedCache }) { return c }
        let s = await availability.supportedLanguages
        lock.withLock { supportedCache = s }
        return s
    }

    /// DeepL-style codes Apple can translate (for /v2/languages and /v3/languages).
    func deeplCodes() async -> (source: [String], target: [String]) {
        let apple = Set(await supportedLanguages().compactMap { $0.languageCode?.identifier })
        let base = Lang.deeplNames.keys.filter { !$0.contains("-") && apple.contains(Lang.apple($0)?.languageCode?.identifier ?? "") }
        var extra: [String] = apple.map { $0.uppercased() }.filter { Lang.deeplNames[$0] == nil && $0 != "ZH" && $0 != "PT" && $0 != "NO" }
        extra = extra.filter { $0.count == 2 }
        let source = (base + extra).sorted()
        var target = source
        for v in ["EN-GB", "EN-US", "PT-BR", "PT-PT", "ZH-HANS", "ZH-HANT"] {
            let baseCode = String(v.prefix(2))
            if source.contains(baseCode) { target.append(v) }
        }
        return (source, target.sorted())
    }

    func status(_ from: Locale.Language, _ to: Locale.Language) async -> LanguageAvailability.Status {
        await availability.status(from: from, to: to)
    }

    /// Detects the language of `text` among Apple-supported languages.
    func detect(_ text: String) async -> Locale.Language? {
        let supported = await supportedLanguages()
        let r = NLLanguageRecognizer()
        r.languageConstraints = supported.compactMap { l in
            if l.languageCode?.identifier == "zh" { return l.script?.identifier == "Hant" ? .traditionalChinese : .simplifiedChinese }
            return NLLanguage(rawValue: l.languageCode?.identifier ?? "")
        }
        r.processString(text)
        guard let d = r.dominantLanguage else { return nil }
        switch d {
        case .simplifiedChinese: return Locale.Language(identifier: "zh-Hans")
        case .traditionalChinese: return Locale.Language(identifier: "zh-Hant")
        default: return Locale.Language(identifier: d.rawValue)
        }
    }

    private func key(_ a: Locale.Language, _ b: Locale.Language) -> String { "\(a.minimalIdentifier)>\(b.minimalIdentifier)" }

    private func checkout(_ from: Locale.Language, _ to: Locale.Language) -> TranslationSession {
        let k = key(from, to)
        if let s = lock.withLock({ idle[k]?.popLast() }) { return s }
        return TranslationSession(installedSource: from, target: to)
    }

    private func checkin(_ s: TranslationSession, _ from: Locale.Language, _ to: Locale.Language) {
        let k = key(from, to)
        lock.withLock { if (idle[k]?.count ?? 0) < 8 { idle[k, default: []].append(s) } }
    }

    /// Translates plain strings (one call per non-empty line so newlines/indentation survive).
    func translate(_ texts: [String], from: Locale.Language, to: Locale.Language) async throws -> [String] {
        switch await status(from, to) {
        case .installed: break
        case .supported:
            throw TranslateError(status: 400, message:
                "Language pair \(Lang.deeplSource(from))->\(to.minimalIdentifier) is supported but not installed on this server. Download it from the Beonyeok menu.")
        case .unsupported:
            throw TranslateError(status: 400, message: "Language pair \(from.minimalIdentifier)->\(to.minimalIdentifier) is not supported by Apple Translation.")
        @unknown default: break
        }
        // Split every text into lines; translate only lines with letters; keep leading/trailing whitespace.
        struct Piece { var text: Int; var line: Int; var lead: String; var core: String; var trail: String }
        var lines: [[String]] = texts.map { $0.components(separatedBy: "\n") }
        var pieces: [Piece] = []
        for (ti, ls) in lines.enumerated() {
            for (li, l) in ls.enumerated() {
                let core = l.trimmingCharacters(in: .whitespacesAndNewlines)
                guard core.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { continue }
                let lead = String(l.prefix { $0.isWhitespace })
                let trail = String(String(l.reversed()).prefix { $0.isWhitespace }.reversed())
                pieces.append(Piece(text: ti, line: li, lead: lead, core: core, trail: trail))
            }
        }
        guard !pieces.isEmpty else { return texts }
        // Cache first; only misses (deduplicated) go to the Apple engine.
        let src = from.minimalIdentifier, tgt = to.minimalIdentifier
        var out: [String?] = cache.lookup(pieces.map(\.core), src: src, tgt: tgt)
        let missing = Array(Set(pieces.indices.filter { out[$0] == nil }.map { pieces[$0].core }))
        if !missing.isEmpty {
            let session = checkout(from, to)
            defer { checkin(session, from, to) }
            let reqs = missing.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
            let responses: [TranslationSession.Response]
            do { responses = try await session.translations(from: reqs) }
            catch { throw TranslateError(status: 500, message: "Apple Translation failed: \(error.localizedDescription)") }
            var fresh: [String: String] = [:]
            for r in responses { if let id = r.clientIdentifier.flatMap(Int.init), id < missing.count { fresh[missing[id]] = r.targetText } }
            cache.store(fresh.map { ($0.key, $0.value) }, src: src, tgt: tgt)
            for i in pieces.indices where out[i] == nil { out[i] = fresh[pieces[i].core] ?? pieces[i].core }
        }
        let outs = out.map { $0 ?? "" }
        for (i, p) in pieces.enumerated() { lines[p.text][p.line] = p.lead + outs[i] + p.trail }
        return lines.map { $0.joined(separator: "\n") }
    }

    // MARK: - tag_handling (xml / html)

    /// Translates text between tags, keeping markup intact. Content of `ignore` tags is left as is.
    func translateMarkup(_ text: String, from: Locale.Language, to: Locale.Language, ignore: Set<String>, html: Bool) async throws -> String {
        var tokens: [(isTag: Bool, s: String)] = []
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "<", let close = text[i...].firstIndex(of: ">") {
                tokens.append((true, String(text[i...close]))); i = text.index(after: close)
            } else {
                let next = text[i...].firstIndex(of: "<") ?? text.endIndex
                let seg = String(text[i..<next])
                if next == text.endIndex || text[next...].firstIndex(of: ">") != nil { tokens.append((false, seg)); i = next }
                else { tokens.append((false, String(text[i...]))); i = text.endIndex }
            }
        }
        let skipAlways: Set<String> = html ? ["script", "style", "code", "pre"] : []
        var depth: [String: Int] = [:]
        var targets: [Int] = []
        for (idx, t) in tokens.enumerated() {
            if t.isTag {
                let inner = t.s.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                let closing = inner.hasPrefix("/")
                let name = inner.drop { $0 == "/" }.prefix { !$0.isWhitespace && $0 != "/" && $0 != ">" }.lowercased()
                let selfClosing = inner.hasSuffix("/")
                guard ignore.contains(name) || skipAlways.contains(name), !selfClosing else { continue }
                depth[name, default: 0] += closing ? -1 : 1
                if depth[name]! < 0 { depth[name] = 0 }
            } else if depth.values.allSatisfy({ $0 == 0 }),
                      t.s.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) {
                targets.append(idx)
            }
        }
        // Decode entities for translation, re-encode afterwards.
        let src = targets.map { Self.decodeEntities(tokens[$0].s) }
        let translated = try await translate(src, from: from, to: to)
        for (k, idx) in targets.enumerated() { tokens[idx].s = Self.encodeEntities(translated[k]) }
        return tokens.map(\.s).joined()
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}").replacingOccurrences(of: "&amp;", with: "&")
    }

    static func encodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
