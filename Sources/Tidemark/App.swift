import AppKit
import SwiftUI
import UserNotifications

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains(IdleScan.flag) { IdleScan.run() }   // headless, never returns
        MainActor.assumeIsolated { TidemarkApp.main() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Clicking an idle-scan notification: rescan and show what changed since the scan it compared with.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let root = info["root"] as? String else { return }
        let baseline = (info["baseline"] as? Double).map(Date.init(timeIntervalSince1970:))
        await MainActor.run {
            NSApp.activate()
            AppModel.open(path: root, compareWith: baseline)
        }
    }

    /// Folders handed over by `open -b com.aeroglu.tidemark <path>`, e.g. the Finder
    /// "Open in Tidemark" Quick Action (scripts/Open in Tidemark.workflow).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: \.isFileURL) else { return }
        NSApp.activate()
        AppModel.open(path: url.path)
    }
}

struct TidemarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Tidemark", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .defaultSize(width: 1500, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose Folder…") { model.chooseFolder() }.keyboardShortcut("o")
                Button("Rescan") { model.rescan() }.keyboardShortcut("r")
                    .disabled(model.root == nil)
                Button("Parent Folder") { model.goUp() }.keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!model.canGoUp)
                Divider()
                Toggle("Scan Main Drive Daily When Idle", isOn: $model.idleScanEnabled)
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var m: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SummaryBar()
            Divider()
            SplitView(axis: .horizontal, autosaveName: "MainSplit", panes: [
                SplitPane(minSize: 280, initialFraction: 0.37, holding: .defaultLow + 1) {
                    SplitView(axis: .vertical, autosaveName: "LeftSplit", panes: [
                        SplitPane(minSize: 160, initialFraction: 0.65) { TreePane().environmentObject(m) },
                        SplitPane(minSize: 90, initialFraction: 0.35, holding: .defaultLow + 1) {
                            DiskListView().environmentObject(m)
                        },
                    ])
                },
                SplitPane(minSize: 420, initialFraction: 0.63) { RightPane().environmentObject(m) },
            ])
            Divider()
            StatusBar()
        }
        .navigationTitle(m.selected?.path ?? "Tidemark")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { m.goUp() } label: { Image(systemName: "arrow.up") }
                    .help("Parent folder")
                    .disabled(!m.canGoUp)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { m.chooseFolder() } label: { Image(systemName: "folder.badge.plus") }
                    .help("Choose folder…")
                Button { m.rescan() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan")
                    .disabled(m.root == nil || m.scanning)
                Picker("Measure", selection: $m.mode) {
                    Text("Size").tag(SizeMode.logical)
                    Text("Size on Disk").tag(SizeMode.alloc)
                }
                .pickerStyle(.segmented)
                .help("Show sizes by file size or by space allocated on disk")
                Menu {
                    Picker("Unit", selection: $m.unit) {
                        ForEach(SizeUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "ruler")
                }
                .help("Size unit")
            }
        }
    }
}

struct SummaryBar: View {
    @EnvironmentObject private var m: AppModel

    var body: some View {
        HStack(spacing: 16) {
            Text(m.selected?.path ?? "Choose a disk or folder")
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            if let n = m.selected {
                stat("Size", Fmt.size(n.size, m.unit))
                stat("On Disk", Fmt.size(n.alloc, m.unit))
                stat("Slack", Fmt.size(max(0, n.alloc - n.size), m.unit))
                stat("Files", Fmt.count(n.fileCount))
                stat("Folders", Fmt.count(n.dirCount))
                stat("Last Modified", Fmt.date(n.mtime))
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label + ":").foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject private var m: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if let v = m.rootVolume {
                Text("Free Space: \(Fmt.size(v.free, m.unit)) (total \(Fmt.size(v.total, m.unit)))")
                sep
            }
            if !m.blockInfo.isEmpty {
                Text(m.blockInfo)
                sep
            }
            if let r = m.root {
                Text("\(Fmt.count(r.fileCount)) Files, \(Fmt.count(r.dirCount)) Folders")
                sep
                Text("\(Fmt.count(m.stats.excluded)) Excluded")
                    .help(DiskScanner.excludedPaths(for: r.name).sorted().joined(separator: "\n"))
                sep
                Text("\(Fmt.count(m.stats.errors)) Access Denied")
                    .foregroundStyle(m.stats.errors > 0 ? Color.orange : Color.secondary)
                sep
                Text("Time: \(Fmt.seconds(m.stats.duration))")
            }
            Spacer()
            if m.root != nil {
                if let d = m.cachedScanDate {
                    Text("Showing scan of \(Fmt.date(d))")
                        .help("Saved from the last scan of this location")
                }
                if m.scanning {
                    ProgressView().controlSize(.mini)
                    Text("Refreshing… \(Fmt.count(m.progress.files)) files · \(Fmt.size(m.progress.bytes, m.unit))")
                        .help(m.progress.currentPath)
                    Button("Cancel") { m.cancelScan() }
                        .buttonStyle(.link)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var sep: some View { Divider().frame(height: 12) }
}
