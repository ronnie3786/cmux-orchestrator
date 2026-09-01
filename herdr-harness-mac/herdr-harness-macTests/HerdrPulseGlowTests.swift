import Testing
@testable import herdr_harness_mac

@Suite("Herdr pulse glow")
struct HerdrPulseGlowTests {
    @Test("Visibility mirrors the inactive opacity branch")
    func visibilityPolicy() {
        #expect(HerdrPulseGlow.isVisible(isActive: true))
        #expect(!HerdrPulseGlow.isVisible(isActive: false))
    }

    @Test("Animation only runs while active and motion is allowed")
    func animationPolicy() {
        #expect(HerdrPulseGlow.animation(isPulsing: true, reduceMotion: false) != nil)
        #expect(HerdrPulseGlow.animation(isPulsing: false, reduceMotion: false) == nil)
        #expect(HerdrPulseGlow.animation(isPulsing: true, reduceMotion: true) == nil)
    }

    @Test("Opacity preserves a resting reduce-motion signal")
    func opacityPolicy() {
        #expect(HerdrPulseGlow.opacity(isActive: false, isPulsing: true, reduceMotion: false) == 0)
        #expect(
            HerdrPulseGlow.opacity(isActive: true, isPulsing: true, reduceMotion: true)
                == HerdrPulseGlow.restOpacity
        )
        #expect(
            HerdrPulseGlow.opacity(isActive: true, isPulsing: false, reduceMotion: false)
                == HerdrPulseGlow.restOpacity
        )
        #expect(
            HerdrPulseGlow.opacity(isActive: true, isPulsing: true, reduceMotion: false)
                == HerdrPulseGlow.peakOpacity
        )
    }

    @Test("Working status keeps its own sidebar hue")
    func workingStatusColor() {
        #expect(SidebarTone.statusColor(for: .working) == AgentStatus.working.color)
        #expect(SidebarTone.statusColor(for: .idle) == SidebarTone.status)
        #expect(SidebarTone.statusColor(for: .unknown) == SidebarTone.status)
    }

    @Test("Tab working counts use machine-scoped tab IDs")
    func workingCountUsesScopedTabID() {
        let workspace = HerdrWorkspace(
            workspaceID: "workspace",
            number: 1,
            label: "Workspace",
            focused: false,
            paneCount: 4,
            tabCount: 2,
            activeTabID: "tab-1",
            agentStatus: .working,
            panes: [
                pane(id: "pane-1", tabID: "tab-1", status: .working),
                pane(id: "pane-2", tabID: "tab-1", status: .working),
                pane(id: "pane-3", tabID: "tab-1", status: .idle),
                pane(id: "pane-4", tabID: "tab-2", status: .working),
            ]
        )
        .stamped(machineID: "work-mac")

        #expect(workspace.workingCount(inTab: "work-mac|tab-1") == 2)
        #expect(workspace.workingCount(inTab: "tab-1") == 0)
    }

    private func pane(id: String, tabID: String, status: AgentStatus) -> HerdrPane {
        HerdrPane(
            paneID: id,
            terminalID: id,
            workspaceID: "workspace",
            tabID: tabID,
            focused: false,
            agentStatus: status,
            revision: 0,
            cwd: nil,
            foregroundCWD: nil,
            label: nil,
            title: nil,
            agent: nil,
            displayAgent: nil,
            terminalTitle: nil,
            terminalTitleStripped: nil
        )
    }
}
