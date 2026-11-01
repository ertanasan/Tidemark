import AppKit
import SwiftUI

enum SizeUnit: String, CaseIterable, Identifiable {
    case auto = "Automatic", bytes = "Bytes", kb = "KB", mb = "MB", gb = "GB", tb = "TB"
    var id: String { rawValue }
}

enum DetailTab: String, CaseIterable, Identifiable {
    case chart = "Chart", details = "Details", extensions = "Extensions", largest = "Largest Files", changes = "Changes"
    var id: String { rawValue }
}

enum Fmt {
    private static let tr = Locale(identifier: "en_US")
    private static let dec1: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = tr
        f.numberStyle = .decimal
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f
    }()
    private static let int: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = tr
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = tr
        f.dateFormat = "MM/dd/yyyy HH:mm"
        return f
    }()
    private static let names = ["Bytes", "KB", "MB", "GB", "TB", "PB"]

    static func size(_ b: Int64, _ unit: SizeUnit = .auto) -> String {
        var idx: Int
        switch unit {
        case .auto:
            idx = 0
            var v = Double(b)
            while v >= 1024 && idx < names.count - 1 { v /= 1024; idx += 1 }
        case .bytes: idx = 0
        case .kb: idx = 1
        case .mb: idx = 2
        case .gb: idx = 3
        case .tb: idx = 4
        }
        if idx == 0 { return "\(count(Int(b))) Bytes" }
        let v = Double(b) / pow(1024, Double(idx))
        return "\(dec1.string(from: v as NSNumber) ?? "") \(names[idx])"
    }
    static func count(_ n: Int) -> String { int.string(from: n as NSNumber) ?? "\(n)" }
    static func pct(_ f: Double) -> String { "\(dec1.string(from: (f * 100) as NSNumber) ?? "")%" }
    static func seconds(_ s: Double) -> String { "\(dec1.string(from: s as NSNumber) ?? "") s" }
    static func date(_ d: Date) -> String { dateFmt.string(from: d) }
    static func date(_ t: Double) -> String { t > 0 ? dateFmt.string(from: Date(timeIntervalSince1970: t)) : "" }
}

struct VolumeInfo: Identifiable {
    let id: String   // mount path
    let name: String
    let total: Int64
    let free: Int64
    let icon: NSImage
    var freeFraction: Double { total > 0 ? Double(free) / Double(total) : 0 }

    private static let keys: Set<URLResourceKey> = [
        .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
    ]

    static func all() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap(info(volumeURL:))
    }

    static func info(volumeURL url: URL) -> VolumeInfo? {
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        let total = Int64(v.volumeTotalCapacity ?? 0)
        let free = Int64(v.volumeAvailableCapacity ?? 0)
        return VolumeInfo(id: url.path, name: v.volumeLocalizedName ?? url.lastPathComponent,
                          total: total, free: free, icon: NSWorkspace.shared.icon(forFile: url.path))
    }

    static func containing(path: String) -> VolumeInfo? {
        guard let vol = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeURLKey]).volume
        else { return nil }
        return info(volumeURL: vol)
    }
}

struct ScanStats {
    var excluded = 0
    var errors = 0
    var duration = 0.0
}

@MainActor
final class AppModel: ObservableObject {
    @Published var root: DirNode?
    @Published var selection: DirNode?
    @Published var expanded = Set<ObjectIdentifier>()
    @Published var mode: SizeMode = .alloc { didSet { recomputeChanges() } }
    @Published var unit: SizeUnit = .auto
    @Published var tab: DetailTab = .details
    @Published var scanning = false
    @Published var progress = ScanSnapshot()
    @Published var stats = ScanStats()
    @Published var volumes: [VolumeInfo] = []
    @Published var selectedVolumeID: String?
    @Published var rootVolume: VolumeInfo?
    @Published var blockInfo = ""
    @Published var hasFullDiskAccess = true
    @Published var scrollTarget: DirNode?

    // Growth tracking (Changes tab)
    @Published var baselines: [SnapshotRef] = []
    @Published var baseline: Baseline? { didSet { recomputeChanges() } }
    @Published var changeThreshold: Int64 = {
        let v = UserDefaults.standard.object(forKey: "changeThreshold") as? Int64
        return v ?? 1 << 30
    }() {
        didSet {
            UserDefaults.standard.set(changeThreshold, forKey: "changeThreshold")
            recomputeChanges()
        }
    }
    @Published var showNestedChanges = false { didSet { recomputeChanges() } }
    @Published private(set) var changes: [FolderChange] = []
    @Published private(set) var changeByNode: [ObjectIdentifier: FolderChange] = [:]
    @Published private(set) var computingChanges = false
    private var loadedSnapshot: (SnapshotRef, Snapshot)?
    private var changeGeneration = 0

    /// Set while the tree on screen is the cached result of an earlier scan: that scan's date.
    @Published private(set) var cachedScanDate: Date?
    /// Items moved to the Trash while a scan was running; dropped again from its result.
    private var trashedDuringScan: [String] = []

    private var currentProgress: ScanProgress?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    var selected: DirNode? { selection ?? root }

    private static weak var shared: AppModel?
    private static var pendingPath: String?
    private static var pendingBaselineDate: Date?
    /// After the next scan, compare with the snapshot taken at this date and show the Changes tab.
    private var compareWith: Date?

    /// Scans `path` in the live model, or queues it until the model exists (e.g. a service launched the app).
    static func open(path: String, compareWith date: Date? = nil) {
        if let m = shared {
            m.compareWith = date
            m.scan(path: path)
        } else {
            pendingPath = path
            pendingBaselineDate = date
        }
    }

    @Published var idleScanEnabled = IdleScan.isEnabled {
        didSet {
            guard idleScanEnabled != IdleScan.isEnabled else { return }
            do {
                try IdleScan.setEnabled(idleScanEnabled)
            } catch {
                NSAlert(error: error).runModal()
                idleScanEnabled = IdleScan.isEnabled
            }
        }
    }

    init() {
        refreshVolumes()
        checkFullDiskAccess()
        Self.shared = self
        if let path = Self.pendingPath ?? CommandLine.arguments.dropFirst().first(where: { $0.hasPrefix("/") })
            ?? UserDefaults.standard.string(forKey: "lastRoot") {
            Self.pendingPath = nil
            compareWith = Self.pendingBaselineDate
            scan(path: path)
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshVolumes() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.checkFullDiskAccess()
                    self?.refreshVolumes()
                }
            })
    }

    // MARK: Scanning

    func scan(path: String, reselect: String? = nil) {
        cancelScan()
        let p = ScanProgress()
        currentProgress = p
        scanning = true
        progress = ScanSnapshot()
        trashedDuringScan = []
        let name = DiskScanner.rootName(path)
        if root?.name != name {
            // A different location: show its last scan, if cached, while this one runs.
            root = nil
            selection = nil
            cachedScanDate = nil
            Task.detached(priority: .userInitiated) {
                guard let cached = TreeCache.load(root: name) else { return }
                await self.showCached(cached.result, date: cached.date, progress: p, reselect: reselect)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let cp = self.currentProgress else { return }
                self.progress = cp.snapshot()
            }
        }
        Task.detached(priority: .userInitiated) {
            let result = DiskScanner.scan(path: path, progress: p)
            let date = Date()
            if let result {
                // Encode before the UI can edit the tree; compress and write in the background.
                let data = TreeCache.encode(result, date: date)
                Task.detached(priority: .utility) { TreeCache.write(data, root: result.root.name) }
            }
            await self.finish(result, date: date, progress: p, reselect: reselect)
        }
    }

    private func showCached(_ result: ScanResult, date: Date, progress p: ScanProgress, reselect: String?) {
        guard p === currentProgress, root == nil else { return }   // the scan finished first, or another started
        cachedScanDate = date
        show(result, reselect: reselect)
        // Compare with the scan before the cached one (the newest snapshot is the cached scan itself).
        baselines = SnapshotStore.list(covering: result.root.name)
        baseline = baselines.first(where: { $0.date < date.addingTimeInterval(-1) }).map(Baseline.snapshot)
            ?? .createdWithin(days: 30)
    }

    private func finish(_ result: ScanResult?, date: Date, progress p: ScanProgress, reselect: String?) {
        guard p === currentProgress else { return }
        stopTimer()
        scanning = false
        guard let result else { return }
        for path in trashedDuringScan {
            let folder = (path as NSString).deletingLastPathComponent
            if let n = result.root.find(path: path), n.path == path, let parent = n.parent {
                parent.removeChild(n)
            } else if let f = result.root.find(path: folder), f.path == folder {
                f.removeFile(named: (path as NSString).lastPathComponent)
            }
        }
        show(result, reselect: reselect)
        cachedScanDate = nil
        UserDefaults.standard.set(result.root.name, forKey: "lastRoot")

        // Compare with the previous scan, then record this one for next time.
        baselines = SnapshotStore.list(covering: result.root.name)
        if let want = compareWith, let ref = baselines.first(where: { abs($0.date.timeIntervalSince(want)) < 1 }) {
            baseline = .snapshot(ref)
            tab = .changes
        } else {
            baseline = baselines.first.map(Baseline.snapshot) ?? .createdWithin(days: 30)
        }
        compareWith = nil
        let r = result.root
        Task.detached(priority: .utility) { SnapshotStore.save(root: r, date: date) }
    }

    /// Puts a scanned tree on screen. Replacing a tree of the same location keeps the
    /// selected and expanded folders.
    private func show(_ result: ScanResult, reselect: String?) {
        var open: [String] = []
        var keep = reselect
        if let old = root, old.name == result.root.name {
            func walk(_ n: DirNode) {
                guard expanded.contains(n.id) else { return }
                open.append(n.path)
                n.children.forEach(walk)
            }
            walk(old)
            keep = keep ?? selection?.path
        }
        root = result.root
        stats = ScanStats(excluded: result.excluded, errors: result.errors, duration: result.duration)
        expanded = [result.root.id]
        for p in open { if let n = result.root.find(path: p) { expanded.insert(n.id) } }
        let target = keep.flatMap { result.root.find(path: $0) } ?? result.root
        navigate(to: target)
        updateRootVolume()
    }

    func recomputeChanges() {
        changeGeneration += 1
        let gen = changeGeneration
        guard let root, let baseline else {
            changes = []; changeByNode = [:]
            return
        }
        let threshold = changeThreshold, mode = self.mode, nested = showNestedChanges
        let cached = loadedSnapshot
        computingChanges = true
        Task {
            let (result, loaded) = await Task.detached(priority: .userInitiated) {
                () -> ([FolderChange], (SnapshotRef, Snapshot)?) in
                switch baseline {
                case .snapshot(let ref):
                    let snap = cached?.0 == ref ? cached?.1 : SnapshotStore.load(ref)
                    guard let snap else { return ([], nil) }
                    return (ChangeFinder.find(root: root, snapshot: snap, since: ref.date,
                                              threshold: threshold, mode: mode, nested: nested), (ref, snap))
                case .createdWithin(let days):
                    let since = Date().addingTimeInterval(-Double(days) * 86400)
                    return (ChangeFinder.find(root: root, snapshot: nil, since: since,
                                              threshold: threshold, mode: mode, nested: nested), nil)
                }
            }.value
            if let loaded { loadedSnapshot = loaded }
            guard gen == changeGeneration else { return }
            changes = result
            changeByNode = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
            computingChanges = false
        }
    }

    func cancelScan() {
        currentProgress?.cancel()
        currentProgress = nil
        stopTimer()
        scanning = false
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func rescan() {
        guard let root else { return }
        scan(path: root.name, reselect: selected?.path)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose the folder or disk to scan"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedVolumeID = nil
        scan(path: url.path)
    }

    // MARK: Navigation

    var canGoUp: Bool {
        guard let s = selected else { return false }
        return s.parent != nil || s.name != "/"
    }

    func goUp() {
        guard let s = selected else { return }
        if let p = s.parent {
            navigate(to: p)
        } else {
            let up = (s.name as NSString).deletingLastPathComponent
            selectedVolumeID = nil
            scan(path: up.isEmpty ? "/" : up, reselect: s.name)
        }
    }

    func navigate(to node: DirNode) {
        var p = node.parent
        while let n = p {
            expanded.insert(n.id)
            p = n.parent
        }
        selection = node
        scrollTarget = node
    }

    func isExpanded(_ node: DirNode) -> Binding<Bool> {
        Binding(get: { self.expanded.contains(node.id) },
                set: { if $0 { self.expanded.insert(node.id) } else { self.expanded.remove(node.id) } })
    }

    // MARK: Volumes & system

    func refreshVolumes() {
        volumes = VolumeInfo.all()
        if root != nil { updateRootVolume() }
    }

    private func updateRootVolume() {
        guard let path = root?.name else { return }
        rootVolume = VolumeInfo.containing(path: path)
        var s = statfs()
        if statfs(path, &s) == 0 {
            let fs = withUnsafeBytes(of: s.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            blockInfo = "\(Fmt.count(Int(s.f_bsize))) Bytes/Block (\(fs.uppercased()))"
        }
    }

    func checkFullDiskAccess() {
        let fd = Darwin.open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        hasFullDiskAccess = fd >= 0
        if fd >= 0 { Darwin.close(fd) }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    // MARK: File actions

    /// Bumped whenever the scanned tree is edited in place, so derived views can reload.
    @Published var treeVersion = 0 { didSet { recomputeChanges() } }

    /// Asks for confirmation, moves the item to the Trash, and removes it from the scanned tree.
    /// Pass `node` for a folder; for a file pass its containing folder as `parent`.
    func moveToTrash(path: String, node: DirNode?, parent: DirNode?) {
        guard let parent = node?.parent ?? parent else { return }   // never the scan root
        let name = (path as NSString).lastPathComponent
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move “\(name)” to the Trash?"
        var info = path
        if let node {
            info += "\n\n\(Fmt.size(node.value(mode), unit)) · \(Fmt.count(node.fileCount)) files, \(Fmt.count(node.dirCount)) folders"
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            let err = NSAlert(error: error)
            err.messageText = "Couldn’t move “\(name)” to the Trash"
            err.runModal()
            return
        }
        if scanning { trashedDuringScan.append(path) }

        if let node {
            // Move selection out of the deleted subtree before detaching it.
            var s = selection
            while let cur = s, cur !== node { s = cur.parent }
            if s != nil { selection = parent }
            parent.removeChild(node)
        } else {
            parent.removeFile(named: name)
        }
        treeVersion += 1
        updateRootVolume()
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func copy(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}
