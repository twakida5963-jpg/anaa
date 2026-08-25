import SwiftUI
import WebKit

// MARK: - Model

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
}

struct Settings: Codable {
    let conditions: [MonitorCondition]
    let ntfyTopic: String
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var conditions: [MonitorCondition] = []
    @Published var monitoring = false
    @Published var status = "準備完了"
    @Published var ntfyTopic: String

    private let settingsURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ANAWatcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settingsURL = dir.appendingPathComponent("settings.json")

        var topic = ""
        if let data = try? Data(contentsOf: settingsURL),
           let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            conditions = saved.conditions
            topic = saved.ntfyTopic
        }
        if topic.isEmpty {
            topic = "ana-award-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        }
        ntfyTopic = topic
        save()
    }

    func save() {
        let saved = Settings(conditions: conditions, ntfyTopic: ntfyTopic)
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }

    func add() {
        conditions.append(MonitorCondition())
        save()
    }

    func remove(_ id: UUID) {
        conditions.removeAll { $0.id == id }
        save()
    }

    func start() {
        monitoring = true
        status = "監視中（10分間隔）"
    }

    func stop() {
        monitoring = false
        status = "停止中"
    }
}

// MARK: - Web View

struct ANAWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView.configuration.preferences.isElementFullscreenEnabled = true
        webView.load(URLRequest(url: URL(string: "https://www.ana.co.jp/ja/jp/guide/amc/award/")!))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - App

struct ContentView: View {
    @StateObject private var store = Store()
    @State private var webView = WKWebView()

    var body: some View {
        NavigationSplitView {
            List {
                Section("監視") {
                    Label(store.monitoring ? "監視中・10分間隔" : "停止中",
                          systemImage: store.monitoring ? "checkmark.circle.fill" : "pause.circle")
                    Text(store.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("監視条件") {
                    if store.conditions.isEmpty {
                        Text("監視条件を追加してください")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(store.conditions) { condition in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(condition.name).font(.headline)
                            Text("\(condition.origin) → \(condition.destination)")
                            Text("\(condition.cabin) / \(condition.passengers)名")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("出発: \(condition.departureFrom.formatted(date: .numeric, time: .omitted)) ～ \(condition.departureTo.formatted(date: .numeric, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                store.remove(condition.id)
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                    }

                    Button {
                        store.add()
                    } label: {
                        Label("監視条件を追加", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("ANA特典航空券")
        } detail: {
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ANA特典航空券 空席監視")
                            .font(.largeTitle.bold())
                        Text("ANA公式の特典航空券ページを開き、ユーザー自身がログインします。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(store.monitoring ? "監視停止" : "監視開始") {
                        store.monitoring ? store.stop() : store.start()
                    }
                    .buttonStyle(.borderedProminent)
                }

                ANAWebView(webView: webView)
                    .frame(minHeight: 500)

                HStack {
                    Text("iPhone通知トピック:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(store.ntfyTopic)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Text("パスワードはアプリの設定ファイルに保存しません")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .frame(minWidth: 1050, minHeight: 700)
    }
}

struct ANAWatcherApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

@main
struct MainEntry: App {
    var body: some Scene {
        ANAWatcherApp().body
    }
}
