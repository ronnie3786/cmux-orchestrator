# Herdr Guided Code Review

*Working product and architecture specification, 2026-08-25.*

## Vision

Herdr should make a code review feel like a guided investigation, not a wall of patches. The first step is a fast, familiar Git workbench: repository state and files on the left, a full-height code diff on the right, and clear navigation among local changes and commits. From that foundation, Herdr can become an AI review companion that builds a mental model of a change, points out the parts that deserve attention, explains them in text or audio, and answers questions about the exact code currently on screen.

The long-term experience is a tour guide for a pull request:

1. Load a local change or paste a pull request URL.
2. Let AI analyze the change, summarize its intent, and identify likely risks.
3. Review a numbered path through the most important files and hunks.
4. Play a short explanation at any tour stop, with the relevant lines highlighted.
5. Ask a live voice question while reading, with the current file, visible lines, selection, diff, and review findings already in context.
6. Optionally start autoplay so Herdr advances through the tour, scrolls to each anchor, highlights the code being discussed, and narrates the explanation.

The UI must remain useful without AI, voice, network access, or a hosted pull request. Every advanced feature is layered onto a strong local Git diff experience.

## Product principles

1. **Code first.** The diff is the primary surface. AI, metadata, and controls support it without shrinking it into a secondary panel.
2. **Familiar before novel.** Start with conventions from established Git review tools: file rail, status groups, commit navigation, split and unified diffs, line selection, and inline annotations.
3. **Herdr owns the experience.** Herdr controls the shell, data model, context assembly, AI prompts, voice lifecycle, styling, and feature flags so the product can evolve independently.
4. **Guidance is reversible.** Relevance filtering may collapse or de-emphasize low-priority changes, but it must never make them unavailable. One action always reveals the complete diff.
5. **AI is evidence-linked.** Every finding, explanation, and tour stop points to concrete file and line anchors. Unsupported general commentary should not appear as a code finding.
6. **The viewport is context.** The app must know what the reviewer is looking at and make that state available to explicit AI and voice actions.
7. **Local first.** Local diffs work without a remote provider. Repository content leaves the machine only through an explicitly configured and visible AI workflow.
8. **Progressive capability.** Text review, guided tours, pre-generated audio, live voice, and autoplay share the same underlying context and anchors rather than becoming separate implementations.

## Scope and terminology

- **Review:** A versioned set of changes with a base and head. It may come from the working tree, a branch or commit range, or a hosted pull request.
- **File rail:** The left-side navigator for status groups, files, and commits.
- **Diff canvas:** The main code review surface.
- **Finding:** An AI- or human-authored observation about a specific part of the change.
- **Tour stop:** A numbered, ordered explanation anchored to one or more ranges in the diff.
- **Review context:** The bounded, versioned payload that describes the review and what the user is currently viewing.
- **Focus mode:** An optional presentation that emphasizes relevant files and hunks while retaining an obvious path to all changes.

## Architecture decision

### Decision

Build a Herdr-owned React review surface and use [`@pierre/diffs`](https://diffs.com/docs) as the diff rendering engine. Follow and adapt interaction patterns demonstrated by [Plannotator](https://github.com/backnotprop/plannotator), but do not embed or iframe the complete Plannotator application in the first implementation.

### Why

Plannotator's review product is a useful design and feature reference, including Git status grouping, commit navigation, syntax-aware diffs, annotations, and guided review. Its complete review application is organized as a coupled monorepo workspace rather than a small drop-in component. Embedding the whole application would also introduce a second server, routing model, state store, permissions boundary, visual system, and context model inside Herdr.

`@pierre/diffs` is the public renderer that underpins Plannotator's diff canvas. Using it directly provides a capable and customizable rendering foundation while leaving Herdr free to own:

- local and remote review sources
- stage and unstage actions
- file and commit navigation
- line selection and annotation behavior
- AI findings and guided review
- review-context assembly
- microphone and audio state
- autoplay, scrolling, and highlighting
- theming, accessibility, and Mac WebKit integration

This is an integration with the same diff foundation and an intentional adaptation of the useful product patterns, not a fork of the complete Plannotator application.

### Revisit conditions

Reconsider importing or forking a larger Plannotator package only if all of these are true:

- it exposes a stable package boundary that does not require its server and application shell
- the imported functionality would remove substantial maintained Herdr code
- its state and line-anchor models can map cleanly to `ReviewContext`
- styling, keyboard behavior, privacy, and future voice hooks remain under Herdr control

Any copied source must retain the license notices required by the upstream MIT or Apache-2.0 license. The Phase 0 renderer dependency is `@pierre/diffs` 1.3.2, licensed Apache-2.0. It must remain pinned in the package lock. The web release build copies the tracked `public/third-party-licenses/pierre-diffs-LICENSE.md` and `public/THIRD_PARTY_NOTICES.md` files beside the served assets. If the web bundle later ships inside the app, both files must also be copied into the app resources.

## Target experience

### Review workbench layout

The desktop layout has two primary regions:

```text
+-----------------------------+------------------------------------------------+
| Repository / branch         | Active file                       Unified Split |
| Working changes             | path/to/File.swift                Review state  |
|                             +------------------------------------------------+
| Staged                      |                                                |
|   FileA.swift               |                                                |
| Unstaged                    |            syntax-highlighted diff             |
|   FileB.swift               |                                                |
| Untracked                   |                                                |
|   NewFile.swift             |                                                |
|                             |                                                |
| Recent commits              |                                                |
| independently scrollable    |             independently scrollable           |
+-----------------------------+------------------------------------------------+
```

The left rail remains visible at normal desktop widths. It can switch among status, tree, and commits as capabilities are added. The diff canvas consumes the remaining width and starts expanded, without opening a duplicate modal or sheet.

At narrow widths, the file rail may become a drawer, but opening a file always returns focus to the diff canvas. The review header reports the repository, base and head refs, and dirty state without competing with the code.

### Navigation behavior

- Selecting the Git view enters review mode.
- Selecting the active Git view again exits to chat, matching a deselectable mode control.
- Selecting a file updates the same persistent diff canvas.
- Working changes and recent commits share one independently scrollable rail in the first slice. Dedicated status, tree, and commits modes may replace that arrangement when the rail gains enough depth to justify them.
- File and diff regions scroll independently.
- The selected file, display mode, and rail mode survive ordinary refreshes for the same review.
- Keyboard navigation covers next or previous file, next or previous finding, next or previous tour stop, split or unified mode, reveal all, and return to chat.

## System architecture

```text
Mac app shell
  `- Herdr review web view
       |- React review shell
       |    |- review source store
       |    |- file / commit rail
       |    |- @pierre/diffs canvas
       |    |- annotation and tour overlays
       |    `- ReviewContext assembler
       |
       |- Herdr API
       |    |- local Git provider
       |    |- hosted PR provider
       |    |- review persistence
       |    `- AI review broker
       |
       `- Voice services
            |- speech-to-text session
            |- question / answer agent
            |- text-to-speech clips
            `- tour playback coordinator
```

### Frontend boundaries

The review UI should depend on narrow interfaces instead of provider-specific data:

```ts
interface ReviewSourceProvider {
  open(input: ReviewSourceInput): Promise<ReviewSnapshot>
  refresh(reviewId: string): Promise<ReviewSnapshot>
  loadFileDiff(reviewId: string, comparisonId: string, path: string): Promise<FilePatch>
  loadComparisonDiff(reviewId: string, comparisonId: string, path?: string): Promise<FilePatch[]>
}

interface DiffRendererAdapter {
  renderFile(patch: FilePatch, options: DiffDisplayOptions): React.ReactNode
  scrollTo(anchor: CodeAnchor, behavior: ScrollBehavior): Promise<void>
  highlight(anchors: CodeAnchor[], style: HighlightStyle): void
  clearHighlights(owner: string): void
  getVisibleRanges(): VisibleCodeRange[]
  getSelection(): CodeSelection | null
}

interface ReviewAnalyzer {
  analyze(context: ReviewContextV1): AsyncIterable<ReviewAnalysisEvent>
  answer(question: string, context: ReviewContextV1): AsyncIterable<ReviewAnswerEvent>
}

interface TourPlaybackCoordinator {
  play(stopId: string): Promise<void>
  pause(): void
  resume(): void
  next(): Promise<void>
  stop(): void
}
```

The first `DiffRendererAdapter` implementation wraps `@pierre/diffs`. Components outside the adapter should not depend on renderer-specific DOM or private classes. This keeps line navigation and overlays testable and permits a future renderer change without replacing the review model.

### Backend boundaries

1. **Local Git provider:** Reads repository status, branches, commits, file patches, and binary metadata. Performs stage and unstage actions through existing Herdr API controls.
2. **Hosted PR provider:** Resolves a supported PR URL, authenticates on the backend, fetches metadata and patches, and returns the common `ReviewSnapshot` model.
3. **Review persistence:** Stores user state, annotations, findings, viewed state, tour order, and cached analysis by review revision.
4. **AI broker:** Builds bounded prompts from `ReviewContext`, invokes the configured model, validates structured results, and streams progress.
5. **Voice broker:** Owns microphone transcription requests, question answering, narration generation, and audio clip caching. Provider details remain outside the web view.

## Core data model

### Review snapshot

```ts
type ReviewSource =
  | { kind: "working-tree"; repositoryId: string }
  | { kind: "revision-range"; repositoryId: string; baseRef: string; headRef: string }
  | { kind: "pull-request"; provider: "github"; owner: string; repository: string; number: number };

interface ReviewSnapshot {
  schemaVersion: 1
  reviewId: string
  revision: string
  source: ReviewSource
  repository: {
    id: string
    displayName: string
    root?: string
    remoteUrl?: string
  }
  refs: {
    baseRef?: string
    baseSha?: string
    headRef?: string
    headSha?: string
    mergeBaseSha?: string
  }
  pullRequest?: {
    url: string
    title: string
    author: string
    state: "open" | "closed" | "merged" | "draft"
    body?: string
  }
  comparisons: ReviewComparison[]
  files: ReviewFile[]
  commits: ReviewCommit[]
  capabilities: ReviewCapabilities
  generatedAt: string
}

interface ReviewFile {
  path: string
  changes: ReviewFileChange[]
}

interface ReviewFileChange {
  comparisonId: string
  previousPath?: string
  status: "added" | "modified" | "deleted" | "renamed" | "copied" | "untracked" | "binary"
  workingTreeGroup?: "staged" | "unstaged" | "untracked"
  additions?: number
  deletions?: number
  isBinary: boolean
  patchRevision: string
}

interface ReviewComparison {
  id: string
  kind: "head-to-index" | "index-to-worktree" | "empty-to-worktree" | "commit-parent" | "revision-range" | "pull-request"
  revision: string
  baseRef?: string
  baseSha?: string
  headRef?: string
  headSha?: string
  commitId?: string
}

interface FilePatch {
  comparisonId: string
  patchRevision: string
  path: string
  previousPath?: string
  patch: string
  truncated: boolean
  isBinary: boolean
}
```

`revision` changes whenever the review content changes. AI output and line anchors record the revision they were generated against so stale output can be identified rather than silently shown against different code.

Working-tree reviews expose separate comparisons for staged changes (`HEAD` to index), unstaged changes (index to worktree), and untracked files (empty to worktree). A path may belong to more than one comparison. Hosted pull requests and revision ranges expose their exact base and head comparison, while each per-commit view has its own commit-to-parent comparison. Every returned `FilePatch` carries the identity and revision that a `CodeAnchor` must use.

### Code anchors

All explanations, findings, selections, tour stops, and playback cues use one anchor type:

```ts
interface CodeAnchor {
  comparisonId: string
  patchRevision: string
  path: string
  previousPath?: string
  side: "base" | "head"
  startLine: number
  endLine: number
  hunkFingerprint?: string
  contentHash?: string
}
```

Line numbers are one-based and inclusive. `comparisonId` identifies the exact comparison being viewed, such as working tree, combined pull request, or one commit against its parent. `patchRevision` identifies the file patch within that comparison. Both are mandatory because the same path and line can refer to different content in per-commit and combined views. `side` is mandatory because the same number may represent different content on each side of a split diff. `hunkFingerprint` and `contentHash` help remap an anchor after a refresh or between compatible comparisons. If remapping is ambiguous, Herdr marks the annotation stale and asks the user to reveal the original comparison and revision. It must not guess silently.

### Review findings

```ts
interface ReviewFinding {
  schemaVersion: 1
  id: string
  reviewId: string
  reviewRevision: string
  author: "ai" | "human"
  severity: "critical" | "high" | "medium" | "low" | "note"
  confidence?: number
  title: string
  explanation: string
  impact?: string
  recommendation?: string
  anchors: CodeAnchor[]
  status: "open" | "accepted" | "dismissed" | "stale"
  createdAt: string
}
```

AI findings are suggestions, not authoritative defects. The UI shows confidence and evidence, supports dismissal, and never converts a finding into a repository mutation without a separate explicit action.

### Guided tour

```ts
interface ReviewTour {
  schemaVersion: 1
  id: string
  reviewId: string
  reviewRevision: string
  title: string
  overview: string
  stopIds: string[]
  generatedAt: string
}

interface ReviewTourStop {
  schemaVersion: 1
  id: string
  tourId: string
  reviewId: string
  reviewRevision: string
  order: number
  kind: "architecture" | "behavior" | "risk" | "finding" | "test" | "context"
  importance: "critical" | "high" | "normal"
  title: string
  summary: string
  narrationText: string
  anchors: CodeAnchor[]
  relatedFindingIds: string[]
  audio?: {
    clipId: string
    durationMs: number
    transcript: string
    cues: HighlightCue[]
  }
}

interface HighlightCue {
  startMs: number
  endMs: number
  anchors: CodeAnchor[]
  emphasis: "primary" | "supporting"
}
```

The number shown in the UI is derived from `order`, not embedded in narration. Reordering a tour therefore does not require regenerating audio unless the narration refers to a specific number.

## ReviewContext contract

`ReviewContextV1` is the common input for text questions, live voice questions, review analysis, tour generation, and narration. It deliberately separates review identity, UI state, bounded code evidence, and prior analysis.

```ts
interface ReviewContextV1 {
  schemaVersion: 1
  capturedAt: string
  requestId: string

  review: {
    reviewId: string
    revision: string
    sourceKind: "working-tree" | "revision-range" | "pull-request"
    repositoryId: string
    repositoryName: string
    baseRef?: string
    baseSha?: string
    headRef?: string
    headSha?: string
    pullRequest?: {
      url: string
      number: number
      title: string
      bodyExcerpt?: string
    }
  }

  view: {
    activePath?: string
    displayMode: "unified" | "split"
    railMode: "status" | "tree" | "commits"
    activeCommitId?: string
    visibleRanges: VisibleCodeRange[]
    selection?: CodeSelection
    activeFindingId?: string
    activeTourStopId?: string
    focusMode: boolean
  }

  evidence: {
    activeFile?: ContextFile
    selectedExcerpts: ContextExcerpt[]
    visibleExcerpts: ContextExcerpt[]
    relatedExcerpts: ContextExcerpt[]
    fileOutline: ContextFileSummary[]
    omitted: {
      fileCount: number
      lineCount: number
      reasons: ("budget" | "binary" | "low-relevance" | "unavailable")[]
    }
  }

  analysis: {
    summary?: string
    findingIds: string[]
    tourStopIds: string[]
    userNotes: string[]
  }

  permissions: {
    maySendCodeToConfiguredAI: boolean
    mayReadAdditionalFiles: boolean
    mayRunRepositoryCommands: boolean
    mayMutateRepository: false
  }
}

interface VisibleCodeRange extends CodeAnchor {
  visibilityRatio: number
}

interface CodeSelection {
  anchors: CodeAnchor[]
  selectedText?: string
}

interface ContextFile {
  comparisonId: string
  patchRevision: string
  path: string
  status: ReviewFileChange["status"]
  patch: string
  language?: string
}

interface ContextExcerpt {
  anchor: CodeAnchor
  text: string
  source: "patch" | "base-file" | "head-file"
  purpose: "selected" | "visible" | "dependency" | "finding" | "tour"
}

interface ContextFileSummary {
  path: string
  changes: ContextFileChangeSummary[]
  relevance?: number
  symbols?: string[]
}

interface ContextFileChangeSummary {
  comparisonId: string
  patchRevision: string
  status: ReviewFileChange["status"]
  additions?: number
  deletions?: number
}
```

### Assembly rules

Context is assembled at the moment the user asks a question or starts an analysis. It is not a continuously transmitted stream.

1. Selected lines have highest priority.
2. Visible changed lines and their surrounding function or type context come next.
3. The active file patch and findings related to it come next.
4. Related definitions, callers, tests, and tour anchors may be included within the request budget.
5. A file outline represents the rest of the review without sending every patch.
6. The payload reports omissions explicitly so the model can state when it lacks evidence.
7. Raw credentials, environment files, ignored secrets, and repository paths outside the review root are excluded.
8. The payload is immutable for the lifetime of one answer. If the review changes mid-answer, the response is labeled with its original revision.

The active viewport should be sampled after scrolling settles and before request dispatch. Live voice follow-up questions capture a fresh `ReviewContext` for each utterance, while retaining the conversation's review identity and cited findings.

## Proposed API surface

Existing local Git endpoints should be preserved and expanded behind the common review model.

```text
POST /api/v1/reviews/open
  { source: ReviewSourceInput }
  -> ReviewSnapshot

GET /api/v1/reviews/{reviewId}
  -> ReviewSnapshot

GET /api/v1/reviews/{reviewId}/files/{encodedPath}/diff
  ?comparison=<required>&context=<optional>
  -> FilePatch

POST /api/v1/reviews/{reviewId}/analyze
  { context: ReviewContextV1, options }
  -> streamed ReviewAnalysisEvent

POST /api/v1/reviews/{reviewId}/questions
  { question, context: ReviewContextV1, conversationId? }
  -> streamed ReviewAnswerEvent

POST /api/v1/reviews/{reviewId}/tour
  { analysisRevision, preferences }
  -> ReviewTour

POST /api/v1/reviews/{reviewId}/tour-stops/{stopId}/audio
  { voice, speed }
  -> audio metadata and stream URL

POST /api/v1/reviews/{reviewId}/voice/sessions
  { context: ReviewContextV1 }
  -> explicit, short-lived voice session
```

The first slice can continue to use the current pane Git status and diff routes. These review routes describe the convergence target and should be introduced incrementally rather than through a disruptive rewrite.

## Phased roadmap

### Phase 0: Review canvas foundation

Goal: Replace the custom patch presentation with a traditional, durable review surface.

- use `@pierre/diffs` through `DiffRendererAdapter`
- persistent file rail and full-height diff canvas
- staged, unstaged, and untracked groups
- working changes with recent commits below them in the same scrollable rail
- independent scrolling for rail and diff
- split and unified display controls
- syntax highlighting and correct old or new line gutters
- resilient states for loading, empty, binary, large, and malformed diffs
- preserve stage and unstage controls
- expose the active file and display mode to a local review UI store shaped for later `ReviewContext` assembly
- no modal or duplicate diff view

### Phase 1: Complete local review workflow

Goal: Make local changes reviewable from start to finish without leaving Herdr.

- all-files and selected-file modes
- next or previous changed file and hunk
- viewed state per file
- line selection and human annotations
- status, tree, and commits rail modes
- per-commit and combined diffs
- refresh and stale-anchor handling
- search by file path and changed content
- keyboard shortcut help
- optional focus mode with a persistent `Show all changes` action

### Phase 2: Pull request URL loading

Goal: Paste a GitHub pull request URL and open it as the same review experience.

- validate and parse supported GitHub URLs
- authenticate through a backend provider, never through browser-held tokens
- load title, description, author, refs, commits, files, and patch data
- indicate whether the review is remote-only or matched to a local checkout
- show provider comments and checks as optional layers
- cache by provider, repository, pull request number, base or merge-base SHA, and head SHA
- derive the review revision from both sides of the comparison and refresh when either side changes
- retain a provider abstraction for later GitLab or other sources

The initial implementation should prefer fetching diff data without executing or building pull request code. Checking out a remote branch is a separate, explicit user action.

### Phase 3: AI pre-review and explanations

Goal: Help the reviewer understand the change before and during manual review.

- review summary: intent, architecture, behavior changes, test coverage, and risk areas
- structured findings with severity, confidence, impact, recommendation, and line anchors
- `Explain this change` for a file, hunk, selection, or finding
- inline findings rendered through the same annotation layer as human notes
- analysis progress and cancellation
- provenance showing model, review revision, and cited anchors
- accept, dismiss, and stale states
- no automatic posting to GitHub or repository mutation

### Phase 4: Numbered guided review and audio clips

Goal: Turn analysis into an ordered path through the most important code.

- generate a numbered tour ordered for comprehension, not merely by filename
- make architecture and control-flow stops precede dependent details
- mark critical stops with an intentional pulse that respects reduced-motion settings
- show a voice button only when narration is available or can be generated
- play a concise clip explaining what the section does, why it matters, what to verify, and any related finding
- scroll to and highlight all anchors for the active stop
- allow manual reorder, skip, replay, and completion tracking
- keep the full review available outside the tour

Tour generation should prioritize building a mental model. A useful default order is entry point, core state or data flow, side effects, error handling, security-sensitive paths, and tests. The analyzer can vary that order when evidence supports a better path.

### Phase 5: Live voice questions

Goal: Let the reviewer ask questions naturally while reading code.

- microphone starts only after an explicit click or shortcut
- clear listening, thinking, and speaking states
- capture a fresh `ReviewContext` for every utterance
- understand deictic questions such as `Why is this here?`, `What calls this?`, or `Is this finding actually risky?` from selection and viewport context
- stream spoken and visible answers with file and line citations
- attach the visible answer to the active selection, hunk, or finding inside the diff canvas, with pin, dismiss, replay, and cited-anchor actions
- use a non-obscuring sidecar or bottom sheet when the anchored answer would cover code at narrow widths
- support interruption and follow-up questions
- let an answer create a draft note or finding only through a separate confirmation
- stop the microphone immediately when the user ends voice mode or leaves the review

The voice session has access to the review, active viewport, current selection, prior AI analysis, and current tour stop. Its answer remains associated with the code that supplied the context even after the reviewer scrolls. It does not receive ambient control of the repository or Mac.

### Phase 6: Synchronized autoplay tour

Goal: Provide a narrated walkthrough that moves through the review at the pace of the explanation.

- play stops in the configured order
- preload the next file and audio clip
- scroll before narration begins, then keep the primary anchor comfortably visible
- apply timed `HighlightCue` ranges during playback
- pause on user scroll, selection, question, or tab change
- resume from the current cue or skip to the next stop
- show transcript and progress at all times
- support playback speed and captions
- respect reduced motion by using direct positioning and static emphasis

Autoplay never takes irreversible action. Manual interaction wins immediately over automated scrolling.

## Relevance and focus mode

AI may assign a relevance score to files and hunks using change size, control-flow position, risk category, call relationships, test coverage, and findings. Relevance is presentation metadata, not a filter on the source of truth.

- Default review mode shows all changes.
- Focus mode groups critical and high-relevance content first.
- Lower-relevance content may be collapsed with counts and reasons.
- Deleted, generated, vendored, lockfile, and snapshot changes may use category-specific summaries, but remain revealable.
- Files with security, permissions, persistence, migrations, or public API changes cannot be hidden solely because they have few changed lines.
- `Show all changes` is always visible in focus mode.
- AI review completeness reports which files or hunks were omitted from model context.

## Voice and audio behavior

### Pre-generated clips

Narration text is stored separately from audio so it can be reviewed, edited, translated, or regenerated with a different voice. Clips are keyed by review revision, tour stop, narration hash, voice, and speed. Stale clips remain playable only with a visible warning if their anchors no longer match.

### Live mode

- A live session is scoped to one review ID and current revision.
- It starts on explicit user action and displays an unmistakable microphone indicator.
- Audio capture is sent in bounded utterances, not kept as an always-on background stream.
- Each transcript is visible and editable before any optional note or comment action.
- Barge-in stops current answer playback and begins a new utterance without losing conversation context.
- Leaving review mode ends audio capture and playback.

### Playback synchronization

Audio timing uses explicit cues produced with the narration, not estimated from scroll position. The playback coordinator owns the clock. The renderer adapter translates each cue's anchors into visible highlights. If an anchor cannot be resolved, playback pauses and offers to continue without synchronized highlighting.

## Security and privacy

### Repository access

- Canonicalize every repository root and file path on the backend.
- Reject traversal outside the opened repository.
- Do not construct shell commands from raw URLs, refs, file paths, or model output.
- Use argument arrays or a Git library for repository operations.
- Treat pull request content, filenames, commit messages, comments, and patches as untrusted data.
- Opening a pull request does not execute, build, install, or check out its code.
- Repository mutations remain separate, explicit actions protected by existing Herdr permissions.

### Provider credentials

- Hosted-provider and AI credentials stay in the Mac backend or system credential store. Provider and AI bearer tokens never enter the web view.
- Herdr's existing API bearer token may be injected only into the Herdr-owned, origin-restricted web view. It must never be forwarded to diff content, an iframe, third-party script, or a future Plannotator sidecar.
- Logs redact credentials, authorization headers, signed URLs, and sensitive prompt content.
- Remote comments or statuses are read-only until a later, explicitly designed write workflow.

### AI data policy

- Local Git review remains fully functional without AI.
- Before first use of a configured remote model, disclose that selected code context will be sent to that provider.
- The context assembler excludes known secret files and can apply repository-level deny patterns.
- Send the smallest context needed for the task and report omissions.
- Store model name, request time, review revision, and cited anchors for auditability.
- Do not train, fine-tune, or build cross-repository memory from review content through Herdr defaults.
- Model output is untrusted and must be schema-validated before rendering as findings or tour data.

### Microphone and audio

- Request microphone permission only when live voice starts.
- Show listening state for the full duration of capture.
- Stop and release the microphone on session end, view exit, web view teardown, or permission failure.
- Keep raw microphone audio ephemeral by default. Persist transcripts or generated clips only when the product state calls for it.
- Before first remote STT or TTS use, identify the provider and disclose which audio, transcript, or narration text leaves the Mac, the provider retention behavior, and the available deletion controls.
- Report local STT, remote STT, local TTS, and remote TTS as separate capabilities so the user can choose or disable each path.
- Cancellation deletes buffered utterance audio immediately. Deleting a conversation or tour clip removes Herdr's stored transcript, audio, and provider object when the configured provider supports deletion, and clearly reports any provider retention that Herdr cannot control.
- Do not include ambient terminal, clipboard, or other app content in voice context unless the user explicitly attaches it.

### Embedded content

The first implementation does not iframe a third-party review server. Diff content is treated as text and rendered through the owned component boundary. Any future hosted preview or rich-content iframe must be sandboxed and must not inherit Herdr credentials.

## Extensibility requirements

1. **Provider adapters:** Local working tree, revision range, and GitHub pull request all produce `ReviewSnapshot` and `FilePatch`.
2. **Renderer adapter:** The app can upgrade or replace `@pierre/diffs` without changing analysis, tour, or voice contracts.
3. **Annotation registry:** Human notes, AI findings, tour stops, search results, and playback highlights have separate owners and styles but share anchors.
4. **Capability negotiation:** The backend reports which source, mutation, AI, TTS, STT, and hosted-provider features are available. The UI hides or explains unavailable actions.
5. **Versioned schemas:** Review, context, finding, and tour payloads carry schema versions and review revisions.
6. **Feature flags:** PR providers, AI review, voice, and autoplay can ship independently without branching the core review UI.
7. **Theme tokens:** Renderer colors, annotations, selection, pulse, and audio highlights derive from Herdr tokens rather than hard-coded upstream styles.
8. **Command boundaries:** AI may propose notes, findings, navigation, or repository actions, but a separate command layer validates and authorizes execution.

## Performance and resilience

- Fetch file patches lazily and cache them by review revision and path.
- Virtualize large file lists and all-files rendering.
- Set thresholds for large diffs, long lines, generated files, and binary files, with explicit fallback UI.
- Cancel obsolete patch and AI requests when the active file or revision changes.
- Keep scrolling and line selection responsive while analysis streams.
- Preserve the last valid diff during a transient refresh failure and label it stale.
- Debounce viewport capture. Do not rebuild AI context on every scroll event.
- Preload only the next tour stop, not the entire repository.
- Audio playback failure must not block text narration or manual review.

## Accessibility

- Every icon control has a visible tooltip and accessibility label.
- File, finding, and tour navigation are operable by keyboard.
- Diff additions and deletions are not communicated by color alone.
- Split and unified views maintain readable focus order.
- Pulsing tour markers stop under `prefers-reduced-motion` and retain a static emphasized state.
- Synchronized narration always has a visible transcript and captions.
- Automated scrolling pauses on manual input and exposes an explicit Stop control.
- Voice state is communicated visually and through accessibility announcements.

## First-slice acceptance criteria

The first implementation is complete when all of the following are true:

1. Git review opens as a persistent two-region workbench, not a duplicate modal or popup.
2. The left rail clearly separates staged, unstaged, and untracked files, with recent commits available below them in the same scrollable rail.
3. The left rail and diff canvas scroll independently at supported Mac window sizes.
4. Selecting a changed file renders it in the main canvas with `@pierre/diffs` syntax highlighting and old or new line gutters.
5. The reviewer can switch between unified and split views without refetching the patch.
6. The selected file and display mode remain stable during ordinary status refreshes.
7. Stage and unstage actions still work and refresh the appropriate status groups.
8. Loading, empty, binary, large, and malformed patch states have intentional, non-crashing presentations.
9. The frontend captures the active file and display mode in local state shaped for later `ReviewContextV1` assembly.
10. Clicking the active Git navigation control again returns to chat.
11. Existing Git API, web, Mac build, and relevant UI tests pass.
12. The dependency and upstream inspiration are documented, and the production web build contains the tracked third-party notice plus the bundled `@pierre/diffs` license.

## Verification plan for the first slice

### Automated

- unit test status grouping, active-file repair, and same-rail commit selection
- unit test unified or split preference and malformed patch fallback
- component test that the renderer receives a valid patch and display options
- regression test stage and unstage behavior
- frontend type check, unit test, and production build
- Mac app build and existing Git-view tests

### Manual

1. Open a workspace with staged, unstaged, and untracked files.
2. Enter Git review and confirm the diff is already expanded beside the file rail.
3. Scroll the files and code independently.
4. Switch between unified and split views.
5. Select files from each status group and confirm syntax, gutters, and the active file update.
6. Scroll to recent commits, open a commit file, then return to current changes.
7. Stage and unstage a file and confirm it moves groups without losing the review shell.
8. Resize the Mac window through supported widths and confirm the active code remains usable.
9. Select the active Git control again and confirm chat returns.

## Non-goals for the first slice

- embedding the complete Plannotator application or running its server inside Herdr
- pixel-for-pixel reproduction of Plannotator
- pull request URL loading
- GitHub comment creation or review submission
- AI analysis, findings, or automatic code changes
- relevance scoring or hiding files
- generated narration, microphone capture, or live voice
- numbered guided tours or autoplay
- building or executing code from a pasted pull request
- replacing existing Herdr repository authorization or stage controls

These are roadmap items, not rejected ideas. The first slice establishes the renderer, anchors, state, and component boundaries they require.

## Open decisions

1. Whether all-files mode should be the default on wide windows or remain an explicit view alongside selected-file mode.
2. Which GitHub authentication source to use first: existing `gh` credentials, a dedicated token in Keychain, or a Herdr provider connection.
3. Whether review persistence belongs in the existing Herdr store or a dedicated SQLite review database.
4. Which configured model and context budget should power initial AI review.
5. Whether narration is generated on demand per stop or pre-generated for the complete tour.
6. Whether human review notes remain local by default or can be exported as a draft GitHub review.
7. The exact shortcut set and whether it should mirror GitHub, IDE, or Plannotator conventions.

None of these decisions block the Phase 0 renderer and workbench foundation.

## Reference projects

- [Plannotator repository](https://github.com/backnotprop/plannotator): product and interaction reference, licensed MIT or Apache-2.0 at the time of this specification. The research baseline was version 0.27.8 at commit `b381ecbe1200b07db8c050715c0f2c035a44b73a`.
- [Plannotator Code Review](https://plannotator.ai/code-review/): reference for local and hosted review, annotations, Ask AI, Guided Review, and review-agent workflows.
- [Plannotator Code Tour schema at the research baseline](https://github.com/backnotprop/plannotator/blob/b381ecbe1200b07db8c050715c0f2c035a44b73a/packages/shared/tour.ts): reference for ordered, numbered review stops anchored to exact code ranges. Herdr's stop-level `importance` field is an extension; upstream attaches severity to key takeaways rather than to each stop.
- [`@pierre/diffs` documentation](https://diffs.com/docs) and [source license](https://github.com/pierrecomputer/pierre/blob/main/packages/diffs/LICENSE.md): renderer and customization boundary used by Phase 0. Herdr pins version 1.3.2 under Apache-2.0.
