// RetroArch playlists: one .lpl per system ("Sony - PlayStation.lpl"), so games show up without a scan.
import Foundation

enum RetroArch {
    /// Where RetroArch for macOS keeps its playlists.
    nonisolated static var defaultFolder: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/RetroArch/playlists", isDirectory: true)
    }

    struct Entry: Sendable, Equatable {
        let path: URL
        let label: String
    }

    /// What a converted game puts in a playlist: its .m3u for a multi-disc game (RetroArch swaps discs from
    /// it), otherwise each CHD or RVZ. Labels are the file names, which are Redump's names when renamed.
    nonisolated static func entries(made: [URL], playlist: URL?) -> [Entry] {
        if let playlist { return [Entry(path: playlist, label: playlist.deletingPathExtension().lastPathComponent)] }
        return made.map { Entry(path: $0, label: $0.deletingPathExtension().lastPathComponent) }
    }

    /// Adds these games to `<folder>/<RetroArch's name for the system>.lpl`, replacing any entry with the same
    /// path and keeping everything else in the playlist as it was. Returns the playlist file.
    @discardableResult
    nonisolated static func add(_ entries: [Entry], system: GameSystem, folder: URL, replacing: [URL] = []) throws -> URL {
        let file = folder.appendingPathComponent(system.retroArch + ".lpl")
        var root: [String: Any] = [
            "version": "1.5", "default_core_path": "", "default_core_name": "",
            "label_display_mode": 0, "right_thumbnail_mode": 0, "left_thumbnail_mode": 0, "sort_mode": 0,
        ]
        if let data = try? Data(contentsOf: file) {
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "\(file.lastPathComponent) isn't a playlist RetroArch wrote, so it was left alone"])
            }
            root = existing
        }
        var items = root["items"] as? [[String: Any]] ?? []
        // (Also taking out `replacing`: the separate discs of a game now listed through its .m3u.)
        let paths = Set((entries.map(\.path) + replacing).map(\.standardizedFileURL.path))
        items.removeAll { paths.contains(URL(fileURLWithPath: $0["path"] as? String ?? "/").standardizedFileURL.path) }
        for e in entries {
            items.append(["path": e.path.standardizedFileURL.path, "label": e.label, "core_path": "DETECT", "core_name": "DETECT",
                          "crc32": "DETECT", "db_name": system.retroArch + ".lpl"])
        }
        items.sort { ($0["label"] as? String ?? "").localizedStandardCompare($1["label"] as? String ?? "") == .orderedAscending }
        root["items"] = items
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
        return file
    }

    /// Points playlist entries at files' new places after they're moved or renamed, in every playlist in
    /// `folder`. Returns how many entries changed.
    @discardableResult
    nonisolated static func relocate(_ moves: [URL: URL], folder: URL) -> Int {
        let map = Dictionary(moves.map { (Systems.pathKey($0.key), $0.value.standardizedFileURL.path) }, uniquingKeysWith: { a, _ in a })
        var changed = 0
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "lpl" }
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  var items = root["items"] as? [[String: Any]] else { continue }
            var here = 0
            for i in items.indices {
                guard let path = items[i]["path"] as? String,
                      let new = map[Systems.pathKey(URL(fileURLWithPath: path))] else { continue }
                items[i]["path"] = new
                if items[i]["label"] as? String == URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent {
                    items[i]["label"] = URL(fileURLWithPath: new).deletingPathExtension().lastPathComponent
                }
                here += 1
            }
            guard here > 0 else { continue }
            root["items"] = items
            if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
               (try? out.write(to: file, options: .atomic)) != nil { changed += here }
        }
        return changed
    }

    /// Games in a folder (CHDs, RVZs and .m3u playlists), grouped by system, for "Add to RetroArch Playlists".
    /// A CHD listed in an .m3u next to it goes in through the .m3u. A game's system comes from its Redump
    /// match, the folder it's in ("PlayStation", "psx"…), or for an RVZ its header. Returns the games it
    /// couldn't place too.
    nonisolated static func library(_ folder: URL, index: RedumpIndex, checked: [String: RedumpCache.Entry])
        -> (bySystem: [GameSystem: [Entry]], unknown: [URL]) {
        let files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
            .allObjects as? [URL] ?? [])
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let m3us = files.filter { $0.pathExtension.lowercased() == "m3u" }
        var inPlaylist: [URL: URL] = [:]   // disc → its .m3u
        for m in m3us {
            let text = (try? String(contentsOf: m, encoding: .utf8)) ?? ""
            for line in text.components(separatedBy: .newlines) {
                let name = line.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.hasPrefix("#") else { continue }
                inPlaylist[m.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL] = m
            }
        }
        func system(of f: URL) -> GameSystem? {
            if case .match(let game) = RedumpCache.result(for: f, in: checked, datStamp: index.stamp),
               let id = index.system[game], let s = Systems.byID(id) { return s }
            var dir = f.deletingLastPathComponent()
            for _ in 0..<2 {
                if let s = Systems.fromFolderName(dir.lastPathComponent) { return s }
                dir = dir.deletingLastPathComponent()
            }
            return f.pathExtension.lowercased() == "rvz" ? Systems.rvzSystem(f) : nil
        }
        var bySystem: [GameSystem: [Entry]] = [:], unknown: [URL] = []
        var listed = Set<URL>()
        for f in files where ["chd", "rvz"].contains(f.pathExtension.lowercased()) {
            let entry: Entry
            if let m = inPlaylist[f.standardizedFileURL] {
                guard listed.insert(m).inserted else { continue }
                entry = Entry(path: m, label: m.deletingPathExtension().lastPathComponent)
            } else {
                entry = Entry(path: f, label: f.deletingPathExtension().lastPathComponent)
            }
            if let s = system(of: f) { bySystem[s, default: []].append(entry) } else { unknown.append(entry.path) }
        }
        return (bySystem, unknown)
    }
}
