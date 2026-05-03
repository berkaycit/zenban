import Foundation

final class FeedBridgeStore: @unchecked Sendable {
    static let shared = FeedBridgeStore()

    private final class PendingWaiter {
        let semaphore = DispatchSemaphore(value: 0)
        var decision: FeedDecision?
    }

    private struct FeedDecision {
        let payload: [String: Any]
    }

    private struct FeedItem {
        let id: UUID
        let requestId: String?
        let workstreamId: String
        let source: String
        let kind: String
        let createdAt: Date
        var updatedAt: Date
        var status: String
        var decision: [String: Any]?
        var fields: [String: Any]
    }

    private let lock = NSLock()
    private var items: [FeedItem] = []
    private var waiters: [String: PendingWaiter] = [:]
    private let ringCapacity = 500

    private init() {}

    func push(event: [String: Any], waitTimeout: TimeInterval) -> [String: Any] {
        let requestId = stringValue(event["_opencode_request_id"])
            ?? stringValue(event["request_id"])
            ?? stringValue(event["tool_use_id"])
            ?? stringValue(event["toolUseID"])
        let item = makeItem(event: event, requestId: requestId, waitTimeout: waitTimeout)

        guard waitTimeout > 0, let requestId else {
            append(item)
            return payload(status: "acknowledged", itemId: item.id, decision: nil)
        }

        let waiter = PendingWaiter()
        lock.lock()
        waiters[requestId] = waiter
        appendLocked(item)
        lock.unlock()

        let waitResult = waiter.semaphore.wait(timeout: .now() + waitTimeout)

        lock.lock()
        let resolvedWaiter = waiters.removeValue(forKey: requestId)
        let decision = resolvedWaiter?.decision
        if waitResult == .success, let decision {
            markItemLocked(requestId: requestId, status: "resolved", decision: decision.payload)
            lock.unlock()
            return payload(status: "resolved", itemId: item.id, decision: decision.payload)
        }
        markItemLocked(requestId: requestId, status: "expired", decision: nil)
        lock.unlock()
        return payload(status: "timed_out", itemId: item.id, decision: nil)
    }

    func replyPermission(requestId: String, mode: String) {
        deliver(requestId: requestId, decision: ["kind": "permission", "mode": mode])
    }

    func replyQuestion(requestId: String, selections: [String]) {
        deliver(requestId: requestId, decision: ["kind": "question", "selections": selections])
    }

    func replyExitPlan(requestId: String, mode: String, feedback: String?) {
        var decision: [String: Any] = ["kind": "exit_plan", "mode": mode]
        if let feedback, !feedback.isEmpty {
            decision["feedback"] = feedback
        }
        deliver(requestId: requestId, decision: decision)
    }

    func snapshot(pendingOnly: Bool) -> [[String: Any]] {
        lock.lock()
        let snapshot = items
        lock.unlock()
        return snapshot
            .filter { !pendingOnly || $0.status == "pending" }
            .reversed()
            .map(itemDict)
    }

    func hasWorkstream(_ workstreamId: String) -> Bool {
        lock.lock()
        let matched = items.contains { $0.workstreamId == workstreamId }
        lock.unlock()
        return matched
    }

    private func deliver(requestId: String, decision: [String: Any]) {
        lock.lock()
        let feedDecision = FeedDecision(payload: decision)
        if let waiter = waiters[requestId] {
            waiter.decision = feedDecision
            waiter.semaphore.signal()
        }
        markItemLocked(requestId: requestId, status: "resolved", decision: decision)
        lock.unlock()
    }

    private func append(_ item: FeedItem) {
        lock.lock()
        appendLocked(item)
        lock.unlock()
    }

    private func appendLocked(_ item: FeedItem) {
        items.append(item)
        if items.count > ringCapacity {
            items.removeFirst(items.count - ringCapacity)
        }
    }

    private func markItemLocked(requestId: String, status: String, decision: [String: Any]?) {
        guard let index = items.lastIndex(where: { $0.requestId == requestId }) else { return }
        items[index].status = status
        items[index].updatedAt = Date()
        items[index].decision = decision
    }

    private func makeItem(event: [String: Any], requestId: String?, waitTimeout: TimeInterval) -> FeedItem {
        let hookEventName = stringValue(event["hook_event_name"]) ?? "PreToolUse"
        let source = stringValue(event["_source"]) ?? "unknown"
        let toolName = stringValue(event["tool_name"])
        let toolInput = jsonString(event["tool_input"])
        let workstreamId = stringValue(event["session_id"]) ?? "\(source)-unknown"
        let kind = kindForHookEvent(hookEventName)
        let now = Date()
        var fields: [String: Any] = [:]

        if let requestId {
            fields["request_id"] = requestId
        }
        if let cwd = stringValue(event["cwd"]) {
            fields["cwd"] = cwd
        }
        if let toolName {
            fields["tool_name"] = toolName
            fields["title"] = toolName
        }
        if let toolInput {
            switch kind {
            case "exitPlan":
                fields["plan"] = toolInput
                fields["plan_summary"] = firstNonEmptyLine(toolInput)
            case "question":
                addQuestionFields(fromToolInput: toolInput, to: &fields)
            case "permissionRequest", "toolUse", "toolResult":
                fields["tool_input"] = toolInput
            default:
                fields["text"] = toolInput
            }
        }

        let status: String
        if waitTimeout > 0, requestId != nil, isActionable(kind) {
            status = "pending"
        } else if isActionable(kind) {
            status = "pending"
        } else {
            status = "telemetry"
        }

        return FeedItem(
            id: UUID(),
            requestId: requestId,
            workstreamId: workstreamId,
            source: source,
            kind: kind,
            createdAt: now,
            updatedAt: now,
            status: status,
            decision: nil,
            fields: fields
        )
    }

    private func kindForHookEvent(_ hookEventName: String) -> String {
        switch hookEventName {
        case "PermissionRequest":
            return "permissionRequest"
        case "ExitPlanMode":
            return "exitPlan"
        case "AskUserQuestion":
            return "question"
        case "PostToolUse":
            return "toolResult"
        case "UserPromptSubmit":
            return "userPrompt"
        case "SessionStart":
            return "sessionStart"
        case "SessionEnd":
            return "sessionEnd"
        case "Stop", "SubagentStop":
            return "stop"
        case "TodoWrite":
            return "todos"
        default:
            return "toolUse"
        }
    }

    private func isActionable(_ kind: String) -> Bool {
        kind == "permissionRequest" || kind == "exitPlan" || kind == "question"
    }

    private func payload(status: String, itemId: UUID?, decision: [String: Any]?) -> [String: Any] {
        var payload: [String: Any] = ["status": status]
        if let itemId {
            payload["item_id"] = itemId.uuidString
        }
        if let decision {
            payload["decision"] = decision
        }
        return payload
    }

    private func itemDict(_ item: FeedItem) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "id": item.id.uuidString,
            "workstream_id": item.workstreamId,
            "source": item.source,
            "kind": item.kind,
            "status": item.status,
            "created_at": formatter.string(from: item.createdAt),
            "updated_at": formatter.string(from: item.updatedAt)
        ]
        for (key, value) in item.fields {
            dict[key] = value
        }
        if let decision = item.decision {
            dict["decision"] = decision
        }
        return dict
    }

    private func addQuestionFields(fromToolInput toolInput: String, to fields: inout [String: Any]) {
        guard let data = toolInput.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            fields["question_prompt"] = toolInput
            return
        }

        let rawQuestions: [[String: Any]]
        if let questions = root["questions"] as? [[String: Any]] {
            rawQuestions = questions
        } else {
            rawQuestions = [root]
        }

        let questions: [[String: Any]] = rawQuestions.enumerated().map { index, raw in
            let prompt = stringValue(raw["question"])
                ?? stringValue(raw["prompt"])
                ?? stringValue(raw["header"])
                ?? ""
            let rawOptions = raw["options"] as? [Any] ?? []
            let options = rawOptions.enumerated().compactMap { optionIndex, option -> [String: Any]? in
                if let label = option as? String {
                    return ["id": "opt\(optionIndex)", "label": label]
                }
                guard let dict = option as? [String: Any] else { return nil }
                let id = stringValue(dict["id"]) ?? "opt\(optionIndex)"
                let label = stringValue(dict["label"])
                    ?? stringValue(dict["title"])
                    ?? id
                var out: [String: Any] = ["id": id, "label": label]
                if let description = stringValue(dict["description"]) ?? stringValue(dict["detail"]) {
                    out["description"] = description
                }
                return out
            }
            return [
                "id": stringValue(raw["id"]) ?? "question-\(index + 1)",
                "prompt": prompt,
                "multi_select": boolValue(raw["multi_select"]) ?? boolValue(raw["multiSelect"]) ?? false,
                "options": options
            ]
        }

        fields["questions"] = questions
        if let first = questions.first {
            fields["question_prompt"] = first["prompt"] as? String ?? ""
            fields["question_multi_select"] = first["multi_select"] as? Bool ?? false
            fields["question_options"] = first["options"] as? [[String: Any]] ?? []
        }
    }

    private func firstNonEmptyLine(_ value: String) -> String? {
        value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private func jsonString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            return string
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else {
            return String(describing: value)
        }
        return String(data: data, encoding: .utf8)
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }
}
