/**
 * Display helpers for workspace metadata.
 *
 * Port of the String/Workspace/DetailTab display logic from
 * cmux-harness-ios Views/Shared/SharedViewSupport.swift.
 */

import type { Workspace, WorkspaceAutoMode } from "../api/types";

/** Trim to a non-empty string, or null (Swift `nonEmptyTrimmed`). */
export function nonEmptyTrimmed(value: string | null | undefined): string | null {
  if (value == null) return null;
  const trimmed = value.trim();
  return trimmed === "" ? null : trimmed;
}

/**
 * Last `componentCount` path components (Swift `pathTail`). Returns null when
 * the path has one or fewer components (nothing to abbreviate).
 */
export function pathTail(value: string, componentCount: number): string | null {
  const components = value
    .replace(/\\/g, "/")
    .split("/")
    .map((component) => component.trim())
    .filter((component) => component.length > 0 && component !== "..." && component !== "…");
  if (components.length <= 1) return null;
  const count = Math.max(1, componentCount);
  return components.slice(-count).join("/");
}

/** `.../a/b` style abbreviation (Swift `abbreviatedPath`). */
export function abbreviatedPath(value: string, componentCount: number): string {
  const tail = pathTail(value, componentCount);
  return tail == null ? value : `.../${tail}`;
}

/** Auto mode display label (Swift `WorkspaceAutoMode.label`). */
export function autoModeLabel(mode: WorkspaceAutoMode): string {
  switch (mode) {
    case "off":
      return "Off";
    case "auto":
      return "Auto";
    case "super":
      return "Super Auto";
  }
}

/** h/m/s remaining-duration formatting (Swift `formatRemainingDuration`). */
export function formatRemainingDuration(seconds: number): string {
  const totalSeconds = Math.max(Math.ceil(seconds), 0);
  if (totalSeconds >= 3_600) {
    const hours = Math.floor(totalSeconds / 3_600);
    const minutes = Math.floor((totalSeconds % 3_600) / 60);
    return minutes > 0 ? `${hours}h ${minutes}m` : `${hours}h`;
  }
  if (totalSeconds >= 60) {
    return `${Math.max(1, Math.floor(totalSeconds / 60))}m`;
  }
  return `${totalSeconds}s`;
}

/** "Auto 12m" / "Super Auto expired" (Swift `autoExpirationLabel`). */
export function autoExpirationLabel(expiresAt: number, now: number, mode: WorkspaceAutoMode): string {
  const remaining = expiresAt - now;
  if (remaining <= 0) {
    return `${autoModeLabel(mode)} expired`;
  }
  return `${autoModeLabel(mode)} ${formatRemainingDuration(remaining)}`;
}

/** Cost text color class (Swift `costColor`): red ≥ $5, orange ≥ $2, muted otherwise. */
export function costColorClass(cost: string): string {
  const number = Number(cost.replace("$", ""));
  const value = Number.isFinite(number) ? number : 0;
  if (value >= 5) return "cost-high";
  if (value >= 2) return "cost-medium";
  return "cost-normal";
}

/** "Worktree" value: cwd (4 components) or display name fallback. */
export function worktreeValue(workspace: Workspace, display: string): string {
  const cwd = nonEmptyTrimmed(workspace.cwd);
  if (cwd != null) return abbreviatedPath(cwd, 4);
  return abbreviatedPath(display, 4);
}

/** "Directory" value: cwd (2 components) or display name fallback. */
export function directoryValue(workspace: Workspace, display: string): string {
  const cwd = nonEmptyTrimmed(workspace.cwd);
  if (cwd != null) return abbreviatedPath(cwd, 2);
  return abbreviatedPath(display, 2);
}

/** Branch value: raw branch (2 components) or "No branch". */
export function branchValue(workspace: Workspace): string {
  const branch = nonEmptyTrimmed(workspace.branch);
  return branch == null ? "No branch" : abbreviatedPath(branch, 2);
}
