import SwiftUI
import WebKit

struct MonitorCondition: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = "新しい監視条件"
    var origin = "HND"
    var destination = "JFK"
    var departureFrom = Date()
    var departureTo = Date(timeIntervalSinceNow: 30 * 86400)
    var returnFrom = Date()
    var returnTo = Date(timeIntervalSinceNow: 30 * 86400)
    var passengers = 1
    var cabin = "Business"
    var enabled = true
    var monitorURL = ""
}

struct Settings: Codable {
    let conditions: [MonitorCondition]
    let ntfyTopic: String
    let lastAvailabilitySignatures: [String: String]
}

@MainActor
final class Store: ObservableObject {
    @Published var conditions: [MonitorCondition] = []
    @Published var monitoring = false
    @Published var status = "準備完了"
    @Published var ntfyTopic: String
    @Published var lastScan = "未実行"
    @Published var lastAvailabilitySignatures: [String: String] = [:]
    private let settingsURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ANAWatcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settingsURL = dir.appendingPathComponent("settings.json")
        var topic = ""
        if let data = try? Data(contentsOf: settingsURL), let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            conditions = saved.conditions
            topic = saved.ntfyTopic
            lastAvailabilitySignatures = saved.lastAvailabilitySignatures
        }
        ntfyTopic = topic.isEmpty ? "ana-award-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "") : topic
        save()
    }

    func save() {
        let s = Settings(conditions: conditions, ntfyTopic: ntfyTopic, lastAvailabilitySignatures: lastAvailabilitySignatures)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: settingsURL, options: .atomic) }
    }

    func add() { conditions.append(MonitorCondition()); save() }
    func remove(_ id: UUID) { conditions.removeAll { $0.id == id }; lastAvailabilitySignatures.removeValue(forKey: id.uuidString); save() }

    func registerCurrentPage(_ webView: WKWebView, for id: UUID) {
        guard let url = webView.url?.absoluteString, !url.isEmpty else { status = "ANAのページを開いてから登録してください"; return }
        if let i = conditions.firstIndex(where: { $0.id == id }) {
            conditions[i].monitorURL = url
            status = "監視ページを登録しました"
            save()
        }
    }

    func start() { monitoring = true; status = "監視中（10分間隔）" }
    func stop() { monitoring = false; status = "停止中" }
}

struct ANAWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView {
        webView.load(URLRequest(url: URL(string: "https://www.ana.co.jp/ja/jp/guide/amc/award/")!))
        return webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct PageSnapshot { let url: String; let text: String }

@MainActor
final class PageScanner: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var continuation: CheckedContinuation<PageSnapshot, Error>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func scan(url: URL) async throws -> PageSnapshot {
        timeoutTask?.cancel()
        return try await withCheckedThrowingContinuation { c in
            continuation = c
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45))
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(ScanError.timeout))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.body ? document.body.innerText : '';" ) { [weak self] result, error in
            if let error { self?.finish(.failure(error)); return }
            self?.finish(.success(PageSnapshot(url: webView.url?.absoluteString ?? "", text: result as? String ?? "")))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<PageSnapshot, Error>) {
        timeoutTask?.cancel(); timeoutTask = nil
        guard let c = continuation else { return }
        continuation = nil
        c.resume(with: result)
    }

    enum ScanError: LocalizedError {
        case timeout
        var errorDescription: String? { "ANAページの読み込みがタイムアウトしました" }
    }
}

struct AvailabilityResult {
    let available: Bool
    let signature: String
    let detail: String
}

func detectAvailability(in text: String) -> AvailabilityResult {
    let normalized = text.replacingOccurrences(of: "\r", with: "\n")
    let yes = ["空席あり", "残席あり", "空席：あり", "空席:あり", "available", "seats available"]
    let no = ["空席なし", "満席", "設定なし", "受付終了", "not available", "sold out"]
    let lower = normalized.lowercased()
    let hasYes = yes.contains { lower.contains($0.lowercased()) }
    let hasNo = no.contains { lower.contains($0.lowercased()) }
    let details = normalized.split(separator: "\n").map(String.init).filter { line in yes.contains { line.lowercased().contains($0.lowercased()) } }
    if hasYes && !hasNo {
        let d = details.joined(separator: " | ")
        return AvailabilityResult(available: true, signature: d, detail: d)
    }
    return AvailabilityResult(available: false, signature: "", detail: "空席ありを示す明確な表示は検出されませんでした")
}

@MainActor
final class MonitorEngine: ObservableObject {
    private let store: Store
    private let scanner = PageScanner()
    private var timer: Timer?

    init(store: Store) { self.store = store }

    func start() {
        stop()
        scanNow()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanNow() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func scanNow() {
        guard store.monitoring else { return }
        Task { @MainActor in
            store.status = "空席を確認中…"
            let targets = store.conditions.filter { $0.enabled && !$0.monitorURL.isEmpty }
            if targets.isEmpty {
                store.status = "監視ページ未登録：ANAで検索後「現在のANAページを登録」を押してください"
                store.lastScan = Date().formatted(date: .numeric, time: .standard)
                return
            }
            for condition in targets {
                guard let url = URL(string: condition.monitorURL) else { continue }
                do {
                    let page = try await scanner.scan(url: url)
                    let r = detectAvailability(in: page.text)
                    let key = condition.id.uuidString
                    let previous = store.lastAvailabilitySignatures[key] ?? ""
                    if r.available && r.signature != previous {
                        await NtfyNotifier.send(topic: store.ntfyTopic, title: "✈️ ANA特典航空券 空席発生", message: "\(condition.origin) → \(condition.destination)\n\(condition.cabin) / \(condition.passengers)名\n\(r.detail)", clickURL: page.url)
                        store.lastAvailabilitySignatures[key] = r.signature
                        store.status = "空席を検出してiPhoneへ通知しました"
                    } else {
                        store.status = "確認済み：空席発生なし"
                    }
                } catch {
                    store.status = "ANAページの確認に失敗しました"
                }
            }
            store.lastScan = Date().formatted(date: .numeric, time: .standard)
            store.save()
        }
    }
}

enum NtfyNotifier {
    static func send(topic: String, title: String, message: String, clickURL: String) async {
        guard let url = URL(string: "https://ntfy.sh/\(topic)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(title, forHTTPHeaderField: "Title")
        request.setValue("high", forHTTPHeaderField: "Priority")
        request.setValue(clickURL, forHTTPHeaderField: "Click")
        request.httpBody = message.data(using: .utf8)
        _ = try? await URLSession.shared.data(for: request)
    }
}

struct ContentView: View {
    @StateObject private var store: Store
    @StateObject private var monitor: MonitorEngine
    @State private var webView = WKWebView()

    init() {
        let s = Store()
        _store = StateObject(wrappedValue: s)
        _monitor = StateObject(wrappedValue: MonitorEngine(store: s))
    }

    var body: some View {
        NavigationSplitView {
            List {
                Section("監視") {
                    Label(store.monitoring ? "監視中・10分間隔" : "停止中", systemImage: store.monitoring ? "checkmark.circle.fill" : "pause.circle")
                    Text(store.status).font(.caption).foregroundStyle(.secondary)
                    Text("最終確認: \(store.lastScan)").font(.caption2).foregroundStyle(.secondary)
                }
                Section("監視条件") {
                    if store.conditions.isEmpty { Text("監視条件を追加してください").foregroundStyle(.secondary) }
                    ForEach(store.conditions) { condition in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(condition.name).font(.headline)
                            Text("\(condition.origin) → \(condition.destination)")
                            Text("\(condition.cabin) / \(condition.passengers)名").font(.caption).foregroundStyle(.secondary)
                            Text(condition.monitorURL.isEmpty ? "監視ページ未登録" : "監視ページ登録済み").font(.caption2).foregroundStyle(condition.monitorURL.isEmpty ? .orange : .green)
                        }
                        .swipeActions {
                            Button(role: .destructive) { store.remove(condition.id) } label: { Label("削除", systemImage: "trash") }
                        }
                    }
                    Button { store.add() } label: { Label("監視条件を追加", systemImage: "plus") }
                }
            }
            .navigationTitle("ANA特典航空券")
        } detail: {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ANA特典航空券 空席監視").font(.largeTitle.bold())
                        Text("ANAにログインし、希望する特典航空券の検索・特典カレンダー画面を表示してください。").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(store.monitoring ? "監視停止" : "監視開始") {
                        if store.monitoring { store.stop(); monitor.stop() } else { store.start(); monitor.start() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                HStack {
                    ForEach(store.conditions) { condition in
                        Button("現在のANAページを「\(condition.name)」に登録") { store.registerCurrentPage(webView, for: condition.id) }
                            .font(.caption)
                    }
                    Spacer()
                }
                ANAWebView(webView: webView).frame(minHeight: 520)
                HStack {
                    Text("iPhone通知トピック:").font(.caption).foregroundStyle(.secondary)
                    Text(store.ntfyTopic).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Text("ANAパスワードは保存しません").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .frame(minWidth: 1050, minHeight: 700)
    }
}

@main
struct ANAWatcherApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
