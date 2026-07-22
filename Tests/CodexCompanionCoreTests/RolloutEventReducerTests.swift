import CodexCompanionCore
import Foundation
import Testing

@Suite
struct RolloutEventReducerTests {
    @Test
    func startAndCompletionFollowTheTaskLifecycle() {
        var reducer = RolloutEventReducer()
        let startedAt = Date(timeIntervalSince1970: 1_784_648_776)
        let finishedAt = Date(timeIntervalSince1970: 1_784_715_636.379)

        reducer.consume(line: event("event_msg", [
            "type": "task_started",
            "started_at": startedAt.timeIntervalSince1970
        ]))
        #expect(reducer.status == .working)
        #expect(reducer.workingSince == startedAt)
        #expect(reducer.finishedAt == nil)

        reducer.consume(line: event(
            "event_msg",
            [
                "type": "task_complete",
                "started_at": startedAt.timeIntervalSince1970,
                "completed_at": 1_784_715_636
            ],
            timestamp: "2026-07-22T10:20:36.379Z"
        ))
        #expect(reducer.status == .finished)
        #expect(reducer.workingSince == nil)
        #expect(reducer.finishedAt == finishedAt)
    }

    @Test
    func completionFallsBackToCompletedAtWithoutAnEnvelopeTimestamp() {
        var reducer = RolloutEventReducer()
        let completedAt = Date(timeIntervalSince1970: 1_784_715_636)

        reducer.consume(line: event("event_msg", [
            "type": "task_complete",
            "started_at": 1_784_648_776,
            "completed_at": completedAt.timeIntervalSince1970
        ]))

        #expect(reducer.finishedAt == completedAt)
    }

    @Test
    func inputWaitClearsOnlyForItsMatchingOutput() {
        var reducer = RolloutEventReducer()
        reducer.consume(line: event("event_msg", ["type": "task_started"]))
        reducer.consume(line: event("response_item", [
            "type": "function_call",
            "name": "request_user_input",
            "call_id": "input-1"
        ]))

        #expect(reducer.status == .waitingForInput)
        reducer.consume(line: event("response_item", ["type": "function_call_output", "call_id": "other"]))
        #expect(reducer.status == .waitingForInput)
        reducer.consume(line: event("response_item", ["type": "function_call_output", "call_id": "input-1"]))
        #expect(reducer.status == .working)
    }

    @Test
    func permissionWaitRecognizesCurrentCodeModeShape() {
        var reducer = RolloutEventReducer()
        reducer.consume(line: event("event_msg", ["type": "task_started"]))
        reducer.consume(line: event("response_item", [
            "type": "custom_tool_call",
            "name": "exec",
            "call_id": "approval-1",
            "input": #"tools.exec_command({sandbox_permissions:"require_escalated"})"#
        ]))

        #expect(reducer.status == .waitingForPermission)
        reducer.consume(line: event("response_item", ["type": "custom_tool_call_output", "call_id": "approval-1"]))
        #expect(reducer.status == .working)
    }

    @Test
    func escapedPermissionTokensInSourceDoNotCreateAWait() {
        var reducer = RolloutEventReducer()
        reducer.consume(line: event("event_msg", ["type": "task_started"]))
        reducer.consume(line: event("response_item", [
            "type": "custom_tool_call",
            "name": "exec",
            "call_id": "ordinary-call",
            "input": #"let fixture = \"sandbox_permissions\":\"require_escalated\""#
        ]))

        #expect(reducer.status == .working)
    }

    @Test(arguments: ["interrupted", "cancelled", "replaced"])
    func benignAbortReasonsBecomeInactive(_ reason: String) {
        var reducer = RolloutEventReducer()
        reducer.consume(line: event("event_msg", ["type": "task_started"]))
        reducer.consume(line: event("event_msg", ["type": "turn_aborted", "reason": reason]))
        #expect(reducer.status == .inactive)
    }

    @Test
    func explicitFailureRecoversOnTheNextTask() {
        var reducer = RolloutEventReducer()
        reducer.consume(line: event("event_msg", ["type": "task_failed"]))
        #expect(reducer.status == .error)
        reducer.consume(line: event("event_msg", ["type": "task_started"]))
        #expect(reducer.status == .working)
    }

    @Test
    func exclusionIsPermanentWhenParentMetadataIsCopiedLater() {
        var reducer = RolloutEventReducer()
        reducer.consume(line: event("session_meta", [
            "source": ["subagent": ["thread_spawn": ["parent_thread_id": "parent"]]],
            "thread_source": "subagent"
        ]))
        reducer.consume(line: event("session_meta", ["source": "vscode", "thread_source": "automation"]))

        #expect(reducer.isExcluded)
        #expect(reducer.isAgent)
        #expect(!reducer.isBatch)
    }

    @Test
    func topLevelAutomationIsNotExcluded() {
        var reducer = RolloutEventReducer()
        reducer.consume(line: event("session_meta", [
            "source": "vscode",
            "thread_source": "automation"
        ]))

        #expect(!reducer.isExcluded)
        #expect(!reducer.isAgent)
        #expect(!reducer.isBatch)
    }

    @Test
    func batchExecRemainsExcluded() {
        var reducer = RolloutEventReducer()
        reducer.consume(line: event("session_meta", [
            "source": "exec",
            "thread_source": "user",
            "originator": "codex_exec"
        ]))

        #expect(reducer.isExcluded)
        #expect(reducer.isBatch)
        #expect(!reducer.isAgent)
    }

    @Test
    func malformedAndIrrelevantLinesDoNotChangeState() {
        var reducer = RolloutEventReducer()
        reducer.consume(line: "not json event_msg")
        reducer.consume(line: event("response_item", ["type": "message", "text": "Script failed"] ))
        #expect(reducer.status == .inactive)
        #expect(!reducer.isExcluded)
    }

    private func event(_ type: String, _ payload: [String: Any], timestamp: String? = nil) -> String {
        var envelope: [String: Any] = ["type": type, "payload": payload]
        if let timestamp {
            envelope["timestamp"] = timestamp
        }
        let data = try! JSONSerialization.data(withJSONObject: envelope)
        return String(decoding: data, as: UTF8.self)
    }
}
