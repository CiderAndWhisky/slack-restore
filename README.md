# Slack Restore

Keeps Slack on the leftmost display and Microsoft Outlook on the rightmost display after macOS moves windows during unlock.

The helper polls every 2 seconds by default. On each poll it:

1. Does nothing unless exactly 3 displays are connected.
2. Does nothing while the display arrangement is inconsistent: overlapping display bounds, AppKit (`NSScreen`) and CoreGraphics disagreeing about where a display is, or a display change less than 5 seconds ago.
3. Finds the visible, on-screen main-window candidate for each configured app on the current Space.
4. Ignores an app when it is minimized, hidden, fullscreen, or on another Space.
5. Moves and resizes Slack to the full bounds of the leftmost display when needed.
6. Moves and resizes Outlook to the full bounds of the rightmost display when needed.

## Why the consistency checks exist

The display *selection* (leftmost/rightmost) uses CoreGraphics, which always reflects the live arrangement. The *target frame* (display minus menu bar and Dock) comes from `NSScreen`, which is an AppKit cache that is only refreshed when the process handles display reconfiguration callbacks on its run loop. An earlier version slept with `Thread.sleep` and never ran a run loop, so after a reboot with only the built-in display attached the agent kept using the boot-time `NSScreen` data forever and moved Outlook to where the MacBook display *used to be* - the middle of the ultrawide.

The agent now polls from a timer on the main run loop so those callbacks are delivered, refuses to move windows while `NSScreen` and CoreGraphics disagree, and exits after 30 seconds of disagreement so launchd relaunches it with a fresh view. It still restarts every 6 hours as a last-resort safety net.

The leftmost display is the active display with the smallest x coordinate. The rightmost display is the active display with the largest x coordinate.

Slack huddle/call windows are ignored by title fragments such as `huddle`, `junta`, `slack call`, `call with`, and `llamada`; only the Slack main-window candidate is restored to the left display.

## Setup

Build the helper:

```sh
bin/slack-restore build
```

Grant Accessibility permission to **Slack Restore Agent.app**:

```sh
bin/slack-restore open-permissions
```

If macOS shows iTerm in the permission prompt, do not grant iTerm just for this tool. Use the Accessibility settings window instead: click **+**, press **Cmd+Shift+G**, paste this path, and add the app bundle:

```text
/Users/vecchio/projects/slack-restore/.build/Slack Restore Agent.app
```

If the entry is already enabled but `bin/slack-restore once` still says permission is missing, remove **Slack Restore Agent.app** from the Accessibility list and add it again. macOS can stale the permission after a local app bundle is rebuilt.

The older `prompt-permission` command is still available, but the manual app-bundle flow is more predictable for command-line tools.

### Keeping the Accessibility grant across rebuilds

macOS ties the grant to the bundle's code-signing requirement. With the default ad-hoc signature that requirement is the build's hash, so **every rebuild drops the permission** and the agent logs `Accessibility permission is missing` until you re-add it. To make the grant survive rebuilds, create a self-signed code-signing certificate named `Slack Restore Agent` once; `bin/slack-restore build` picks it up automatically (or set `SLACK_RESTORE_SIGN_IDENTITY`):

```sh
cd "$(mktemp -d)"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout key.pem -out cert.pem -subj "/CN=Slack Restore Agent" \
  -addext "keyUsage=digitalSignature" -addext "extendedKeyUsage=codeSigning"
# `-legacy` is required with OpenSSL 3: `security import` cannot read the default
# PKCS12 encryption and fails with "MAC verification failed".
openssl pkcs12 -export -legacy -out identity.p12 -inkey key.pem -in cert.pem -passout pass:slack-restore
security import identity.p12 -k ~/Library/Keychains/login.keychain-db -P slack-restore -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem   # asks for your login password
security find-identity -v -p codesigning   # should list "Slack Restore Agent"
```

Then rebuild, re-grant Accessibility one last time, and future rebuilds keep the grant:

```sh
touch Sources/slack-restore-agent/main.swift && bin/slack-restore restart
```

Run one check:

```sh
bin/slack-restore once
```

Install the LaunchAgent:

```sh
bin/slack-restore install
```

Use a custom poll interval:

```sh
bin/slack-restore install --interval 5
```

## Commands

```sh
bin/slack-restore status
bin/slack-restore logs
bin/slack-restore restart
bin/slack-restore uninstall
```

## Configuration

The LaunchAgent writes these environment variables into its plist:

```sh
SLACK_RESTORE_INTERVAL_SECONDS=2
SLACK_RESTORE_EXPECTED_DISPLAYS=3
SLACK_RESTORE_VERBOSE=0
```

You can override them while installing:

```sh
SLACK_RESTORE_VERBOSE=1 bin/slack-restore install --interval 2
```

The helper also supports:

```sh
SLACK_RESTORE_BUNDLE_ID=com.tinyspeck.slackmacgap
SLACK_RESTORE_APP_NAME=Slack
OUTLOOK_RESTORE_BUNDLE_ID=com.microsoft.Outlook
OUTLOOK_RESTORE_APP_NAME="Microsoft Outlook"
SLACK_RESTORE_MIN_WINDOW_WIDTH=400
SLACK_RESTORE_MIN_WINDOW_HEIGHT=300
SLACK_RESTORE_SETTLE_SECONDS=5
SLACK_RESTORE_STALE_RESTART_SECONDS=30
SLACK_RESTORE_MAX_UPTIME_SECONDS=21600
```

Logs go to `~/Library/Logs/slack-restore.log`; `install`/`restart` rotate a log to `.1` once it exceeds 5 MB.
