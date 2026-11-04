import SwiftUI

/// Claude is waiting for a yes or no on something outside what it may do on its own. It sits at the end of the
/// chat, where the answer being written is, and is the only thing the run is waiting for.
struct ApprovalCard: View {
    let pending: ApprovalModel.Pending
    let others: Int
    let onAnswer: (ApprovalModel.Answer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "hand.raised.fill").font(.headline)
            CommandHint(label: pending.request.reason ?? label, command: detail)
            Text(footnote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack { buttons }
                VStack(alignment: .leading) { buttons }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.orange.opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude is asking for your OK")
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Allow Once") { onAnswer(.allowOnce) }
            .buttonStyle(.borderedProminent)
            .help("Let Claude do this one time")
        if pending.canAlwaysAllow {
            Button("Always Allow") { onAnswer(.allowAlways) }
                .help("Don't ask again for this exact command in this project. You can undo that from the project's details.")
        }
        Button("Don't Allow") { onAnswer(.decline) }
            .help("Claude is told no, and says what it couldn't do")
    }

    private var title: String {
        switch pending.request.action {
        case .command: "Claude wants to run a command"
        case .readFile: "Claude wants to read a file outside your project"
        case .editFile, .other: "Claude is asking first"
        }
    }

    private var label: String {
        switch pending.request.action {
        case .command: "Command"
        case .readFile, .editFile: "File"
        case .other: "Tool"
        }
    }

    private var detail: String {
        switch pending.request.action {
        case .command(let command): command
        case .readFile(let path), .editFile(let path): AgentPermissionRequest.Action.shortened(path)
        case .other(let tool): tool
        }
    }

    private var footnote: String {
        let waiting = others == 0 ? "" : " \(others) more \(others == 1 ? "question is" : "questions are") waiting."
        return "Claude is paused until you answer." + waiting
    }
}
