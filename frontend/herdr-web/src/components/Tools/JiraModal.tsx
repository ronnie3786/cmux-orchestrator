import { useCallback, useEffect, useRef, useState } from "react";
import {
  AlertTriangle,
  Check,
  FilePlus2,
  Link as LinkIcon,
  RefreshCw,
  Search,
  Ticket,
} from "lucide-react";
import { jiraAssigned, jiraIssue, type JiraTicket } from "../../api/tools";
import { ToolErrorCard } from "../Shared/ToolErrorCard";
import { useEscapeLayer, useScrollLock } from "../../hooks/useOverlay";
import "./tools.css";

interface JiraModalProps {
  /** Called with the picked ticket (from the lookup result or assigned list). */
  onPick: (ticket: JiraTicket) => void;
  onClose: () => void;
}

interface JiraProjectGroup {
  project: string;
  tickets: JiraTicket[];
}

/**
 * Command Lens "jira" sheet (P9-run-B) — port of the Phase-1 JiraModal
 * re-pointed at GET /api/v1/jira/assigned?limit=50 + GET /api/v1/jira/issue?q
 * (doc 02 §2).
 *
 * Strings byte-exact per doc 01 §6: "JIRA CONTEXT", "EXACT LOOKUP",
 * "LOOKUP RESULT", "Paste a ticket key or browse URL from any project.",
 * "loading assigned tickets", "Jira unavailable", "no assigned tickets",
 * "Use exact lookup for another ticket." (Phase-1 strings where §6 is
 * silent: "Assigned" section header, "Done", the copy toast). The assigned
 * list failure reuses the shared ToolErrorCard chrome (P11-run-B) keeping
 * the byte-exact "Jira unavailable" + "Retry".
 */
export function JiraModal({ onPick, onClose }: JiraModalProps) {
  // Lookup state.
  const [lookupQuery, setLookupQuery] = useState("");
  const [resolvedTicket, setResolvedTicket] = useState<JiraTicket | null>(null);
  const [lookupError, setLookupError] = useState<string | null>(null);
  const [resolving, setResolving] = useState(false);

  // Assigned state.
  const [tickets, setTickets] = useState<JiraTicket[]>([]);
  const [ticketsLoading, setTicketsLoading] = useState(false);
  const [ticketsError, setTicketsError] = useState<string | null>(null);

  // Copy toast (Phase-1 timing: 1.6 s window, restarted on each copy).
  const [copiedKey, setCopiedKey] = useState<string | null>(null);
  const toastTimerRef = useRef<number | null>(null);

  const lookupAbortRef = useRef<AbortController | null>(null);
  const assignedAbortRef = useRef<AbortController | null>(null);

  const loadAssigned = useCallback(() => {
    assignedAbortRef.current?.abort();
    setTicketsLoading(true);
    setTicketsError(null);
    const controller = new AbortController();
    assignedAbortRef.current = controller;
    jiraAssigned(controller.signal)
      .then((response) => {
        setTicketsLoading(false);
        setTicketsError(null);
        setTickets(
          [...(response.tickets ?? [])].sort((a, b) =>
            a.key.localeCompare(b.key, undefined, { sensitivity: "base" }),
          ),
        );
      })
      .catch((err) => {
        if (err instanceof Error && err.message === "Request cancelled") return;
        setTicketsLoading(false);
        setTicketsError(
          err instanceof Error && err.message !== "" ? err.message : "Couldn't load Jira tickets",
        );
      });
  }, []);

  // Load on open; cancel both in-flight tasks + the toast timer on close.
  useEffect(() => {
    loadAssigned();
    return () => {
      assignedAbortRef.current?.abort();
      lookupAbortRef.current?.abort();
      if (toastTimerRef.current !== null) window.clearTimeout(toastTimerRef.current);
    };
  }, [loadAssigned]);

  useEscapeLayer(onClose);
  useScrollLock(true);

  const changeLookupQuery = (value: string) => {
    setLookupQuery(value);
    setResolvedTicket(null);
    setLookupError(null);
  };

  // The raw trimmed query is sent as `q` (the server parses a key or URL).
  const resolveLookup = useCallback(() => {
    const query = lookupQuery.trim();
    if (query === "" || resolving) return;
    setResolving(true);
    setLookupError(null);
    setResolvedTicket(null);
    lookupAbortRef.current?.abort();
    const controller = new AbortController();
    lookupAbortRef.current = controller;
    jiraIssue(query, controller.signal)
      .then((response) => {
        setResolving(false);
        if (response.ticket) {
          setResolvedTicket(response.ticket);
          // The field becomes the resolved key (Phase-1 parity).
          setLookupQuery(response.ticket.key);
        } else {
          setLookupError(response.error ?? "Jira ticket not found");
        }
      })
      .catch((err) => {
        if (err instanceof Error && err.message === "Request cancelled") return;
        setResolving(false);
        setLookupError(err instanceof Error ? err.message : "Couldn't look up the ticket");
      });
  }, [lookupQuery, resolving]);

  const copyTicketKey = (key: string) => {
    void navigator.clipboard?.writeText(key).catch(() => {
      // Clipboard unavailable — the toast still shows (Phase-1 parity).
    });
    setCopiedKey(key);
    if (toastTimerRef.current !== null) window.clearTimeout(toastTimerRef.current);
    toastTimerRef.current = window.setTimeout(() => setCopiedKey(null), 1600);
  };

  const openTicket = (ticket: JiraTicket) => {
    window.open(ticket.url, "_blank", "noopener");
  };

  const groups: JiraProjectGroup[] = (() => {
    const byProject = new Map<string, JiraTicket[]>();
    for (const ticket of tickets) {
      const project = projectKeyFor(ticket);
      const list = byProject.get(project);
      if (list) list.push(ticket);
      else byProject.set(project, [ticket]);
    }
    return Array.from(byProject.entries())
      .map(([project, list]) => ({
        project,
        tickets: list
          .slice()
          .sort((a, b) => a.key.localeCompare(b.key, undefined, { sensitivity: "base" })),
      }))
      .sort((a, b) => a.project.localeCompare(b.project, undefined, { sensitivity: "base" }));
  })();

  return (
    <div className="tools-modal-backdrop" onClick={onClose}>
      <div
        className="tools-modal jira-modal"
        role="dialog"
        aria-label="Jira tickets"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="tools-modal-header">
          <span className="tools-modal-title">JIRA CONTEXT</span>
          <div className="tools-modal-header-actions">
            <button
              type="button"
              className="icon-button"
              title="Refresh Jira tickets"
              aria-label="Refresh Jira tickets"
              disabled={ticketsLoading}
              onClick={loadAssigned}
            >
              <RefreshCw size={14} aria-hidden />
            </button>
            <button type="button" className="diff-sheet-done" onClick={onClose}>
              Done
            </button>
          </div>
        </div>

        {copiedKey !== null ? (
          <div className="jira-copy-toast" role="status">
            <Check size={14} className="jira-copy-toast-icon" aria-hidden />
            <span>Copied {copiedKey}</span>
          </div>
        ) : null}

        <div className="tools-modal-body jira-modal-body">
          <div className="jira-lookup-section">
            <div className="jira-section-header">EXACT LOOKUP</div>
            <div className="jira-lookup-row">
              <input
                className="jira-lookup-input"
                type="text"
                value={lookupQuery}
                placeholder="Paste a ticket key or browse URL from any project."
                autoCapitalize="characters"
                autoCorrect="off"
                spellCheck={false}
                aria-label="Jira key or URL"
                onChange={(event) => changeLookupQuery(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === "Enter") {
                    event.preventDefault();
                    resolveLookup();
                  }
                }}
              />
              <button
                type="button"
                className="jira-lookup-button"
                disabled={lookupQuery.trim() === "" || resolving}
                aria-label="Look up Jira ticket"
                onClick={resolveLookup}
              >
                {resolving ? (
                  <span className="spinner spinner-small" aria-label="Looking up" />
                ) : (
                  <Search size={15} aria-hidden />
                )}
              </button>
            </div>
            {lookupError !== null ? (
              <div className="jira-lookup-error">
                <AlertTriangle size={13} aria-hidden /> {lookupError}
              </div>
            ) : null}
          </div>

          {resolvedTicket !== null ? (
            <div className="jira-section">
              <div className="jira-section-header">LOOKUP RESULT</div>
              <div className="jira-ticket-list">
                <JiraTicketRow
                  ticket={resolvedTicket}
                  onCopy={() => copyTicketKey(resolvedTicket.key)}
                  onOpen={() => openTicket(resolvedTicket)}
                  onInsert={() => onPick(resolvedTicket)}
                />
              </div>
            </div>
          ) : null}

          <div className="jira-section">
            <div className="jira-section-header">Assigned</div>
            {ticketsLoading && tickets.length === 0 ? (
              <div className="tools-modal-spinner-wrap">
                <div className="spinner" aria-label="Loading assigned tickets" />
                <span className="jira-loading-label">loading assigned tickets</span>
              </div>
            ) : ticketsError !== null ? (
              <ToolErrorCard tool="Jira" message={ticketsError} retryLabel="Retry" onRetry={loadAssigned} />
            ) : tickets.length === 0 ? (
              <div className="tools-modal-empty">
                <Ticket size={20} aria-hidden />
                <span>no assigned tickets</span>
                <span className="jira-empty-hint">Use exact lookup for another ticket.</span>
              </div>
            ) : (
              groups.map((group) => (
                <div key={group.project} className="jira-project-group">
                  <div className="jira-project-header">{group.project}</div>
                  <div className="jira-ticket-list">
                    {group.tickets.map((ticket) => (
                      <JiraTicketRow
                        key={ticket.key}
                        ticket={ticket}
                        onCopy={() => copyTicketKey(ticket.key)}
                        onOpen={() => openTicket(ticket)}
                        onInsert={() => onPick(ticket)}
                      />
                    ))}
                  </div>
                </div>
              ))
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

function JiraTicketRow({
  ticket,
  onCopy,
  onOpen,
  onInsert,
}: {
  ticket: JiraTicket;
  onCopy: () => void;
  onOpen: () => void;
  onInsert: () => void;
}) {
  return (
    <div className="jira-ticket-row">
      <div className="jira-ticket-main">
        <button
          type="button"
          className="jira-ticket-key"
          title={`Copy ${ticket.key}`}
          aria-label={`Copy ${ticket.key}`}
          onClick={onCopy}
        >
          {ticket.key}
        </button>
        <div className="jira-ticket-title">{ticket.title}</div>
        <div className="jira-ticket-pills">
          <span className="jira-pill">{ticket.status === "" ? "Unknown" : ticket.status}</span>
          {ticket.priority !== "" ? <span className="jira-pill">{ticket.priority}</span> : null}
        </div>
      </div>
      <div className="jira-ticket-actions">
        <button
          type="button"
          className="jira-ticket-action jira-ticket-action-link"
          title="Open Jira ticket"
          aria-label="Open Jira ticket"
          onClick={onOpen}
        >
          <LinkIcon size={16} aria-hidden />
        </button>
        <button
          type="button"
          className="jira-ticket-action jira-ticket-action-insert"
          title="Insert Jira ticket context"
          aria-label="Insert Jira ticket context"
          onClick={onInsert}
        >
          <FilePlus2 size={16} aria-hidden />
        </button>
      </div>
    </div>
  );
}

function projectKeyFor(ticket: JiraTicket): string {
  const projectKey = (ticket.project_key ?? "").trim();
  if (projectKey !== "") return projectKey;
  const prefix = ticket.key.split("-")[0];
  return prefix === "" ? "Other" : prefix;
}
