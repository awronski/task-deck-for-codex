import Foundation

public enum PendingAttention: String, Codable, Sendable {
    case input
    case permission
}

private struct PendingActivity: Equatable, Sendable {
    let headline: String
}

public struct RolloutEventReducer: Equatable, Sendable {
    private static let envelopeTimestampFormat = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )

    public private(set) var isActive = false
    public private(set) var isAgent = false
    public private(set) var isBatch = false
    public private(set) var hasFailed = false
    public private(set) var hasFinished = false
    public private(set) var hasLifecycleEvent = false
    public private(set) var pendingCalls: [String: PendingAttention] = [:]
    public private(set) var workingSince: Date?
    public private(set) var finishedAt: Date?

    private var pendingActivities: [String: PendingActivity] = [:]
    private var latestNarration: String?
    private var latestNarrationAt: Date?
    private var completionSummary: String?
    private var failureSummary: String?
    private var recentEvents: [TaskActivityEvent] = []

    public init() {}

    public var isExcluded: Bool {
        isAgent || isBatch
    }

    public var status: AttentionStatus {
        if hasFailed { return .error }
        if pendingCalls.values.contains(.input) { return .waitingForInput }
        if pendingCalls.values.contains(.permission) { return .waitingForPermission }
        if hasFinished { return .finished }
        return isActive ? .working : .inactive
    }

    public var activity: TaskActivityPreview? {
        switch status {
        case .waitingForInput:
            return pendingPreview(
                for: .input,
                fallback: "Codex needs your input to continue."
            )
        case .waitingForPermission:
            return pendingPreview(
                for: .permission,
                fallback: "Codex needs permission to continue."
            )
        case .working:
            return TaskActivityPreview(
                headline: latestNarration ?? "Codex is working on this task.",
                recentEvents: recentEvents
            )
        case .finished:
            return TaskActivityPreview(
                headline: completionSummary ?? latestNarration ?? "Task completed successfully.",
                recentEvents: recentEvents
            )
        case .error:
            return TaskActivityPreview(
                headline: failureSummary ?? "Codex could not complete this task.",
                detail: latestNarration,
                recentEvents: recentEvents
            )
        case .inactive:
            return nil
        }
    }

    public mutating func consume(line: String) {
        guard line.contains("\"session_meta\"")
                || line.contains("\"event_msg\"")
                || line.contains("\"response_item\"")
                || line.contains("\"error\"")
        else {
            return
        }

        guard let data = line.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }

        let envelopeType = envelope["type"] as? String
        let payload = envelope["payload"] as? [String: Any] ?? [:]
        let eventType = payload["type"] as? String
        if envelopeType == "session_meta" {
            permanentlyExcludeIfNeeded(payload)
            return
        }

        switch eventType {
        case "task_started":
            hasLifecycleEvent = true
            isActive = true
            hasFailed = false
            hasFinished = false
            pendingCalls.removeAll()
            pendingActivities.removeAll()
            latestNarration = nil
            latestNarrationAt = nil
            completionSummary = nil
            failureSummary = nil
            recentEvents.removeAll()
            workingSince = payloadDate("started_at", in: payload) ?? envelopeDate(envelope)
            finishedAt = nil

        case "task_complete":
            hasLifecycleEvent = true
            isActive = false
            hasFailed = false
            hasFinished = true
            pendingCalls.removeAll()
            pendingActivities.removeAll()
            if let summary = cleanText(payload["last_agent_message"]) {
                recordLatestNarration(excluding: summary)
                completionSummary = summary
            }
            workingSince = nil
            finishedAt = envelopeDate(envelope) ?? payloadDate("completed_at", in: payload)

        case "turn_aborted":
            hasLifecycleEvent = true
            isActive = false
            hasFinished = false
            pendingCalls.removeAll()
            pendingActivities.removeAll()
            workingSince = nil
            finishedAt = nil
            let reason = cleanText(payload["reason"])?.lowercased() ?? ""
            let isBenign = ["interrupted", "cancelled", "replaced"].contains(reason)
            hasFailed = !isBenign
            if !isBenign {
                failureSummary = reason.isEmpty
                    ? "Codex stopped before completing this task."
                    : "Codex stopped: \(reason)."
            }

        case "agent_message":
            recordAgentMessage(
                payload["message"],
                phase: payload["phase"] as? String,
                occurredAt: envelopeDate(envelope)
            )

        case "item_completed":
            guard envelopeType == "event_msg",
                  let item = payload["item"] as? [String: Any],
                  item["type"] as? String == "AgentMessage",
                  let content = item["content"] as? [[String: Any]]
            else { return }
            let message = content.compactMap { block -> String? in
                guard block["type"] as? String == "Text" else { return nil }
                return block["text"] as? String
            }.joined(separator: "\n")
            recordAgentMessage(
                message,
                phase: item["phase"] as? String,
                occurredAt: envelopeDate(envelope)
            )

        case "function_call", "custom_tool_call":
            recordPendingCall(payload)

        case "function_call_output", "custom_tool_call_output":
            let id = callID(in: payload)
            pendingCalls.removeValue(forKey: id)
            pendingActivities.removeValue(forKey: id)

        case "patch_apply_end":
            if payload["success"] as? Bool == true {
                recordRecent("Updated code", occurredAt: envelopeDate(envelope))
            }

        case "error", "task_failed":
            markFailed(message: errorMessage(in: payload))

        default:
            if envelopeType == "error" {
                markFailed(message: errorMessage(in: payload))
            }
        }
    }

    private func pendingPreview(
        for attention: PendingAttention,
        fallback: String
    ) -> TaskActivityPreview {
        let callID = pendingCalls.first(where: { $0.value == attention })?.key
        let headline = callID.flatMap { pendingActivities[$0]?.headline } ?? fallback
        let detail = latestNarration == headline ? nil : latestNarration
        return TaskActivityPreview(
            headline: headline,
            detail: detail,
            recentEvents: recentEvents
        )
    }

    private mutating func recordAgentMessage(_ value: Any?, phase: String?, occurredAt: Date?) {
        guard let message = cleanText(value) else { return }
        switch phase {
        case "commentary":
            guard latestNarration != message else { return }
            if let latestNarration {
                recordRecent(latestNarration, occurredAt: latestNarrationAt)
            }
            latestNarration = message
            latestNarrationAt = occurredAt
        case "final_answer":
            recordLatestNarration(excluding: message)
            completionSummary = message
        default:
            break
        }
    }

    private mutating func permanentlyExcludeIfNeeded(_ payload: [String: Any]) {
        let sourceString = (payload["source"] as? String)?.lowercased() ?? ""
        let threadSource = (payload["thread_source"] as? String)?.lowercased() ?? ""
        let originator = (payload["originator"] as? String)?.lowercased() ?? ""
        let sourceObject = payload["source"] as? [String: Any]

        isAgent = isAgent
            || sourceString.contains("subagent")
            || threadSource.contains("subagent")
            || sourceObject?.keys.contains(where: { $0.lowercased().contains("subagent") }) == true
        isBatch = isBatch || sourceString == "exec" || originator == "codex_exec"
    }

    private mutating func recordPendingCall(_ payload: [String: Any]) {
        let name = (payload["name"] as? String) ?? ""
        let id = callID(in: payload)

        if name == "request_user_input" {
            pendingCalls[id] = .input
            pendingActivities[id] = PendingActivity(
                headline: requestQuestion(in: payload) ?? "Codex needs your input to continue."
            )
            return
        }

        let input = String(describing: payload["input"] ?? payload["arguments"] ?? "")
        let permissionPattern = #"(?:[\"']?sandbox_permissions[\"']?)\s*:\s*[\"']require_escalated[\"']"#
        if ["exec", "exec_command"].contains(name),
           input.range(of: permissionPattern, options: .regularExpression) != nil
        {
            pendingCalls[id] = .permission
            pendingActivities[id] = PendingActivity(
                headline: "Codex needs permission to continue."
            )
        }
    }

    private func requestQuestion(in payload: [String: Any]) -> String? {
        let rawArguments = payload["arguments"] ?? payload["input"]
        let arguments: [String: Any]?
        if let dictionary = rawArguments as? [String: Any] {
            arguments = dictionary
        } else if let string = rawArguments as? String,
                  let data = string.data(using: .utf8)
        {
            arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } else {
            arguments = nil
        }

        guard let questions = arguments?["questions"] as? [[String: Any]],
              let first = questions.first
        else {
            return nil
        }
        return cleanText(first["question"])
    }

    private func callID(in payload: [String: Any]) -> String {
        String(describing: payload["call_id"] ?? "unknown")
    }

    private mutating func markFailed(message: String?) {
        hasLifecycleEvent = true
        isActive = false
        hasFailed = true
        hasFinished = false
        pendingCalls.removeAll()
        pendingActivities.removeAll()
        failureSummary = message
        workingSince = nil
        finishedAt = nil
    }

    private func errorMessage(in payload: [String: Any]) -> String? {
        ["message", "error", "reason"]
            .lazy
            .compactMap { cleanText(payload[$0]) }
            .first
    }

    private mutating func recordLatestNarration(excluding summary: String) {
        guard let latestNarration, latestNarration != summary else { return }
        recordRecent(latestNarration, occurredAt: latestNarrationAt)
    }

    private mutating func recordRecent(_ title: String, occurredAt: Date?) {
        let title = cleanText(title, limit: 120) ?? ""
        guard !title.isEmpty else { return }

        let event = TaskActivityEvent(title: title, occurredAt: occurredAt)
        recentEvents.removeAll { $0.title == title }
        if let occurredAt,
           let insertionIndex = recentEvents.firstIndex(where: {
               guard let existingDate = $0.occurredAt else { return false }
               return occurredAt < existingDate
           })
        {
            recentEvents.insert(event, at: insertionIndex)
        } else {
            recentEvents.append(event)
        }
        if recentEvents.count > 2 {
            recentEvents.removeFirst(recentEvents.count - 2)
        }
    }

    private func cleanText(_ value: Any?, limit: Int = 280) -> String? {
        guard let source = value as? String else { return nil }
        let normalized = source
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > limit else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: limit - 1)
        return String(normalized[..<end]).trimmingCharacters(in: .whitespaces) + "…"
    }

    private func payloadDate(_ key: String, in payload: [String: Any]) -> Date? {
        guard let seconds = payload[key] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: seconds.doubleValue)
    }

    private func envelopeDate(_ envelope: [String: Any]) -> Date? {
        guard let timestamp = envelope["timestamp"] as? String else { return nil }
        return try? Self.envelopeTimestampFormat.parse(timestamp)
    }
}
