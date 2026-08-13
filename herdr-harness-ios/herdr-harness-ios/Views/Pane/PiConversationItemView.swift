import SwiftUI

struct PiConversationItemView: View {
    let item: PiConversationItem

    var body: some View {
        switch item {
        case let .assistant(block):
            PiAssistantMessageView(block: block)
        case let .thinking(block):
            PiThinkingDisclosureView(block: block)
        case let .tool(tool):
            PiToolCardView(tool: tool)
        case let .notice(notice):
            PiConversationNoticeView(notice: notice)
        }
    }
}
