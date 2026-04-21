# Enrollinator

An MDM-agnostic macOS onboarding runner. Enrollinator shows users a branded
progress window during first-boot provisioning, installs software, verifies
system state, and can block the run until the user completes required actions
(sign into ZScaler, set Chrome as default browser, etc.).

It is a shell script driven entirely by a `.mobileconfig`. Your MDM deploys
the `.mobileconfig`; Enrollinator reads the resulting managed preferences and
does the rest. No Jamf policies, no custom agents per vendor, no forks.

---

## Profile Builder

**[`tools/profile-builder.html`](tools/profile-builder.html)** — open it in
any browser. No server, no install, no build step.

The Profile Builder is the primary way to create and maintain Enrollinator
configs. It gives you a full visual editor for every key in the schema:

- **Playbook editor** — create multiple playbooks (Standard, Engineering,
  Design, …), set selectors, drag-and-drop steps within and across playbooks.
- **Step editor** — four tabs per step: Info, Action, Conditions, Behavior.
  All changes are buffered in a draft and committed only when you click Done.
- **If/else branching** — click the ⎇ button on any step to open an inline
  branch block and wire `OnSuccess` / `OnFailure` to any other step ID,
  `$next`, or `$end`.
- **SF Symbol picker** — enter `SF=symbol.name` in any icon field to get an
  inline animation dropdown (pulse, bounce, rotate, …) and a direct link to
  the [SF Symbols library](https://developer.apple.com/sf-symbols/).
- **Token substitution** — `{ }` button next to Title / Subtitle inserts
  live tokens like `{console_user}`, `{serial_number}`, etc.
- **Import / export** — drag in an existing `.mobileconfig` or bare plist to
  continue editing it. Download as a ready-to-upload `.mobileconfig` or as a
  bare `.plist` for use with `--xml`.
- **Live preview panel** — see the swiftDialog window layout update as you
  type.

No XML by hand required. The builder is a single self-contained HTML file
you can keep in the repo, share with teammates, or drop into a wiki.

---

## Why another onboarding tool?

- **MDM-agnostic.** No Jamf-specific parameters or policies. Ships as a
  LaunchDaemon + bash script; the only input is a `com.enrollinator.app`
  configuration profile. Jamf, Kandji, Mosyle, Workspace ONE, and even
  hand-installed profiles work identically.
- **Single source of truth.** Branding, playbook selection, and every step
  live in one `.mobileconfig`. Swap configs without rebuilding the pkg.
- **Playbooks with selectors.** One config defines Engineering, Design,
  Standard, etc. Enrollinator picks one at launch based on hostname regex,
  Mac model identifier, or a flag file. You can also scope the
  `.mobileconfig` itself to a smart group in your MDM.
- **Conditional gating.** A step can require a user action to complete
  before Enrollinator proceeds. The runner polls the condition and surfaces a
  prompt until it passes.
- **If/else branching.** Each step can route to a named step ID, `$next`, or
  `$end` on success or failure — building real decision trees without touching
  the XML by hand. Use the ⎇ button in the Profile Builder or set
  `OnSuccess` / `OnFailure` directly in the schema.
- **Vendor-neutral primitives.** The built-in action and condition handlers
  are deliberately generic: `shell`, `package`, `noop`, `app_installed`,
  `default_browser`, `file_exists`, `profile_installed`, `process_running`.
  Vendor-specific gates (ZScaler, GlobalProtect, CrowdStrike, etc.) are
  composed from these primitives in the `.mobileconfig` — see
  [docs/recipes.md](docs/recipes.md).
- **Addon playbooks.** Mark any playbook `Addon: true` to exclude it from
  automatic selection and surface it in an optional post-install checkbox
  picker instead. Steps already executed during the main run are
  automatically skipped (no double-installs). The picker title, message,
  button labels, icon, and dimensions are all configurable via the
  `AddonPicker` dict or `ENROLLINATOR_ADDON_*` env vars — see
  [docs/recipes.md](docs/recipes.md).

## How it fits together

```
  ┌─────────────────────────┐
  │  Profile Builder        │  tools/profile-builder.html
  │  (browser, no install)  │
  └────────────┬────────────┘
               │ exports
               ▼
  ┌─────────────────────────┐
  │  .mobileconfig          │  com.enrollinator.app
  │  (your MDM deploys it)  │
  └────────────┬────────────┘
               │ managed prefs
               ▼
  ┌─────────────────────────┐
  │  enrollinator.sh        │
  │  lib/plist.sh           │
  │  lib/ui.sh              │
  │  lib/plugins.sh         │
  └────────────┬────────────┘
               │ drives
               ▼
  ┌─────────────────────────┐
  │  swiftDialog            │
  └─────────────────────────┘
```

Enrollinator itself is ~500 lines of bash. It calls out to
`/usr/bin/defaults`, `/usr/libexec/PlistBuddy`, `/usr/bin/plutil`,
`/usr/sbin/installer`, `/usr/bin/profiles`, and a few other standard
utilities — all shipped in the base macOS install. The only external
dependency is [swiftDialog](https://github.com/swiftDialog/swiftDialog),
which you deploy alongside Enrollinator via your MDM.

## Quickstart

### 1. Build your config in the Profile Builder

Open [`tools/profile-builder.html`](tools/profile-builder.html) in any
browser. Click **Load sample** to start from a working example, or
**Import** to load an existing `.mobileconfig`. When you're done, click
**Download ▾ → Download .mobileconfig**.

No XML editing required — but if you prefer to work directly in the schema,
see [docs/mobileconfig-schema.md](docs/mobileconfig-schema.md).

### 2. Install Enrollinator on each Mac

Option A: build and deploy a pkg.

```bash
./pkg/build.sh 1.0.0 "Developer ID Installer: You, Inc. (ABCDE12345)"
# Upload build/Enrollinator-1.0.0.pkg to your MDM.
```

Option B: from a dev machine, just run it.

```bash
sudo /usr/local/enrollinator/enrollinator.sh --config ./examples/enrollinator.mobileconfig
```

### 3. Deploy the `.mobileconfig`

Upload the file from the Profile Builder to your MDM as a custom
configuration profile scoped to the devices you want Enrollinator to run on.

### 4. Deploy swiftDialog

Enrollinator won't start without it. Grab the
[latest release](https://github.com/swiftDialog/swiftDialog/releases) and
push it to `/usr/local/bin/dialog` via your MDM.

### 5. Boot

The LaunchDaemon (`com.enrollinator.app`) starts Enrollinator as root at
boot. Enrollinator waits for a console user, reads the managed config, picks
the matching playbook, and walks the steps. The UI is rendered into the
user's session via `launchctl asuser`. A `/var/lib/enrollinator/completed`
flag prevents it from running again; delete the flag (or pass `--force`) to
re-run.

## The schema in brief

```xml
<dict>
    <key>Branding</key>
    <dict>
        <!-- {console_user}, {hostname}, {serial_number}, and other tokens
             are expanded at runtime inside Title and Subtitle strings. -->
        <key>Title</key><string>Welcome, {console_user}!</string>
        <key>Subtitle</key><string>We're getting a few things ready.</string>
        <key>Logo</key><string>/Library/Enrollinator/assets/logo.png</string>
        <key>AccentColor</key><string>#0A84FF</string>
    </dict>
    <key>DefaultPlaybook</key><string>Standard Employee</string>
    <key>Playbooks</key>
    <array>
        <dict>
            <key>Name</key><string>Standard Employee</string>
            <key>Steps</key>
            <array>
                <dict>
                    <key>Id</key><string>install-chrome</string>
                    <key>Name</key><string>Install Google Chrome</string>
                    <key>Icon</key><string>SF=globe,animation=pulse</string>
                    <key>Action</key>
                    <dict>
                        <key>Type</key><string>package</string>
                        <key>Path</key>
                        <string>/Library/Enrollinator/packages/GoogleChrome.pkg</string>
                    </dict>
                    <key>Conditions</key>
                    <array>
                        <dict>
                            <key>Type</key><string>app_installed</string>
                            <key>BundleId</key><string>com.google.Chrome</string>
                        </dict>
                    </array>
                    <!-- On success, skip straight to the VPN step. -->
                    <key>OnSuccess</key><string>zscaler-signin</string>
                </dict>
            </array>
        </dict>
    </array>
</dict>
```

For the full schema see [docs/mobileconfig-schema.md](docs/mobileconfig-schema.md).

## Project layout

```
Enrollinator/
├── enrollinator.sh                    Main script (managed prefs → swiftDialog)
├── lib/
│   ├── plist.sh                       PlistBuddy helpers
│   ├── ui.sh                          swiftDialog command-file driver
│   └── plugins.sh                     Action + condition handlers
├── launchd/com.enrollinator.app.plist LaunchDaemon (boot trigger; runs as root)
├── pkg/build.sh                       Component-pkg builder
├── scripts/uninstall.sh               Uninstaller
├── examples/enrollinator.mobileconfig Reference configuration profile
├── tools/profile-builder.html         ← Start here: visual config editor
└── docs/                              Schema + deployment guides
```

## Documentation

- [**Profile Builder**](tools/profile-builder.html) — visual editor; open in any browser.
- [Mobileconfig schema](docs/mobileconfig-schema.md) — every key, every handler.
- [Deployment](docs/deployment.md) — pkg, LaunchDaemon, MDM, logging.
- [Recipes](docs/recipes.md) — copy-pasteable gates for VPNs, EDRs, etc.

## License

GPLv3. See [LICENSE](LICENSE).
