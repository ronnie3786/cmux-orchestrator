# cmux harness

Local web and iOS companion tools for monitoring and controlling [cmux](https://cmux.com) sessions from your Mac, browser, and iPhone.

This project is in active development. The main supported workflow today is the **cmux harness**: run the local server, open `/harness`, connect the iOS app, and control active cmux sessions from wherever your Mac is reachable.

## Quick Links

- [Install And Run](#install-and-run)
- [Requirements](#requirements)
- [Home Setup Page](#home-setup-page)
- [Harness Dashboard](#harness-dashboard)
- [Run The iOS App Locally](#run-the-ios-app-locally)
- [Network And iPhone URLs](#network-and-iphone-urls)
- [GitHub And Jira Setup](#github-and-jira-setup)
- [Troubleshooting](#troubleshooting)

## What You Get

- A local server that talks to cmux through the cmux Automation socket.
- A setup homepage at `http://localhost:9091/` that checks server, cmux, LAN, Tailscale, GitHub CLI, and Atlassian CLI readiness.
- A harness dashboard at `http://localhost:9091/harness` for live session monitoring and controls.
- An iOS app that connects to the same local server over LAN or Tailscale, with a local demo mode for trying the mobile UI without a Mac server.
- Git status/diff views, PR comment lookup, Jira ticket lookup, file references, attachment upload, and prompt helpers.

## Requirements

Required:

- macOS.
- [cmux](https://cmux.com) installed.
- Python 3.9 or newer.
- Claude Code installed and authenticated if you want to control Claude Code sessions.

For the iOS app:

- Xcode.
- An iPhone or iOS simulator.
- Apple signing configured if running on a physical iPhone.

Recommended for full functionality:

- [GitHub CLI](https://cli.github.com/) authenticated with `gh auth login`.
- Atlassian CLI authenticated with `acli jira auth login`.
- Tailscale on your Mac and iPhone if you want the iOS app to work outside the local network.

## Install And Run

Clone the repo:

```bash
git clone git@github.com:ronnie3786/cmux-orchestrator.git
cd cmux-orchestrator
```

Start the local server:

```bash
python3 dashboard.py
```

Open the homepage:

```text
http://localhost:9091/
```

Useful routes:

```text
http://localhost:9091/        # setup, checks, connection URLs
http://localhost:9091/harness # main cmux harness dashboard
http://localhost:9091/orchestrator-v2 # Orchestrator V2 production-local runtime
```

`python3 dashboard.py` also supervises the Orchestrator V2 watcher and Node/Vercel AI SDK sidecar when the sidecar package is installed. Run the redacted production readiness check with:

```bash
scripts/orchestrator_v2_health.py
```

For the Orchestrator V2 local Piper voice path, install the local voice wrapper and model once per machine:

```bash
scripts/orchestrator_v2_setup_piper.py
```

The setup script stores Piper assets under `~/.cmux-harness/orchestrator-v2/piper` and writes only non-secret local path entries to `.env.local`.

Optional custom port:

```bash
python3 dashboard.py 8080
```

## Home Setup Page

The homepage is the first place to look after starting the server:

```text
http://localhost:9091/
```

It checks:

- **Harness server:** confirms the Python server is reachable.
- **cmux Automation socket:** confirms cmux Automation mode is enabled and the socket can be polled.
- **LAN discovery:** shows same-network URLs for another device, including the iPhone app.
- **Tailscale:** detects MagicDNS or Tailscale IP access for remote use.
- **GitHub CLI:** verifies `gh` is installed and authenticated for PR comment features.
- **Atlassian CLI:** verifies `acli` is installed and can query Jira work items.

If a row is red, expand it for the reason and setup command. After changing CLI auth or cmux settings, restart the server if the page still shows stale results.

## Configure cmux

The harness talks to cmux through the cmux Automation socket.

1. Open the cmux Mac app.
2. Open **Settings**.
3. Open **Automation**.
4. Enable the socket API / Automation mode.
5. Restart cmux if the homepage still reports that the socket is missing.

Once this is working, the homepage should show the cmux Automation socket as connected.

## Harness Dashboard

Open:

```text
http://localhost:9091/harness
```

The harness dashboard is the primary browser UI. It supports:

- Live cmux workspace/session list.
- Terminal screen mirroring.
- Sending text and simple keys to sessions.
- Auto-mode controls per workspace.
- Git status and diffs.
- GitHub PR comments for the current branch.
- Jira ticket lookup and assigned-ticket browsing.
- File search and prompt reference insertion.
- Build log, console log, and attachment workflows.

Keep `python3 dashboard.py` running while using the dashboard or iOS app.

## Run The iOS App Locally

Open `cmux-harness-ios/cmux-harness-ios.xcodeproj` in Xcode, select the `cmux-harness-ios` scheme, choose an iOS simulator or physical iPhone, then run the app. Configure signing if you are using a real device.

### Try Local Demo Mode

On the setup screen, tap **Start Local Demo** to explore the iOS app without starting `dashboard.py` or connecting to a Mac.

Local demo mode runs entirely inside the iOS app. It uses simulated cmux sessions, terminal output, Git status and diffs, GitHub PR comments, Jira tickets, file search, skills, attachments, and prompt flows. No commands are sent to your Mac, and no network server is required.

While demo mode is active, the app shows a **Local Demo Mode** banner. Tap **Connect Real Server** from that banner, the session list, or Settings to leave demo mode and return to server discovery.

### Connect To Your Mac Server

1. Start the server with `python3 dashboard.py`.
2. Confirm the homepage at `http://localhost:9091/` shows the harness server and cmux socket as healthy.
3. Run the iOS app.
4. Allow Local Network access when iOS prompts for it.

On first launch, enter or discover the server URL. Use:

```text
http://localhost:9091/harness
```

for the simulator on the same Mac.

For a physical iPhone, use one of the LAN or Tailscale URLs shown on the homepage.

Existing iOS installs keep using the server URL already saved in app storage. If you change networks, open settings in the app and update the server URL.

## Network And iPhone URLs

Use the URL that matches where the client is running.

Same Mac or iOS simulator:

```text
http://localhost:9091/harness
```

Physical iPhone on the same Wi-Fi/LAN:

```text
http://<mac-lan-ip>:9091/harness
http://<mac-hostname>.local:9091/harness
```

Physical iPhone over Tailscale:

```text
http://<mac-device-name>.<tailnet-name>.ts.net:9091/harness
```

The homepage lists detected LAN and Tailscale URLs. Tailscale is optional, but it is the easiest way to use the iOS app away from your local network.

Recommended Tailscale setup:

1. Install Tailscale on the Mac.
2. Install Tailscale on the iPhone.
3. Sign into the same tailnet on both devices.
4. Give the Mac a stable Tailscale machine name, such as `cmux-mac`.
5. Use the MagicDNS URL shown on the homepage.

## GitHub And Jira Setup

The harness can work without these CLIs, but some mobile and dashboard features depend on them.

GitHub PR comments require `gh`:

```bash
brew install gh
gh auth login
```

Jira ticket lookup requires Atlassian CLI:

```bash
acli jira auth login
```

The homepage checks both tools. Expand either row to see what failed and why the tool is useful.

Features that use these tools:

- GitHub PR comment discovery for the current branch.
- Prompt insertion for PR review comments.
- Jira assigned-ticket browsing.
- Jira issue lookup by key or URL.
- Prompt insertion for Jira ticket context.

## Troubleshooting

`cmux Automation socket` is red:

- Enable cmux Automation/socket API in cmux settings.
- Restart cmux.
- Restart `python3 dashboard.py`.

The iOS app cannot connect:

- Confirm the Mac server is still running.
- Open the homepage and copy a LAN or Tailscale URL.
- Use `/harness` at the end of the URL.
- Allow Local Network access on iOS.
- If using Tailscale, confirm both devices are connected to the same tailnet.

GitHub or Jira checks are red:

- Expand the row on the homepage.
- Re-run `gh auth login` or `acli jira auth login`.
- Restart the server if the diagnostic still looks stale.

The homepage still shows old text after code changes:

- Restart `python3 dashboard.py`.
- Hard-refresh the browser.

## License

MIT
