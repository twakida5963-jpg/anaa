import SwiftUI
import WebKit
import Foundation

struct MonitorCondition: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = "新しい監視条件"
    var origin = "HND"
    var destination = "JFK"
    var departureFrom = Date()
    var departureTo = Date().addingTimeInterval(30 * 86400)
    var returnFrom = Date()
    var returnTo = Date().addingTimeInterval(30 * 86400)
    var passengers = 1
    var cabin = "Business"
    var enabled = true
    var monitorURL = ""
}

struct Settings: Codable {
    let conditions: [MonitorCondition]
    let ntfyTopic: String
    let signatures: [String: String]
}

@MainActor
final class Store: ObservableObject {
    @Published var conditions: [MonitorCondition] = []
    @Published var monitoring = false
    @Published var status = "準備完了"
    @Published var lastScan = "未実行"
    @Published var ntfyTopic = ""
    @Published var signatures: [String: String] = [:]
    private let settingsURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ANAWatcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settingsURL = dir.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: settingsURL), let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            conditions = saved.conditions
            ntfyTopic = saved.ntfyTopic
            signatures = saved.signatures
        }
        if ntfyTopic.isEmpty { ntfyTopic = "ana-award-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
        save()
    }

    func save() {
        let saved = Settings(conditions: conditions, ntfyTopic: ntfyTopic, signatures: signatures)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: settingsURL, options: .atomic) }
    }
    func addCondition() { conditions.append(MonitorCondition()); save() }
    func removeCondition(_ id: UUID) { conditions.removeAll { $0.id == id }; signatures.removeValue(forKey: id.uuidString); save() }
    func registerCurrentPage(_ webView: WKWebView, for id: UUID) {
        guard let url = webView.url?.absoluteString, !url.isEmpty else { status = "ANAの検索結果ページを開いてから登録してください"; return }
        guard let index = conditions.firstIndex(where: { $0.id == id }) else { return }
        conditions[index].monitorURL = url
        status = "監視ページを登録しました"
        save()
    }
}

@MainActor
final class BrowserTab: ObservableObject, Identifiable {
    let id = UUID()
    let webView: WKWebView
    @Published var title = "ANA"
    init(configuration: WKWebViewConfiguration, request: URLRequest? = nil) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        if let request { webView.load(request) }
    }
}

@MainActor
final class BrowserManager: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var tabs: [BrowserTab] = []
    @Published var selectedTabID: UUID?
    private let sharedProcessPool = WKProcessPool()

    override init() { super.init(); openInitialTab() }

    private func makeConfiguration(from base: WKWebViewConfiguration? = nil) -> WKWebViewConfiguration {
        let config = base ?? WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.processPool = sharedProcessPool
        return config
    }

    @discardableResult
    func addTab(request: URLRequest? = nil, configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        let tab = BrowserTab(configuration: makeConfiguration(from: configuration), request: request)
        tab.webView.navigationDelegate = self
        tab.webView.uiDelegate = self
        tabs.append(tab)
        selectedTabID = tab.id
        return tab
    }

    func openInitialTab() { addTab(request: URLRequest(url: URL(string: "https://www.ana.co.jp/ja/jp/")!)) }
    func selectedTab() -> BrowserTab? { guard let selectedTabID else { return tabs.first }; return tabs.first(where: { $0.id == selectedTabID }) ?? tabs.first }
    func close(tab: BrowserTab) {
        let id = tab.id
        tabs.removeAll { $0.id == id }
        if tabs.isEmpty { openInitialTab() } else if selectedTabID == id { selectedTabID = tabs.last?.id }
    }
    func newBlankTab() { _ = addTab() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let tab = tabs.first(where: { $0.webView === webView }) { tab.title = (webView.title?.isEmpty == false ? webView.title! : "ANA") }
    }

    // Handles <a target="_blank"> and window.open().
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let tab = addTab(request: navigationAction.request, configuration: configuration)
        return tab.webView
    }

    // Fallback for pages that use a navigation action with no target frame.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame == nil {
            _ = addTab(request: navigationAction.request, configuration: webView.configuration)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {}
}

struct BrowserTabView: NSViewRepresentable {
    let tab: BrowserTab
    func makeNSView(context: Context) -> WKWebView { tab.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

@MainActor
final class PageScanner: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var continuation: CheckedContinuation<(String, String), Error>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func scan(url: URL) async throws -> (String, String) {
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
        webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] result, error in
            if let error { self?.finish(.failure(error)); return }
            self?.finish(.success((webView.url?.absoluteString ?? "", result as? String ?? "")))
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    private func finish(_ result: Result<(String, String), Error>) {
        timeoutTask?.cancel(); timeoutTask = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
    enum ScanError: Error { case timeout }
}

struct AvailabilityResult { let available: Bool; let signature: String; let detail: String }

func detectAvailability(_ text: String) -> AvailabilityResult {
    let lower = text.lowercased()
    let positive = ["空席あり", "残席あり", "available", "seats available"]
    let negative = ["空席なし", "満席", "not available", "sold out"]
    let hasPositive = positive.contains { lower.contains($0) }
    let hasNegative = negative.contains { lower.contains($0) }
    if hasPositive && !hasNegative {
        let lines = text.split(separator: "\n").map(String.init)
        let detail = lines.filter { line in positive.contains { line.lowercased().contains($0) } }.joined(separator: " | ")
        return AvailabilityResult(available: true, signature: detail.isEmpty ? "available" : detail, detail: detail.isEmpty ? "空席あり表示を検出しました" : detail)
    }
    return AvailabilityResult(available: false, signature: "", detail: "空席ありを示す表示はありません")
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

@MainActor
final class MonitorEngine: ObservableObject {
    private let store: Store
    private let scanner = PageScanner()
    private var timer: Timer?
    init(store: Store) { self.store = store }
    func start() {
        stop()
        store.monitoring = true
        store.status = "監視中（10分間隔）"
        scanNow()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in Task { @MainActor in self?.scanNow() } }
    }
    func stop() { timer?.invalidate(); timer = nil; store.monitoring = false; store.status = "停止中" }
    private func scanNow() {
        guard store.monitoring else { return }
        Task { @MainActor in
            let targets = store.conditions.filter { $0.enabled && !$0.monitorURL.isEmpty }
            store.lastScan = Date().formatted(date: .numeric, time: .standard)
            if targets.isEmpty { store.status = "監視ページが未登録です"; return }
            for condition in targets {
                guard let url = URL(string: condition.monitorURL) else { continue }
                do {
                    let (pageURL, text) = try await scanner.scan(url: url)
                    let result = detectAvailability(text)
                    let key = condition.id.uuidString
                    let previous = store.signatures[key] ?? ""
                    if result.available && result.signature != previous {
                        await NtfyNotifier.send(topic: store.ntfyTopic,
                            title: "✈️ ANA特典航空券 空席発生",
                            message: "\(condition.origin) → \(condition.destination)\n\(condition.cabin) / \(condition.passengers)名\n\(result.detail)",
                            clickURL: pageURL)
                        store.signatures[key] = result.signature
                        store.status = "空席を検出してiPhoneへ通知しました"
                    } else {
                        store.status = "確認済み：新しい空席なし"
                    }
                } catch {
                    store.status = "ANAページの確認に失敗しました"
                }
            }
            store.save()
        }
    }
}

struct ContentView: View {
    @StateObject private var store: Store
    @StateObject private var engine: MonitorEngine
    @StateObject private var browser = BrowserManager()

    init() {
        let store = Store()
        _store = StateObject(wrappedValue: store)
        _engine = StateObject(wrappedValue: MonitorEngine(store: store))
    }

    private func openAwardReservation() {
        guard let tab = browser.selectedTab() else { return }
        let js = """
        (() => {
          const els = [...document.querySelectorAll('a,button,[role="button"]')];
          const target = els.find(el => {
            const t = (el.innerText || el.textContent || '').replace(/\\s+/g, '');
            return t.includes('特典航空券の新規予約') || t.includes('特典航空券の新規予約・申し込み') || t.includes('特典航空券予約') || t.includes('特典航空券の予約');
          });
          if (target) { target.click(); return true; }
          return false;
        })();
        """
        tab.webView.evaluateJavaScript(js) { result, _ in
            guard !((result as? Bool) ?? false) else { return }
            tab.webView.load(URLRequest(url: URL(string: "https://www.ana.co.jp/ja/jp/guide/amc/award/")!))
        }
    }

    var body: some View {
        NavigationSplitView {
            List {
                Section("状態") {
                    Label(store.monitoring ? "監視中・10分間隔" : "停止中", systemImage: store.monitoring ? "checkmark.circle.fill" : "pause.circle")
                    Text(store.status).font(.caption).foregroundStyle(.secondary)
                    Text("最終確認: \(store.lastScan)").font(.caption2).foregroundStyle(.secondary)
                }
                Section("監視条件") {
                    ForEach(store.conditions) { condition in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(condition.name).font(.headline)
                            Text("\(condition.origin) → \(condition.destination)")
                            Text("\(condition.cabin) / \(condition.passengers)名").font(.caption)
                            Text(condition.monitorURL.isEmpty ? "監視ページ未登録" : "監視ページ登録済み").font(.caption2).foregroundStyle(condition.monitorURL.isEmpty ? .orange : .green)
                        }
                        .swipeActions {
                            Button(role: .destructive) { store.removeCondition(condition.id) } label: { Label("削除", systemImage: "trash") }
                        }
                    }
                    Button { store.addCondition() } label: { Label("監視条件を追加", systemImage: "plus") }
                }
            }
            .navigationTitle("ANA特典航空券")
        } detail: {
            VStack(spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ANA特典航空券 空席監視").font(.largeTitle.bold())
                        Text("ANAの新しいタブで開くページにも対応しています。").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("新しいタブ") { browser.newBlankTab() }.buttonStyle(.bordered)
                    Button("特典航空券予約を開く") { openAwardReservation() }.buttonStyle(.bordered)
                    Button(store.monitoring ? "監視停止" : "監視開始") { if store.monitoring { engine.stop() } else { engine.start() } }.buttonStyle(.borderedProminent)
                }

                HStack {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(browser.tabs) { tab in
                                HStack(spacing: 5) {
                                    Button { browser.selectedTabID = tab.id } label: {
                                        HStack(spacing: 5) { Image(systemName: "globe"); Text(tab.title.isEmpty ? "ANA" : tab.title).lineLimit(1) }
                                    }.buttonStyle(.plain)
                                    Button { browser.close(tab: tab) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(browser.selectedTabID == tab.id ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                        }
                    }
                    ForEach(store.conditions) { condition in
                        Button("現在のページを「\(condition.name)」に登録") { if let tab = browser.selectedTab() { store.registerCurrentPage(tab.webView, for: condition.id) } }.font(.caption)
                    }
                }

                if let tab = browser.selectedTab() { BrowserTabView(tab: tab).frame(minHeight: 520) }

                HStack {
                    Text("iPhone通知:").font(.caption).foregroundStyle(.secondary)
                    Text(store.ntfyTopic).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Text("ANAパスワードはアプリの設定ファイルに保存しません").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .frame(minWidth: 1100, minHeight: 760)
    }
}

@main
struct ANAWatcherApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
