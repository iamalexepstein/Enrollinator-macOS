# Deploying Enrollinator

This document covers what you put on disk, where, and how Enrollinator starts.

## Config delivery: MDM profile vs. bundled XML

Enrollinator supports two ways to receive its configuration. Choose one per
deployment:

**Option A — MDM profile (recommended)**
Deploy a `.mobileconfig` via your MDM as a custom configuration profile.
macOS writes it into the `com.enrollinator.app` managed preferences domain;
Enrollinator reads it at runtime. The pkg and the config are independent — you
can update steps, branding, or playbooks by pushing a new profile without
rebuilding or redeploying the pkg.

**Option B — Bundled XML**
Export a bare `.plist` from the Profile Builder (**Download ▾ → Download as
.plist**), save it as `enrollinator.xml` in the repo root, and run
`./pkg/build.sh`. The file is installed at
`/usr/local/enrollinator/enrollinator.xml` and auto-discovered at runtime — no
MDM profile needed. This is useful when a configuration profile isn't
practical (e.g. testing, or environments where profile scoping is awkward).

Config resolution order (first match wins):

1. `--xml <path>` CLI flag
2. `--config <path>` CLI flag
3. `/usr/local/enrollinator/enrollinator.xml` (bundled, Option B)
4. `com.enrollinator.app` managed preferences domain (MDM profile, Option A)

## Artifacts

| Artifact | Required | Notes |
|---|---|---|
| `Enrollinator-<version>.pkg` | Yes | Built by `./pkg/build.sh`. Installs scripts + LaunchDaemon. |
| swiftDialog `.pkg` | Yes | From [swiftDialog releases](https://github.com/swiftDialog/swiftDialog/releases). Installs `dialog` to `/usr/local/bin/dialog`. |
| `.mobileconfig` | Option A only | Custom configuration profile, scoped to target devices in your MDM. |
| App packages (Chrome, Slack, …) | As needed | Any `.pkg` referenced by an `Action: Type=package` step. |

### Building the pkg

```bash
# Standard build — config delivered via MDM profile (Option A)
./pkg/build.sh 1.0.0

# Bundled XML build — config baked in (Option B)
cp /path/to/exported-config.plist enrollinator.xml
./pkg/build.sh 1.0.0
```

Packages do not need to be signed for deployment via Jamf or other MDMs — the
MDM agent validates packages using its own checksum. A signing identity
(`"Developer ID Installer: …"`) is only needed if you distribute the pkg
outside of MDM (e.g. direct download). Pass it as the second argument:

```bash
./pkg/build.sh 1.0.0 "Developer ID Installer: Example, Inc. (ABCDE12345)"
```

## Paths after install

```
/usr/local/enrollinator/
├── enrollinator.sh                        # runs as root, from the LaunchDaemon
├── enrollinator.xml                       # only present for Option B (bundled XML)
└── lib/
    ├── plist.sh
    ├── ui.sh
    └── plugins.sh

/Library/LaunchDaemons/com.enrollinator.app.plist

/var/log/enrollinator.log                  # structured run log
/var/log/enrollinator.stdout.log           # daemon stdout
/var/log/enrollinator.stderr.log           # daemon stderr
/var/tmp/enrollinator/                     # runtime scratch space
/var/tmp/dialog.log                        # swiftDialog command file (world-writable by design)
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

# Test mode: walk the UI, evaluate conditions, skip actions (dialog actions still run):
sudo /usr/local/enrollinator/enrollinator.sh --test --force

# Print the plan without executing anything:
sudo /usr/local/enrollinator/enrollinator.sh --dry-run

# Dev on a non-root machine (UI may not appear in GUI):
/usr/local/enrollinator/enrollinator.sh --skip-root-check --test
```

## Jamf Pro

There are two ways to deploy Enrollinator via Jamf. Both require swiftDialog
and the Enrollinator pkg on disk; they differ in what triggers the run and how
long the policy waits.

---

### Method 1: LaunchDaemon (recommended for DEP/ADE enrollment)

The Enrollinator pkg installs a LaunchDaemon that fires at every boot. It
calls `wait_for_console_user` internally and will not try to show UI until a
real user is at the login window or desktop, so it works cleanly with
zero-touch ADE provisioning flows where the device may boot before a user
session exists.

#### Policies

Create three policies, all scoped to the same Smart Group (e.g.
*Enrollinator — Pending*) and triggered by **Enrollment Complete**:

| Policy | Package | Config profile | Execution order |
|--------|---------|----------------|-----------------|
| Install swiftDialog | swiftDialog `.pkg` | — | 1 |
| Install Enrollinator | `Enrollinator-<version>.pkg` | — | 2 |
| Push Enrollinator config *(Option A only)* | — | Your `.mobileconfig` | 3 |

For **Option B** (bundled XML), the config is baked into the pkg — only the
first two policies are needed.

The LaunchDaemon fires automatically after the pkg lands. Exact policy
execution order is not critical as long as all artifacts arrive before the
user's first login session.

#### Re-running via Jamf

Do not call `enrollinator.sh` directly from a Jamf script policy — Jamf
injects positional arguments (`$1`–`$3`) the script does not expect, and
there may be no active user session for the UI to land in. Instead, create a
policy with a small wrapper script that removes the completed flag and kicks
the existing daemon:

```bash
#!/bin/bash
rm -f /var/lib/enrollinator/completed
launchctl kickstart -k system/com.enrollinator.app
```

This exits immediately; `launchd` relaunches Enrollinator in its normal
context.

---

### Method 2: Enrollment Complete script (lighter, no LaunchDaemon)

If you prefer not to leave a persistent daemon on the machine, you can drive
Enrollinator directly from a Jamf policy triggered by **Enrollment Complete**.
The policy installs the pkg (which puts the script and libraries on disk) and
then runs a second script that blocks until Enrollinator finishes.

Because Jamf injects `$1`–`$3` into every script, use a wrapper that ignores
those arguments and calls `enrollinator.sh` with your own flags:

**Option A — config delivered via MDM profile:**

Push the `.mobileconfig` configuration profile in an earlier policy (or
include it in the same policy group), then run:

```bash
#!/bin/bash
# Wait for swiftDialog to be present before launching.
until [ -f /usr/local/bin/dialog ]; do sleep 2; done

/usr/local/enrollinator/enrollinator.sh
```

Jamf waits for this script to exit before marking the policy complete, so the
policy log captures the final exit code. Make sure the policy's **Execution
Frequency** is set to *Once per computer*.

**Option B — config delivered as bundled XML:**

Build the pkg with `enrollinator.xml` baked in (see [Building the
pkg](#building-the-pkg)). The wrapper is identical — the script auto-discovers
the bundled file at `/usr/local/enrollinator/enrollinator.xml`:

```bash
#!/bin/bash
until [ -f /usr/local/bin/dialog ]; do sleep 2; done

/usr/local/enrollinator/enrollinator.sh
```

Alternatively, if you want to point at an XML file deployed separately (e.g.
via Jamf as a text file copy):

```bash
#!/bin/bash
until [ -f /usr/local/bin/dialog ]; do sleep 2; done

/usr/local/enrollinator/enrollinator.sh --xml /usr/local/enrollinator/enrollinator.xml
```

#### Tradeoffs vs. Method 1

| | Method 1 (LaunchDaemon) | Method 2 (Enrollment Complete) |
|---|---|---|
| Timing | Waits for console user automatically | Runs while Jamf policy is live — user must be logged in |
| Policy log | Not captured (daemon context) | Full stdout/exit code in Jamf log |
| Re-run | Kick daemon or remove completed flag | Re-scope the policy or use a dedicated re-run policy |
| Persistent daemon | Yes — LaunchDaemon remains on disk | No — pkg installs scripts only |

Method 2 is well-suited to workflows where a user is always at the Mac during
enrollment (e.g. IT-assisted setup). Method 1 is better for zero-touch ADE
where the device may boot unattended.

### Reporting back to Jamf

Because Enrollinator runs via LaunchDaemon rather than a Jamf policy, its
output never appears in the Jamf policy log. Instead:

**Automatic inventory update** — Enrollinator calls `jamf recon` in the
background when it finishes (skipped in test/dry-run mode and when Jamf is not
present). This pushes an inventory update to Jamf Pro as soon as the run
completes.

**Extension Attributes** — Create these in Jamf Pro → Settings → Computer
Management → Extension Attributes (data type: String, input: Script). They are
evaluated during every recon and their values appear on the computer record and
can drive Smart Groups.

*Enrollinator Status* — primary EA for Smart Groups:

```bash
#!/bin/bash
COMPLETED=/var/lib/enrollinator/completed
LOG=/var/log/enrollinator.log
if [ ! -f "$LOG" ]; then
    echo "<result>Never run</result>"; exit 0
fi
if grep -q 'any_fail=1' "$LOG" 2>/dev/null; then
    last_fail=$(grep 'Enrollinator finished.*any_fail=1' "$LOG" | tail -1 | cut -d' ' -f1)
    echo "<result>Failed ($last_fail)</result>"
elif [ -f "$COMPLETED" ]; then
    echo "<result>Complete</result>"
else
    echo "<result>In progress</result>"
fi
```

*Enrollinator Last Run* — timestamp:

```bash
#!/bin/bash
ts=$(grep 'Enrollinator finished' /var/log/enrollinator.log 2>/dev/null | tail -1 | awk '{print $1}')
echo "<result>${ts:-Never}</result>"
```

*Enrollinator Last Error* — most recent `[error]` or `[warn]` line:

```bash
#!/bin/bash
last=$(grep -E '\[(error|warn)\]' /var/log/enrollinator.log 2>/dev/null | tail -1)
echo "<result>${last:-None}</result>"
```

Suggested Smart Groups:

| Name | Criteria |
|---|---|
| Enrollinator — Complete | Status `is` `Complete` |
| Enrollinator — Failed | Status `is` `Failed (…)` (use `like` `Failed`) |
| Enrollinator — Pending | Status `is not` `Complete` AND `is not` `Failed (…)` |

## Logging

Enrollinator writes structured lines to `/var/log/enrollinator.log`:

```
2026-04-19T09:14:22-0700 [info]  Enrollinator starting (root=/usr/local/enrollinator domain=com.enrollinator.app pid=842)
2026-04-19T09:14:22-0700 [info]  Console user: alex
2026-04-19T09:14:22-0700 [info]  Using bundled config: /usr/local/enrollinator/enrollinator.xml
2026-04-19T09:14:22-0700 [info]  Selected profile: Standard Employee (index 1)
2026-04-19T09:14:22-0700 [info]  step=install-chrome name=Install Google Chrome blocking=false
2026-04-19T09:14:44-0700 [info]  step=chrome-default name=Set Chrome as your default browser blocking=true
2026-04-19T09:15:10-0700 [info]  Enrollinator finished (any_fail=0 test_mode=0)
2026-04-19T09:15:10-0700 [info]  Triggering jamf recon
```

swiftDialog's own output goes to `/var/log/enrollinator.stdout.log` and
`/var/log/enrollinator.stderr.log` (configured by the LaunchDaemon plist).

## Updating the config

**Option A (MDM profile):** Edit your config in the
[Profile Builder](../tools/profile-builder.html), click **Import** to load
the current file, make your changes, then **Download .mobileconfig**. Push the
new profile through your MDM. On next boot, Enrollinator reads the fresh
managed preferences. There is no need to rebuild or redeploy the pkg.

**Option B (bundled XML):** Re-export the `.plist` from the Profile Builder,
overwrite `enrollinator.xml` in the repo root, and rebuild + redeploy the pkg.

If the completed flag is in the way, wipe `/var/lib/enrollinator/completed`
from your MDM, or add a step with `Action: Type=shell` that removes it.

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
