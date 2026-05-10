# Web-First Product Direction

Ronnie wants cmux-orchestrator built as a web app first.

Native Mac and iOS apps come later. The web app is the current product target because it is easier to test, iterate, inspect, screenshot, and improve quickly.

## Current Focus

1. Build the web app shell around the Hybrid B direction:
   - Command/attention sidebar.
   - Board canvas for Jira, objectives, ideas, decisions, and review-ready work.
   - Persistent voice/mic affordance later, after the core web workflow is real.
2. Keep the UI ADHD-friendly:
   - Light/simple theme.
   - One obvious top priority.
   - Fewer competing metrics.
   - Clear hierarchy and whitespace.
   - Progressive disclosure instead of dense dashboards.
3. Wire the web UI to real product APIs:
   - `GET /api/command-center`
   - `POST /api/check-ins`
   - `GET/POST/PATCH /api/ideas`
   - `GET /api/decisions`
   - decision approve/reject endpoints
4. Prove one end-to-end objective flow before native apps:
   - capture idea or Jira ticket
   - groom/context pre-flight
   - launch work
   - monitor progress
   - surface decisions/reviews
   - produce final briefing

## Explicit Non-Goal For Now

Do not spend implementation energy on the native Mac app or iOS app until the web app workflow is validated.

Native apps should consume the same APIs later, after the product shape is clear.
