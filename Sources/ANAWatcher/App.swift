import SwiftUI
import WebKit
import AppKit
import Foundation

struct MonitorCondition: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = "新しい監視条件"
    var origin = "HND"
    var destination = "JFK"
    var departureFrom = Date()
    var departureTo = Date().addingTimeInterval(30 * 86400)
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
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ANAWatcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settingsURL = dir.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            conditions = saved.conditions
            ntfyTopic = saved.ntfyTopic
            signatures = saved.signatures
        }
        if ntfyTopic.isEmpty {
            ntfyTopic = "ana-award-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        save()
    }

    func save() {
        let saved = Settings(conditions: conditions, ntfyTopic: ntfyTopic, signatures: signatures)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: settingsURL, options: .atomic) }
    }

    func addCondition() { conditions.append(MonitorCondition()); save() }
    func removeCondition(_ id: UUID) {
        conditions.removeAll { $0.id == id }
        signatures.removeValue(forKey: id.uuidString)
        save()
    }
    func registerCurrentPage(_ webView: WKWebView, for id: UUID) {
        guard let url = webView.url?.absoluteString, !url.isEmpty else {
            status = "ANAの検索結果ページを開いてから登録してください"
            return
        }
        guard let index = conditions.firstIndex(where: { $0.id == id }) else { return }
        conditions[index].monitorURL = url
        status = "監視ページを登録しました"
        save()
    }
}

@MainActor
final class PopupWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let window: NSWindow

    init(url: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        window.title = "ANA 特典航空券"
        window.contentView = webView
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        webView.load(URLRequest(url: url))
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let child = PopupWindowController(configuration: configuration)
        WindowRegistry.shared.add(child)
        child.show()
        return child.webView
    }

    private init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        window.title = "ANA 特典航空券"
        window.contentView = webView
        window.delegate = self
        window.center()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let title = webView.title, !title.isEmpty { window.title = "ANA - \(title)" }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            let child = PopupWindowController(url: url)
            WindowRegistry.shared.add(child)
            child.show()
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func windowWillClose(_ notification: Notification) {
        WindowRegistry.shared.remove(self)
    }
}

@MainActor
final class WindowRegistry {
    static let shared = WindowRegistry()
    private var windows: [PopupWindowController] = []
    func add(_ window: PopupWindowController) { windows.append(window) }
    func remove(_ window: PopupWindowController) { windows.removeAll { $0 === window } }
    func open(url: URL) {
        let controller = PopupWindowController(url: url)
        windows.append(controller)
        controller.show()
    }
}

@MainActor
final class MainBrowserCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView

    init(mainURL: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: mainURL))
    }

    func openAwardPage() {
        WindowRegistry.shared.open(
            url: URL(string: "https://www.ana.co.jp/ja/jp/guide/amc/award/international/application/")!
        )
    }

    func openAwardPageInMainWindow() {
        webView.load(URLRequest(url: URL(string: "https://www.ana.co.jp/ja/jp/guide/amc/award/international/application/")!))
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let child = PopupWindowController(configuration: configuration)
        WindowRegistry.shared.add(child)
        child.show()
        return child.webView
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            let child = PopupWindowController(url: url)
            WindowRegistry.shared.add(child)
            child.show()
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}

struct MainBrowserView: NSViewRepresentable {
    let coordinator: MainBrowserCoordinator
    func makeNSView(context: Context) -> WKWebView { coordinator.webView }
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
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
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

struct AvailabilityResult {
    let available: Bool
    let signature: String
    let detail: String
}

func detectAvailability(_ text: String) -> AvailabilityResult {
    let lower = text.lowercased()
    let positive = ["空席あり", "残席あり", "available", "seats available"]
    let negative = ["空席なし", "満席", "not available", "sold out"]
    let hasPositive = positive.contains { lower.contains($0) }
    let hasNegative = negative.contains { lower.contains($0) }
    guard hasPositive && !hasNegative else {
        return AvailabilityResult(available: false, signature: "", detail: "空席ありを示す表示はありません")
    }
    let details = text.split(separator: "\n").map(String.init).filter { line in
        positive.contains { line.lowercased().contains($0) }
    }
    let detail = details.joined(separator: " | ")
    return AvailabilityResult(available: true, signature: detail.isEmpty ? "available" : detail, detail: detail.isEmpty ? "空席あり表示を検出しました" : detail)
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
        stop(); store.monitoring = true; store.status = "監視中（10分間隔）"; scanNow()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in Task { @MainActor in self?.scanNow() } }
    }
    func stop() { timer?.invalidate(); timer = nil; store.monitoring = false; store.status = "停止中" }
    private func scanNow() {
        guard store.monitoring else { return }
        Task { @MainActor in
            let targets = store.conditions.filter { $0.enabled && !$0.monitorURL.isEmpty }
            store.lastScan = Date().formatted(date: .numeric, time: .standard)
            guard !targets.isEmpty else { store.status = "監視ページが未登録です"; return }
            for condition in targets {
                guard let url = URL(string: condition.monitorURL) else { continue }
                do {
                    let (pageURL, text) = try await scanner.scan(url: url)
                    let result = detectAvailability(text)
                    let key = condition.id.uuidString
                    let previous = store.signatures[key] ?? ""
                    if result.available && result.signature != previous {
                        await NtfyNotifier.send(topic: store.ntfyTopic, title: "✈️ ANA特典航空券 空席発生", message: "\(condition.origin) → \(condition.destination)\n\(condition.cabin) / \(condition.passengers)名\n\(result.detail)", clickURL: pageURL)
                        store.signatures[key] = result.signature
                        store.status = "空席を検出してiPhoneへ通知しました"
                    } else {
                        store.status = "確認済み：新しい空席なし"
                    }
                } catch { store.status = "ANAページの確認に失敗しました" }
            }
            store.save()
        }
    }
}

struct ContentView: View {
    @StateObject private var store: Store
    @StateObject private var engine: MonitorEngine
    private let browser: MainBrowserCoordinator

    init() {
        let store = Store()
        _store = StateObject(wrappedValue: store)
        _engine = StateObject(wrappedValue: MonitorEngine(store: store))
        browser = MainBrowserCoordinator(mainURL: URL(string: "https://www.ana.co.jp/ja/jp/")!)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ANA特典航空券 空席監視").font(.title.bold())
                    Text("ANAの新しいタブ／新しいウインドウを独立したANAウインドウとして表示します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("特典航空券ページを新しいウインドウで開く") { browser.openAwardPage() }
                Button(store.monitoring ? "監視停止" : "監視開始") {
                    if store.monitoring { engine.stop() } else { engine.start() }
                }.buttonStyle(.borderedProminent)
            }

            HStack {
                Text("状態: \(store.status)").font(.caption)
                Spacer()
                Text("最終確認: \(store.lastScan)").font(.caption2).foregroundStyle(.secondary)
            }

            HStack {
                ForEach(store.conditions) { condition in
                    Button("現在のANAページを「\(condition.name)」に登録") {
                        store.registerCurrentPage(browser.webView, for: condition.id)
                    }.font(.caption)
                }
                Button("監視条件を追加") { store.addCondition() }.font(.caption)
                Spacer()
            }

            MainBrowserView(coordinator: browser).frame(minHeight: 550)

            HStack {
                Text("iPhone通知トピック:").font(.caption).foregroundStyle(.secondary)
                Text(store.ntfyTopic).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Text("ANAパスワードは保存しません").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 1120, minHeight: 760)
    }
}

@main
struct ANAWatcherApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
