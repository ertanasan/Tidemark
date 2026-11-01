import AppKit
import CoreGraphics
import CoreServices
import IOKit.ps
import IOKit.pwr_mgt
import UserNotifications

/// Scan of the main drive once a day while the Mac is idle. A LaunchAgent starts the app
/// binary with `--idle-scan` every 15 minutes; that headless run scans only when `/` hasn't been
/// scanned today, there's been no input for a while, and the Mac is on AC power. It saves a
/// snapshot (so the Changes tab has a baseline) and notifies about big changes. Between weekly full
/// scans it only re-reads the folders FSEvents says changed since the last one.
enum IdleScan {
    static let flag = "--idle-scan"
    static let label = "com.aeroglu.tidemark.idlescan"
    static let root = "/"
    static let checkInterval = 15 * 60
    static let requiredIdle: Double = 10 * 60
    /// Catches anything incremental scans missed.
    static let fullScanInterval: TimeInterval = 7 * 86400
    // Where FSEvents was at the last idle scan, so the next can pick up from there.
    private static let eventIdKey = "idleScanEventId", volumeKey = "idleScanVolume"
    private static let scanDateKey = "idleScanDate", fullScanDateKey = "idleScanFullDate"

    // MARK: LaunchAgent

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func setEnabled(_ on: Bool) throws {
        let domain = "gui/\(getuid())"
        launchctl(["bootout", "\(domain)/\(label)"])   // fine if it wasn't loaded
        if on {
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [Bundle.main.executablePath ?? "", flag],
                "StartInterval": checkInterval,
                "ProcessType": "Background",
                "StandardErrorPath": FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Logs/Tidemark-idlescan.log").path,
            ]
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: plistURL, options: .atomic)
            launchctl(["bootstrap", domain, plistURL.path])
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        } else if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private static func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: Headless run

    static func run() -> Never {
        let earlier = SnapshotStore.list(covering: root).filter { $0.root == root }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                           eventType: CGEventType(rawValue: ~0)!)
        if !CommandLine.arguments.contains("--force") {   // --force: run now, for testing
            if let last = earlier.first, Calendar.current.isDateInToday(last.date) { exit(0) }
            guard idle >= requiredIdle, onACPower() else { exit(0) }
        }

        log("idle \(Int(idle))s, scanning \(root)")
        var assertion: IOPMAssertionID = 0
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Tidemark idle scan" as CFString, &assertion)
        defer { IOPMAssertionRelease(assertion) }

        // Taken before scanning, so changes made during the scan are picked up next time.
        let eventId = FSEventsGetCurrentEventId()
        let full: Bool
        let result: ScanResult
        if let r = incrementalScan() {
            (full, result) = (false, r)
        } else if let r = DiskScanner.scan(path: root, progress: ScanProgress()) {
            (full, result) = (true, r)
        } else {
            log("scan failed")
            exit(1)
        }
        let date = Date()
        TreeCache.write(TreeCache.encode(result, date: date), root: result.root.name)   // shown at next launch
        SnapshotStore.save(root: result.root, date: date)
        let d = UserDefaults.standard
        d.set(NSNumber(value: eventId), forKey: eventIdKey)
        d.set(volumeUUID(), forKey: volumeKey)
        d.set(date, forKey: scanDateKey)
        if full { d.set(date, forKey: fullScanDateKey) }
        log("saved snapshot of \(full ? "full" : "incremental") scan in \(Int(result.duration))s")

        guard let base = earlier.first, let snap = SnapshotStore.load(base) else { exit(0) }
        let threshold = UserDefaults.standard.object(forKey: "changeThreshold") as? Int64 ?? 1 << 30
        let changes = ChangeFinder.find(root: result.root, snapshot: snap, since: base.date,
                                        threshold: threshold, mode: .alloc, nested: false)
        log("\(changes.count) change(s) since \(Fmt.date(base.date))")
        if !changes.isEmpty { notify(changes, since: base) }
        exit(0)
    }

    /// The cached tree of `/` with the folders that changed since it was made re-read, or nil when
    /// a full scan is due or needed.
    private static func incrementalScan() -> ScanResult? {
        let d = UserDefaults.standard
        guard let lastFull = d.object(forKey: fullScanDateKey) as? Date,
              Date().timeIntervalSince(lastFull) < fullScanInterval,
              let since = d.object(forKey: eventIdKey) as? NSNumber,
              let volume = volumeUUID(), d.string(forKey: volumeKey) == volume,
              let scanned = d.object(forKey: scanDateKey) as? Date,
              // The app may have cached a newer scan since, which is fine; an older one isn't.
              let cached = TreeCache.load(root: root), cached.date >= scanned.addingTimeInterval(-1),
              let changed = changedFolders(since: since.uint64Value) else { return nil }
        log("\(changed.count) folder(s) changed since \(Fmt.date(scanned))")
        return DiskScanner.update(cached.result, changed: changed)
    }

    /// Folders FSEvents recorded changes in since `id`, true for those whose whole subtree must be
    /// rescanned. nil if the history can't be trusted.
    private static func changedFolders(since id: FSEventStreamEventId) -> [String: Bool]? {
        final class Box {
            var changed: [String: Bool] = [:]
            var complete = true
            var finished = false   // live events after the history are ignored
            let done = DispatchSemaphore(value: 0)
        }
        let box = Box()
        // Retained for good: this headless run exits soon, and no callback can outlive the box.
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(box).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            let box = Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue()
            guard !box.finished else { return }
            let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            for i in 0..<min(count, paths.count) {
                let f = Int(flags[i])
                if f & kFSEventStreamEventFlagHistoryDone != 0 { box.finished = true; box.done.signal(); return }
                if f & (kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged) != 0 {
                    box.complete = false
                }
                var p = paths[i]
                if p.count > 1 && p.hasSuffix("/") { p.removeLast() }
                box.changed[p] = box.changed[p] == true || f & kFSEventStreamEventFlagMustScanSubDirs != 0
            }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root] as CFArray, id, 0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes))
        else { return nil }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: label))
        FSEventStreamStart(stream)
        defer { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        guard box.done.wait(timeout: .now() + 120) == .success, box.complete else { return nil }
        return box.changed
    }

    /// Changes when the volume's FSEvents history is reset, which makes saved event ids meaningless.
    private static func volumeUUID() -> String? {
        var st = stat()
        guard stat(root, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private static func onACPower() -> Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }

    private static func notify(_ changes: [FolderChange], since base: SnapshotRef) {
        let total = changes.reduce(Int64(0)) { $0 + $1.delta }
        let content = UNMutableNotificationContent()
        content.title = changes.count == 1 ? "1 folder is using more space"
                                           : "\(changes.count) folders are using more space"
        content.body = changes.prefix(3).map { c in
            "\(c.kind == .new ? "New: " : "")\(c.path) (+\(Fmt.size(c.delta)))"
        }.joined(separator: "\n") + "\nTotal +\(Fmt.size(total)) since \(Fmt.date(base.date))"
        content.userInfo = ["root": root, "baseline": base.date.timeIntervalSince1970]
        let done = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: label, content: content,
                                                                     trigger: nil)) { error in
            if let error { log("notification failed: \(error)") }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
    }

    private static func log(_ s: String) {
        FileHandle.standardError.write(Data("\(Fmt.date(Date())) \(s)\n".utf8))
    }
}
