# Deploying Enrollinator

This document covers what you put on disk, where, and how Enrollinator starts.

## Artifacts

A typical deployment consists of four artifacts, each pushed by your MDM:

1. **`Enrollinator-<version>.pkg`** — installs the script, the `lib/` helpers,
   and the LaunchDaemon. Built by `./pkg/build.sh`.
2. **swiftDialog `.pkg`** — from
   [swiftDialog](https://github.com/swiftDialog/swiftDialog/releases). Must
   land `dialog` at `/usr/local/bin/dialog`.
3. **`.mobileconfig`** — your Enrollinator configuration profile. Deliver it as
   a signed custom configuration profile scoped to the devices you want
   Enrollinator to run on.
4. **App packages** (Chrome, Slack, …) — any `.pkg` referenced by an
   `Action: Type=package` step. Drop them at the path the config
   expects (e.g. `/Library/Enrollinator/packages/`).

## Paths after install

```
/usr/local/enrollinator/
├── enrollinator.sh                        # runs as root, from the LaunchDaemon
└── lib/
    ├── plist.sh
    ├── ui.sh
    └── plugins.sh

/Library/LaunchDaemons/com.enrollinator.app.plist

/var/log/enrollinator.log                  # structured run log
/var/log/enrollinator.stdout.log           # daemon stdout (swiftDialog spawn)
/var/log/enrollinator.stderr.log           # daemon stderr
/var/tmp/enrollinator/                     # runtime scratch space
/var/tmp/dialog.log                    # swiftDialog command file — Enrollinator writes real-time update commands here; swiftDialog tails it. World-writable by design.
/var/lib/enrollinator/completed            # present after a successful run; gates re-runs
```

## LaunchDaemon

`/Library/LaunchDaemons/com.enrollinator.app.plist`:

- Runs as **root** at boot.
- `RunAtLoad = true` — triggers on every boot.
- `KeepAlive = false` — one-shot per machine. Enrollinator's
  `/var/lib/enrollinator/completed` flag prevents it from doing any real work
  on subsequent boots (use `--force` to re-run).

The pkg installs it at mode `644`, owner `root:wheel`.

### Why a daemon, not an agent?

Enrollinator needs root to install `.pkg`s and manage state under
`/var/lib/enrollinator/`. It also needs to render UI to the console user. The
daemon satisfies both: it runs as root, waits for a console user via
`wait_for_console_user`, and then invokes swiftDialog with
`/bin/launchctl asuser <uid>` so the window lands in the user's session.

### Protecting the background item

The example `.mobileconfig` ships a `com.apple.servicemanagement` payload
that prevents users from disabling Enrollinator in System Settings → Login
Items & Extensions → Allow in Background:

```xml
<key>Rules</key>
<array>
    <dict>
        <key>RuleType</key><string>LabelPrefix</string>
        <key>RuleValue</key><string>com.enrollinator</string>
    </dict>
</array>
```

## Running by hand

For development or breakfix. Most paths need root:

```bash
# Against managed preferences (requires the profile to be installed):
sudo /usr/local/enrollinator/enrollinator.sh

# Against a local .mobileconfig:
sudo /usr/local/enrollinator/enrollinator.sh --config ./examples/enrollinator.mobileconfig

# Against a bare plist (schema at the top level, no PayloadContent):
sudo /usr/local/enrollinator/enrollinator.sh --xml ./dev.plist

# Force a particular profile, ignoring selectors:
sudo /usr/local/enrollinator/enrollinator.sh --profile Engineering

# Re-run even if already completed:
sudo /usr/local/enrollinator/enrollinator.sh --force

# Test mode: walk the UI, evaluate conditions, SKIP actions:
sudo /usr/local/enrollinator/enrollinator.sh --test --force

# Print the plan without executing anything:
sudo /usr/local/enrollinator/enrollinator.sh --dry-run

# Dev on a non-root machine (UI may not appear in GUI):
/usr/local/enrollinator/enrollinator.sh --skip-root-check --test
```

## Logging

Enrollinator writes structured lines to `/var/log/enrollinator.log`:

```
2026-04-19T09:14:22-0700 [info]  Enrollinator starting (root=/usr/local/enrollinator domain=com.enrollinator.app pid=842)
2026-04-19T09:14:22-0700 [info]  Console user: alex
2026-04-19T09:14:22-0700 [info]  Config loaded: /var/folders/…/enrollinator-prefs.plist
2026-04-19T09:14:22-0700 [info]  Selected profile: Standard Employee (index 1)
2026-04-19T09:14:22-0700 [info]  step=install-chrome name=Install Google Chrome blocking=false
2026-04-19T09:14:44-0700 [info]  step=chrome-default name=Set Chrome as your default browser blocking=true
```

swiftDialog's own output goes to `/var/log/enrollinator.stdout.log` and
`/var/log/enrollinator.stderr.log` (configured by the LaunchDaemon plist).

## Updating the config

Edit your config in the [Profile Builder](../tools/profile-builder.html)
(open it in any browser, click **Import** to load the current file, make
your changes, then **Download**), or edit the XML directly. Push the new
`.mobileconfig` through your MDM. On next boot, Enrollinator reads the fresh
managed preferences and runs the new steps. There is no need to rebuild or
redeploy the pkg when only the config changes — that's the whole point.

If the completed flag is in the way and you need to re-run after a config
change, wipe `/var/lib/enrollinator/completed` from your MDM, or deploy a new
`.mobileconfig` with a step that does so as an `Action: Type=shell`.

## Uninstalling

```bash
sudo /usr/local/enrollinator/scripts/uninstall.sh
```

The uninstaller removes both the new LaunchDaemon and the old LaunchAgent
(for upgrades), the binaries in `/usr/local/enrollinator`, the scratch dir in
`/var/tmp/enrollinator`, and the persistent state in `/var/lib/enrollinator`.

Then remove the `.mobileconfig` from your MDM scope. If you only remove
the pkg without removing the profile, the managed preferences will remain
in place (harmless, but untidy).
