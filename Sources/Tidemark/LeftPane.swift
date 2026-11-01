import SwiftUI

struct TreePane: View {
    @EnvironmentObject private var m: AppModel

    var body: some View {
        if let root = m.root {
            ScrollViewReader { proxy in
                List(selection: $m.selection) {
                    TreeNodeView(node: root)
                }
                .listStyle(.plain)
                .onChange(of: m.scrollTarget) { _, target in
                    guard let target else { return }
                    DispatchQueue.main.async { proxy.scrollTo(target.id) }
                }
            }
        } else if m.scanning {
            ScanningView()
        } else {
            ContentUnavailableView {
                Label("Tidemark", systemImage: "externaldrive")
            } description: {
                Text("Pick a disk below, or open a folder to scan.")
            } actions: {
                Button("Choose Folder…") { m.chooseFolder() }
            }
        }
    }
}

private struct ScanningView: View {
    @EnvironmentObject private var m: AppModel

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Scanning…").font(.headline)
            Text("\(Fmt.count(m.progress.files)) files, \(Fmt.count(m.progress.dirs)) folders · \(Fmt.size(m.progress.bytes, m.unit))")
                .monospacedDigit()
            Text(m.progress.currentPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 420)
            Button("Cancel") { m.cancelScan() }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TreeNodeView: View {
    let node: DirNode
    @EnvironmentObject private var m: AppModel

    var body: some View {
        if node.children.isEmpty {
            TreeRow(node: node)
        } else {
            DisclosureGroup(isExpanded: m.isExpanded(node)) {
                ForEach(node.sortedChildren(m.mode)) { TreeNodeView(node: $0) }
            } label: {
                TreeRow(node: node)
            }
        }
    }
}

private struct TreeRow: View {
    let node: DirNode
    @EnvironmentObject private var m: AppModel

    var body: some View {
        let v = node.value(m.mode)
        let pv = node.parent?.value(m.mode) ?? v
        let frac = pv > 0 ? Double(v) / Double(pv) : 0
        HStack(spacing: 6) {
            Text(Fmt.size(v, m.unit))
                .monospacedDigit()
                .frame(minWidth: 68, alignment: .trailing)
            Image(systemName: node.inaccessible ? "exclamationmark.triangle.fill" : "folder.fill")
                .foregroundStyle(node.inaccessible ? Color.orange : Color.yellow)
            Text(node.name).lineLimit(1)
            if let c = m.changeByNode[node.id] { ChangeBadge(change: c) }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(alignment: .leading) {
            GeometryReader { g in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.yellow.opacity(0.22))
                    .frame(width: g.size.width * frac)
            }
        }
        .help(node.inaccessible ? "\(node.path)\nAccess denied" : node.path)
        .tag(Optional(node))
        .id(node.id)
        .contextMenu {
            PathMenu(path: node.path)
            if node.parent != nil {
                Divider()
                Button("Move to Trash…", role: .destructive) {
                    m.moveToTrash(path: node.path, node: node, parent: nil)
                }
            }
        }
    }
}

struct PathMenu: View {
    let path: String

    var body: some View {
        Button("Show in Finder") { AppModel.reveal(path) }
        Button("Open") { AppModel.open(path) }
        Divider()
        Button("Copy Path") { AppModel.copy(path) }
    }
}

struct DiskListView: View {
    @EnvironmentObject private var m: AppModel

    var body: some View {
        Table(m.volumes, selection: $m.selectedVolumeID) {
            TableColumn("Disk") { v in
                HStack(spacing: 6) {
                    Image(nsImage: v.icon).resizable().frame(width: 16, height: 16)
                    Text(v.name).lineLimit(1)
                }
                .help(v.id)
            }
            .width(min: 120, ideal: 220)
            TableColumn("Total") { v in
                Text(Fmt.size(v.total, m.unit)).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 100)
            TableColumn("Free") { v in
                Text(Fmt.size(v.free, m.unit)).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 100)
            TableColumn("% Free") { v in
                PercentBar(fraction: v.freeFraction, tint: v.freeFraction < 0.1 ? .orange : .green)
            }
            .width(min: 90, ideal: 200)
        }
        .background(FitTableColumns())
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first {
                Button("Scan") { m.scan(path: id) }
                PathMenu(path: id)
            }
        }
        .onChange(of: m.selectedVolumeID) { _, id in
            if let id { m.scan(path: id) }
        }
    }
}

/// SwiftUI's Table starts its columns at their ideal widths, so in a narrow pane the rightmost ones
/// begin off-screen. Placed as the table's background, this scales the columns to fill the visible
/// width whenever that width changes.
private struct FitTableColumns: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ v: Probe, context: Context) {}

    final class Probe: NSView {
        private weak var table: NSTableView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, table == nil else { return }
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        private func attach() {
            var ancestor = superview
            while let a = ancestor, table == nil {
                table = Self.firstTable(in: a)
                ancestor = a.superview
            }
            guard let clip = table?.enclosingScrollView?.contentView else { return }
            clip.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(fit), name: NSView.frameDidChangeNotification, object: clip)
            fit()
        }

        private static func firstTable(in view: NSView) -> NSTableView? {
            if let t = view as? NSTableView { return t }
            for sub in view.subviews { if let t = firstTable(in: sub) { return t } }
            return nil
        }

        @objc private func fit() {
            guard let table, let clip = table.enclosingScrollView?.contentView,
                  let last = table.tableColumns.indices.last else { return }
            // The inset table style pads both ends by the first column's offset.
            let inset = table.rect(ofColumn: 0).minX
            // Columns that hit their minimum stop shrinking, so repeat over the rest.
            for _ in 0..<3 {
                let overflow = table.rect(ofColumn: last).maxX + inset - clip.bounds.width
                let flexible = table.tableColumns.filter { overflow < 0 || $0.width > $0.minWidth }
                let total = flexible.reduce(0) { $0 + $1.width }
                guard abs(overflow) > 1, total > 0 else { break }
                let scale = (total - overflow) / total
                for c in flexible { c.width = max(c.minWidth, (c.width * scale).rounded(.down)) }
            }
        }
    }
}

struct PercentBar: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.85))
                    .frame(width: g.size.width * max(0, min(1, fraction)))
            }
        }
        .overlay(Text(Fmt.pct(fraction)).font(.caption).monospacedDigit())
        .frame(height: 16)
    }
}
