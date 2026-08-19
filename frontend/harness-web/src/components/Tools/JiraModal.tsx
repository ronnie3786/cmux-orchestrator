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
import { getJiraAssigned, getJiraIssue } from "../../api/endpoints";
import type { JiraTicket } from "../../api/types";
import { useDraftStore } from "../../store/draftStore";
import { useEscapeLayer, useScrollLock } from "../../hooks/useOverlay";
import { formatJiraTicketPrompt } from "../../lib/jiraPrompt";

interface JiraModalProps {
  /** Switch the detail view to the Terminal tab (iOS `detailTab = .terminal`). */
  onJumpToTerminal: () => void;
  onClose: () => void;
}

interface JiraProjectGroup {
  project: string;
  tickets: JiraTicket[];
}

/**
 * iOS `JiraTicketsView` + `HarnessFeatureToolsReducer` Jira state parity.
 *
 * - Exact Lookup: accepts a ticket key OR a browse URL. The raw trimmed
 *   query is sent as `q` to /api/jira/issue — the server parses it (iOS
 *   `resolveJiraTicket` sends the trimmed query verbatim; the iOS test
 *   `jiraLookupResolvesAnyKeyAndInsertsCompactMetadata` asserts
 *   `query == "https://example.atlassian.net/browse/web-42"` reaches the
 *   client unchanged). On success the field is replaced with the resolved
 *   key (iOS sets `jiraLookupQuery = ticket.key`).
 * - Assigned list: loaded on every open (iOS `.jiraTicketsTapped` always
 *   sends `.loadAssignedJiraTickets`, limit 50, no project filter) and via
 *   the header refresh (iOS toolbar `arrow.clockwise`). No polling — the
 *   server-side Jira cache is what it is; parity is "load on open + manual
 *   refresh".
 * - Rows grouped by project (iOS `projectKey`: `ticket.projectKey` trimmed,
 *   falling back to the key's prefix before "-", else "Other"); tickets and
 *   groups sorted case-insensitively (iOS `localizedCaseInsensitiveCompare`).
 * - Copy key: clipboard + "Copied &lt;KEY&gt;" toast for 1.6 s (iOS
 *   `JiraCopyToast` timing/text; a new copy restarts the window).
 * - Insert: `appendPromptBlock(formatJiraTicketPrompt(ticket))` (EXACT text —
 *   agent-facing), jump to the Terminal tab, focus the input row, and close
 *   the modal with the lookup state reset (iOS `.appendJiraTicketReference`).
 */
export function JiraModal({ onJumpToTerminal, onClose }: JiraModalProps) {
  // Lookup state (iOS jiraLookupQuery / resolvedJiraTicket / jiraLookupError /
  // isResolvingJiraTicket).
  const [lookupQuery, setLookupQuery] = useState("");
  const [resolvedTicket, setResolvedTicket] = useState<JiraTicket | null>(null);
  const [lookupError, setLookupError] = useState<string | null>(null);
  const [resolving, setResolving] = useState(false);

  // Assigned state (iOS jiraTickets / isLoadingJiraTickets / jiraTicketsError).
  const [tickets, setTickets] = useState<JiraTicket[]>([]);
  const [ticketsLoading, setTicketsLoading] = useState(false);
  const [ticketsError, setTicketsError] = useState<string | null>(null);

  // Copy toast (iOS copiedTicketKey + copiedToastID).
  const [copiedKey, setCopiedKey] = useState<string | null>(null);
  const toastTimerRef = useRef<number | null>(null);

  const lookupAbortRef = useRef<AbortController | null>(null);
  const assignedAbortRef = useRef<AbortController | null>(null);

  /** iOS `.loadAssignedJiraTickets` (limit 50, no project filter). */
  const loadAssigned = useCallback(() => {
    assignedAbortRef.current?.abort();
    setTicketsLoading(true);
    setTicketsError(null);
    const controller = new AbortController();
    assignedAbortRef.current = controller;
    getJiraAssigned(50, undefined, controller.signal)
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
        setTicketsError(err instanceof Error ? err.message : "Couldn't load assigned tickets");
      });
  }, []);

  // iOS `.task { if jiraTickets.isEmpty && !isLoadingJiraTickets { load } }`
  // + `.jiraTicketsTapped` always sends the load — the modal loads on open.
  useEffect(() => {
    loadAssigned();
    return () => {
      // iOS `.dismissJiraTickets` cancels both in-flight tasks.
      assignedAbortRef.current?.abort();
      lookupAbortRef.current?.abort();
      if (toastTimerRef.current !== null) window.clearTimeout(toastTimerRef.current);
    };
  }, [loadAssigned]);

  // Close on Escape (web idiom; iOS uses the Done button) — top-most layer only.
  useEscapeLayer(onClose);
  useScrollLock(true);

  // iOS `.jiraLookupQueryChanged`: any edit clears the resolved ticket + error.
  const changeLookupQuery = (value: string) => {
    setLookupQuery(value);
    setResolvedTicket(null);
    setLookupError(null);
  };

  // iOS `.resolveJiraTicket`: trimmed raw query as `q` (server parses key or
  // browse URL).
  const resolveLookup = useCallback(() => {
    const query = lookupQuery.trim();
    if (query === "") return;
    if (resolving) return;
    setResolving(true);
    setLookupError(null);
    setResolvedTicket(null);
    lookupAbortRef.current?.abort();
    const controller = new AbortController();
    lookupAbortRef.current = controller;
    getJiraIssue(query, controller.signal)
      .then((response) => {
        setResolving(false);
        if (response.ticket) {
          setResolvedTicket(response.ticket);
          // iOS: the field becomes the resolved key.
          setLookupQuery(response.ticket.key);
          setLookupError(null);
        } else {
          setResolvedTicket(null);
          setLookupError(response.error ?? "Jira ticket not found");
        }
      })
      .catch((err) => {
        if (err instanceof Error && err.message === "Request cancelled") return;
        setResolving(false);
        setResolvedTicket(null);
        setLookupError(err instanceof Error ? err.message : "Couldn't look up the ticket");
      });
  }, [lookupQuery, resolving]);

  // iOS `copyTicketKey`: clipboard + toast; a newer copy restarts the 1.6 s
  // window (iOS guards with copiedToastID).
  const copyTicketKey = (key: string) => {
    void navigator.clipboard?.writeText(key).catch(() => {
      // Clipboard unavailable (permissions) — the toast still matches iOS's
      // unconditional show; parity over perfect feedback.
    });
    setCopiedKey(key);
    if (toastTimerRef.current !== null) window.clearTimeout(toastTimerRef.current);
    toastTimerRef.current = window.setTimeout(() => setCopiedKey(null), 1600);
  };

  // iOS `.appendJiraTicketReference`: exact prompt block + terminal + focus +
  // close (the unmount discards the lookup state — iOS resets it explicitly).
  const insertTicket = (ticket: JiraTicket) => {
    useDraftStore.getState().appendBlock(formatJiraTicketPrompt(ticket));
    useDraftStore.getState().requestFocus();
    onJumpToTerminal();
    onClose();
  };

  const openTicket = (ticket: JiraTicket) => {
    window.open(ticket.url, "_blank", "noopener");
  };

  // iOS `groupedAssignedTickets`: group by project, sort both sides.
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
          <span className="tools-modal-title">Jira</span>
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
          {/* Exact Lookup (iOS section header "Exact Lookup" + footer) */}
          <div className="jira-lookup-section">
            <div className="jira-section-header">Exact Lookup</div>
            <div className="jira-lookup-row">
              <input
                className="jira-lookup-input"
                type="text"
                value={lookupQuery}
                placeholder="Jira key or URL"
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
            <div className="jira-section-footer">Paste a Jira key or browse URL from any project.</div>
            {lookupError !== null ? (
              <div className="jira-lookup-error">
                <AlertTriangle size={13} aria-hidden /> {lookupError}
              </div>
            ) : null}
          </div>

          {/* Lookup Result (iOS section "Lookup Result") */}
          {resolvedTicket !== null ? (
            <div className="jira-section">
              <div className="jira-section-header">Lookup Result</div>
              <div className="jira-ticket-list">
                <JiraTicketRow
                  ticket={resolvedTicket}
                  onCopy={() => copyTicketKey(resolvedTicket.key)}
                  onOpen={() => openTicket(resolvedTicket)}
                  onInsert={() => insertTicket(resolvedTicket)}
                />
              </div>
            </div>
          ) : null}

          {/* Assigned (iOS `assignedTicketsContent`) */}
          <div className="jira-section">
            <div className="jira-section-header">Assigned</div>
            {ticketsLoading && tickets.length === 0 ? (
              <div className="tools-modal-spinner-wrap">
                <div className="spinner" aria-label="Loading assigned tickets" />
              </div>
            ) : ticketsError !== null ? (
              <div className="git-error">
                <span className="git-error-text">
                  <AlertTriangle size={13} aria-hidden /> {ticketsError}
                </span>
                <button type="button" className="git-error-retry" onClick={loadAssigned}>
                  Retry
                </button>
              </div>
            ) : tickets.length === 0 ? (
              <div className="tools-modal-empty">
                <Ticket size={20} aria-hidden />
                <span>No Assigned Tickets</span>
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
                        onInsert={() => insertTicket(ticket)}
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

/**
 * iOS `JiraTicketRow`: monospaced bold key (tap = copy), title (3-line
 * clamp), status pill (always; "Unknown" when empty) + priority pill (only
 * when non-empty), link button (opens the Jira URL), green insert button.
 */
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

/**
 * iOS `projectKey(for:)`: trimmed `ticket.projectKey`, falling back to the
 * key's prefix before "-", else "Other".
 */
function projectKeyFor(ticket: JiraTicket): string {
  const projectKey = (ticket.projectKey ?? "").trim();
  if (projectKey !== "") return projectKey;
  const prefix = ticket.key.split("-")[0];
  return prefix === "" ? "Other" : prefix;
}
