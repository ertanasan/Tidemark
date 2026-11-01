import Foundation

// MARK: Snapshots

/// Folder sizes recorded after a scan, so a later scan can tell what grew.
struct Snapshot: Codable {
    let root: String
    let date: Date
    /// path → [size, alloc], for folders of at least `SnapshotStore.floor` in either measure.
    let folders: [String: [Int64]]

    func value(_ path: String, _ mode: SizeMode) -> Int64? {
        folders[path].map { mode == .logical ? $0[0] : $0[1] }
    }
}

struct SnapshotRef: Hashable, Identifiable {
    let root: String
    let date: Date
    let url: URL
    var id: URL { url }
}

/// ~/Library/Application Support/Tidemark/Snapshots/<percent-encoded root>/<unix time>.json
enum SnapshotStore {
    /// Smaller folders aren't recorded; one missing from a snapshot was below this.
    static let floor: Int64 = 25 << 20
    /// Retention per scanned location: every snapshot from the last `keepAllFor`, then the
    /// newest one per day for `keepDays` days.
    static let keepAllFor: TimeInterval = 48 * 3600
    static let keepDays = 60

    private static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tidemark/Snapshots", isDirectory: true)
    }

    private static func folder(for root: String) -> URL {
        let name = root.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? root
        return dir.appendingPathComponent(name, isDirectory: true)
    }

    static func save(root: DirNode, date: Date) {
        var out: [String: [Int64]] = [:]
        func walk(_ n: DirNode, _ path: String) {
            // Children never exceed their parent, so the whole subtree can be skipped.
            guard n.size >= floor || n.alloc >= floor else { return }
            out[path] = [n.size, n.alloc]
            let join = path.hasSuffix("/") ? path : path + "/"
            for c in n.children { walk(c, join + c.name) }
        }
        walk(root, root.name)
        let snap = Snapshot(root: root.name, date: date, folders: out)
        let f = folder(for: root.name)
        do {
            try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
            try JSONEncoder().encode(snap)
                .write(to: f.appendingPathComponent("\(Int(date.timeIntervalSince1970)).json"), options: .atomic)
        } catch {
            NSLog("Tidemark: couldn't save snapshot: \(error)")
        }
        // Prune the oldest.
        var days = Set<Date>()
        for r in refs(in: f, root: root.name) {   // newest first
            if date.timeIntervalSince(r.date) < keepAllFor { continue }
            let day = Calendar.current.startOfDay(for: r.date)
            if days.count < keepDays, days.insert(day).inserted { continue }
            try? FileManager.default.removeItem(at: r.url)
        }
    }

    /// Snapshots of `root` or of any folder containing it, newest first.
    static func list(covering root: String) -> [SnapshotRef] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return dirs.flatMap { d -> [SnapshotRef] in
            guard let r = d.lastPathComponent.removingPercentEncoding,
                  r == root || root.hasPrefix(r.hasSuffix("/") ? r : r + "/") else { return [] }
            return refs(in: d, root: r)
        }
        .sorted { $0.date > $1.date }
    }

    private static func refs(in folder: URL, root: String) -> [SnapshotRef] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { u in
            guard u.pathExtension == "json", let t = Double(u.deletingPathExtension().lastPathComponent) else { return nil }
            return SnapshotRef(root: root, date: Date(timeIntervalSince1970: t), url: u)
        }
        .sorted { $0.date > $1.date }
    }

    static func load(_ ref: SnapshotRef) -> Snapshot? {
        guard let data = try? Data(contentsOf: ref.url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}

// MARK: Comparison

enum Baseline: Hashable {
    /// Compare sizes with an earlier scan.
    case snapshot(SnapshotRef)
    /// No history needed: folders created in the last N days.
    case createdWithin(days: Int)
}

enum ChangeKind: String {
    case new = "New"
    case crossed = "Crossed"
    case grew = "Grew"
}

struct FolderChange: Identifiable {
    let node: DirNode
    let path: String
    let kind: ChangeKind
    /// Size in the baseline; nil when the folder wasn't recorded (new, or under `SnapshotStore.floor`).
    let before: Int64?
    let now: Int64
    let created: Date?

    var id: ObjectIdentifier { node.id }
    var delta: Int64 { now - (before ?? 0) }
    var status: String { kind.rawValue }
    var beforeSort: Int64 { before ?? -1 }
    var createdSort: Date { created ?? .distantPast }
}

enum ChangeFinder {
    /// Folders of at least `threshold` that are new since `since`, went past `threshold`,
    /// or grew by at least `threshold`. Without `nested`, a parent whose growth is mostly
    /// explained by flagged subfolders is hidden, as is anything inside a new folder.
    static func find(root: DirNode, snapshot: Snapshot?, since: Date, threshold: Int64,
                     mode: SizeMode, nested: Bool) -> [FolderChange] {
        var all: [FolderChange] = []
        func created(_ path: String) -> Date? {
            try? URL(fileURLWithPath: path).resourceValues(forKeys: [.creationDateKey]).creationDate
        }
        func walk(_ n: DirNode, _ path: String) {
            let now = n.value(mode)
            guard now >= threshold else { return }
            var kind: ChangeKind?
            var before: Int64?
            var born: Date?
            if let snapshot {
                before = snapshot.value(path, mode)
                if let before {
                    if before < threshold { kind = .crossed } else if now - before >= threshold { kind = .grew }
                } else {
                    born = created(path)
                    kind = (born ?? .distantPast) > since ? .new : .crossed
                }
            } else {
                born = created(path)
                if (born ?? .distantPast) > since { kind = .new }
            }
            if let kind {
                all.append(FolderChange(node: n, path: path, kind: kind, before: before, now: now,
                                        created: born ?? created(path)))
            }
            let join = path.hasSuffix("/") ? path : path + "/"
            for c in n.children { walk(c, join + c.name) }
        }
        walk(root, root.name)

        if !nested {
            let byNode = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            var explained: [ObjectIdentifier: Int64] = [:]
            var drop = Set<ObjectIdentifier>()
            for c in all {
                var p = c.node.parent
                while let a = p {
                    if let fa = byNode[a.id] {
                        if fa.kind == .new { drop.insert(c.id) } else { explained[fa.id, default: 0] += c.delta }
                        break
                    }
                    p = a.parent
                }
            }
            for c in all where c.kind != .new {
                if Double(explained[c.id] ?? 0) >= 0.75 * Double(c.delta) { drop.insert(c.id) }
            }
            all.removeAll { drop.contains($0.id) }
        }
        return all.sorted { $0.delta > $1.delta }
    }
}
