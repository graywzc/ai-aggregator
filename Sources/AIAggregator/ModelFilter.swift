import AppKit
import SwiftUI

/// Which models the requests table hides. Stored as the hidden set, so a model that
/// starts appearing after the choice was made is shown until unchecked.
final class ModelFilter: ObservableObject {
    static let key = "ClaudeCodeRequestsHiddenModels"

    @Published var hidden: Set<String> {
        didSet { defaults.set(hidden.sorted(), forKey: Self.key) }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hidden = Set(defaults.stringArray(forKey: Self.key) ?? [])
        defaults.removeObject(forKey: "ClaudeCodeRequestsModel")   // 1.6.1's single-model picker
    }

    var isActive: Bool { !hidden.isEmpty }

    func apply(_ requests: [RequestSpeed]) -> [RequestSpeed] {
        hidden.isEmpty ? requests : requests.filter { !hidden.contains($0.model) }
    }

    func isShown(_ model: String) -> Bool { !hidden.contains(model) }

    func set(_ model: String, shown: Bool) {
        if shown { hidden.remove(model) } else { hidden.insert(model) }
    }

    /// Every model among `requests`, sorted, with how many requests each has.
    static func models(in requests: [RequestSpeed]) -> [(model: String, count: Int)] {
        Dictionary(grouping: requests, by: \.model)
            .map { (model: $0.key, count: $0.value.count) }
            .sorted { $0.model < $1.model }
    }

    static func label(_ model: String) -> String {
        model.isEmpty ? "(unknown)" : model.replacingOccurrences(of: "claude-", with: "")
    }
}

/// The checklist that drops down from the table's Model header.
struct ModelFilterPopover: View {
    @ObservedObject var filter: ModelFilter
    @ObservedObject var log: RequestLog

    var body: some View {
        let models = ModelFilter.models(in: log.requests)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Select all") { filter.hidden = [] }
                    .disabled(!filter.isActive)
                Button("Select none") { filter.hidden = Set(models.map(\.model)) }
                    .disabled(models.allSatisfy { !filter.isShown($0.model) })
            }
            .controlSize(.small)
            Divider()
            if models.isEmpty {
                Text("No requests yet.").foregroundColor(.secondary)
            }
            ForEach(models, id: \.model) { entry in
                Toggle(isOn: Binding(get: { filter.isShown(entry.model) },
                                     set: { filter.set(entry.model, shown: $0) })) {
                    HStack {
                        Text(ModelFilter.label(entry.model))
                        Spacer(minLength: 16)
                        Text(entry.count.formatted()).foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .frame(minWidth: 240)
    }
}

/// SwiftUI's Table gives no control over its header cells, so this sits behind the table
/// and watches the window for a click on the header cell whose title carries `marker`,
/// showing `content` in a popover under that cell instead of letting the header have it.
struct HeaderClickPopover<Content: View>: NSViewRepresentable {
    let marker: String
    let content: () -> Content

    func makeNSView(context: Context) -> HookView {
        let view = HookView()
        view.marker = marker
        view.makeContent = { NSHostingController(rootView: content()) }
        return view
    }

    func updateNSView(_ view: HookView, context: Context) {
        view.marker = marker
        view.makeContent = { NSHostingController(rootView: content()) }
    }

    static func dismantleNSView(_ view: HookView, coordinator: ()) { view.removeMonitor() }

    final class HookView: NSView {
        var marker = ""
        var makeContent: (() -> NSViewController)?
        private var monitor: Any?
        private(set) var popover: NSPopover?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.intercept(event) ?? event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { removeMonitor() }

        /// Returns nil to swallow a click on the marked header cell, after showing the popover.
        func intercept(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, let content = window.contentView,
                  let header = content.hitTest(event.locationInWindow) as? NSTableHeaderView,
                  let table = header.tableView
            else { return event }
            let column = header.column(at: header.convert(event.locationInWindow, from: nil))
            guard column >= 0, table.tableColumns[column].title.contains(marker) else { return event }
            toggle(anchoredTo: header.headerRect(ofColumn: column), in: header)
            return nil
        }

        private func toggle(anchoredTo rect: NSRect, in view: NSView) {
            if let popover, popover.isShown { popover.close(); return }
            guard let makeContent else { return }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = makeContent()
            popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
            self.popover = popover
        }
    }
}
