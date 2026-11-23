// The consoles Converterator can tell apart: for sorting games into a folder per system and for RetroArch
// playlists. A game's system comes from its Redump match when there is one, otherwise from the disc itself.
import Foundation

struct GameSystem: Hashable, Sendable {
    let id: String          // redump.org's name for it ("psx")
    let folder: String      // readable folder name ("PlayStation")
    let esde: String        // ES-DE / Batocera / RetroBat folder name ("psx")
    let retroArch: String   // RetroArch's database and playlist name ("Sony - PlayStation")
    var aliases: [String] = []
}

enum Systems {
    nonisolated static let all: [GameSystem] = [
        GameSystem(id: "psx", folder: "PlayStation", esde: "psx", retroArch: "Sony - PlayStation", aliases: ["ps1", "playstation 1", "psone"]),
        GameSystem(id: "ps2", folder: "PlayStation 2", esde: "ps2", retroArch: "Sony - PlayStation 2"),
        GameSystem(id: "psp", folder: "PSP", esde: "psp", retroArch: "Sony - PlayStation Portable", aliases: ["playstation portable"]),
        GameSystem(id: "ss", folder: "Saturn", esde: "saturn", retroArch: "Sega - Saturn", aliases: ["sega saturn"]),
        GameSystem(id: "mcd", folder: "Sega CD", esde: "segacd", retroArch: "Sega - Mega-CD - Sega CD", aliases: ["megacd", "mega cd", "mega-cd"]),
        GameSystem(id: "dc", folder: "Dreamcast", esde: "dreamcast", retroArch: "Sega - Dreamcast", aliases: ["sega dreamcast"]),
        GameSystem(id: "pce", folder: "PC Engine CD", esde: "pcenginecd", retroArch: "NEC - PC Engine CD - TurboGrafx-CD",
                   aliases: ["turbografx cd", "turbografx-cd", "tgcd", "pcecd"]),
        GameSystem(id: "pc-fx", folder: "PC-FX", esde: "pcfx", retroArch: "NEC - PC-FX"),
        GameSystem(id: "ngcd", folder: "Neo Geo CD", esde: "neogeocd", retroArch: "SNK - Neo Geo CD"),
        GameSystem(id: "3do", folder: "3DO", esde: "3do", retroArch: "The 3DO Company - 3DO"),
        GameSystem(id: "cdi", folder: "CD-i", esde: "cdimono1", retroArch: "Philips - CD-i"),
        GameSystem(id: "cd32", folder: "Amiga CD32", esde: "amigacd32", retroArch: "Commodore - CD32"),
        GameSystem(id: "ajcd", folder: "Jaguar CD", esde: "atarijaguarcd", retroArch: "Atari - Jaguar CD"),
        GameSystem(id: "gc", folder: "GameCube", esde: "gc", retroArch: "Nintendo - GameCube", aliases: ["ngc", "gamecube"]),
        GameSystem(id: "wii", folder: "Wii", esde: "wii", retroArch: "Nintendo - Wii"),
        GameSystem(id: "xbox", folder: "Xbox", esde: "xbox", retroArch: "Microsoft - Xbox"),
    ]

    nonisolated static func byID(_ id: String) -> GameSystem? { all.first { $0.id == id } }

    /// The system a folder is named for ("PlayStation", "psx", "PS1", "Sony - PlayStation"…), if any.
    nonisolated static func fromFolderName(_ name: String) -> GameSystem? {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        return all.first { s in
            ([s.id, s.folder, s.esde, s.retroArch] + s.aliases).contains { $0.lowercased() == n }
        }
    }

    /// Folder names a system's games may be sorted into (both styles), for finding outputs again.
    nonisolated static var folderNames: [String] { Array(Set(all.flatMap { [$0.folder, $0.esde] })).sorted() }

    // MARK: Telling from the disc

    /// The system a disc image (.cue/.bin, .gdi, .iso, .pbp, GameCube/Wii formats) is for, from its contents.
    nonisolated static func detect(_ url: URL) -> GameSystem? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "gdi": return byID("dc")
        case "pbp": return byID("psx")
        case "wbfs": return byID("wii")
        case "rvz", "wia": return rvzSystem(url)
        case "gcm": return byID("gc")
        case "iso":
            if Converter.isNintendoDisc(url) { return byID(Converter.nintendoSystem(url) == "Wii" ? "wii" : "gc") }
            if isXbox(url) { return byID("xbox") }
            return detect(reader: SectorReader(file: url, sectorSize: 2048, dataOffset: 0))
        case "ciso":
            // A CISO's disc header starts at 0x8000.
            guard let b = read(url, at: 0x8000, 0x20), b.count == 0x20 else { return nil }
            if be32(b, 0x18) == 0x5D1C9EA3 { return byID("wii") }
            if be32(b, 0x1C) == 0xC2339F3D { return byID("gc") }
            return nil
        case "cue":
            guard let track = firstDataTrack(url) else { return nil }
            return detect(reader: track)
        default: return nil
        }
    }

    /// An RVZ or WIA file's disc type, from its second header (1 = GameCube, 2 = Wii).
    nonisolated static func rvzSystem(_ url: URL) -> GameSystem? {
        guard let b = read(url, at: 0, 0x4C), b.count == 0x4C,
              b[0..<4] == [0x52, 0x56, 0x5A, 0x01] || b[0..<4] == [0x57, 0x49, 0x41, 0x01] else { return nil }
        switch be32(b, 0x48) { case 1: return byID("gc"); case 2: return byID("wii"); default: return nil }
    }

    /// Reads 2048-byte user-data sectors from a disc image track (plain ISO, or raw 2352-byte sectors).
    struct SectorReader: Sendable {
        let file: URL
        let sectorSize: Int       // 2048 or 2352
        let dataOffset: Int       // where the 2048 bytes start in each sector: 0, 16 (Mode 1) or 24 (Mode 2)
        func sector(_ n: Int) -> [UInt8]? {
            Systems.read(file, at: UInt64(n * sectorSize + dataOffset), 2048).flatMap { $0.count == 2048 ? $0 : nil }
        }
    }

    /// The first data track a .cue lists, and how to read it.
    nonisolated static func firstDataTrack(_ cue: URL) -> SectorReader? {
        guard let data = try? Data(contentsOf: cue) else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var file: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let upper = line.uppercased()
            if upper.hasPrefix("FILE "), let q1 = line.firstIndex(of: "\""), let q2 = line.lastIndex(of: "\""), q1 < q2 {
                file = String(line[line.index(after: q1)..<q2])
            } else if upper.hasPrefix("TRACK "), let file, !upper.contains("AUDIO") {
                let url = cue.deletingLastPathComponent().appendingPathComponent(file)
                if upper.contains("MODE1/2048") { return SectorReader(file: url, sectorSize: 2048, dataOffset: 0) }
                if upper.contains("MODE1/2352") { return SectorReader(file: url, sectorSize: 2352, dataOffset: 16) }
                if upper.contains("MODE2/2352") { return SectorReader(file: url, sectorSize: 2352, dataOffset: 24) }
                if upper.contains("MODE2/2336") { return SectorReader(file: url, sectorSize: 2336, dataOffset: 8) }
            }
        }
        return nil
    }

    /// The system, from what's at the start of a data track and in its ISO 9660 file system.
    nonisolated static func detect(reader r: SectorReader) -> GameSystem? {
        guard let s0 = r.sector(0) else { return nil }
        let head = String(decoding: s0.prefix(16), as: UTF8.self)
        if head.hasPrefix("SEGA SEGASATURN") { return byID("ss") }
        if head.hasPrefix("SEGADISCSYSTEM") || head.hasPrefix("SEGABOOTDISC") { return byID("mcd") }
        if head.hasPrefix("SEGA SEGAKATANA") { return byID("dc") }
        if head.hasPrefix("PC-FX:Hu_CD-ROM") { return byID("pc-fx") }
        if s0[0] == 0x01, s0[1...5].allSatisfy({ $0 == 0x5A }), s0[6] == 0x01 { return byID("3do") }
        // PC Engine CD: the boot sector says so near the start of the data track.
        for n in 0..<4 {
            if let s = r.sector(n), String(decoding: s.prefix(0x60), as: UTF8.self).contains("PC Engine CD-ROM") { return byID("pce") }
        }
        guard let pvd = r.sector(16) else { return nil }
        if pvd[0] == 1, Array(pvd[1...5]) == Array("CD-I ".utf8) { return byID("cdi") }
        guard pvd[0] == 1, Array(pvd[1...5]) == Array("CD001".utf8) else { return nil }
        let systemID = String(decoding: pvd[8..<40], as: UTF8.self).trimmingCharacters(in: .whitespaces).uppercased()
        let root = isoRoot(r, pvd: pvd)
        if root.keys.contains("PSP_GAME") || root.keys.contains("UMD_DATA.BIN") { return byID("psp") }
        if let cnf = root["SYSTEM.CNF"], let s = r.sector(cnf.lba) {
            let text = String(decoding: s.prefix(min(cnf.size, 2048)), as: UTF8.self).uppercased()
            if text.contains("BOOT2") { return byID("ps2") }
            if text.contains("BOOT") { return byID("psx") }
        }
        if systemID.hasPrefix("PLAYSTATION") { return byID("psx") }
        if root.keys.contains("IPL.TXT") { return byID("ngcd") }
        if root.keys.contains("CD32.TM") { return byID("cd32") }
        return nil
    }

    /// Names in an ISO 9660 root directory (upper-cased, without ";1"), with each one's sector and size.
    nonisolated static func isoRoot(_ r: SectorReader, pvd: [UInt8]) -> [String: (lba: Int, size: Int)] {
        func le32(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
        let rootLBA = le32(pvd, 156 + 2), rootSize = min(le32(pvd, 156 + 10), 16 * 2048)
        var dir: [UInt8] = []
        for n in 0..<max(1, (rootSize + 2047) / 2048) {
            guard let s = r.sector(rootLBA + n) else { break }
            dir += s
        }
        var result: [String: (lba: Int, size: Int)] = [:]
        var i = 0
        while i < dir.count {
            let len = Int(dir[i])
            if len == 0 { i = (i / 2048 + 1) * 2048; continue }
            guard i + len <= dir.count, len >= 34 else { break }
            let nameLen = Int(dir[i + 32])
            if nameLen > 0, i + 33 + nameLen <= dir.count {
                var name = String(decoding: dir[(i + 33)..<(i + 33 + nameLen)], as: UTF8.self).uppercased()
                if let semi = name.firstIndex(of: ";") { name = String(name[..<semi]) }
                if name.hasSuffix(".") { name.removeLast() }
                result[name] = (le32(dir, i + 2), le32(dir, i + 10))
            }
            i += len
        }
        return result
    }

    /// An original Xbox disc image (XDVDFS, at sector 32 of the game partition or of the image).
    nonisolated static func isXbox(_ url: URL) -> Bool {
        let magic = Array("MICROSOFT*XBOX*MEDIA".utf8)
        for base: UInt64 in [0, 0x18300000] {
            if let b = read(url, at: base + 0x10000, 20), b == magic { return true }
        }
        return false
    }

    nonisolated static func read(_ url: URL, at offset: UInt64, _ count: Int) -> [UInt8]? {
        guard let h = try? FileHandle(forReadingFrom: url.resolvingSymlinksInPath()) else { return nil }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: offset)) != nil, let d = try? h.read(upToCount: count) else { return nil }
        return [UInt8](d)
    }

    /// A path to compare files by, the same however the folder was spelled (/var vs /private/var), even after
    /// the file itself has moved away.
    nonisolated static func pathKey(_ u: URL) -> String {
        u.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path + "/" + u.lastPathComponent
    }

    nonisolated static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
}

// MARK: - Telling a CHD's system

extension Systems {
    /// A CHD's metadata entries (tag and text), read from the file without decompressing anything.
    nonisolated static func chdMetadata(_ url: URL) -> [(tag: String, text: String)] {
        guard let head = read(url, at: 0, 124), head.count >= 64, head.prefix(8).elementsEqual("MComprHD".utf8) else { return [] }
        func be64(_ b: [UInt8], _ i: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(b[i + $1]) } }
        let version = be32(head, 12)
        var offset: UInt64
        switch version {
        case 5: offset = be64(head, 48)
        case 4, 3: offset = be64(head, 36)
        default: return []
        }
        var entries: [(String, String)] = []
        while offset != 0, entries.count < 512, let e = read(url, at: offset, 16), e.count == 16 {
            let tag = String(decoding: e[0..<4], as: UTF8.self)
            let length = Int(be32(e, 4) & 0x00FF_FFFF)
            let data = length > 0 ? (read(url, at: offset + 16, min(length, 4096)) ?? []) : []
            entries.append((tag, String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)))
            offset = be64(e, 8)
        }
        return entries
    }

    /// The system a CHD is for: a GD-ROM is a Dreamcast game; otherwise the start of its first data track is
    /// read (chdman extracts just those few hundred KB) and looked at like a disc image.
    nonisolated static func detectCHD(_ chd: URL, chdman: URL) -> GameSystem? {
        let meta = chdMetadata(chd)
        let tags = Set(meta.map(\.tag))
        if tags.contains("CHGD") || tags.contains("CHGT") { return byID("dc") }
        let isDVD = tags.contains("DVD ")
        var start = 0, sectorSize = 2048, dataOffset = 0, frames = 1024
        if !isDVD {
            // CD: tracks one after another, each padded to a multiple of 4 frames of 2448 bytes.
            let tracks = meta.filter { ["CHT2", "CHTR"].contains($0.tag) }.map { m -> [String: String] in
                var f: [String: String] = [:]
                for part in m.text.split(separator: " ") {
                    let kv = part.split(separator: ":", maxSplits: 1)
                    if kv.count == 2 { f[String(kv[0])] = String(kv[1]) }
                }
                return f
            }.sorted { Int($0["TRACK"] ?? "") ?? 0 < Int($1["TRACK"] ?? "") ?? 0 }
            guard !tracks.isEmpty else { return nil }
            var frame = 0
            var found = false
            for t in tracks {
                let n = Int(t["FRAMES"] ?? "") ?? 0
                let type = t["TYPE"] ?? "AUDIO"
                if type != "AUDIO" {
                    // A pregap stored in the track ("V…") comes before its first sector.
                    if (t["PGTYPE"] ?? "").hasPrefix("V") { frame += Int(t["PREGAP"] ?? "") ?? 0 }
                    start = frame * 2448
                    sectorSize = 2448
                    switch type {
                    case "MODE1_RAW": dataOffset = 16
                    case "MODE2_RAW": dataOffset = 24
                    case "MODE2", "MODE2_FORM_MIX": dataOffset = 8
                    default: dataOffset = 0   // MODE1, MODE2_FORM1: just the 2048 bytes
                    }
                    found = true
                    break
                }
                frame += (n + 3) / 4 * 4
            }
            guard found else { return nil }
            frames = 600
        }
        // No more than the disc holds (chdman refuses to read past the end).
        guard let head = read(chd, at: 0, 48), head.count == 48 else { return nil }
        func be64(_ i: Int) -> Int { Int((0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(head[i + $1]) }) }
        let logical = be32(head, 12) == 5 ? be64(32) : be64(28)
        let length = min(frames * sectorSize, logical - start)
        guard length >= 17 * sectorSize else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("converterator-peek-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = chdman
        p.arguments = ["extractraw", "-i", chd.path, "-o", tmp.path, "-f",
                       "--inputstartbyte", String(start), "--inputbytes", String(length)]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let found = detect(reader: SectorReader(file: tmp, sectorSize: sectorSize, dataOffset: dataOffset))
        // A DVD can't be a PS1 game: "PLAYSTATION" on a DVD is a PS2 disc.
        if isDVD, found?.id == "psx" { return byID("ps2") }
        if isDVD, found == nil, isXbox(tmp) { return byID("xbox") }
        return found
    }
}
