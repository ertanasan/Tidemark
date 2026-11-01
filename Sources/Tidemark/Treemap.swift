import SwiftUI

struct TreemapView: View {
    let node: DirNode
    @EnvironmentObject private var m: AppModel
    @State private var hover: Int?

    private struct Item {
        let name: String
        let value: Int64
        let node: DirNode?
        let isFile: Bool
    }

    private var items: [Item] {
        var all = node.children.map { Item(name: $0.name, value: $0.value(m.mode), node: $0, isFile: false) }
        all += node.files.map { Item(name: $0.name, value: m.mode == .logical ? $0.size : $0.alloc, node: nil, isFile: true) }
        all = all.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        let cap = 250
        if all.count > cap {
            let rest = all[cap...].reduce(Int64(0)) { $0 + $1.value }
            let restCount = all.count - cap
            all = Array(all.prefix(cap))
            all.append(Item(name: "Other (\(Fmt.count(restCount)))", value: rest, node: nil, isFile: true))
        }
        return all
    }

    var body: some View {
        let items = self.items
        let total = Double(max(1, node.value(m.mode)))
        VStack(spacing: 0) {
            GeometryReader { g in
                let rects = squarify(items.map { Double($0.value) }, in: CGRect(origin: .zero, size: g.size))
                Canvas { ctx, _ in
                    for (i, r) in rects.enumerated() {
                        let item = items[i]
                        let cell = r.insetBy(dx: 1, dy: 1)
                        guard cell.width > 0, cell.height > 0 else { continue }
                        let path = Path(roundedRect: cell, cornerRadius: 3)
                        ctx.fill(path, with: .color(color(i, item).opacity(hover == i ? 1 : 0.82)))
                        if hover == i { ctx.stroke(path, with: .color(.white), lineWidth: 2) }
                        if cell.width > 56 && cell.height > 30 {
                            let label = Text("\(item.name)\n\(Fmt.size(item.value, m.unit))")
                                .font(.caption)
                                .foregroundColor(.white)
                            ctx.draw(label, in: cell.insetBy(dx: 5, dy: 4))
                        }
                    }
                }
                .onContinuousHover { phase in
                    if case .active(let p) = phase {
                        hover = rects.firstIndex { $0.contains(p) }
                    } else {
                        hover = nil
                    }
                }
                .onTapGesture { p in
                    if let i = rects.firstIndex(where: { $0.contains(p) }), let n = items[i].node {
                        m.navigate(to: n)
                    }
                }
            }
            .padding(6)
            Divider()
            HStack {
                if let h = hover, h < items.count {
                    Image(systemName: items[h].isFile ? "doc" : "folder.fill")
                    Text(items[h].name).lineLimit(1)
                    Spacer()
                    Text("\(Fmt.size(items[h].value, m.unit)) · \(Fmt.pct(Double(items[h].value) / total))")
                        .monospacedDigit()
                } else {
                    Text("Click a folder to open it").foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
    }

    private func color(_ i: Int, _ item: Item) -> Color {
        if item.isFile { return Color(hue: 0.6, saturation: 0.15, brightness: 0.55) }
        return Color(hue: Double((i * 7) % 24) / 24, saturation: 0.55, brightness: 0.72)
    }
}

/// Squarified treemap layout (Bruls et al.). Values must be sorted descending.
func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
    var result = [CGRect](repeating: .zero, count: values.count)
    let total = values.reduce(0, +)
    guard total > 0, rect.width > 0, rect.height > 0 else { return result }
    let scale = Double(rect.width * rect.height) / total
    let areas = values.map { $0 * scale }
    var r = rect
    var i = 0

    func worst(_ sum: Double, _ mx: Double, _ mn: Double, _ side: Double) -> Double {
        let s2 = sum * sum, w2 = side * side
        return max(w2 * mx / s2, s2 / (w2 * mn))
    }

    while i < areas.count {
        let side = Double(min(r.width, r.height))
        guard side > 0 else { break }
        var sum = areas[i], mx = areas[i], mn = areas[i]
        var best = worst(sum, mx, mn, side)
        var j = i + 1
        while j < areas.count {
            let a = areas[j]
            let w = worst(sum + a, max(mx, a), min(mn, a), side)
            if w > best { break }
            sum += a; mx = max(mx, a); mn = min(mn, a); best = w
            j += 1
        }
        if r.width >= r.height {
            let w = CGFloat(sum / Double(r.height))
            var y = r.minY
            for k in i..<j {
                let h = CGFloat(areas[k]) / w
                result[k] = CGRect(x: r.minX, y: y, width: w, height: h)
                y += h
            }
            r = CGRect(x: r.minX + w, y: r.minY, width: max(0, r.width - w), height: r.height)
        } else {
            let h = CGFloat(sum / Double(r.width))
            var x = r.minX
            for k in i..<j {
                let w = CGFloat(areas[k]) / h
                result[k] = CGRect(x: x, y: r.minY, width: w, height: h)
                x += w
            }
            r = CGRect(x: r.minX, y: r.minY + h, width: r.width, height: max(0, r.height - h))
        }
        i = j
    }
    return result
}
