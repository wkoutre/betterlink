import Foundation

// Sync's safety notes as agent commands (docs/sync.md, Safety): the hold that
// keeps one Mac from deleting many synced items at once, and the history of
// what sync deleted or replaced on this Mac, with Restore. Both are in
// sync-local.json in the settings folder; the running app's sync reads the
// answers from there, so these commands only record what was chosen.
extension Agent {
    static let syncCommands: [String] = ["sync.paused", "sync.resolve", "sync.history", "sync.restore"]

    static let syncNote = "A running betterlink acts on it at once; otherwise it does when it next opens."

    static func syncRun(_ command: String, _ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse? {
        let store = SyncLocalStore(folder: env.folder)
        switch command {
        case "sync.paused":
            return .success(describeHold(store.load()))
        case "sync.resolve":
            let choice: SyncDecision.Choice
            switch try string(input, "choice") ?? "" {
            case "delete": choice = .delete
            case "keep": choice = .keep
            default: throw fail("Give choice: delete (delete them on every Mac) or keep (bring them back on this Mac).")
            }
            let saved = try store.update { notes in
                guard let held = notes.held else { return }
                notes.answer(choice)
            }
            guard saved.held != nil else { throw fail("Sync isn't paused on this Mac (sync paused).") }
            var out = describeHold(saved)
            out["note"] = syncNote
            return .success(out)
        case "sync.history":
            let notes = store.load()
            return .success(notes.history.map { e -> [String: Any] in
                ["id": e.id.uuidString, "date": ISO8601DateFormatter().string(from: e.date), "kind": e.kind.rawValue,
                 "item": e.what, "from": e.from, "summary": e.summary, "restoring": notes.restore.contains(e.id)]
            })
        case "sync.restore":
            guard let raw = try string(input, "id"), !raw.isEmpty else { throw fail("Give id: an entry's id (sync history).") }
            let notes = store.load()
            let hits = notes.history.filter { $0.id.uuidString.lowercased().hasPrefix(raw.lowercased()) }
            guard hits.count == 1, let entry = hits.first else {
                throw fail(hits.isEmpty ? "No entry \(raw) in the sync history (sync history)." : "More than one entry starts with \(raw); give more of its id.")
            }
            try store.update { if !$0.restore.contains(entry.id) { $0.restore.append(entry.id) } }
            return .success(["id": entry.id.uuidString, "summary": entry.summary,
                             "note": "It comes back as a new edit on this Mac, so it wins on every Mac. " + syncNote])
        default:
            return nil
        }
    }

    private static func describeHold(_ notes: SyncLocal) -> [String: Any] {
        guard let h = notes.held else { return ["paused": false] }
        var out: [String: Any] = ["paused": true, "reason": h.reason, "items": h.names,
                                  "since": ISO8601DateFormatter().string(from: h.since)]
        if let c = notes.decision?.choice(for: h.ids) { out["chosen"] = c.rawValue }
        return out
    }
}
