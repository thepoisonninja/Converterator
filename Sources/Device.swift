// "Copy finished games to:" an SD card, a Steam Deck share or any folder, after each game is converted.
import Foundation

extension Converter {
    /// Where `file` goes on the device: in the same system folder it's in here, when games are sorted that way.
    nonisolated static func deviceDestination(for file: URL, in device: URL) -> URL {
        let parent = file.deletingLastPathComponent().lastPathComponent
        let dir = Systems.folderNames.contains(parent) ? device.appendingPathComponent(parent, isDirectory: true) : device
        return dir.appendingPathComponent(file.lastPathComponent)
    }

    /// Copies a finished game's files (CHDs, RVZ, playlist, PBP…) to the device folder, skipping ones already
    /// there at the same size. Returns a few words for the job's summary, or nil when copying is off.
    func copyToDevice(_ files: [URL], id: UUID?) async -> String? {
        guard let device = copyDestination, !files.isEmpty else { return nil }
        let fm = FileManager.default
        let place = DiskSpace.volumeName(device)
        guard fm.fileExists(atPath: device.path) else {
            append("  not copied: \(device.path) isn't there (is the card or drive connected?)")
            return "not copied: \(place) isn't connected"
        }
        let pairs = files.filter { fm.fileExists(atPath: $0.path) }.map { ($0, Converter.deviceDestination(for: $0, in: device)) }
        let todo = pairs.filter { totalSize([$0.1]) != totalSize([$0.0]) }
        if todo.isEmpty {
            append("  already on \(place)")
            return "already on \(place)"
        }
        let needed = todo.reduce(0.0) { $0 + totalSize([$1.0]) - totalSize([$1.1]) }
        if let free = DiskSpace.free(at: device), free < needed + DiskSpace.margin {
            append("  not copied: \(place) has \(formatBytes(free)) free and this needs \(formatBytes(needed))")
            return "not copied: not enough space on \(place)"
        }
        if let id { update(id) { $0.detail = "Copying to \(place)…"; $0.progress = nil } }
        let failure: String? = await Task.detached {
            for (from, to) in todo {
                do {
                    try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    // Copy under a temporary name, then rename: an unplugged card never ends up with half a game.
                    let partial = to.deletingLastPathComponent().appendingPathComponent(".converterator-partial-" + to.lastPathComponent)
                    try? fm.removeItem(at: partial)
                    try fm.copyItem(at: from, to: partial)
                    if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                    try fm.moveItem(at: partial, to: to)
                } catch {
                    return "\(from.lastPathComponent): \(error.localizedDescription)"
                }
            }
            return nil
        }.value
        if let failure {
            append("  couldn't copy to \(place): \(failure)")
            return "not copied to \(place)"
        }
        append("  copied \(todo.count == 1 ? todo[0].0.lastPathComponent : "\(todo.count) files") to \(device.path)")
        return "copied to \(place)"
    }
}
