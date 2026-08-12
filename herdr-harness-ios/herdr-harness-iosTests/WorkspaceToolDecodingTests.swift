import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Workspace tool contracts")
struct WorkspaceToolDecodingTests {
    @Test("Git status decodes the workspace-scoped backend contract")
    func decodesGitStatus() throws {
        let response = try decode(
            WorkspaceGitStatus.self,
            from: """
            {
              "ok": true,
              "workspace_id": "w1",
              "root_path": "/work/herdr",
              "branch": "codex/pane-polish",
              "staged": [{"status": "M", "file": "PaneSessionView.swift"}],
              "unstaged": [{"status": "M", "file": "server.py"}],
              "untracked": ["WorkspaceSkillsView.swift"],
              "commits": [{"hash": "8d3b96a", "message": "Keep panes live"}]
            }
            """
        )

        #expect(response.workspaceID == "w1")
        #expect(response.cwd == "/work/herdr")
        #expect(response.branch == "codex/pane-polish")
        #expect(response.changeCount == 3)
        #expect(response.untracked == ["WorkspaceSkillsView.swift"])
        #expect(response.commits.first?.hash == "8d3b96a")
    }

    @Test("Skills decode into project and user groups with all insertion styles")
    func decodesSkillsAndBuildsTokens() throws {
        let response = try decode(
            SkillsResponse.self,
            from: """
            {
              "ok": true,
              "workspace_id": "w1",
              "root_path": "/work/herdr",
              "project_skills": [
                {"name": "swiftui-pro", "skill_file_path": "/work/herdr/.claude/skills/swiftui-pro/SKILL.md", "scope": "project"}
              ],
              "user_skills": [
                {"name": "handoff", "skill_file_path": "/Users/me/.claude/skills/handoff/SKILL.md", "scope": "user"}
              ],
              "skills": []
            }
            """
        )

        let project = try #require(response.resolvedProjectSkills.first)
        #expect(response.resolvedUserSkills.first?.name == "handoff")
        #expect(SkillInsertionStyle.claudeCode.token(for: project) == "/swiftui-pro")
        #expect(SkillInsertionStyle.codexCLI.token(for: project) == "$swiftui-pro")
        #expect(SkillInsertionStyle.filePath.token(for: project) == "`/work/herdr/.claude/skills/swiftui-pro/SKILL.md`")
    }

    @Test("File, Jira, and attachment responses preserve snake-case fields")
    func decodesAuxiliaryResponses() throws {
        let files = try decode(
            FileSearchResponse.self,
            from: """
            {"ok":true,"workspace_id":"w1","root_path":"/work/herdr","query":"Pane","files":[{"path":"Views/Pane/PaneSessionView.swift"}],"truncated":false,"limit":25}
            """
        )
        let jira = try decode(
            JiraTicketsResponse.self,
            from: """
            {"ok":true,"site":"https://jira.example","tickets":[{"key":"MOB-1842","project_key":"MOB","title":"Keep the pane live","status":"in progress","priority":"high","issue_type":"Story","url":"https://jira.example/browse/MOB-1842"}]}
            """
        )
        let upload = try decode(
            AttachmentUploadResponse.self,
            from: """
            {"ok":true,"attachment":{"id":"a1","filename":"a1-note.m4a","original_filename":"note.m4a","content_type":"audio/mp4","size":2048,"path":"/tmp/herdr/a1-note.m4a","workspace_id":"w1","created_at":"2026-08-12T14:00:00Z"}}
            """
        )

        #expect(files.files.first?.path == "Views/Pane/PaneSessionView.swift")
        #expect(jira.tickets.first?.projectKey == "MOB")
        #expect(jira.tickets.first?.issueType == "Story")
        #expect(upload.attachment?.originalFilename == "note.m4a")
        #expect(upload.attachment?.workspaceID == "w1")
    }

    @Test("Terminal presets match the cmux two-row command deck")
    func terminalPresetMatrix() {
        #expect(TerminalPresetKey.primaryRow == [.up, .down, .tab, .enter])
        #expect(TerminalPresetKey.secondaryRow == [.left, .right, .escape, .backspace])
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
