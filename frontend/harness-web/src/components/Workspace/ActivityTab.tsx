/**
 * Activity tab — port of ActivityListView from
 * cmux-harness-ios/Views/Tools/ActivitySkillsFileSearchViews.swift.
 *
 * Data: the /api/log entries from the 2 s global tick (workspacesStore),
 * filtered to the selected session's workspace index (iOS parity —
 * WorkspaceDetailView.activityEntries; iOS keeps the server's newest-first
 * order).
 */

import { Activity } from "lucide-react";
import type { LogEntry, Workspace } from "../../api/types";
import { useWorkspacesStore } from "../../store/workspacesStore";

/** Port of SharedViewSupport.formatTimestamp (strict ISO8601, else raw). */
const ISO8601 = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/;

function formatTimestamp(value: string): string {
  if (!ISO8601.test(value)) return value;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
}

function ActivityRow({ entry }: { entry: LogEntry }) {
  return (
    <div className="activity-row">
      <div className="activity-row-top">
        <span className="activity-action">{entry.action ?? "Activity"}</span>
        {entry.timestamp && <span className="activity-timestamp">{formatTimestamp(entry.timestamp)}</span>}
      </div>
      {entry.promptType ? <div className="activity-prompt-type">{entry.promptType}</div> : null}
      {entry.reason ? <div className="activity-reason">{entry.reason}</div> : null}
    </div>
  );
}

export function ActivityTab({ workspace }: { workspace: Workspace }) {
  const logEntries = useWorkspacesStore((state) => state.logEntries);
  const entries = logEntries.filter((entry) => entry.workspace === workspace.index);

  if (entries.length === 0) {
    return (
      <div className="activity-empty">
        <Activity size={20} aria-hidden />
        <span>No Activity</span>
      </div>
    );
  }

  return (
    <div className="activity-list">
      {entries.map((entry, index) => (
        <ActivityRow key={`${entry.timestamp ?? ""}-${entry.action ?? ""}-${index}`} entry={entry} />
      ))}
    </div>
  );
}
