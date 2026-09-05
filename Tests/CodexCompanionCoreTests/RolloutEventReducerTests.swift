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
    func workingPreviewUsesLatestCommentaryAndKeepsTwoRecentUpdates() {
        var reducer = RolloutEventReducer()
        reducer.consume(line: event("event_msg", ["type": "task_started"]))
        reducer.consume(line: event("event_msg", [
            "type": "agent_message",
            "phase": "commentary",
            "message": "Inspecting the rollout format."
        ]))
        reducer.consume(line: event("event_msg", [
            "type": "agent_message",
            "phase": "commentary",
            "message": "Building the activity model."
        ]))
        reducer.consume(line: event("event_msg", [
            "type": "agent_message",
            "phase": "commentary",
            "message": "Running the full test suite."
        ]))

        #expect(reducer.activity?.headline == "Running the full test suite.")
        #expect(
            reducer.activity?.recentEvents.map(\.title)
                == ["Inspecting the rollout format.", "Building the activity model."]
        )
    }

    @Test
    func completedAgentItemsProvideCommentaryAndFinalSummaries() {
        var reducer = RolloutEventReducer()
        reducer.consume(line: event("event_msg", ["type": "task_started"]))
        reducer.consume(line: event("event_msg", [
            "type": "item_completed",
            "item": [
                "type": "AgentMessage",
                "id": "commentary-1",
                "phase": "commentary",
                "content": [
                    ["type": "Text", "text": "Inspecting the **current** format."],
                    ["type": "Text", "text": "Checking the activity preview."],
                    ["type": "Image", "text": "Not narration"]
                ]
            ]
        ], timestamp: "2026-09-05T07:54:09.256Z"))

        #expect(reducer.status == .working)
        #expect(reducer.activity?.headline == "Inspecting the current format. Checking the activity preview.")

        reducer.consume(line: completedAgentMessage(
            "The activity preview is ready.",
            phase: "final_answer",
            timestamp: "2026-09-05T07:55:00.000Z"
        ))
        reducer.consume(line: event("event_msg", ["type": "task_complete"], timestamp: "2026-09-05T07:55:01.000Z"))

        #expect(reducer.status == .finished)
        #expect(reducer.activity?.headline == "The activity preview is ready.")
        #expect(reducer.activity?.recentEvents.map(\.title) == [
            "Inspecting the current format. Checking the activity preview."
        ])
    }

    @Test
    func duplicateModernAndLegacyNarrationKeepsTheOriginalTimestamp() throws {
        var reducer = RolloutEventReducer()
        let firstTimestamp = "2026-09-05T07:54:09.256Z"
        let firstDate = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(firstTimestamp)
        reducer.consume(line: event("event_msg", ["type": "task_started"]))
        reducer.consume(line: completedAgentMessage("Inspecting the task.", timestamp: firstTimestamp))
        reducer.consume(line: event("event_msg", [
            "type": "agent_message",
            "phase": "commentary",
            "message": "Inspecting the task."
        ], timestamp: "2026-09-05T07:54:10.000Z"))

        #expect(reducer.activity?.recentEvents.isEmpty == true)

        reducer.consume(line: completedAgentMessage(
            "Checking the result.",
            timestamp: "2026-09-05T07:55:00.000Z"
        ))
        #expect(reducer.activity?.recentEvents.count == 1)
        #expect(reducer.activity?.recentEvents.first?.occurredAt == firstDate)

        reducer.consume(line: completedAgentMessage(
            "The task is ready.",
            phase: "final_answer",
            timestamp: "2026-09-05T07:56:00.000Z"
        ))
        reducer.consume(line: event("event_msg", [
            "type": "agent_message",
            "phase": "final_answer",
            "message": "The task is ready."
        ]))
        reducer.consume(line: event("event_msg", ["type": "task_complete", "last_agent_message": "The task is ready."]))
        #expect(reducer.activity?.recentEvents.map(\.title) == ["Inspecting the task.", "Checking the result."])
    }

    @Test
    func incompleteAndNonTextItemsDoNotReplaceNarration() {
        var reducer = RolloutEventReducer()
        reducer.consume(line: event("event_msg", ["type": "task_started"]))
        reducer.consume(line: completedAgentMessage("The visible update."))
        for item in [
            ["type": "AgentMessage", "phase": "commentary", "content": [["type": "Text", "text": NSNull()]]],
            ["type": "AgentMessage", "phase": "commentary", "content": [["type": "Image", "text": "Not narration"]]],
            ["type": "Reasoning", "phase": "commentary", "content": [["type": "Text", "text": "Not narration"]]]
        ] as [[String: Any]] {
            reducer.consume(line: event("event_msg", ["type": "item_completed", "item": item]))
        }
        reducer.consume(line: event("event_msg", [
            "type": "item_started",
            "item": ["type": "AgentMessage", "phase": "commentary", "content": [["type": "Text", "text": "Incomplete update"]]]
        ]))

        #expect(reducer.status == .working)
        #expect(reducer.activity?.headline == "The visible update.")
        #expect(reducer.activity?.recentEvents.isEmpty == true)
    }

    @Test
    func recentUpdatesKeepTheirOwnTimestamps() {
        var reducer = RolloutEventReducer()
        let firstTimestamp = "2026-07-22T10:00:00.000Z"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        reducer.consume(line: event("event_msg", ["type": "task_started"]))
        reducer.consume(line: event(
            "event_msg",
            [
                "type": "agent_message",
                "phase": "commentary",
                "message": "Inspecting the task."
            ],
            timestamp: firstTimestamp
        ))
        reducer.consume(line: event(
            "event_msg",
            [
                "type": "agent_message",
                "phase": "commentary",
                "message": "Implementing the change."
            ],
            timestamp: "2026-07-22T10:05:00.000Z"
        ))

        #expect(
            reducer.activity?.recentEvents.first?.occurredAt
                == formatter.date(from: firstTimestamp)
        )
    }

    @Test
    func recentUpdatesStayChronologicalAcrossPatchesAndCommentary() {
        var reducer = RolloutEventReducer()
        reducer.consume(line: event("event_msg", ["type": "task_started"]))
        reducer.consume(line: event(
            "event_msg",
            [
                "type": "agent_message",
                "phase": "commentary",
                "message": "Inspecting the implementation."
            ],
            timestamp: "2026-07-22T10:00:00.000Z"
        ))
        reducer.consume(line: event(
            "event_msg",
            ["type": "patch_apply_end", "success": true],
            timestamp: "2026-07-22T10:01:00.000Z"
        ))
        reducer.consume(line: event(
            "event_msg",
            [
                "type": "agent_message",
                "phase": "commentary",
                "message": "Running the test suite."
            ],
            timestamp: "2026-07-22T10:02:00.000Z"
        ))

        #expect(reducer.activity?.headline == "Running the test suite.")
        #expect(
            reducer.activity?.recentEvents.map(\.title)
                == ["Inspecting the implementation.", "Updated code"]
        )
    }

    @Test
    func completionKeepsTheLatestCommentaryInRecentActivity() {
        var reducer = RolloutEventReducer()
        reducer.consume(line: event("event_msg", ["type": "task_started"]))
        reducer.consume(line: event(
            "event_msg",
            [
                "type": "agent_message",
                "phase": "commentary",
                "message": "Running the final checks."
            ],
            timestamp: "2026-07-22T10:00:00.000Z"
        ))
        reducer.consume(line: event(
            "event_msg",
            [
                "type": "agent_message",
                "phase": "final_answer",
                "message": "The change is ready."
            ],
            timestamp: "2026-07-22T10:01:00.000Z"
        ))
        reducer.consume(line: event(
            "event_msg",
            ["type": "task_complete", "last_agent_message": "The change is ready."],
            timestamp: "2026-07-22T10:02:00.000Z"
        ))

        #expect(reducer.activity?.headline == "The change is ready.")
        #expect(reducer.activity?.recentEvents.map(\.title) == ["Running the final checks."])
    }

    @Test
    func inputPreviewUsesTheQuestionAndClearsOnlyForItsOutput() throws {
        var reducer = RolloutEventReducer()
        let argumentsData = try JSONSerialization.data(withJSONObject: [
            "questions": [[
                "header": "Direction",
                "id": "direction",
                "question": "Which layout should Task Deck use?",
                "options": []
            ]]
        ])
        let arguments = String(decoding: argumentsData, as: UTF8.self)

        reducer.consume(line: event("event_msg", ["type": "task_started"]))
        reducer.consume(line: event("event_msg", [
            "type": "agent_message",
            "phase": "commentary",
            "message": "I need one product decision before continuing."
        ]))
        reducer.consume(line: event("response_item", [
            "type": "function_call",
            "name": "request_user_input",
            "call_id": "input-1",
            "arguments": arguments
        ]))

        #expect(reducer.status == .waitingForInput)
        #expect(reducer.activity?.headline == "Which layout should Task Deck use?")
        #expect(reducer.activity?.detail == "I need one product decision before continuing.")

        reducer.consume(line: event("response_item", [
            "type": "function_call_output",
            "call_id": "other"
        ]))
        #expect(reducer.status == .waitingForInput)

        reducer.consume(line: event("response_item", [
            "type": "function_call_output",
            "call_id": "input-1"
        ]))
        #expect(reducer.status == .working)
        #expect(reducer.activity?.headline == "I need one product decision before continuing.")
    }

    @Test
    func permissionPreviewStaysGenericAndReadOnly() {
        var reducer = RolloutEventReducer()
        reducer.consume(line: event("event_msg", ["type": "task_started"]))
        reducer.consume(line: event("event_msg", [
            "type": "agent_message",
            "phase": "commentary",
            "message": "The release build needs access outside the workspace."
        ]))
        reducer.consume(line: event("response_item", [
            "type": "custom_tool_call",
            "name": "exec",
            "call_id": "approval-1",
            "input": #"tools.exec_command({cmd:"sensitive command",sandbox_permissions:"require_escalated"})"#
        ]))

        #expect(reducer.status == .waitingForPermission)
        #expect(reducer.activity?.headline == "Codex needs permission to continue.")
        #expect(reducer.activity?.detail == "The release build needs access outside the workspace.")
        #expect(reducer.activity?.headline.contains("sensitive command") == false)
    }

    @Test
    func finishedAndErrorPreviewsUseLifecycleSummaries() {
        var reducer = RolloutEventReducer()
        reducer.consume(line: event("event_msg", ["type": "task_started"]))
        reducer.consume(line: event("event_msg", [
            "type": "task_complete",
            "last_agent_message": "Implemented and verified the activity preview."
        ]))
        #expect(reducer.status == .finished)
        #expect(reducer.activity?.headline == "Implemented and verified the activity preview.")

        reducer.consume(line: event("event_msg", ["type": "task_started"]))
        #expect(reducer.activity?.headline == "Codex is working on this task.")
        #expect(reducer.activity?.recentEvents.isEmpty == true)
        reducer.consume(line: event("event_msg", [
            "type": "task_failed",
            "message": "The build could not be signed."
        ]))
        #expect(reducer.status == .error)
        #expect(reducer.activity?.headline == "The build could not be signed.")
    }

    @Test
    func nonStringLifecycleValuesDoNotReplaceSafeSummaries() {
        var reducer = RolloutEventReducer()
        reducer.consume(line: event("event_msg", ["type": "task_started"]))
        reducer.consume(line: event("event_msg", [
            "type": "agent_message",
            "phase": "final_answer",
            "message": "The verified completion summary."
        ]))
        reducer.consume(line: event("event_msg", [
            "type": "task_complete",
            "last_agent_message": NSNull()
        ]))

        #expect(reducer.activity?.headline == "The verified completion summary.")

        reducer.consume(line: event("event_msg", ["type": "task_started"]))
        reducer.consume(line: event("event_msg", [
            "type": "task_failed",
            "error": ["command": "private command"],
            "reason": "The build failed safely."
        ]))

        #expect(reducer.activity?.headline == "The build failed safely.")
        #expect(reducer.activity?.headline.contains("private command") == false)
    }

    @Test(arguments: [false, true])
    func activityTextIsBoundedDuringRecovery(modernFormat: Bool) {
        var reducer = RolloutEventReducer()
        reducer.consume(line: event("event_msg", ["type": "task_started"]))
        let message = String(repeating: "x", count: 70_000)
        reducer.consume(line: modernFormat ? completedAgentMessage(message) : event("event_msg", [
            "type": "agent_message",
            "phase": "commentary",
            "message": message
        ]))

        #expect(reducer.activity?.headline.count == 280)
        #expect(reducer.activity?.headline.hasSuffix("…") == true)

        reducer.consume(line: event("event_msg", ["type": "task_failed", "message": "The attempt failed."]))
        reducer.consume(line: event("event_msg", ["type": "task_started"]))
        #expect(reducer.activity?.headline == "Codex is working on this task.")
        #expect(reducer.activity?.recentEvents.isEmpty == true)
        reducer.consume(line: completedAgentMessage("The new attempt is running."))
        #expect(reducer.status == .working)
        #expect(reducer.activity?.headline == "The new attempt is running.")
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

    private func completedAgentMessage(
        _ message: String,
        phase: String = "commentary",
        timestamp: String? = nil
    ) -> String {
        event("event_msg", [
            "type": "item_completed",
            "item": [
                "type": "AgentMessage",
                "id": "message-1",
                "phase": phase,
                "content": [["type": "Text", "text": message]]
            ]
        ], timestamp: timestamp)
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
