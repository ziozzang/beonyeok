import Foundation

/// Request log / counters shared with the UI.
final class Stats: @unchecked Sendable {
    struct Entry: Identifiable {
        let id = UUID()
        let time: Date
        let remote: String
        let summary: String
        let status: Int
        let ms: Int
    }
    private let lock = NSLock()
    private(set) var requests = 0
    private(set) var errors = 0
    private(set) var recent: [Entry] = []
    var onChange: (@Sendable () -> Void)?

    /// Billed characters (persisted, reported by /v2/usage).
    var characters: Int {
        get { UserDefaults.standard.integer(forKey: "characterCount") }
        set { UserDefaults.standard.set(newValue, forKey: "characterCount") }
    }

    func record(_ e: Entry, chars: Int) {
        lock.withLock {
            requests += 1
            if e.status >= 400 { errors += 1 }
            if chars > 0 { characters += chars }
            recent.insert(e, at: 0)
            if recent.count > 50 { recent.removeLast() }
        }
        onChange?()
    }

    func snapshot() -> (requests: Int, errors: Int, chars: Int, recent: [Entry]) {
        lock.withLock { (requests, errors, characters, recent) }
    }

    func resetUsage() { lock.withLock { characters = 0 }; onChange?() }
}

/// DeepL API v2/v3-compatible front for Apple Translation.
/// Implemented: POST|GET /v2/translate, GET|POST /v2/usage, GET|POST /v2/languages, GET /v3/languages,
/// empty glossary listings. Parameters without an Apple equivalent (formality, context, glossary_id, model_type,
/// custom_instructions, …) are accepted and ignored.
final class DeepLAPI: @unchecked Sendable {
    struct Config {
        var apiKeys: [String]           // empty = no auth required
        var characterLimit: Int         // reported by /v2/usage (0 = effectively unlimited)
    }

    let engine = AppleEngine.shared
    let stats: Stats
    private let lock = NSLock()
    private var _config: Config
    var config: Config {
        get { lock.withLock { _config } }
        set { lock.withLock { _config = newValue } }
    }

    init(config: Config, stats: Stats) { _config = config; self.stats = stats }

    // MARK: Entry point

    func handle(_ req: HTTPRequest) async -> HTTPResponse {
        let t0 = Date()
        var chars = 0
        var summary = "\(req.method) \(req.path)"
        var resp: HTTPResponse
        if req.method == "OPTIONS" {
            resp = HTTPResponse(status: 204)
        } else if let authError = authorize(req) {
            resp = authError
        } else {
            do {
                switch (req.method, req.path.hasSuffix("/") && req.path.count > 1 ? String(req.path.dropLast()) : req.path) {
                case ("POST", "/v2/translate"), ("GET", "/v2/translate"):
                    let (r, c, s) = try await translate(req); resp = r; chars = c; summary = s
                case (_, "/v2/usage"):
                    let limit = config.characterLimit > 0 ? config.characterLimit : 1_000_000_000_000
                    resp = .json(200, ["character_count": stats.characters, "character_limit": limit])
                case (_, "/v2/languages"):
                    resp = try await languages(req)
                case ("GET", "/v3/languages"):
                    resp = await languagesV3(req)
                case ("GET", "/v2/glossaries"), ("GET", "/v3/glossaries"):
                    resp = .json(200, ["glossaries": [Any]()])
                case ("GET", "/v2/glossary-language-pairs"):
                    resp = .json(200, ["supported_languages": [Any]()])
                case ("GET", "/"), ("GET", "/health"):
                    resp = .json(200, ["service": "Apple Translation (DeepL API compatible)", "status": "ok",
                                       "endpoints": ["/v2/translate", "/v2/usage", "/v2/languages", "/v3/languages"]])
                case (_, "/v2/translate"), (_, "/v2/languages"):
                    resp = .json(405, ["message": "Method not allowed"])
                case (_, let p) where p.hasPrefix("/v2/document") || p.hasPrefix("/v2/glossaries") || p.hasPrefix("/v3/glossaries")
                                    || p.hasPrefix("/v2/write") || p.hasPrefix("/v3/style_rules"):
                    resp = .json(501, ["message": "Not supported by this server (Apple Translation bridge)", "code": "not_supported"])
                default:
                    resp = .json(404, ["message": "Not found"])
                }
            } catch let e as TranslateError {
                resp = .json(e.status, ["message": e.message])
            } catch {
                resp = .json(500, ["message": "Internal error: \(error.localizedDescription)"])
            }
        }
        resp.headers += [
            ("X-Trace-ID", UUID().uuidString.lowercased()),
            ("Access-Control-Allow-Origin", "*"),
            ("Access-Control-Allow-Headers", "Authorization, Content-Type, X-DeepL-Reporting-Tag"),
            ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
        ]
        if req.method != "OPTIONS" {
            stats.record(.init(time: Date(), remote: req.remote, summary: summary, status: resp.status,
                               ms: Int(Date().timeIntervalSince(t0) * 1000)), chars: chars)
        }
        return resp
    }

    // MARK: Auth

    private func authorize(_ req: HTTPRequest) -> HTTPResponse? {
        let keys = config.apiKeys
        guard !keys.isEmpty, !(req.method == "GET" && (req.path == "/" || req.path == "/health")) else { return nil }
        var presented: String?
        if let h = req.header("authorization") {
            for prefix in ["DeepL-Auth-Key ", "Bearer "] where h.hasPrefix(prefix) {
                presented = String(h.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        // Legacy (deprecated by DeepL, still accepted here): auth_key in query or form body.
        if presented == nil { presented = (req.query + formParams(req)).first { $0.0 == "auth_key" }?.1 }
        if let p = presented, keys.contains(p) { return nil }
        return .json(403, ["message": "Authorization failure, check auth_key", "code": "auth_failure"])
    }

    // MARK: Parameters

    private func formParams(_ req: HTTPRequest) -> [(String, String)] {
        let type = req.header("content-type")?.lowercased() ?? ""
        guard !req.body.isEmpty, !type.contains("json") else { return [] }
        return parseForm(String(decoding: req.body, as: UTF8.self))
    }

    /// Unified parameters from query, form body or JSON body. Values are strings or string arrays.
    private func params(_ req: HTTPRequest) throws -> [String: [String]] {
        var out: [String: [String]] = [:]
        for (k, v) in req.query { out[k, default: []].append(v) }
        let type = req.header("content-type")?.lowercased() ?? ""
        if !req.body.isEmpty {
            if type.contains("json") || (type.isEmpty && req.body.first == UInt8(ascii: "{")) {
                guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
                    throw TranslateError(status: 400, message: "Invalid JSON body")
                }
                for (k, v) in obj {
                    switch v {
                    case let a as [Any]: out[k] = a.map { "\($0)" }
                    case let b as Bool: out[k] = [b ? "1" : "0"]
                    case let n as NSNumber: out[k] = [n.stringValue]
                    case let s as String: out[k] = [s]
                    default: continue
                    }
                }
            } else {
                for (k, v) in formParams(req) { out[k, default: []].append(v) }
            }
        }
        // Form clients may send text[]=… style keys.
        if let t = out["text[]"] { out["text", default: []] += t }
        return out
    }

    private static func bool(_ v: String?) -> Bool {
        guard let v = v?.lowercased() else { return false }
        return v == "1" || v == "true"
    }

    // MARK: /v2/translate

    private func translate(_ req: HTTPRequest) async throws -> (HTTPResponse, Int, String) {
        let p = try params(req)
        guard let texts = p["text"], !texts.isEmpty else {
            throw TranslateError(status: 400, message: "Parameter 'text' not specified.")
        }
        guard let targetCode = p["target_lang"]?.first, !targetCode.isEmpty else {
            throw TranslateError(status: 400, message: "Value for 'target_lang' not specified.")
        }
        guard let target = Lang.apple(targetCode) else {
            throw TranslateError(status: 400, message: "Value for 'target_lang' not supported.")
        }
        var source: Locale.Language?
        if let s = p["source_lang"]?.first, !s.isEmpty {
            guard let l = Lang.apple(s) else { throw TranslateError(status: 400, message: "Value for 'source_lang' not supported.") }
            source = l
        }
        let tagHandling = p["tag_handling"]?.first?.lowercased()
        if let t = tagHandling, t != "xml", t != "html" {
            throw TranslateError(status: 400, message: "Value for 'tag_handling' not supported.")
        }
        let ignore = Set((p["ignore_tags"] ?? []).flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let showBilled = Self.bool(p["show_billed_characters"]?.first)
        let modelType = p["model_type"]?.first

        // Group texts by (detected) source so each pair is one batched call.
        var detected: [Locale.Language] = []
        for t in texts {
            if let source { detected.append(source); continue }
            detected.append(await engine.detect(t) ?? Locale.Language(identifier: "en"))
        }
        var results = texts
        var groups: [String: [Int]] = [:]
        for (i, l) in detected.enumerated() { groups[l.minimalIdentifier, default: []].append(i) }
        for (_, idxs) in groups {
            let from = detected[idxs[0]]
            // Same language (e.g. EN -> EN-US): DeepL returns the text unchanged.
            if from.languageCode == target.languageCode && from.script == target.script { continue }
            if let tagHandling {
                for i in idxs {
                    results[i] = try await engine.translateMarkup(texts[i], from: from, to: target,
                                                                  ignore: ignore, html: tagHandling == "html")
                }
            } else {
                let out = try await engine.translate(idxs.map { texts[$0] }, from: from, to: target)
                for (k, i) in idxs.enumerated() { results[i] = out[k] }
            }
        }
        var chars = 0
        let translations: [[String: Any]] = texts.indices.map { i in
            var d: [String: Any] = ["detected_source_language": Lang.deeplSource(detected[i]), "text": results[i]]
            let billed = texts[i].count
            chars += billed
            if showBilled { d["billed_characters"] = billed }
            if modelType != nil { d["model_type_used"] = "latency_optimized" }
            return d
        }
        let srcLabel = source.map { Lang.deeplSource($0) } ?? "auto(\(Set(detected.map(Lang.deeplSource)).sorted().joined(separator: ",")))"
        let summary = "translate \(srcLabel)→\(targetCode.uppercased()) · \(texts.count) text(s) · \(chars) chars"
        return (.json(200, ["translations": translations]), chars, summary)
    }

    // MARK: /v2/languages, /v3/languages

    private func languages(_ req: HTTPRequest) async throws -> HTTPResponse {
        let p = try params(req)
        let type = p["type"]?.first?.lowercased() ?? "source"
        guard type == "source" || type == "target" else {
            throw TranslateError(status: 400, message: "Value for 'type' not supported.")
        }
        let codes = await engine.deeplCodes()
        let list: [[String: Any]] = (type == "source" ? codes.source : codes.target).map { c in
            var d: [String: Any] = ["language": c, "name": Lang.name(c)]
            if type == "target" { d["supports_formality"] = false }
            return d
        }
        return .json(200, list)
    }

    private func languagesV3(_ req: HTTPRequest) async -> HTTPResponse {
        let codes = await engine.deeplCodes()
        let all = Set(codes.source).union(codes.target).sorted()
        let list: [[String: Any]] = all.map { c in
            let isSource = codes.source.contains(c)
            var features: [String: Any] = [:]
            if isSource { features["auto_detection"] = ["status": "stable"] }
            features["tag_handling"] = ["status": "beta"]
            return ["lang": c.lowercased().replacingOccurrences(of: "-hans", with: "-Hans").replacingOccurrences(of: "-hant", with: "-Hant")
                        .replacingOccurrences(of: "-us", with: "-US").replacingOccurrences(of: "-gb", with: "-GB")
                        .replacingOccurrences(of: "-br", with: "-BR").replacingOccurrences(of: "-pt", with: "-PT"),
                    "name": Lang.name(c), "usable_as_source": isSource, "usable_as_target": codes.target.contains(c),
                    "status": "stable", "features": features]
        }
        return .json(200, list)
    }
}
