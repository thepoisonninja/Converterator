// Converterator — Multi-disc names and .m3u playlists.
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import CryptoKit

// MARK: - Multi-disc playlists

/// Recognises the disc number in a file name: "Game (USA) (Disc 2)", "Game (Disc 2 of 3)",
/// "Game - Disc 2" (how PSXPackager names discs), "Game CD2".
struct DiscName: Hashable, Sendable {
    let key: String     // the name without the disc part, e.g. "Game (USA)"
    let disc: Int
    let of: Int?        // from "(Disc 2 of 3)", if given

    nonisolated static func parse(_ name: String) -> DiscName? {
        let patterns = [
            #"\s*\((?:Disc|Disk|CD)\s*(\d{1,2})(?:\s*of\s*(\d{1,2}))?\)"#,     // (Disc 2) / (Disc 2 of 3), anywhere
            #"\s*[-_]\s*(?:Disc|Disk|CD)\s*(\d{1,2})(?:\s*of\s*(\d{1,2}))?$"#, // " - Disc 2" at the end
            #"\s+(?:Disc|Disk|CD)\s*(\d{1,2})(?:\s*of\s*(\d{1,2}))?$"#,        // " Disc 2" / " CD2" at the end
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let whole = Range(m.range, in: name), let n = Range(m.range(at: 1), in: name),
                  let disc = Int(name[n]), disc >= 1 else { continue }
            let of = Range(m.range(at: 2), in: name).flatMap { Int(name[$0]) }
            var key = name
            key.removeSubrange(whole)
            key = key.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
            while key.hasSuffix("-") || key.hasSuffix("_") { key = String(key.dropLast()).trimmingCharacters(in: .whitespaces) }
            guard !key.isEmpty else { continue }
            return DiscName(key: key, disc: disc, of: of)
        }
        return nil
    }
}

enum Playlist {
    /// Multi-disc CHD (or RVZ) sets in one folder: playlist name → its files in disc order. Only sets with 2+ discs.
    nonisolated static func sets(in dir: URL) -> [String: [URL]] {
        let chds = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["chd", "rvz"].contains($0.pathExtension.lowercased()) }   // (Dolphin reads .m3u too)
        var groups: [String: [(Int, URL)]] = [:]
        for chd in chds {
            guard let d = DiscName.parse(chd.deletingPathExtension().lastPathComponent) else { continue }
            groups[d.key, default: []].append((d.disc, chd))
        }
        return groups.filter { Set($0.value.map(\.0)).count >= 2 }
            .mapValues { $0.sorted { $0.0 < $1.0 }.map(\.1) }
    }

    /// The CHD names each .m3u in `dir` lists.
    nonisolated static func existing(in dir: URL) -> [URL: [String]] {
        let m3us = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "m3u" }
        var result: [URL: [String]] = [:]
        for m in m3us {
            guard let text = try? String(contentsOf: m, encoding: .utf8) else { continue }
            result[m] = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        return result
    }

    /// Writes `Name.m3u` for each multi-disc set in `dir` that doesn't have one. A set counts as having
    /// one if any .m3u there already lists any of its discs; if that's its own `Name.m3u` and it's
    /// missing a disc we now have (Disc 3 converted later), it's brought up to date. Other people's
    /// playlists are never changed. `only` limits it to sets containing one of those CHDs.
    /// Returns the playlists written.
    @discardableResult
    nonisolated static func make(in dir: URL, only: Set<URL>? = nil) -> [URL] {
        let have = existing(in: dir)
        var written: [URL] = []
        for (key, discs) in sets(in: dir) {
            if let only, !discs.contains(where: { only.contains($0.standardizedFileURL) }) { continue }
            let names = discs.map(\.lastPathComponent)
            let target = dir.appendingPathComponent(Converter.safeFileName(key) + ".m3u")
            let mentioning = have.filter { !Set($0.value).isDisjoint(with: names) }
            if let current = mentioning[target] {
                // Ours (same name): update only if it lists nothing but this set's discs and is missing some.
                guard Set(current).isSubset(of: Set(names)), current != names else { continue }
            } else if !mentioning.isEmpty {
                continue   // another playlist already covers these discs (e.g. one written for a PBP)
            } else if FileManager.default.fileExists(atPath: target.path) {
                continue   // a playlist with this name lists something else; leave it alone
            }
            let body = names.joined(separator: "\n") + "\n"
            if (try? body.write(to: target, atomically: true, encoding: .utf8)) != nil { written.append(target) }
        }
        return written
    }

    /// Sets in `dir` that have no playlist yet.
    nonisolated static func missing(in dir: URL) -> [(name: String, discs: [URL])] {
        let have = existing(in: dir).values.flatMap { $0 }
        let listed = Set(have)
        return sets(in: dir)
            .filter { _, discs in discs.allSatisfy { !listed.contains($0.lastPathComponent) } }
            .map { (name: $0.key, discs: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
