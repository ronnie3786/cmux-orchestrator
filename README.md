# cmux harness

> This is in active development and has sharp edges. Use it if you are experimenting with cmux automation or contributing to the project.

cmux harness is a local web server for controlling and reviewing [cmux](https://cmux.com) sessions. It includes:

- A home setup page at `/` for onboarding, connectivity status, and network URLs.
- The cmux session harness at `/harness`.
- The objective orchestrator at `/orchestrator`.
- An iOS app that connects to the same server over Tailscale or your LAN.

## Requirements

- **cmux** installed on your Mac.
- **Python 3.9+**. The server uses the Python standard library.
- **Claude Code** installed and authenticated if you use Claude-based sessions.
- **Xcode** if you want to run the iOS app.
- **Tailscale** on your Mac and iPhone if you want remote access outside your local network.

## 1. Start The Server

```bash
git clone git@github.com:ronnie3786/cmux-orchestrator.git
cd cmux-orchestrator
python3 dashboard.py
```

The server opens the setup page automatically:

```text
http://localhost:9091/
```

Useful routes:

```text
http://localhost:9091/             # setup, network status, onboarding
http://localhost:9091/harness      # cmux session harness
http://localhost:9091/orchestrator # objective orchestrator
```

Optional custom port:

```bash
python3 dashboard.py 8080
```

You can also use the helper script:

```bash
./cmux-dashboard start
./cmux-dashboard stop
./cmux-dashboard restart
```

## 2. Configure cmux

The harness talks to cmux through the cmux socket API. Configure this in the Mac app:

1. Open **cmux**.
2. Open **Settings**.
3. Open **Automation**.
4. Enable the socket API / Automation mode.
5. Restart cmux if the setup page still reports that the socket is missing.

The setup page at `http://localhost:9091/` shows whether the socket is present and connected.

## 3. Choose A Network URL

The server listens on all interfaces. Pick the URL that matches where you are connecting from.

For the same Mac:

```text
http://localhost:9091/harness
```

For another device on the same Wi-Fi/LAN:

```text
http://<mac-lan-ip>:9091/harness
http://<mac-hostname>.local:9091/harness
```

For Tailscale:

```text
http://<mac-device-name>.<tailnet-name>.ts.net:9091/harness
```

The home page lists detected LAN URLs and tries to detect Tailscale automatically. When Tailscale is running on the Mac, it prefers the Mac's MagicDNS name and falls back to the Mac's 100.x Tailscale IP if only the interface address is available. You can still save a stable MagicDNS host manually.

## 4. Optional Tailscale Setup

Use Tailscale when you want the iOS app to reach your Mac away from your local network.

1. Install Tailscale on the Mac.
2. Install Tailscale on the iPhone.
3. Sign into the same tailnet on both devices.
4. Confirm the Mac appears as connected in Tailscale.
5. Use the Mac device's MagicDNS name as the iOS server host, or use the Tailscale URL shown on the harness home page.

Recommended: set a stable Tailscale machine name for the Mac, such as `cmux-mac`, instead of relying on the macOS hostname. In the Tailscale admin console, edit the machine name and turn off auto-generation from the OS hostname so your MagicDNS URL does not change when the Mac hostname changes.

Example URL shape:

```text
http://cmux-mac.<tailnet-name>.ts.net:9091/harness
```

Tailscale is optional. LAN discovery still works when the iPhone and Mac are on the same network.

## 5. Run The iOS App

1. Open `cmux-harness-ios/cmux-harness-ios.xcodeproj` in Xcode.
2. Select the `cmux-harness-ios` scheme.
3. Select your iPhone or a simulator.
4. If running on a real iPhone, make sure signing is configured for your team.
5. Run the app.
6. Allow Local Network access when iOS prompts for it.

On first launch, the iOS app no longer uses a hardcoded server URL. It requires a saved server URL before showing sessions.

Discovery order:

1. Probe the saved Tailscale host, if one exists.
2. Scan the LAN for the Bonjour service advertised by `dashboard.py`.
3. Let you type the server URL manually.

Manual URLs to enter:

```text
http://<mac-device-name>.<tailnet-name>.ts.net:9091/harness
http://<mac-lan-ip>:9091/harness
http://<mac-hostname>.local:9091/harness
```

Existing iOS installs keep using the server URL already saved in `UserDefaults`.

## Features

### Harness (`/harness`)

- Live cmux workspace/session list.
- Terminal screen mirroring.
- Send text and simple keys to sessions.
- Auto-approval controls for individual workspaces.
- Git status, diffs, build logs, and console logs.

### Orchestrator (`/orchestrator`)

- Define objectives in plain language.
- Break work into tasks and dispatch across cmux workspaces.
- Track plans, task progress, contracts, and review status.
- Inspect diffs, build logs, console logs, and worker output.

## Configuration

Most harness and orchestrator settings are still managed inside their existing settings panels. The home page only covers onboarding, cmux Automation/socket setup, and network connectivity.

The approval severity threshold is shared by the `/harness` Haiku auto-approval flow and the Claude Code PreToolUse hook flow:

- **Level 1:** read-only project access.
- **Level 2:** file edits and safe shell commands.
- **Level 3:** known external services such as Jira, GitHub, or Slack.
- **Level 4:** ambiguous operations that need human judgment.
- **Level 5:** destructive or dangerous operations.

Levels at or below the configured threshold are eligible for auto-approval. Levels above it escalate to a human.

## License

MIT
