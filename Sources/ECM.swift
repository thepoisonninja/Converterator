import Foundation

/// ECM ("Error Code Modeler", by Neill Corlett) files: CD images (`Game.bin.ecm`) with each sector's
/// error-correction data left out, because it can be computed again. Decoding computes it, giving back
/// the original `.bin` byte for byte, which is checked against the checksum stored at the end of the file.
enum ECM {
    struct DecodeError: Error { let message: String }

    /// Whether the file starts with ECM's signature ("ECM" and a zero byte).
    nonisolated static func isECM(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: 4)) == Data([0x45, 0x43, 0x4D, 0x00])
    }

    /// The file it decodes to: "Game.bin.ecm" → "Game.bin" (one without an inner extension gets ".bin").
    nonisolated static func decodedName(_ url: URL) -> String {
        let inner = url.deletingPathExtension().lastPathComponent
        return (inner as NSString).pathExtension.isEmpty ? inner + ".bin" : inner
    }

    /// The game's name: "Game.bin.ecm" → "Game".
    nonisolated static func gameName(_ url: URL) -> String {
        (decodedName(url) as NSString).deletingPathExtension
    }

    // MARK: Decoding

    private struct Tables {
        var eccF = [UInt8](repeating: 0, count: 256)
        var eccB = [UInt8](repeating: 0, count: 256)
        var edc = [UInt32](repeating: 0, count: 256)
        init() {
            for i in 0..<256 {
                let j = ((i << 1) ^ ((i & 0x80) != 0 ? 0x11D : 0)) & 0xFF
                eccF[i] = UInt8(j)
                eccB[i ^ j] = UInt8(i)
                var e = UInt32(i)
                for _ in 0..<8 { e = (e >> 1) ^ ((e & 1) != 0 ? 0xD801_8001 : 0) }
                edc[i] = e
            }
        }
    }
    nonisolated private static let tables = Tables()

    /// Decodes `src` into `dst`. `progress` gets 0…1; returning true from `cancelled` stops it.
    nonisolated static func decode(_ src: URL, to dst: URL, progress: (Double) -> Void = { _ in },
                                   cancelled: () -> Bool = { false }) throws {
        guard let input = try? FileHandle(forReadingFrom: src) else { throw DecodeError(message: "Can't read \(src.lastPathComponent)") }
        defer { try? input.close() }
        let total = Double((try? input.seekToEnd()) ?? 0)
        try? input.seek(toOffset: 0)
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: dst) else { throw DecodeError(message: "Can't write \(dst.lastPathComponent)") }
        defer { try? output.close() }

        let t = tables
        // Buffered reading and writing: images are hundreds of MB.
        var inBuf = [UInt8](), inPos = 0, consumed = 0.0
        func refill() throws -> Bool {
            let d = (try? input.read(upToCount: 1 << 20)) ?? nil
            guard let d, !d.isEmpty else { return false }
            consumed += Double(inPos)
            inBuf = [UInt8](d); inPos = 0
            return true
        }
        func readByte() throws -> UInt8 {
            if inPos == inBuf.count, !(try refill()) { throw DecodeError(message: "The ECM file ends too early: it's incomplete or damaged") }
            defer { inPos += 1 }
            return inBuf[inPos]
        }
        func read(_ n: Int, into s: inout [UInt8], at offset: Int) throws {
            var done = 0
            while done < n {
                if inPos == inBuf.count, !(try refill()) { throw DecodeError(message: "The ECM file ends too early: it's incomplete or damaged") }
                let k = min(n - done, inBuf.count - inPos)
                for i in 0..<k { s[offset + done + i] = inBuf[inPos + i] }
                inPos += k; done += k
            }
        }
        var outBuf = [UInt8](); outBuf.reserveCapacity(4 << 20)
        func flush() throws {
            guard !outBuf.isEmpty else { return }
            do { try output.write(contentsOf: Data(outBuf)) }
            catch { throw DecodeError(message: "Can't write \(dst.lastPathComponent): \(error.localizedDescription)") }
            outBuf.removeAll(keepingCapacity: true)
        }

        func edc(_ crc: UInt32, _ s: [UInt8], _ from: Int, _ count: Int) -> UInt32 {
            var e = crc
            for i in from..<(from + count) { e = (e >> 8) ^ t.edc[Int((e ^ UInt32(s[i])) & 0xFF)] }
            return e
        }
        func putLE(_ v: UInt32, _ s: inout [UInt8], _ at: Int) {
            s[at] = UInt8(v & 0xFF); s[at + 1] = UInt8((v >> 8) & 0xFF)
            s[at + 2] = UInt8((v >> 16) & 0xFF); s[at + 3] = UInt8(v >> 24)
        }
        // Reed-Solomon product code (ECMA-130 annex A): P parity, then Q parity, over the sector from byte 12.
        func eccBlock(_ s: inout [UInt8], majorCount: Int, minorCount: Int, majorMult: Int, minorInc: Int, dest: Int) {
            let size = majorCount * minorCount
            for major in 0..<majorCount {
                var index = (major >> 1) * majorMult + (major & 1)
                var a: UInt8 = 0, b: UInt8 = 0
                for _ in 0..<minorCount {
                    let v = s[0xC + index]
                    index += minorInc
                    if index >= size { index -= size }
                    a ^= v; b ^= v
                    a = t.eccF[Int(a)]
                }
                a = t.eccB[Int(t.eccF[Int(a)] ^ b)]
                s[dest + major] = a
                s[dest + major + majorCount] = a ^ b
            }
        }
        func ecc(_ s: inout [UInt8], zeroAddress: Bool) {
            let saved = Array(s[12..<16])
            if zeroAddress { for i in 12..<16 { s[i] = 0 } }
            eccBlock(&s, majorCount: 86, minorCount: 24, majorMult: 2, minorInc: 86, dest: 0x81C)
            eccBlock(&s, majorCount: 52, minorCount: 43, majorMult: 86, minorInc: 88, dest: 0x8C8)
            if zeroAddress { for i in 0..<4 { s[12 + i] = saved[i] } }
        }

        // Signature
        var magic = [UInt8](repeating: 0, count: 4)
        try read(4, into: &magic, at: 0)
        guard magic == [0x45, 0x43, 0x4D, 0x00] else { throw DecodeError(message: "\(src.lastPathComponent) isn't an ECM file") }

        var checksum: UInt32 = 0
        var s = [UInt8](repeating: 0, count: 2352)
        var lastReport = 0.0
        while true {
            // A run: its kind (0 = bytes as they are, 1 = Mode 1 sectors, 2/3 = Mode 2 Form 1/2 sectors)
            // and its length, in 7-bit groups.
            var c = try readByte()
            let kind = Int(c & 3)
            var num = UInt64((c >> 2) & 0x1F), bits: UInt64 = 5
            while c & 0x80 != 0 {
                c = try readByte()
                guard bits <= 33 else { throw DecodeError(message: "The ECM file is damaged") }
                num |= UInt64(c & 0x7F) << bits
                bits += 7
            }
            if num == 0xFFFF_FFFF { break }   // end of the image
            num += 1
            guard num < 0x8000_0000 else { throw DecodeError(message: "The ECM file is damaged") }

            if kind == 0 {
                var left = Int(num)
                while left > 0 {
                    let n = min(left, 2352)
                    try read(n, into: &s, at: 0)
                    checksum = edc(checksum, s, 0, n)
                    outBuf.append(contentsOf: s[0..<n])
                    left -= n
                }
            } else {
                for _ in 0..<num {
                    for i in 0..<2352 { s[i] = 0 }
                    for i in 1...10 { s[i] = 0xFF }   // sync pattern
                    switch kind {
                    case 1:   // Mode 1: address and 2048 bytes of data stored; EDC, zero gap and ECC computed
                        s[0x0F] = 1
                        try read(3, into: &s, at: 0x0C)
                        try read(0x800, into: &s, at: 0x10)
                        putLE(edc(0, s, 0, 0x810), &s, 0x810)
                        ecc(&s, zeroAddress: false)
                        checksum = edc(checksum, s, 0, 2352)
                        outBuf.append(contentsOf: s[0..<2352])
                    default:  // Mode 2 Form 1 (2) / Form 2 (3): the 2336 bytes after the header
                        s[0x0F] = 2
                        try read(kind == 2 ? 0x804 : 0x918, into: &s, at: 0x14)
                        for i in 0..<4 { s[0x10 + i] = s[0x14 + i] }   // the subheader is stored twice
                        if kind == 2 {
                            putLE(edc(0, s, 0x10, 0x808), &s, 0x818)
                            ecc(&s, zeroAddress: true)
                        } else {
                            putLE(edc(0, s, 0x10, 0x91C), &s, 0x92C)
                        }
                        checksum = edc(checksum, s, 0x10, 2336)
                        outBuf.append(contentsOf: s[0x10..<2352])
                    }
                    if outBuf.count >= 4 << 20 { try flush() }
                }
            }
            if outBuf.count >= 4 << 20 { try flush() }
            let done = consumed + Double(inPos)
            if total > 0, done - lastReport > 8_388_608 {
                lastReport = done
                progress(min(done / total, 1))
                if cancelled() { throw DecodeError(message: "Cancelled") }
            }
        }
        try flush()
        var stored = [UInt8](repeating: 0, count: 4)
        try read(4, into: &stored, at: 0)
        let expected = UInt32(stored[0]) | UInt32(stored[1]) << 8 | UInt32(stored[2]) << 16 | UInt32(stored[3]) << 24
        guard expected == checksum else {
            throw DecodeError(message: "The decoded image doesn't match the checksum stored in the ECM file: the file is damaged")
        }
        progress(1)
    }

    // MARK: Finding the .cue

    /// The .cue or .gdi next to `ecm` that lists its decoded file (e.g. Game.cue listing "Game.bin"), if any.
    nonisolated static func sheet(for ecm: URL) -> URL? {
        let dir = ecm.deletingLastPathComponent(), fm = FileManager.default
        let decoded = decodedName(ecm)
        func lists(_ c: URL) -> Bool {
            fm.fileExists(atPath: c.path) && Converter.trackNames(in: c).contains { ($0 as NSString).lastPathComponent == decoded }
        }
        // The usual case first: the same name (Game.cue for Game.bin.ecm). Otherwise any sheet beside it.
        let base = (decoded as NSString).deletingPathExtension
        for ext in ["cue", "gdi"] where lists(dir.appendingPathComponent(base + "." + ext)) {
            return dir.appendingPathComponent(base + "." + ext)
        }
        return ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["cue", "gdi"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first(where: lists)
    }

    /// A .cue sheet for a lone decoded .bin (one data track), from the mode its first sector shows.
    /// Nil if it doesn't look like a raw CD image.
    nonisolated static func cueSheet(for bin: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: bin) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 16), head.count == 16,
              Array(head[0..<12]) == [0x00] + [UInt8](repeating: 0xFF, count: 10) + [0x00],
              [1, 2].contains(head[15]) else { return nil }
        let size = (try? h.seekToEnd()) ?? 0
        guard size % 2352 == 0 else { return nil }
        return "FILE \"\(bin.lastPathComponent)\" BINARY\n  TRACK 01 MODE\(head[15])/2352\n    INDEX 01 00:00:00\n"
    }
}

// MARK: - Converting ECM-compressed games

extension Converter {
    /// Tracks of a .cue/.gdi that are only there ECM-compressed (Game.bin missing, Game.bin.ecm next to it).
    nonisolated static func ecmTracks(for sheet: URL) -> [String] {
        guard ["cue", "gdi"].contains(sheet.pathExtension.lowercased()) else { return [] }
        let dir = sheet.deletingLastPathComponent(), fm = FileManager.default
        var seen = Set<String>()
        return trackNames(in: sheet).filter {
            seen.insert($0).inserted
                && !fm.fileExists(atPath: dir.appendingPathComponent($0).path)
                && fm.fileExists(atPath: dir.appendingPathComponent($0 + ".ecm").path)
        }
    }

    /// Whether a game has to be expanded from ECM before chdman or PSXPackager can read it.
    nonisolated static func needsECM(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "ecm" || !ecmTracks(for: url).isEmpty
    }

    /// The game with its ECM files expanded into `dir`: a copy of its .cue/.gdi, with the expanded tracks
    /// and links to the others; or, for a lone Game.bin.ecm, Game.bin with a .cue made for it.
    func expandECM(_ game: URL, into dir: URL, id: UUID) async -> Result<URL, CHDCheck.CheckError> {
        let fm = FileManager.default
        func failure(_ m: String) -> Result<URL, CHDCheck.CheckError> { .failure(.init(message: m)) }
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { return failure("Can't create temporary folder: \(error.localizedDescription)") }

        let sheet = game.pathExtension.lowercased() == "ecm" ? (ECM.sheet(for: game) ?? game) : game
        var work: [(ecm: URL, out: URL)] = []
        var result: URL
        let lone = sheet.pathExtension.lowercased() == "ecm"
        if lone {
            result = dir.appendingPathComponent(ECM.decodedName(sheet))
            work = [(sheet, result)]
        } else {
            let srcDir = sheet.deletingLastPathComponent()
            let packed = Set(Converter.ecmTracks(for: sheet))
            result = dir.appendingPathComponent(sheet.lastPathComponent)
            do {
                try fm.copyItem(at: sheet, to: result)
                // (Its LibCrypt .sbi too, so it ends up next to the CHD.)
                if let sbi = Converter.sbiFile(for: sheet) {
                    try fm.createSymbolicLink(at: dir.appendingPathComponent(sbi.lastPathComponent), withDestinationURL: sbi.resolvingSymlinksInPath())
                }
                var seen = Set<String>()
                for name in Converter.trackNames(in: sheet) where seen.insert(name).inserted {
                    let out = dir.appendingPathComponent(name)
                    guard out.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path + "/") else { continue }
                    try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if packed.contains(name) {
                        work.append((srcDir.appendingPathComponent(name + ".ecm"), out))
                    } else if fm.fileExists(atPath: srcDir.appendingPathComponent(name).path) {
                        try fm.createSymbolicLink(at: out, withDestinationURL: srcDir.appendingPathComponent(name).resolvingSymlinksInPath())
                    }
                }
            } catch { return failure("Can't prepare the tracks: \(error.localizedDescription)") }
        }

        final class Stop: @unchecked Sendable {
            let lock = NSLock(); var value = false
            func set() { lock.lock(); value = true; lock.unlock() }
            var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        }
        let stop = Stop()
        for (k, w) in work.enumerated() {
            let label = work.count > 1 ? "Expanding \(w.ecm.lastPathComponent) (\(k + 1) of \(work.count))" : "Expanding \(w.ecm.lastPathComponent)"
            update(id) { $0.detail = label + "…"; $0.progress = 0 }
            let ecm = w.ecm, out = w.out
            let err: String? = await Task.detached {
                do {
                    try ECM.decode(ecm, to: out, progress: { p in
                        Task { @MainActor in
                            if self.cancelRequested { stop.set() }
                            self.update(id) { $0.progress = p; $0.detail = "\(label) — \(Int(p * 100))%" }
                        }
                    }, cancelled: { stop.isSet })
                    return nil
                } catch let e as ECM.DecodeError {
                    return e.message
                } catch {
                    return error.localizedDescription
                }
            }.value
            if cancelRequested { return failure("Cancelled") }
            if let err { return failure("\(ecm.lastPathComponent): \(err)") }
        }
        append("  expanded \(work.map(\.ecm.lastPathComponent).joined(separator: ", "))")

        // A lone .bin needs a .cue for chdman (an .iso doesn't).
        if lone && result.pathExtension.lowercased() != "iso" {
            guard let text = ECM.cueSheet(for: result) else {
                return failure("Can't tell how this disc's tracks are laid out. Put its .cue file next to \(sheet.lastPathComponent) and add the .cue.")
            }
            let cue = result.deletingPathExtension().appendingPathExtension("cue")
            do { try text.write(to: cue, atomically: true, encoding: .utf8) }
            catch { return failure("Can't write a .cue: \(error.localizedDescription)") }
            append("  no .cue with it, so made one for a single \(text.contains("MODE1") ? "Mode 1" : "Mode 2") data track")
            result = cue
        }
        return .success(result)
    }
}
