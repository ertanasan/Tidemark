import SwiftUI

/// Folders that are new, went past the threshold, or grew by it since the chosen baseline.
struct ChangesView: View {
    let node: DirNode
    @EnvironmentObject private var m: AppModel
    @State private var sortOrder = [KeyPathComparator(\FolderChange.delta, order: .reverse)]
    @State private var selection = Set<ObjectIdentifier>()

    private static let thresholds: [Int64] = [256 << 20, 512 << 20, 1 << 30, 5 << 30, 10 << 30]
    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    /// Changes inside the selected folder.
    private var rows: [FolderChange] {
        let base = node.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return m.changes.filter { $0.path == base || $0.path.hasPrefix(prefix) }.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if m.baselines.isEmpty {
                Text("First scan of this location. Showing folders created recently; rescan later to also catch existing folders that grew.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.08))
            }
            let rows = rows
            if rows.isEmpty {
                if m.computingChanges {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("No Big Changes", systemImage: "checkmark.circle",
                                           description: Text(emptyText))
                }
            } else {
                table(rows)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("Compare with", selection: $m.baseline) {
                ForEach(m.baselines) { ref in
                    Text(label(ref)).tag(Optional(Baseline.snapshot(ref)))
                }
                if !m.baselines.isEmpty { Divider() }
                Text("Created in the last 7 days").tag(Optional(Baseline.createdWithin(days: 7)))
                Text("Created in the last 30 days").tag(Optional(Baseline.createdWithin(days: 30)))
                Text("Created in the last 90 days").tag(Optional(Baseline.createdWithin(days: 90)))
            }
            .fixedSize()
            Picker("Over", selection: $m.changeThreshold) {
                ForEach(Self.thresholds, id: \.self) { Text(Fmt.size($0)).tag($0) }
            }
            .fixedSize()
            Toggle("Show nested", isOn: $m.showNestedChanges)
                .help("Also list parent folders whose growth comes from a flagged subfolder")
            Spacer()
            Toggle("Daily idle scan of main drive", isOn: $m.idleScanEnabled)
                .help("Once a day, when the Mac has been idle for 10 minutes on AC power, scan / in the background and notify about big changes")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func table(_ rows: [FolderChange]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Folder", value: \.path) { c in
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").foregroundStyle(.yellow)
                    Text(relative(c.path)).lineLimit(1).truncationMode(.middle)
                }
                .help(c.path)
            }
            .width(min: 180, ideal: 320)
            TableColumn("Status", value: \.status) { c in ChangeBadge(change: c, compact: false) }
                .width(min: 70, ideal: 80)
            TableColumn("Before", value: \.beforeSort) { c in
                Text(c.before.map { Fmt.size($0, m.unit) } ?? (c.kind == .new ? "—" : "< \(Fmt.size(SnapshotStore.floor))"))
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Now", value: \.now) { c in
                Text(Fmt.size(c.now, m.unit)).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Change", value: \.delta) { c in
                Text("+" + Fmt.size(c.delta, m.unit)).fontWeight(.semibold).monospacedDigit()
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 100)
            TableColumn("Created", value: \.createdSort) { c in
                Text(c.created.map(Fmt.date) ?? "").monospacedDigit()
            }
            .width(min: 110, ideal: 130)
        }
        .contextMenu(forSelectionType: ObjectIdentifier.self) { ids in
            let selectedRows = rows.filter { ids.contains($0.id) }
            FolderPathsMenu(allPaths: rows.map(\.path), selectedPaths: selectedRows.map(\.path))
            if let c = rows.first(where: { ids.contains($0.id) }) {
                Divider()
                Button("Go to Folder") { m.navigate(to: c.node) }
                PathMenu(path: c.path)
                if c.node.parent != nil {
                    Divider()
                    Button("Move to Trash…", role: .destructive) {
                        m.moveToTrash(path: c.path, node: c.node, parent: nil)
                    }
                }
            }
        } primaryAction: { ids in
            if let c = rows.first(where: { ids.contains($0.id) }) { m.navigate(to: c.node) }
        }
    }

    private func label(_ ref: SnapshotRef) -> String {
        var s = "Scan of \(Fmt.date(ref.date)) (\(Self.rel.localizedString(for: ref.date, relativeTo: Date())))"
        if ref.root != m.root?.name { s += " of \(ref.root)" }
        return s
    }

    private func relative(_ path: String) -> String {
        let base = node.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path == base ? (path as NSString).lastPathComponent : String(path.dropFirst(prefix.count))
    }

    private var emptyText: String {
        let t = Fmt.size(m.changeThreshold)
        switch m.baseline {
        case .createdWithin(let days)?: return "No folder over \(t) was created in the last \(days) days."
        default: return "No folder over \(t) is new, went past \(t), or grew by \(t) since that scan."
        }
    }
}

struct ChangeBadge: View {
    let change: FolderChange
    var compact = true

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.2)))
            .foregroundStyle(color)
            .help(help)
    }

    private var text: String {
        switch change.kind {
        case .new: return "NEW"
        case .crossed, .grew: return compact ? "+" + Fmt.size(change.delta) : change.kind.rawValue.uppercased()
        }
    }

    private var color: Color { change.kind == .new ? .red : .orange }

    private var help: String {
        let now = Fmt.size(change.now)
        switch change.kind {
        case .new: return "New folder, \(now)"
        case .crossed: return "Grew to \(now) (was \(change.before.map { Fmt.size($0) } ?? "< \(Fmt.size(SnapshotStore.floor))"))"
        case .grew: return "Grew by \(Fmt.size(change.delta)) to \(now)"
        }
    }
}
