import Foundation

/// The full tree of the latest scan of each location, so the app can show it at launch while a
/// fresh scan runs. ~/Library/Caches/Tidemark/Trees/<percent-encoded root>.tree, LZFSE-compressed.
enum TreeCache {
    private static let magic: UInt32 = 0x3143_5354   // "TSC1"
    /// Locations not scanned for this long lose their cache.
    private static let maxAge: TimeInterval = 30 * 86400

    private static var dir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tidemark/Trees", isDirectory: true)
    }

    private static func file(for root: String) -> URL {
        let name = root.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? root
        return dir.appendingPathComponent(name + ".tree")
    }

    /// Serializes the tree. Call before anything else can edit it (e.g. before handing it to the UI).
    static func encode(_ r: ScanResult, date: Date) -> Data {
        var w = Writer()
        w.int(magic)
        w.double(date.timeIntervalSince1970)
        w.int(Int64(r.excluded)); w.int(Int64(r.errors)); w.double(r.duration)
        func node(_ n: DirNode) {
            w.string(n.name)
            w.double(n.mtime)
            w.int(UInt8(n.inaccessible ? 1 : 0))
            w.int(UInt32(n.ownErrors))
            w.int(UInt32(n.files.count))
            for f in n.files { w.string(f.name); w.int(f.size); w.int(f.alloc); w.double(f.mtime) }
            w.int(UInt32(n.children.count))
            for c in n.children { node(c) }
        }
        node(r.root)
        return Data(w.buf)
    }

    static func write(_ data: Data, root: String) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try (data as NSData).compressed(using: .lzfse).write(to: file(for: root), options: .atomic)
        } catch {
            NSLog("Tidemark: couldn't cache scan: \(error)")
        }
        let old = Date().addingTimeInterval(-maxAge)
        for u in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where ((try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) < old {
            try? FileManager.default.removeItem(at: u)
        }
    }

    static func load(root: String) -> (result: ScanResult, date: Date)? {
        guard let packed = try? Data(contentsOf: file(for: root)),
              let data = try? (packed as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return data.withUnsafeBytes { p -> (ScanResult, Date)? in
            var r = Reader(p: p)
            func node(_ parent: DirNode?) throws -> DirNode {
                let n = DirNode(name: try r.string(), parent: parent)
                n.mtime = try r.double()
                n.inaccessible = try r.int(UInt8.self) != 0
                n.ownErrors = Int(try r.int(UInt32.self))
                for _ in 0..<(try r.int(UInt32.self)) {
                    n.files.append(FileItem(name: try r.string(), size: try r.int(Int64.self),
                                            alloc: try r.int(Int64.self), mtime: try r.double()))
                }
                for _ in 0..<(try r.int(UInt32.self)) { n.children.append(try node(n)) }
                return n
            }
            do {
                guard try r.int(UInt32.self) == magic else { return nil }
                let date = Date(timeIntervalSince1970: try r.double())
                let excluded = Int(try r.int(Int64.self)), errors = Int(try r.int(Int64.self))
                let duration = try r.double()
                let root = try node(nil)
                guard r.i == p.count else { return nil }
                DiskScanner.finalize(root)
                return (ScanResult(root: root, excluded: excluded, errors: errors, duration: duration), date)
            } catch {
                return nil
            }
        }
    }

    private struct Writer {
        var buf: [UInt8] = []
        mutating func int<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { buf.append(contentsOf: $0) } }
        mutating func double(_ v: Double) { int(v.bitPattern) }
        mutating func string(_ s: String) {
            var s = s
            s.withUTF8 { u in int(UInt32(u.count)); buf.append(contentsOf: u) }
        }
    }

    private struct Reader {
        struct Truncated: Error {}
        let p: UnsafeRawBufferPointer
        var i = 0
        mutating func int<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let n = MemoryLayout<T>.size
            guard i + n <= p.count else { throw Truncated() }
            defer { i += n }
            return T(littleEndian: p.loadUnaligned(fromByteOffset: i, as: T.self))
        }
        mutating func double() throws -> Double { Double(bitPattern: try int(UInt64.self)) }
        mutating func string() throws -> String {
            let n = Int(try int(UInt32.self))
            guard i + n <= p.count else { throw Truncated() }
            defer { i += n }
            return String(decoding: UnsafeRawBufferPointer(rebasing: p[i..<i + n]), as: UTF8.self)
        }
    }
}
