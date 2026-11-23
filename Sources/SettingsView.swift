// Converterator — The Settings window.
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import CryptoKit

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject private var c = Converter.shared
    @ObservedObject private var redump = RedumpDB.shared
    @ObservedObject private var patches = PatchLibrary.shared
    @ObservedObject private var watch = WatchFolder.shared

    var body: some View {
        Form {
            Section("Finder") {
                Toggle("Start converting right away", isOn: $c.startFromFinder)
                Text("For files sent with Convert with Converterator in Finder's right-click menu (under Quick Actions or Services). Turned off, they're just added to the list.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Watch folder") {
                HStack {
                    Text("Folder:")
                    Text(watch.folder?.path(percentEncoded: false) ?? "None")
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("Choose…", action: chooseWatchFolder)
                    if watch.folder != nil { Button("Clear") { watch.folder = nil } }
                }
                Toggle("Watch it for new games", isOn: $watch.enabled).disabled(watch.folder == nil)
                Toggle("Start converting as soon as one arrives", isOn: $watch.autoStart).disabled(watch.folder == nil || !watch.enabled)
                Text("While Converterator is open, disc images, archives and ECM files that land in this folder (or one level of folders inside it) are added to the list once they've finished downloading. Patches go into the patches box. Files already there when watching starts are left alone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Folders per system") {
                Picker("Folder names:", selection: $c.systemFolderStyle) {
                    ForEach(SystemFolderStyle.allCases) { Text($0.label).tag($0) }
                }
                Text("With “Sort into a folder per system” on in the main window, each game is saved in a folder for its console. The console comes from the game's Redump match, or from the disc itself (PlayStation, PS2, PSP, Saturn, Sega CD, Dreamcast, PC Engine CD, PC-FX, 3DO, Neo Geo CD, CD-i, CD32, GameCube, Wii and Xbox can be told apart).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("RetroArch") {
                Toggle("Add converted games to RetroArch playlists", isOn: $c.retroArchPlaylists)
                HStack {
                    Text("Playlists folder:")
                    Text(c.retroArchPlaylistFolder.path(percentEncoded: false))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("Choose…", action: chooseRetroArchFolder)
                    if c.retroArchFolder != nil { Button("Default") { c.retroArchFolder = nil } }
                }
                Text("Each game goes into the playlist for its system (for example “Sony - PlayStation”), so it shows up in RetroArch without a scan, with thumbnails when it has its Redump name. A multi-disc game goes in through its .m3u. File → Library Report… can add games you converted before.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Patches") {
                HStack {
                    Text("Patches folder:")
                    Text(patches.folder?.path(percentEncoded: false) ?? "None")
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("Choose…", action: choosePatchesFolder)
                    if patches.folder != nil { Button("Clear") { patches.folder = nil } }
                }
                Toggle("Find patches for games automatically", isOn: $patches.enabled)
                    .disabled(patches.folder == nil)
                Text("Keep your patches in one folder, loose or still in their download zips. Each game you add gets the patch made for it: BPS and PPF patches are matched by checksum, xdelta and IPS patches by the game's name (preferring \(PatchLibrary.preferredLanguage ?? "your language") when there are several). If a patch matched by name doesn't fit, the game is converted without it. \(patches.folder == nil ? "" : "\(patches.patchCount) patch\(patches.patchCount == 1 ? "" : "es") in the folder.")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Redump") {
                Text("Redump lists the checksums of known good disc dumps. With its DAT files loaded, each BIN/CUE, GDI or ISO is checked before it's converted, and File → Check Against Redump… checks CHDs and GameCube/Wii RVZs you already have (turn on GameCube and Wii below for RVZs). PBPs can't be checked.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Check dumps while converting", isOn: $redump.enabled)
                Toggle("Name CHDs after the matching Redump game", isOn: $redump.renameToRedump)
                Text("For example “Armored Core (USA).chd” instead of “armored core.chd”. Only for dumps that match.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("With “Move source files to Trash” on, keep the originals of dumps that don't match", isOn: $redump.keepUnmatched)
            }
            Section("Redump DAT files") {
                Toggle("Download from redump.org automatically", isOn: $redump.autoDownload)
                Text("Checked when Converterator opens, at most once a day. Only newer DATs are downloaded. redump.org only offers plain HTTP.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Systems (\(redump.systems.count))") {
                    ForEach(RedumpDB.systems, id: \.slug) { sys in
                        Toggle(isOn: Binding(
                            get: { redump.systems.contains(sys.slug) },
                            set: { on in if on { redump.systems.insert(sys.slug) } else { redump.systems.remove(sys.slug) } })) {
                            HStack {
                                Text(sys.name)
                                Spacer()
                                if let dat = redump.dats.first(where: { $0.system == sys.slug }) {
                                    Text("\(dat.games) games\(redump.datDate(sys.slug).map { ", \($0)" } ?? "")")
                                        .foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                    }
                }
                HStack {
                    if redump.isDownloading { ProgressView().controlSize(.small) }
                    Text(redump.downloadStatus.isEmpty ? "Not checked yet." : redump.downloadStatus)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { redump.updateFromWeb(force: true) }
                        .disabled(!redump.autoDownload || redump.isDownloading)
                }
                let own = redump.dats.filter { $0.system == nil }
                ForEach(own) { dat in
                    HStack {
                        Text(dat.url.deletingPathExtension().lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(dat.games) games").foregroundStyle(.secondary).monospacedDigit()
                        Button("Remove") { redump.remove(dat) }
                    }
                }
                if redump.isLoading { HStack { ProgressView().controlSize(.small); Text("Reading DAT files…") } }
                if let err = redump.lastError { Text(err).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Text("\(redump.index.gameCount) games loaded").foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Your Own DAT Files…", action: addDATs)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 520)
    }

    private func chooseWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Watch"
        panel.message = "Choose a folder to watch for new games, such as Downloads"
        if panel.runModal() == .OK, let url = panel.url { watch.folder = url; watch.enabled = true }
    }

    private func chooseRetroArchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = c.retroArchPlaylistFolder
        panel.message = "Choose RetroArch's playlists folder (in RetroArch: Settings → Directory → Playlists)"
        if panel.runModal() == .OK, let url = panel.url { c.retroArchFolder = url }
    }

    private func choosePatchesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder where you keep your patches (subfolders and zips are included)"
        let done: (NSApplication.ModalResponse) -> Void = { if $0 == .OK, let url = panel.url { patches.folder = url } }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    private func addDATs() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ["dat", "xml", "zip"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose Redump DAT files (.dat, or the .zip they're downloaded as)"
        let done: (NSApplication.ModalResponse) -> Void = { if $0 == .OK { redump.add(panel.urls) } }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }
}
