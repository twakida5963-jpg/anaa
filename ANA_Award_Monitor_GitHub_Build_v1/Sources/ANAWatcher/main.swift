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
}

@MainActor
final class Store: ObservableObject {
    @Published var conditions: [MonitorCondition] = []
    @Published var monitoring = false
    @Published var status = "準備完了"
    @Published var ntfyTopic: String

    private let settingsURL: URL

    init() {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ANAWatcher", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        settingsURL = dir.appendingPathComponent("settings.json")

        var topic = ""
        if let d = try? Data(contentsOf: settingsURL),
           let s = try? JSONDecoder().decode(Settings.self, from: d) {
            conditions = s.conditions
            topic = s.ntfyTopic
        }
        if topic.isEmpty {
            topic = "ana-award-\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
        }
        ntfyTopic = topic
        save()
    }

    func save() {
        let s = Settings(conditions: conditions, ntfyTopic: ntfyTopic)
        if let d = try? JSONEncoder().encode(s) {
            try? d.write(to: settingsURL, options: .atomic)
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

struct Settings: Codable {
    let conditions: [MonitorCondition]
    let ntfyTopic: String
}

struct ANAWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let w = WKWebView()
        w.load(URLRequest(url: URL(string: "https://www.ana.co.jp/")!))
        return w
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct ContentView: View {
    @StateObject var store = Store()

    var body: some View {
        NavigationSplitView {
            List {
                Section("監視") {
                    Label(store.monitoring ? "監視中・10分間隔" : "停止中",
                          systemImage: store.monitoring ? "checkmark.circle.fill" : "pause.circle")
                    Text(store.status).font(.caption).foregroundStyle(.secondary)
                }

                Section("監視条件") {
                    ForEach(store.conditions) { c in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.name).font(.headline)
                            Text("\(c.origin) → \(c.destination)")
                            Text("\(c.cabin) / \(c.passengers)名")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("出発 \(c.departureFrom.formatted(date: .numeric, time: .omitted)) ～ \(c.departureTo.formatted(date: .numeric, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button(role: .destructive) { store.remove(c.id) } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                    }
                    Button("監視条件を追加") { store.add() }
                }
            }
            .navigationTitle("ANA特典航空券")
        } detail: {
            VStack(spacing: 18) {
                Text("ANA特典航空券 空席監視")
                    .font(.largeTitle.bold())

                Text("ANAのログイン画面をここから開けます。パスワードはアプリの設定ファイルに保存しません。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                ANAWebView()
                    .frame(minHeight: 420)

                HStack {
                    Button(store.monitoring ? "監視停止" : "監視開始") {
                        store.monitoring ? store.stop() : store.start()
                    }
                    .buttonStyle(.borderedProminent)

                    Text("iPhone通知: \(store.ntfyTopic)")
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
            .padding()
        }
        .frame(minWidth: 1050, minHeight: 700)
    }
}

@main
struct ANAWatcherApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
