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

**[`Enrollinator Profile Builder`](https://iamalexepstein.github.io/Enrollinator-macOS/tools/profile-builder.html)** — open it in
any browser (tested in Chrome). No server, no install, no build step.

The Profile Builder is the primary way to create and maintain Enrollinator
configs. It gives you a full visual editor for every key in the schema:

- **Starts by asking how you're starting** — new config, open an existing one,
  or explore the sample. A new config gets a couple of questions about your
  fleet; the other two are read straight out of the config you loaded.
- **Set your MDM once** — the builder narrows the step catalogue and every
  command picker to that MDM, macOS built-ins, and whatever tooling you named.
  Every other preset stays one click away under **Show all sources**.
- **Guided steps** — adding a step opens a searchable catalogue of tasks ("Run
  a Jamf policy", "Wait for the user, with a guide"), then asks only for the
  values it can't infer, one question at a time. Everything else — action,
  conditions, timeout, icon, blocking behaviour — is filled in for you.
- **…or don't be guided** — **Open the full editor** sits on every question
  screen and hands the half-built step straight over, and **Advanced mode**
  turns the questions off entirely and shows every source.
- **Playbook editor** — create multiple playbooks (Standard, Engineering,
  Design, …) and drag-and-drop steps within and across playbooks.
- **Step editor** — four tabs per step: Info, Action, Conditions, Behavior.
  All changes are buffered in a draft and committed only when you click Done.
- **If/else branching** — click the ⎇ button on any step to open an inline
  branch block and wire `OnSuccess` / `OnFailure` to any other step ID,
  `$next`, or `$end`.
- **SF Symbol picker** — every icon and logo field has an **SF** button that
  opens a searchable shortlist of symbols suited to Mac setup, labelled in
  plain language (`vpn` → `lock.shield`), with an animation dropdown (pulse,
  bounce, rotate, …) and a free-text field that accepts any symbol name.
- **Token substitution** — `{ }` button next to Title / Subtitle inserts
  live tokens like `{console_user}`, `{serial_number}`, etc.
- **Hardware info panel builder** — two columns: available blocks on the left,
  the panel's running order on the right. Drag across to place, drag to
  reorder, drag back to remove. Besides the live device fields, drop in a
  **custom text** block (a literal line, `{token}`s expanded) or a **spacer**
  to group what belongs together.
- **Import / export** — drag in an existing `.mobileconfig` or bare plist to
  continue editing it. Download as a ready-to-upload `.mobileconfig` or as a
  bare `.plist` for use with `--xml`.
- **Live preview panel** — the swiftDialog windows drawn on a mock Mac desktop,
  at true size against the screen, with the generated XML folded away
  underneath. Step through the entire run — welcome screen, every slideshow
  frame, every step, the add-on picker — and watch the step list change status,
  windows open on top of each other, and the screen blur exactly where the
  config says it will. Media and SF Symbols appear as labelled placeholders
  rather than being faked.
- **Light and dark** — the **Display ▾** menu follows the Mac's appearance by
  default, or pins Light / Dark.
- **Scales to your display** — the same menu sets interface scale
  (auto, or 90–175%) and content width, so the builder is as usable on a 5K
  monitor as on a laptop.
- **Built-in help centre** — the **?** button opens a searchable reference for
  every panel, action, condition, and export option. No network required, and
  **⧉** pops it into its own window so it can sit beside your config instead of
  on top of it.

No XML by hand required. The builder is a single self-contained HTML file
you can keep in the repo, share with teammates, or drop into a wiki.

---

## Why another onboarding tool?

- **MDM-agnostic.** No Jamf-specific parameters or policies. Ships as a
  LaunchDaemon + bash script; the only input is a `com.enrollinator.app`
  configuration profile. Jamf, Iru (formerly Kandji), Mosyle, Workspace ONE,
  and even hand-installed profiles work identically.
- **Single source of truth.** Branding, playbook selection, and every step
  live in one `.mobileconfig`. Swap configs without rebuilding the pkg.
- **Multiple playbooks per config.** One config defines Engineering, Design,
  Standard, etc. Which one runs is set by `DefaultPlaybook`, overridden per
  run with `--profile`, or chosen by the user when the welcome screen's
  playbook picker is enabled. To vary the playbook by machine, scope the
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

Enrollinator itself is ~3,700 lines of bash across the runner and its three
libs. It calls out to
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
**Download ▾** and choose your format:

- **Download .mobileconfig** — deploy via your MDM as a configuration profile
- **Download as .plist (--xml)** — bundle directly in the pkg (see step 2B)

No XML editing required — but if you prefer to work directly in the schema,
see [docs/mobileconfig-schema.md](docs/mobileconfig-schema.md).

### 2. Install Enrollinator on each Mac

**Option A — MDM profile (recommended):** Build the pkg without a config baked in,
deploy it via your MDM, then deploy the `.mobileconfig` from step 1 as a
separate configuration profile. The config and the code are independent — you
can update the config without rebuilding the pkg.

```bash
./pkg/build.sh 1.0.0
# Upload build/Enrollinator-1.0.0.pkg to your MDM.
```

Packages deployed via Jamf (and most MDMs) do not need to be signed. A signing
identity is only required if you're distributing the pkg outside of MDM.

**Option B — Bundled XML:** Export a `.plist` from the Profile Builder
(**Download ▾ → Download as .plist**), save it as `enrollinator.xml` in the
repo root, then build. The file is bundled into the pkg and auto-discovered at
runtime — no MDM profile needed.

```bash
cp /path/to/your-config.plist enrollinator.xml
./pkg/build.sh 1.0.0
# Upload build/Enrollinator-1.0.0.pkg to your MDM.
```

**Option C — dev/testing:** Run directly against a local config file.

```bash
sudo /usr/local/enrollinator/enrollinator.sh --config ./examples/enrollinator.mobileconfig
```

### 3. Deploy the `.mobileconfig` (Option A only)

Upload the file from the Profile Builder to your MDM as a custom configuration
profile scoped to the devices you want Enrollinator to run on. Skip this step
if you used Option B.

### 4. Deploy swiftDialog

Enrollinator won't start without it. Grab the
[latest release](https://github.com/swiftDialog/swiftDialog/releases) and
push it to `/usr/local/bin/dialog` via your MDM, or enable **Install
swiftDialog** in the Profile Builder's global settings to have Enrollinator
install it automatically on first run.

### 5. Boot

The LaunchDaemon (`com.enrollinator.app`) starts Enrollinator as root at
boot. Enrollinator waits for a console user, reads the config (bundled XML if
present, otherwise managed prefs), picks the matching playbook, and walks the
steps. The UI is rendered into the user's session via `launchctl asuser`. A
`/var/lib/enrollinator/completed` flag prevents re-runs; delete the flag (or
pass `--force`) to re-run.

On Jamf, Enrollinator triggers a `jamf recon` when it finishes so the machine's
inventory reflects the completed state immediately. See
[docs/deployment.md](docs/deployment.md) for Extension Attributes that surface
run status, last run timestamp, and last error in Jamf Pro.

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
- [Profile Builder guide](docs/profile-builder.md) — walkthrough of every panel, field, and feature in the builder.
- [Mobileconfig schema](docs/mobileconfig-schema.md) — every key, every handler.
- [Deployment](docs/deployment.md) — pkg, LaunchDaemon, MDM, Jamf reporting.
- [Recipes](docs/recipes.md) — copy-pasteable gates for VPNs, EDRs, etc.
- [AI conversion guide](docs/ai-conversion-guide.md) — paste into an LLM to convert an existing DEPNotify / Setup Your Mac / SplashBuddy / Liftoff / bash setup flow into an Enrollinator config.

## License

GPLv3. See [LICENSE](LICENSE).
