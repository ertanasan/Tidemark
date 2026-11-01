import AppKit
import SwiftUI

/// One pane of a `SplitView`.
struct SplitPane {
    let content: AnyView
    var minSize: CGFloat
    /// Share of the split's length on first launch, before the user has dragged a divider.
    var initialFraction: CGFloat
    /// Higher-priority panes keep their size when the window resizes; the lowest absorbs the change.
    var holding: NSLayoutConstraint.Priority = .defaultLow

    init<V: View>(minSize: CGFloat, initialFraction: CGFloat,
                  holding: NSLayoutConstraint.Priority = .defaultLow, @ViewBuilder _ content: () -> V) {
        self.content = AnyView(content())
        self.minSize = minSize
        self.initialFraction = initialFraction
        self.holding = holding
    }
}

/// NSSplitView-backed replacement for HSplitView/VSplitView: draggable dividers that respect
/// minimum sizes and remember pane sizes across launches (under `autosaveName` in UserDefaults).
/// Panes are hosted in separate NSHostingControllers, so pass environment objects explicitly.
struct SplitView: NSViewControllerRepresentable {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    let autosaveName: String
    let panes: [SplitPane]

    func makeNSViewController(context: Context) -> Controller {
        let c = Controller()
        c.axis = axis
        c.fractions = panes.map(\.initialFraction)
        c.defaultsKey = "SplitView Pane Sizes \(autosaveName)"
        c.splitView.isVertical = axis == .horizontal
        c.splitView.dividerStyle = .thin
        for pane in panes {
            let host = NSHostingController(rootView: pane.content)
            host.sizingOptions = []
            let item = NSSplitViewItem(viewController: host)
            item.minimumThickness = pane.minSize
            item.holdingPriority = pane.holding
            item.canCollapse = false
            c.addSplitViewItem(item)
        }
        return c
    }

    func updateNSViewController(_ c: Controller, context: Context) {
        for (item, pane) in zip(c.splitViewItems, panes) {
            (item.viewController as? NSHostingController<AnyView>)?.rootView = pane.content
        }
    }

    /// NSSplitView's own autosave restores before SwiftUI gives the window its final size, and the
    /// later resize redistributes the panes. So sizes are saved here and applied once the window is up.
    final class Controller: NSSplitViewController {
        var axis: Axis = .horizontal
        var fractions: [CGFloat] = []
        var defaultsKey = ""
        private var restoring = false
        private var restored = false
        private var observer: NSObjectProtocol?

        override func viewDidLoad() {
            super.viewDidLoad()
            observer = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: splitView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.save() }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        override func viewDidAppear() {
            super.viewDidAppear()
            scheduleRestore()
        }

        override func viewDidLayout() {
            super.viewDidLayout()
            if view.window?.isVisible == true { scheduleRestore() }
        }

        private func scheduleRestore() {
            guard !restoring, !restored else { return }
            restoring = true
            apply()
            // Once more after the window's restored frame has settled; save only from then on.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                apply()
                restored = true
            }
        }

        private var length: CGFloat { axis == .horizontal ? splitView.bounds.width : splitView.bounds.height }

        private func apply() {
            let length = self.length
            guard length > 0 else { return }
            let saved = (UserDefaults.standard.array(forKey: defaultsKey) as? [Double])?.map { CGFloat($0) }
            let sizes = saved?.count == fractions.count - 1 ? saved! : fractions.dropLast().map { $0 * length }
            var pos: CGFloat = 0
            for (i, size) in sizes.enumerated() {
                pos += size
                splitView.setPosition(pos, ofDividerAt: i)
                pos += splitView.dividerThickness
            }
        }

        private func save() {
            guard restored else { return }
            let sizes = splitView.arrangedSubviews.dropLast().map {
                Double(axis == .horizontal ? $0.frame.width : $0.frame.height)
            }
            UserDefaults.standard.set(sizes, forKey: defaultsKey)
        }
    }
}
