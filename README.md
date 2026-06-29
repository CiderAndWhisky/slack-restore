# Slack Restore

Keeps Slack on the leftmost display and Microsoft Outlook on the rightmost display after macOS moves windows during unlock.

The helper polls every 2 seconds by default. On each poll it:

1. Does nothing unless exactly 3 displays are connected.
2. Finds the visible, on-screen main-window candidate for each configured app on the current Space.
3. Ignores an app when it is minimized, hidden, fullscreen, or on another Space.
4. Moves and resizes Slack to the full bounds of the leftmost display when needed.
5. Moves and resizes Outlook to the full bounds of the rightmost display when needed.

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
```
