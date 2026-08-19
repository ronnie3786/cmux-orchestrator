import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError, apiRequest, setDemoRequestHandler } from "../api/client";
import { useAlertsStore } from "../store/alertsStore";
import { useConnectionStore } from "../store/connectionStore";
import { useWorkspacesStore } from "../store/workspacesStore";
import {
  demoEnabled,
  demoRequest,
  disableDemoMode,
  enableDemoMode,
} from "./demoAdapter";

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  fetchMock = vi.fn().mockResolvedValue(
    new Response(JSON.stringify({ ok: true, workspaces: [], alerts: [], generatedAt: "live" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    }),
  );
  vi.stubGlobal("fetch", fetchMock);
  setDemoRequestHandler(demoRequest);
  useConnectionStore.setState({
    status: "Offline",
    streamOpen: false,
    herdr: null,
    herdrEventsConnected: null,
    lastProbeAt: null,
    demo: false,
  });
  useWorkspacesStore.setState({
    data: null,
    lastUpdated: null,
    refreshing: false,
    selectedWorkspaceId: null,
    selectedPaneId: null,
  });
  useAlertsStore.setState({ alerts: [], unreadCount: 0 });
});

afterEach(() => {
  setDemoRequestHandler(null);
  vi.unstubAllGlobals();
});

async function waitSeeded(): Promise<void> {
  await vi.waitFor(() => {
    expect(useWorkspacesStore.getState().data).not.toBeNull();
  });
}

describe("demoRequest (the client.ts fetch seam)", () => {
  it("is keyed on connectionStore.demo: undefined when demo is off", async () => {
    expect(demoEnabled()).toBe(false);
    expect(demoRequest("/workspaces")).toBeUndefined();

    fetchMock.mockClear();
    const live = await apiRequest<{ generatedAt: string }>("/workspaces");
    expect(live.generatedAt).toBe("live");
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("returns the ported DemoData workspaces through the seam while demo is on", async () => {
    useConnectionStore.getState().setDemo(true);
    expect(demoEnabled()).toBe(true);

    fetchMock.mockClear();
    const response = await apiRequest<{
      workspaces: Array<{ label: string; panes: unknown[] }>;
    }>("/workspaces");

    expect(fetchMock).not.toHaveBeenCalled();
    expect(response.workspaces.map((workspace) => workspace.label)).toEqual([
      "iOS Doximity",
      "Member API",
      "Release Train",
    ]);
    expect(response.workspaces[0]?.panes).toHaveLength(3);
    expect(response.workspaces[1]?.panes).toHaveLength(2);
    expect(response.workspaces[2]?.panes).toHaveLength(1);
  });

  it("answers /health, /alerts, mark-read and read-all without the network", async () => {
    useConnectionStore.getState().setDemo(true);
    fetchMock.mockClear();

    const health = await apiRequest<{ herdr: { connected: boolean } }>("/health");
    expect(health.herdr.connected).toBe(true);

    const alerts = await apiRequest<{ alerts: Array<{ id: string }> }>("/alerts");
    expect(alerts.alerts.map((alert) => alert.id)).toEqual(["demo-blocked", "demo-done"]);

    const read = await apiRequest<{ unreadCount: number }>(
      "/alerts/demo-blocked/read",
      { method: "POST" },
    );
    expect(read.unreadCount).toBe(1);

    const readAll = await apiRequest<{ unreadCount: number }>("/alerts/read-all", {
      method: "POST",
    });
    expect(readAll.unreadCount).toBe(0);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("rejects unhandled demo routes with a benign 501 instead of a live 401", async () => {
    useConnectionStore.getState().setDemo(true);
    fetchMock.mockClear();

    const error = await apiRequest("/workspaces/w1/git").catch((caught: unknown) => caught);

    expect(error).toBeInstanceOf(ApiError);
    expect((error as ApiError).status).toBe(501);
    expect((error as ApiError).code).toBe("not_available");
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("serves an empty terminal snapshot and an unavailable Pi snapshot", async () => {
    useConnectionStore.getState().setDemo(true);

    const output = await apiRequest<{ output: { text: string } }>(
      "/panes/w1:p2/output?source=recent_unwrapped&lines=160",
    );
    expect(output.output.text).toBe("");

    const pi = await apiRequest<{ available: boolean }>("/panes/w1:p1/pi/snapshot");
    expect(pi.available).toBe(false);
  });
});

describe("enableDemoMode / disableDemoMode (store seeding)", () => {
  it("pins status to Demo and seeds the same stores through the seam", async () => {
    enableDemoMode();
    expect(useConnectionStore.getState().status).toBe("Demo");
    await waitSeeded();

    const data = useWorkspacesStore.getState();
    expect(data.data?.workspaces).toHaveLength(3);
    // Selection repaired to the first workspace + pane.
    expect(data.selectedWorkspaceId).toBe("w1");
    expect(data.selectedPaneId).toBe("w1:p1");
    expect(data.data?.alerts).toHaveLength(2);

    const alerts = useAlertsStore.getState();
    expect(alerts.alerts).toHaveLength(2);
    expect(alerts.unreadCount).toBe(2);
  });

  it("disabling demo clears the demo state and restores live fetching", async () => {
    enableDemoMode();
    await waitSeeded();

    disableDemoMode();
    expect(useConnectionStore.getState().status).toBe("Offline");
    expect(useWorkspacesStore.getState().data).toBeNull();
    expect(useAlertsStore.getState().alerts).toHaveLength(0);

    fetchMock.mockClear();
    await apiRequest("/workspaces");
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
});
