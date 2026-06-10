# API Discovery

The Cmux harness exposes a machine-readable API discovery endpoint for coding agents and tools that need to learn what the local harness can do at runtime.

## Endpoints

```http
GET /api/discovery
GET /api/help
```

`/api/help` is an alias for `/api/discovery`.

The unfiltered response returns the full supported API catalog, including regular HTTP endpoints and Orchestrator V2 agent tools.

## Query Filters

Use filters to narrow the catalog:

| Query | Purpose | Example |
|---|---|---|
| `method` | Filter by HTTP method | `/api/discovery?method=POST` |
| `category` | Filter by category | `/api/discovery?category=PR%20Reviews` |
| `q` | Search path, summary, category, safety, and related tools | `/api/discovery?q=pr-reviews` |
| `prefix` | Filter by path prefix | `/api/discovery?prefix=/api/orchestrator-v2/pr-reviews` |

Filters can be combined:

```sh
curl 'http://localhost:9091/api/discovery?method=POST&q=pr-reviews'
```

## Response Shape

The response is JSON:

```json
{
  "ok": true,
  "name": "cmux-harness API discovery",
  "description": "Machine-readable help for harness HTTP endpoints and Orchestrator V2 agent tools.",
  "catalogVersion": 1,
  "discoveryEndpoints": [
    "GET /api/discovery",
    "GET /api/help"
  ],
  "filters": {
    "method": "",
    "category": "",
    "q": "",
    "prefix": ""
  },
  "categories": ["Discovery", "PR Reviews", "Orchestrator V2"],
  "endpointCount": 185,
  "totalEndpointCount": 185,
  "endpoints": [],
  "agentToolCount": 39,
  "agentTools": []
}
```

`endpointCount` is the number of endpoints after filters are applied. `totalEndpointCount` is the full catalog size.

## Endpoint Entries

Each item in `endpoints` describes one HTTP endpoint:

```json
{
  "id": "POST /api/orchestrator-v2/pr-reviews/start",
  "method": "POST",
  "path": "/api/orchestrator-v2/pr-reviews/start",
  "summary": "Start a remote PR code review in a new cmux workspace and create/link an Orchestrator V2 task.",
  "category": "PR Reviews",
  "safety": "terminal_write",
  "parameters": [
    {
      "name": "number",
      "in": "body",
      "type": "integer",
      "required": true,
      "description": "Pull request number to review."
    }
  ],
  "request": {
    "contentType": "application/json",
    "required": ["number"],
    "optional": ["repo", "projectDir", "reviewCli", "pullRequest", "taskId", "title", "priority", "tags"],
    "example": {
      "repo": "doximity/iOS-Doximity",
      "number": 11244,
      "reviewCli": "codex"
    }
  },
  "relatedTools": ["start_pr_review"]
}
```

## Agent Tools

`agentTools` describes callable Orchestrator V2 tools. These tools are invoked through:

```http
POST /api/orchestrator-v2/agent/tools/{toolName}
```

Example:

```json
{
  "runId": "optional-run-id",
  "args": {
    "repo": "doximity/iOS-Doximity",
    "number": 11244,
    "reviewCli": "codex"
  }
}
```

A discovered tool entry includes its status, kind, approval requirement, invocation path, and argument example.

## PR Review Discovery

To discover the PR review API:

```sh
curl 'http://localhost:9091/api/discovery?q=pr-reviews'
```

Useful returned endpoints:

```http
GET /api/orchestrator-v2/pr-reviews/review-requests
POST /api/orchestrator-v2/pr-reviews/start
```

Useful returned tools:

```text
list_pr_review_requests
start_pr_review
```

A coding agent can use this flow:

1. Call `GET /api/discovery?q=pr-reviews`.
2. Read the `request.required`, `request.optional`, and `request.example` fields.
3. Call `GET /api/orchestrator-v2/pr-reviews/review-requests?repo=doximity/iOS-Doximity`.
4. Call `POST /api/orchestrator-v2/pr-reviews/start` with the selected PR number.

## Safety Field

Every endpoint includes a `safety` value to help agents decide whether the call is read-only or mutating.

Common values:

| Safety | Meaning |
|---|---|
| `read` | Read-only local/API data. |
| `local_write` | Writes local harness state. |
| `terminal_write` | Creates sessions or sends terminal input. |
| `git_write` | Mutates git index/state. |
| `file_read` | Reads local files. |
| `file_write` | Writes local files. |
| `native_ui` | Opens native macOS UI or apps. |
| `external_read` | Reads external systems like Jira/GitHub. |
| `external_write` | Writes to external systems. |
| `tool_dependent` | Safety depends on the selected agent tool. |

Agents should prefer read-only discovery first, then inspect `safety`, `parameters`, and `request` before invoking mutating endpoints.
