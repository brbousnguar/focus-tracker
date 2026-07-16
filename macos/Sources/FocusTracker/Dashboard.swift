import SwiftUI
import Charts
import Combine

// MARK: - Data

private struct SessionEdit: Identifiable {
    let id: Int64
    var start: Date
    var end: Date
    var category: String
    var sessionNames: [String]
    var description: String
    var device: String
}

private enum SessionSheet {
    case add(Date)
    case edit(SessionEdit)
}

private enum DashboardSheet: Identifiable {
    case session(SessionSheet)
    case settings

    var id: String {
        switch self {
        case .session(.add): "add"
        case .session(.edit(let value)): "edit-\(value.id)"
        case .settings: "settings"
        }
    }
}

private struct Parsed {
    let date: Date
    let min: Int
    let cat: String
}

private extension Color {
    init(hex: UInt) {
        self.init(red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

private let aiCategoryColor = Color(hex: 0xd89b00)

// Categorical palette for non-AI categories. AI has the semantic yellow above.
private let categoryPalette: [Color] = [
    Color(hex: 0x2a78d6), Color(hex: 0x1baf7a), Color(hex: 0x7a52c7), Color(hex: 0xe34948),
    Color(hex: 0xeb6834), Color(hex: 0x1b9aaa), Color(hex: 0xe05a9d), Color(hex: 0x557a3e)
]

private func categoryColor(for category: String, among categories: [String]) -> Color {
    if category.caseInsensitiveCompare("AI") == .orderedSame { return aiCategoryColor }
    let ordered = Set(categories.filter {
        $0.caseInsensitiveCompare("AI") != .orderedSame
    }).sorted {
        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
    guard let index = ordered.firstIndex(where: {
        $0.caseInsensitiveCompare(category) == .orderedSame
    }) else { return categoryPalette[0] }
    return categoryPalette[index % categoryPalette.count]
}

// MARK: - View

enum DashboardSection: Hashable {
    case timer
    case overview
    case sessions
}

private enum ChartGranularity: Hashable {
    case day
    case month
}

final class DashboardNavigation: ObservableObject {
    @Published var section: DashboardSection = .timer
    @Published var reloadToken = UUID()
    @Published var settingsRequestToken: UUID?
}

struct DashboardView: View {
    @State private var config: Config
    let onConfigChanged: (Config) -> Void
    let onDatabaseChanged: () -> Void
    @ObservedObject var navigation: DashboardNavigation
    @ObservedObject var focusTimer: FocusTimerModel

    init(config: Config, navigation: DashboardNavigation, focusTimer: FocusTimerModel,
         onConfigChanged: @escaping (Config) -> Void = { _ in },
         onDatabaseChanged: @escaping () -> Void = {}) {
        _config = State(initialValue: config)
        self.navigation = navigation
        self.focusTimer = focusTimer
        self.onConfigChanged = onConfigChanged
        self.onDatabaseChanged = onDatabaseChanged
    }

    @State private var rows: [DashRow] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var selectedDate = Date()
    @State private var selectedMonth = Date()
    @State private var chartGranularity: ChartGranularity = .day
    @State private var activeSheet: DashboardSheet?
    @State private var deleteCandidate: DashRow?
    @State private var deleting = false
    @State private var supportsSessionNames = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("Dashboard section", selection: $navigation.section) {
                Text("Timer").tag(DashboardSection.timer)
                Text("Dashboard").tag(DashboardSection.overview)
                Text("Sessions").tag(DashboardSection.sessions)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorText {
                Text(errorText).foregroundStyle(.red).padding()
            } else if navigation.section == .timer {
                timerView
            } else if navigation.section == .sessions {
                sessionsView
            } else {
                overviewView
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 560)
        .task(id: navigation.reloadToken) { await load() }
        .onAppear { presentRequestedSettingsIfNeeded() }
        .onChange(of: navigation.settingsRequestToken) { _ in
            presentRequestedSettingsIfNeeded()
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .settings:
                SettingsSheet(config: config) { savedConfig in
                    config = savedConfig
                    onConfigChanged(savedConfig)
                    navigation.reloadToken = UUID()
                }
            case .session(let session):
                SessionEditorSheet(sheet: session, config: config,
                                   categories: categoriesByUsage,
                                   sessionNamesByCategory: sessionNamesByCategory,
                                   supportsSessionNames: supportsSessionNames) { saved in
                    if let index = rows.firstIndex(where: { $0.id == saved.id }) {
                        rows[index] = saved
                    } else {
                        rows.append(saved)
                        if let savedDate = parseDate(saved.started_at) {
                            selectedDate = savedDate
                            selectedMonth = savedDate
                        }
                    }
                    onDatabaseChanged()
                }
            }
        }
        .alert("Delete session?", isPresented: Binding(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } }
        ), presenting: deleteCandidate) { row in
            Button("Delete", role: .destructive) {
                Task { await delete(row) }
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: { row in
            Text("\(row.category) at \(timeRange(row)) will be permanently removed.")
        }
    }

    private func presentRequestedSettingsIfNeeded() {
        guard navigation.settingsRequestToken != nil else { return }
        activeSheet = .settings
        navigation.settingsRequestToken = nil
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sectionTitle)
                    .font(.title2.bold())
                Text(headerSubtitle)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                activeSheet = .settings
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityLabel("Settings")
            Button {
                Task { await load() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    private var sectionTitle: String {
        switch navigation.section {
        case .timer: "Focus Timer"
        case .overview: "Dashboard"
        case .sessions: "Sessions"
        }
    }

    private var headerSubtitle: String {
        if loading { return "loading…" }
        if navigation.section == .timer { return focusTimer.statusMessage }
        return "\(visibleSessionCount) sessions"
    }

    private var timerView: some View {
        FocusTimerView(timer: focusTimer,
                       categories: categoriesByUsage,
                       sessionNamesByCategory: sessionNamesByCategory)
    }

    private var overviewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                monthSelector
                if items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text("No sessions in \(monthTitle)").font(.headline)
                        Text("Choose another month or add a session from Sessions.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    tiles
                    focusChartCard
                    categoryCard
                }
            }
        }
    }

    private var monthSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Previous month")

                Text(monthTitle)
                    .font(.headline)
                    .frame(minWidth: 150)

                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel("Next month")

                Spacer()

                if !Calendar.current.isDate(selectedMonth, equalTo: Date(), toGranularity: .month) {
                    Button("This month") { selectedMonth = Date() }
                }
            }

            HStack {
                Text("Chart bars")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Chart granularity", selection: $chartGranularity) {
                    Text("Day").tag(ChartGranularity.day)
                    Text("Month").tag(ChartGranularity.month)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
        }
    }

    private var tiles: some View {
        HStack(spacing: 12) {
            tile("Month focus", String(format: "%.1f h", totalHours))
            tile("Sessions", "\(items.count)")
            tile("Active days", "\(activeDays)")
            tile("Categories", "\(overviewCategories.count)")
        }
    }

    private func tile(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key.uppercased()).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var focusChartCard: some View {
        card(chartTitle) {
            Chart(timeBars) { bar in
                BarMark(x: .value("Period", bar.label), y: .value("Hours", bar.hours))
                    .foregroundStyle(by: .value("Category", bar.cat))
                    .cornerRadius(4)
            }
            .chartXScale(domain: chartPeriodLabels)
            .chartForegroundStyleScale(domain: chartCategories,
                                       range: chartCategories.map {
                                           categoryColor(for: $0, among: categoriesByUsage)
                                       })
            .chartLegend(position: .bottom)
            .frame(height: 220)
        }
    }

    private var categoryCard: some View {
        card("By category") {
            Chart(byCategory) { c in
                BarMark(x: .value("Hours", c.hours), y: .value("Category", c.cat))
                    .foregroundStyle(by: .value("Category", c.cat))
                    .cornerRadius(4)
                    .annotation(position: .trailing) {
                        Text(String(format: "%.1fh", c.hours))
                            .font(.caption).foregroundStyle(.secondary)
                    }
            }
            .chartForegroundStyleScale(domain: byCategory.map(\.cat),
                                       range: byCategory.map {
                                           categoryColor(for: $0.cat, among: categoriesByUsage)
                                       })
            .chartLegend(.hidden)
            .frame(height: CGFloat(max(1, byCategory.count)) * 38 + 10)
        }
    }

    private var sessionsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                DatePicker("Sessions for", selection: $selectedDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
                Spacer()
                Text("\(sessionsOnSelectedDate.count) session\(sessionsOnSelectedDate.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Button {
                    activeSheet = .session(.add(selectedDate))
                } label: {
                    Label("Add session", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            Divider()

            if sessionsOnSelectedDate.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No sessions").font(.headline)
                    Text("There are no sessions on this date.")
                        .foregroundStyle(.secondary)
                    Button("Add session") { activeSheet = .session(.add(selectedDate)) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sessionsOnSelectedDate) { row in
                            sessionRow(row)
                            if row.id != sessionsOnSelectedDate.last?.id { Divider() }
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sessionRow(_ row: DashRow) -> some View {
        let details = details(for: row)
        let color = categoryColor(for: row.category, among: categoriesByUsage)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(row.category)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(color.opacity(0.16)))
                    Text("\(row.duration_min) min")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(timeRange(row))
                    .font(.caption).foregroundStyle(.secondary)
                if !details.sessionNames.isEmpty {
                    Text(details.sessionNames.joined(separator: " · ")).lineLimit(2)
                }
                if !details.note.isEmpty {
                    Text(details.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Button("Edit") {
                if let value = makeEdit(row) { activeSheet = .session(.edit(value)) }
            }
                .accessibilityLabel("Edit \(row.category) session")
            Button(role: .destructive) { deleteCandidate = row } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(deleting)
            .accessibilityLabel("Delete \(row.category) session")
        }
        .padding(12)
    }

    // MARK: - Aggregates

    private var allItems: [Parsed] {
        let f = ISO8601DateFormatter()
        return rows.compactMap { row in
            guard let date = f.date(from: row.started_at) else { return nil }
            return Parsed(date: date, min: row.duration_min, cat: row.category)
        }
    }

    private var items: [Parsed] {
        allItems.filter {
            Calendar.current.isDate($0.date, equalTo: selectedMonth, toGranularity: .month)
        }
    }

    private var visibleSessionCount: Int {
        navigation.section == .overview ? items.count : rows.count
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: selectedMonth)
    }

    private func shiftMonth(_ offset: Int) {
        selectedMonth = Calendar.current.date(byAdding: .month, value: offset, to: selectedMonth)
            ?? selectedMonth
    }

    private var sessionsOnSelectedDate: [DashRow] {
        rows.filter {
            guard let date = parseDate($0.started_at) else { return false }
            return Calendar.current.isDate(date, inSameDayAs: selectedDate)
        }
        .sorted { ($0.started_at) < ($1.started_at) }
    }

    private func parseDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private func makeEdit(_ row: DashRow) -> SessionEdit? {
        guard let start = parseDate(row.started_at), let end = parseDate(row.ended_at) else { return nil }
        let details = details(for: row)
        return SessionEdit(id: row.id, start: start, end: end, category: row.category,
                           sessionNames: details.sessionNames, description: details.note,
                           device: row.device ?? "")
    }

    private func details(for row: DashRow) -> SessionDetailsValue {
        if let sessionNames = row.session_names {
            return SessionDetailsValue(sessionNames: sessionNames, note: row.description ?? "")
        }
        return SessionDescriptionCodec.decode(row.description ?? "")
    }

    private func timeRange(_ row: DashRow) -> String {
        guard let start = parseDate(row.started_at), let end = parseDate(row.ended_at) else { return "" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    private var totalHours: Double { Double(items.reduce(0) { $0 + $1.min }) / 60 }

    private var activeDays: Int {
        Set(items.map { Calendar.current.startOfDay(for: $0.date) }).count
    }

    private var overviewCategories: [String] {
        let present = Set(items.map(\.cat))
        return categoriesByUsage.filter { present.contains($0) }
    }

    private func monthKey(_ date: Date) -> Date {
        let calendar = Calendar.current
        return calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    struct TimeCategoryBar: Identifiable {
        let id = UUID()
        let label: String
        let cat: String
        let hours: Double
    }

    private var chartTitle: String {
        switch chartGranularity {
        case .day: "Daily focus in \(monthTitle)"
        case .month: "Monthly focus through \(monthTitle)"
        }
    }

    private var chartItems: [Parsed] {
        guard chartGranularity == .month else { return items }
        let calendar = Calendar.current
        let endMonth = monthKey(selectedMonth)
        let startMonth = calendar.date(byAdding: .month, value: -11, to: endMonth) ?? endMonth
        let monthAfterEnd = calendar.date(byAdding: .month, value: 1, to: endMonth) ?? endMonth
        return allItems.filter { $0.date >= startMonth && $0.date < monthAfterEnd }
    }

    private var chartPeriods: [Date] {
        let calendar = Calendar.current
        let selectedMonthStart = monthKey(selectedMonth)
        switch chartGranularity {
        case .day:
            guard let range = calendar.range(of: .day, in: .month, for: selectedMonthStart) else {
                return []
            }
            return range.compactMap {
                calendar.date(byAdding: .day, value: $0 - 1, to: selectedMonthStart)
            }
        case .month:
            return (-11...0).compactMap {
                calendar.date(byAdding: .month, value: $0, to: selectedMonthStart)
            }
        }
    }

    private func chartPeriodLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = chartGranularity == .day ? "d" : "MMM yy"
        return formatter.string(from: date)
    }

    private var chartPeriodLabels: [String] {
        chartPeriods.map(chartPeriodLabel)
    }

    private var chartCategories: [String] {
        let present = Set(chartItems.map(\.cat))
        return categoriesByUsage.filter { present.contains($0) }
    }

    private var timeBars: [TimeCategoryBar] {
        var map: [Date: [String: Int]] = [:]
        let calendar = Calendar.current
        for item in chartItems {
            let period = chartGranularity == .day
                ? calendar.startOfDay(for: item.date)
                : monthKey(item.date)
            map[period, default: [:]][item.cat, default: 0] += item.min
        }
        return chartPeriods.flatMap { period in
            chartCategories.compactMap { category in
                guard let minutes = map[period]?[category], minutes > 0 else { return nil }
                return TimeCategoryBar(label: chartPeriodLabel(period), cat: category,
                                       hours: Double(minutes) / 60)
            }
        }
    }

    struct CatBar: Identifiable { let id = UUID(); let cat: String; let hours: Double }
    private var byCategory: [CatBar] {
        var map: [String: Int] = [:]
        for it in items { map[it.cat, default: 0] += it.min }
        return map.map { CatBar(cat: $0.key, hours: Double($0.value) / 60) }
            .sorted { $0.hours > $1.hours }
    }

    private var categoriesByUsage: [String] {
        var counts: [String: Int] = [:]
        for row in rows { counts[row.category, default: 0] += 1 }
        return counts.keys.sorted {
            let left = counts[$0] ?? 0
            let right = counts[$1] ?? 0
            return left == right ? $0.localizedCaseInsensitiveCompare($1) == .orderedAscending : left > right
        }
    }

    private var sessionNamesByCategory: [String: [String]] {
        var counts: [String: [String: Int]] = [:]
        var labels: [String: [String: String]] = [:]
        for row in rows {
            for rawName in details(for: row).sessionNames {
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                counts[row.category, default: [:]][key, default: 0] += 1
                let current = labels[row.category, default: [:]][key]
                if current == nil || (current == current?.lowercased() && name != name.lowercased()) {
                    labels[row.category, default: [:]][key] = name
                }
            }
        }
        var result: [String: [String]] = [:]
        for (category, categoryCounts) in counts {
            let keys = categoryCounts.keys.sorted {
                let left = categoryCounts[$0] ?? 0
                let right = categoryCounts[$1] ?? 0
                return left == right
                    ? $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                    : left > right
            }
            result[category] = keys.compactMap { labels[category]?[$0] }
        }
        return result
    }

    // MARK: - Load

    private func load() async {
        loading = true; errorText = nil
        if config.storageBackend == .local {
            let loaded = SessionStore.loadLocalRows().sorted { $0.started_at < $1.started_at }
            rows = loaded
            if let latest = loaded.last, let latestDate = parseDate(latest.started_at) {
                selectedDate = latestDate
                selectedMonth = latestDate
            }
            loading = false
            return
        }
        guard !config.supabaseUrl.isEmpty, !config.apiKey.isEmpty,
              var comps = URLComponents(string: config.supabaseUrl) else {
            errorText = "Set the Firebase URL and API key in Settings."
            loading = false
            return
        }
        comps.queryItems = [
            URLQueryItem(name: "select", value: supportsSessionNames
                         ? "id,started_at,ended_at,duration_min,category,session_names,description,device"
                         : "id,started_at,ended_at,duration_min,category,description,device"),
            URLQueryItem(name: "order", value: "started_at.asc")
        ]
        guard let url = comps.url else { loading = false; return }
        do {
            let pageSize = 1_000
            var offset = 0
            var loaded: [DashRow] = []

            while true {
                var request = URLRequest(url: url)
                request.setValue(config.apiKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("items", forHTTPHeaderField: "Range-Unit")
                request.setValue("\(offset)-\(offset + pageSize - 1)", forHTTPHeaderField: "Range")

                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200...299).contains(code) else {
                    let detail = String(data: data, encoding: .utf8) ?? ""
                    if code == 400, supportsSessionNames, detail.contains("session_names") {
                        supportsSessionNames = false
                        await load()
                        return
                    }
                    errorText = "Server error (HTTP \(code))"
                    loading = false
                    return
                }
                let page = try JSONDecoder().decode([DashRow].self, from: data)
                loaded.append(contentsOf: page)
                if page.count < pageSize { break }
                offset += pageSize
            }

            rows = loaded
            if let latest = loaded.last, let latestDate = parseDate(latest.started_at) {
                selectedDate = latestDate
                selectedMonth = latestDate
            }
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }

    private func delete(_ row: DashRow) async {
        deleting = true
        errorText = nil
        defer { deleting = false; deleteCandidate = nil }

        if config.storageBackend == .local {
            guard SessionStore.deleteLocal(id: row.id) else {
                errorText = "The local session could not be found."
                return
            }
            rows.removeAll { $0.id == row.id }
            onDatabaseChanged()
            return
        }

        guard var components = URLComponents(string: config.supabaseUrl) else {
            errorText = "Invalid Firebase URL."
            return
        }
        components.queryItems = [URLQueryItem(name: "id", value: "eq.\(row.id)")]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(config.apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(code) else {
                let detail = String(data: data, encoding: .utf8) ?? ""
                errorText = "Delete failed (HTTP \(code))\(detail.isEmpty ? "" : ": \(detail)")"
                return
            }
            let deleted = try JSONDecoder().decode([DashRow].self, from: data)
            guard deleted.contains(where: { $0.id == row.id }) else {
                errorText = "Supabase did not delete the session. Check the delete policy."
                return
            }
            rows.removeAll { $0.id == row.id }
            onDatabaseChanged()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var storageBackend: StorageBackend
    @State private var firebaseURL: String
    @State private var apiKey: String
    @State private var device: String
    @State private var sessionMinutes: Int
    @State private var revealsAPIKey = false

    private let credentialFieldWidth: CGFloat = 300

    let onSave: (Config) -> Void

    init(config: Config, onSave: @escaping (Config) -> Void) {
        _storageBackend = State(initialValue: config.storageBackend)
        _firebaseURL = State(initialValue: config.supabaseUrl)
        _apiKey = State(initialValue: config.apiKey)
        _device = State(initialValue: config.device)
        _sessionMinutes = State(initialValue: config.sessionMinutes)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Settings")
                    .font(.title2.bold())
            }

            Form {
                Section("Storage") {
                    Picker("Store sessions in", selection: $storageBackend) {
                        ForEach(StorageBackend.allCases) { backend in
                            Text(backend.title).tag(backend)
                        }
                    }
                    .pickerStyle(.segmented)

                    if storageBackend == .firebase {
                        LabeledContent("Firebase URL") {
                            TextField("https://…", text: $firebaseURL)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: credentialFieldWidth)
                                .multilineTextAlignment(.leading)
                                .environment(\.layoutDirection, .leftToRight)
                        }

                        LabeledContent("API key") {
                            HStack(spacing: 6) {
                                Group {
                                    if revealsAPIKey {
                                        TextField("API key", text: $apiKey)
                                    } else {
                                        SecureField("API key", text: $apiKey)
                                    }
                                }
                                .textFieldStyle(.roundedBorder)
                                .frame(width: credentialFieldWidth)
                                .environment(\.layoutDirection, .leftToRight)

                                Image(systemName: revealsAPIKey ? "eye.slash" : "eye")
                                    .frame(width: 24, height: 22)
                                    .contentShape(Rectangle())
                                    .onLongPressGesture(
                                        minimumDuration: 60,
                                        maximumDistance: 30,
                                        pressing: { revealsAPIKey = $0 },
                                        perform: {}
                                    )
                                    .help("Press and hold to show API key")
                                    .accessibilityLabel("Press and hold to show API key")
                                    .accessibilityAddTraits(.isButton)
                            }
                        }

                        Text("The existing remote URL and API key are prefilled. Press and hold the eye to reveal the key.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Location") {
                            Text("FocusTracker/local-sessions.json")
                                .foregroundStyle(.secondary)
                        }
                        Text("Local sessions remain on this Mac and do not require a URL or API key.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Changing storage switches the active session collection; it does not copy sessions between backends.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Timer") {
                    Stepper("Default duration: \(sessionMinutes) min",
                            value: $sessionMinutes, in: 5...720, step: 5)
                }

                Section("Device") {
                    TextField("Device name", text: $device)
                }
            }
            .formStyle(.grouped)

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationMessage != nil)
            }
        }
        .padding(20)
        .frame(width: 520, height: storageBackend == .firebase ? 490 : 410)
    }

    private var validationMessage: String? {
        guard storageBackend == .firebase else { return nil }
        let url = firebaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, let components = URLComponents(string: url),
              components.scheme != nil, components.host != nil else {
            return "Enter a valid Firebase URL."
        }
        return key.isEmpty ? "Enter the Firebase API key." : nil
    }

    private func save() {
        let saved = Config(
            storageBackend: storageBackend,
            supabaseUrl: firebaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            device: device.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "mac"
                : device.trimmingCharacters(in: .whitespacesAndNewlines),
            sessionMinutes: sessionMinutes
        )
        saved.save()
        onSave(saved)
        dismiss()
    }
}

private struct FocusTimerView: View {
    @ObservedObject var timer: FocusTimerModel
    let categories: [String]
    let sessionNamesByCategory: [String: [String]]

    private var accent: Color {
        categoryColor(for: timer.category.isEmpty ? "Focus" : timer.category,
                      among: categories + [timer.category])
    }

    private var progress: Double {
        guard timer.totalSeconds > 0 else { return 0 }
        return min(1, max(0, Double(timer.remainingSeconds) / Double(timer.totalSeconds)))
    }

    private var timeText: String {
        String(format: "%02d:%02d", timer.remainingSeconds / 60, timer.remainingSeconds % 60)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 34) {
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.14), lineWidth: 18)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(accent,
                                style: StrokeStyle(lineWidth: 18, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.2), value: progress)

                    VStack(spacing: 8) {
                        Text(timeText)
                            .font(.system(size: 54, weight: .medium, design: .rounded))
                            .monospacedDigit()
                        Text(timer.category.isEmpty ? "Choose a category" : timer.category)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: 300, height: 300)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Focus timer, \(timeText) remaining")

                controls
            }
            .frame(maxWidth: .infinity)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Stepper("Duration: \(timer.durationMinutes) minutes",
                            value: Binding(
                                get: { timer.durationMinutes },
                                set: { timer.setDurationMinutes($0) }
                            ),
                            in: 1...720,
                            step: 5)
                        .disabled(timer.isActive)

                    CategorySelector(selection: $timer.category, categories: categories)
                        .disabled(timer.isActive)

                    Divider()

                    // Editable while the timer runs so details can be filled in
                    // during the session and saved automatically when it finishes.
                    SessionNameSelector(selection: $timer.sessionNames,
                                        names: sessionNamesByCategory[timer.category] ?? [])

                    Divider()

                    TextField("Optional note", text: $timer.note, axis: .vertical)
                        .lineLimit(2...4)
                }
                .padding(.trailing, 8)
            }
            .frame(width: 330)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 12)
        .onAppear(perform: chooseDefaultCategory)
        .onChange(of: categories) { _ in chooseDefaultCategory() }
        .onChange(of: timer.category) { _ in
            if timer.phase == .idle { timer.sessionNames = [] }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch timer.phase {
        case .idle:
            timerButton("Start", systemImage: "play.fill", color: .green) {
                timer.startFromWindow()
            }
            .disabled(timer.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(timer.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
        case .running:
            HStack(spacing: 18) {
                timerButton("Pause", systemImage: "pause.fill", color: .orange) { timer.pause() }
                timerButton("Restart", systemImage: "arrow.counterclockwise", color: .blue) {
                    timer.restart()
                }
                timerButton("Cancel", systemImage: "xmark", color: .red) { timer.cancel() }
            }
        case .paused:
            HStack(spacing: 18) {
                timerButton("Resume", systemImage: "play.fill", color: .green) {
                    timer.startOrResume()
                }
                timerButton("Restart", systemImage: "arrow.counterclockwise", color: .blue) {
                    timer.restart()
                }
                timerButton("Cancel", systemImage: "xmark", color: .red) { timer.cancel() }
            }
        }
    }

    private func timerButton(_ title: String, systemImage: String, color: Color,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(color.opacity(0.18)))
                    .overlay(Circle().stroke(color.opacity(0.55), lineWidth: 1))
                Text(title).font(.caption)
            }
            .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func chooseDefaultCategory() {
        if timer.category.isEmpty, let first = categories.first {
            timer.category = first
        }
    }
}

private struct SessionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var value: SessionEdit
    @State private var durationInputMinutes: Int
    @State private var saving = false
    @State private var errorText: String?

    let config: Config
    private let isNew: Bool
    private let categories: [String]
    private let sessionNamesByCategory: [String: [String]]
    private let supportsSessionNames: Bool
    let onSaved: (DashRow) -> Void

    init(sheet: SessionSheet, config: Config, categories: [String],
         sessionNamesByCategory: [String: [String]],
         supportsSessionNames: Bool,
        onSaved: @escaping (DashRow) -> Void) {
        switch sheet {
        case .add(let date):
            let calendar = Calendar.current
            let now = Date()
            let time = calendar.dateComponents([.hour, .minute], from: now)
            let finish = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0,
                                       second: 0, of: date) ?? date
            let duration = max(1, config.sessionMinutes)
            _value = State(initialValue: SessionEdit(
                                                     id: 0,
                                                     start: finish.addingTimeInterval(-Double(duration) * 60),
                                                     end: finish,
                                                     category: categories.first ?? "",
                                                     sessionNames: [], description: "", device: config.device))
            _durationInputMinutes = State(initialValue: duration)
            isNew = true
        case .edit(let edit):
            _value = State(initialValue: edit)
            let duration = max(1, Int((edit.end.timeIntervalSince(edit.start) / 60).rounded()))
            _durationInputMinutes = State(initialValue: duration)
            isNew = false
        }
        self.config = config
        self.categories = categories
        self.sessionNamesByCategory = sessionNamesByCategory
        self.supportsSessionNames = supportsSessionNames
        self.onSaved = onSaved
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "Add session" : "Edit session").font(.title2.bold())

            Form {
                if isNew {
                    DatePicker("Finish", selection: $value.end)
                    Stepper("Duration: \(durationInputMinutes) min", value: $durationInputMinutes,
                            in: 5...720, step: 5)
                    LabeledContent("Start (automatic)") {
                        Text(dateTimeText(effectiveStart))
                    }
                } else {
                    DatePicker("Start", selection: $value.start)
                    DatePicker("End", selection: $value.end)
                }
                CategorySelector(selection: $value.category, categories: categories)
                SessionNameSelector(selection: $value.sessionNames,
                                    names: sessionNamesByCategory[value.category] ?? [])
                TextField("Note", text: $value.description, axis: .vertical)
                    .lineLimit(2...5)
                TextField("Device", text: $value.device)
                if !isNew {
                    LabeledContent("Duration") {
                        Text("\(durationMinutes) min")
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: value.category) { _ in
                value.sessionNames = []
            }

            if let errorText {
                Text(errorText).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(saving ? "Saving…" : (isNew ? "Add" : "Save")) {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || value.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.end <= effectiveStart)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var durationMinutes: Int {
        isNew ? durationInputMinutes
            : max(0, Int((value.end.timeIntervalSince(value.start) / 60).rounded()))
    }

    private var effectiveStart: Date {
        isNew ? value.end.addingTimeInterval(-Double(durationInputMinutes) * 60) : value.start
    }

    private func dateTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func save() async {
        saving = true
        errorText = nil
        defer { saving = false }

        let iso = ISO8601DateFormatter()
        let note = value.description.trimmingCharacters(in: .whitespacesAndNewlines)

        if config.storageBackend == .local {
            let row = DashRow(
                id: isNew ? 0 : value.id,
                started_at: iso.string(from: effectiveStart),
                ended_at: iso.string(from: value.end),
                duration_min: durationMinutes,
                category: value.category.trimmingCharacters(in: .whitespacesAndNewlines),
                session_names: value.sessionNames,
                description: note,
                device: value.device.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            onSaved(SessionStore.upsertLocal(row))
            dismiss()
            return
        }

        guard var components = URLComponents(string: config.supabaseUrl) else {
            errorText = "Invalid Firebase URL."
            return
        }
        let selectedColumns = supportsSessionNames
            ? "id,started_at,ended_at,duration_min,category,session_names,description,device"
            : "id,started_at,ended_at,duration_min,category,description,device"
        components.queryItems = isNew
            ? [URLQueryItem(name: "select", value: selectedColumns)]
            : [URLQueryItem(name: "id", value: "eq.\(value.id)"),
               URLQueryItem(name: "select", value: selectedColumns)]
        guard let url = components.url else {
            errorText = "Invalid Firebase URL."
            return
        }

        var body: [String: Any] = [
            "started_at": iso.string(from: effectiveStart),
            "ended_at": iso.string(from: value.end),
            "duration_min": durationMinutes,
            "category": value.category.trimmingCharacters(in: .whitespacesAndNewlines),
            "description": supportsSessionNames
                ? note
                : SessionDescriptionCodec.encode(sessionNames: value.sessionNames, note: note),
            "device": value.device.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        if supportsSessionNames { body["session_names"] = value.sessionNames }

        var request = URLRequest(url: url)
        request.httpMethod = isNew ? "POST" : "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(code) else {
                let detail = String(data: data, encoding: .utf8) ?? ""
                errorText = "Save failed (HTTP \(code))\(detail.isEmpty ? "" : ": \(detail)")"
                return
            }
            guard let updated = try JSONDecoder().decode([DashRow].self, from: data).first else {
                errorText = "Supabase did not return the updated session."
                return
            }
            onSaved(updated)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct SessionNameSelector: View {
    @Binding var selection: [String]
    let names: [String]

    @State private var isAdding = false
    @State private var newName = ""
    @FocusState private var newNameFocused: Bool

    private var suggested: [String] { Array(names.prefix(3)) }
    private var more: [String] { Array(names.dropFirst(3)) }
    private var addedNames: [String] {
        selection.filter { selected in
            !names.contains { $0.caseInsensitiveCompare(selected) == .orderedSame }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sessions")
                Spacer()
                Text(selection.isEmpty ? "None selected" : "\(selection.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if names.isEmpty {
                Text("No saved sessions for this category yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(suggested, id: \.self) { name in
                    Toggle(name, isOn: binding(for: name))
                        .toggleStyle(.checkbox)
                }

                if !more.isEmpty {
                    Menu {
                        ForEach(more, id: \.self) { name in
                            Button {
                                toggle(name)
                            } label: {
                                if contains(name) {
                                    Label(name, systemImage: "checkmark")
                                } else {
                                    Text(name)
                                }
                            }
                        }
                    } label: {
                        Label("More sessions", systemImage: "chevron.down")
                    }
                }
            }

            ForEach(addedNames, id: \.self) { name in
                Toggle(name, isOn: binding(for: name))
                    .toggleStyle(.checkbox)
            }

            Button {
                isAdding.toggle()
                if isAdding {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                        newNameFocused = true
                    }
                } else {
                    newName = ""
                }
            } label: {
                Label(isAdding ? "Cancel new session" : "New session", systemImage: "plus")
            }
            .buttonStyle(.borderless)

            if isAdding {
                HStack {
                    TextField("Session name", text: $newName)
                        .focused($newNameFocused)
                        .onSubmit(addSession)
                    Button {
                        pasteSessionName()
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    Button("Add", action: addSession)
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if !selection.isEmpty {
                Text(selection.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(get: { contains(name) }, set: { selected in
            if selected {
                if !contains(name) { selection.append(name) }
            } else {
                selection.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
            }
        })
    }

    private func contains(_ name: String) -> Bool {
        selection.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func toggle(_ name: String) {
        if contains(name) {
            selection.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        } else {
            selection.append(name)
        }
    }

    private func addSession() {
        let proposed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proposed.isEmpty else { return }
        let canonical = (names + selection).first {
            $0.caseInsensitiveCompare(proposed) == .orderedSame
        } ?? proposed
        if !contains(canonical) { selection.append(canonical) }
        newName = ""
        isAdding = false
        newNameFocused = false
    }

    private func pasteSessionName() {
        guard let clipboard = NSPasteboard.general.string(forType: .string) else { return }
        let pasted = clipboard.components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pasted.isEmpty else { return }
        newName = pasted
        newNameFocused = true
    }
}

private struct CategorySelector: View {
    @Binding var selection: String
    let categories: [String]

    @State private var isAdding = false
    @State private var newCategory = ""
    @FocusState private var newCategoryFocused: Bool

    private var suggested: [String] { Array(categories.prefix(3)) }
    private var more: [String] { Array(categories.dropFirst(3)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Category")
                Spacer()
                if !selection.isEmpty {
                    let color = categoryColor(for: selection, among: categories + [selection])
                    Text(selection)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(color.opacity(0.16)))
                }
            }

            HStack(spacing: 8) {
                ForEach(suggested, id: \.self) { category in
                    let color = categoryColor(for: category, among: categories)
                    Button { selection = category } label: {
                        Text(category)
                            .font(.callout.weight(selection == category ? .semibold : .regular))
                            .foregroundStyle(color)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(color.opacity(selection == category ? 0.22 : 0.11)))
                            .overlay(Capsule().stroke(color.opacity(selection == category ? 0.9 : 0.35),
                                                      lineWidth: selection == category ? 1.5 : 1))
                    }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Choose category \(category)")
                }

                if !more.isEmpty {
                    Menu {
                        ForEach(more, id: \.self) { category in
                            Button {
                                selection = category
                            } label: {
                                if selection == category {
                                    Label(category, systemImage: "checkmark")
                                } else {
                                    Text(category)
                                }
                            }
                        }
                    } label: {
                        Label("More categories", systemImage: "chevron.down")
                    }
                }
            }

            Button {
                isAdding.toggle()
                if isAdding {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                        newCategoryFocused = true
                    }
                } else {
                    newCategory = ""
                }
            } label: {
                Label(isAdding ? "Cancel new category" : "New category", systemImage: "plus")
            }
            .buttonStyle(.borderless)

            if isAdding {
                HStack {
                    TextField("Category name", text: $newCategory)
                        .focused($newCategoryFocused)
                        .onSubmit(addCategory)
                    Button("Use", action: addCategory)
                        .disabled(newCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func addCategory() {
        let proposed = newCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proposed.isEmpty else { return }
        selection = categories.first {
            $0.caseInsensitiveCompare(proposed) == .orderedSame
        } ?? proposed
        newCategory = ""
        isAdding = false
        newCategoryFocused = false
    }
}
