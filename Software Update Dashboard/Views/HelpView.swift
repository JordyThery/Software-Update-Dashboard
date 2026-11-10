import SwiftUI

/// Which part of Help to show: set by a link in Inspect, read by the Help window.
@MainActor
@Observable
final class HelpNavigator {
    static let shared = HelpNavigator()
    /// The topic or known problem to scroll to (`HelpTopic.id` or `KnownProblem.id`).
    private(set) var target: String?
    /// Changes with every request, so the same link scrolls again.
    private(set) var request = UUID()

    func show(_ id: String?) {
        target = id
        request = UUID()
    }
}

/// Help › Software Update Dashboard Help: how the app decides, then the
/// known problems, each with its public source. The same in Demo Mode.
struct HelpView: View {
    @State private var navigator = HelpNavigator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(HelpContent.topics) { topic in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(topic.title).font(.title2.weight(.semibold))
                                .accessibilityAddTraits(.isHeader)
                            ForEach(topic.paragraphs, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
                        }
                        .id(topic.id)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Known Problems").font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text("Reasons an update doesn’t install that Apple’s own documentation describes, each with a link to that page.")
                            .foregroundStyle(.secondary)
                        ForEach(HelpContent.problems) { problem in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(problem.title).font(.headline)
                                    .accessibilityAddTraits(.isHeader)
                                Text(problem.text).fixedSize(horizontal: false, vertical: true)
                                Link(problem.sourceTitle, destination: problem.source)
                                    .help(problem.source.absoluteString)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.background.secondary, in: .rect(cornerRadius: 8))
                            // the entry a link opened: outlined, not by colour alone
                            .overlay {
                                if navigator.target == problem.id {
                                    RoundedRectangle(cornerRadius: 8).strokeBorder(.tint, lineWidth: 2)
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityAddTraits(navigator.target == problem.id ? .isSelected : [])
                            .id(problem.id)
                        }
                    }
                    .id("known-problems")
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
                .textSelection(.enabled)
            }
            .onAppear { scroll(reader) }
            .onChange(of: navigator.request) { scroll(reader) }
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    private func scroll(_ reader: ScrollViewProxy) {
        guard let target = navigator.target else { return }
        withAnimation(reduceMotion ? nil : .default) { reader.scrollTo(target, anchor: .top) }
    }
}

/// Help › Software Update Dashboard Help (⌘?).
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Software Update Dashboard Help") {
                HelpNavigator.shared.show(nil)
                openWindow(id: HelpView.windowID)
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }
}

extension HelpView {
    static let windowID = "help"
}

/// A link from an Inspect finding to its Known Problems entry.
struct KnownProblemLink: View {
    let problem: KnownProblem
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About “\(problem.title)”") {
            HelpNavigator.shared.show(problem.id)
            openWindow(id: HelpView.windowID)
        }
        .buttonStyle(.link)
        .help("Opens Help at this known problem, with Apple’s page about it")
    }
}
