// betterlink-tabs: the app side without a UI. Connects to every running host,
// prints each event with its browser -> app latency, and accepts commands:
//
//   open <url>          open a tab in the first browser's focused window
//   close <tabId>       close a tab
//   activate <tabId>    focus a tab
//   list                print every window and tab
//
// --json prints one JSON object per state change instead (used by the e2e test).
import Foundation
import TabSyncCore

setvbuf(stdout, nil, _IOLBF, 0)
let jsonMode = CommandLine.arguments.contains("--json")

func emit(_ obj: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), let s = String(data: d, encoding: .utf8) {
        print(s)
    }
}

func render(_ sessions: [BrowserSession]) -> [[String: Any]] {
    sessions.map { s in
        [
            "browser": s.browser,
            "pid": s.pid,
            "windows": s.store.orderedWindows.map { w in
                ["id": w.window.id, "focused": w.window.focused,
                 "tabs": w.tabs.map { ["id": $0.id, "url": $0.url, "title": $0.title, "active": $0.active] as [String: Any] }] as [String: Any]
            },
        ]
    }
}

let hub = SyncHub(onLine: { path, m in
    guard !jsonMode, m.type == "event" else { return }
    let ms = m.t.map { String(format: "%.1f ms", nowMs() - $0) } ?? "?"
    let what = m.tab.map { "\($0.id) \($0.url)" } ?? m.tabId.map(String.init) ?? m.windowId.map { "window \($0)" } ?? ""
    print("[\(ms)] \(m.kind ?? "?") \(what)")
}, onChange: { sessions in
    guard jsonMode else { return }
    var out: [String: Any] = ["sessions": render(sessions), "t": nowMs()]
    if let s = sessions.first {
        if let l = s.lastEventLatencyMs { out["eventLatencyMs"] = l }
        if let k = s.lastEventKind { out["lastEvent"] = k }
        if let r = s.lastCommandRoundTripMs { out["commandRoundTripMs"] = r }
    }
    emit(out)
})
hub.start()
if !jsonMode { print("watching \(SocketDirectory.path)") }

func listAll() {
    for s in hub.current {
        print("\(s.browser) (pid \(s.pid))")
        for w in s.store.orderedWindows {
            print("  window \(w.window.id)\(w.window.focused ? " *" : "")")
            for t in w.tabs { print("    \(t.active ? ">" : " ") \(t.id)  \(t.title.prefix(50))  \(t.url)") }
        }
    }
}

while let line = readLine() {
    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
    guard let verb = parts.first, let target = hub.current.first else { continue }
    let arg = parts.count > 1 ? parts[1] : ""
    switch verb {
    case "open": hub.send(.open(arg), to: target.socketPath)
    case "close": if let id = Int(arg) { hub.send(.close(id), to: target.socketPath) }
    case "activate": if let id = Int(arg) { hub.send(.activate(id), to: target.socketPath) }
    case "list": listAll()
    default: print("commands: open <url> | close <tabId> | activate <tabId> | list")
    }
}
// stdin closed: keep streaming until killed
dispatchMain()
