// Converterator's tests. Built and run by tests/test.sh, which makes the sample files first.
// Arguments: <fixtures folder> <scratch folder> [--network] <repo folder>
import AppKit

var failures = 0, passes = 0
func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
    if ok { passes += 1; print("  ✓ \(what)") }
    else { failures += 1; print("  ✗ \(what)\(detail().isEmpty ? "" : " — \(detail())")") }
}
func section(_ name: String) { print("\n\(name)") }

let fm = FileManager.default
func url(_ path: String) -> URL { URL(fileURLWithPath: path) }
func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }
/// Converterator's temporary folders that exist right now.
func tempFolders() -> Set<String> {
    Set(((try? fm.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []).filter {
        ($0.hasPrefix("converterator-") && !$0.hasPrefix("converterator-tests")) || $0.hasPrefix("pbp2chd-")
    })
}
func sha1(_ u: URL) -> String? { RedumpResult.sha1Hex(of: u) { _ in } }
/// A fresh folder with copies of the given fixture files (relative paths keep their subfolders).
func workspace(_ name: String, from fixtures: URL, _ files: [String], into work: URL) -> URL {
    let dir = work.appendingPathComponent(name)
    try? fm.removeItem(at: dir)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for f in files {
        let dest = dir.appendingPathComponent((f as NSString).lastPathComponent)
        try! fm.copyItem(at: fixtures.appendingPathComponent(f), to: dest)
    }
    return dir
}
@MainActor func runBatch(_ urls: [URL]) async -> [Job] {
    let c = Converter.shared
    c.clearAll()
    c.add(urls)
    c.start()
    while c.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
    return c.jobs
}
/// The job whose file path ends with `suffix` ("convert/game.cue", or just "ps2.iso").
func job(_ jobs: [Job], _ suffix: String) -> Job? { jobs.first { $0.url.path.hasSuffix("/" + suffix) } }
@MainActor func tags(_ chd: URL) -> String {
    let p = Process(); p.executableURL = Converter.findTool("chdman"); p.arguments = ["info", "-i", chd.path]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    try? p.run(); let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit()
    return out
}

@main struct Tests {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let args = CommandLine.arguments
        let F = url(args[1]), W = url(args[2])
        let network = args.contains("--network")
        let repo = url(args.last!)
        try? fm.createDirectory(at: W, withIntermediateDirectories: true)

        let c = Converter.shared
        let db = RedumpDB.shared
        Converter.stallTimeout = 6
        db.autoDownload = false
        db.systems = []
        c.verify = false; c.overwrite = false; c.trashSources = false; c.outputDir = nil; c.makeM3U = true; c.isoMode = .automatic
        db.enabled = false; db.renameToRedump = false
        check(c.chdman != nil, "chdman found")

        // MARK: Names
        section("Disc names")
        let names: [(String, String?, Int?)] = [
            ("Game (USA) (Disc 2)", "Game (USA)", 2), ("Game (Disc 2 of 3)", "Game", 2),
            ("Armored Core - Master of Arena - Disc 2", "Armored Core - Master of Arena", 2),
            ("Final Fantasy VII CD2", "Final Fantasy VII", 2), ("Game_Disc3", "Game", 3),
            ("Discworld (USA)", nil, nil), ("Disc Station", nil, nil),
        ]
        for (n, key, disc) in names {
            let p = DiscName.parse(n)
            check(p?.key == key && p?.disc == disc, "“\(n)”", "got \(p.map { "\($0.key) / \($0.disc)" } ?? "none")")
        }
        check(Converter.safeFileName("A: B / C") == "A - B - C", "Redump names made safe for files")
        check(UpdateChecker.isNewer("1.10.0", than: "1.9.0") && !UpdateChecker.isNewer("1.9.0", than: "1.10.0")
              && UpdateChecker.isNewer("v2.0", than: "1.99.9") && !UpdateChecker.isNewer("1.9", than: "1.9.0"),
              "version comparison (1.10 is newer than 1.9)")

        // MARK: ISO type
        section("ISO: CD or DVD")
        for (n, dvd) in [("psp", true), ("ps2", true), ("ps1", false), ("plain", false), ("big", true)] {
            let (isDVD, why) = Converter.isoLooksLikeDVD(F.appendingPathComponent("\(n).iso"))
            check(isDVD == dvd, "\(n).iso → \(dvd ? "DVD" : "CD")", why)
        }

        // MARK: Converting
        section("Converting")
        c.verify = true
        let conv = workspace("convert", from: F, ["cd/game.cue", "cd/game.bin", "ps2.iso", "plain.iso"], into: W)
        // An existing damaged CHD next to a source: verify must stop chdman and fail it, keeping the file.
        let broken = workspace("broken", from: F, ["cd/game.cue", "cd/game.bin"], into: W)
        try! fm.copyItem(at: F.appendingPathComponent("chd/bad.chd"), to: broken.appendingPathComponent("game.chd"))
        // A cue whose track file is missing
        let missing = W.appendingPathComponent("missing"); try? fm.createDirectory(at: missing, withIntermediateDirectories: true)
        try! "FILE \"gone.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n".write(to: missing.appendingPathComponent("gone.cue"), atomically: true, encoding: .utf8)
        var jobs = await runBatch([conv, broken.appendingPathComponent("game.cue"), missing.appendingPathComponent("gone.cue")])
        check(job(jobs, "convert/game.cue")?.state == .done && exists(conv.appendingPathComponent("game.chd")), "CUE → CHD", job(jobs, "convert/game.cue")?.detail ?? "")
        check(job(jobs, "ps2.iso")?.state == .done && tags(conv.appendingPathComponent("ps2.chd")).contains("Tag='DVD '"), "PS2 ISO → DVD CHD")
        check(tags(conv.appendingPathComponent("ps2.chd")).contains("2,048 bytes"), "DVD CHD uses 2048-byte hunks")
        check(tags(conv.appendingPathComponent("plain.chd")).contains("Tag='CHT2'"), "plain ISO → CD CHD")
        check(job(jobs, "convert/game.cue")?.detail.contains("verified") == true, "Verify runs after writing")
        let brokenJob = jobs.first { $0.url.path.contains("/broken/") }
        check(brokenJob?.state == .failed && brokenJob?.detail.contains("stopped responding") == true, "damaged existing CHD stops the watchdog", brokenJob?.detail ?? "")
        check(exists(broken.appendingPathComponent("game.chd")), "damaged CHD that already existed is kept")
        check(job(jobs, "gone.cue")?.detail.contains("Missing track file: gone.bin") == true, "missing track file flagged", job(jobs, "gone.cue")?.detail ?? "")
        c.verify = false

        // MARK: Folder scans and archives
        section("Folder scans and archives")
        let tempBefore = tempFolders()
        let arch = workspace("archives", from: F, ["zip/one.zip", "zip/two.zip", "zip/snes.zip", "chd/game.chd"], into: W)
        c.clearAll(); c.add([arch])
        let found = Set(c.jobs.map(\.url.lastPathComponent))
        check(found == ["one.zip", "two.zip"], "folder scan picks disc zips, skips cartridge zip and .chd", "\(found.sorted())")
        try? fm.removeItem(at: arch.appendingPathComponent("game.chd"))
        jobs = await runBatch([arch.appendingPathComponent("one.zip"), arch.appendingPathComponent("two.zip")])
        check(job(jobs, "one.zip")?.state == .done && exists(arch.appendingPathComponent("game.chd")), "zip with a game in a subfolder")
        check(exists(arch.appendingPathComponent("alpha.chd")) && exists(arch.appendingPathComponent("beta.chd")), "zip with two games")
        let leftovers = tempFolders().subtracting(tempBefore)
        check(leftovers.isEmpty, "temporary files cleaned up", "\(leftovers.sorted())")

        // MARK: 7z and RAR (bundled 7-Zip)
        section("7z and RAR")
        let rw = workspace("rar", from: F, ["rar/one.rar", "rar/Split Game.part1.rar", "rar/Split Game.part2.rar",
                                            "rar/Split Game.part3.rar", "zip/seven.7z"], into: W)
        let part1 = rw.appendingPathComponent("Split Game.part1.rar")
        check(c.sevenZip?.path.contains("/vendor/7zz-") == true, "uses the bundled 7-Zip", c.sevenZip?.path ?? "none")
        c.clearAll(); c.add([rw])
        let rarFound = c.jobs.map(\.url.lastPathComponent).sorted()
        check(rarFound == ["Split Game.part1.rar", "one.rar", "seven.7z"], "folder scan: .rar, .7z, and only part 1 of a split archive", "\(rarFound)")
        c.clearAll(); c.add([rw.appendingPathComponent("Split Game.part3.rar")])
        check(c.jobs.map(\.url.lastPathComponent) == ["Split Game.part1.rar"], "a dropped later part adds part 1")
        c.clearAll(); c.add([part1, rw.appendingPathComponent("Split Game.part2.rar")])
        check(c.jobs.count == 1, "dropping every part adds the archive once", "\(c.jobs.map(\.url.lastPathComponent))")
        check(Converter.sourceFiles(for: part1).map(\.lastPathComponent)
              == ["Split Game.part1.rar", "Split Game.part2.rar", "Split Game.part3.rar"], "all three parts belong to the archive")
        let gameSize = totalSize([F.appendingPathComponent("cd/game.cue"), F.appendingPathComponent("cd/game.bin")])
        check(Converter.spaceNeeded(for: rw.appendingPathComponent("one.rar")).temp == gameSize, "unpacked size read from the .rar",
              "\(Converter.spaceNeeded(for: rw.appendingPathComponent("one.rar")).temp) vs \(gameSize)")
        let tempBeforeRar = tempFolders()
        jobs = await runBatch([rw])
        check(job(jobs, "one.rar")?.state == .done && exists(rw.appendingPathComponent("game.chd")), "RAR with a game in a subfolder", job(jobs, "one.rar")?.detail ?? "")
        check(job(jobs, "Split Game.part1.rar")?.state == .done && exists(rw.appendingPathComponent("Two.chd")), "RAR split over three parts",
              job(jobs, "Split Game.part1.rar")?.detail ?? "")
        check(job(jobs, "seven.7z")?.state == .done && exists(rw.appendingPathComponent("alpha.chd")), "7z", job(jobs, "seven.7z")?.detail ?? "")
        let rarScan = Cleanup.scanSources(in: rw, outputDir: nil, sevenZip: c.sevenZip)
        let splitItem = rarScan.converted.first { $0.source.lastPathComponent == "Split Game.part1.rar" }
        check(splitItem?.files.count == 3 && rarScan.converted.count == 3 && rarScan.unconverted.isEmpty,
              "Clean Up Originals: a split archive is one original with all its parts",
              "\(rarScan.converted.map { "\($0.source.lastPathComponent): \($0.files.count)" }) / \(rarScan.unconverted)")
        check(tempFolders().subtracting(tempBeforeRar).isEmpty, "temporary files cleaned up")

        // MARK: ECM
        section("ECM")
        let ecmBin = F.appendingPathComponent("ecm/ECM Game.bin"), ecmFile = F.appendingPathComponent("ecm/ECM Game.bin.ecm")
        check(ECM.isECM(ecmFile) && !ECM.isECM(ecmBin), "recognised by its signature")
        check(ECM.decodedName(ecmFile) == "ECM Game.bin" && ECM.gameName(ecmFile) == "ECM Game", "names: Game.bin.ecm → Game.bin → Game")
        let decoded = W.appendingPathComponent("decoded.bin")
        do {
            try ECM.decode(ecmFile, to: decoded)
            check(sha1(decoded) == sha1(ecmBin), "decodes to the original image (Mode 1, Mode 2 Form 1 and Form 2, damaged and plain sectors)")
        } catch { check(false, "decodes to the original image", "\(error)") }
        do {
            try ECM.decode(F.appendingPathComponent("ecm/damaged.bin.ecm"), to: decoded)
            check(false, "a damaged ECM file is refused")
        } catch let e as ECM.DecodeError {
            check(e.message.contains("damaged"), "a damaged ECM file is refused", e.message)
        } catch { check(false, "a damaged ECM file is refused", "\(error)") }
        let ew = workspace("ecm", from: F, ["ecm/ECM Game.cue", "ecm/ECM Game.bin.ecm"], into: W)
        let lone = workspace("ecm-lone", from: F, ["ecm/lone/Lone Game.bin.ecm"], into: W)
        let ez = workspace("ecm-zip", from: F, ["ecm/zip/zipped.zip"], into: W)
        let ecmCue = ew.appendingPathComponent("ECM Game.cue")
        check(Converter.missingTracks(for: ecmCue).isEmpty, "a track kept as .ecm isn't missing")
        check(Converter.sourceFiles(for: ecmCue).map(\.lastPathComponent) == ["ECM Game.cue", "ECM Game.bin.ecm"], "the .ecm is one of the game's files")
        check(Converter.spaceNeeded(for: ecmCue).temp > 0, "room is needed to expand it")
        c.clearAll(); c.add([ew, lone, ez])
        let ecmFound = c.jobs.map(\.url.lastPathComponent).sorted()
        check(ecmFound == ["ECM Game.cue", "Lone Game.bin.ecm", "zipped.zip"], "folder scan: the .cue (not its .ecm), a lone .ecm, a zip with ECM inside", "\(ecmFound)")
        c.clearAll(); c.add([ew.appendingPathComponent("ECM Game.bin.ecm")])
        check(c.jobs.map(\.url.lastPathComponent) == ["ECM Game.cue"], "a dropped .ecm goes through its .cue")
        let tempBeforeECM = tempFolders()
        jobs = await runBatch([ecmCue, lone.appendingPathComponent("Lone Game.bin.ecm"), ez.appendingPathComponent("zipped.zip")])
        @MainActor func discBin(_ chd: URL) async -> String? {
            let out = W.appendingPathComponent("ecm-check-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: out) }
            guard case .success(let disc) = await Converter.unpackCHD(chd, into: out, chdman: c.chdman!),
                  let bin = Converter.sourceFiles(for: disc).dropFirst().first else { return nil }
            return sha1(bin)
        }
        let original = sha1(ecmBin)
        for (j, chd, what) in [("ECM Game.cue", ew.appendingPathComponent("ECM Game.chd"), ".cue with an .ecm track"),
                               ("Lone Game.bin.ecm", lone.appendingPathComponent("Lone Game.chd"), "lone .bin.ecm (a .cue made for it)"),
                               ("zipped.zip", ez.appendingPathComponent("ECM Game.chd"), "zip with a .cue and an .ecm inside")] {
            let ok = job(jobs, j)?.state == .done
            let same = ok ? await discBin(chd) == original : false
            check(ok && same, "\(what) → CHD holding the original image", job(jobs, j)?.detail ?? "")
        }
        check(job(jobs, "ECM Game.cue")?.bytesIn == totalSize([ecmCue, ew.appendingPathComponent("ECM Game.bin.ecm")]),
              "savings compare the CHD with the .ecm on disk")
        check(tempFolders().subtracting(tempBeforeECM).isEmpty, "temporary files cleaned up")
        let ecmScan = Cleanup.scanSources(in: ew, outputDir: nil, sevenZip: nil)
        check(ecmScan.converted.map(\.source.lastPathComponent) == ["ECM Game.cue"] && ecmScan.converted.first?.files.count == 2,
              "Clean Up Originals: the .cue and its .ecm", "\(ecmScan.converted.map(\.source.lastPathComponent))")
        let loneScan = Cleanup.scanSources(in: lone, outputDir: nil, sevenZip: nil)
        check(loneScan.converted.map(\.source.lastPathComponent) == ["Lone Game.bin.ecm"], "Clean Up Originals: a lone .ecm")
        c.clearAll()

        // MARK: Playlists
        section("Playlists")
        let discs = W.appendingPathComponent("discs"); try? fm.createDirectory(at: discs, withIntermediateDirectories: true)
        for n in 1...2 {
            try! fm.copyItem(at: F.appendingPathComponent("cd/game.bin"), to: discs.appendingPathComponent("Game G (Disc \(n)).bin"))
            try! "FILE \"Game G (Disc \(n)).bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n"
                .write(to: discs.appendingPathComponent("Game G (Disc \(n)).cue"), atomically: true, encoding: .utf8)
        }
        _ = await runBatch([discs])
        let m3u = (try? String(contentsOf: discs.appendingPathComponent("Game G.m3u"), encoding: .utf8)) ?? ""
        check(m3u == "Game G (Disc 1).chd\nGame G (Disc 2).chd\n", "batch writes Game G.m3u in disc order", m3u)
        try! "Other.chd\nGame G (Disc 1).chd\n".write(to: discs.appendingPathComponent("Mine.m3u"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: discs.appendingPathComponent("Game G.m3u"))
        check(Playlist.make(in: discs).isEmpty, "a playlist someone else wrote is left alone")

        // MARK: Extracting
        section("Extracting CHDs")
        let ext = workspace("extract", from: F, ["chd/game.chd", "chd/ps2.chd"], into: W)
        jobs = await runBatch([ext.appendingPathComponent("game.chd"), ext.appendingPathComponent("ps2.chd")])
        check(sha1(ext.appendingPathComponent("game.bin")) == sha1(F.appendingPathComponent("cd/game.bin")), "CD CHD → identical BIN/CUE")
        check(sha1(ext.appendingPathComponent("ps2.iso")) == sha1(F.appendingPathComponent("ps2.iso")), "DVD CHD → identical ISO")

        // MARK: Redump while converting
        section("Redump while converting")
        db.add([F.appendingPathComponent("redump.zip")])
        while db.isLoading { try? await Task.sleep(for: .milliseconds(50)) }
        check(db.index.gameCount == 7, "DAT read from a .zip", "\(db.index.gameCount) games")
        db.enabled = true; db.renameToRedump = true; db.keepUnmatched = true
        let rd = workspace("redump", from: F, ["cd/game.cue", "cd/game.bin", "ps2.iso", "plain.iso",
                                               "two/Two.cue", "two/Two (Track 1).bin", "two/Two (Track 2).bin"], into: W)
        c.trashSources = false
        jobs = await runBatch([rd])
        check(job(jobs, "game.cue")?.detail.contains("✓ Redump") == true && exists(rd.appendingPathComponent("Good Game (USA).chd")),
              "match, and the CHD is named after Redump", job(jobs, "game.cue")?.detail ?? "")
        check(job(jobs, "ps2.iso")?.detail.contains("✓ Redump") == true, "ISO match")
        check(job(jobs, "Two.cue")?.detail.contains("partial") == true, "partial match", job(jobs, "Two.cue")?.detail ?? "")
        check(job(jobs, "plain.iso")?.detail.contains("not in Redump") == true, "no match")
        check(RedumpCache.lookup(rd.appendingPathComponent("Good Game (USA).chd"))?.isMatch == true, "new CHD's result is remembered")
        let log = ConversionLog.load()[rd.appendingPathComponent("game.cue").standardizedFileURL.path] ?? []
        check(log.first?.hasSuffix("Good Game (USA).chd") == true, "conversion record points at the renamed CHD")
        // Trash on + unmatched: originals must stay (nothing here may reach the real Trash)
        let keep = workspace("keep", from: F, ["plain.iso"], into: W)
        c.trashSources = true
        jobs = await runBatch([keep.appendingPathComponent("plain.iso")])
        c.trashSources = false
        check(exists(keep.appendingPathComponent("plain.iso")) && job(jobs, "plain.iso")?.detail.contains("originals kept") == true,
              "unmatched originals kept with Trash on")
        db.renameToRedump = false

        // MARK: Checking CHDs
        section("Checking CHDs against Redump")
        let ck = workspace("check", from: F, ["chd/game.chd", "chd/ps2.chd", "chd/two.chd", "chd/gd.chd", "chd/bad.chd"], into: W)
        try! "game.chd\nother.chd\n".write(to: ck.appendingPathComponent("set.m3u"), atomically: true, encoding: .utf8)
        let k = CHDCheck.shared
        k.clear(); k.recheck = false
        k.add([ck])
        k.start(); while k.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        func item(_ n: String) -> CHDCheck.Item? { k.items.first { $0.url.lastPathComponent == n } }
        func why(_ n: String) -> String { item(n).map { "\($0.state): \($0.result?.long ?? $0.error ?? "no result")" } ?? "missing" }
        check(item("game.chd")?.result?.isMatch == true, "CD CHD matches", why("game.chd"))
        check(item("ps2.chd")?.result?.isMatch == true, "DVD CHD matches", why("ps2.chd"))
        check(item("gd.chd")?.result?.isMatch == true, "Dreamcast GD-ROM CHD matches (Redump layout, gaps included)", item("gd.chd")?.result?.long ?? item("gd.chd")?.error ?? "")
        if case .partial(_, 1, 2) = item("two.chd")?.result { check(true, "partial match reported") } else { check(false, "partial match reported", item("two.chd")?.result?.long ?? "") }
        check(item("bad.chd")?.state == .failed, "damaged CHD fails", item("bad.chd")?.error ?? "")
        // Second run: unchanged CHDs come from memory
        k.clear(); k.add([ck]); k.start(); while k.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        check(item("game.chd")?.remembered == true && item("gd.chd")?.remembered == true, "unchanged CHDs aren't unpacked again",
              "game: \(why("game.chd")), remembered \(item("game.chd")?.remembered ?? false); gd remembered \(item("gd.chd")?.remembered ?? false)")
        check(item("bad.chd")?.remembered == false, "failed checks aren't remembered")
        k.renameMatches()
        check(exists(ck.appendingPathComponent("Good Game (USA).chd")) && exists(ck.appendingPathComponent("GD Game (USA).chd")), "matches renamed")
        let set = (try? String(contentsOf: ck.appendingPathComponent("set.m3u"), encoding: .utf8)) ?? ""
        check(set.hasPrefix("Good Game (USA).chd\n"), "playlist updated after rename", set)
        check(RedumpCache.lookup(ck.appendingPathComponent("Good Game (USA).chd"))?.isMatch == true, "remembered result follows the rename")

        // MARK: Cleanup and library report
        section("Clean Up Originals and Library Report")
        let lib = W.appendingPathComponent("library"); try? fm.createDirectory(at: lib, withIntermediateDirectories: true)
        let chd = F.appendingPathComponent("chd/game.chd")
        for n in ["Solo.chd", "Game A (Disc 1).chd", "Game A (Disc 2).chd", "Game B (Disc 1 of 3).chd", "Game B (Disc 3 of 3).chd",
                  "Game D (USA) (Disc 1).chd", "Game D (USA) (Disc 2).chd"] {
            try! fm.copyItem(at: chd, to: lib.appendingPathComponent(n))
        }
        try! fm.copyItem(at: F.appendingPathComponent("cd/game.bin"), to: lib.appendingPathComponent("Solo.bin"))
        try! "FILE \"Solo.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n".write(to: lib.appendingPathComponent("Solo.cue"), atomically: true, encoding: .utf8)
        try! fm.copyItem(at: F.appendingPathComponent("plain.iso"), to: lib.appendingPathComponent("New.iso"))
        RedumpCache.store(lib.appendingPathComponent("Solo.chd"), .match("Solo"))
        let r = LibraryReport.build(folder: lib, outputDir: nil, sevenZip: nil, log: ConversionLog.load(),
                                    redump: db.index, checked: RedumpCache.all()) { _ in }
        check(r.unconverted.map(\.lastPathComponent) == ["New.iso"], "not converted yet", "\(r.unconverted.map(\.lastPathComponent))")
        check(r.leftovers.map(\.source.lastPathComponent) == ["Solo.cue"] && r.leftovers.first?.files.count == 2, "original with a CHD (cue + bin)")
        let gaps = Dictionary(uniqueKeysWithValues: r.missingDiscs.map { ($0.name, $0.missing) })
        check(gaps["Game B"] == [2], "missing disc from “Disc 1 of 3” / “3 of 3”", "\(gaps)")
        check(gaps["Game D (USA)"] == [3], "missing disc from Redump's disc count", "\(gaps)")
        check(Set(r.needsPlaylist.map(\.name)) == ["Game A", "Game B", "Game D (USA)"], "sets without playlists", "\(r.needsPlaylist.map(\.name))")
        check(r.redumpMatched == 1 && r.redumpUnchecked.count == 6, "Redump counts from remembered results", "\(r.redumpMatched) / \(r.redumpUnchecked.count)")
        // Export
        let csv = r.csv()
        check(csv.hasPrefix("Section,Name,Folder,Details,Size (bytes)\n") && csv.contains("Not converted yet,New.iso,")
              && csv.contains("Missing discs,Game B,") && csv.contains("\"has 1, 3; missing 2\""), "report exports as CSV (with quoting)")
        let txt = r.text(folder: lib)
        check(txt.contains("Not converted yet: 1") && txt.contains("Game B: has disc 1, 3; missing 2"), "report exports as text")
        // Duplicates: stand-in CHDs whose headers name their disc data (a v5 header is all that's read)
        func fakeCHD(_ url: URL, data: UInt8, size: Int = 4096) {
            var d = Data("MComprHD".utf8) + Data([0, 0, 0, 124, 0, 0, 0, 5]) + Data(count: 48)
            d += Data(repeating: data, count: 20) + Data(count: 40)
            d += Data(count: size - d.count)
            try! d.write(to: url)
        }
        let dup = W.appendingPathComponent("dups"); try? fm.createDirectory(at: dup.appendingPathComponent("more"), withIntermediateDirectories: true)
        fakeCHD(dup.appendingPathComponent("Alpha (USA).chd"), data: 1)
        fakeCHD(dup.appendingPathComponent("more/Alpha (USA) copy.chd"), data: 1, size: 8192)
        fakeCHD(dup.appendingPathComponent("Alpha (Japan).chd"), data: 2)
        fakeCHD(dup.appendingPathComponent("Gamma (USA).chd"), data: 3)
        fakeCHD(dup.appendingPathComponent("gamma.chd"), data: 4)
        fakeCHD(dup.appendingPathComponent("Epsilon (Disc 1).chd"), data: 5)
        fakeCHD(dup.appendingPathComponent("Epsilon (Disc 2).chd"), data: 6)
        fakeCHD(dup.appendingPathComponent("Zeta.chd"), data: 7)
        fakeCHD(dup.appendingPathComponent("more/Zeta.chd"), data: 7)
        try! fm.copyItem(at: F.appendingPathComponent("plain.iso"), to: dup.appendingPathComponent("Alpha (Europe).iso"))
        RedumpCache.store(dup.appendingPathComponent("Gamma (USA).chd"), .match("Gamma (USA)"))
        RedumpCache.store(dup.appendingPathComponent("gamma.chd"), .match("Gamma (USA)"))
        check(LibraryReport.chdDataSHA1(F.appendingPathComponent("chd/game.chd"))?.count == 40
              && LibraryReport.chdDataSHA1(F.appendingPathComponent("plain.iso")) == nil, "reads a CHD's data SHA-1 from its header")
        let dr = LibraryReport.build(folder: dup, outputDir: nil, sevenZip: nil, log: [:], redump: db.index,
                                     checked: RedumpCache.all()) { _ in }
        let sets = dr.identical.map { $0.files.map(\.lastPathComponent).sorted() }
        check(sets.contains(["Alpha (USA) copy.chd", "Alpha (USA).chd"]), "identical copies: same disc data, whatever the name", "\(sets)")
        check(sets.contains(["Gamma (USA).chd", "gamma.chd"])
              && dr.identical.first { $0.files.contains { $0.lastPathComponent == "gamma.chd" } }?.why.contains("Redump") == true,
              "identical copies: both match the same Redump game", "\(sets)")
        check(sets.contains(["Zeta.chd", "Zeta.chd"]) && sets.count == 3, "identical copies in different folders, and nothing else", "\(sets)")
        check(dr.identicalBytes == 4096 * 3, "counts what deleting the extra copies would free", "\(dr.identicalBytes)")
        let versions = Dictionary(uniqueKeysWithValues: dr.versions.map { ($0.title, $0.files.map(\.lastPathComponent).sorted()) })
        check(versions["Alpha"] == ["Alpha (Europe).iso", "Alpha (Japan).chd", "Alpha (USA) copy.chd", "Alpha (USA).chd"],
              "several versions: regions, including one not converted yet", "\(versions)")
        check(versions.count == 1, "discs 1 and 2 of a game, and identical copies alone, aren't versions", "\(versions.keys.sorted())")
        check(dr.csv().contains("Identical copies,") && dr.csv().contains("Several versions,Alpha (Japan).chd")
              && dr.text(folder: dup).contains("Games in several versions: 1"), "duplicates are in the exports")

        // Ambiguous: two originals pointing at one CHD in a shared folder are left out of cleanup
        let shared = W.appendingPathComponent("shared"); let a1 = W.appendingPathComponent("amb1"), a2 = W.appendingPathComponent("amb2")
        for d in [shared, a1, a2] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try! fm.copyItem(at: chd, to: shared.appendingPathComponent("game.chd"))
        for d in [a1, a2] { for f in ["game.cue", "game.bin"] { try! fm.copyItem(at: F.appendingPathComponent("cd/\(f)"), to: d.appendingPathComponent(f)) } }
        let amb = Cleanup.findConverted(in: W, outputDir: shared, sevenZip: nil)
        let (clear, skipped) = Cleanup.unambiguous(amb.filter { $0.source.path.contains("/amb") })
        check(clear.isEmpty && skipped == 2, "files sharing one CHD name are left out of cleanup")

        // MARK: Patches
        section("Patches")
        @MainActor func chdBin(_ chd: URL) -> String? {
            let out = W.appendingPathComponent("unpacked-\(UUID().uuidString)")
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            let p = Process(); p.executableURL = c.chdman
            p.arguments = ["extractcd", "-i", chd.path, "-o", out.appendingPathComponent("x.cue").path, "-sb"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            let bins = ((try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "bin" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            return bins.compactMap(sha1).joined(separator: ",")
        }
        let patchNames: [(game: String, patch: String, redump: String?, want: String)] = [
            ("Racing Lagoon (Japan).cue", "racinglagoonenglish.xdelta", nil, "Racing Lagoon (English)"),
            ("racinglagoon.cue", "racinglagoonenglish.xdelta", "Racing Lagoon (Japan)", "Racing Lagoon (English)"),
            ("Game (Japan) (Disc 1).cue", "game_t-es_v1.0.ppf", nil, "Game (Spanish)"),
            ("Game (Japan).cue", "GAME-PTBR.xdelta", nil, "Game (Portuguese)"),
            ("Game (Japan).cue", "game-undub.xdelta", nil, "Game (Undub)"),
            ("Game (Japan).cue", "fix.ips", nil, "Game (Patched)"),
            ("Game (Japan).cue", "Tengai Makyou Zero (English) v1.1.xdelta", nil, "Tengai Makyou Zero (English) v1.1"),
        ]
        for n in patchNames {
            let got = Patcher.patchedName(game: url("/x/\(n.game)"), patch: url("/x/\(n.patch)"), redumpGame: n.redump)
            check(got == n.want, "“\(n.patch)” on “\(n.redump ?? n.game)” → “\(n.want)”", "got “\(got)”")
        }
        let wantPatched = sha1(F.appendingPathComponent("patch/target.bin"))
        check(Converter.findTool("xdelta3") != nil, "xdelta3 found")
        for (patchName, chdName) in [("Base (English).xdelta", "Base (English).chd"), ("Base (IPS).ips", "Base (IPS).chd"),
                                     ("Base (BPS).bps", "Base (BPS).chd"), ("Base (PPF).ppf", "Base (PPF).chd")] {
            let ws = workspace("patch-\(PatchFormat.of(url(patchName))!.rawValue)", from: F, ["patch/Base.cue", "patch/Base.bin", "patch/\(patchName)"], into: W)
            c.clearAll(); c.add([ws.appendingPathComponent("Base.cue")])
            if let id = c.jobs.first?.id { c.setPatch(ws.appendingPathComponent(patchName), for: id) }
            c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
            let chd = ws.appendingPathComponent(chdName)
            check(c.jobs.first?.state == .done && exists(chd) && chdBin(chd) == wantPatched,
                  "\(PatchFormat.of(url(patchName))!.rawValue) patch applied, CHD named after it", c.jobs.first?.detail ?? "")
            check(!exists(ws.appendingPathComponent("Base.chd")) && sha1(ws.appendingPathComponent("Base.bin")) == sha1(F.appendingPathComponent("patch/Base.bin")),
                  "\(PatchFormat.of(url(patchName))!.rawValue): original untouched, no unpatched CHD")
        }
        // Wrong game: the patch must refuse, not produce garbage
        let wrong = workspace("patch-wrong", from: F, ["cd/game.cue", "plain.iso"], into: W)
        try! fm.copyItem(at: F.appendingPathComponent("two/Two (Track 1).bin"), to: wrong.appendingPathComponent("game.bin"))
        for p in ["Base (English).xdelta", "Base (BPS).bps", "Base (PPF).ppf"] {
            try? fm.copyItem(at: F.appendingPathComponent("patch/\(p)"), to: wrong.appendingPathComponent(p))
            c.clearAll(); c.add([wrong.appendingPathComponent("game.cue")])
            if let id = c.jobs.first?.id { c.setPatch(wrong.appendingPathComponent(p), for: id) }
            c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
            check(c.jobs.first?.state == .failed && c.jobs.first?.detail.contains("doesn't fit") == true,
                  "\(PatchFormat.of(url(p))!.rawValue) patch for a different game is refused", c.jobs.first?.detail ?? "")
        }
        // Multi-track: the xdelta patch for track 2 is found and applied to track 2 only
        let mt = workspace("patch-two", from: F, ["two/Two.cue", "two/Two (Track 1).bin", "two/Two (Track 2).bin", "patch/Two (Fixed).xdelta"], into: W)
        try! fm.moveItem(at: mt.appendingPathComponent("Two (Fixed).xdelta"), to: mt.appendingPathComponent("Two.xdelta"))
        c.clearAll(); c.add([mt.appendingPathComponent("Two.cue")])
        check(c.jobs.first?.patch?.lastPathComponent == "Two.xdelta", "a patch next to the game with the same name is picked up")
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        let wantTwo = [F.appendingPathComponent("two/Two (Track 1).bin"), F.appendingPathComponent("patch/two-track2-target.bin")].compactMap(sha1).joined(separator: ",")
        check(chdBin(mt.appendingPathComponent("Two (Patched).chd")) == wantTwo, "multi-track: only the track the patch was made for is changed",
              c.jobs.first?.detail ?? "")
        // MARK: Zipped patches and the patches folder
        // (Redump off here: the sample disc matches “Good Game” in the test DAT, which would name the CHDs.)
        db.enabled = false
        @MainActor func zip(_ dir: URL, _ name: String, _ files: [(from: URL, as: String)]) -> URL {
            let stage = W.appendingPathComponent("zipstage-\(UUID().uuidString)")
            try? fm.createDirectory(at: stage, withIntermediateDirectories: true)
            for f in files { try! fm.copyItem(at: f.from, to: stage.appendingPathComponent(f.as)) }
            try! "Apply with Delta Patcher.".write(to: stage.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
            let out = dir.appendingPathComponent(name)
            let p = Process(); p.executableURL = url("/usr/bin/zip"); p.currentDirectoryURL = stage
            p.arguments = ["-q", "-r", out.path, "."]; try? p.run(); p.waitUntilExit()
            return out
        }
        func waitForLookup() async { while PatchLibrary.shared.isLooking { try? await Task.sleep(for: .milliseconds(50)) } }
        let px = F.appendingPathComponent("patch")
        check(Patcher.patchedName(game: url("/x/Racing Lagoon (Japan).cue"), patch: url("/x/patch.xdelta"), alsoLookIn: "racinglagoon-english")
              == "Racing Lagoon (English)", "a patch called “patch” takes its language from the zip’s name")

        // A zip with a patch for another game and the right one: the right one is used
        let zp = workspace("patch-zip", from: F, ["patch/Base.cue", "patch/Base.bin"], into: W)
        let bundle = zip(zp, "Base English v1.zip", [(px.appendingPathComponent("Two (Fixed).xdelta"), "patch-other-game.xdelta"),
                                                     (px.appendingPathComponent("Base (English).xdelta"), "Base (English).xdelta")])
        check(Patcher.isPatchZip(bundle), "a zip of patches is recognised as a patch")
        c.clearAll(); c.add([zp.appendingPathComponent("Base.cue"), bundle])
        check(c.jobs.count == 1 && c.jobs.first?.patch == bundle, "a patch zip dropped with its game goes with it (not converted as a game)")
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(chdBin(zp.appendingPathComponent("Base (English).chd")) == wantPatched, "the patch in the zip that fits is applied", c.jobs.first?.detail ?? "")
        // A patch zip next to the game with the same name is picked up
        let zn = workspace("patch-zip-next", from: F, ["patch/Base.cue", "patch/Base.bin"], into: W)
        _ = zip(zn, "Base.zip", [(px.appendingPathComponent("Base (BPS).bps"), "Base (BPS).bps")])
        c.clearAll(); c.add([zn.appendingPathComponent("Base.cue")])
        check(c.jobs.first?.patch?.lastPathComponent == "Base.zip", "a patch zip next to the game is picked up")

        // Patches folder
        let plib = PatchLibrary.shared
        let pf = W.appendingPathComponent("patches-folder"); try? fm.createDirectory(at: pf, withIntermediateDirectories: true)
        try! fm.copyItem(at: px.appendingPathComponent("Base (BPS).bps"), to: pf.appendingPathComponent("some unrelated name.bps"))
        try! fm.copyItem(at: px.appendingPathComponent("Base (English).xdelta"), to: pf.appendingPathComponent("racingbaseenglish.xdelta"))
        try! fm.copyItem(at: px.appendingPathComponent("Base (English).xdelta"), to: pf.appendingPathComponent("racingbasespanish.xdelta"))
        plib.enabled = true
        plib.folder = pf
        let bf = workspace("folder-bps", from: F, ["patch/Base.cue", "patch/Base.bin"], into: W)
        c.clearAll(); c.add([bf.appendingPathComponent("Base.cue")]); await waitForLookup()
        check(c.jobs.first?.patch?.lastPathComponent == "some unrelated name.bps" && c.jobs.first?.patchFromFolder == true,
              "patches folder: BPS found by checksum, whatever its name", "\(c.jobs.first?.patch?.lastPathComponent ?? "none")")
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(chdBin(bf.appendingPathComponent("Base (Patched).chd")) == wantPatched, "…and applied", c.jobs.first?.detail ?? "")
        // xdelta by name: the game "Racing Base (Japan)"; English preferred over Spanish
        let nf = W.appendingPathComponent("folder-name"); try? fm.createDirectory(at: nf, withIntermediateDirectories: true)
        try! fm.copyItem(at: px.appendingPathComponent("Base.bin"), to: nf.appendingPathComponent("Racing Base (Japan).bin"))
        try! "FILE \"Racing Base (Japan).bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n"
            .write(to: nf.appendingPathComponent("Racing Base (Japan).cue"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: pf.appendingPathComponent("some unrelated name.bps"))   // so only the name can match
        c.clearAll(); c.add([nf.appendingPathComponent("Racing Base (Japan).cue")]); await waitForLookup()
        check(c.jobs.first?.patch?.lastPathComponent == "racingbaseenglish.xdelta", "patches folder: xdelta found by the game's name, in your language",
              "\(c.jobs.first?.patch?.lastPathComponent ?? "none") (preferred: \(PatchLibrary.preferredLanguage ?? "?"))")
        check(c.jobs.first?.patchedName == "Racing Base (English)", "…and the list shows “Racing Base (English).chd”")
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(chdBin(nf.appendingPathComponent("Racing Base (English).chd")) == wantPatched, "…and applied", c.jobs.first?.detail ?? "")
        // A name match that doesn't fit: converted without the patch
        let nm = W.appendingPathComponent("folder-nofit"); try? fm.createDirectory(at: nm, withIntermediateDirectories: true)
        try! fm.copyItem(at: F.appendingPathComponent("two/Two (Track 1).bin"), to: nm.appendingPathComponent("Racing Base (Japan).bin"))
        try! fm.copyItem(at: nf.appendingPathComponent("Racing Base (Japan).cue"), to: nm.appendingPathComponent("Racing Base (Japan).cue"))
        c.clearAll(); c.add([nm.appendingPathComponent("Racing Base (Japan).cue")]); await waitForLookup()
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(c.jobs.first?.state == .done && exists(nm.appendingPathComponent("Racing Base (Japan).chd"))
              && c.jobs.first?.detail.contains("didn't fit") == true, "a folder patch that doesn't fit: converted without it", c.jobs.first?.detail ?? "")
        // PPF inside a zip in the folder, found by checksum
        let pf2 = W.appendingPathComponent("patches-folder-2"); try? fm.createDirectory(at: pf2, withIntermediateDirectories: true)
        _ = zip(pf2, "stuff.zip", [(px.appendingPathComponent("Base (PPF).ppf"), "random.ppf")])
        plib.folder = pf2
        let ppfGame = workspace("folder-ppf", from: F, ["patch/Base.cue", "patch/Base.bin"], into: W)
        c.clearAll(); c.add([ppfGame.appendingPathComponent("Base.cue")]); await waitForLookup()
        check(c.jobs.first?.patch?.lastPathComponent == "stuff.zip" && c.jobs.first?.patchMember == "random.ppf",
              "patches folder: PPF inside a zip found by checksum")
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(chdBin(ppfGame.appendingPathComponent("Base (Patched).chd")) == wantPatched, "…and applied", c.jobs.first?.detail ?? "")
        plib.folder = nil
        c.clearAll()

        // Patches box: patches added on their own go to the games they were made for
        func waitForMatching() async { while c.matchingPatches { try? await Task.sleep(for: .milliseconds(50)) } }
        let pb = W.appendingPathComponent("patch-box"); try? fm.createDirectory(at: pb, withIntermediateDirectories: true)
        try! fm.copyItem(at: px.appendingPathComponent("Base (BPS).bps"), to: pb.appendingPathComponent("unrelated name.bps"))
        try! fm.copyItem(at: px.appendingPathComponent("Two (Fixed).xdelta"), to: pb.appendingPathComponent("fix.xdelta"))
        try! fm.copyItem(at: px.appendingPathComponent("Base (English).xdelta"), to: pb.appendingPathComponent("racingbaseenglish.xdelta"))
        c.clearAll(); c.clearAddedPatches()
        c.addPatches([pb.appendingPathComponent("unrelated name.bps"), pb.appendingPathComponent("fix.xdelta")])
        check(c.addedPatches.count == 2 && c.jobs.isEmpty, "patches can be added before any game")
        let boxGame = workspace("box-bps", from: F, ["patch/Base.cue", "patch/Base.bin"], into: W)
        let boxTwo = workspace("box-two", from: F, ["two/Two.cue", "two/Two (Track 1).bin", "two/Two (Track 2).bin"], into: W)
        c.add([boxGame.appendingPathComponent("Base.cue"), boxTwo.appendingPathComponent("Two.cue")]); await waitForMatching()
        check(job(c.jobs, "Base.cue")?.patch?.lastPathComponent == "unrelated name.bps" && job(c.jobs, "Base.cue")?.patchFromFolder == false,
              "a game added later gets the BPS made for it (by checksum)", job(c.jobs, "Base.cue")?.patch?.lastPathComponent ?? "none")
        check(job(c.jobs, "Two.cue")?.patch == nil && c.gamesPatched(by: pb.appendingPathComponent("fix.xdelta").standardizedFileURL).isEmpty,
              "a patch that matches no game waits (with two games, it isn't guessed)")
        c.clearAll(); c.clearAddedPatches()
        // By name, among two games; then converted with it
        let boxName = W.appendingPathComponent("box-name"); try? fm.createDirectory(at: boxName, withIntermediateDirectories: true)
        for f in ["Racing Base (Japan).cue", "Racing Base (Japan).bin"] { try! fm.copyItem(at: nf.appendingPathComponent(f), to: boxName.appendingPathComponent(f)) }
        c.add([boxName.appendingPathComponent("Racing Base (Japan).cue"), boxTwo.appendingPathComponent("Two.cue")])
        // A folder of patches (no BPS here: this game's track is the one the BPS was made for, so it would win)
        let named = W.appendingPathComponent("patch-box-named"); try? fm.createDirectory(at: named, withIntermediateDirectories: true)
        for f in ["fix.xdelta", "racingbaseenglish.xdelta"] { try! fm.copyItem(at: pb.appendingPathComponent(f), to: named.appendingPathComponent(f)) }
        c.addPatches([named])
        await waitForMatching()
        check(c.addedPatches.count == 2, "a folder of patches adds each one")
        check(job(c.jobs, "Racing Base (Japan).cue")?.patch?.lastPathComponent == "racingbaseenglish.xdelta",
              "an xdelta goes to the game its name matches", job(c.jobs, "Racing Base (Japan).cue")?.patch?.lastPathComponent ?? "none")
        c.remove(job(c.jobs, "Two.cue")!.id)
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(chdBin(boxName.appendingPathComponent("Racing Base (English).chd")) == wantPatched, "…and is applied", c.jobs.first?.detail ?? "")
        c.clearAll(); c.clearAddedPatches()
        // One game and one patch: they go together, even if nothing matches by name
        c.add([boxTwo.appendingPathComponent("Two.cue")])
        c.add([pb.appendingPathComponent("fix.xdelta")])   // dropped on its own: joins the patches box
        await waitForMatching()
        check(c.addedPatches.map(\.lastPathComponent) == ["fix.xdelta"], "a patch dropped on its own joins the patches box")
        check(c.jobs.first?.patch?.lastPathComponent == "fix.xdelta", "one game and one patch go together")
        c.removeAddedPatch(c.addedPatches[0])
        check(c.addedPatches.isEmpty && c.jobs.first?.patch == nil, "removing a patch takes it off its game")
        c.clearAll()

        // MARK: Stacked patches, patching a CHD, and patches in the Library Report
        // Translation, then a fix on top
        let st = workspace("stack", from: F, ["patch/Base.cue", "patch/Base.bin", "patch/Base (English).xdelta", "patch/bugfix.ips"], into: W)
        c.clearAll(); c.add([st.appendingPathComponent("Base.cue")])
        if let id = c.jobs.first?.id {
            c.setPatch(st.appendingPathComponent("Base (English).xdelta"), for: id)
            c.addPatch(st.appendingPathComponent("bugfix.ips"), for: id)
        }
        check(c.jobs.first?.morePatches.map(\.lastPathComponent) == ["bugfix.ips"], "a second patch is added after the first")
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(chdBin(st.appendingPathComponent("Base (English).chd")) == sha1(F.appendingPathComponent("patch/target2.bin")),
              "stacked: translation then fix, named after the first", c.jobs.first?.detail ?? "")
        check(sha1(st.appendingPathComponent("Base.bin")) == sha1(F.appendingPathComponent("patch/Base.bin")), "stacked: original untouched")
        // Two tracks: xdelta changes track 2, then an IPS changes track 1 (a linked original: must be copied, not written through)
        let st2 = workspace("stack-two", from: F, ["two/Two.cue", "two/Two (Track 1).bin", "two/Two (Track 2).bin",
                                                   "patch/Two (Fixed).xdelta", "patch/track1fix.ips"], into: W)
        c.clearAll(); c.add([st2.appendingPathComponent("Two.cue")])
        if let id = c.jobs.first?.id {
            c.setPatch(st2.appendingPathComponent("Two (Fixed).xdelta"), for: id)
            c.addPatch(st2.appendingPathComponent("track1fix.ips"), for: id)
        }
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        let wantBoth = [F.appendingPathComponent("patch/two-track1-target.bin"), F.appendingPathComponent("patch/two-track2-target.bin")]
            .compactMap(sha1).joined(separator: ",")
        check(chdBin(st2.appendingPathComponent("Two (Fixed).chd")) == wantBoth, "stacked on two tracks: each patch changes its own track",
              c.jobs.first?.detail ?? "")
        check(sha1(st2.appendingPathComponent("Two (Track 1).bin")) == sha1(F.appendingPathComponent("two/Two (Track 1).bin"))
              && sha1(st2.appendingPathComponent("Two (Track 2).bin")) == sha1(F.appendingPathComponent("two/Two (Track 2).bin")),
              "stacked on two tracks: the original tracks are untouched")

        // Patching a CHD you already have
        let pc = W.appendingPathComponent("patch-chd"); try? fm.createDirectory(at: pc, withIntermediateDirectories: true)
        try! fm.copyItem(at: F.appendingPathComponent("chd/game.chd"), to: pc.appendingPathComponent("Base (Japan).chd"))   // game.bin = Base.bin
        try! fm.copyItem(at: px.appendingPathComponent("Base (English).xdelta"), to: pc.appendingPathComponent("Base (English).xdelta"))
        let chdBefore = sha1(pc.appendingPathComponent("Base (Japan).chd"))
        c.clearAll(); c.add([pc.appendingPathComponent("Base (Japan).chd")])
        check(c.jobs.first?.isExtraction == true && c.jobs.first?.patch == nil, "a CHD on its own is still extracted (no patch picked up)")
        if let id = c.jobs.first?.id { c.setPatch(pc.appendingPathComponent("Base (English).xdelta"), for: id) }
        check(c.jobs.first?.isExtraction == false, "…with a patch, it's patched instead")
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(chdBin(pc.appendingPathComponent("Base (English).chd")) == wantPatched, "a CHD is unpacked, patched and compressed again",
              c.jobs.first?.detail ?? "")
        check(sha1(pc.appendingPathComponent("Base (Japan).chd")) == chdBefore, "…and the original CHD is untouched")

        // Library Report: patches available
        let rl = W.appendingPathComponent("report-patches"); try? fm.createDirectory(at: rl, withIntermediateDirectories: true)
        try! fm.copyItem(at: px.appendingPathComponent("Base.bin"), to: rl.appendingPathComponent("Racing Base (Japan).bin"))
        try! "FILE \"Racing Base (Japan).bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n"
            .write(to: rl.appendingPathComponent("Racing Base (Japan).cue"), atomically: true, encoding: .utf8)
        try! fm.copyItem(at: F.appendingPathComponent("chd/game.chd"), to: rl.appendingPathComponent("Speed Base (Japan).chd"))
        try! fm.copyItem(at: F.appendingPathComponent("chd/game.chd"), to: rl.appendingPathComponent("Done Base (Japan).chd"))
        try! fm.copyItem(at: F.appendingPathComponent("chd/game.chd"), to: rl.appendingPathComponent("Done Base (English).chd"))
        let rp = W.appendingPathComponent("report-patches-folder"); try? fm.createDirectory(at: rp, withIntermediateDirectories: true)
        for n in ["racingbaseenglish", "speedbaseenglish", "donebaseenglish"] {
            try! fm.copyItem(at: px.appendingPathComponent("Base (English).xdelta"), to: rp.appendingPathComponent("\(n).xdelta"))
        }
        let offers = LibraryReport.patchOffers(patchesFolder: rp, prefer: "English", outputDir: nil,
                                               unconverted: [rl.appendingPathComponent("Racing Base (Japan).cue")], leftovers: [],
                                               chds: ["Speed Base (Japan).chd", "Done Base (Japan).chd", "Done Base (English).chd"].map { rl.appendingPathComponent($0) })
        check(offers.map(\.name) == ["Racing Base (English)", "Speed Base (English)"],
              "report offers patches for a game and a CHD, not for ones already patched", "\(offers.map(\.name))")
        // What “Convert Patched Versions” does
        c.clearAll()
        for o in offers {
            c.add([o.game])
            if let job = c.jobs.last(where: { $0.url.standardizedFileURL == o.game.standardizedFileURL }) { c.setPatch(o.patch.url, member: o.patch.member, for: job.id) }
        }
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(chdBin(rl.appendingPathComponent("Racing Base (English).chd")) == wantPatched
              && chdBin(rl.appendingPathComponent("Speed Base (English).chd")) == wantPatched, "Convert Patched Versions makes both",
              c.jobs.map(\.detail).joined(separator: " | "))
        c.clearAll()

        // Dropped together with its game
        let dz = workspace("patch-drop", from: F, ["patch/Base.cue", "patch/Base.bin", "patch/Base (BPS).bps"], into: W)
        c.clearAll(); c.add([dz.appendingPathComponent("Base.cue"), dz.appendingPathComponent("Base (BPS).bps")])
        check(c.jobs.count == 1 && c.jobs.first?.patch?.lastPathComponent == "Base (BPS).bps", "a patch dropped with its game goes with it")
        c.clearAll()

        // MARK: GameCube and Wii
        section("GameCube and Wii (RVZ)")
        check(Converter.isNintendoDisc(F.appendingPathComponent("gc/GC Game (USA).iso"))
              && Converter.isNintendoDisc(F.appendingPathComponent("gc/wii-header.iso"))
              && !Converter.isNintendoDisc(F.appendingPathComponent("ps2.iso")) && !Converter.isNintendoDisc(F.appendingPathComponent("plain.iso")),
              "GameCube and Wii discs are recognised by their header (other ISOs aren't)")
        check(Converter.nintendoSystem(F.appendingPathComponent("gc/wii-header.iso")) == "Wii", "…and told apart")
        check(Converter.findTool("dolphin-tool") != nil, "dolphin-tool found")
        c.verify = true
        let gcw = workspace("gc", from: F, ["gc/GC Game (USA).iso"], into: W)
        jobs = await runBatch([gcw.appendingPathComponent("GC Game (USA).iso")])
        let rvz = gcw.appendingPathComponent("GC Game (USA).rvz")
        check(jobs.first?.state == .done && exists(rvz) && !exists(gcw.appendingPathComponent("GC Game (USA).chd")),
              "a GameCube ISO becomes an RVZ (not a CHD), verified", jobs.first?.detail ?? "")
        c.verify = false
        // Checking an RVZ against Redump: dolphin-tool works out the SHA-1 of the disc inside
        let gcSHA = sha1(gcw.appendingPathComponent("GC Game (USA).iso"))!
        let gcDisc = await Converter.discSHA1(rvz, dolphin: Converter.findTool("dolphin-tool")!)
        check(gcDisc == gcSHA, "an RVZ's disc SHA-1 is the original ISO's", gcDisc ?? "none")
        var gcIndex = RedumpIndex()
        gcIndex.roms[gcSHA] = [.init(game: "GC Game (USA)", name: "GC Game (USA).iso")]
        gcIndex.trackCount["GC Game (USA)"] = 1
        let noDAT = await CHDCheck.check(rvz, chdman: c.chdman!, index: gcIndex, started: { _ in }, progress: { _ in })
        if case .failure(let e) = noDAT { check(e.message.contains("GameCube and Wii"), "without the GameCube/Wii DATs, it says to turn them on", e.message) }
        else { check(false, "without the GameCube/Wii DATs, it says to turn them on") }
        gcIndex.system["GC Game (USA)"] = "gc"
        let rvzCheck = await CHDCheck.check(rvz, chdman: c.chdman!, index: gcIndex, started: { _ in }, progress: { _ in })
        if case .success(.match(let g)) = rvzCheck { check(g == "GC Game (USA)", "an RVZ matches Redump") }
        else { check(false, "an RVZ matches Redump", "\(rvzCheck)") }
        CHDCheck.shared.items = []; CHDCheck.shared.add([gcw])
        check(CHDCheck.shared.items.map(\.url.lastPathComponent).contains("GC Game (USA).rvz"), "Check Against Redump picks up RVZs in a folder")
        CHDCheck.shared.items = []
        try? fm.moveItem(at: gcw.appendingPathComponent("GC Game (USA).iso"), to: gcw.appendingPathComponent("original.iso"))
        jobs = await runBatch([rvz])
        check(sha1(gcw.appendingPathComponent("GC Game (USA).iso")) == sha1(F.appendingPathComponent("gc/GC Game (USA).iso")),
              "an RVZ extracts back to the identical ISO", jobs.first?.detail ?? "")
        // Clean Up counts an RVZ as the converted copy
        try? fm.removeItem(at: gcw.appendingPathComponent("GC Game (USA).iso"))
        try? fm.moveItem(at: gcw.appendingPathComponent("original.iso"), to: gcw.appendingPathComponent("GC Game (USA).iso"))
        check(Cleanup.findConverted(in: gcw, outputDir: nil, sevenZip: nil).first?.chds.first?.lastPathComponent == "GC Game (USA).rvz",
              "Clean Up Originals counts the RVZ as converted")
        // Patched
        let gcp = workspace("gc-patch", from: F, ["gc/GC Game (USA).iso", "gc/gcgameenglish.xdelta"], into: W)
        c.clearAll(); c.add([gcp.appendingPathComponent("GC Game (USA).iso")])
        if let id = c.jobs.first?.id { c.setPatch(gcp.appendingPathComponent("gcgameenglish.xdelta"), for: id) }
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        let prvz = gcp.appendingPathComponent("GC Game (English).rvz")
        check(exists(prvz), "a patched GameCube game becomes “GC Game (English).rvz”", c.jobs.first?.detail ?? "")
        jobs = await runBatch([prvz])
        check(sha1(gcp.appendingPathComponent("GC Game (English).iso")) == sha1(F.appendingPathComponent("gc/gc-patched.iso")), "…with the patch in it")
        c.clearAll()

        // MARK: Making PBPs
        section("Making PBPs (PSP / PS Vita)")
        @MainActor func pbpBins(_ pbp: URL) -> [String] {
            let out = W.appendingPathComponent("pbp-out-\(UUID().uuidString)")
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            let p = Process(); p.executableURL = c.psxpackager
            p.arguments = ["-i", pbp.path, "-o", out.path, "-x", "-v", "1"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            return ((try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "bin" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .compactMap(sha1)
        }
        check(c.psxpackager != nil, "PSXPackager found")
        c.outputFormat = .pbp
        let d1 = sha1(F.appendingPathComponent("ps1/PS1 Game (Disc 1).bin")), d2 = sha1(F.appendingPathComponent("ps1/PS1 Game (Disc 2).bin"))
        // One disc
        let pb1 = workspace("pbp-single", from: F, ["ps1/PS1 Game (Disc 1).cue", "ps1/PS1 Game (Disc 1).bin"], into: W)
        jobs = await runBatch([pb1])
        check(pbpBins(pb1.appendingPathComponent("PS1 Game (Disc 1).pbp")) == [d1].compactMap { $0 }, "a disc becomes a PBP with the same data",
              jobs.first?.detail ?? "")
        // Two discs, one PBP
        let pb2 = workspace("pbp-multi", from: F, ["ps1/PS1 Game (Disc 1).cue", "ps1/PS1 Game (Disc 1).bin",
                                                   "ps1/PS1 Game (Disc 2).cue", "ps1/PS1 Game (Disc 2).bin"], into: W)
        jobs = await runBatch([pb2])
        check(pbpBins(pb2.appendingPathComponent("PS1 Game.pbp")) == [d1, d2].compactMap { $0 }, "two discs of a game go into one PBP",
              jobs.map(\.detail).joined(separator: " | "))
        check(jobs.allSatisfy { $0.state == .done } && jobs.contains { $0.detail.contains("with the other discs") }, "…and both are marked done")
        // Patched
        let pb3 = workspace("pbp-patched", from: F, ["ps1/PS1 Game (Disc 1).cue", "ps1/PS1 Game (Disc 1).bin", "ps1/psgameenglish.xdelta"], into: W)
        c.clearAll(); c.add([pb3.appendingPathComponent("PS1 Game (Disc 1).cue")])
        if let id = c.jobs.first?.id { c.setPatch(pb3.appendingPathComponent("psgameenglish.xdelta"), for: id) }
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(pbpBins(pb3.appendingPathComponent("PS1 Game (English).pbp")) == [sha1(F.appendingPathComponent("ps1/patched-disc1.bin"))].compactMap { $0 },
              "a patched game becomes a patched PBP, named “PS1 Game (English)”", c.jobs.first?.detail ?? "")
        check(sha1(pb3.appendingPathComponent("PS1 Game (Disc 1).bin")) == d1, "…and the original is untouched")
        // From a CHD, into a PSP folder
        c.pbpFolders = true
        let pb4 = workspace("pbp-chd", from: F, ["ps1/PS1 Game (Disc 1).chd"], into: W)
        c.clearAll(); c.add([pb4])   // a folder scan picks up CHDs when making PBPs
        check(c.jobs.count == 1, "making PBPs, a folder scan picks up CHDs")
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(pbpBins(pb4.appendingPathComponent("PS1 Game (Disc 1)/EBOOT.pbp")) == [d1].compactMap { $0 },
              "a CHD becomes PS1 Game (Disc 1)/EBOOT.PBP for a PSP", c.jobs.first?.detail ?? "")
        c.pbpFolders = false
        // Not a PlayStation game
        let pb5 = workspace("pbp-notps1", from: F, ["plain.iso"], into: W)
        jobs = await runBatch([pb5.appendingPathComponent("plain.iso")])
        check(jobs.first?.state == .failed && jobs.first?.detail.contains("PlayStation") == true && !exists(pb5.appendingPathComponent("plain.pbp")),
              "a disc that isn't a PlayStation game is refused", jobs.first?.detail ?? "")
        c.outputFormat = .chd
        c.clearAll()

        // MARK: Systems
        section("Telling systems apart")
        /// A raw CD image whose first data sector starts with `header` (Mode 1, 2352-byte sectors), with its .cue.
        func rawDisc(_ dir: URL, _ name: String, header: [UInt8], mode2048: Bool = false) -> URL {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var d = Data()
            for n in 0..<40 {
                var s = [UInt8](repeating: 0, count: mode2048 ? 2048 : 2352)
                let o = mode2048 ? 0 : 16
                if !mode2048 { s[1...10] = ArraySlice(repeating: 0xFF, count: 10); s[15] = 1 }
                if n == 0 { for (k, b) in header.enumerated() { s[o + k] = b } }
                d += Data(s)
            }
            try! d.write(to: dir.appendingPathComponent(name + ".bin"))
            let cue = dir.appendingPathComponent(name + ".cue")
            try! "FILE \"\(name).bin\" BINARY\n  TRACK 01 \(mode2048 ? "MODE1/2048" : "MODE1/2352")\n    INDEX 01 00:00:00\n".write(to: cue, atomically: true, encoding: .utf8)
            return cue
        }
        let sysDir = W.appendingPathComponent("systems")
        let saturn = rawDisc(sysDir, "Saturn Game", header: Array("SEGA SEGASATURN ".utf8))
        let segacd = rawDisc(sysDir, "Sega CD Game", header: Array("SEGADISCSYSTEM  ".utf8))
        let threeDO = rawDisc(sysDir, "3DO Game", header: [0x01, 0x5A, 0x5A, 0x5A, 0x5A, 0x5A, 0x01], mode2048: true)
        let wiiRVZ = Data([0x52, 0x56, 0x5A, 0x01]) + Data(count: 0x44) + Data([0, 0, 0, 2]) + Data(count: 64)
        try! wiiRVZ.write(to: sysDir.appendingPathComponent("Wii Game.rvz"))
        for (file, want) in [(F.appendingPathComponent("psp.iso"), "PSP"), (F.appendingPathComponent("ps2.iso"), "PlayStation 2"),
                             (F.appendingPathComponent("ps1.iso"), "PlayStation"), (F.appendingPathComponent("ps1/PS1 Game (Disc 1).cue"), "PlayStation"),
                             (F.appendingPathComponent("gc/GC Game (USA).iso"), "GameCube"), (sysDir.appendingPathComponent("Wii Game.rvz"), "Wii"),
                             (saturn, "Saturn"), (segacd, "Sega CD"), (threeDO, "3DO"), (F.appendingPathComponent("plain.iso"), "unknown")] {
            check((Systems.detect(file)?.folder ?? "unknown") == want, "\(file.lastPathComponent) → \(want)", Systems.detect(file)?.folder ?? "unknown")
        }
        var sysIndex = RedumpIndex(); sysIndex.system["Some Game (Japan)"] = "ss"
        check(Converter.system(of: F.appendingPathComponent("plain.iso"), redump: .match("Some Game (Japan)"), index: sysIndex)?.folder == "Saturn",
              "a Redump match's system comes first")
        check(Systems.fromFolderName("psx")?.id == "psx" && Systems.fromFolderName("PS1")?.id == "psx"
              && Systems.fromFolderName("Sony - PlayStation 2")?.id == "ps2" && Systems.fromFolderName("Games") == nil, "systems from folder names")

        // MARK: Folders per system, RetroArch playlists, copying to a device
        section("Folders per system, RetroArch playlists and copying")
        let org = workspace("organize", from: F, ["ps1/PS1 Game (Disc 1).cue", "ps1/PS1 Game (Disc 1).bin", "ps2.iso"], into: W)
        let ra = W.appendingPathComponent("retroarch"), device = W.appendingPathComponent("device")
        try? fm.createDirectory(at: ra, withIntermediateDirectories: true); try? fm.createDirectory(at: device, withIntermediateDirectories: true)
        // A playlist RetroArch already has, with a game and a setting of its own, must be kept.
        try! #"{"version":"1.5","default_core_name":"Beetle PSX","items":[{"path":"/Games/Other.chd","label":"Other Game"}]}"#
            .write(to: ra.appendingPathComponent("Sony - PlayStation.lpl"), atomically: true, encoding: .utf8)
        c.organizeBySystem = true; c.systemFolderStyle = .readable
        c.retroArchPlaylists = true; c.retroArchFolder = ra; c.copyDestination = device
        jobs = await runBatch([org.appendingPathComponent("PS1 Game (Disc 1).cue"), org.appendingPathComponent("ps2.iso")])
        let ps1CHD = org.appendingPathComponent("PlayStation/PS1 Game (Disc 1).chd"), ps2CHD = org.appendingPathComponent("PlayStation 2/ps2.chd")
        check(exists(ps1CHD) && exists(ps2CHD), "CHDs saved in PlayStation/ and PlayStation 2/", job(jobs, "ps2.iso")?.detail ?? "")
        let lpl = (try? JSONSerialization.jsonObject(with: Data(contentsOf: ra.appendingPathComponent("Sony - PlayStation.lpl")))) as? [String: Any]
        let items = lpl?["items"] as? [[String: Any]] ?? []
        check(items.contains { $0["path"] as? String == ps1CHD.standardizedFileURL.path && $0["label"] as? String == "PS1 Game (Disc 1)" && $0["db_name"] as? String == "Sony - PlayStation.lpl" },
              "added to RetroArch's “Sony - PlayStation” playlist", "\(items)")
        check(items.contains { $0["path"] as? String == "/Games/Other.chd" } && lpl?["default_core_name"] as? String == "Beetle PSX",
              "the playlist's other games and settings are kept")
        check(exists(ra.appendingPathComponent("Sony - PlayStation 2.lpl")), "a PS2 game goes in the PS2 playlist")
        check(totalSize([device.appendingPathComponent("PlayStation/PS1 Game (Disc 1).chd")]) == totalSize([ps1CHD])
              && exists(device.appendingPathComponent("PlayStation 2/ps2.chd")), "copied to the device, in the same system folders")
        check(job(jobs, "ps2.iso")?.detail.contains("copied to") == true, "the list says it was copied", job(jobs, "ps2.iso")?.detail ?? "")
        check(Cleanup.scanSources(in: org, outputDir: nil, sevenZip: nil).converted.count == 2, "Clean Up Originals finds CHDs in system folders")
        jobs = await runBatch([org.appendingPathComponent("ps2.iso")])
        check(job(jobs, "ps2.iso")?.detail.contains("already on") == true, "a game already on the device isn't copied again", job(jobs, "ps2.iso")?.detail ?? "")
        c.copyDestination = W.appendingPathComponent("unplugged-card"); c.overwrite = true
        jobs = await runBatch([org.appendingPathComponent("ps2.iso")])
        check(job(jobs, "ps2.iso")?.state == .done && job(jobs, "ps2.iso")?.detail.contains("isn't connected") == true,
              "a device that isn't connected: converted, not copied", job(jobs, "ps2.iso")?.detail ?? "")
        c.copyDestination = device; try? fm.removeItem(at: device.appendingPathComponent("PlayStation 2"))
        DiskSpace.override = { url in url.path.hasPrefix(device.path) ? 1_000 : nil }
        jobs = await runBatch([org.appendingPathComponent("ps2.iso")])
        check(job(jobs, "ps2.iso")?.detail.contains("not enough space") == true && !exists(device.appendingPathComponent("PlayStation 2/ps2.chd")),
              "not enough space on the device: not copied", job(jobs, "ps2.iso")?.detail ?? "")
        DiskSpace.override = nil; c.overwrite = false
        c.systemFolderStyle = .esde
        let orgE = workspace("organize-esde", from: F, ["ps2.iso"], into: W)
        jobs = await runBatch([orgE.appendingPathComponent("ps2.iso")])
        check(exists(orgE.appendingPathComponent("ps2/ps2.chd")), "ES-DE style folder names (ps2/)")
        c.organizeBySystem = false; c.systemFolderStyle = .readable; c.retroArchPlaylists = false; c.retroArchFolder = nil; c.copyDestination = nil
        // A whole library into RetroArch: system from the folder name, discs through their .m3u
        let ralib = W.appendingPathComponent("ra-library")
        for d in ["PlayStation", "Unsorted"] { try? fm.createDirectory(at: ralib.appendingPathComponent(d), withIntermediateDirectories: true) }
        fakeCHD(ralib.appendingPathComponent("PlayStation/Solo (USA).chd"), data: 11)
        fakeCHD(ralib.appendingPathComponent("PlayStation/Two (Disc 1).chd"), data: 12)
        fakeCHD(ralib.appendingPathComponent("PlayStation/Two (Disc 2).chd"), data: 13)
        try! "Two (Disc 1).chd\nTwo (Disc 2).chd\n".write(to: ralib.appendingPathComponent("PlayStation/Two.m3u"), atomically: true, encoding: .utf8)
        fakeCHD(ralib.appendingPathComponent("Unsorted/Mystery.chd"), data: 14)
        let (bySystem, unknownGames) = RetroArch.library(ralib, index: db.index, checked: [:])
        let psx = (bySystem.first { $0.key.id == "psx" }?.value ?? []).map(\.label).sorted()
        check(psx == ["Solo (USA)", "Two"] && unknownGames.map(\.lastPathComponent) == ["Mystery.chd"],
              "library: system from the folder, a multi-disc game through its .m3u, unknown ones left out", "\(psx) / \(unknownGames)")

        // A multi-disc game converted disc by disc: its .m3u goes into RetroArch in place of the discs, and to the device
        let md = workspace("multidisc", from: F, ["ps1/PS1 Game (Disc 1).cue", "ps1/PS1 Game (Disc 1).bin",
                                                  "ps1/PS1 Game (Disc 2).cue", "ps1/PS1 Game (Disc 2).bin"], into: W)
        let ra2 = W.appendingPathComponent("retroarch-multidisc"), device2 = W.appendingPathComponent("device-multidisc")
        try? fm.createDirectory(at: device2, withIntermediateDirectories: true)
        c.organizeBySystem = true; c.retroArchPlaylists = true; c.retroArchFolder = ra2; c.copyDestination = device2
        jobs = await runBatch([md])
        let mdM3U = md.appendingPathComponent("PlayStation/PS1 Game.m3u")
        check(((try? String(contentsOf: mdM3U, encoding: .utf8)) ?? "") == "PS1 Game (Disc 1).chd\nPS1 Game (Disc 2).chd\n",
              "the batch writes PS1 Game.m3u next to the discs, in the system folder")
        let mdItems = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: ra2.appendingPathComponent("Sony - PlayStation.lpl")))) as? [String: Any])?["items"] as? [[String: Any]] ?? []
        check(mdItems.count == 1 && mdItems.first?["path"] as? String == mdM3U.standardizedFileURL.path && mdItems.first?["label"] as? String == "PS1 Game",
              "RetroArch lists the game once, through its .m3u", "\(mdItems.map { $0["label"] ?? "" })")
        check(exists(device2.appendingPathComponent("PlayStation/PS1 Game.m3u")) && exists(device2.appendingPathComponent("PlayStation/PS1 Game (Disc 2).chd")),
              "the .m3u is copied to the device with the discs")
        c.organizeBySystem = false; c.retroArchPlaylists = false; c.retroArchFolder = nil; c.copyDestination = nil

        // MARK: Sorting a library into system folders
        section("Sorting a library into system folders")
        let chdman = c.chdman!
        for (file, want) in [(F.appendingPathComponent("ps1/PS1 Game (Disc 1).chd"), "PlayStation"), (F.appendingPathComponent("chd/ps2.chd"), "PlayStation 2"),
                             (F.appendingPathComponent("chd/gd.chd"), "Dreamcast"), (F.appendingPathComponent("chd/game.chd"), "unknown")] {
            check((Systems.detectCHD(file, chdman: chdman)?.folder ?? "unknown") == want, "CHD \(file.lastPathComponent) → \(want)",
                  Systems.detectCHD(file, chdman: chdman)?.folder ?? "unknown")
        }
        let lib2 = W.appendingPathComponent("sort-library")
        try? fm.createDirectory(at: lib2.appendingPathComponent("Saturn"), withIntermediateDirectories: true)
        try! fm.copyItem(at: F.appendingPathComponent("ps1/PS1 Game (Disc 1).chd"), to: lib2.appendingPathComponent("Star (Disc 1).chd"))
        try! fm.copyItem(at: F.appendingPathComponent("ps1/PS1 Game (Disc 1).chd"), to: lib2.appendingPathComponent("Star (Disc 2).chd"))
        try! "Star (Disc 1).chd\nStar (Disc 2).chd\n".write(to: lib2.appendingPathComponent("Star.m3u"), atomically: true, encoding: .utf8)
        try! fm.copyItem(at: F.appendingPathComponent("chd/ps2.chd"), to: lib2.appendingPathComponent("ps2 game.chd"))
        try! fm.copyItem(at: F.appendingPathComponent("chd/game.chd"), to: lib2.appendingPathComponent("mystery.chd"))
        try! fm.copyItem(at: F.appendingPathComponent("chd/game.chd"), to: lib2.appendingPathComponent("Saturn/already sorted.chd"))
        try! wiiRVZ.write(to: lib2.appendingPathComponent("wii game.rvz"))
        try! fm.copyItem(at: F.appendingPathComponent("chd/gd.chd"), to: lib2.appendingPathComponent("dc game.chd"))
        RedumpCache.store(lib2.appendingPathComponent("dc game.chd"), .match("Sea Adventure (USA)"))
        try! Data("SBI\0".utf8).write(to: lib2.appendingPathComponent("dc game.sbi"))
        var lib2Index = RedumpIndex(); lib2Index.system["Sea Adventure (USA)"] = "dc"
        ConversionLog.record(source: W.appendingPathComponent("somewhere/dc game.gdi"), chds: [lib2.appendingPathComponent("dc game.chd")])
        let ra3 = W.appendingPathComponent("retroarch-sort"); try? fm.createDirectory(at: ra3, withIntermediateDirectories: true)
        try! #"{"items":[{"path":"\#(lib2.appendingPathComponent("ps2 game.chd").standardizedFileURL.path)","label":"ps2 game"}]}"#
            .write(to: ra3.appendingPathComponent("Sony - PlayStation 2.lpl"), atomically: true, encoding: .utf8)
        let plan = Organize.plan(folder: lib2, style: .readable, index: lib2Index, checked: RedumpCache.all(), chdman: chdman)
        let planned = Dictionary(uniqueKeysWithValues: plan.moves.map { ($0.from.lastPathComponent, $0.toDir.lastPathComponent) })
        check(planned == ["Star (Disc 1).chd": "PlayStation", "Star (Disc 2).chd": "PlayStation", "ps2 game.chd": "PlayStation 2",
                          "wii game.rvz": "Wii", "dc game.chd": "Dreamcast"], "each game's system worked out (from the CHD, the RVZ header, or Redump)", "\(planned)")
        check(plan.unknown.map(\.lastPathComponent) == ["mystery.chd"], "a game whose system can't be told stays", "\(plan.unknown.map(\.lastPathComponent))")
        check(plan.playlists.map(\.from.lastPathComponent) == ["Star.m3u"] && plan.renameable == 1, "the .m3u moves with its discs; one can take its Redump name")
        let outcome = Organize.apply(plan, folder: lib2, rename: true, retroArchFolder: ra3)
        check(outcome.moved == 5 && outcome.renamed == 1, "moved 5, renamed 1", "\(outcome)")
        check(exists(lib2.appendingPathComponent("PlayStation/Star (Disc 2).chd")) && exists(lib2.appendingPathComponent("PlayStation/Star.m3u"))
              && exists(lib2.appendingPathComponent("Dreamcast/Sea Adventure (USA).chd")) && exists(lib2.appendingPathComponent("Wii/wii game.rvz"))
              && exists(lib2.appendingPathComponent("Saturn/already sorted.chd")) && exists(lib2.appendingPathComponent("mystery.chd")),
              "files are in their system folders (already-sorted and unknown ones untouched)",
              ((fm.enumerator(atPath: lib2.path)?.allObjects as? [String]) ?? []).sorted().joined(separator: ", "))
        check(RedumpCache.lookup(lib2.appendingPathComponent("Dreamcast/Sea Adventure (USA).chd"))?.isMatch == true
              && ConversionLog.load()[W.appendingPathComponent("somewhere/dc game.gdi").standardizedFileURL.path]?.first?.hasSuffix("Dreamcast/Sea Adventure (USA).chd") == true,
              "the Redump result and Clean Up Originals' record follow the move")
        let ra3Items = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: ra3.appendingPathComponent("Sony - PlayStation 2.lpl")))) as? [String: Any])?["items"] as? [[String: Any]] ?? []
        check(ra3Items.first?["path"] as? String == lib2.appendingPathComponent("PlayStation 2/ps2 game.chd").standardizedFileURL.path && outcome.playlistEntries == 1,
              "RetroArch playlists point at the new places", "\(ra3Items)")
        check(exists(lib2.appendingPathComponent("Dreamcast/Sea Adventure (USA).sbi")) && !exists(lib2.appendingPathComponent("dc game.sbi")),
              "a game's .sbi moves and is renamed with it")
        let again = Organize.plan(folder: lib2, style: .readable, index: lib2Index, checked: RedumpCache.all(), chdman: chdman)
        check(again.moves.isEmpty, "a second run finds nothing to move")
        // Undo Last Sort
        check(Organize.lastSort()?.moves.count == 7, "the sort is recorded (5 games, a .sbi, an .m3u)", "\(Organize.lastSort()?.moves.count ?? -1)")
        let undone = Organize.undoLast(retroArchFolder: ra3)
        let afterUndo = ((fm.enumerator(atPath: lib2.path)?.allObjects as? [String]) ?? []).sorted()
        check(undone.restored == 7 && undone.skipped == 0
              && afterUndo == ["Saturn", "Saturn/already sorted.chd", "Star (Disc 1).chd", "Star (Disc 2).chd", "Star.m3u",
                               "dc game.chd", "dc game.sbi", "mystery.chd", "ps2 game.chd", "wii game.rvz"],
              "Undo Last Sort puts every file back with its old name, and removes the folders it made", "\(undone) \(afterUndo)")
        check(((try? String(contentsOf: lib2.appendingPathComponent("Star.m3u"), encoding: .utf8)) ?? "") == "Star (Disc 1).chd\nStar (Disc 2).chd\n",
              "the .m3u is back as it was")
        check(RedumpCache.lookup(lib2.appendingPathComponent("dc game.chd"))?.isMatch == true
              && ConversionLog.load()[W.appendingPathComponent("somewhere/dc game.gdi").standardizedFileURL.path]?.first?.hasSuffix("sort-library/dc game.chd") == true,
              "the Redump result and Clean Up Originals' record go back too")
        let ra3Back = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: ra3.appendingPathComponent("Sony - PlayStation 2.lpl")))) as? [String: Any])?["items"] as? [[String: Any]] ?? []
        check(ra3Back.first?["path"] as? String == lib2.appendingPathComponent("ps2 game.chd").standardizedFileURL.path, "RetroArch playlists point back", "\(ra3Back)")
        check(Organize.lastSort() == nil, "there's nothing left to undo")

        // MARK: LibCrypt
        section("LibCrypt .sbi files")
        let sbiGame = workspace("sbi", from: F, ["ps1/PS1 Game (Disc 1).cue", "ps1/PS1 Game (Disc 1).bin"], into: W)
        try! Data("SBI\0libcrypt".utf8).write(to: sbiGame.appendingPathComponent("PS1 Game (Disc 1).sbi"))
        let sbiOut = W.appendingPathComponent("sbi-out"), sbiBack = W.appendingPathComponent("sbi-back")
        c.outputDir = sbiOut
        jobs = await runBatch([sbiGame.appendingPathComponent("PS1 Game (Disc 1).cue")])
        check(sha1(sbiOut.appendingPathComponent("PS1 Game (Disc 1).sbi")) == sha1(sbiGame.appendingPathComponent("PS1 Game (Disc 1).sbi"))
              && jobs.first?.detail.contains("with its .sbi") == true, "the .sbi goes next to the CHD, with the same name", jobs.first?.detail ?? "")
        check(Cleanup.scanSources(in: sbiGame, outputDir: sbiOut, sevenZip: nil).converted.first?.files.contains { $0.pathExtension == "sbi" } == true,
              "Clean Up Originals counts the .sbi as one of the originals")
        c.outputDir = sbiBack
        jobs = await runBatch([sbiOut.appendingPathComponent("PS1 Game (Disc 1).chd")])
        check(exists(sbiBack.appendingPathComponent("PS1 Game (Disc 1).sbi")), "extracting the CHD brings the .sbi back next to the .cue", jobs.first?.detail ?? "")
        let sbiECM = workspace("sbi-ecm", from: F, ["ecm/ECM Game.cue", "ecm/ECM Game.bin.ecm"], into: W)
        try! Data("SBI\0".utf8).write(to: sbiECM.appendingPathComponent("ECM Game.sbi"))
        c.outputDir = sbiOut
        jobs = await runBatch([sbiECM.appendingPathComponent("ECM Game.cue")])
        check(exists(sbiOut.appendingPathComponent("ECM Game.sbi")), "an ECM game's .sbi too", jobs.first?.detail ?? "")
        c.outputDir = nil

        // MARK: Extra copies
        section("Extra copies")
        let ex = W.appendingPathComponent("extra"); try? fm.createDirectory(at: ex.appendingPathComponent("PlayStation"), withIntermediateDirectories: true)
        fakeCHD(ex.appendingPathComponent("game copy 2.chd"), data: 21); fakeCHD(ex.appendingPathComponent("gm.chd"), data: 21)
        check(LibraryReport.keeper(of: [ex.appendingPathComponent("game copy 2.chd"), ex.appendingPathComponent("gm.chd")],
                                   redumpNames: [], checked: [:], datStamp: "").lastPathComponent == "gm.chd", "otherwise the shortest name stays")
        fakeCHD(ex.appendingPathComponent("Real Game (USA).chd"), data: 21)
        check(LibraryReport.keeper(of: [ex.appendingPathComponent("gm.chd"), ex.appendingPathComponent("Real Game (USA).chd")],
                                   redumpNames: ["Real Game (USA)"], checked: [:], datStamp: "").lastPathComponent == "Real Game (USA).chd",
              "the copy named as in Redump stays")
        fakeCHD(ex.appendingPathComponent("PlayStation/x.chd"), data: 21)
        check(LibraryReport.keeper(of: [ex.appendingPathComponent("gm.chd"), ex.appendingPathComponent("PlayStation/x.chd")],
                                   redumpNames: [], checked: [:], datStamp: "").path.hasSuffix("PlayStation/x.chd"), "one in a folder per system beats a shorter name")
        try! "game copy 2.chd\n".write(to: ex.appendingPathComponent("set.m3u"), atomically: true, encoding: .utf8)
        check(LibraryReport.keeper(of: [ex.appendingPathComponent("Real Game (USA).chd"), ex.appendingPathComponent("game copy 2.chd")],
                                   redumpNames: ["Real Game (USA)"], checked: [:], datStamp: "").lastPathComponent == "game copy 2.chd",
              "the copy a playlist lists stays, whatever its name")

        // MARK: Collection against Redump
        section("Collection against Redump")
        let col = W.appendingPathComponent("collection"); try? fm.createDirectory(at: col.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try! fm.copyItem(at: F.appendingPathComponent("chd/game.chd"), to: col.appendingPathComponent("Alpha (USA).chd"))
        try! "FILE \"x.bin\" BINARY\n".write(to: col.appendingPathComponent("sub/Beta (Europe).cue"), atomically: true, encoding: .utf8)
        try! Data().write(to: col.appendingPathComponent("Gamma (Japan).zip"))
        try! fm.copyItem(at: F.appendingPathComponent("chd/game.chd"), to: col.appendingPathComponent("mystery.chd"))
        try! Data().write(to: col.appendingPathComponent("Epsilon (USA).txt"))   // not a game file
        RedumpCache.store(col.appendingPathComponent("mystery.chd"), .match("Delta (USA)"))
        var colIndex = RedumpIndex()
        for (g, sys) in [("Alpha (USA)", "psx"), ("Beta (Europe)", "psx"), ("Delta (USA)", "psx"), ("Epsilon (USA)", "psx"),
                         ("Gamma (Japan)", "ss"), ("Zeta (USA)", "ss"), ("Only (USA)", "dc"), ("Hand Added (USA)", "")] {
            colIndex.trackCount[g] = 1
            if !sys.isEmpty { colIndex.system[g] = sys }
            colIndex.roms[String(repeating: "0", count: 30) + String(format: "%010d", colIndex.roms.count)] = [.init(game: g, name: g + ".bin")]
        }
        try! Data().write(to: col.appendingPathComponent("hand added (usa).iso"))
        let colReport = LibraryReport.build(folder: col, outputDir: nil, sevenZip: nil, log: [:], redump: colIndex, checked: RedumpCache.all()) { _ in }
        let comp = colReport.completeness
        check(comp.map(\.name) == ["DATs you added", "Sega Saturn", "Sony PlayStation"], "systems you have games for are listed (not Dreamcast)", "\(comp.map(\.name))")
        let psxSet = comp.first { $0.id == "psx" }
        check(psxSet?.have.count == 3 && psxSet?.total == 4 && psxSet?.missing == ["Epsilon (USA)"],
              "PlayStation: 3 of 4, by Redump name or remembered match; Epsilon missing", "\(psxSet.map { "\($0.have.keys.sorted()) missing \($0.missing)" } ?? "none")")
        check(psxSet?.have["Delta (USA)"]?.lastPathComponent == "mystery.chd" && psxSet?.have["Beta (Europe)"]?.lastPathComponent == "Beta (Europe).cue",
              "a remembered match counts whatever the file's name; originals in subfolders count")
        check(comp.first { $0.id == "ss" }.map { $0.have.count == 1 && $0.total == 2 } == true, "Saturn: 1 of 2 (a zip named as in Redump counts)")
        check(comp.first { $0.id == "" }?.have.count == 1, "names match whatever their capitals")
        let colCSV = colReport.collectionCSV()
        check(colCSV.contains("Sony PlayStation,Epsilon (USA),Missing,\n") && colCSV.contains("Sega Saturn,Gamma (Japan),Have,/") && colCSV.contains("/collection/Gamma (Japan).zip\n"),
              "the have/missing list saves as CSV", colCSV)
        check(colReport.csv().contains("Redump collection,Sony PlayStation,,have 3 of 4,"), "the report's CSV has each system's count")
        check(LibraryReport.completeness(files: [], index: RedumpIndex(), checked: [:]).isEmpty, "no DATs, no list")

        // MARK: Damaged files
        section("Damaged files")
        let dmg = workspace("damage", from: F, ["chd/game.chd", "chd/bad.chd"], into: W)
        let dolphin = Converter.findTool("dolphin-tool")!
        // A GameCube disc of random data: dolphin-tool stores it uncompressed, so damage to it reads without error
        var randomISO = FileHandle(forReadingAtPath: "/dev/urandom")!.readData(ofLength: 4 << 20)
        randomISO.replaceSubrange(0..<6, with: Data("GTEST2".utf8)); randomISO.replaceSubrange(0x1C..<0x20, with: Data([0xC2, 0x33, 0x9F, 0x3D]))
        let randISO = W.appendingPathComponent("random.iso"); try! randomISO.write(to: randISO)
        func dolphinRVZ(_ iso: URL, _ out: URL) {
            let p = Process(); p.executableURL = dolphin
            p.arguments = ["convert", "-i", iso.path, "-o", out.path, "-f", "rvz", "-c", "zstd", "-l", "5", "-b", "131072"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
        let randRVZ = dmg.appendingPathComponent("random.rvz")
        dolphinRVZ(randISO, randRVZ)
        let rvzData = try! Data(contentsOf: randRVZ)
        try! rvzData.prefix(rvzData.count * 6 / 10).write(to: dmg.appendingPathComponent("cut.rvz"))
        let dc = DamageCheck.shared
        dc.clear(); dc.recheck = false
        dc.add([dmg])
        check(dc.items.map(\.url.lastPathComponent) == ["bad.chd", "cut.rvz", "game.chd", "random.rvz"], "CHDs and RVZs in a folder are added",
              "\(dc.items.map(\.url.lastPathComponent))")
        dc.start(); while dc.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        func dItem(_ n: String) -> DamageCheck.Item? { dc.items.first { $0.url.lastPathComponent == n } }
        func dWhy(_ n: String) -> String { dItem(n).map { "\($0.state) \($0.why ?? "")" } ?? "missing" }
        check(dItem("game.chd")?.state == .ok && dItem("random.rvz")?.state == .ok, "undamaged CHD and RVZ pass", "\(dWhy("game.chd")); \(dWhy("random.rvz"))")
        check(dItem("bad.chd")?.state == .damaged, "a damaged CHD is found", dWhy("bad.chd"))
        check(dItem("cut.rvz")?.state == .damaged, "an RVZ cut short is found", dWhy("cut.rvz"))
        check(DamageRecord.entry(for: randRVZ, in: DamageRecord.all())?.sha1 == sha1(randISO), "the RVZ's disc SHA-1 is remembered")
        check(dc.message.hasPrefix("2 damaged, 2 undamaged."), "summary", dc.message)
        // A second check skips files found undamaged recently, and reads damaged ones again
        dc.clear(); dc.add([dmg]); dc.start(); while dc.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        check(dItem("game.chd")?.remembered != nil && dItem("bad.chd")?.remembered == nil && dItem("bad.chd")?.state == .damaged,
              "files found undamaged recently aren't read again; damaged ones are", dc.message)
        // Damage dolphin-tool can't see: the data changes but the file's size and date don't
        let attrs = try! fm.attributesOfItem(atPath: randRVZ.path)
        let fh = try! FileHandle(forWritingTo: randRVZ); try! fh.seek(toOffset: 300_000); fh.write(Data(repeating: 0x58, count: 16)); try! fh.close()
        try! fm.setAttributes([.modificationDate: attrs[.modificationDate]!], ofItemAtPath: randRVZ.path)
        dc.recheck = true
        dc.clear(); dc.add([randRVZ]); dc.start(); while dc.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        check(dItem("random.rvz")?.state == .damaged && dItem("random.rvz")?.why?.contains("changed since") == true,
              "an RVZ whose disc data changed since its last check is found", dWhy("random.rvz"))
        dc.clear(); dc.add([randRVZ]); dc.start(); while dc.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        check(dItem("random.rvz")?.state == .damaged, "…and still found on the next check")
        dc.recheck = false
        // Against Redump: an RVZ that matched before is compared with Redump's SHA-1
        let good = await DamageCheck.check(dmg.appendingPathComponent("random.rvz"), chdman: c.chdman!, dolphin: dolphin, previous: nil,
                                           redump: ("Rand (USA)", ["0000000000000000000000000000000000000000"]), started: { _ in }, progress: { _ in })
        if case .damaged(let why) = good { check(why.contains("Rand (USA)"), "an RVZ that no longer matches its Redump game is damaged", why) }
        else { check(false, "an RVZ that no longer matches its Redump game is damaged", "\(good)") }
        // The Library Report shows it
        let dmgReport = LibraryReport.build(folder: dmg, outputDir: nil, sevenZip: nil, log: [:], redump: RedumpIndex(), checked: [:],
                                            damageChecks: DamageRecord.all()) { _ in }
        check(dmgReport.damageCheckable.count == 4 && dmgReport.damageChecked == 4
              && dmgReport.damaged.map(\.url.lastPathComponent).sorted() == ["bad.chd", "cut.rvz", "random.rvz"],
              "the Library Report counts checked and damaged files", "\(dmgReport.damageChecked) \(dmgReport.damaged.map(\.url.lastPathComponent))")
        check(dmgReport.csv().contains("Damaged,bad.chd,"), "…and lists them in its CSV")
        // A result follows its file when it's renamed
        DamageRecord.move(dmg.appendingPathComponent("game.chd"), to: dmg.appendingPathComponent("Game (USA).chd"))
        try! fm.moveItem(at: dmg.appendingPathComponent("game.chd"), to: dmg.appendingPathComponent("Game (USA).chd"))
        check(DamageRecord.entry(for: dmg.appendingPathComponent("Game (USA).chd"), in: DamageRecord.all())?.damaged == false, "a result follows a renamed file")
        dc.clear()

        // MARK: Watch folder
        section("Watch folder")
        let wf = WatchFolder.shared, watched = W.appendingPathComponent("watched")
        try? fm.createDirectory(at: watched.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try! fm.copyItem(at: F.appendingPathComponent("plain.iso"), to: watched.appendingPathComponent("old.iso"))
        c.clearAll(); c.clearAddedPatches()
        wf.interval = 3600; wf.settle = 0; wf.autoStart = false
        wf.folder = watched; wf.enabled = true
        check(wf.isWatching, "watching")
        try! fm.copyItem(at: F.appendingPathComponent("ps1.iso"), to: watched.appendingPathComponent("sub/new.iso"))
        try! fm.copyItem(at: F.appendingPathComponent("patch/Base (English).xdelta"), to: watched.appendingPathComponent("Base (English).xdelta"))
        try! "FILE \"half.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n".write(to: watched.appendingPathComponent("half.cue"), atomically: true, encoding: .utf8)
        wf.look()
        check(c.jobs.isEmpty, "a new file isn't added until it's stopped changing")
        wf.look()
        check(c.jobs.map(\.url.lastPathComponent) == ["new.iso"], "a new game (in a subfolder) is added; one already there isn't", "\(c.jobs.map(\.url.lastPathComponent))")
        check(c.addedPatches.map(\.lastPathComponent) == ["Base (English).xdelta"], "a new patch goes into the patches box")
        try! fm.copyItem(at: F.appendingPathComponent("cd/game.bin"), to: watched.appendingPathComponent("half.bin"))
        wf.look(); wf.look()
        check(c.jobs.contains { $0.url.lastPathComponent == "half.cue" } && c.jobs.first { $0.url.lastPathComponent == "half.cue" }?.state == .queued,
              "a .cue waits for its .bin to arrive")
        wf.enabled = false
        check(!wf.isWatching, "stops watching when turned off")
        c.clearAll(); c.clearAddedPatches(); wf.folder = nil

        // MARK: CSO / ZSO
        section("CSO and ZSO (maxcso)")
        check(Converter.findTool("maxcso") != nil, "maxcso found")
        c.outputFormat = .cso; c.verify = true
        let cso = workspace("cso", from: F, ["psp.iso", "ps2.iso", "cd/game.cue", "cd/game.bin"], into: W)
        let csoCHD = workspace("cso-chd", from: F, ["chd/ps2.chd"], into: W)
        c.clearAll(); c.add([cso])
        check(Set(c.jobs.map(\.url.lastPathComponent)) == ["psp.iso", "ps2.iso", "game.cue"], "making CSO/ZSO, a folder scan picks up the games")
        jobs = await runBatch([cso.appendingPathComponent("psp.iso"), cso.appendingPathComponent("ps2.iso"), cso.appendingPathComponent("game.cue"),
                               csoCHD.appendingPathComponent("ps2.chd")])
        var unpackNote = ""
        func unpacked(_ f: URL) -> String? {
            let out = W.appendingPathComponent("cso-check-\(UUID().uuidString).iso")
            defer { try? fm.removeItem(at: out) }
            let p = Process(); p.executableURL = Converter.findTool("maxcso"); p.arguments = ["--decompress", f.path, "-o", out.path]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            do { try p.run() } catch { unpackNote = "couldn't run maxcso: \(error)"; return nil }
            let said = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            unpackNote = "maxcso exit \(p.terminationStatus), \(Int(totalSize([out]))) bytes: \(said.suffix(300))"
            return sha1(out)
        }
        check(job(jobs, "psp.iso")?.state == .done && unpacked(cso.appendingPathComponent("psp.cso")) == sha1(F.appendingPathComponent("psp.iso")),
              "a PSP ISO becomes a CSO holding the same ISO", (job(jobs, "psp.iso")?.detail ?? "") + " / " + unpackNote)
        check(job(jobs, "ps2.iso")?.state == .done && unpacked(cso.appendingPathComponent("ps2.zso")) == sha1(F.appendingPathComponent("ps2.iso"))
              && job(jobs, "ps2.iso")?.detail.contains("verified") == true, "a PS2 ISO becomes a ZSO (for OPL), verified", (job(jobs, "ps2.iso")?.detail ?? "") + " / " + unpackNote)
        check(job(jobs, "ps2.chd")?.state == .done && unpacked(csoCHD.appendingPathComponent("ps2.zso")) == sha1(F.appendingPathComponent("ps2.iso")),
              "a DVD CHD is unpacked and becomes a ZSO", job(jobs, "ps2.chd")?.detail ?? "")
        check(job(jobs, "game.cue")?.state == .failed && job(jobs, "game.cue")?.detail.contains("CD image") == true,
              "a CD image (BIN/CUE) is refused with a reason", job(jobs, "game.cue")?.detail ?? "")
        c.csoFormat = .cso
        let cso2 = workspace("cso-always", from: F, ["ps2.iso"], into: W)
        jobs = await runBatch([cso2.appendingPathComponent("ps2.iso")])
        check(exists(cso2.appendingPathComponent("ps2.cso")), "“Always CSO” makes a CSO even for a PS2 game")
        c.csoFormat = .automatic; c.outputFormat = .chd; c.verify = false
        c.clearAll()


        // MARK: Pause and the saved queue
        section("Pause, Resume and the saved queue")
        let pz = W.appendingPathComponent("pause"); try? fm.createDirectory(at: pz, withIntermediateDirectories: true)
        for n in 1...3 {
            try! fm.copyItem(at: F.appendingPathComponent("cd/game.bin"), to: pz.appendingPathComponent("p\(n).bin"))
            try! "FILE \"p\(n).bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n"
                .write(to: pz.appendingPathComponent("p\(n).cue"), atomically: true, encoding: .utf8)
        }
        c.clearAll(); c.add([pz]); c.start()
        while !c.jobs.contains(where: { $0.state == .working }) { try? await Task.sleep(for: .milliseconds(10)) }
        c.pause()
        while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(c.isPaused && c.batchDoneCount == 1 && c.batchQueuedCount == 2, "Pause stops after the current file",
              "paused \(c.isPaused), done \(c.batchDoneCount), waiting \(c.batchQueuedCount)")
        let saved = Converter.loadQueue(from: Converter.queueFile)
        check(saved.count == 3 && saved.filter { $0.state == .queued }.count == 2, "the list is saved as it changes")
        c.start()
        while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(!c.isPaused && c.batchDoneCount == 3 && c.batchJobs.count == 3, "Resume finishes the same batch")

        let slow = workspace("slow", from: F, ["slow/slow.cue", "slow/slow.bin"], into: W)
        c.clearAll(); c.add([slow.appendingPathComponent("slow.cue")]); c.start()
        while c.jobs.first?.progress ?? 0 < 0.01 && c.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
        c.pause(now: true)
        while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(c.isPaused && c.jobs.first?.state == .queued && !exists(slow.appendingPathComponent("slow.chd")),
              "Pause Now puts the file back and deletes its unfinished CHD", c.jobs.first?.detail ?? "")
        c.cancel()
        check(!c.isPaused && c.batchEnd != nil, "Cancel ends a paused batch")

        // A list saved while a file was converting comes back with that file waiting again.
        let qf = W.appendingPathComponent("queue-test.json")
        let fake = [Converter.SavedJob(path: "/a.cue", state: "done", detail: "a.chd", weight: 1, bytesIn: 0, bytesOut: 0, outputs: []),
                    Converter.SavedJob(path: "/b.cue", state: "working", detail: "Compressing — 40%", weight: 1, bytesIn: 0, bytesOut: 0, outputs: [])]
        try! JSONEncoder().encode(fake).write(to: qf)
        let back = Converter.loadQueue(from: qf)
        check(back.map(\.state) == [.done, .queued] && back[1].detail.contains("interrupted"), "an interrupted file is waiting again after a restart")

        // A file that's gone (drive unplugged) fails with a clear message
        let gone = W.appendingPathComponent("gone/away.iso")
        c.clearAll(); c.jobs = [Job(url: gone)]; c.start()
        while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(c.jobs.first?.detail.contains("Can't find the file") == true, "missing file says to connect the drive", c.jobs.first?.detail ?? "")

        // MARK: Free space
        section("Free space")
        check(Converter.logicalSize("Logical size: 1,411,200 bytes") == 1_411_200, "reads chdman's logical size")
        DiskSpace.override = { _ in 1_000_000 }   // pretend every disk has 1 MB free
        let full = workspace("full", from: F, ["cd/game.cue", "cd/game.bin"], into: W)
        c.clearAll(); c.add([full.appendingPathComponent("game.cue")])
        check(c.batchSpaceWarning()?.contains("may need up to") == true, "warns before starting a batch that may not fit")
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(c.jobs.first?.state == .failed && c.jobs.first?.detail.contains("Not enough free space") == true,
              "a file that won't fit fails before starting", c.jobs.first?.detail ?? "")
        check(!exists(full.appendingPathComponent("game.chd")), "nothing written")
        let tight = await CHDCheck.check(F.appendingPathComponent("chd/game.chd"), chdman: c.chdman!, index: db.index,
                                         started: { _ in }, progress: { _ in })
        if case .failure(let e) = tight { check(e.message.contains("to unpack it"), "CHD check warns when there's no room to unpack") }
        else { check(false, "CHD check warns when there's no room to unpack") }
        DiskSpace.override = nil
        check(c.batchSpaceWarning() == nil, "no warning when there's room")
        c.clearAll()

        // MARK: Diagnostic info
        section("Diagnostic info")
        check(Diagnostics.versionPart("chdman 0.289, built from the unmodified source of MAME 0.289:") == "chdman 0.289"
              && Diagnostics.versionPart("7-Zip 26.06 by Igor Pavlov (https://www.7-zip.org), the official") == "7-Zip 26.06"
              && Diagnostics.versionPart("dolphin-tool from Dolphin 2609b, built from the unmodified source:") == "dolphin-tool from Dolphin 2609b"
              && Diagnostics.versionPart("PSXPackager v1.8.0 by RupertAvery (https://github.com/RupertAvery/PSXPackager), the") == "PSXPackager v1.8.0",
              "tool versions read from their SOURCE.txt")
        c.append("converted \(NSHomeDirectory())/Games/Test.cue")
        let diag = Diagnostics.report()
        check(diag.hasPrefix("Converterator ") && diag.contains("\nmacOS ") && diag.contains("chdman: ") && diag.contains("7-Zip: ")
              && diag.contains("Settings\n") && diag.contains("Recent log (last") && !diag.contains("macOS Version"), "the report has versions, tools, settings and the log")
        check(!diag.contains(NSHomeDirectory()) && diag.contains("~/Games/Test.cue"), "your home folder is shortened to ~")

        // MARK: Updater
        section("Updater checks")
        let zip = repo.appendingPathComponent("dist/Converterator.zip")
        let installed = url("/Applications/Converterator.app")
        if exists(zip), exists(installed), let team = UpdateChecker.teamID(ofCodeAt: installed) {
            check(UpdateChecker.validSignature(installed, teamID: team) && !UpdateChecker.validSignature(installed, teamID: "ABCDE12345"),
                  "signature check accepts the right team only")
            let target = W.appendingPathComponent("upd/Converterator.app")
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: installed, to: target)
            let version = { (NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String) ?? "?" }
            let before = version()
            // The version inside the zip, from its Info.plist
            let unzip = Process(); unzip.executableURL = url("/usr/bin/unzip")
            unzip.arguments = ["-p", zip.path, "Converterator.app/Contents/Info.plist"]
            let pipe = Pipe(); unzip.standardOutput = pipe; try? unzip.run()
            let plist = pipe.fileHandleForReading.readDataToEndOfFile(); unzip.waitUntilExit()
            let zipVersion = ((try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any])?["CFBundleShortVersionString"] as? String ?? "?"
            do { try UpdateChecker.installUpdate(zip: zip, expectedVersion: "0.0.1", teamID: team, replacing: target); check(false, "wrong version refused") }
            catch { check(version() == before, "wrong version refused, app untouched") }
            do { try UpdateChecker.installUpdate(zip: zip, expectedVersion: zipVersion, teamID: team, replacing: target)
                 check(version() == zipVersion, "signed release installs over a copy", "now \(version())") }
            catch { check(false, "signed release installs over a copy", error.localizedDescription) }
        } else {
            print("  – skipped (needs dist/Converterator.zip from notarize.sh and a signed app in /Applications)")
        }

        // MARK: Network
        if network {
            section("redump.org download")
            do {
                let name = try await RedumpDB.fetch(slug: "psx", haveName: nil, haveFile: false)
                let idx = RedumpDB.load(RedumpDB.storedDAT("psx"))
                check((idx?.gameCount ?? 0) > 1000, "PlayStation DAT downloaded and read", "\(name ?? "nil"), \(idx?.gameCount ?? 0) games")
                let again = try await RedumpDB.fetch(slug: "psx", haveName: name, haveFile: true)
                check(again == nil, "not downloaded again when unchanged")
            } catch { check(false, "download from redump.org", "\(error)") }
        }

        print("\n\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
