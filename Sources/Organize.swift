// Library Report → Sort into System Folders…: moves the CHDs and RVZs already in a library into a folder per
// system (with their .m3u playlists), optionally renaming them to their Redump names.
import AppKit

struct OrganizePlan: Sendable {
    struct Move: Sendable {
        let from: URL
        let toDir: URL
        let system: GameSystem
        let redumpName: String?        // set when Redump knows the game under another name
    }
    var moves: [Move] = []
    var playlists: [(from: URL, toDir: URL)] = []   // .m3u files moving with their discs
    var unknown: [URL] = []                          // their system couldn't be told
    var keptTogether: [URL] = []                     // discs whose playlist couldn't move as one

    var renameable: Int { moves.filter { $0.redumpName != nil }.count }
    /// "PlayStation: 12, Saturn: 3".
    var bySystem: String {
        Dictionary(grouping: moves, by: { $0.toDir.lastPathComponent }).map { ($0.key, $0.value.count) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
            .map { "\($0.0): \($0.1)" }.joined(separator: ", ")
    }
}

enum Organize {
    /// Works out where each CHD/RVZ under `folder` goes: a folder for its system next to where it is now. Games
    /// already inside a system folder are left as they are. The system comes from the remembered Redump match,
    /// an RVZ's header, or the start of the CHD itself (read with chdman).
    nonisolated static func plan(folder: URL, style: SystemFolderStyle, index: RedumpIndex,
                                 checked: [String: RedumpCache.Entry], chdman: URL?,
                                 progress: (Int, Int) -> Void = { _, _ in }) -> OrganizePlan {
        let fm = FileManager.default
        // (Paths built from the folder as given, so they match what other records say about these files.)
        let files = ((fm.enumerator(atPath: folder.path)?.allObjects as? [String]) ?? [])
            .filter { !$0.split(separator: "/").contains { $0.hasPrefix(".") } }
            .map { folder.appendingPathComponent($0) }
            .filter { ["chd", "rvz"].contains($0.pathExtension.lowercased()) }
            .filter { f in
                // Already sorted: it (or its parent folder) is in a folder named for a system.
                let p = f.deletingLastPathComponent()
                return Systems.fromFolderName(p.lastPathComponent) == nil
                    && (p.standardizedFileURL == folder.standardizedFileURL || Systems.fromFolderName(p.deletingLastPathComponent().lastPathComponent) == nil)
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        var plan = OrganizePlan()
        for (n, f) in files.enumerated() {
            progress(n + 1, files.count)
            var system: GameSystem?
            var redumpName: String?
            if case .match(let game) = RedumpCache.result(for: f, in: checked, datStamp: index.stamp) {
                if let id = index.system[game] { system = Systems.byID(id) }
                let safe = Converter.safeFileName(game)
                if safe != f.deletingPathExtension().lastPathComponent { redumpName = safe }
            }
            if system == nil {
                system = f.pathExtension.lowercased() == "rvz" ? Systems.rvzSystem(f) : chdman.flatMap { Systems.detectCHD(f, chdman: $0) }
            }
            guard let system else { plan.unknown.append(f); continue }
            let dir = f.deletingLastPathComponent().appendingPathComponent(style == .esde ? system.esde : system.folder, isDirectory: true)
            plan.moves.append(.init(from: f, toDir: dir, system: system, redumpName: redumpName))
        }
        // A playlist moves with its discs, when all of them go to the same folder; otherwise none of them move.
        let movingFrom = Dictionary(plan.moves.map { ($0.from.standardizedFileURL, $0) }, uniquingKeysWith: { a, _ in a })
        var stay = Set<URL>()
        for dir in Set(plan.moves.map { $0.from.deletingLastPathComponent() }) {
            for (m3u, names) in Playlist.existing(in: dir) where !names.isEmpty {
                let discs = names.map { dir.appendingPathComponent($0).standardizedFileURL }
                let moving = discs.compactMap { movingFrom[$0] }
                guard !moving.isEmpty else { continue }
                if moving.count == discs.count, Set(moving.map(\.toDir)).count == 1 {
                    plan.playlists.append((m3u, moving[0].toDir))
                } else {
                    stay.formUnion(moving.map(\.from.standardizedFileURL))
                }
            }
        }
        plan.keptTogether = plan.moves.filter { stay.contains($0.from.standardizedFileURL) }.map(\.from)
        plan.moves.removeAll { stay.contains($0.from.standardizedFileURL) }
        return plan
    }

    struct Outcome { var moved = 0, renamed = 0; var skipped: [String] = []; var playlistEntries = 0 }

    /// What a sort did, saved so Undo Last Sort can put it back.
    struct Record: Codable {
        var folder: String
        var date: Date
        var moves: [[String]] = []          // [from, to], in the order they were made
        var renames: [[String]] = []        // [folder, old name, new name] for .m3u lines
        var createdFolders: [String] = []
    }
    nonisolated static var recordFile: URL { AppPaths.dataDir.appendingPathComponent("last-sort.json") }

    nonisolated static func lastSort() -> Record? {
        guard let d = try? Data(contentsOf: recordFile) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Record.self, from: d)
    }

    /// Moves (and with `rename`, renames) everything in the plan. Clean Up Originals' record, remembered
    /// Redump results, .m3u playlists and RetroArch playlists follow the files.
    @MainActor static func apply(_ plan: OrganizePlan, folder: URL, rename: Bool, retroArchFolder: URL?) -> Outcome {
        let fm = FileManager.default
        var out = Outcome()
        var moves: [URL: URL] = [:]
        var renames: [(dir: URL, from: String, to: String)] = []
        var record = Record(folder: folder.path, date: Date())
        for m in plan.moves {
            let name = rename && m.redumpName != nil ? m.redumpName! + "." + m.from.pathExtension : m.from.lastPathComponent
            let to = m.toDir.appendingPathComponent(name)
            guard !fm.fileExists(atPath: to.path) else { out.skipped.append(m.from.lastPathComponent); continue }
            do {
                if !fm.fileExists(atPath: m.toDir.path) {
                    try fm.createDirectory(at: m.toDir, withIntermediateDirectories: true)
                    record.createdFolders.append(m.toDir.path)
                }
                try fm.moveItem(at: m.from, to: to)
            } catch { out.skipped.append(m.from.lastPathComponent); continue }
            ConversionLog.renamed(m.from, to: to)
            RedumpCache.move(m.from, to: to)
            moves[m.from] = to
            record.moves.append([m.from.path, to.path])
            // Its LibCrypt .sbi goes with it, renamed to match.
            if let sbi = Converter.sbiFile(for: m.from) {
                let sbiTo = to.deletingPathExtension().appendingPathExtension("sbi")
                if !fm.fileExists(atPath: sbiTo.path), (try? fm.moveItem(at: sbi, to: sbiTo)) != nil {
                    record.moves.append([sbi.path, sbiTo.path])
                }
            }
            out.moved += 1
            if name != m.from.lastPathComponent { out.renamed += 1; renames.append((m.toDir, m.from.lastPathComponent, name)) }
        }
        for p in plan.playlists {
            // Only if its discs all made it.
            let dir = p.from.deletingLastPathComponent()
            let discs = ((try? String(contentsOf: p.from, encoding: .utf8)) ?? "").components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .map { dir.appendingPathComponent($0) }
            let movedPaths = Set(moves.keys.map(Systems.pathKey))
            guard discs.allSatisfy({ movedPaths.contains(Systems.pathKey($0)) }) else { continue }
            let to = p.toDir.appendingPathComponent(p.from.lastPathComponent)
            guard !fm.fileExists(atPath: to.path), (try? fm.moveItem(at: p.from, to: to)) != nil else { continue }
            moves[p.from] = to
            record.moves.append([p.from.path, to.path])
        }
        for r in renames {
            CHDCheck.fixPlaylists(in: r.dir, from: r.from, to: r.to)
            record.renames.append([r.dir.path, r.from, r.to])
        }
        if let retroArchFolder { out.playlistEntries = RetroArch.relocate(moves, folder: retroArchFolder) }
        if !record.moves.isEmpty {
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
            try? fm.createDirectory(at: recordFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? enc.encode(record).write(to: recordFile, options: .atomic)
        }
        return out
    }

    /// Puts everything the last sort moved back where it was (newest first), with its old names, and points
    /// the records and playlists back. Files moved or deleted since are skipped. Returns (restored, skipped).
    @MainActor static func undoLast(retroArchFolder: URL?) -> (restored: Int, skipped: Int) {
        guard let record = lastSort() else { return (0, 0) }
        let fm = FileManager.default
        var restored = 0, skipped = 0
        var back: [URL: URL] = [:]
        // .m3u lines get their old disc names back first, while the .m3u is still in the new folder.
        for r in record.renames where r.count == 3 {
            CHDCheck.fixPlaylists(in: URL(fileURLWithPath: r[0]), from: r[2], to: r[1])
        }
        for pair in record.moves.reversed() where pair.count == 2 {
            let from = URL(fileURLWithPath: pair[1]), to = URL(fileURLWithPath: pair[0])
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { skipped += 1; continue }
            do {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: from, to: to)
            } catch { skipped += 1; continue }
            ConversionLog.renamed(from, to: to)
            RedumpCache.move(from, to: to)
            back[from] = to
            restored += 1
        }
        if let retroArchFolder { RetroArch.relocate(back, folder: retroArchFolder) }
        // Folders the sort made, if they're empty again (a stray .DS_Store doesn't count).
        for dir in record.createdFolders.reversed() {
            let contents = (try? fm.contentsOfDirectory(atPath: dir)) ?? ["?"]
            if contents.allSatisfy({ $0 == ".DS_Store" }) { try? fm.removeItem(atPath: dir) }
        }
        try? fm.removeItem(at: recordFile)
        return (restored, skipped)
    }
}

extension Library {
    /// Works out the plan in the background, asks, then moves.
    func sortIntoSystemFolders() {
        guard let folder else { return }
        let c = Converter.shared
        let style = c.systemFolderStyle, index = RedumpDB.shared.index, checked = RedumpCache.all(), chdman = c.chdman
        isScanning = true
        message = ""
        Task.detached {
            let plan = Organize.plan(folder: folder, style: style, index: index, checked: checked, chdman: chdman) { n, total in
                Task { @MainActor in self.status = "Working out each game's system… \(n) of \(total)" }
            }
            await MainActor.run {
                self.isScanning = false
                self.confirmAndSort(plan)
            }
        }
    }

    private func confirmAndSort(_ plan: OrganizePlan) {
        let c = Converter.shared
        guard !plan.moves.isEmpty else {
            message = plan.unknown.isEmpty
                ? "Every game here is already in a folder per system."
                : "Couldn't tell the system of \(plan.unknown.count) game\(plan.unknown.count == 1 ? "" : "s"), so nothing was moved."
            return
        }
        let a = NSAlert()
        a.messageText = "Move \(plan.moves.count) game\(plan.moves.count == 1 ? "" : "s") into folders per system?"
        var info = "\(plan.bySystem).\n\nEach goes into a folder next to where it is now"
            + (plan.playlists.isEmpty ? "." : ", with its .m3u playlist.")
            + " Games already in a system folder are left alone."
        if !plan.unknown.isEmpty { info += "\n\n\(plan.unknown.count) stay where they are: their system couldn't be told." }
        if !plan.keptTogether.isEmpty { info += "\n\n\(plan.keptTogether.count) discs stay with a playlist that lists discs going elsewhere." }
        if c.retroArchPlaylists || FileManager.default.fileExists(atPath: c.retroArchPlaylistFolder.path) {
            info += "\n\nRetroArch playlists are updated to the new places."
        }
        a.informativeText = info
        let box = NSButton(checkboxWithTitle: "Also rename \(plan.renameable) to their Redump names", target: nil, action: nil)
        if plan.renameable > 0 { box.state = .on; a.accessoryView = box }
        a.addButton(withTitle: "Move")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let raFolder = FileManager.default.fileExists(atPath: c.retroArchPlaylistFolder.path) ? c.retroArchPlaylistFolder : nil
        let o = Organize.apply(plan, folder: folder ?? URL(fileURLWithPath: "/"), rename: plan.renameable > 0 && box.state == .on, retroArchFolder: raFolder)
        message = "Moved \(o.moved) game\(o.moved == 1 ? "" : "s") into folders per system"
            + (o.renamed > 0 ? ", renaming \(o.renamed)" : "") + "."
            + (o.playlistEntries > 0 ? " Updated \(o.playlistEntries) RetroArch playlist entr\(o.playlistEntries == 1 ? "y" : "ies")." : "")
            + (o.skipped.isEmpty ? "" : " Left \(o.skipped.count) where they were: a file with that name is already there.")
        lastSortChanged()
        rescan()
    }

    func undoLastSort() {
        guard let record = Organize.lastSort() else { return }
        let a = NSAlert()
        a.messageText = "Undo the last sort?"
        a.informativeText = "Puts back the \(record.moves.count) file\(record.moves.count == 1 ? "" : "s") moved into folders per system in \(URL(fileURLWithPath: record.folder).lastPathComponent) on \(record.date.formatted(date: .abbreviated, time: .shortened)), with their old names. Files moved or deleted since then are left alone."
        a.addButton(withTitle: "Undo Sort")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let c = Converter.shared
        let raFolder = FileManager.default.fileExists(atPath: c.retroArchPlaylistFolder.path) ? c.retroArchPlaylistFolder : nil
        let r = Organize.undoLast(retroArchFolder: raFolder)
        message = "Put back \(r.restored) file\(r.restored == 1 ? "" : "s")." + (r.skipped > 0 ? " \(r.skipped) had moved or gone since, so were left alone." : "")
        lastSortChanged()
        rescan()
    }

    /// For the Undo Last Sort button.
    func lastSortChanged() { hasLastSort = Organize.lastSort() != nil }
}
