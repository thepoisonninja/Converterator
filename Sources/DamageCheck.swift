// Converterator — File → Check for Damaged Files…: reads CHDs and GameCube/Wii discs all the way through,
// to find damage from a failing drive, a bad copy or a bad download before it matters.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// What damage checks found, remembered per file in Application Support, so the Library Report can show it
/// and an RVZ can be compared with what it was last time.
enum DamageRecord {
    struct Entry: Codable, Sendable {
        let size: Int64
        let modified: Double
        let damaged: Bool
        let why: String?
        /// For a GameCube/Wii disc: the SHA-1 of the disc inside, the last time it read as undamaged.
        let sha1: String?
        let date: Date
    }

    static var file: URL { AppPaths.dataDir.appendingPathComponent("damage-checks.json") }
    @MainActor private static var memory: [String: Entry]?

    @MainActor static func all() -> [String: Entry] {
        if let memory { return memory }
        let loaded = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        memory = loaded
        return loaded
    }

    /// The remembered result for `url`, if the file hasn't changed since (same size and modification date).
    nonisolated static func entry(for url: URL, in entries: [String: Entry]) -> Entry? {
        guard let e = entries[url.standardizedFileURL.path], let (size, modified) = RedumpCache.fingerprint(url),
              e.size == size, abs(e.modified - modified) < 1 else { return nil }
        return e
    }

    @MainActor static func store(_ url: URL, damaged: Bool, why: String?, sha1: String?) {
        guard let (size, modified) = RedumpCache.fingerprint(url) else { return }
        var entries = all()
        entries[url.standardizedFileURL.path] = Entry(size: size, modified: modified, damaged: damaged, why: why, sha1: sha1, date: Date())
        save(entries)
    }

    /// Keeps a result attached to a file after it's renamed or moved.
    @MainActor static func move(_ old: URL, to new: URL) {
        var entries = all()
        guard let e = entries.removeValue(forKey: old.standardizedFileURL.path) else { return }
        entries[new.standardizedFileURL.path] = e
        save(entries)
    }

    @MainActor private static func save(_ entries: [String: Entry]) {
        memory = entries
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }
}

@MainActor
final class DamageCheck: ObservableObject {
    static let shared = DamageCheck()

    /// What can be checked: CHDs (which carry checksums of everything in them) and Dolphin's formats.
    nonisolated static let extensions: Set<String> = ["chd", "rvz", "wia", "gcz"]
    /// Files found undamaged this recently are skipped unless "Check again" is on.
    nonisolated static let recentDays = 30

    struct Item: Identifiable {
        enum State { case waiting, checking, ok, damaged, failed }
        let id = UUID()
        var url: URL
        var state: State = .waiting
        var progress: Double?
        var why: String?
        var remembered: Date?   // found undamaged on this date, so not read again
    }

    @Published var items: [Item] = []
    @Published private(set) var isRunning = false
    @Published var message = ""
    /// Read again even files found undamaged in the last `recentDays` days.
    @Published var recheck = false
    private var cancelled = false
    private var current: Process?

    var damaged: [Item] { items.filter { $0.state == .damaged } }

    func add(_ urls: [URL]) {
        let fm = FileManager.default
        var found: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let all = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?.allObjects as? [URL] ?? []
                found += all.filter { DamageCheck.extensions.contains($0.pathExtension.lowercased()) }
            } else if DamageCheck.extensions.contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }
        let have = Set(items.map { $0.url.standardizedFileURL })
        items += Array(Set(found.map(\.standardizedFileURL))).filter { !have.contains($0) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { Item(url: $0) }
        message = found.isEmpty ? "No CHD, RVZ, WIA or GCZ files found in what was added." : ""
    }

    func clear() { if !isRunning { items = []; message = "" } }

    func cancel() { cancelled = true; current?.terminate() }

    /// Checks the waiting files one at a time (reading two at once from one drive is slower, not faster).
    func start() {
        guard !isRunning, let chdman = Converter.shared.chdman else { return }
        let dolphin = Converter.findTool("dolphin-tool")
        isRunning = true
        cancelled = false
        message = ""
        let index = RedumpDB.shared.index
        let checked = RedumpCache.all()
        // For RVZs that matched Redump before: the SHA-1s Redump lists for that game, to compare against.
        var redumpGame: [URL: String] = [:]
        for item in items where item.url.pathExtension.lowercased() != "chd" {
            if case .match(let g) = RedumpCache.result(for: item.url, in: checked, datStamp: index.stamp) { redumpGame[item.url] = g }
        }
        var shasOf: [String: Set<String>] = [:]
        if !redumpGame.isEmpty {
            let wanted = Set(redumpGame.values)
            for (sha, roms) in index.roms { for r in roms where wanted.contains(r.game) { shasOf[r.game, default: []].insert(sha) } }
        }
        Task {
            var skipped = 0
            while !cancelled, let i = items.firstIndex(where: { $0.state == .waiting }) {
                let url = items[i].url, id = items[i].id
                let previous = DamageRecord.entry(for: url, in: DamageRecord.all())
                if !recheck, let p = previous, !p.damaged, Date().timeIntervalSince(p.date) < Double(DamageCheck.recentDays) * 86400 {
                    items[i].state = .ok; items[i].remembered = p.date; skipped += 1
                    continue
                }
                items[i].state = .checking
                items[i].remembered = nil
                let expected = redumpGame[url].map { ($0, shasOf[$0] ?? []) }
                let outcome = await DamageCheck.check(url, chdman: chdman, dolphin: dolphin, previous: previous, redump: expected,
                    started: { p in Task { @MainActor in self.current = p } },
                    progress: { p in Task { @MainActor in self.set(id) { $0.progress = p } } })
                if cancelled { set(id) { $0.state = .waiting; $0.progress = nil }; break }
                set(id) {
                    switch outcome {
                    case .ok(let sha):
                        $0.state = .ok
                        DamageRecord.store(url, damaged: false, why: nil, sha1: sha)
                    case .damaged(let why):
                        $0.state = .damaged; $0.why = why
                        // Keep the last good SHA-1, so the next check still compares against it.
                        DamageRecord.store(url, damaged: true, why: why, sha1: previous?.sha1)
                    case .couldNotCheck(let why):
                        $0.state = .failed; $0.why = why
                    }
                }
            }
            current = nil
            isRunning = false
            let ok = items.filter { $0.state == .ok }.count, bad = damaged.count
            let failed = items.filter { $0.state == .failed }.count
            guard ok + bad + failed > 0 else { return }
            var parts = [bad == 0 ? "No damage found in \(ok) file\(ok == 1 ? "" : "s")."
                                  : "\(bad) damaged, \(ok) undamaged."]
            if skipped > 0 { parts.append("\(skipped) found undamaged in the last \(DamageCheck.recentDays) days weren't read again.") }
            if failed > 0 { parts.append("\(failed) couldn't be checked.") }
            if cancelled { parts.append("Stopped; click Check to carry on.") }
            message = parts.joined(separator: " ")
            if !cancelled {
                Notifier.post(id: "damage-check", title: bad == 0 ? "No damaged files found" : "\(bad) damaged file\(bad == 1 ? "" : "s") found",
                              body: message)
            }
            if Library.shared.report != nil { Library.shared.rescan() }
        }
    }

    private func set(_ id: UUID, _ change: (inout Item) -> Void) {
        if let i = items.firstIndex(where: { $0.id == id }) { change(&items[i]) }
    }

    enum Outcome: Sendable, Equatable {
        case ok(sha1: String?)
        case damaged(String)
        case couldNotCheck(String)
    }

    /// Reads one file through.
    /// - A CHD: `chdman verify` checks every block's checksum and the SHA-1 of the whole disc stored in it,
    ///   so any damage is found.
    /// - A GameCube/Wii disc: dolphin-tool reads it through and works out the SHA-1 of the disc inside. It's
    ///   damaged if that fails, or if the SHA-1 isn't the one Redump lists for the game it matched before,
    ///   or isn't what it was at the last check (the file's size and date unchanged).
    nonisolated static func check(_ url: URL, chdman: URL, dolphin: URL?, previous: DamageRecord.Entry?,
                                  redump: (game: String, shas: Set<String>)?,
                                  started: @escaping @Sendable (Process) -> Void,
                                  progress: @escaping @Sendable (Double?) -> Void) async -> Outcome {
        guard FileManager.default.fileExists(atPath: url.path) else { return .couldNotCheck("It isn't there any more") }
        if url.pathExtension.lowercased() == "chd" {
            progress(0)
            let (status, lines) = await ToolRun.run(chdman, ["verify", "-i", url.path], started: started) { progress($0) }
            if status == 0 { return .ok(sha1: nil) }
            if status == Converter.stalledStatus { return .damaged("chdman stopped responding while reading it (an unreadable spot on the drive?)") }
            let all = lines.joined(separator: "\n")
            if all.contains("Decompression error") { return .damaged("Part of it can't be decompressed") }
            if all.range(of: "SHA1", options: .caseInsensitive) != nil && all.range(of: "error|mismatch|actual", options: [.regularExpression, .caseInsensitive]) != nil {
                return .damaged("Its data doesn't match the checksum stored in it")
            }
            if all.contains("No such file") || all.contains("Permission denied") { return .couldNotCheck("chdman couldn't open it") }
            let line = lines.last { $0.contains("rror") }?.replacingOccurrences(of: #"\s*\([^)]*\):"#, with: ":", options: .regularExpression)
            return .damaged("chdman couldn't read it through" + (line.map { " (\($0.trimmingCharacters(in: .whitespaces)))" } ?? ""))
        }
        guard let dolphin else { return .couldNotCheck("dolphin-tool is missing from the app") }
        progress(nil)
        let (status, lines) = await ToolRun.run(dolphin, ["verify", "-i", url.path, "-a", "sha1"], watchdog: false, started: started) { _ in }
        let sha = status == 0 ? lines.lazy.compactMap { l in l.range(of: #"\b[0-9a-fA-F]{40}\b"#, options: .regularExpression).map { l[$0].lowercased() } }.first : nil
        guard let sha else {
            let line = lines.last { $0.contains("rror") }
            return .damaged("dolphin-tool couldn't read it through" + (line.map { " (\($0.trimmingCharacters(in: .whitespaces)))" } ?? ""))
        }
        if let redump, !redump.shas.isEmpty, !redump.shas.contains(sha) {
            return .damaged("It matched Redump's “\(redump.game)” before, and doesn't now")
        }
        if let old = previous?.sha1, old != sha {
            return .damaged("Its disc data has changed since it was checked on \(previous!.date.formatted(date: .abbreviated, time: .omitted)), though the file's date hasn't")
        }
        return .ok(sha1: sha)
    }
}

struct DamageCheckView: View {
    @ObservedObject private var m = DamageCheck.shared
    @ObservedObject private var c = Converter.shared
    @State private var dropTargeted = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reads each CHD and GameCube/Wii disc (RVZ, WIA, GCZ) all the way through, to find damage from a failing drive, a bad copy or a bad download. Nothing is changed.")
                .foregroundStyle(.secondary)
            Text("A CHD carries checksums of everything in it, so any damage is found. A GameCube or Wii disc is compared with Redump when it matched before, and with what it was at its last check here. CSO, ZSO and PBP files carry no checksums, so they can't be checked.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Add Files…") { pick(folders: false) }
                Button("Choose Folder…") { pick(folders: true) }
                Button("Clear") { m.clear() }.disabled(m.isRunning || m.items.isEmpty)
                Spacer()
                Toggle("Check again if checked in the last \(DamageCheck.recentDays) days", isOn: $m.recheck).disabled(m.isRunning)
                if m.isRunning {
                    Button("Stop") { m.cancel() }
                } else {
                    Button("Check") { m.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!m.items.contains { $0.state == .waiting } || c.chdman == nil)
                }
            }
            list
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).opacity(dropTargeted ? 1 : 0))
                .dropDestination(for: URL.self) { urls, _ in m.add(urls); return true } isTargeted: { dropTargeted = $0 }
            if !m.message.isEmpty { Text(m.message).font(.callout) }
            HStack {
                Button("Show \(m.damaged.count) Damaged in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(m.damaged.map(\.url))
                }
                .disabled(m.damaged.isEmpty)
                Spacer()
                Button("Back to Converterator") {
                    openWindow(id: "main")
                    dismissWindow(id: "damage")
                }
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 440)
    }

    private var list: some View {
        List {
            if m.items.isEmpty {
                Text("Drop CHD, RVZ, WIA or GCZ files or folders here.").foregroundStyle(.secondary)
            }
            ForEach(m.items) { item in
                HStack(spacing: 10) {
                    icon(item).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        if item.state == .checking {
                            if let p = item.progress { ProgressView(value: p).controlSize(.small) } else { ProgressView().progressViewStyle(.linear).controlSize(.small) }
                        }
                        Text(detail(item)).font(.caption)
                            .foregroundStyle(item.state == .damaged ? Color.red : Color.secondary)
                            .lineLimit(2)
                    }
                }
                .contextMenu { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } }
            }
        }
    }

    @ViewBuilder private func icon(_ item: DamageCheck.Item) -> some View {
        switch item.state {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .checking: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .damaged: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func detail(_ item: DamageCheck.Item) -> String {
        switch item.state {
        case .waiting: return "Waiting · " + formatBytes(totalSize([item.url]))
        case .checking: return item.progress.map { "Reading — \(Int($0 * 100))%" } ?? "Reading…"
        case .ok:
            return item.remembered.map { "Undamaged when checked on \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Undamaged"
        case .damaged: return "Damaged: " + (item.why ?? "")
        case .failed: return "Couldn't check: " + (item.why ?? "")
        }
    }

    private func pick(folders: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = !folders
        panel.canChooseDirectories = folders
        if !folders { panel.allowedContentTypes = DamageCheck.extensions.compactMap { UTType(filenameExtension: $0) } }
        panel.message = folders ? "Choose a folder of games (subfolders are included)" : "Choose CHD, RVZ, WIA or GCZ files to check"
        let done: (NSApplication.ModalResponse) -> Void = { if $0 == .OK { m.add(panel.urls) } }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }
}
