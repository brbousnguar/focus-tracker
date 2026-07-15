import Foundation

enum StorageBackend: String, Codable, CaseIterable, Identifiable {
    case firebase
    case local

    var id: Self { self }

    var title: String {
        switch self {
        case .firebase: "Firebase"
        case .local: "Local storage"
        }
    }
}

/// User config, stored at ~/Library/Application Support/FocusTracker/config.json
struct Config: Codable {
    var storageBackend: StorageBackend
    var supabaseUrl: String     // e.g. https://xxxx.supabase.co/rest/v1/sessions
    var apiKey: String          // Supabase anon (public) key
    var device: String          // provenance tag, e.g. "mac"
    var sessionMinutes: Int      // focus length, default 30

    init(storageBackend: StorageBackend = .firebase, supabaseUrl: String,
         apiKey: String, device: String, sessionMinutes: Int) {
        self.storageBackend = storageBackend
        self.supabaseUrl = supabaseUrl
        self.apiKey = apiKey
        self.device = device
        self.sessionMinutes = sessionMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case storageBackend, supabaseUrl, apiKey, device, sessionMinutes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        storageBackend = try values.decodeIfPresent(StorageBackend.self,
                                                    forKey: .storageBackend) ?? .firebase
        supabaseUrl = try values.decodeIfPresent(String.self, forKey: .supabaseUrl) ?? ""
        apiKey = try values.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        device = try values.decodeIfPresent(String.self, forKey: .device) ?? "mac"
        sessionMinutes = try values.decodeIfPresent(Int.self, forKey: .sessionMinutes) ?? 30
    }

    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FocusTracker", isDirectory: true)
    }()
    static var fileURL: URL { dir.appendingPathComponent("config.json") }

    static func load() -> Config {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let cfg = try? JSONDecoder().decode(Config.self, from: data) {
            cfg.save() // normalize and remove legacy keys such as `categories`
            return cfg
        }
        let def = Config(storageBackend: .local, supabaseUrl: "", apiKey: "", device: "mac",
                         sessionMinutes: 30)
        def.save()
        return def
    }

    func save() {
        try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: Config.fileURL) }
    }
}
