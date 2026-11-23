// Converterator — Redump: DAT parsing, hashing and matching dumps, and downloading DATs from redump.org.
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import CryptoKit

// MARK: - Redump

/// Hashes of known good dumps, from Redump DAT files (Logiqx XML, one per system, from redump.org).
struct RedumpIndex: Sendable {
    struct Rom: Sendable { let game: String; let name: String }
    /// SHA-1 (lowercase hex) of each track file → which game and file it is.
    var roms: [String: [Rom]] = [:]
    /// How many track files (not counting the .cue) each game has.
    var trackCount: [String: Int] = [:]
    /// Game name → redump.org system ("psx"), for DATs downloaded by system.
    var system: [String: String] = [:]
    var gameCount: Int { trackCount.count }
    /// Changes whenever the loaded DATs change, so remembered "no match" results get rechecked.
    var stamp: String { "\(gameCount)-\(roms.count)" }
    var isEmpty: Bool { roms.isEmpty }

    mutating func merge(_ other: RedumpIndex) {
        for (k, v) in other.roms { roms[k, default: []] += v }
        trackCount.merge(other.trackCount) { a, _ in a }
        system.merge(other.system) { a, _ in a }
    }

    /// Parses a Logiqx XML DAT (what redump.org publishes). Returns nil if it isn't one.
    static func parse(_ data: Data) -> RedumpIndex? {
        final class Delegate: NSObject, XMLParserDelegate {
            var index = RedumpIndex()
            var game: String?
            var sawDatafile = false
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes a: [String: String] = [:]) {
                switch name {
                case "datafile": sawDatafile = true
                case "game", "machine": game = a["name"]
                case "rom":
                    guard let game, let rom = a["name"], let sha1 = a["sha1"]?.lowercased(), !sha1.isEmpty else { return }
                    if (rom as NSString).pathExtension.lowercased() == "cue" { return }   // cue sheets differ in whitespace; tracks are what count
                    index.roms[sha1, default: []].append(.init(game: game, name: rom))
                    index.trackCount[game, default: 0] += 1
                default: break
                }
            }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                if name == "game" || name == "machine" { game = nil }
            }
        }
        let parser = XMLParser(data: data)
        let d = Delegate()
        parser.delegate = d
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), d.sawDatafile else { return nil }
        return d.index
    }
}

enum RedumpResult: Sendable, Codable {
    case match(String)                  // every track matches this game
    case partial(String, Int, Int)      // game, tracks matched, tracks the game has
    case noMatch

    var isMatch: Bool { if case .match = self { return true } else { return false } }

    /// Short text for the job's status line.
    var short: String {
        switch self {
        case .match: return "✓ Redump"
        case .partial: return "⚠ partial Redump match"
        case .noMatch: return "⚠ not in Redump"
        }
    }

    /// Longer text for the log.
    var long: String {
        switch self {
        case .match(let g): return "Redump: matches “\(g)”"
        case .partial(let g, let n, let total): return "Redump: \(n) of \(total) tracks match “\(g)”; the others differ (a bad or modified dump?)"
        case .noMatch: return "Redump: no match in the loaded DAT files (a bad, modified or unlisted dump, or a different system's DAT)"
        }
    }

    /// Hashes `tracks` and looks them up. `progress` gets 0…1 by bytes read.
    static func check(tracks: [URL], index: RedumpIndex, progress: @escaping @Sendable (Double) -> Void) -> RedumpResult {
        let total = max(totalSize(tracks), 1)
        var done = 0.0
        var hits: [String: Int] = [:]   // game → tracks matched
        for t in tracks {
            guard let sha1 = sha1Hex(of: t, onBytes: { done += $0; progress(min(done / total, 1)) }) else { continue }
            // One file can appear in several games (e.g. a shared audio track); count it for each.
            for g in Set((index.roms[sha1] ?? []).map(\.game)) { hits[g, default: 0] += 1 }
        }
        guard let (game, n) = hits.max(by: { $0.value < $1.value }) else { return .noMatch }
        let expected = index.trackCount[game] ?? n
        return n == tracks.count && n == expected ? .match(game) : .partial(game, n, expected)
    }

    /// A whole disc image's SHA-1 looked up (for single-file discs, like GameCube and Wii).
    static func lookup(sha1: String, index: RedumpIndex) -> RedumpResult {
        let games = Set((index.roms[sha1.lowercased()] ?? []).map(\.game)).sorted()
        guard let game = games.first else { return .noMatch }
        return (index.trackCount[game] ?? 1) == 1 ? .match(game) : .partial(game, 1, index.trackCount[game] ?? 1)
    }

    /// SHA-1 of a file, read in 8 MB chunks. `onBytes` is told how much was read each time.
    static func sha1Hex(of url: URL, onBytes: (Double) -> Void) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = Insecure.SHA1()
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            onBytes(Double(chunk.count))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Redump DAT files: downloaded from redump.org for the systems you pick, plus any you add yourself,
/// and the combined index built from them.
@MainActor
final class RedumpDB: ObservableObject {
    static let shared = RedumpDB()

    /// Disc systems redump.org has DATs for, as (URL slug, name). Only these can be downloaded.
    nonisolated static let systems: [(slug: String, name: String)] = [
        ("psx", "Sony PlayStation"), ("ps2", "Sony PlayStation 2"), ("psp", "Sony PlayStation Portable"),
        ("mcd", "Sega CD / Mega CD"), ("ss", "Sega Saturn"), ("dc", "Sega Dreamcast"),
        ("pce", "PC Engine CD / TurboGrafx CD"), ("pc-fx", "NEC PC-FX"), ("ngcd", "Neo Geo CD"),
        ("3do", "3DO"), ("cdi", "Philips CD-i"), ("cd32", "Amiga CD32"), ("ajcd", "Atari Jaguar CD"),
        ("gc", "Nintendo GameCube"), ("wii", "Nintendo Wii"), ("xbox", "Microsoft Xbox"),
        ("fmt", "FM Towns"), ("pc-98", "NEC PC-98"), ("x68k", "Sharp X68000"),
    ]
    nonisolated static let defaultSystems: Set<String> = ["psx", "ps2", "psp", "mcd", "ss", "dc"]
    nonisolated static func systemName(_ slug: String) -> String { systems.first { $0.slug == slug }?.name ?? slug }

    struct DAT: Identifiable, Sendable {
        let url: URL
        let games: Int
        let system: String?       // slug, for downloaded ones
        var id: String { url.path }
    }

    @Published private(set) var dats: [DAT] = []
    @Published private(set) var index = RedumpIndex()
    @Published private(set) var isLoading = false
    @Published var lastError: String?
    /// Check dumps while converting (only when at least one DAT is loaded).
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "redumpEnabled") } }
    /// With "Move source files to Trash" on, keep the originals of dumps that don't match.
    @Published var keepUnmatched: Bool { didSet { UserDefaults.standard.set(keepUnmatched, forKey: "redumpKeepUnmatched") } }
    /// Name each CHD after the Redump game it matches.
    @Published var renameToRedump: Bool { didSet { UserDefaults.standard.set(renameToRedump, forKey: "redumpRename") } }
    /// Fetch DATs from redump.org when the app opens (at most once a day).
    @Published var autoDownload: Bool {
        didSet { UserDefaults.standard.set(autoDownload, forKey: "redumpAutoDownload"); if autoDownload { updateFromWeb(force: true) } }
    }
    /// Which systems to download.
    @Published var systems: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(systems).sorted(), forKey: "redumpSystems")
            reload()
            if autoDownload && !systems.subtracting(oldValue).isEmpty { updateFromWeb(force: true) }
        }
    }
    @Published private(set) var downloadStatus = ""
    @Published private(set) var isDownloading = false

    var active: Bool { enabled && !index.isEmpty }

    private var paths: [String] {
        get { UserDefaults.standard.stringArray(forKey: "redumpDATs") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "redumpDATs") }
    }
    /// slug → the file name redump.org gave the DAT we have, e.g. "Sony - PlayStation - Datfile (10914) (2026-06-15 11-55-46).zip"
    private var downloaded: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "redumpDownloaded") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "redumpDownloaded") }
    }

    nonisolated static var storage: URL { AppPaths.dataDir.appendingPathComponent("Redump", isDirectory: true) }
    nonisolated static func storedDAT(_ slug: String) -> URL { storage.appendingPathComponent("\(slug).zip") }

    init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "redumpEnabled") as? Bool ?? true
        keepUnmatched = d.object(forKey: "redumpKeepUnmatched") as? Bool ?? true
        renameToRedump = d.bool(forKey: "redumpRename")
        autoDownload = d.object(forKey: "redumpAutoDownload") as? Bool ?? true
        systems = (d.stringArray(forKey: "redumpSystems")).map(Set.init) ?? RedumpDB.defaultSystems
        reload()
    }

    func add(_ urls: [URL]) {
        paths = Array(Set(paths + urls.map(\.path))).sorted()
        reload()
    }

    func remove(_ dat: DAT) {
        if let slug = dat.system { systems.remove(slug) } else { paths.removeAll { $0 == dat.url.path } }
        reload()
    }

    /// "Updated 15 Jun 2026" for a downloaded DAT, from the date in redump.org's file name.
    func datDate(_ slug: String) -> String? {
        guard let name = downloaded[slug],
              let r = name.range(of: #"\((\d{4}-\d{2}-\d{2})"#, options: .regularExpression) else { return nil }
        return String(name[r].dropFirst())
    }

    /// Reads every DAT on a background thread: the downloaded ones for the chosen systems, then any added by hand.
    func reload() {
        let fm = FileManager.default
        let sources: [(URL, String?)] =
            systems.sorted().map { (RedumpDB.storedDAT($0), $0) }.filter { fm.fileExists(atPath: $0.0.path) }
            + paths.map { (URL(fileURLWithPath: $0), nil) }
        isLoading = true
        Task.detached {
            var merged = RedumpIndex(), loaded: [DAT] = [], failed: [String] = []
            for (url, slug) in sources {
                if var one = RedumpDB.load(url) {
                    if let slug { for game in one.trackCount.keys { one.system[game] = slug } }
                    merged.merge(one); loaded.append(DAT(url: url, games: one.gameCount, system: slug))
                } else {
                    failed.append(slug.map(RedumpDB.systemName) ?? url.lastPathComponent)
                }
            }
            let (m, l, f) = (merged, loaded, failed)
            await MainActor.run {
                self.index = m
                self.dats = l
                self.isLoading = false
                self.lastError = f.isEmpty ? nil : "Couldn't read: \(f.joined(separator: ", ")). It may have moved, or isn't a Redump DAT."
            }
        }
    }

    // MARK: Downloading

    /// Fetches the chosen systems' DATs from redump.org, skipping any whose file name (which carries its
    /// date) hasn't changed. Without `force`, does nothing if it already checked in the last 24 hours.
    func updateFromWeb(force: Bool = false) {
        guard autoDownload, !isDownloading else { return }
        let last = UserDefaults.standard.object(forKey: "redumpLastCheck") as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(last) > 24 * 3600 else { return }
        isDownloading = true
        let wanted = systems.sorted()
        Task {
            var problems: [String] = [], updated = 0
            try? FileManager.default.createDirectory(at: RedumpDB.storage, withIntermediateDirectories: true)
            for slug in wanted {
                let name = RedumpDB.systemName(slug)
                downloadStatus = "Checking \(name)…"
                do {
                    if let newName = try await RedumpDB.fetch(slug: slug, haveName: downloaded[slug],
                                                              haveFile: FileManager.default.fileExists(atPath: RedumpDB.storedDAT(slug).path)) {
                        downloaded[slug] = newName
                        updated += 1
                    }
                } catch {
                    problems.append(name)
                }
            }
            UserDefaults.standard.set(Date(), forKey: "redumpLastCheck")
            isDownloading = false
            let time = Date().formatted(date: .abbreviated, time: .shortened)
            downloadStatus = problems.isEmpty
                ? "Checked redump.org \(time)" + (updated > 0 ? ": \(updated) DAT\(updated == 1 ? "" : "s") updated." : ". All up to date.")
                : "Couldn't reach redump.org for \(problems.joined(separator: ", ")). It'll try again next time the app opens."
            if updated > 0 { reload() }
        }
    }

    /// Downloads one system's DAT if redump.org has a different one than we do.
    /// Returns its new file name, or nil if ours is current. Throws on network errors.
    nonisolated static func fetch(slug: String, haveName: String?, haveFile: Bool) async throws -> String? {
        let url = URL(string: "http://redump.org/datfile/\(slug)/")!
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 120   // redump.org is often slow
        let (_, headResponse) = try await URLSession.shared.data(for: head)
        guard let http = headResponse as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        let name = fileName(fromDisposition: http.value(forHTTPHeaderField: "Content-Disposition")) ?? "\(slug).zip"
        if haveFile && haveName == name { return nil }

        var get = URLRequest(url: url)
        get.timeoutInterval = 300
        let (tmp, response) = try await URLSession.shared.download(for: get)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        // Only keep it if it really is a DAT; otherwise the one we had stays.
        let zip = renamed(tmp, ext: "zip")
        guard load(zip) != nil else {
            try? FileManager.default.removeItem(at: zip)
            throw URLError(.cannotParseResponse)
        }
        let dest = storedDAT(slug)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: zip, to: dest)
        return name
    }

    /// The download lands with a temporary name; give it an extension so it's read as a zip.
    nonisolated private static func renamed(_ url: URL, ext: String) -> URL {
        let target = url.deletingPathExtension().appendingPathExtension(ext)
        if !FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.moveItem(at: url, to: target) }
        return target
    }

    /// `attachment; filename="Sony - PlayStation - Datfile (10914) (2026-06-15 11-55-46).zip"` → the name.
    nonisolated static func fileName(fromDisposition header: String?) -> String? {
        guard let header, let r = header.range(of: #"filename="[^"]+""#, options: .regularExpression) else { return nil }
        return String(header[r].dropFirst(10).dropLast())
    }

    nonisolated static func load(_ url: URL) -> RedumpIndex? {
        if url.pathExtension.lowercased() == "zip" {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("converterator-dat-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: tmp) }
            guard (try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil,
                  UpdateChecker.runTool("/usr/bin/ditto", ["-x", "-k", url.path, tmp.path]) == 0 else { return nil }
            let dats = (fm.enumerator(at: tmp, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { ["dat", "xml"].contains($0.pathExtension.lowercased()) }
            var merged = RedumpIndex(), any = false
            for d in dats { if let data = try? Data(contentsOf: d), let i = RedumpIndex.parse(data) { merged.merge(i); any = true } }
            return any ? merged : nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return RedumpIndex.parse(data)
    }
}

// MARK: - Remembered results

/// Redump results for CHDs, kept in Application Support so a CHD that hasn't changed (same size and
/// modification date) isn't unpacked and checked again. A match stays a match; a "no match" or
/// partial result is rechecked when the loaded DATs change.
enum RedumpCache {
    struct Entry: Codable, Sendable {
        let size: Int64
        let modified: Double
        let result: RedumpResult
        let datStamp: String
    }

    static var file: URL { AppPaths.dataDir.appendingPathComponent("redump-results.json") }

    @MainActor private static var memory: [String: Entry]?

    @MainActor static func all() -> [String: Entry] {
        if let memory { return memory }
        let loaded = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        memory = loaded
        return loaded
    }

    nonisolated static func fingerprint(_ url: URL) -> (Int64, Double)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (a[.size] as? NSNumber)?.int64Value,
              let date = a[.modificationDate] as? Date else { return nil }
        return (size, date.timeIntervalSince1970)
    }

    /// The remembered result for `chd`, if it still applies. Safe to call off the main thread with a snapshot.
    nonisolated static func result(for chd: URL, in entries: [String: Entry], datStamp: String) -> RedumpResult? {
        guard let e = entries[chd.standardizedFileURL.path], let (size, modified) = fingerprint(chd),
              e.size == size, abs(e.modified - modified) < 1 else { return nil }
        return e.result.isMatch || e.datStamp == datStamp ? e.result : nil
    }

    @MainActor static func lookup(_ chd: URL) -> RedumpResult? {
        result(for: chd, in: all(), datStamp: RedumpDB.shared.index.stamp)
    }

    @MainActor static func store(_ chd: URL, _ result: RedumpResult) {
        guard let (size, modified) = fingerprint(chd) else { return }
        var entries = all()
        entries[chd.standardizedFileURL.path] = Entry(size: size, modified: modified, result: result,
                                                       datStamp: RedumpDB.shared.index.stamp)
        save(entries)
    }

    /// Keeps a result attached to a CHD after it's renamed.
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
