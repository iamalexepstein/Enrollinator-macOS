# Profile Builder

The Profile Builder is a single-page visual editor for Enrollinator configs.
No install, no server, no build step — open
[`tools/profile-builder.html`](../tools/profile-builder.html) in any browser
(or visit the [hosted version](https://iamalexepstein.github.io/Enrollinator-macOS/tools/profile-builder.html))
and everything runs locally in the page.

---

## Getting started

**Load sample** — populates the builder with a fully-formed example config you
can explore and modify. Good starting point for a new deployment.

**Import** — drag a `.mobileconfig` or bare `.plist` onto the canvas, or click
Import and pick a file. The builder parses it and reconstructs the full editor
state. Use this to continue editing an existing config.

**Download ▾** — exports the current config:
- **Download .mobileconfig** — ready to upload to your MDM as a configuration
  profile.
- **Download as .plist (--xml)** — bare plist with no MDM wrapping. Save as
  `enrollinator.xml` at the repo root and run `./pkg/build.sh` to bake it
  directly into the package (see [deployment.md](deployment.md)).

Changes are not persisted across page reloads — download before closing.

---

## Global settings ⚙

The gear icon (top-right) opens a popover for settings that apply to every
playbook:

| Setting | What it does |
|---|---|
| Title / Subtitle | Main window title and subtitle. Support `{token}` substitution (see below). |
| Logo | PNG/JPG/SVG path, `https://` URL, or SF Symbol (`SF=symbol.name`). |
| Banner | Optional image strapped across the top of the window. |
| Accent color | Hex color applied to the title text. |
| Window size | Default dimensions of the main swiftDialog window. |
| Font sizes | Title and body font sizes (compact inline fields). |
| Allow close | When on, a Done button appears after the run finishes. When off, the window closes automatically. |
| Test mode | Walk the UI and evaluate conditions without running destructive actions. |
| Install swiftDialog | Enrollinator will install swiftDialog automatically on first run if it's missing. |
| Blur screen | Blur the desktop behind the window. |
| Always on top | Keep the window above all other windows. |
| Payload identifier | Reverse-DNS identifier for the generated `.mobileconfig`. |

### Token substitution

`Title` and `Subtitle` support `{token}` placeholders, expanded at runtime:

| Token | Value |
|---|---|
| `{console_user}` | Login username |
| `{full_name}` | User's display name |
| `{computer_name}` | Computer name |
| `{hostname}` | Local hostname |
| `{serial_number}` | Hardware serial |
| `{model}` | Model identifier |
| `{os_version}` | macOS version |
| `{ip_address}` | Primary IP address |

Click the **{…}** button next to any title/subtitle field to pick a token from
a dropdown instead of typing it.

---

## Playbooks

The left sidebar lists all playbooks. Each playbook is an independent workflow
— you define one per device type, department, or role (Engineering, Design,
Standard, Addon, …).

**Add playbook** — button at the bottom of the sidebar.

**Reorder** — drag playbooks in the sidebar. The first playbook whose selector
matches the machine at runtime is used. If none match, `DefaultPlaybook` is
used (set in global settings).

Click a playbook name to open it. Click the playbook title in the canvas header
to rename or edit its description and selector.

### Selectors

A selector is an optional rule that decides which machines use this playbook.
If no selector is set, the playbook is always eligible (use `DefaultPlaybook`
to pick the fallback).

| Selector type | Matches when… |
|---|---|
| Hostname regex | `hostname` matches the pattern (e.g. `^eng-`) |
| Model identifier | Hardware model ID equals the value (e.g. `MacBookPro18,3`) |
| Serial number | Serial number equals the value |
| Flag file | A file exists at the given path |
| macOS version | OS version is `>=`, `<=`, or `=` the given version |
| Console user | Current user equals the value |

### Addon playbooks

Toggle **Addon** on a playbook to exclude it from automatic selection. Addon
playbooks are instead offered to the user in a checkbox picker after the main
run finishes. Steps that already ran during the main run are automatically
skipped.

---

## Steps

Click **+ Add step** in the canvas to create a step, or click any existing step
to open its editor. Each step editor has four tabs.

### Info tab

| Field | Description |
|---|---|
| Name | Displayed in the step list during the run. |
| Description | Shown in the step list subtitle. |
| ID | Optional stable identifier for branching (`OnSuccess` / `OnFailure`). Auto-generated if left blank. |
| Icon | SF Symbol token (`SF=checkmark.circle`), absolute path, or `https://` URL. The **SF** button opens a searchable symbol picker with animation options (pulse, bounce, rotate, …). |

### Action tab

What Enrollinator *does* for this step. Choose a type from the dropdown.

**Shell** — run a command as root (or as the console user with **Run as user**).
Use the **MDM / source** picker to get pre-filled commands for common tasks:

| MDM / source | Available commands |
|---|---|
| Jamf Pro | `policy` (event / ID / all scoped), `recon`, `manage` |
| Installomator | Install by label |
| Munki / Workspace ONE | `managedsoftwareupdate` (auto / install-only / check-only) |
| Kandji | Run all library items, run specific item |
| Mosyle | Force agent check-in |
| Addigy | Run a policy |
| macOS built-ins | Rosetta 2, Xcode CLT, Software Update, `installer` |
| Custom | Write any shell command directly |

Set **Timeout** to cap how long the command can run (seconds). Useful for
package installs or MDM policy calls that might hang.

**Package** — install a `.pkg` via `installer`. Set the path to the package
file on disk (e.g. `/Library/Enrollinator/packages/Chrome.pkg`) and optionally
a target volume (default `/`).

**Dialog** — show a swiftDialog popup. The step passes or fails based on which
button the user clicks:
- **Title / Message** — window content (Markdown supported in Message).
- **Font sizes** — compact `Title / Body` inline fields.
- **Size** — compact `W / H` inline fields.
- **Buttons** — up to 3 labels. Add, reorder, or remove buttons with ↑ ↓ ✕.
- **Expected** — which button click counts as a pass. Only visible when at
  least one button is defined.
- **Media** — choose one mode:
  - **None** — dialog only, no media.
  - **Slideshow** — a sequence of frames the user clicks through before
    reaching the dialog. Each frame has an image, optional title override,
    and optional message override.
  - **Video** — a video file or YouTube URL/ID. An **▶ Autoplay** toggle
    appears when a URL is entered.
- **Blur screen / Always on top** — per-dialog overrides of the global setting.

**Wait** — sleep for a fixed number of seconds, then succeed. Useful for
letting a LaunchDaemon settle after a package install.

**Noop** — always succeeds immediately. Useful for condition-only steps or
branch targets.

### Conditions tab

Conditions are checks that must pass for the step to be considered complete.
Add as many as needed — all conditions must pass. Conditions are also used by
blocking steps: Enrollinator keeps polling until every condition passes.

| Type | Passes when… |
|---|---|
| Shell | Command exits 0 |
| App installed | App with the given bundle ID (and optional min version) is installed |
| Default browser | App with the given bundle ID is the default browser |
| File exists | A file (or directory) exists at the given path |
| Profile installed | A configuration profile with the given identifier is installed |
| Process running | A process with the given name is running (optional min count) |

The **Invert** toggle on any condition flips the pass/fail logic.

### Behavior tab

Controls how Enrollinator handles this step's lifecycle.

**Blocking** — when on, Enrollinator does not advance to the next step until
all conditions pass. It polls the conditions on an interval. The following
settings only appear when Blocking is on:

| Field | Description |
|---|---|
| Interval | How often to re-evaluate conditions (seconds, default 5). |
| Timeout | Maximum time to wait before giving up (seconds, 0 = wait forever). |
| User prompt | Text shown in the main window subtitle while waiting. |
| Wait window | An optional secondary swiftDialog window shown while polling. |

**Continue on failure** — when on, a failed step does not stop the run.

---

## Wait window

The wait window is a secondary dialog shown alongside the main window while a
blocking step is polling. Configure it within the **Behavior** tab after
enabling Blocking and clicking **Add wait window**.

| Field | Description |
|---|---|
| Title / Message | Window content. |
| Font sizes | Compact `Title / Body` inline fields. |
| Size | Compact `W / H` inline fields. |
| Blur screen / Always on top | Per-window overrides. |
| Media | Same **None / Slideshow / Video** picker as dialogs (see above). Slideshow frames include Back/Next navigation buttons for the user. |

---

## Branching

Click the **⎇** button on any step card to open an inline branch block below
it. Set **On success** and **On failure** independently:

| Value | Meaning |
|---|---|
| Continue to next step | Default success behaviour — advance sequentially. |
| End run | Close Enrollinator immediately. |
| Stop run | Default failure behaviour — halt without closing. |
| Any step name | Jump to that step by ID. |

Branch arrows are drawn on the canvas so the flow is visible at a glance.
Collapse a branch block by clicking ⎇ again.

---

## Live preview

The right panel shows the raw XML that will be written into the `.mobileconfig`
payload. It updates on every field change. A **valid** / **error** badge
indicates whether the current config serializes cleanly.

Click the **‹** / **›** toggle to collapse or expand the preview panel if you
need more room.

---

## Keyboard shortcuts

| Key | Action |
|---|---|
| `Esc` | Close the current step/profile editor without saving |
| `Enter` (in modal footer) | Confirm / Done |

---

## Tips

- **Draft edits** — the step editor buffers changes in a draft. Click **Done**
  to commit, **Cancel** to discard. Re-opening the same step resumes the
  draft.
- **Reordering** — drag step cards up and down within a playbook. Steps can
  also be moved between playbooks by dragging onto the sidebar playbook name.
- **Validation badges** — a red outline and warning icon on a step card means
  a required field is missing. Hover to see what's needed.
- **Config round-trips** — any `.mobileconfig` or `.plist` exported by the
  builder can be imported back in without data loss.
