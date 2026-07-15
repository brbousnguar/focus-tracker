import Foundation

/// Remembers the session names you've used per category so the end prompt can
/// offer them as checkboxes. Stored at
/// ~/Library/Application Support/FocusTracker/suggestions.json
final class Suggestions {
    private static var url: URL { Config.dir.appendingPathComponent("suggestions.json") }
    private var map: [String: [String]]

    init() {
        if let data = try? Data(contentsOf: Suggestions.url),
           let m = try? JSONDecoder().decode([String: [String]].self, from: data) {
            map = m
        } else {
            map = [:]
        }
    }

    /// Most-recent-first session names previously used for this category.
    func list(for category: String, limit: Int = 10) -> [String] {
        Array((map[category] ?? []).prefix(limit))
    }

    /// Record chosen session names: move them to the front, dedup, and cap.
    func record(_ sessionNames: [String], for category: String, cap: Int = 30) {
        guard !sessionNames.isEmpty else { return }
        var current = map[category] ?? []
        for n in sessionNames.reversed() {   // reversed => first chosen ends up frontmost
            current.removeAll { $0.caseInsensitiveCompare(n) == .orderedSame }
            current.insert(n, at: 0)
        }
        map[category] = Array(current.prefix(cap))
        persist()
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(map) { try? data.write(to: Suggestions.url) }
    }
}
