// Converterator — File → Library Report…
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import CryptoKit

// MARK: - Library report

/// A look over a whole folder of games: what's converted, what isn't, leftovers, missing discs and playlists.
struct LibraryReport: Sendable {
    struct MissingDiscs: Identifiable, Sendable {
        let id = UUID()
        let dir: URL
        let name: String
        let have: [Int]
        let expected: Int
        let fromRedump: Bool
        var missing: [Int] { (1...max(expected, have.max() ?? 1)).filter { !have.contains($0) } }
    }
    struct NeedsPlaylist: Identifiable, Sendable {
        let id = UUID()
        let dir: URL
        let name: String
        let discs: [URL]
    }

    /// A game here with a patch waiting in your patches folder.
    struct PatchOffer: Identifiable, Sendable {
        let id = UUID()
        let game: URL                  // the original, or the CHD if that's all there is
        let patch: PatchLibrary.Entry
        let name: String               // what the patched CHD will be called
    }
    var patchOffers: [PatchOffer] = []
    var patchesFolderOn = false

    var chds: [URL] = []
    var chdBytes = 0.0
    var redumpNamed = 0               // CHDs whose name is exactly a Redump game name
    var redumpMatched = 0             // CHDs remembered as matching Redump
    var redumpNotMatching: [URL] = [] // remembered as partial or no match
    var redumpUnchecked: [URL] = []   // never checked, or changed since
    var unconverted: [URL] = []
    var unconvertedBytes = 0.0
    var leftovers: [Cleanup.Item] = []  // originals whose CHDs exist
    var leftoverBytes = 0.0
    var missingDiscs: [MissingDiscs] = []
    var needsPlaylist: [NeedsPlaylist] = []

    /// Copies of the same disc: CHDs holding the same data, or files matching the same Redump game.
    struct IdenticalCopies: Identifiable, Sendable {
        let id = UUID()
        let files: [URL]
        let why: String
        /// What deleting all but the biggest copy would free.
        var extraBytes: Double { totalSize(files) - (files.map { totalSize([$0]) }.max() ?? 0) }
    }
    /// The same game in more than one version (region, language, revision or patch), not identical.
    struct Versions: Identifiable, Sendable {
        let id = UUID()
        let title: String
        let files: [URL]
    }
    var identical: [IdenticalCopies] = []
    var identicalBytes = 0.0
    var versions: [Versions] = []

    nonisolated static func build(folder: URL, outputDir: URL?, sevenZip: URL?, log: [String: [String]],
                                  redump: RedumpIndex, checked: [String: RedumpCache.Entry] = [:],
                                  patchesFolder: URL? = nil, preferLanguage: String? = nil,
                                  status: @escaping @Sendable (String) -> Void) -> LibraryReport {
        var r = LibraryReport()
        let fm = FileManager.default
        status("Listing files…")
        let all = (fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
            .allObjects as? [URL] ?? [])
        r.chds = all.filter { $0.pathExtension.lowercased() == "chd" }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        r.chdBytes = totalSize(r.chds)

        // Redump game names, and for multi-disc games how many discs Redump lists.
        let redumpNames = Set(redump.trackCount.keys)
        var redumpDiscs: [String: Int] = [:]
        for name in redumpNames {
            if let d = DiscName.parse(name) { redumpDiscs[d.key] = max(redumpDiscs[d.key] ?? 0, d.of ?? d.disc) }
        }
        r.redumpNamed = r.chds.filter { redumpNames.contains($0.deletingPathExtension().lastPathComponent) }.count
        let rvzs = all.filter { $0.pathExtension.lowercased() == "rvz" }
        for chd in r.chds + rvzs {   // (GameCube/Wii RVZs are checked too)
            switch RedumpCache.result(for: chd, in: checked, datStamp: redump.stamp) {
            case .some(let res) where res.isMatch: r.redumpMatched += 1
            case .some: r.redumpNotMatching.append(chd)
            case .none: r.redumpUnchecked.append(chd)
            }
        }

        status("Matching originals with CHDs…")
        let (converted, unconverted) = Cleanup.scanSources(in: folder, outputDir: outputDir, sevenZip: sevenZip, log: log)
        r.leftovers = Cleanup.unambiguous(converted).0
        r.leftoverBytes = r.leftovers.reduce(0) { $0 + $1.bytes }
        r.unconverted = unconverted
        r.unconvertedBytes = unconverted.reduce(0) { $0 + totalSize(Converter.sourceFiles(for: $1)) }

        status("Looking for missing discs and playlists…")
        // Disc sets per folder, counting both CHDs and not-yet-converted disc images.
        let discFiles = r.chds + unconverted.filter { ["ecm"].contains($0.pathExtension.lowercased()) || Converter.inputExtensions.contains($0.pathExtension.lowercased()) }
        var sets: [String: (dir: URL, name: String, discs: Set<Int>, of: Int?)] = [:]
        for f in discFiles {
            guard let d = DiscName.parse(Converter.gameName(f)) else { continue }
            let dir = f.deletingLastPathComponent()
            let k = dir.path + "\u{0}" + d.key
            var e = sets[k] ?? (dir, d.key, [], nil)
            e.discs.insert(d.disc)
            if let of = d.of { e.of = max(e.of ?? 0, of) }
            sets[k] = e
        }
        for e in sets.values {
            let redumpCount = redumpDiscs[e.name]
            let expected = e.of ?? redumpCount ?? (e.discs.max() ?? 1)
            let set = MissingDiscs(dir: e.dir, name: e.name, have: e.discs.sorted(), expected: expected,
                                   fromRedump: e.of == nil && redumpCount != nil)
            if !set.missing.isEmpty { r.missingDiscs.append(set) }
        }
        r.missingDiscs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        for dir in Set(r.chds.map { $0.deletingLastPathComponent() }) {
            r.needsPlaylist += Playlist.missing(in: dir).map { NeedsPlaylist(dir: dir, name: $0.name, discs: $0.discs) }
        }
        r.needsPlaylist.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        status("Looking for duplicates…")
        (r.identical, r.versions) = duplicates(compressed: r.chds + rvzs, originals: unconverted,
                                               checked: checked, datStamp: redump.stamp)
        r.identicalBytes = r.identical.reduce(0) { $0 + $1.extraBytes }

        if let patchesFolder {
            status("Looking for patches for your games…")
            r.patchesFolderOn = true
            r.patchOffers = patchOffers(patchesFolder: patchesFolder, prefer: preferLanguage, outputDir: outputDir,
                                        unconverted: unconverted, leftovers: r.leftovers, chds: r.chds)
        }
        return r
    }

    /// The SHA-1 of the disc data a CHD holds, from its header (CHD versions 4 and 5), without reading the rest.
    nonisolated static func chdDataSHA1(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 124), d.count >= 108, d.prefix(8) == Data("MComprHD".utf8) else { return nil }
        let version = d[12...15].reduce(0) { $0 << 8 | Int($1) }
        let offset: Int
        switch version {
        case 5 where d.count >= 124: offset = 64
        case 4: offset = 88
        default: return nil
        }
        let sha = d[offset..<(offset + 20)]
        guard sha.contains(where: { $0 != 0 }) else { return nil }
        return sha.map { String(format: "%02x", $0) }.joined()
    }

    /// Which copy of an identical set to keep: one a playlist (.m3u) next to it lists, then one named exactly as
    /// in Redump, then one remembered as matching Redump, then one in a folder per system; otherwise the one with
    /// the shortest name. The rest can go.
    nonisolated static func keeper(of files: [URL], redumpNames: Set<String>, checked: [String: RedumpCache.Entry],
                                   datStamp: String) -> URL {
        func score(_ f: URL) -> Int {
            var s = 0
            let dir = f.deletingLastPathComponent()
            let m3us = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "m3u" }
            if m3us.contains(where: { m in
                ((try? String(contentsOf: m, encoding: .utf8)) ?? "").components(separatedBy: .newlines)
                    .contains { $0.trimmingCharacters(in: .whitespaces) == f.lastPathComponent }
            }) { s += 8 }
            let base = f.deletingPathExtension().lastPathComponent
            if redumpNames.contains(where: { Converter.safeFileName($0) == base }) { s += 4 }
            if RedumpCache.result(for: f, in: checked, datStamp: datStamp)?.isMatch == true { s += 2 }
            if Systems.folderNames.contains(f.deletingLastPathComponent().lastPathComponent) { s += 1 }
            return s
        }
        return files.max { a, b in
            let (sa, sb) = (score(a), score(b))
            if sa != sb { return sa < sb }
            if a.lastPathComponent.count != b.lastPathComponent.count { return a.lastPathComponent.count > b.lastPathComponent.count }
            return a.path.localizedStandardCompare(b.path) == .orderedDescending
        } ?? files[0]
    }

    /// A game's title without its tags and disc number: "Racing Lagoon (Japan, Asia) (Disc 1)" → "Racing Lagoon".
    nonisolated static func plainTitle(_ name: String) -> String {
        var t = DiscName.parse(name)?.key ?? name
        if let r = t.range(of: #"\s*[\(\[]"#, options: .regularExpression) { t = String(t[..<r.lowerBound]) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Identical copies (same CHD data, or the same Redump match) among the CHDs and RVZs, and games kept in
    /// more than one version among those and the not-yet-converted originals (same title and disc number).
    nonisolated static func duplicates(compressed: [URL], originals: [URL], checked: [String: RedumpCache.Entry],
                                       datStamp: String) -> ([IdenticalCopies], [Versions]) {
        // Group the CHDs and RVZs that share a data SHA-1 or a Redump match (either joins them).
        var parent = Array(compressed.indices)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        var firstWith: [String: Int] = [:]
        var why: [Int: String] = [:]
        for (i, f) in compressed.enumerated() {
            var keys: [(String, String)] = []
            if f.pathExtension.lowercased() == "chd", let sha = chdDataSHA1(f) { keys.append(("data:" + sha, "same disc data")) }
            if case .match(let game) = RedumpCache.result(for: f, in: checked, datStamp: datStamp) {
                keys.append(("redump:" + game, "both match Redump's “\(game)”"))
            }
            for (k, reason) in keys {
                if let j = firstWith[k] {
                    let (a, b) = (find(i), find(j))
                    if a != b { parent[a] = b }
                    why[find(i)] = why[find(i)] ?? reason
                } else { firstWith[k] = i }
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in compressed.indices { groups[find(i), default: []].append(i) }
        var identical: [IdenticalCopies] = []
        var groupOf: [URL: Int] = [:]
        for (root, members) in groups where members.count > 1 {
            let files = members.map { compressed[$0] }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let reason = why[root] ?? members.compactMap { why[$0] }.first ?? "same disc data"
            identical.append(IdenticalCopies(files: files, why: files.count > 2 ? reason.replacingOccurrences(of: "both match", with: "all match") : reason))
            for f in files { groupOf[f] = identical.count - 1 }
        }
        identical.sort { $0.files[0].lastPathComponent.localizedStandardCompare($1.files[0].lastPathComponent) == .orderedAscending }

        // The same title and disc number in more than one file, unless they're all copies of one disc.
        var byTitle: [String: (title: String, files: [URL])] = [:]
        for f in compressed + originals {
            let name = Converter.gameName(f)
            let title = plainTitle(name)
            let key = PatchLibrary.key(title)
            guard key.count >= 2 else { continue }
            let disc = DiscName.parse(name)?.disc ?? 0
            let k = key + "#\(disc)"
            byTitle[k, default: (disc > 0 ? "\(title) (Disc \(disc))" : title, [])].files.append(f)
        }
        var versions: [Versions] = []
        for (_, v) in byTitle where v.files.count > 1 {
            let groupsHere = Set(v.files.map { groupOf[$0] ?? -1 })
            if groupsHere.count == 1, groupsHere.first != -1 { continue }   // all one identical set
            versions.append(Versions(title: v.title, files: v.files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }))
        }
        versions.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return (identical, versions)
    }

    /// Games (originals not converted yet, originals with CHDs, and CHDs on their own) with a patch in
    /// the patches folder, leaving out ones whose patched CHD is already there and CHDs that are patched
    /// themselves.
    nonisolated static func patchOffers(patchesFolder: URL, prefer: String?, outputDir: URL?,
                                        unconverted: [URL], leftovers: [Cleanup.Item], chds: [URL]) -> [PatchOffer] {
        let entries = PatchLibrary.index(patchesFolder)
        guard !entries.isEmpty else { return [] }
        let covered = Set(leftovers.flatMap(\.chds).map(\.standardizedFileURL))
        let patchedTag = "(" + (Patcher.tags.map(\.name) + ["Patched"]).joined(separator: "|") + ")"
        let loneCHDs = chds.filter { chd in
            !covered.contains(chd.standardizedFileURL)
                && chd.deletingPathExtension().lastPathComponent.range(of: #"\(\#(patchedTag)\)"#, options: .regularExpression) == nil
        }
        var offers: [PatchOffer] = []
        for game in unconverted + leftovers.map(\.source) + loneCHDs {
            guard let e = PatchLibrary.match(game: game, entries: entries, prefer: prefer) else { continue }
            let inner = e.member.map { URL(fileURLWithPath: $0) } ?? e.url
            let name = Patcher.patchedName(game: game, patch: inner, alsoLookIn: e.member == nil ? nil : e.url.deletingPathExtension().lastPathComponent)
            let dirs = [game.deletingLastPathComponent()] + (outputDir.map { [$0] } ?? [])
            if dirs.contains(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name + ".chd").path) }) { continue }
            offers.append(PatchOffer(game: game, patch: e, name: name))
        }
        return offers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: Export

extension LibraryReport {
    /// One row per item: Section, Name, Folder, Details, Size (bytes). Opens in Numbers or Excel.
    nonisolated func csv() -> String {
        var rows = [["Section", "Name", "Folder", "Details", "Size (bytes)"]]
        func add(_ section: String, _ url: URL, name: String? = nil, _ details: String = "", size: Double? = nil) {
            rows.append([section, name ?? url.lastPathComponent, url.deletingLastPathComponent().path, details, size.map { String(Int64($0)) } ?? ""])
        }
        rows.append(["Summary", "CHDs", "", "\(chds.count)", String(Int64(chdBytes))])
        for u in unconverted { add("Not converted yet", u, size: totalSize(Converter.sourceFiles(for: u))) }
        for i in leftovers { add("Originals with CHDs", i.source, "has " + i.chds.map(\.lastPathComponent).joined(separator: ", "), size: i.bytes) }
        for m in missingDiscs {
            rows.append(["Missing discs", m.name, m.dir.path,
                         "has \(m.have.map(String.init).joined(separator: ", ")); missing \(m.missing.map(String.init).joined(separator: ", "))", ""])
        }
        for p in needsPlaylist { rows.append(["Needs a playlist", p.name + ".m3u", p.dir.path, "\(p.discs.count) discs", ""]) }
        for o in patchOffers { add("Patches available", o.game, name: o.name + ".chd", "from \(o.game.lastPathComponent) with \(o.patch.member ?? o.patch.name)") }
        for (n, g) in identical.enumerated() {
            for f in g.files { add("Identical copies", f, "set \(n + 1): \(g.why)", size: totalSize([f])) }
        }
        for v in versions {
            for f in v.files { add("Several versions", f, v.title, size: totalSize([f])) }
        }
        for u in redumpNotMatching { add("Don't match Redump", u, size: totalSize([u])) }
        for u in redumpUnchecked { add("Not checked against Redump", u, size: totalSize([u])) }
        func cell(_ s: String) -> String { s.contains(where: { ",\"\n".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }
        return rows.map { $0.map(cell).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// The report as plain text, section by section.
    nonisolated func text(folder: URL?) -> String {
        var out = "Converterator Library Report\n"
        if let folder { out += folder.path + "\n" }
        out += Date().formatted(date: .long, time: .shortened) + "\n\n"
        out += "CHDs: \(chds.count) (\(formatBytes(chdBytes)))\n"
        func section(_ title: String, _ lines: [String]) {
            out += "\n\(title): \(lines.count)\n"
            for l in lines { out += "  \(l)\n" }
        }
        section("Not converted yet", unconverted.map { "\($0.lastPathComponent)  (\($0.deletingLastPathComponent().lastPathComponent))" })
        section("Originals that already have CHDs", leftovers.map { "\($0.source.lastPathComponent)  (\(formatBytes($0.bytes)))" })
        section("Multi-disc games with a disc missing", missingDiscs.map {
            "\($0.name): has disc \($0.have.map(String.init).joined(separator: ", ")); missing \($0.missing.map(String.init).joined(separator: ", "))"
        })
        section("Multi-disc games without a playlist", needsPlaylist.map { "\($0.name) (\($0.discs.count) discs)" })
        if patchesFolderOn { section("Patches available", patchOffers.map { "\($0.name).chd  from \($0.game.lastPathComponent)" }) }
        section("Identical copies (could free \(formatBytes(identicalBytes)))", identical.map {
            $0.files.map(\.lastPathComponent).joined(separator: " = ") + "  (\($0.why))"
        })
        section("Games in several versions", versions.map { "\($0.title): " + $0.files.map(\.lastPathComponent).joined(separator: ", ") })
        section("Don't match Redump", redumpNotMatching.map(\.lastPathComponent))
        out += "\nMatch Redump: \(redumpMatched)   Not checked yet: \(redumpUnchecked.count)\n"
        return out
    }
}

@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published var folder: URL?
    @Published private(set) var report: LibraryReport?
    @Published var isScanning = false
    @Published var hasLastSort = Organize.lastSort() != nil
    @Published var status = ""
    @Published var message = ""

    func scan(_ folder: URL) {
        self.folder = folder
        isScanning = true
        message = ""
        let outDir = Converter.shared.outputDir, sevenZip = Converter.shared.sevenZip
        let redump = RedumpDB.shared.index
        let checked = RedumpCache.all()
        let patches = PatchLibrary.shared.active ? PatchLibrary.shared.folder : nil
        let prefer = PatchLibrary.preferredLanguage
        Task.detached {
            let r = LibraryReport.build(folder: folder, outputDir: outDir, sevenZip: sevenZip, log: ConversionLog.load(),
                                        redump: redump, checked: checked, patchesFolder: patches, preferLanguage: prefer) { s in
                Task { @MainActor in self.status = s }
            }
            await MainActor.run { self.report = r; self.isScanning = false }
        }
    }

    func rescan() { if let folder { scan(folder) } }

    /// The copies Move Extra Copies to Trash would remove (all but one of each identical set).
    func extraCopies() -> [URL] {
        guard let report else { return [] }
        let names = Set(RedumpDB.shared.index.trackCount.keys), checked = RedumpCache.all(), stamp = RedumpDB.shared.index.stamp
        return report.identical.flatMap { g in
            let keep = LibraryReport.keeper(of: g.files, redumpNames: names, checked: checked, datStamp: stamp)
            return g.files.filter { $0 != keep }
        }
    }

    func moveExtraCopiesToTrash() {
        let extra = extraCopies()
        guard !extra.isEmpty else { return }
        let a = NSAlert()
        a.messageText = "Move \(extra.count) extra cop\(extra.count == 1 ? "y" : "ies") to the Trash?"
        a.informativeText = "One copy of each game stays: one a playlist lists, or one named as in Redump, or one in a folder per system, or else the one with the shortest name. This frees \(formatBytes(totalSize(extra))). You can put them back from the Trash.\n\n"
            + extra.prefix(8).map { "• " + $0.lastPathComponent }.joined(separator: "\n") + (extra.count > 8 ? "\n…and \(extra.count - 8) more" : "")
        a.addButton(withTitle: "Move to Trash")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var moved = 0, failed: [String] = []
        for f in extra {
            do { try FileManager.default.trashItem(at: f, resultingItemURL: nil); moved += 1 }
            catch { failed.append(f.lastPathComponent) }
        }
        message = "Moved \(moved) extra cop\(moved == 1 ? "y" : "ies") to the Trash." + (failed.isEmpty ? "" : " Couldn't move: \(failed.joined(separator: ", ")).")
        rescan()
    }

    /// Adds every game in the folder to RetroArch's playlists, by system.
    func addToRetroArch() {
        guard let folder else { return }
        let c = Converter.shared
        let (bySystem, unknown) = RetroArch.library(folder, index: RedumpDB.shared.index, checked: RedumpCache.all())
        var added = 0, errors: [String] = []
        for (system, entries) in bySystem {
            do { try RetroArch.add(entries, system: system, folder: c.retroArchPlaylistFolder); added += entries.count }
            catch { errors.append(error.localizedDescription) }
        }
        var parts = ["Added \(added) game\(added == 1 ? "" : "s") to \(bySystem.count) RetroArch playlist\(bySystem.count == 1 ? "" : "s")."]
        if !unknown.isEmpty {
            parts.append("\(unknown.count) couldn't be placed: their system isn't known. Put them in a folder named for the system (like “PlayStation”), or check them against Redump first.")
        }
        parts += errors
        message = parts.joined(separator: " ")
    }

    func makePlaylists() {
        guard let report else { return }
        var written = 0
        for dir in Set(report.needsPlaylist.map(\.dir)) { written += Playlist.make(in: dir).count }
        message = "Wrote \(written) playlist\(written == 1 ? "" : "s")."
        rescan()
    }
}

struct LibraryView: View {
    @ObservedObject private var m = Library.shared
    @ObservedObject private var c = Converter.shared
    @ObservedObject private var redump = RedumpDB.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(m.folder?.path(percentEncoded: false) ?? "Choose a folder of games, such as your whole ROMs folder.")
                    .lineLimit(1).truncationMode(.head)
                    .foregroundStyle(m.folder == nil ? .secondary : .primary)
                Spacer()
                if let r = m.report, !m.isScanning {
                    Menu("Export") {
                        Button("As a Spreadsheet (CSV)…") { export(r, csv: true) }
                        Button("As Text…") { export(r, csv: false) }
                    }
                    .fixedSize()
                }
                if m.folder != nil { Button("Rescan") { m.rescan() }.disabled(m.isScanning) }
                Button("Choose Folder…", action: chooseFolder).disabled(m.isScanning)
            }
            Divider()
            if m.isScanning {
                HStack { ProgressView().controlSize(.small); Text(m.status) }
                Spacer()
            } else if let r = m.report {
                report(r)
            } else {
                Text("The report shows which games are converted, which aren't, originals you can clean up, multi-disc games with a disc missing, identical copies, games kept in several versions, and ones without a playlist. Nothing is changed until you click an action.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if !m.message.isEmpty { Text(m.message).font(.callout) }
            HStack {
                Spacer()
                Button("Back to Converterator") { openWindow(id: "main"); dismissWindow(id: "library") }
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 520)
    }

    private func report(_ r: LibraryReport) -> some View {
        List {
            Section {
                row("CHDs", "\(r.chds.count) · \(formatBytes(r.chdBytes))")
                if !redump.index.isEmpty {
                    row("Named as in Redump", "\(r.redumpNamed) of \(r.chds.count)")
                }
                if !r.chds.isEmpty {
                    HStack {
                        Button("Sort into System Folders…") { m.sortIntoSystemFolders() }
                            .help("Moves the CHDs and RVZs here into a folder per system (PlayStation, Saturn…), with their playlists, and can rename them to their Redump names. You see what will happen first.")
                        if m.hasLastSort {
                            Button("Undo Last Sort…") { m.undoLastSort() }
                                .help("Puts the files the last Sort into System Folders moved back where they were, with their old names.")
                        }
                        Button("Add to RetroArch Playlists") { m.addToRetroArch() }
                            .help("Adds every game here to RetroArch's playlist for its system.")
                        Spacer()
                    }
                    .disabled(c.isRunning)
                }
            } header: { Text("Summary") }

            Section {
                if r.unconverted.isEmpty { Text("Everything here is converted.").foregroundStyle(.secondary) }
                ForEach(r.unconverted.prefix(200), id: \.self) { fileRow($0, detail: formatBytes(totalSize(Converter.sourceFiles(for: $0)))) }
                more(r.unconverted.count)
            } header: {
                header("Not converted yet: \(r.unconverted.count)", r.unconverted.isEmpty ? nil : formatBytes(r.unconvertedBytes),
                       action: r.unconverted.isEmpty || c.isRunning ? nil : ("Add All to Converter", {
                    c.add(r.unconverted); openWindow(id: "main")
                }))
            }

            Section {
                if r.leftovers.isEmpty { Text("No leftover originals.").foregroundStyle(.secondary) }
                ForEach(r.leftovers.prefix(200)) { item in
                    fileRow(item.source, detail: "\(formatBytes(item.bytes)) · has \(item.chds.count == 1 ? item.chds[0].lastPathComponent : "\(item.chds.count) CHDs")")
                }
                more(r.leftovers.count)
            } header: {
                header("Originals that already have CHDs: \(r.leftovers.count)", r.leftovers.isEmpty ? nil : formatBytes(r.leftoverBytes),
                       action: r.leftovers.isEmpty ? nil : ("Clean Up…", {
                    if let f = m.folder { Cleanup.shared.scan(f) }
                    openWindow(id: "cleanup")
                }))
            }

            Section {
                if r.missingDiscs.isEmpty { Text("No multi-disc games with a disc missing.").foregroundStyle(.secondary) }
                ForEach(r.missingDiscs) { set in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(set.name).lineLimit(1).truncationMode(.middle)
                        Text("Has disc \(set.have.map(String.init).joined(separator: ", ")); missing \(set.missing.map(String.init).joined(separator: ", "))\(set.fromRedump ? " (Redump lists \(set.expected))" : "") · \(set.dir.lastPathComponent)")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    .contextMenu { Button("Show in Finder") { NSWorkspace.shared.open(set.dir) } }
                }
            } header: { header("Multi-disc games with a disc missing: \(r.missingDiscs.count)", nil, action: nil) }

            Section {
                if r.identical.isEmpty { Text("No identical copies.").foregroundStyle(.secondary) }
                ForEach(r.identical.prefix(200)) { g in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(g.why.prefix(1).uppercased() + g.why.dropFirst() + " · could free \(formatBytes(g.extraBytes))")
                            .font(.caption).foregroundStyle(.orange)
                        ForEach(g.files, id: \.self) { f in
                            fileRow(f, detail: formatBytes(totalSize([f])))
                        }
                    }
                }
                more(r.identical.count)
            } header: {
                header("Identical copies: \(r.identical.count)", r.identical.isEmpty ? nil : "could free \(formatBytes(r.identicalBytes))",
                       action: r.identical.isEmpty ? nil : ("Move Extra Copies to Trash…", { m.moveExtraCopiesToTrash() }))
            }

            Section {
                if r.versions.isEmpty { Text("No game is here in more than one version.").foregroundStyle(.secondary) }
                ForEach(r.versions.prefix(200)) { v in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(v.title).fontWeight(.medium)
                        ForEach(v.files, id: \.self) { f in
                            fileRow(f, detail: formatBytes(totalSize(Converter.sourceFiles(for: f))))
                        }
                    }
                }
                more(r.versions.count)
            } header: {
                header("Games in several versions: \(r.versions.count)", nil, action: nil)
            }

            Section {
                if !r.patchesFolderOn {
                    Text("Choose a patches folder in Settings to see which of your games have a patch waiting.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if r.patchOffers.isEmpty {
                    Text("No patches in your patches folder for games here (or their patched CHDs already exist).").foregroundStyle(.secondary)
                }
                ForEach(r.patchOffers) { offer in
                    fileRow(offer.game, title: offer.name + ".chd",
                            detail: "from \(offer.game.lastPathComponent) with \(offer.patch.member.map { "\(offer.patch.url.lastPathComponent) → \(($0 as NSString).lastPathComponent)" } ?? offer.patch.name)")
                }
            } header: {
                header("Patches available: \(r.patchOffers.count)", nil, action: r.patchOffers.isEmpty || c.isRunning ? nil : ("Convert Patched Versions", {
                    for offer in r.patchOffers {
                        c.add([offer.game])
                        if let job = c.jobs.last(where: { $0.url.standardizedFileURL == offer.game.standardizedFileURL }) {
                            c.setPatch(offer.patch.url, member: offer.patch.member, for: job.id)
                        }
                    }
                    openWindow(id: "main")
                }))
            }

            Section {
                if r.needsPlaylist.isEmpty { Text("Every multi-disc game has a playlist.").foregroundStyle(.secondary) }
                ForEach(r.needsPlaylist) { set in
                    fileRow(set.discs[0], title: set.name + ".m3u",
                            detail: "\(set.discs.count) discs · \(set.dir.lastPathComponent)")
                }
            } header: {
                header("Multi-disc games without a playlist: \(r.needsPlaylist.count)", nil,
                       action: r.needsPlaylist.isEmpty ? nil : ("Make Playlists", { m.makePlaylists() }))
            }

            Section {
                if redump.index.isEmpty {
                    Text("Load Redump DATs in Settings to check your CHDs.").font(.caption).foregroundStyle(.secondary)
                } else {
                    row("Match Redump", "\(r.redumpMatched)")
                    row("Don't match", "\(r.redumpNotMatching.count)")
                    row("Not checked yet (or changed since)", "\(r.redumpUnchecked.count)")
                    ForEach(r.redumpNotMatching.prefix(200), id: \.self) { fileRow($0, detail: "partial or no match") }
                    more(r.redumpNotMatching.count)
                }
            } header: {
                header("Redump", nil, action: r.redumpUnchecked.isEmpty || redump.index.isEmpty ? nil : ("Check \(r.redumpUnchecked.count) Unchecked…", {
                    CHDCheck.shared.add(r.redumpUnchecked); openWindow(id: "chdcheck")
                }))
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary).monospacedDigit() }
    }

    private func header(_ title: String, _ size: String?, action: (String, () -> Void)?) -> some View {
        HStack {
            Text(title)
            if let size { Text(size).foregroundStyle(.secondary) }
            Spacer()
            if let action { Button(action.0, action: action.1).textCase(nil) }
        }
    }

    private func fileRow(_ url: URL, title: String? = nil, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title ?? url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Text(detail + " · " + url.deletingLastPathComponent().lastPathComponent).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .contextMenu { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    }

    @ViewBuilder private func more(_ count: Int) -> some View {
        if count > 200 { Text("…and \(count - 200) more").font(.caption).foregroundStyle(.secondary) }
    }

    /// Saves the report as CSV (for Numbers or Excel) or plain text.
    private func export(_ r: LibraryReport, csv: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .plainText]
        panel.nameFieldStringValue = "Library Report – \(m.folder?.lastPathComponent ?? "Games").\(csv ? "csv" : "txt")"
        panel.canCreateDirectories = true
        let done: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try (csv ? r.csv() : r.text(folder: m.folder)).write(to: url, atomically: true, encoding: .utf8); m.message = "Saved \(url.lastPathComponent)." }
            catch { m.message = "Couldn't save the report: \(error.localizedDescription)" }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Scan"
        panel.message = "Choose a folder of games to report on (subfolders are included)"
        let done: (NSApplication.ModalResponse) -> Void = { if $0 == .OK, let url = panel.url { m.scan(url) } }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }
}
