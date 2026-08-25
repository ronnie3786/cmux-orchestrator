import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Herdr API decoding")
struct HerdrAPIDecodingTests {
    @Test("A complete workspace graph decodes from the backend contract")
    func decodesWorkspaceGraph() throws {
        let response = try decode(
            WorkspacesResponse.self,
            from: """
            {
              "ok": true,
              "generated_at": "2026-08-11T18:42:00Z",
              "workspaces": [
                {
                  "workspace_id": "w7",
                  "number": 7,
                  "label": "Herdr Harness",
                  "focused": true,
                  "pane_count": 1,
                  "tab_count": 1,
                  "active_tab_id": "w7:t1",
                  "agent_status": "blocked",
                  "tokens": { "branch": "codex/herdr-harness" },
                  "worktree": {
                    "repo_key": "herdr",
                    "repo_name": "Herdr",
                    "repo_root": "/work/herdr",
                    "checkout_path": "/work/herdr-ios",
                    "is_linked_worktree": true
                  },
                  "tabs": [
                    {
                      "tab_id": "w7:t1",
                      "workspace_id": "w7",
                      "number": 1,
                      "label": "Agents",
                      "focused": true,
                      "pane_count": 1,
                      "agent_status": "blocked"
                    }
                  ],
                  "panes": [
                    {
                      "pane_id": "w7:p1",
                      "terminal_id": "term-1",
                      "workspace_id": "w7",
                      "tab_id": "w7:t1",
                      "focused": true,
                      "agent_status": "blocked",
                      "revision": 91,
                      "first_seen_at": "2026-08-11T17:00:00Z",
                      "last_activity_at": "2026-08-11T18:41:30.125Z",
                      "working_since": "2026-08-11T18:00:00Z",
                      "cwd": "/work/herdr-ios",
                      "foreground_cwd": "/work/herdr-ios/App",
                      "title": "Waiting for approval",
                      "agent": "codex",
                      "display_agent": "Codex"
                    }
                  ],
                  "agents": [
                    {
                      "terminal_id": "term-1",
                      "workspace_id": "w7",
                      "tab_id": "w7:t1",
                      "pane_id": "w7:p1",
                      "focused": true,
                      "agent_status": "blocked",
                      "revision": 91,
                      "state_change_seq": 12,
                      "agent": "codex",
                      "display_agent": "Codex",
                      "interactive_ready": true
                    }
                  ],
                  "layouts": [
                    {
                      "workspace_id": "w7",
                      "tab_id": "w7:t1",
                      "focused_pane_id": "w7:p1",
                      "zoomed": false,
                      "area": { "x": 0, "y": 0, "width": 120, "height": 36 },
                      "panes": [
                        {
                          "pane_id": "w7:p1",
                          "focused": true,
                          "rect": { "x": 0, "y": 0, "width": 120, "height": 36 }
                        }
                      ],
                      "splits": []
                    }
                  ]
                }
              ],
              "alerts": [
                {
                  "id": "alert-7",
                  "workspace_id": "w7",
                  "pane_id": "w7:p1",
                  "status": "blocked",
                  "title": "Codex needs you",
                  "message": "Review the proposed command.",
                  "created_at": "2026-08-11T18:41:30Z",
                  "is_read": false
                }
              ]
            }
            """
        )

        #expect(response.ok)
        #expect(response.generatedAt == "2026-08-11T18:42:00Z")
        #expect(response.workspaces.count == 1)

        let workspace = try #require(response.workspaces.first)
        #expect(workspace.id == "w7")
        #expect(workspace.displayPath == "/work/herdr-ios")
        #expect(workspace.tokens["branch"] == "codex/herdr-harness")
        #expect(workspace.tabs.map(\.id) == ["w7:t1"])
        #expect(workspace.panes.map(\.id) == ["w7:p1"])
        #expect(workspace.panes.first?.firstSeenAt == HerdrTimestamp.date(from: "2026-08-11T17:00:00Z"))
        #expect(workspace.panes.first?.lastActivityAt == HerdrTimestamp.date(from: "2026-08-11T18:41:30.125Z"))
        #expect(workspace.panes.first?.workingSince == HerdrTimestamp.date(from: "2026-08-11T18:00:00Z"))
        #expect(workspace.agents.first?.interactiveReady == true)
        #expect(workspace.layouts.first?.area.width == 120)
        #expect(response.alerts.first?.status == .blocked)
    }

    @Test("Forward-compatible defaults keep a partial snapshot usable")
    func defaultsPartialSnapshotAndUnknownStatus() throws {
        let response = try decode(
            WorkspacesResponse.self,
            from: """
            {
              "workspaces": [
                {
                  "workspace_id": "w-minimal",
                  "panes": [
                    {
                      "pane_id": "w-minimal:p9",
                      "workspace_id": "w-minimal",
                      "tab_id": "w-minimal:t1",
                      "agent_status": "future-status"
                    }
                  ]
                }
              ]
            }
            """
        )

        #expect(response.ok)
        #expect(response.alerts.isEmpty)
        let workspace = try #require(response.workspaces.first)
        #expect(workspace.label == "w-minimal")
        #expect(workspace.number == 0)
        #expect(workspace.tokens.isEmpty)
        #expect(workspace.panes.first?.agentStatus == .unknown)
        #expect(workspace.panes.first?.terminalID == "w-minimal:p9")
        #expect(workspace.panes.first?.displayTitle == "Pane 9")
    }

    @Test("Pane output supports nested output, nested read, and flat payloads")
    func decodesPaneOutputVariants() throws {
        let output = try decode(
            PaneOutputResponse.self,
            from: """
            { "ok": true, "output": { "pane_id": "w1:p1", "text": "one", "revision": 8, "truncated": false } }
            """
        )
        let read = try decode(
            PaneOutputResponse.self,
            from: """
            { "read": { "pane_id": "w1:p2", "text": "two", "revision": 9, "truncated": true } }
            """
        )
        let flat = try decode(
            PaneOutputResponse.self,
            from: """
            { "pane_id": "w1:p3", "text": "three", "revision": 10, "truncated": false }
            """
        )

        #expect(output.paneID == "w1:p1")
        #expect(output.text == "one")
        #expect(read.paneID == "w1:p2")
        #expect(read.truncated)
        #expect(flat.paneID == "w1:p3")
        #expect(flat.revision == 10)
    }

    @Test("Split pane responses decode an optional pane ID")
    func decodesSplitPaneResponse() throws {
        let created = try decode(SplitPaneResponse.self, from: #"{ "ok": true, "paneId": "w1:p2" }"#)
        let absent = try decode(SplitPaneResponse.self, from: #"{ "ok": true, "paneId": null }"#)

        #expect(created.ok)
        #expect(created.paneID == "w1:p2")
        #expect(absent.paneID == nil)
    }

    @Test("Alert aliases and synthetic identity remain backward compatible")
    func decodesAlertAliases() throws {
        let alert = try decode(
            HerdrAlert.self,
            from: """
            {
              "workspace_id": "w2",
              "pane_id": "w2:p4",
              "kind": "done",
              "read": true
            }
            """
        )

        #expect(alert.id == "w2:p4:done")
        #expect(alert.status == .done)
        #expect(alert.title == "Ready")
        #expect(alert.isRead)

        let nativeHarnessAlert = try decode(
            HerdrAlert.self,
            from: """
            {
              "id": "alert-live",
              "workspaceId": "w3",
              "paneId": "w3:p2",
              "status": "blocked",
              "title": "Codex needs you",
              "message": "Waiting for approval.",
              "createdAt": "2026-08-11T19:10:00Z",
              "isRead": false
            }
            """
        )

        #expect(nativeHarnessAlert.workspaceID == "w3")
        #expect(nativeHarnessAlert.paneID == "w3:p2")
        #expect(nativeHarnessAlert.createdAt == "2026-08-11T19:10:00Z")
        #expect(!nativeHarnessAlert.isRead)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
