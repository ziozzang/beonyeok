import SwiftUI
import AppKit
import Combine
import ServiceManagement
import Translation

// MARK: - Controller

@MainActor
final class ServerController: ObservableObject {
    @AppStorage("port") var port = 8989
    @AppStorage("listenAll") var listenAll = true          // 0.0.0.0 (LAN) vs 127.0.0.1 only
    @AppStorage("apiKeys") var apiKeysRaw = ""             // one per line / comma; empty = no auth
    @AppStorage("characterLimit") var characterLimit = 0
    @AppStorage("autoStart") var autoStart = true
    @AppStorage("cacheEnabled") var cacheEnabled = true { didSet { applyCache() } }
    @AppStorage("cacheMax") var cacheMax = 200_000 { didSet { applyCache() } }
    @Published var cacheCount = 0
    @Published var cacheHits = 0
    @Published var cacheMisses = 0

    @Published var running = false
    @Published var status = "Stopped"
    @Published var lastError: String?
    @Published var requests = 0
    @Published var errors = 0
    @Published var characters = 0
    @Published var recent: [Stats.Entry] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    let stats = Stats()
    private lazy var api = DeepLAPI(config: config, stats: stats)
    private var server: HTTPServer?
    private var refreshScheduled = false
    private var updateWatcher: AnyCancellable?

    var apiKeys: [String] {
        apiKeysRaw.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    var config: DeepLAPI.Config { .init(apiKeys: apiKeys, characterLimit: characterLimit) }

    init() {
        stats.onChange = { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        applyCache()
        refresh()
        if autoStart { start() }
        // Menu-bar app: show update prompts as a standalone alert.
        updateWatcher = Updater.shared.$showPrompt.sink { show in
            if show { DispatchQueue.main.async { Updater.shared.presentAlert() } }
        }
        Updater.shared.startAutomaticChecks()
    }

    func applyCache() {
        TranslationCache.shared.enabled = cacheEnabled
        TranslationCache.shared.maxEntries = max(1_000, cacheMax)
    }

    func clearCache() {
        TranslationCache.shared.clear()
        refresh()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    func refresh() {
        let s = stats.snapshot()
        requests = s.requests; errors = s.errors; characters = s.chars; recent = s.recent
        let cs = TranslationCache.shared.stats
        cacheHits = cs.hits; cacheMisses = cs.misses
        cacheCount = TranslationCache.shared.count
    }

    var serverURL: String { "http://\(listenAll ? (lanAddresses.first ?? "127.0.0.1") : "127.0.0.1"):\(port)" }

    func start() {
        stop()
        lastError = nil
        guard (1...65535).contains(port) else { lastError = "Invalid port"; return }
        api.config = config
        let api = self.api
        let srv = HTTPServer(port: UInt16(port), localhostOnly: !listenAll) { req in await api.handle(req) }
        srv.onStateChange = { [weak self] text, ok in
            Task { @MainActor in
                guard let self else { return }
                self.running = ok
                self.status = ok ? "Listening on \(self.listenAll ? "0.0.0.0" : "127.0.0.1"):\(self.port)" : text.capitalized
                if !ok && text.hasPrefix("failed") { self.lastError = text.contains("48") || text.contains("in use")
                    ? "Port \(self.port) is already in use" : text }
            }
        }
        do {
            try srv.start()
            server = srv
            status = "Starting…"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        server?.stop()
        server = nil
        running = false
        status = "Stopped"
    }

    /// Settings that only need a config swap (no restart).
    func applyAuth() { api.config = config }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { lastError = "Launch at login: \(error.localizedDescription)" }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func generateKey() {
        let key = UUID().uuidString.lowercased() + ":fx"   // ":fx" suffix = DeepL Free-style key
        apiKeysRaw = apiKeysRaw.isEmpty ? key : apiKeysRaw + "\n" + key
        applyAuth()
    }

    /// IPv4 addresses of this Mac (for LAN clients).
    var lanAddresses: [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: host))
            }
        }
        return out
    }

    var exampleCurl: String {
        let auth = apiKeys.first.map { "  -H 'Authorization: DeepL-Auth-Key \($0)' \\\n" } ?? ""
        return """
        curl -X POST http://\(lanAddresses.first ?? "127.0.0.1"):\(port)/v2/translate \\
        \(auth)  -H 'Content-Type: application/json' \\
          -d '{"text":["Hello, world!"],"target_lang":"KO"}'
        """
    }
}

// MARK: - App (menu bar only)

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--serve") { Headless.run() } else { TranslateAPIApp.main() }
    }
}

struct TranslateAPIApp: App {
    @StateObject private var controller = ServerController()

    var body: some Scene {
        // Left-click on the tray icon opens this menu.
        MenuBarExtra {
            TrayMenu().environmentObject(controller)
        } label: {
            Image(systemName: controller.running ? "character.bubble.fill" : "character.bubble")
        }
        .menuBarExtraStyle(.menu)

        Window("Beonyeok", id: "settings") {
            PanelView().environmentObject(controller)
        }
        .windowResizability(.contentSize)
    }
}

/// Native menu: status, start/stop, selectable run-on-start options, settings window.
struct TrayMenu: View {
    @EnvironmentObject var c: ServerController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(c.running ? "● \(c.status)" : "○ Stopped").disabled(true)
        if let e = c.lastError { Text(e).disabled(true) }
        Button(c.running ? "Stop Server" : "Start Server") { c.running ? c.stop() : c.start() }
            .keyboardShortcut("s")
        Button("Copy Server URL (\(c.serverURL))") { copy(c.serverURL) }.disabled(!c.running)
        Divider()
        Toggle("Start Server on Launch", isOn: $c.autoStart)
        Toggle("Launch at Login", isOn: Binding(get: { c.launchAtLogin }, set: { c.setLaunchAtLogin($0) }))
        Toggle("Translation Cache", isOn: $c.cacheEnabled)
        Toggle("Allow LAN Access (0.0.0.0)", isOn: Binding(get: { c.listenAll }, set: { c.listenAll = $0; if c.running { c.start() } }))
        Divider()
        Text("Requests \(c.requests) · Cache hits \(c.cacheHits)").disabled(true)
        CheckForUpdatesButton()
        if let v = Updater.shared.available?.version {
            Button("Install Update \(v)…") { Updater.shared.presentAlert() }
        }
        Button("Settings…") {
            openWindow(id: "settings")
            NSApp.activate()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Beonyeok") { c.stop(); NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct PanelView: View {
    @EnvironmentObject var c: ServerController
    @State private var portText = ""
    @State private var fromLang = "en"
    @State private var toLang = "ko"
    @State private var packConfig: TranslationSession.Configuration?
    @State private var packStatus = ""
    @State private var supported: [Locale.Language] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            serverSettings
            Divider()
            statsView
            Divider()
            cacheView
            Divider()
            languagePacks
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 400)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in c.refresh() }
        .onAppear {
            portText = String(c.port)
            Task { supported = await AppleEngine.shared.supportedLanguages().sorted { $0.minimalIdentifier < $1.minimalIdentifier } }
        }
        .translationTask(packConfig) { session in
            do {
                try await session.prepareTranslation()
                packStatus = "Installed ✓"
            } catch { packStatus = "Failed: \(error.localizedDescription)" }
            await refreshPackStatus()
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(c.running ? .green : .secondary).frame(width: 9, height: 9)
                Text("Beonyeok").font(.headline)
                Text("DeepL-compatible · Apple Translation").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(c.running ? "Stop" : "Start") { c.running ? c.stop() : c.start() }
                    .buttonStyle(.borderedProminent).tint(c.running ? .red : .accentColor).controlSize(.small)
            }
            Text(c.status).font(.caption.monospaced()).foregroundStyle(.secondary)
            if let e = c.lastError { Text(e).font(.caption).foregroundStyle(.red) }
            if c.running {
                let hosts = c.listenAll ? ["127.0.0.1"] + c.lanAddresses : ["127.0.0.1"]
                ForEach(hosts, id: \.self) { h in
                    HStack {
                        Text("http://\(h):\(String(c.port))").font(.caption.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button { copy("http://\(h):\(String(c.port))") } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Copy server URL (use as the DeepL client's server_url)")
                    }
                }
            }
        }
    }

    private var serverSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Port")
                TextField("8989", text: $portText).frame(width: 70).textFieldStyle(.roundedBorder)
                    .onSubmit(applyPort)
                Toggle("All interfaces (0.0.0.0)", isOn: $c.listenAll)
                    .toggleStyle(.checkbox)
                    .help("Off = 127.0.0.1 only (this Mac)")
                Spacer()
                Button("Apply") { applyPort() }.controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("API keys").font(.subheadline)
                    Text(c.apiKeys.isEmpty ? "— none: no auth required" : "— \(c.apiKeys.count) key(s)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Generate") { c.generateKey() }.controlSize(.small)
                }
                TextEditor(text: $c.apiKeysRaw)
                    .font(.caption.monospaced())
                    .frame(height: 38)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                    .onChange(of: c.apiKeysRaw) { c.applyAuth() }
                Text("Clients send `Authorization: DeepL-Auth-Key <key>`. One key per line.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Toggle("Start server on launch", isOn: $c.autoStart).toggleStyle(.checkbox)
                Toggle("Launch at login", isOn: Binding(get: { c.launchAtLogin }, set: { c.setLaunchAtLogin($0) }))
                    .toggleStyle(.checkbox)
            }
        }
    }

    private var statsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                stat("Requests", c.requests)
                stat("Errors", c.errors)
                stat("Characters", c.characters)
                Spacer()
                Button("Reset usage") { c.stats.resetUsage() }.controlSize(.small)
                    .help("Resets the character_count reported by /v2/usage")
            }
            if c.recent.isEmpty {
                Text("No requests yet").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(c.recent.prefix(6)) { e in
                        HStack(spacing: 6) {
                            Text(e.time, style: .time).foregroundStyle(.secondary)
                            Text("\(e.status)").foregroundStyle(e.status >= 400 ? .red : .green)
                            Text(e.summary).lineLimit(1).truncationMode(.tail)
                            Spacer()
                            Text("\(e.ms)ms").foregroundStyle(.secondary)
                        }
                        .font(.caption2.monospaced())
                        .help("\(e.remote) · \(e.summary)")
                    }
                }
            }
        }
    }

    private var cacheView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Translation cache", isOn: $c.cacheEnabled).toggleStyle(.checkbox)
                Spacer()
                Button("Clear cache") { c.clearCache() }.controlSize(.small)
            }
            HStack(spacing: 14) {
                stat("Entries", c.cacheCount)
                stat("Hits", c.cacheHits)
                stat("Misses", c.cacheMisses)
                let total = c.cacheHits + c.cacheMisses
                VStack(alignment: .leading, spacing: 0) {
                    Text(total > 0 ? "\(Int(Double(c.cacheHits) / Double(total) * 100))%" : "—")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                    Text("Hit rate").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Stepper("Max \(c.cacheMax / 1000)k", value: $c.cacheMax, in: 10_000...5_000_000, step: 50_000)
                    .font(.caption).fixedSize()
            }
            Text("Stored per line in ~/Library/Application Support/Beonyeok/cache.sqlite (kept across restarts, least-recently-used entries evicted).")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var languagePacks: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Language packs (on-device models)").font(.subheadline)
            HStack {
                langPicker($fromLang)
                Image(systemName: "arrow.right")
                langPicker($toLang)
                Button("Download") {
                    packStatus = "Preparing…"
                    let cfg = TranslationSession.Configuration(source: Locale.Language(identifier: fromLang),
                                                               target: Locale.Language(identifier: toLang))
                    if packConfig == cfg { packConfig?.invalidate() } else { packConfig = cfg }
                }
                .controlSize(.small)
            }
            if !packStatus.isEmpty { Text(packStatus).font(.caption).foregroundStyle(.secondary) }
        }
        .onChange(of: fromLang) { Task { await refreshPackStatus() } }
        .onChange(of: toLang) { Task { await refreshPackStatus() } }
        .task { await refreshPackStatus() }
    }

    private var footer: some View {
        HStack {
            Button("Copy curl example") { copy(c.exampleCurl) }.controlSize(.small)
            Spacer()
            Button("Close") { NSApp.keyWindow?.close() }.controlSize(.small)
            Button("Quit") { c.stop(); NSApp.terminate(nil) }.controlSize(.small)
        }
    }

    // MARK: Helpers

    private func stat(_ label: String, _ v: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(v)").font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func langPicker(_ sel: Binding<String>) -> some View {
        Picker("", selection: sel) {
            ForEach(supported, id: \.minimalIdentifier) { l in
                Text(Locale.current.localizedString(forIdentifier: l.minimalIdentifier) ?? l.minimalIdentifier)
                    .tag(l.minimalIdentifier)
            }
        }
        .labelsHidden()
        .frame(width: 120)
    }

    private func refreshPackStatus() async {
        let s = await AppleEngine.shared.status(Locale.Language(identifier: fromLang), Locale.Language(identifier: toLang))
        packStatus = switch s {
        case .installed: "\(fromLang) → \(toLang): installed ✓"
        case .supported: "\(fromLang) → \(toLang): not installed — press Download"
        case .unsupported: "\(fromLang) → \(toLang): not supported"
        @unknown default: ""
        }
    }

    private func applyPort() {
        if let p = Int(portText), (1...65535).contains(p) { c.port = p } else { portText = String(c.port) }
        c.start()
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: - Headless

/// Beonyeok --serve [--port 8989] [--localhost] [--key KEY]...  (no UI; for servers/tests)
enum Headless {
    static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let a = CommandLine.arguments
        func value(_ f: String) -> String? { a.firstIndex(of: f).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        let port = UInt16(value("--port") ?? "") ?? 8989
        let keys = a.indices.filter { a[$0] == "--key" && $0 + 1 < a.count }.map { a[$0 + 1] }
        let stats = Stats()
        let api = DeepLAPI(config: .init(apiKeys: keys, characterLimit: 0), stats: stats)
        stats.onChange = {
            if let e = stats.snapshot().recent.first { print("\(e.status) \(e.ms)ms \(e.remote) \(e.summary)") }
        }
        let server = HTTPServer(port: port, localhostOnly: a.contains("--localhost")) { await api.handle($0) }
        server.onStateChange = { s, _ in print("server \(s) on \(a.contains("--localhost") ? "127.0.0.1" : "0.0.0.0"):\(port)") }
        do { try server.start() } catch { print("failed: \(error)"); exit(1) }
        dispatchMain()
    }
}
