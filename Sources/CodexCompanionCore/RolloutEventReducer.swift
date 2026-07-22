import Foundation

public enum PendingAttention: String, Codable, Sendable {
    case input
    case permission
}

public struct RolloutEventReducer: Equatable, Sendable {
    public private(set) var isActive = false
    public private(set) var isAgent = false
    public private(set) var isBatch = false
    public private(set) var hasFailed = false
    public private(set) var hasFinished = false
    public private(set) var hasLifecycleEvent = false
    public private(set) var pendingCalls: [String: PendingAttention] = [:]
    public private(set) var workingSince: Date?
    public private(set) var finishedAt: Date?

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
            workingSince = payloadDate("started_at", in: payload) ?? envelopeDate(envelope)
            finishedAt = nil

        case "task_complete":
            hasLifecycleEvent = true
            isActive = false
            hasFailed = false
            hasFinished = true
            pendingCalls.removeAll()
            workingSince = nil
            finishedAt = envelopeDate(envelope) ?? payloadDate("completed_at", in: payload)

        case "turn_aborted":
            hasLifecycleEvent = true
            isActive = false
            hasFinished = false
            pendingCalls.removeAll()
            workingSince = nil
            finishedAt = nil
            let reason = String(describing: payload["reason"] ?? "").lowercased()
            hasFailed = !["interrupted", "cancelled", "replaced"].contains(reason)

        case "function_call", "custom_tool_call":
            recordPendingCall(payload)

        case "function_call_output", "custom_tool_call_output":
            pendingCalls.removeValue(forKey: callID(in: payload))

        case "error", "task_failed":
            markFailed()

        default:
            if envelopeType == "error" {
                markFailed()
            }
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
            return
        }

        let input = String(describing: payload["input"] ?? "")
        let permissionPattern = #"(?:[\"']?sandbox_permissions[\"']?)\s*:\s*[\"']require_escalated[\"']"#
        if ["exec", "exec_command"].contains(name),
           input.range(of: permissionPattern, options: .regularExpression) != nil
        {
            pendingCalls[id] = .permission
        }
    }

    private func callID(in payload: [String: Any]) -> String {
        String(describing: payload["call_id"] ?? "unknown")
    }

    private mutating func markFailed() {
        hasLifecycleEvent = true
        isActive = false
        hasFailed = true
        hasFinished = false
        pendingCalls.removeAll()
        workingSince = nil
        finishedAt = nil
    }

    private func payloadDate(_ key: String, in payload: [String: Any]) -> Date? {
        guard let seconds = payload[key] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: seconds.doubleValue)
    }

    private func envelopeDate(_ envelope: [String: Any]) -> Date? {
        guard let timestamp = envelope["timestamp"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: timestamp)
    }
}
