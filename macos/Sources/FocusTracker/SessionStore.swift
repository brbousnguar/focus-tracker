import Foundation

struct SessionDetailsValue {
    let sessionNames: [String]
    let note: String
}

struct DashRow: Codable, Identifiable {
    let id: Int64
    let started_at: String
    let ended_at: String
    let duration_min: Int
    let category: String
    let session_names: [String]?
    let description: String?
    let device: String?
}

enum SessionDescriptionCodec {
    private static let sessionsPrefix = "Sessions: "
    private static let notePrefix = "Note: "

    static func encode(sessionNames: [String], note: String) -> String {
        var lines: [String] = []
        if !sessionNames.isEmpty {
            lines.append(sessionsPrefix + sessionNames.joined(separator: " | "))
        }
        if !note.isEmpty { lines.append(notePrefix + note) }
        return lines.joined(separator: "\n")
    }

    static func decode(_ description: String) -> SessionDetailsValue {
        guard description.hasPrefix(sessionsPrefix) else {
            let legacyNames = description
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return SessionDetailsValue(sessionNames: legacyNames, note: "")
        }

        let lines = description.components(separatedBy: .newlines)
        let names = lines.first?
            .dropFirst(sessionsPrefix.count)
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let note = lines.dropFirst()
            .joined(separator: "\n")
            .replacingOccurrences(of: notePrefix, with: "", options: [.anchored])
        return SessionDetailsValue(sessionNames: names, note: note)
    }
}

struct SessionRecord: Codable {
    let start: Date
    let end: Date
    let category: String
    let sessionNames: [String]
    let description: String

    init(start: Date, end: Date, category: String, sessionNames: [String], description: String) {
        self.start = start
        self.end = end
        self.category = category
        self.sessionNames = sessionNames
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case start, end, category, sessionNames, description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(Date.self, forKey: .start)
        end = try container.decode(Date.self, forKey: .end)
        category = try container.decode(String.self, forKey: .category)
        sessionNames = try container.decodeIfPresent([String].self, forKey: .sessionNames) ?? []
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    }

    var durationMin: Int {
        max(0, Int((end.timeIntervalSince(start) / 60.0).rounded()))
    }

    /// Row body for Supabase (PostgREST). Keys must match the table columns.
    func payload(device: String) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        return [
            "started_at": iso.string(from: start),
            "ended_at": iso.string(from: end),
            "category": category,
            "session_names": sessionNames,
            "description": description,
            "duration_min": durationMin,
            "device": device
        ]
    }
}

/// Saves sessions locally (permanent log) and pushes them to Supabase with a
/// retry outbox so nothing is lost while offline. Upserts on started_at so
/// retries never create duplicates.
final class SessionStore {
    private static var logURL: URL { Config.dir.appendingPathComponent("sessions.jsonl") }
    private static var outboxURL: URL { Config.dir.appendingPathComponent("outbox.json") }
    private static var localSessionsURL: URL {
        Config.dir.appendingPathComponent("local-sessions.json")
    }

    private var outbox: [SessionRecord]
    private var supportsSessionNames: Bool?

    init() {
        outbox = SessionStore.loadOutbox()
    }

    func save(_ rec: SessionRecord, config: Config) {
        appendLog(rec)
        if config.storageBackend == .local {
            _ = SessionStore.insertLocal(rec, device: config.device)
            return
        }
        outbox.append(rec)
        persistOutbox()
        flushOutbox(config: config)
    }

    func flushOutbox(config: Config) {
        guard config.storageBackend == .firebase,
              !config.supabaseUrl.isEmpty, !config.apiKey.isEmpty, !outbox.isEmpty,
              var comps = URLComponents(string: config.supabaseUrl) else { return }
        comps.queryItems = [URLQueryItem(name: "on_conflict", value: "started_at")]
        guard let url = comps.url else { return }

        for rec in outbox {
            post(rec, to: url, config: config) { [weak self] ok in
                guard let self, ok else { return }
                DispatchQueue.main.async {
                    self.outbox.removeAll { $0.start == rec.start && $0.category == rec.category }
                    self.persistOutbox()
                }
            }
        }
    }

    private func post(_ rec: SessionRecord, to url: URL, config: Config,
                      done: @escaping (Bool) -> Void) {
        post(rec, to: url, config: config, includeSessionNames: supportsSessionNames != false,
             done: done)
    }

    private func post(_ rec: SessionRecord, to url: URL, config: Config,
                      includeSessionNames: Bool, done: @escaping (Bool) -> Void) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        var payload = rec.payload(device: config.device)
        if !includeSessionNames {
            payload.removeValue(forKey: "session_names")
            payload["description"] = SessionDescriptionCodec.encode(
                sessionNames: rec.sessionNames, note: rec.description)
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if includeSessionNames, code == 400,
               String(data: data ?? Data(), encoding: .utf8)?.contains("session_names") == true {
                self?.supportsSessionNames = false
                self?.post(rec, to: url, config: config, includeSessionNames: false, done: done)
                return
            }
            if err == nil && (200...299).contains(code), includeSessionNames {
                self?.supportsSessionNames = true
            }
            done(err == nil && (200...299).contains(code))
        }.resume()
    }

    // MARK: - Disk

    static func loadLocalRows() -> [DashRow] {
        guard let data = try? Data(contentsOf: localSessionsURL) else { return [] }
        return (try? JSONDecoder().decode([DashRow].self, from: data)) ?? []
    }

    @discardableResult
    static func insertLocal(_ rec: SessionRecord, device: String) -> DashRow {
        let formatter = ISO8601DateFormatter()
        var rows = loadLocalRows()
        var id = Int64((Date().timeIntervalSince1970 * 1_000_000).rounded())
        while rows.contains(where: { $0.id == id }) { id += 1 }
        let row = DashRow(id: id,
                          started_at: formatter.string(from: rec.start),
                          ended_at: formatter.string(from: rec.end),
                          duration_min: rec.durationMin,
                          category: rec.category,
                          session_names: rec.sessionNames,
                          description: rec.description,
                          device: device)
        rows.append(row)
        persistLocalRows(rows)
        return row
    }

    @discardableResult
    static func upsertLocal(_ row: DashRow) -> DashRow {
        var rows = loadLocalRows()
        let saved: DashRow
        if row.id == 0 {
            var id = Int64((Date().timeIntervalSince1970 * 1_000_000).rounded())
            while rows.contains(where: { $0.id == id }) { id += 1 }
            saved = DashRow(id: id, started_at: row.started_at, ended_at: row.ended_at,
                            duration_min: row.duration_min, category: row.category,
                            session_names: row.session_names, description: row.description,
                            device: row.device)
            rows.append(saved)
        } else {
            saved = row
            if let index = rows.firstIndex(where: { $0.id == row.id }) {
                rows[index] = row
            } else {
                rows.append(row)
            }
        }
        persistLocalRows(rows)
        return saved
    }

    static func deleteLocal(id: Int64) -> Bool {
        var rows = loadLocalRows()
        let oldCount = rows.count
        rows.removeAll { $0.id == id }
        guard rows.count != oldCount else { return false }
        persistLocalRows(rows)
        return true
    }

    private static func persistLocalRows(_ rows: [DashRow]) {
        try? FileManager.default.createDirectory(at: Config.dir,
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(rows) else { return }
        try? data.write(to: localSessionsURL, options: .atomic)
    }

    private func appendLog(_ rec: SessionRecord) {
        guard let data = try? JSONEncoder().encode(rec),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let url = SessionStore.logURL
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(Data(line.utf8))
            try? fh.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func persistOutbox() {
        if let data = try? JSONEncoder().encode(outbox) {
            try? data.write(to: SessionStore.outboxURL)
        }
    }

    private static func loadOutbox() -> [SessionRecord] {
        guard let data = try? Data(contentsOf: outboxURL) else { return [] }
        return (try? JSONDecoder().decode([SessionRecord].self, from: data)) ?? []
    }
}
