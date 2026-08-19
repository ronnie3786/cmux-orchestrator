/**
 * One tool-invocation card + the ported tool-name → presentation mapping
 * (`PiToolPresentation.swift` — the mapping logic, not the SwiftUI views:
 * symbol names map to lucide-react icons, theme tints to CSS classes).
 */
import { useState } from "react";
import {
  FilePlus,
  FileText,
  Globe,
  Pencil,
  Search,
  Terminal,
  Wrench,
  type LucideIcon,
} from "lucide-react";
import { piDisplayString, piString } from "../../pi/types";
import type { PiJSONValue, PiToolInvocation } from "../../pi/types";

export interface PiToolPresentation {
  title: string;
  subtitle: string | null;
  icon: LucideIcon;
  /** hz-pi-tool-tint-* CSS class (theme color). */
  tint: string;
}

export function piToolPresentation(tool: PiToolInvocation): PiToolPresentation {
  const normalized = tool.name.toLowerCase().replace(/-/g, "_");
  const argument = tool.arguments;
  if (matches(normalized, ["bash", "shell", "exec", "command", "run"])) {
    return {
      title: "Command",
      subtitle: firstString(argument, ["command", "cmd", "script"]),
      icon: Terminal,
      tint: "hz-pi-tool-tint-signal",
    };
  }
  if (matches(normalized, ["read", "open_file"])) {
    return {
      title: "Read",
      subtitle: firstString(argument, ["path", "file", "filename"]),
      icon: FileText,
      tint: "hz-pi-tool-tint-accent",
    };
  }
  if (matches(normalized, ["write", "create_file"])) {
    return {
      title: "Write",
      subtitle: firstString(argument, ["path", "file", "filename"]),
      icon: FilePlus,
      tint: "hz-pi-tool-tint-mauve",
    };
  }
  if (matches(normalized, ["edit", "patch", "apply_patch"])) {
    return {
      title: "Edit",
      subtitle: firstString(argument, ["path", "file", "filename"]),
      icon: Pencil,
      tint: "hz-pi-tool-tint-mauve",
    };
  }
  if (matches(normalized, ["grep", "search", "find", "rg"])) {
    return {
      title: "Search",
      subtitle: firstString(argument, ["query", "pattern", "path"]),
      icon: Search,
      tint: "hz-pi-tool-tint-working",
    };
  }
  if (matches(normalized, ["web", "browser", "fetch", "http"])) {
    return {
      title: "Web",
      subtitle: firstString(argument, ["url", "query"]),
      icon: Globe,
      tint: "hz-pi-tool-tint-accent",
    };
  }
  return {
    title: humanize(tool.name),
    subtitle: null,
    icon: Wrench,
    tint: "hz-pi-tool-tint-mist",
  };
}

function matches(name: string, fragments: string[]): boolean {
  return fragments.some(
    (fragment) =>
      name === fragment || name.includes(`_${fragment}`) || name.includes(`${fragment}_`),
  );
}

/** First non-empty string value among the keys; first line only. */
function firstString(value: PiJSONValue | null, keys: string[]): string | null {
  if (value === null) return null;
  for (const key of keys) {
    const string = piString(value, key);
    if (string !== null && string !== "") {
      return string.split("\n", 1)[0];
    }
  }
  return null;
}

/** Swift `humanize`: underscores/dashes → spaces, capitalize each word's first letter. */
function humanize(name: string): string {
  return name
    .replace(/_/g, " ")
    .replace(/-/g, " ")
    .split(" ")
    .filter((word) => word !== "")
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
    .join(" ");
}

// ---------------------------------------------------------------------------
// Card
// ---------------------------------------------------------------------------

const STATUS_LABEL: Record<PiToolInvocation["status"], string> = {
  waiting: "QUEUED",
  running: "RUNNING",
  succeeded: "DONE",
  failed: "FAILED",
};

/** Relative elapsed: "45s" / "3m" / "2h". */
export function formatElapsed(ms: number): string {
  if (ms < 0) ms = 0;
  const seconds = Math.round(ms / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m`;
  return `${Math.floor(minutes / 60)}h`;
}

export function ToolCard({ tool, now }: { tool: PiToolInvocation; now: number }) {
  const [inputOpen, setInputOpen] = useState(false);
  const [resultOpen, setResultOpen] = useState(false);
  const [errorOpen, setErrorOpen] = useState(true); // ERROR open by default
  const presentation = piToolPresentation(tool);
  const Icon = presentation.icon;

  const hasInput = tool.arguments !== null;
  const hasResult = tool.result !== null;
  const isError = tool.status === "failed";
  const elapsed =
    tool.startedAt !== null ? formatElapsed((tool.finishedAt ?? now) - tool.startedAt) : null;

  return (
    <div
      className={`hz-pi-tool${isError ? " hz-pi-tool-failed" : ""}`}
      data-tool-status={tool.status}
    >
      <header className="hz-pi-tool-head">
        <span className={`hz-pi-tool-icon ${presentation.tint}`}>
          <Icon size={14} aria-hidden />
        </span>
        <span className="hz-pi-tool-title">{presentation.title}</span>
        {presentation.subtitle !== null && (
          <span className="hz-pi-tool-subtitle" title={presentation.subtitle}>
            {presentation.subtitle}
          </span>
        )}
        <span
          className={`hz-pi-tool-status hz-pi-tool-status-${tool.status}${
            tool.status === "running" ? " hz-pi-tool-status-running" : ""
          }`}
        >
          {STATUS_LABEL[tool.status]}
        </span>
        {elapsed !== null && <span className="hz-pi-tool-elapsed">{elapsed}</span>}
      </header>
      {!hasInput && !hasResult ? (
        <p className="hz-pi-tool-waiting">Waiting for tool details…</p>
      ) : (
        <div className="hz-pi-tool-body">
          {hasInput && (
            <Disclosure
              label="INPUT"
              open={inputOpen}
              onToggle={() => setInputOpen((open) => !open)}
            >
              {piDisplayString(tool.arguments)}
            </Disclosure>
          )}
          {hasResult && (
            <Disclosure
              label={isError ? "ERROR" : "RESULT"}
              open={isError ? errorOpen : resultOpen}
              onToggle={() => (isError ? setErrorOpen((open) => !open) : setResultOpen((open) => !open))}
              tone={isError ? "hz-pi-disclosure-error" : undefined}
            >
              {piDisplayString(tool.result)}
            </Disclosure>
          )}
        </div>
      )}
    </div>
  );
}

function Disclosure({
  label,
  open,
  onToggle,
  tone,
  children,
}: {
  label: string;
  open: boolean;
  onToggle: () => void;
  tone?: string;
  children: React.ReactNode;
}) {
  return (
    <section className={`hz-pi-disclosure${open ? " hz-pi-disclosure-open" : ""} ${tone ?? ""}`}>
      <button
        type="button"
        className="hz-pi-disclosure-head"
        onClick={onToggle}
        aria-expanded={open}
      >
        <span className="hz-pi-disclosure-label">{label}</span>
        <span className="hz-pi-disclosure-caret" aria-hidden>
          {open ? "−" : "+"}
        </span>
      </button>
      {open && <pre className="hz-pi-disclosure-body">{children}</pre>}
    </section>
  );
}
