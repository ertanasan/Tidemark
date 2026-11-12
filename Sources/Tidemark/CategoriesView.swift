import SwiftUI

/// The Changes list regrouped by app or tool, each with what it is and whether it's safe to delete.
struct CategoriesView: View {
    let rows: [FolderChange]
    @EnvironmentObject private var m: AppModel
    @State private var selection = Set<String>()

    struct Item: Identifiable {
        let id: String
        let name: String
        /// nil for a category row.
        let change: FolderChange?
        let info: Classification?
        let now: Int64
        let delta: Int64
        /// Space freed by deleting what is safe to delete.
        let free: Int64
        var children: [Item]?
    }

    /// With "Show nested" on, a flagged parent and its flagged subfolders both appear in `rows`.
    /// Only the deepest ones are kept so a gigabyte isn't counted twice.
    private var leaves: [FolderChange] {
        var hasFlaggedChild = Set<ObjectIdentifier>()
        for c in rows {
            var p = c.node.parent
            while let a = p { hasFlaggedChild.insert(a.id); p = a.parent }
        }
        return rows.filter { !hasFlaggedChild.contains($0.id) }
    }

    private var items: [Item] {
        let classified = leaves.map { ($0, Knowledge.classify($0.path)) }
        return Dictionary(grouping: classified, by: { $0.1.app }).map { app, group in
            let kids = group.map { c, info in
                Item(id: "f" + c.path, name: Knowledge.display(c.path), change: c, info: info,
                     now: c.now, delta: c.delta, free: info.safety.deletable ? c.now : 0, children: nil)
            }
            .sorted { $0.delta > $1.delta }
            return Item(id: "c" + app, name: app, change: nil, info: nil,
                        now: kids.reduce(0) { $0 + $1.now }, delta: kids.reduce(0) { $0 + $1.delta },
                        free: kids.reduce(0) { $0 + $1.free }, children: kids)
        }
        .sorted { $0.delta > $1.delta }
    }

    var body: some View {
        let items = items
        let byID = Dictionary(items.flatMap { [$0] + ($0.children ?? []) }.map { ($0.id, $0) },
                              uniquingKeysWith: { a, _ in a })
        VStack(spacing: 0) {
            Table(items, children: \.children, selection: $selection) {
                TableColumn("Name") { i in
                    HStack(spacing: 6) {
                        Image(systemName: i.change == nil ? "square.stack.3d.up.fill" : "folder.fill")
                            .foregroundStyle(i.change == nil ? Color.accentColor : .yellow)
                        Text(i.name).fontWeight(i.change == nil ? .semibold : .regular)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .help(i.change?.path ?? i.name)
                }
                .width(min: 200, ideal: 340)
                TableColumn("What to do") { i in
                    if let s = i.info?.safety { SafetyBadge(safety: s) }
                }
                .width(min: 150, ideal: 180)
                TableColumn("Now") { i in
                    Text(Fmt.size(i.now, m.unit)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 70, ideal: 90)
                TableColumn("Change") { i in
                    Text("+" + Fmt.size(i.delta, m.unit)).fontWeight(.semibold).monospacedDigit()
                        .foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 80, ideal: 100)
                TableColumn("Can free") { i in
                    Text(i.free > 0 ? Fmt.size(i.free, m.unit) : "—").monospacedDigit()
                        .foregroundStyle(i.free > 0 ? Color.green : .secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 80, ideal: 100)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                let picked = ids.compactMap { byID[$0] }
                let folders = picked.flatMap { $0.change.map { [$0] } ?? ($0.children ?? []).compactMap(\.change) }
                FolderPathsMenu(allPaths: leaves.map(\.path), selectedPaths: folders.map(\.path))
                if picked.count == 1, let c = picked[0].change, let info = picked[0].info {
                    Divider()
                    Button("Go to Folder") { m.navigate(to: c.node) }
                    PathMenu(path: c.path)
                    if info.safety.deletable, c.node.parent != nil {
                        Divider()
                        Button("Move to Trash…", role: .destructive) {
                            m.moveToTrash(path: c.path, node: c.node, parent: nil, note: info.advice)
                        }
                    }
                }
            } primaryAction: { ids in
                if let c = ids.compactMap({ byID[$0]?.change }).first { m.navigate(to: c.node) }
            }
            Divider()
            detail(for: selection.count == 1 ? selection.first.flatMap { byID[$0] } : nil)
        }
    }

    @ViewBuilder
    private func detail(for item: Item?) -> some View {
        Group {
            if let c = item?.change, let info = item?.info {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(info.what).font(.headline)
                        SafetyBadge(safety: info.safety)
                        Spacer()
                        Button("Go to Folder") { m.navigate(to: c.node) }
                        Button("Show in Finder") { AppModel.reveal(c.path) }
                        if info.safety.deletable, c.node.parent != nil {
                            Button("Move to Trash…", role: .destructive) {
                                m.moveToTrash(path: c.path, node: c.node, parent: nil, note: info.advice)
                            }
                        }
                    }
                    Text(info.advice).fixedSize(horizontal: false, vertical: true)
                    Text(c.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle)
                }
            } else if let item, let kids = item.children {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.headline)
                    Text("\(kids.count) folder\(kids.count == 1 ? "" : "s") grew by \(Fmt.size(item.delta, m.unit)) in total, now using \(Fmt.size(item.now, m.unit)).")
                    Text(item.free > 0
                         ? "\(Fmt.size(item.free, m.unit)) of it can be freed by deleting what is safe to delete. Select a folder for details."
                         : "Nothing here is marked safe to delete directly. Select a folder to see what to do.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Select a category or folder to see what it is and whether it's safe to delete.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .padding(10)
        .background(.bar)
    }
}

struct SafetyBadge: View {
    let safety: Safety

    var body: some View {
        Label(safety.label, systemImage: safety.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(safety.color)
            .lineLimit(1)
    }
}
