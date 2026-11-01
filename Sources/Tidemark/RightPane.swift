import SwiftUI

struct FolderPathsMenu: View {
    let allPaths: [String]
    var selectedPaths: [String] = []

    var body: some View {
        if selectedPaths.count > 1 {
            Button("Copy Selected Folder Paths") {
                AppModel.copy(unique(selectedPaths).joined(separator: "\n"))
            }
            Divider()
        }
        Button("Copy All Folder Paths") {
            AppModel.copy(unique(allPaths).joined(separator: "\n"))
        }
        .disabled(allPaths.isEmpty)
    }

    private func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}

struct RightPane: View {
    @EnvironmentObject private var m: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $m.tab) {
                ForEach(DetailTab.allCases) { t in
                    Text(t == .changes && !m.changes.isEmpty ? "\(t.rawValue) (\(m.changes.count))" : t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            if !m.hasFullDiskAccess { AccessBanner() }
            if let node = m.selected {
                switch m.tab {
                case .chart: TreemapView(node: node)
                case .details: DetailsView(node: node)
                case .extensions: ExtensionsView(node: node)
                case .largest: LargestFilesView(node: node)
                case .changes: ChangesView(node: node)
                }
            } else {
                Color.clear
            }
        }
    }
}

private struct AccessBanner: View {
    @EnvironmentObject private var m: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "lock.shield").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Full Disk Access not granted: totals will appear low").fontWeight(.semibold)
                Text("Protected folders (Library/Containers, Group Containers, Mail, Messages, Photos…) can’t be read and aren’t counted. Turn on “Tidemark” in Settings (if it isn’t listed, add the app with +), then rescan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open Settings") { m.openFullDiskAccessSettings() }
            Button("Show App in Finder") { m.revealApp() }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }
}

// MARK: Details

struct DetailRow: Identifiable {
    var id: String { name }
    let name: String
    let node: DirNode?
    let path: String
    let size: Int64
    let alloc: Int64
    let files: Int
    let dirs: Int
    let pct: Double
    let modified: Date
    let inaccessible: Bool

    static func rows(for n: DirNode, mode: SizeMode) -> [DetailRow] {
        let total = Double(max(1, n.value(mode)))
        let base = n.path
        let join = base.hasSuffix("/") ? base : base + "/"
        var rows = n.children.map { c in
            DetailRow(name: c.name, node: c, path: join + c.name, size: c.size, alloc: c.alloc,
                      files: c.fileCount, dirs: c.dirCount, pct: Double(c.value(mode)) / total,
                      modified: Date(timeIntervalSince1970: c.mtime), inaccessible: c.inaccessible)
        }
        rows += n.files.map { f in
            DetailRow(name: f.name, node: nil, path: join + f.name, size: f.size, alloc: f.alloc,
                      files: 1, dirs: -1, pct: Double(mode == .logical ? f.size : f.alloc) / total,
                      modified: Date(timeIntervalSince1970: f.mtime), inaccessible: false)
        }
        return rows
    }
}

struct DetailsView: View {
    let node: DirNode
    @EnvironmentObject private var m: AppModel
    @State private var sortOrder = [KeyPathComparator(\DetailRow.pct, order: .reverse)]
    @State private var rows: [DetailRow] = []
    @State private var selection = Set<String>()

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { r in
                HStack(spacing: 6) {
                    Image(systemName: r.inaccessible ? "exclamationmark.triangle.fill" : r.node != nil ? "folder.fill" : "doc")
                        .foregroundStyle(r.inaccessible ? Color.orange : r.node != nil ? Color.yellow : Color.secondary)
                        .frame(width: 16)
                    Text(r.name).lineLimit(1)
                }
                .help(r.path)
            }
            .width(min: 160, ideal: 280)
            TableColumn("Size", value: \.size) { r in
                Text(Fmt.size(r.size, m.unit)).fontWeight(m.mode == .logical ? .semibold : .regular)
                    .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 95)
            TableColumn("On Disk", value: \.alloc) { r in
                Text(Fmt.size(r.alloc, m.unit)).fontWeight(m.mode == .alloc ? .semibold : .regular)
                    .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 95)
            TableColumn("Files", value: \.files) { r in
                Text(Fmt.count(r.files)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 70)
            TableColumn("Folders", value: \.dirs) { r in
                Text(r.dirs >= 0 ? Fmt.count(r.dirs) : "").monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 70)
            TableColumn("% of Parent", value: \.pct) { r in PercentBar(fraction: r.pct) }
                .width(min: 90, ideal: 120)
            TableColumn("Last Modified", value: \.modified) { r in Text(Fmt.date(r.modified)).monospacedDigit() }
                .width(min: 110, ideal: 130)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let selectedRows = rows.filter { ids.contains($0.id) }
            FolderPathsMenu(
                allPaths: rows.filter { $0.node != nil }.map(\.path),
                selectedPaths: selectedRows.filter { $0.node != nil }.map(\.path)
            )
            if let r = selectedRows.first {
                Divider()
                if let n = r.node { Button("Go to Folder") { m.navigate(to: n) } }
                PathMenu(path: r.path)
                Divider()
                Button("Move to Trash…", role: .destructive) {
                    m.moveToTrash(path: r.path, node: r.node, parent: node)
                }
            }
        } primaryAction: { ids in
            guard let r = rows.first(where: { ids.contains($0.id) }) else { return }
            if let n = r.node { m.navigate(to: n) } else { AppModel.reveal(r.path) }
        }
        .onAppear(perform: reload)
        .onChange(of: node) { reload() }
        .onChange(of: m.mode) { reload() }
        .onChange(of: m.treeVersion) { reload() }
        .onChange(of: sortOrder) { rows.sort(using: sortOrder) }
    }

    private func reload() {
        rows = DetailRow.rows(for: node, mode: m.mode).sorted(using: sortOrder)
        selection = []
    }
}

// MARK: Extensions

struct ExtensionsView: View {
    let node: DirNode
    @EnvironmentObject private var m: AppModel
    @State private var rows: [Analysis.ExtRow] = []
    @State private var sortOrder = [KeyPathComparator(\Analysis.ExtRow.pct, order: .reverse)]

    private var folderPaths: [String] {
        var paths = [node.path]
        func appendChildren(of folder: DirNode) {
            for child in folder.children {
                paths.append(child.path)
                appendChildren(of: child)
            }
        }
        appendChildren(of: node)
        return paths
    }

    var body: some View {
        Table(rows, sortOrder: $sortOrder) {
            TableColumn("Extension", value: \.ext) { r in Text(r.ext) }
                .width(min: 100, ideal: 180)
            TableColumn("Size", value: \.size) { r in
                Text(Fmt.size(r.size, m.unit)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            TableColumn("On Disk", value: \.alloc) { r in
                Text(Fmt.size(r.alloc, m.unit)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            TableColumn("Files", value: \.count) { r in
                Text(Fmt.count(r.count)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            TableColumn("%", value: \.pct) { r in PercentBar(fraction: r.pct) }
                .width(min: 90, ideal: 140)
        }
        .contextMenu {
            FolderPathsMenu(allPaths: folderPaths)
        }
        .onChange(of: sortOrder) { rows.sort(using: sortOrder) }
        .task(id: TaskKey(node: node, mode: m.mode, version: m.treeVersion)) {
            let n = node, mode = m.mode
            let result = await Task.detached { Analysis.extensions(of: n, mode: mode) }.value
            rows = result.sorted(using: sortOrder)
        }
    }
}

// MARK: Largest files

struct LargestFilesView: View {
    let node: DirNode
    @EnvironmentObject private var m: AppModel
    @State private var rows: [Analysis.BigFile] = []
    @State private var selection = Set<Int>()

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("Name") { r in
                HStack(spacing: 6) {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                    Text(r.name).lineLimit(1)
                }
                .help(r.path)
            }
            .width(min: 150, ideal: 240)
            TableColumn("Size") { r in
                Text(Fmt.size(r.size, m.unit)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
            TableColumn("On Disk") { r in
                Text(Fmt.size(r.alloc, m.unit)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Folder") { r in
                Text(r.folder).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            .width(min: 150, ideal: 320)
            TableColumn("Last Modified") { r in Text(Fmt.date(r.modified)).monospacedDigit() }
                .width(min: 110, ideal: 130)
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            let selectedPaths = rows.filter { ids.contains($0.id) }.map(\.folder)
            FolderPathsMenu(allPaths: rows.map(\.folder), selectedPaths: selectedPaths)
            if let id = ids.first, id < rows.count { PathMenu(path: rows[id].path) }
        } primaryAction: { ids in
            if let id = ids.first, id < rows.count { AppModel.reveal(rows[id].path) }
        }
        .task(id: TaskKey(node: node, mode: m.mode, version: m.treeVersion)) {
            let n = node, mode = m.mode
            rows = await Task.detached { Analysis.largest(in: n, mode: mode) }.value
        }
    }
}

struct TaskKey: Hashable {
    let node: DirNode
    let mode: SizeMode
    var version = 0
}
