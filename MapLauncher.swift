// VERA20K map launcher — a thin SwiftUI shell over the validated `map-tool` CLI.
// Every engine rule (INI parsing, mission titles, briefing text, preview decode,
// spawn.ini) stays in Rust; this window only browses and launches.

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

struct PackRef: Hashable {
    let archive: String
    let id: Int32
}

struct MapEntry: Identifiable, Hashable {
    let path: String
    let group: String
    let name: String
    let author: String
    let width: Int
    let height: Int
    let theater: String
    let hasPreview: Bool
    let starts: Int
    /// Set for a map packed inside a retail MIX archive: extraction happens at
    /// launch time, so the entry needs its archive and hashed id.
    var pack: PackRef? = nil
    /// Section order: lower groups come first (allied before soviet, …).
    var order: Int = 0
    /// Mission id from the map itself (RA2) or its section name (YR).
    var mission: String = ""
    /// Which tables this row reads: `ra2`, `yr`, `mod` or `pack`.
    var source: String = "mod"
    /// A MIX entry with no `[Basic] Name=` and no mission section: retail packs
    /// store these under hash ids only, so the list shows "map #<id>".
    var isUnnamedPackMap: Bool { pack != nil && (name.isEmpty || name.hasPrefix("map #")) }

    var id: String { path }
    var displayName: String { name.isEmpty ? (path as NSString).lastPathComponent : name }
    var subtitle: String {
        var parts = ["\(width)×\(height)", theater]
        if !author.isEmpty { parts.append(author) }
        return parts.joined(separator: "  ·  ")
    }
}

/// Pack rows from `map-tool mix`, which shares the list columns plus id/archive.
func parsePackRows(_ text: String) -> [MapEntry] {
    var entries: [MapEntry] = []
    var first = true
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        if first {
            first = false
            if line.hasPrefix("group\t") { continue }
        }
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 9, let id = Int32(f[7]) else { continue }
        let size = f[3].split(separator: "x").compactMap { Int($0) }
        guard size.count == 2 else { continue }
        let archive = f[8]
        let archiveName = (archive as NSString).lastPathComponent
        let name = f[1].isEmpty ? "map #\(id)" : f[1]
        entries.append(MapEntry(
            path: archive + "#\(id)",
            group: archiveName,
            name: name,
            author: f[2],
            width: size[0],
            height: size[1],
            theater: f[4],
            hasPreview: f[5] == "yes",
            starts: Int(f[6]) ?? 0,
            pack: PackRef(archive: archive, id: id),
            source: "pack"
        ))
    }
    return entries
}

/// Rows come from `map-tool list`; this keeps one parser in the tree, in Rust.
func parseToolRows(_ text: String) -> [MapEntry] {
    var entries: [MapEntry] = []
    var first = true
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        if first {
            first = false
            if line.hasPrefix("group\t") { continue }
        }
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 8 else { continue }
        let size = f[3].split(separator: "x").compactMap { Int($0) }
        guard size.count == 2 else { continue }
        entries.append(MapEntry(
            path: f[7],
            group: f[0].isEmpty ? "maps" : f[0],
            name: f[1],
            author: f[2],
            width: size[0],
            height: size[1],
            theater: f[4],
            hasPreview: f[5] == "yes",
            starts: Int(f[6]) ?? 0,
            mission: f.count > 8 ? f[8] : "",
            source: "mod"
        ))
    }
    return entries
}

// MARK: - Runner

@MainActor
final class Launcher: ObservableObject {
    @Published var maps: [MapEntry] = []
    @Published var selected: MapEntry?
    @Published var preview: NSImage?
    @Published var generatingPreview = false
    @Published var briefing = ""
    @Published var fullscreen = UserDefaults.standard.bool(forKey: "fullscreen")
    /// Off by default: hash-named pack entries carry no title, so they only add
    /// noise to the list.
    @Published var showUnnamedPacks = UserDefaults.standard.bool(forKey: "showUnnamedPacks")
    /// Off by default: the original RA2 chapters load but their mission scripts
    /// do not run correctly under the YR-derived campaign state yet.
    @Published var showRa2Chapters = UserDefaults.standard.bool(forKey: "showRa2Chapters")
    @Published var status = "Ready"
    @Published var roots: [String] = []

    private let defaults = UserDefaults.standard
    /// `map-tool` from a vera20k checkout: `VERA20K_MAP_TOOL` wins, otherwise the
    /// path this build recorded, otherwise a PATH-style default.
    private var toolPath: String {
        if let override = ProcessInfo.processInfo.environment["VERA20K_MAP_TOOL"], !override.isEmpty {
            return override
        }
        if let saved = defaults.string(forKey: "toolPath"), !saved.isEmpty {
            return saved
        }
        return "/usr/local/bin/map-tool"
    }
    /// Retail game folder, used only when the library has no mission metadata.
    private var ra2Dir: String {
        ProcessInfo.processInfo.environment["VERA20K_GAME_DIR"]
            ?? defaults.string(forKey: "ra2Dir")
            ?? ""
    }
    private var dataDir: String {
        NSHomeDirectory() + "/Library/Application Support/VERA20k"
    }
    /// Launcher-owned library, populated once so the window never has to read a
    /// TCC-protected folder (macOS blocks the first access in the kernel).
    private var libraryDir: String {
        ProcessInfo.processInfo.environment["VERA20K_LAUNCHER_LIBRARY"]
            ?? NSHomeDirectory() + "/Library/Application Support/VERA20K-Maps"
    }
    private var missionIni: String { libraryDir + "/meta/MISSIONMD.INI" }
    private var campaignDir: String { libraryDir + "/campaign" }
    private var ra2CampaignDir: String { libraryDir + "/ra2-campaign" }
    private var baseMissionIni: String { libraryDir + "/meta-base/MISSIONMD.INI" }
    private var baseCsf: String { libraryDir + "/meta-base/ra2md.csf" }
    private var ra2Csf: String { libraryDir + "/meta-ra2/ra2.csf" }
    private var previewDir: String { libraryDir + "/previews" }

    /// Which asset root a launch should use. Official chapters run against the
    /// plain base install; only mod maps get the overlay, because the overlay's
    /// `ra2md.csf` replaces the official mission text.
    private func assetRoot(for entry: MapEntry) -> String {
        let overlay = libraryDir + "/base-mod"
        let base = libraryDir + "/base"
        if entry.source == "mod", FileManager.default.fileExists(atPath: overlay) {
            return overlay
        }
        return base
    }

    /// Cached radar render for a map. One file per map path, so a second visit
    /// is instant; the render itself costs a game launch.
    private func previewCachePath(for entry: MapEntry) -> String {
        let name = entry.mission.isEmpty
            ? (entry.path as NSString).lastPathComponent
            : entry.mission
        return previewDir + "/" + entry.source + "_"
            + name.replacingOccurrences(of: "/", with: "_") + ".png"
    }
    private var csfPath: String { libraryDir + "/meta/ra2md.csf" }

    /// Retail map packs, read from the library copy for the same reason.
    private var packArchives: [String] {
        ["mapsmd03.mix", "multimd.mix"].map { libraryDir + "/packs/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Mission-metadata arguments: the library copy when present, otherwise the
    /// game folder (which needs a one-time macOS approval).
    private var missionArguments: [String] {
        if FileManager.default.fileExists(atPath: missionIni) {
            return ["--mission-ini", missionIni, "--csf", csfPath]
        }
        return ["--ra2-dir", ra2Dir]
    }

    var groups: [String] {
        var orderOf: [String: Int] = [:]
        for entry in maps {
            orderOf[entry.group] = min(orderOf[entry.group] ?? Int.max, entry.order)
        }
        return orderOf.keys
            .filter { !$0.hasPrefix("原版战役 · 训练") && !$0.hasPrefix("原版战役 · 其他") }
            .filter { showRa2Chapters || !$0.hasPrefix("原版战役") }
            .sorted {
            let a = orderOf[$0] ?? 0, b = orderOf[$1] ?? 0
            return a == b ? $0 < $1 : a < b
        }
    }

    func maps(in group: String) -> [MapEntry] {
        maps.filter { $0.group == group }
            .filter { !$0.group.hasPrefix("原版战役 · 训练") }
            .filter { showUnnamedPacks || !$0.isUnnamedPackMap }
            .sorted {
                if $0.order != $1.order { return $0.order < $1.order }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    init() {
        // Never touch a TCC-protected folder (Downloads/Documents/Desktop) before
        // the user has picked one: the first access can block in the kernel
        // while macOS waits for an approval the user never sees.
        let saved = defaults.stringArray(forKey: "roots") ?? []
        let library = libraryDir + "/maps"
        if saved.isEmpty, FileManager.default.fileExists(atPath: library) {
            roots = [library]
        } else {
            roots = saved
        }
        if roots.isEmpty {
            status = "点击 Add Folder… 选择地图目录"
        } else {
            rescan()
        }
    }

    /// Merge a scan result into the library. Sources overlap (a folder and its
    /// parent) and arrive in any order, so the path is the identity.
    /// User folders sort after the built-in campaigns, oldest first, so a newly
    /// added directory appears at the bottom where the player expects it.
    private func folderOrder(for group: String) -> Int {
        for root in roots where (root as NSString).lastPathComponent == group {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: root),
               let created = attributes[.creationDate] as? Date {
                return 100_000 + Int(created.timeIntervalSince1970 / 3600)
            }
        }
        return 100_000
    }

    private func merge(_ entries: [MapEntry]) {
        var byPath = Dictionary(uniqueKeysWithValues: maps.map { ($0.path, $0) })
        // Retail ships each campaign mission twice (Maps01 and Maps02), so a
        // repeated (group, mission) pair keeps only its first copy.
        var seenMission: [String: String] = [:]
        for entry in byPath.values where !entry.mission.isEmpty {
            let key = entry.group + "\u{1F}" + entry.mission
            seenMission[key] = seenMission[key] ?? entry.path
        }
        for entry in entries {
            if !entry.mission.isEmpty {
                let key = entry.group + "\u{1F}" + entry.mission
                if let owner = seenMission[key], owner != entry.path, byPath[owner] != nil {
                    continue
                }
                seenMission[key] = entry.path
            }
            byPath[entry.path] = entry
        }
        maps = byPath.values.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            if $0.group != $1.group {
                return $0.group.localizedCaseInsensitiveCompare($1.group) == .orderedAscending
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        status = "\(maps.count) maps"
    }

    func rescan() {
        guard !roots.isEmpty else {
            status = "Add a folder that holds .map / .mpr files"
            return
        }
        status = "Scanning…"
        if FileManager.default.fileExists(atPath: ra2CampaignDir),
           FileManager.default.fileExists(atPath: baseMissionIni) {
            runTool(["list", ra2CampaignDir, "--csf", ra2Csf]) { [weak self] ok, text in
                guard let self, ok else { return }
                let rows = parseToolRows(text).map { entry -> MapEntry in
                    // The RA2 chapters carry their own mission id (ALL01, SOV03,
                    // TRN01) inside the map, which is both the faction and order.
                    let mission = entry.mission
                    let number = mission.compactMap(\.wholeNumberValue).reduce(0) { $0 * 10 + $1 }
                    let (group, base): (String, Int) = if mission.hasPrefix("TRN") {
                        ("原版战役 · 训练", 0)
                    } else if mission.hasPrefix("ALL") {
                        ("原版战役 · 盟军", 1)
                    } else if mission.hasPrefix("SOV") {
                        ("原版战役 · 苏军", 2)
                    } else {
                        ("原版战役 · 其他", 3)
                    }
                    return MapEntry(
                        path: entry.path, group: group, name: entry.name,
                        author: entry.author, width: entry.width, height: entry.height,
                        theater: entry.theater, hasPreview: entry.hasPreview,
                        starts: entry.starts, pack: nil, order: base * 100 + number,
                        mission: mission, source: "ra2"
                    )
                }
                self.merge(rows)
            }
        }
        if FileManager.default.fileExists(atPath: campaignDir),
           FileManager.default.fileExists(atPath: baseMissionIni) {
            runTool(["list", campaignDir, "--mission-ini", baseMissionIni, "--csf", baseCsf]) { [weak self] ok, text in
                guard let self, ok else { return }
                let rows = parseToolRows(text).map { entry -> MapEntry in
                    // These are Yuri's Revenge's own Allied/Soviet chapters (the
                    // briefings talk about Yuri and the time machine), not the
                    // original RA2 ones. Order them allied → soviet → co-op.
                    let file = (entry.path as NSString).lastPathComponent.uppercased()
                    // Mission order is the number in the file name (ALL01…ALL07),
                    // never the localised title: sorting names puts "腦死" last.
                    let number = file.compactMap(\.wholeNumberValue).reduce(0) { $0 * 10 + $1 }
                    let (group, base): (String, Int) = if file.hasPrefix("ALL") {
                        ("尤里复仇战役 · 盟军", 10)
                    } else if file.hasPrefix("SOV") {
                        ("尤里复仇战役 · 苏军", 20)
                    } else {
                        ("尤里复仇战役 · 合作", 30)
                    }
                    let order = base * 100 + number
                    return MapEntry(
                        path: entry.path,
                        group: group,
                        name: entry.name,
                        author: entry.author,
                        width: entry.width,
                        height: entry.height,
                        theater: entry.theater,
                        hasPreview: entry.hasPreview,
                        starts: entry.starts,
                        pack: nil,
                        order: order,
                        source: "yr"
                    )
                }
                self.merge(rows)
            }
        }
        let packs = packArchives
        if !packs.isEmpty {
            runTool(["mix"] + packs) { [weak self] ok, text in
                guard let self, ok else { return }
                // Packed maps join the same grouped list.
                self.merge(parsePackRows(text))
            }
        }
        runTool(["list"] + missionArguments + roots) { [weak self] ok, text in
            guard let self else { return }
            guard ok else {
                self.status = "scan failed: \(text)"
                return
            }
            let rows = parseToolRows(text).map { entry -> MapEntry in
                var copy = entry
                copy.order = self.folderOrder(for: entry.group)
                return copy
            }
            self.merge(rows)
            self.status = "\(self.maps.count) maps in \(self.roots.count) folder(s)"
        }
    }

    func chooseGameFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "选择游戏目录（含 ra2md.mix）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        defaults.set(url.path, forKey: "ra2Dir")
        rescan()
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !roots.contains(url.path) else { return }
        roots.append(url.path)
        defaults.set(roots, forKey: "roots")
        rescan()
    }

    func select(_ entry: MapEntry) {
        selected = entry
        preview = nil
        briefing = ""
        // Title and briefing are mission metadata: ask the tool rather than
        // parsing MISSIONMD.INI/CSF in the window.
        // The extracted Yuri's Revenge chapters must read the base game's tables;
        // the mod's CSF would overwrite their briefings with its own campaign.
        let metadata: [String]
        switch entry.source {
        case "ra2": metadata = ["--csf", ra2Csf]
        case "yr": metadata = ["--mission-ini", baseMissionIni, "--csf", baseCsf]
        default: metadata = missionArguments
        }
        runTool(["info", entry.path] + metadata) { [weak self] ok, text in
            guard let self else { return }
            if ok {
                for line in text.split(separator: "\n") {
                    if line.hasPrefix("briefing\t") {
                        self.briefing = String(line.dropFirst("briefing\t".count))
                    }
                }
            }
        }
        // A packed preview wins; otherwise use the cached radar render, and if
        // there is none yet the panel offers to render one.
        let out = NSTemporaryDirectory() + "vera20k-preview.png"
        try? FileManager.default.removeItem(atPath: out)
        if entry.hasPreview {
            runTool(["preview", entry.path, "--out", out]) { [weak self] ok, _ in
                guard let self, ok, let image = NSImage(contentsOfFile: out) else { return }
                self.preview = image
            }
        } else if let cached = NSImage(contentsOfFile: previewCachePath(for: entry)) {
            preview = cached
        } else {
            status = "此地图尚无预览，可点「生成地图预览」"
        }
    }

    /// Render a real whole-map preview through the engine's radar surface.
    func generatePreview() {
        guard let entry = selected else { return }
        let out = previewCachePath(for: entry)
        generatingPreview = true
        status = "正在渲染预览（需要启动一次游戏，约 20-40 秒）…"
        runTool(["radar-preview", entry.path, "--out", out, "--wait", "60",
                 "--ra2-dir", assetRoot(for: entry)]) { [weak self] ok, text in
            guard let self else { return }
            self.generatingPreview = false
            if ok, let image = NSImage(contentsOfFile: out) {
                self.preview = image
                self.status = "预览已生成并缓存"
            } else {
                self.status = "预览生成失败：\(text)"
            }
        }
    }

    func launch() {
        guard let entry = selected else { return }
        status = "Launching \(entry.displayName)…"
        // Campaign vs skirmish is decided by the map file itself (ALL/SOV/YUR),
        // so no mode or side picker is needed.
        defaults.set(fullscreen, forKey: "fullscreen")
        if let pack = entry.pack {
            // A packed map has to leave the archive first; the launcher stages it
            // in the game's data folder, where the launch file lives.
            let out = dataDir + "/mixmap_\(pack.id).map"
            runTool(["mix", pack.archive, "--extract", String(pack.id), "--out", out]) { [weak self] ok, text in
                guard let self else { return }
                guard ok else {
                    self.status = "extract failed: \(text)"
                    return
                }
                self.start(mapPath: out, name: entry.displayName)
            }
            return
        }
        start(mapPath: entry.path, name: entry.displayName)
    }

    private func start(mapPath: String, name: String) {
        var arguments = ["launch", mapPath, "--data-dir", dataDir]
        if let entry = selected { arguments += ["--ra2-dir", assetRoot(for: entry)] }
        if fullscreen { arguments.append("--fullscreen") }
        runTool(arguments) { [weak self] ok, text in
            self?.status = ok ? "Started: \(name)" : "launch failed: \(text)"
        }
    }

    private func runTool(_ arguments: [String], completion: @escaping @MainActor (Bool, String) -> Void) {
        let tool = toolPath
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { completion(false, "\(error)") }
                return
            }
            // A tool that blocks (for example on a pending file-access prompt)
            // must not freeze the window: kill it and report instead.
            let deadline = DispatchTime.now() + .seconds(30)
            let watchdog = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: deadline, execute: watchdog)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            let text = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async { completion(process.terminationStatus == 0, text) }
        }
    }
}

// MARK: - View

struct ContentView: View {
    @StateObject private var launcher = Launcher()

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
            VStack(spacing: 0) {
                List(selection: Binding(
                    get: { launcher.selected?.id },
                    set: { id in
                        if let id, let entry = launcher.maps.first(where: { $0.id == id }) {
                            launcher.select(entry)
                        }
                    }
                )) {
                    ForEach(launcher.groups, id: \.self) { group in
                        Section(group) {
                            ForEach(launcher.maps(in: group)) { entry in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.displayName).lineLimit(1)
                                    Text(entry.subtitle)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .tag(entry.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack {
                    Button("Add Folder…") { launcher.addFolder() }
                    Button("游戏目录…") { launcher.chooseGameFolder() }
                    Button("Rescan") { launcher.rescan() }
                    Toggle("无名地图包", isOn: Binding(
                        get: { launcher.showUnnamedPacks },
                        set: { launcher.showUnnamedPacks = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    Toggle("原版 RA2 战役（实验）", isOn: Binding(
                        get: { launcher.showRa2Chapters },
                        set: { launcher.showRa2Chapters = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    Spacer()
                }
                .padding(6)
            }
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let entry = launcher.selected {
                        Text(entry.displayName)
                            .font(.title3).bold()
                            .fixedSize(horizontal: false, vertical: true)
                        Text(entry.subtitle).foregroundStyle(.secondary)
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85))
                            if let preview = launcher.preview {
                                Image(nsImage: preview)
                                    .resizable()
                                    .interpolation(.none)
                                    .aspectRatio(contentMode: .fit)
                                    .padding(6)
                            } else if launcher.generatingPreview {
                                VStack(spacing: 8) {
                                    ProgressView()
                                    Text("正在渲染地图预览…").font(.system(size: 11))
                                }
                                .foregroundStyle(.secondary)
                            } else {
                                Text(entry.hasPreview ? "正在载入预览…" : "暂无预览")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(height: 200)
                        if !launcher.briefing.isEmpty {
                            Text("任务简报").font(.headline)
                            Text(launcher.briefing)
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if entry.source == "ra2" {
                            Text("实验性：原版 RA2 战役在 YR 状态下尚不能正确运行（过场与任务脚本不匹配），启动可能立刻失败。")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if launcher.preview == nil, !launcher.generatingPreview {
                            Button("生成地图预览") { launcher.generatePreview() }
                                .controlSize(.large)
                        }
                        Toggle("以全屏启动", isOn: $launcher.fullscreen)
                        Button("Launch in VERA20K") { launcher.launch() }
                            .keyboardShortcut(.return, modifiers: [.command])
                            .controlSize(.large)
                            .buttonStyle(.borderedProminent)
                    } else {
                        Text("Pick a mission").font(.title3)
                        Text("The list is grouped by folder or map pack.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .frame(minWidth: 460)
            }
            .frame(minWidth: 820, minHeight: 560)
            Divider()
            Text(launcher.status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        }
    }
}

@main
struct MapLauncherApp: App {
    var body: some Scene {
        WindowGroup("VERA20K Map Launcher") {
            ContentView()
        }
        .defaultSize(width: 1000, height: 680)
        .windowResizability(.contentMinSize)
    }
}
