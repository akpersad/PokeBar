import AppKit
import SwiftUI

/// A native segmented control that actually fills the width it is given.
///
/// `Picker` + `.pickerStyle(.segmented)` cannot do this on macOS. It wraps
/// `NSSegmentedControl` at its default `segmentDistribution` of `.fit`, which
/// sizes every segment to its own label, and SwiftUI exposes no way to change
/// that. Adding `.frame(maxWidth: .infinity)` widens the *container* and leaves
/// the control centred inside it, which is exactly what shipped: four tabs
/// bunched in the middle of the popover with dead space either side. Verified on
/// screen twice, once bunched left and once centred.
///
/// `.fillEqually` is the one knob that fixes it, so the control is bridged
/// rather than restyled. Reimplementing the tab bar in SwiftUI was the
/// alternative and it costs more than it buys: the native look here (the rounded
/// trough, the accent-filled selection, the hairline dividers) is already right,
/// and a hand-built copy would drift from it on the next OS.
struct SegmentedTabs<Value: Hashable>: NSViewRepresentable {

    /// Label and value per segment, in display order.
    let tabs: [(label: String, value: Value)]
    @Binding var selection: Value

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: tabs.map(\.label),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.segmentChanged(_:)))
        control.segmentDistribution = .fillEqually
        control.segmentStyle = .automatic
        // Otherwise AppKit resists being stretched past its fitted width and
        // the distribution never gets any slack to distribute.
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.tabs = tabs
        context.coordinator.selection = $selection

        // Labels are rebuilt rather than assumed stable: the segment count is
        // fixed today, but a control whose labels silently disagree with its
        // values would route a tap to the wrong pane.
        if control.segmentCount != tabs.count { control.segmentCount = tabs.count }
        for (index, tab) in tabs.enumerated() where control.label(forSegment: index) != tab.label {
            control.setLabel(tab.label, forSegment: index)
        }
        if let index = tabs.firstIndex(where: { $0.value == selection }),
           control.selectedSegment != index {
            control.selectedSegment = index
        }
    }

    /// Takes every point of width offered and keeps AppKit's natural height, so
    /// the fill is decided here and the control's own metrics are left alone.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context
    ) -> CGSize? {
        let fitted = nsView.intrinsicContentSize
        return CGSize(width: proposal.width ?? fitted.width, height: fitted.height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(tabs: tabs, selection: $selection)
    }

    @MainActor
    final class Coordinator: NSObject {
        var tabs: [(label: String, value: Value)]
        var selection: Binding<Value>

        init(tabs: [(label: String, value: Value)], selection: Binding<Value>) {
            self.tabs = tabs
            self.selection = selection
        }

        @objc func segmentChanged(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard tabs.indices.contains(index) else { return }
            selection.wrappedValue = tabs[index].value
        }
    }
}
