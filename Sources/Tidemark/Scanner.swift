import Foundation

enum SizeMode: String { case logical, alloc }

struct FileItem {
    let name: String
    let size: Int64
    let alloc: Int64
    let mtime: Double
}

final class DirNode: Identifiable, Hashable {
    let name: String            // full path for the scan root, last component otherwise
    weak var parent: DirNode?
    var children: [DirNode] = []
    var files: [FileItem] = []
    var mtime: Double = 0
    var inaccessible = false
    var ownErrors = 0

    // Recursive totals, filled by DiskScanner.finalize.
    var size: Int64 = 0
    var alloc: Int64 = 0
    var fileCount = 0
    var dirCount = 0
    var errorCount = 0

    private var sortCache: (SizeMode, [DirNode])?

    init(name: String, parent: DirNode?) {
        self.name = name
        self.parent = parent
    }

    static func == (a: DirNode, b: DirNode) -> Bool { a === b }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }

    var path: String {
        guard let p = parent else { return name }
        let pp = p.path
        return pp.hasSuffix("/") ? pp + name : pp + "/" + name
    }

    func value(_ mode: SizeMode) -> Int64 { mode == .logical ? size : alloc }

    func sortedChildren(_ mode: SizeMode) -> [DirNode] {
        if let c = sortCache, c.0 == mode { return c.1 }
        let s = children.sorted { $0.value(mode) > $1.value(mode) }
        sortCache = (mode, s)
        return s
    }

    /// Detaches a deleted subfolder and subtracts its totals from every ancestor.
    func removeChild(_ c: DirNode) {
        guard let i = children.firstIndex(of: c) else { return }
        children.remove(at: i)
        subtract(size: c.size, alloc: c.alloc, files: c.fileCount, dirs: c.dirCount + 1, errors: c.errorCount)
    }

    /// Drops a deleted file and subtracts it from every ancestor.
    func removeFile(named fileName: String) {
        guard let i = files.firstIndex(where: { $0.name == fileName }) else { return }
        let f = files.remove(at: i)
        subtract(size: f.size, alloc: f.alloc, files: 1, dirs: 0, errors: 0)
    }

    private func subtract(size s: Int64, alloc a: Int64, files fc: Int, dirs dc: Int, errors ec: Int) {
        var n: DirNode? = self
        while let cur = n {
            cur.size -= s; cur.alloc -= a
            cur.fileCount -= fc; cur.dirCount -= dc; cur.errorCount -= ec
            cur.sortCache = nil
            n = cur.parent
        }
    }

    func find(path target: String) -> DirNode? {
        if target == name { return self }
        let prefix = name.hasSuffix("/") ? name : name + "/"
        guard target.hasPrefix(prefix) else { return nil }
        var node = self
        for comp in target.dropFirst(prefix.count).split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == comp }) else { return node }
            node = next
        }
        return node
    }
}

struct ScanSnapshot {
    var files = 0
    var dirs = 0
    var bytes: Int64 = 0
    var currentPath = ""
}

final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var snap = ScanSnapshot()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    func snapshot() -> ScanSnapshot { lock.withLock { snap } }
    func update(files: Int, dirs: Int, bytes: Int64, path: String) {
        lock.withLock { snap = ScanSnapshot(files: files, dirs: dirs, bytes: bytes, currentPath: path) }
    }
}

struct ScanResult {
    let root: DirNode
    let excluded: Int
    let errors: Int
    let duration: Double
}

enum DiskScanner {
    /// Scanning "/" would otherwise walk other volumes and count the Data volume twice (firmlinks).
    static func excludedPaths(for root: String) -> Set<String> {
        root == "/" ? ["/System/Volumes", "/Volumes", "/dev", "/net", "/home", "/cores"] : []
    }

    /// The path as it appears as a scan root's name.
    static func rootName(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static func scan(path input: String, progress: ScanProgress) -> ScanResult? {
        let start = Date()
        let rootPath = rootName(input)
        let excludedSet = excludedPaths(for: rootPath)

        guard let cPath = strdup(rootPath) else { return nil }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return nil }
        defer { fts_close(fts) }

        var stack: [DirNode] = []
        var root: DirNode?
        var excluded = 0, errors = 0
        var files = 0, dirs = 0
        var bytes: Int64 = 0
        var tick = 0

        while let ent = fts_read(fts) {
            tick += 1
            if tick & 0xFF == 0 {
                if progress.isCancelled { return nil }
                progress.update(files: files, dirs: dirs, bytes: bytes, path: String(cString: ent.pointee.fts_path))
            }
            let e = ent.pointee
            let level = Int(e.fts_level)
            let name = level == 0 ? rootPath
                : String(cString: e.fts_path + (Int(e.fts_pathlen) - Int(e.fts_namelen)))

            switch Int32(e.fts_info) {
            case FTS_D:
                if level > 0 && level <= 2 && !excludedSet.isEmpty
                    && excludedSet.contains(String(cString: e.fts_path)) {
                    fts_set(fts, ent, FTS_SKIP)
                    excluded += 1
                    continue
                }
                if stack.count > level { stack.removeLast(stack.count - level) }
                let parent = level > 0 && stack.count == level ? stack[level - 1] : nil
                if level > 0 && parent == nil { continue }
                let node = DirNode(name: name, parent: parent)
                node.mtime = Double(e.fts_statp.pointee.st_mtimespec.tv_sec)
                parent?.children.append(node)
                if level == 0 { root = node }
                stack.append(node)
                ent.pointee.fts_number = 2
                dirs += 1

            case FTS_DNR, FTS_ERR:
                errors += 1
                if e.fts_number == 2 && stack.count > level && stack[level].name == name {
                    stack[level].inaccessible = true
                } else if level == 0 {
                    let node = DirNode(name: name, parent: nil)
                    node.inaccessible = true
                    root = node
                } else {
                    if stack.count > level { stack.removeLast(stack.count - level) }
                    guard stack.count == level else { continue }
                    let node = DirNode(name: name, parent: stack[level - 1])
                    node.inaccessible = true
                    stack[level - 1].children.append(node)
                }

            case FTS_NS:
                errors += 1
                if stack.count >= level && level > 0 { stack[level - 1].ownErrors += 1 }

            case FTS_DP, FTS_DC, FTS_DOT:
                break

            default: // FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT
                guard level > 0 else { continue }
                if stack.count > level { stack.removeLast(stack.count - level) }
                guard stack.count == level else { continue }
                let st = e.fts_statp.pointee
                let item = FileItem(name: name, size: Int64(st.st_size), alloc: Int64(st.st_blocks) * 512,
                                    mtime: Double(st.st_mtimespec.tv_sec))
                stack[level - 1].files.append(item)
                files += 1
                bytes += item.alloc
            }
        }
        guard let root else { return nil }
        finalize(root)
        return ScanResult(root: root, excluded: excluded, errors: errors, duration: Date().timeIntervalSince(start))
    }

    /// Brings an earlier scan up to date from the folders that changed since (from FSEvents): each is
    /// re-read, and those marked `true` (FSEvents lost the detail) rescanned in full. Edits the tree in
    /// place. nil when only a full scan will do.
    static func update(_ cached: ScanResult, changed: [String: Bool]) -> ScanResult? {
        let start = Date()
        let root = cached.root
        let excluded = excludedPaths(for: root.name)
        func under(_ p: String, _ dir: String) -> Bool { p.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/") }
        var rescanned: [String] = []
        // Sorted, so a folder comes before anything inside it.
        for (path, recursive) in changed.sorted(by: { $0.key < $1.key }) {
            if excluded.contains(where: { path == $0 || under(path, $0) })
                || rescanned.contains(where: { under(path, $0) }) { continue }
            guard let node = root.find(path: path) else { continue }   // outside the scanned folder
            guard node.path == path else {
                // Not in the tree yet: re-reading the nearest folder that is picks it up.
                if !refresh(node, changed: changed, excluded: excluded) { return nil }
                continue
            }
            if !recursive {
                if !refresh(node, changed: changed, excluded: excluded) { return nil }
                continue
            }
            // A fresh scan of this folder would also walk into excluded ones.
            guard let parent = node.parent, !excluded.contains(where: { under($0, path) }) else { return nil }
            if let i = parent.children.firstIndex(of: node) {
                if let fresh = subtree(path, parent: parent) { parent.children[i] = fresh }
                else { parent.children.remove(at: i) }
            }
            rescanned.append(path)
        }
        finalize(root)
        return ScanResult(root: root, excluded: cached.excluded, errors: root.errorCount,
                          duration: Date().timeIntervalSince(start))
    }

    /// Re-reads one folder's own entries: its files are replaced, subfolders that are gone dropped and
    /// new ones scanned in full. Subfolders still there keep their subtrees, unless one was swapped for
    /// another folder (its date changed with no change recorded inside). false if the scan root is gone.
    private static func refresh(_ node: DirNode, changed: [String: Bool], excluded: Set<String>) -> Bool {
        let path = node.path
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else {
            guard let parent = node.parent else { return false }
            parent.children.removeAll { $0 === node }
            return true
        }
        node.mtime = Double(st.st_mtimespec.tv_sec)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            node.inaccessible = true
            node.files = []; node.children = []
            return true
        }
        let old = Dictionary(node.children.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let join = path.hasSuffix("/") ? path : path + "/"
        var files: [FileItem] = [], children: [DirNode] = [], errors = 0
        for name in names {
            let p = join + name
            guard lstat(p, &st) == 0 else { errors += 1; continue }
            guard st.st_mode & S_IFMT == S_IFDIR else {
                files.append(FileItem(name: name, size: Int64(st.st_size), alloc: Int64(st.st_blocks) * 512,
                                      mtime: Double(st.st_mtimespec.tv_sec)))
                continue
            }
            if excluded.contains(p) { continue }
            if let c = old[name], changed[p] != nil || c.mtime == Double(st.st_mtimespec.tv_sec) {
                children.append(c)
            } else if let c = subtree(p, parent: node) {
                children.append(c)
            }
        }
        node.files = files
        node.children = children
        node.ownErrors = errors
        node.inaccessible = false
        return true
    }

    /// A fresh scan of `path`, attached as a subfolder of `parent`.
    private static func subtree(_ path: String, parent: DirNode) -> DirNode? {
        guard let r = scan(path: path, progress: ScanProgress())?.root else { return nil }
        let n = DirNode(name: (path as NSString).lastPathComponent, parent: parent)
        n.mtime = r.mtime
        n.inaccessible = r.inaccessible
        n.ownErrors = r.ownErrors
        n.files = r.files
        n.children = r.children
        for c in n.children { c.parent = n }
        return n
    }

    static func finalize(_ n: DirNode) {
        var s: Int64 = 0, a: Int64 = 0
        var fc = n.files.count, dc = n.children.count
        var ec = n.ownErrors + (n.inaccessible ? 1 : 0)
        for f in n.files { s += f.size; a += f.alloc }
        for c in n.children {
            finalize(c)
            s += c.size; a += c.alloc
            fc += c.fileCount; dc += c.dirCount; ec += c.errorCount
        }
        n.size = s; n.alloc = a; n.fileCount = fc; n.dirCount = dc; n.errorCount = ec
    }
}

/// In-memory queries over a scanned subtree (run off the main thread).
enum Analysis {
    struct ExtRow: Identifiable {
        var id: String { ext }
        let ext: String
        var size: Int64 = 0
        var alloc: Int64 = 0
        var count = 0
        var pct = 0.0
    }

    struct BigFile: Identifiable {
        let id: Int
        let name: String
        let folder: String
        let size: Int64
        let alloc: Int64
        let modified: Date
        var path: String { folder.hasSuffix("/") ? folder + name : folder + "/" + name }
    }

    static func walk(_ root: DirNode, _ body: (DirNode) -> Void) {
        var stack = [root]
        while let n = stack.popLast() {
            body(n)
            stack.append(contentsOf: n.children)
        }
    }

    static func extensions(of root: DirNode, mode: SizeMode) -> [ExtRow] {
        var map: [String: ExtRow] = [:]
        walk(root) { n in
            for f in n.files {
                var ext = "(no extension)"
                if let dot = f.name.lastIndex(of: "."), dot != f.name.startIndex,
                   f.name.index(after: dot) != f.name.endIndex {
                    ext = "." + f.name[f.name.index(after: dot)...].lowercased()
                }
                map[ext, default: ExtRow(ext: ext)].size += f.size
                map[ext]!.alloc += f.alloc
                map[ext]!.count += 1
            }
        }
        let total = Double(max(1, root.value(mode)))
        return map.values.map { r in
            var r = r
            r.pct = Double(mode == .logical ? r.size : r.alloc) / total
            return r
        }.sorted { $0.pct > $1.pct }
    }

    static func largest(in root: DirNode, mode: SizeMode, limit: Int = 200) -> [BigFile] {
        var top: [(FileItem, DirNode)] = []
        var threshold: Int64 = -1
        func val(_ f: FileItem) -> Int64 { mode == .logical ? f.size : f.alloc }
        walk(root) { n in
            for f in n.files where val(f) > threshold {
                top.append((f, n))
                if top.count >= limit * 2 {
                    top.sort { val($0.0) > val($1.0) }
                    top.removeLast(top.count - limit)
                    threshold = val(top.last!.0)
                }
            }
        }
        top.sort { val($0.0) > val($1.0) }
        return top.prefix(limit).enumerated().map { i, t in
            BigFile(id: i, name: t.0.name, folder: t.1.path, size: t.0.size, alloc: t.0.alloc,
                    modified: Date(timeIntervalSince1970: t.0.mtime))
        }
    }
}
