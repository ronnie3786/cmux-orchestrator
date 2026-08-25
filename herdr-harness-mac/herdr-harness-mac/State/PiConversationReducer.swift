import Foundation

struct PiConversationReducer: Sendable {
    enum Effect: Equatable, Sendable {
        case none
        case needsSnapshot
        case completed
        case failed
        case interactionRequested
    }

    private(set) var turns: [PiConversationTurn] = []
    private(set) var pendingInteractions: [PiPendingInteraction] = []
    private(set) var structureRevision: Int = 0
    private(set) var phase: PiConversationPhase = .idle
    private(set) var cursor: String?
    private(set) var sessionID: String?
    private(set) var isTruncated = false
    private(set) var bridgeConnected = false
    private(set) var contextUsage: PiContextUsage?
    private(set) var sessionCost: PiSessionCost?
    private(set) var currentModel: PiModelIdentity?
    private(set) var thinkingLevel: String?

    private var activeTurnID: String?
    private var activeMessageID: String?
    private var turnIndexByID: [String: Int] = [:]
    private var blockIndexByID: [String: (turn: Int, item: Int)] = [:]
    private var toolIndexByCallID: [String: (turn: Int, item: Int)] = [:]
    private var itemsRevisionCounter = 0
    private var isReplacingSnapshot = false
    private var seenCursors: Set<String> = []
    private var cursorOrder: [String] = []

    mutating func replace(with snapshot: PiConversationSnapshot) {
        HerdrPerfDiagnostics.checkpoint("pi.replace")
        isReplacingSnapshot = true
        turns.removeAll(keepingCapacity: true)
        pendingInteractions.removeAll(keepingCapacity: true)
        turnIndexByID.removeAll(keepingCapacity: true)
        blockIndexByID.removeAll(keepingCapacity: true)
        toolIndexByCallID.removeAll(keepingCapacity: true)
        seenCursors.removeAll(keepingCapacity: true)
        cursorOrder.removeAll(keepingCapacity: true)
        activeTurnID = nil
        activeMessageID = nil
        cursor = snapshot.cursor
        sessionID = Self.sessionIdentifier(in: snapshot.session)
        isTruncated = snapshot.truncated
        bridgeConnected = snapshot.connected
        contextUsage = PiContextUsage(from: snapshot.state?["context"])
        sessionCost = PiSessionCost(from: snapshot.state?["cost"])
        currentModel = PiModelIdentity(json: snapshot.state?["model"])
        thinkingLevel = snapshot.state?.string(for: "thinkingLevel", "thinking_level")

        for entry in snapshot.entries {
            projectSessionEntry(entry)
        }
        pendingInteractions = snapshot.pendingInteractions.compactMap(Self.interaction(from:))
        phase = Self.isWorking(snapshot.state) ? .working : .idle
        if phase == .idle {
            markTurnsSettled()
        } else if var last = turns.last {
            last.isActive = true
            turns[turns.count - 1] = last
            activeTurnID = last.id
        }
        isReplacingSnapshot = false
        structureRevision += 1
    }

    mutating func apply(_ envelope: PiConversationEnvelope) -> Effect {
        let event = envelope.event
        let type = Self.normalizedEventType(envelope.eventType)

        // Ready and reset frames describe the replay cursor itself, rather
        // than a journal entry. The server can legitimately give both frames
        // the same cursor, so they must bypass durable-event de-duplication.
        if type == "ready" {
            cursor = envelope.cursor ?? cursor
            bridgeConnected = event.bool(for: "connected") ?? envelope.connected ?? false
            return .none
        }
        if type == "stream.reset" {
            cursor = envelope.cursor ?? cursor
            return .needsSnapshot
        }

        if let eventCursor = envelope.cursor {
            guard !seenCursors.contains(eventCursor) else { return .none }
            remember(cursor: eventCursor)
            cursor = eventCursor
        }

        if let incomingSessionID = envelope.sessionID {
            if let sessionID, sessionID != incomingSessionID { return .needsSnapshot }
            sessionID = incomingSessionID
        }

        switch type {
        case "bridge.connection":
            bridgeConnected = event.bool(for: "connected") ?? envelope.connected ?? false
            return .none
        case "model_select":
            if let updated = PiModelIdentity(json: event["model"]) {
                currentModel = updated
            }
            return .none
        case "thinking_level_select":
            if let level = event.string(for: "level") {
                thinkingLevel = level
            }
            return .none
        case "session_tree", "session_compact":
            // Both can replace the current context without changing the Pi
            // session ID, so the only safe projection is authoritative reload.
            return .needsSnapshot
        case "session_start", "session_switch":
            return sessionChanged(by: event) ? .needsSnapshot : .none
        case "agent_start", "turn_start":
            phase = .working
            // Pi emits agent/turn start before the user message. Wait for the
            // first semantic item so we do not render an empty orphan rail.
            return .none
        case "agent_end":
            return .none
        case "turn_end":
            // Per-turn context reading lets the meter update live during a run.
            // Keep the last known value while Pi reports unknown (post-compaction).
            contextUsage = PiContextUsage(from: event["context"]) ?? contextUsage
            sessionCost = PiSessionCost(from: event["cost"]) ?? sessionCost
            return .none
        case "agent_settled":
            let wasWorking = phase == .working
            phase = .idle
            markTurnsSettled()
            return wasWorking ? .completed : .none
        case "message_start":
            projectLiveMessage(event["message"], envelope: envelope, final: false)
            return .none
        case "message_update":
            projectMessageUpdate(event, envelope: envelope)
            return .none
        case "message_end":
            let message = event["message"]
            projectLiveMessage(message, envelope: envelope, final: true)
            if Self.messageFailed(message) {
                phase = .failed
                return .failed
            }
            return .none
        case "tool_execution_start":
            upsertToolExecution(event, status: .running, final: false)
            return .none
        case "tool_execution_update":
            upsertToolExecution(event, status: .running, final: false)
            return .none
        case "tool_execution_end":
            let failed = event.bool(for: "isError", "is_error") ?? false
            upsertToolExecution(event, status: failed ? .failed : .succeeded, final: true)
            return failed ? .failed : .none
        case "extension_ui_request", "interaction_request":
            if let interaction = Self.interaction(from: event) {
                upsertInteraction(interaction)
                return .interactionRequested
            }
            return .none
        case "extension_ui_response", "interaction_response", "interaction_cancelled":
            if let id = event.string(for: "id", "interactionId", "interaction_id") {
                removeInteraction(id: id)
            }
            return .none
        case "error":
            appendNotice(
                id: "event:\(envelope.cursor ?? UUID().uuidString)",
                title: "Pi reported an error",
                detail: event.string(for: "message", "error"),
                tone: .error
            )
            phase = .failed
            return .failed
        default:
            return .none
        }
    }

    mutating func removeInteraction(id: String) {
        let originalCount = pendingInteractions.count
        pendingInteractions.removeAll { $0.id == id }
        if pendingInteractions.count != originalCount {
            bumpStructureRevision()
        }
    }

    private mutating func projectSessionEntry(_ entry: PiJSONValue) {
        let type = entry.string(for: "type") ?? "unknown"
        let entryID = entry.string(for: "id") ?? "entry:\(turns.count)"
        let timestamp = PiConversationTimestamp.date(from: entry.value(for: "timestamp"))
        switch type {
        case "message":
            projectPersistedMessage(entry["message"], entryID: entryID, timestamp: timestamp)
        case "compaction":
            appendNotice(
                id: entryID,
                title: "Context compacted",
                detail: entry.string(for: "summary"),
                tone: .neutral,
                timestamp: timestamp
            )
        case "branch_summary":
            appendNotice(
                id: entryID,
                title: "Branch context summarized",
                detail: entry.string(for: "summary"),
                tone: .neutral,
                timestamp: timestamp
            )
        case "model_change":
            let provider = entry.string(for: "provider")
            let model = entry.string(for: "modelId", "model_id")
            let detail = [provider, model].compactMap { $0 }.joined(separator: " / ")
            appendNotice(
                id: entryID,
                title: "Model changed",
                detail: detail.isEmpty ? nil : detail,
                tone: .neutral,
                timestamp: timestamp
            )
        case "custom_message":
            guard entry.bool(for: "display") ?? true else { return }
            let text = Self.text(from: entry["content"])
            guard !text.isEmpty else { return }
            appendNotice(
                id: entryID,
                title: entry.string(for: "customType", "custom_type") ?? "Pi",
                detail: text,
                tone: .neutral,
                timestamp: timestamp
            )
        default:
            break
        }
    }

    private mutating func projectPersistedMessage(
        _ message: PiJSONValue?,
        entryID: String,
        timestamp: Date?
    ) {
        guard let message else { return }
        switch message.string(for: "role") {
        case "user":
            startTurn(
                id: "turn:\(entryID)",
                message: PiUserMessage(
                    id: entryID,
                    text: Self.text(from: message["content"]),
                    timestamp: PiConversationTimestamp.date(from: message["timestamp"]) ?? timestamp
                )
            )
        case "assistant":
            ensureActiveTurn(seed: entryID)
            activeMessageID = entryID
            syncAssistantMessage(message, messageID: entryID, final: true)
        case "toolResult", "tool_result":
            ensureActiveTurn(seed: entryID)
            projectToolResult(message, fallbackID: entryID)
        default:
            break
        }
    }

    private mutating func projectLiveMessage(
        _ message: PiJSONValue?,
        envelope: PiConversationEnvelope,
        final: Bool
    ) {
        guard let message else { return }
        let messageID = Self.liveMessageIdentifier(message, envelope: envelope)
        switch message.string(for: "role") {
        case "user":
            let text = Self.text(from: message["content"])
            if let last = turns.last, last.user?.text == text, last.items.isEmpty {
                activeTurnID = last.id
            } else {
                startTurn(
                    id: "turn:\(messageID)",
                    message: PiUserMessage(
                        id: messageID,
                        text: text,
                        timestamp: PiConversationTimestamp.date(from: message["timestamp"])
                    )
                )
            }
        case "assistant":
            phase = final && Self.messageFailed(message) ? .failed : .working
            ensureActiveTurn(seed: messageID)
            activeMessageID = messageID
            syncAssistantMessage(message, messageID: messageID, final: final)
        case "toolResult", "tool_result":
            ensureActiveTurn(seed: messageID)
            projectToolResult(message, fallbackID: messageID)
        default:
            break
        }
    }

    private mutating func projectMessageUpdate(
        _ event: PiJSONValue,
        envelope: PiConversationEnvelope
    ) {
        let message = event["message"]
        let messageID = activeMessageID ?? Self.liveMessageIdentifier(message, envelope: envelope)
        activeMessageID = messageID
        ensureActiveTurn(seed: messageID)

        let assistantEvent = event.value(for: "assistantMessageEvent", "assistant_message_event")
        let updateType = assistantEvent?.string(for: "type") ?? ""
        let contentIndex = Int(assistantEvent?.value(for: "contentIndex", "content_index")?.stringValue ?? "0") ?? 0
        switch updateType {
        case "text_start":
            let id = "\(messageID):text:\(contentIndex)"
            let existing = assistantBlock(id: id)
            upsertAssistant(
                PiAssistantBlock(
                    id: id,
                    text: existing?.text ?? "",
                    status: .streaming,
                    timestamp: existing?.timestamp ?? .now
                )
            )
        case "text_delta":
            let id = "\(messageID):text:\(contentIndex)"
            appendAssistantDelta(id: id, delta: assistantEvent?.string(for: "delta") ?? "")
        case "text_end":
            let id = "\(messageID):text:\(contentIndex)"
            let existing = assistantBlock(id: id)
            upsertAssistant(
                PiAssistantBlock(
                    id: id,
                    text: assistantEvent?.string(for: "content") ?? existing?.text ?? "",
                    status: .complete,
                    timestamp: existing?.timestamp
                )
            )
        case "thinking_start":
            let id = "\(messageID):thinking:\(contentIndex)"
            let existing = thinkingBlock(id: id)
            upsertThinking(
                PiThinkingBlock(
                    id: id,
                    text: existing?.text ?? "",
                    isStreaming: true,
                    isRedacted: existing?.isRedacted ?? false,
                    startedAt: existing?.startedAt ?? .now
                )
            )
        case "thinking_delta":
            let id = "\(messageID):thinking:\(contentIndex)"
            appendThinkingDelta(id: id, delta: assistantEvent?.string(for: "delta") ?? "")
        case "thinking_end":
            let id = "\(messageID):thinking:\(contentIndex)"
            let existing = thinkingBlock(id: id)
            upsertThinking(
                PiThinkingBlock(
                    id: id,
                    text: assistantEvent?.string(for: "content") ?? existing?.text ?? "",
                    isStreaming: false,
                    isRedacted: existing?.isRedacted ?? false,
                    startedAt: existing?.startedAt
                )
            )
        case "toolcall_start":
            let callID = "pending:\(messageID):\(contentIndex)"
            upsertTool(
                PiToolInvocation(
                    id: "tool:\(callID)",
                    callID: callID,
                    name: "Preparing tool",
                    arguments: nil,
                    result: nil,
                    status: .waiting,
                    startedAt: .now,
                    finishedAt: nil
                )
            )
        case "toolcall_delta":
            let callID = "pending:\(messageID):\(contentIndex)"
            let existing = tool(callID: callID)
            let delta = assistantEvent?.string(for: "delta") ?? ""
            let accumulated = (existing?.arguments?.stringValue ?? "") + delta
            upsertTool(
                PiToolInvocation(
                    id: "tool:\(callID)",
                    callID: callID,
                    name: existing?.name ?? "Preparing tool",
                    arguments: accumulated.isEmpty ? nil : .string(accumulated),
                    result: nil,
                    status: .waiting,
                    startedAt: existing?.startedAt ?? .now,
                    finishedAt: nil
                )
            )
        case "toolcall_end":
            let pendingCallID = "pending:\(messageID):\(contentIndex)"
            removeTool(callID: pendingCallID)
            if let toolCall = assistantEvent?["toolCall"],
               let callID = toolCall.string(for: "id") {
                upsertTool(
                    PiToolInvocation(
                        id: "tool:\(callID)",
                        callID: callID,
                        name: toolCall.string(for: "name") ?? "Tool",
                        arguments: toolCall.value(for: "arguments", "args"),
                        result: nil,
                        status: .waiting,
                        startedAt: .now,
                        finishedAt: nil
                    )
                )
            }
        case "done":
            syncAssistantMessage(assistantEvent?["message"] ?? message, messageID: messageID, final: true)
        case "error":
            syncAssistantMessage(assistantEvent?["error"] ?? message, messageID: messageID, final: true)
            phase = .failed
        default:
            syncAssistantMessage(message, messageID: messageID, final: false)
        }
    }

    private mutating func syncAssistantMessage(
        _ message: PiJSONValue?,
        messageID: String,
        final: Bool
    ) {
        guard let message else { return }
        let content = message["content"]?.arrayValue ?? []
        let timestamp = PiConversationTimestamp.date(from: message["timestamp"])
        let stopReason = message.string(for: "stopReason", "stop_reason")
        let errorMessage = message.string(for: "errorMessage", "error_message")
        let failed = stopReason == "error" || stopReason == "aborted"

        for (index, part) in content.enumerated() {
            switch part.string(for: "type") {
            case "text":
                let id = "\(messageID):text:\(index)"
                let status: PiAssistantBlock.Status = failed
                    ? .failed(errorMessage)
                    : (final ? .complete : .streaming)
                upsertAssistant(
                    PiAssistantBlock(
                        id: id,
                        text: part.string(for: "text") ?? "",
                        status: status,
                        timestamp: timestamp
                    )
                )
            case "thinking":
                upsertThinking(
                    PiThinkingBlock(
                        id: "\(messageID):thinking:\(index)",
                        text: part.string(for: "thinking") ?? "",
                        isStreaming: !final,
                        isRedacted: part.bool(for: "redacted") ?? false,
                        startedAt: timestamp
                    )
                )
            case "toolCall", "tool_call":
                guard let callID = part.string(for: "id") else { continue }
                let existing = tool(callID: callID)
                upsertTool(
                    PiToolInvocation(
                        id: "tool:\(callID)",
                        callID: callID,
                        name: part.string(for: "name") ?? existing?.name ?? "Tool",
                        arguments: part.value(for: "arguments", "args") ?? existing?.arguments,
                        result: existing?.result,
                        status: existing?.status ?? .waiting,
                        startedAt: existing?.startedAt,
                        finishedAt: existing?.finishedAt
                    )
                )
            default:
                continue
            }
        }

        if failed, !content.contains(where: { $0.string(for: "type") == "text" }) {
            appendNotice(
                id: "\(messageID):failure",
                title: stopReason == "aborted" ? "Response stopped" : "Pi could not finish",
                detail: errorMessage ?? (stopReason == "aborted" ? "The response was interrupted." : "No error details were provided."),
                tone: stopReason == "aborted" ? .warning : .error,
                timestamp: timestamp
            )
        }
    }

    private mutating func projectToolResult(_ message: PiJSONValue, fallbackID: String) {
        let callID = message.string(for: "toolCallId", "tool_call_id") ?? fallbackID
        let existing = tool(callID: callID)
        upsertTool(
            PiToolInvocation(
                id: "tool:\(callID)",
                callID: callID,
                name: message.string(for: "toolName", "tool_name") ?? existing?.name ?? "Tool",
                arguments: existing?.arguments,
                result: message.value(for: "content", "result"),
                status: (message.bool(for: "isError", "is_error") ?? false) ? .failed : .succeeded,
                startedAt: existing?.startedAt,
                finishedAt: PiConversationTimestamp.date(from: message["timestamp"])
            )
        )
    }

    private mutating func upsertToolExecution(
        _ event: PiJSONValue,
        status: PiToolInvocation.Status,
        final: Bool
    ) {
        guard let callID = event.string(for: "toolCallId", "tool_call_id") else { return }
        ensureActiveTurn(seed: callID)
        let existing = tool(callID: callID)
        let result = event.value(for: "result", "partialResult", "partial_result")
        upsertTool(
            PiToolInvocation(
                id: "tool:\(callID)",
                callID: callID,
                name: event.string(for: "toolName", "tool_name") ?? existing?.name ?? "Tool",
                arguments: event.value(for: "args", "arguments") ?? existing?.arguments,
                result: result ?? existing?.result,
                status: status,
                startedAt: existing?.startedAt ?? .now,
                finishedAt: final ? .now : nil
            )
        )
    }

    private mutating func startTurn(id: String, message: PiUserMessage) {
        if !turns.isEmpty {
            turns[turns.count - 1].isActive = false
        }
        turns.append(
            PiConversationTurn(
                id: id,
                user: message,
                items: [],
                startedAt: message.timestamp,
                isActive: phase == .working
            )
        )
        turnIndexByID[id] = turns.count - 1
        bumpStructureRevision()
        activeTurnID = id
        activeMessageID = nil
    }

    private mutating func ensureActiveTurn(seed: String?) {
        if let activeTurnID, turnIndexByID[activeTurnID] != nil { return }
        if let last = turns.last {
            activeTurnID = last.id
            return
        }
        let id = "turn:orphan:\(seed ?? "initial")"
        turns.append(PiConversationTurn(id: id, user: nil, items: [], startedAt: .now, isActive: true))
        turnIndexByID[id] = turns.count - 1
        bumpStructureRevision()
        activeTurnID = id
    }

    private mutating func append(_ item: PiConversationItem) {
        ensureActiveTurn(seed: item.id)
        guard let activeTurnID, let index = turnIndexByID[activeTurnID] else { return }
        if let itemIndex = turns[index].items.firstIndex(where: { $0.id == item.id }) {
            turns[index].items[itemIndex] = item
            turns[index].itemsRevision = nextItemsRevision()
        } else {
            turns[index].items.append(item)
            turns[index].itemsRevision = nextItemsRevision()
            recordIndex(for: item, turn: index, item: turns[index].items.count - 1)
            bumpStructureRevision()
        }
    }

    private mutating func upsertAssistant(_ block: PiAssistantBlock) {
        if let position = blockIndexByID[block.id],
           position.turn < turns.count,
           position.item < turns[position.turn].items.count,
           case let .assistant(existing) = turns[position.turn].items[position.item],
           existing.id == block.id {
            turns[position.turn].items[position.item] = .assistant(block)
            turns[position.turn].itemsRevision = nextItemsRevision()
            return
        }
        blockIndexByID.removeValue(forKey: block.id)
        appendBlock(.assistant(block), id: block.id)
    }

    private mutating func upsertThinking(_ block: PiThinkingBlock) {
        if let position = blockIndexByID[block.id],
           position.turn < turns.count,
           position.item < turns[position.turn].items.count,
           case let .thinking(existing) = turns[position.turn].items[position.item],
           existing.id == block.id {
            turns[position.turn].items[position.item] = .thinking(block)
            turns[position.turn].itemsRevision = nextItemsRevision()
            return
        }
        blockIndexByID.removeValue(forKey: block.id)
        appendBlock(.thinking(block), id: block.id)
    }

    private func assistantBlock(id: String) -> PiAssistantBlock? {
        guard let position = blockIndexByID[id],
              position.turn < turns.count,
              position.item < turns[position.turn].items.count,
              case let .assistant(block) = turns[position.turn].items[position.item],
              block.id == id
        else { return nil }
        return block
    }

    private func thinkingBlock(id: String) -> PiThinkingBlock? {
        guard let position = blockIndexByID[id],
              position.turn < turns.count,
              position.item < turns[position.turn].items.count,
              case let .thinking(block) = turns[position.turn].items[position.item],
              block.id == id
        else { return nil }
        return block
    }

    private mutating func upsertTool(_ invocation: PiToolInvocation) {
        if let position = toolIndexByCallID[invocation.callID],
           position.turn < turns.count,
           position.item < turns[position.turn].items.count,
           case let .tool(existing) = turns[position.turn].items[position.item],
           existing.callID == invocation.callID {
            turns[position.turn].items[position.item] = .tool(invocation)
            turns[position.turn].itemsRevision = nextItemsRevision()
            return
        }
        toolIndexByCallID.removeValue(forKey: invocation.callID)
        ensureActiveTurn(seed: invocation.id)
        guard let activeTurnID, let turnIndex = turnIndexByID[activeTurnID] else { return }
        turns[turnIndex].items.append(.tool(invocation))
        turns[turnIndex].itemsRevision = nextItemsRevision()
        toolIndexByCallID[invocation.callID] = (turn: turnIndex, item: turns[turnIndex].items.count - 1)
        bumpStructureRevision()
    }

    private func tool(callID: String) -> PiToolInvocation? {
        guard let position = toolIndexByCallID[callID],
              position.turn < turns.count,
              position.item < turns[position.turn].items.count,
              case let .tool(tool) = turns[position.turn].items[position.item],
              tool.callID == callID
        else { return nil }
        return tool
    }

    private mutating func removeTool(callID: String) {
        guard let position = toolIndexByCallID[callID],
              position.turn < turns.count,
              position.item < turns[position.turn].items.count,
              case let .tool(tool) = turns[position.turn].items[position.item],
              tool.callID == callID
        else {
            toolIndexByCallID.removeValue(forKey: callID)
            return
        }
        turns[position.turn].items.remove(at: position.item)
        turns[position.turn].itemsRevision = nextItemsRevision()
        toolIndexByCallID.removeValue(forKey: callID)
        renumberIndexes(afterRemovingItemAt: position)
        bumpStructureRevision()
    }

    private mutating func appendAssistantDelta(id: String, delta: String) {
        if let position = blockIndexByID[id],
           position.turn < turns.count,
           position.item < turns[position.turn].items.count,
           case var .assistant(block) = turns[position.turn].items[position.item],
           block.id == id {
            block.text += delta
            block.status = .streaming
            turns[position.turn].items[position.item] = .assistant(block)
            turns[position.turn].itemsRevision = nextItemsRevision()
            return
        }
        blockIndexByID.removeValue(forKey: id)
        upsertAssistant(PiAssistantBlock(id: id, text: delta, status: .streaming, timestamp: .now))
    }

    private mutating func appendThinkingDelta(id: String, delta: String) {
        if let position = blockIndexByID[id],
           position.turn < turns.count,
           position.item < turns[position.turn].items.count,
           case var .thinking(block) = turns[position.turn].items[position.item],
           block.id == id {
            block.text += delta
            block.isStreaming = true
            turns[position.turn].items[position.item] = .thinking(block)
            turns[position.turn].itemsRevision = nextItemsRevision()
            return
        }
        blockIndexByID.removeValue(forKey: id)
        upsertThinking(PiThinkingBlock(id: id, text: delta, isStreaming: true, isRedacted: false, startedAt: .now))
    }

    private mutating func appendBlock(_ item: PiConversationItem, id: String) {
        ensureActiveTurn(seed: id)
        guard let activeTurnID, let turnIndex = turnIndexByID[activeTurnID] else { return }
        turns[turnIndex].items.append(item)
        turns[turnIndex].itemsRevision = nextItemsRevision()
        blockIndexByID[id] = (turn: turnIndex, item: turns[turnIndex].items.count - 1)
        bumpStructureRevision()
    }

    private mutating func recordIndex(for item: PiConversationItem, turn: Int, item itemIndex: Int) {
        switch item {
        case let .assistant(block):
            blockIndexByID[block.id] = (turn: turn, item: itemIndex)
        case let .thinking(block):
            blockIndexByID[block.id] = (turn: turn, item: itemIndex)
        case let .tool(tool):
            toolIndexByCallID[tool.callID] = (turn: turn, item: itemIndex)
        case .notice:
            break
        }
    }

    private mutating func renumberIndexes(afterRemovingItemAt position: (turn: Int, item: Int)) {
        let shiftedBlockIDs = blockIndexByID.compactMap { id, indexedPosition in
            indexedPosition.turn == position.turn && indexedPosition.item > position.item ? id : nil
        }
        for id in shiftedBlockIDs {
            guard var indexedPosition = blockIndexByID[id] else { continue }
            indexedPosition.item -= 1
            blockIndexByID[id] = indexedPosition
        }
        let shiftedToolCallIDs = toolIndexByCallID.compactMap { callID, indexedPosition in
            indexedPosition.turn == position.turn && indexedPosition.item > position.item ? callID : nil
        }
        for callID in shiftedToolCallIDs {
            guard var indexedPosition = toolIndexByCallID[callID] else { continue }
            indexedPosition.item -= 1
            toolIndexByCallID[callID] = indexedPosition
        }
    }

    private mutating func bumpStructureRevision() {
        guard !isReplacingSnapshot else { return }
        structureRevision += 1
    }

    private mutating func nextItemsRevision() -> Int {
        itemsRevisionCounter += 1
        return itemsRevisionCounter
    }

    private mutating func appendNotice(
        id: String,
        title: String,
        detail: String?,
        tone: PiConversationNotice.Tone,
        timestamp: Date? = nil
    ) {
        ensureActiveTurn(seed: id)
        append(
            .notice(
                PiConversationNotice(
                    id: id,
                    title: title,
                    detail: detail,
                    tone: tone,
                    timestamp: timestamp
                )
            )
        )
    }

    private mutating func upsertInteraction(_ interaction: PiPendingInteraction) {
        if let index = pendingInteractions.firstIndex(where: { $0.id == interaction.id }) {
            pendingInteractions[index] = interaction
        } else {
            pendingInteractions.append(interaction)
            bumpStructureRevision()
        }
    }

    private mutating func markTurnsSettled() {
        for index in turns.indices {
            turns[index].isActive = false
            for itemIndex in turns[index].items.indices {
                switch turns[index].items[itemIndex] {
                case var .assistant(block):
                    if case .streaming = block.status { block.status = .complete }
                    turns[index].items[itemIndex] = .assistant(block)
                    turns[index].itemsRevision = nextItemsRevision()
                case var .thinking(block):
                    block.isStreaming = false
                    turns[index].items[itemIndex] = .thinking(block)
                    turns[index].itemsRevision = nextItemsRevision()
                case .tool, .notice:
                    break
                }
            }
        }
        activeTurnID = turns.last?.id
        activeMessageID = nil
    }

    private mutating func remember(cursor: String) {
        seenCursors.insert(cursor)
        cursorOrder.append(cursor)
        if cursorOrder.count > 2_048 {
            let removed = Array(cursorOrder.prefix(512))
            cursorOrder.removeFirst(512)
            seenCursors.subtract(removed)
        }
    }

    private mutating func sessionChanged(by event: PiJSONValue) -> Bool {
        guard let incomingID = event.string(for: "sessionId", "session_id", "id") else { return false }
        if let sessionID, sessionID != incomingID { return true }
        sessionID = incomingID
        return false
    }

    private static func normalizedEventType(_ type: String) -> String {
        type.hasPrefix("pi.") ? String(type.dropFirst(3)) : type
    }

    private static func sessionIdentifier(in session: PiJSONValue?) -> String? {
        session?.string(for: "id", "sessionId", "session_id") ?? session?.stringValue
    }

    private static func isWorking(_ state: PiJSONValue?) -> Bool {
        state?.bool(for: "isStreaming", "is_streaming", "running", "working")
            ?? ["working", "running", "streaming"].contains(state?.string(for: "status", "phase") ?? "")
    }

    private static func liveMessageIdentifier(
        _ message: PiJSONValue?,
        envelope: PiConversationEnvelope
    ) -> String {
        if let id = message?.string(for: "id", "messageId", "message_id") { return id }
        let timestamp = message?.value(for: "timestamp")?.stringValue
        return "live:\(envelope.sessionID ?? "session"):\(timestamp ?? envelope.cursor ?? "message")"
    }

    private static func messageFailed(_ message: PiJSONValue?) -> Bool {
        let reason = message?.string(for: "stopReason", "stop_reason")
        return reason == "error" || reason == "aborted"
    }

    private static func text(from content: PiJSONValue?) -> String {
        guard let content else { return "" }
        if let string = content.stringValue { return string }
        guard let parts = content.arrayValue else { return "" }
        return parts.compactMap { part -> String? in
            switch part.string(for: "type") {
            case "text": part.string(for: "text")
            case "image": "[Image]"
            default: nil
            }
        }
        .joined(separator: "\n")
    }

    private static func interaction(from value: PiJSONValue) -> PiPendingInteraction? {
        let request = value["request"] ?? value
        guard let id = request.string(for: "id", "interactionId", "interaction_id", "requestId", "request_id") else {
            return nil
        }
        let rawKind = request.string(for: "method", "kind", "requestType", "request_type") ?? "unknown"
        let kind = PiPendingInteraction.Kind(rawValue: rawKind) ?? .unknown
        let options = request.value(for: "options", "choices")?.arrayValue?.compactMap { option in
            option.stringValue ?? option.string(for: "label", "value")
        } ?? []
        return PiPendingInteraction(
            id: id,
            kind: kind,
            title: request.string(for: "title", "prompt") ?? "Pi needs your input",
            message: request.string(for: "message", "description"),
            options: options,
            placeholder: request.string(for: "placeholder")
        )
    }
}
