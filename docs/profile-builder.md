# Profile Builder

The Profile Builder is a single-page visual editor for Enrollinator configs.
No install, no server, no build step — open
[`tools/profile-builder.html`](../tools/profile-builder.html) in any browser
(or visit the [hosted version](https://iamalexepstein.github.io/Enrollinator-macOS/tools/profile-builder.html))
and everything runs locally in the page.

## Contents

- [Getting started](#getting-started)
- [Deployment target](#deployment-target) — [What it changes](#what-it-changes) · [Advanced mode](#advanced-mode) · [Nothing is removed](#nothing-is-removed)
- [Global settings ⚙](#global-settings-) — [Token substitution](#token-substitution)
- [Playbooks](#playbooks) — [Selectors (removed)](#selectors-removed) · [Addon playbooks](#addon-playbooks)
- [Steps](#steps) — [The step catalogue](#the-step-catalogue) · [The SF Symbol picker](#the-sf-symbol-picker) · [Guided mode](#guided-mode)
  — [Info tab](#info-tab) · [Action tab](#action-tab) · [Conditions tab](#conditions-tab) · [Behavior tab](#behavior-tab)
- [Wait window](#wait-window)
- [Branching](#branching)
- [Live preview](#live-preview)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Tips](#tips)

---

## Getting started

On load the builder asks how you're starting:

| Choice | What happens |
|---|---|
| **Start a new config** | Goes on to the [deployment questions](#deployment-target) — which MDM, which tooling, your organisation name — then drops you on an empty playbook. |
| **Open an existing config** | Opens the file picker. The config's MDM is [read out of its own commands](#deployment-target), so you aren't asked again. |
| **Explore the sample** | Loads the worked example, likewise detecting its MDM. |

Tick **Don't show again** to skip the launcher on later visits. **Take the
tour** opens the four-card orientation, which is also always available from the
**?** menu.

**Load sample** — populates the builder with a fully-formed example config you
can explore and modify. Good starting point for a new deployment.

**Import** — drag a `.mobileconfig` or bare `.plist` onto the canvas, or click
Import and pick a file. The builder parses it and reconstructs the full editor
state. Use this to continue editing an existing config.

**Download ▾** — two sections. *Your configuration* exports what you've built:
- **Download .mobileconfig** — ready to upload to your MDM as a configuration
  profile.
- **Download as .plist (--xml)** — bare plist with no MDM wrapping. Save as
  `enrollinator.xml` at the repo root and run `./pkg/build.sh` to bake it
  directly into the package (see [deployment.md](deployment.md)).

*Enrollinator* fetches the runtime itself from the latest release, so you can
assemble a deployment without leaving the builder:
- **Latest script** — `enrollinator.sh`, the runner.
- **Latest package** — the installer `.pkg` you upload to your MDM.
- **Latest daemon** — `com.enrollinator.app.plist`, the LaunchDaemon that
  starts Enrollinator at boot. The package installs this already; download it
  separately only when building a deployment by hand.

All three resolve through the GitHub releases API and come from the same tag,
so the script, package and daemon you download together are one build — none
of them is pinned to a version in the builder, and none comes from `main`,
which runs ahead of the newest tag between releases. They require network
access; if GitHub is unreachable, or its unauthenticated API rate limit
(60 requests an hour per address) is hit, the click opens the releases page
rather than substituting a file that isn't part of the release.

Changes are not persisted across page reloads — download before closing.

**Help** — the **?** button in the header opens the in-app help centre: a
searchable reference covering playbooks, actions, conditions, branching,
media, tokens, export, and troubleshooting. It mirrors this document and is
available offline, since the builder is a single self-contained file.

The **⧉** button beside the help search box moves the panel into its own
window, so a section stays open beside the config you're editing rather than
over it. The window keeps the section you were reading, follows the builder's
appearance and scale settings as you change them, and searches identically —
it's constructed from the page in memory, so it needs no network and works
from `file://`. Closing the builder closes it. If the browser blocks the
pop-up the panel stays where it is and says so.

---

## Deployment target

A fleet has one MDM, but a config has many shell steps. The builder asks once
and shapes what it offers from the answer. The chip at the left of the header
shows the current target and reopens the setup sheet.

| Question | Why |
|---|---|
| What manages these Macs? | Picks one MDM, which turns on [guided mode](#guided-mode). Or pick **Advanced mode** — see below. |
| Also deployed on this fleet? | Tooling that pairs with any MDM — currently Installomator. Zero or more. |
| Organisation | Optional name and logo. The name fills in `PayloadOrganization` and `PayloadIdentifier` so they aren't left as `com.example` placeholders; the logo becomes `Branding.Logo`, the image at the top of the onboarding window. Anything you've already edited in Profile Settings is left alone. |

This is **builder context, not configuration**. It lives in the browser's local
storage and never reaches the exported profile — two people building the same
config on different MDMs get byte-identical output.

### What it changes

| Surface | Effect |
|---|---|
| Adding a step | Guided mode asks a few follow-up questions instead of opening the four-tab editor. |
| [Step catalogue](#the-step-catalogue) | Your MDM's tasks lead the *Install software* group, then your tooling, then macOS built-ins. Other MDMs' tasks are not offered. |
| **MDM / source** picker | Narrows to your MDM, macOS built-ins, your tooling, and Custom. Other MDMs' presets are hidden, not reordered. |
| Profile identity | Seeded from the organisation name, as above. |
| Branding logo | Seeded from the organisation logo. The welcome screen and add-on picker both fall back to it, so setting it here covers all three windows. |

### Advanced mode

Picking **Advanced mode** instead of an MDM turns all of that off: every source
in every picker, the whole catalogue, and recipes that go straight to the full
step editor with no questions. It's also the right answer when your MDM isn't
listed, or when Enrollinator runs from a package with no MDM binary involved.

Advanced mode is a setting, not a one-way door — switch back to an MDM from the
header chip whenever you like.

### Nothing is removed

Narrowing is a default, never a wall:

- **Show all sources**, under any narrowed picker, restores the full list. The
  link flips to **Narrow to …** so you can go back.
- A step already using a source from outside your fleet always keeps that
  source in its dropdown. Importing a Kandji config while set to Jamf never
  hides the commands that config is built on.
- Every preset in [MDM presets](#action-tab) remains reachable, whichever MDM
  you picked.
- Every guided question screen carries **Open the full editor**.

**Imported configs answer for themselves.** Import and Load sample read the MDM
back out of the commands a config already contains and adopt it, rather than
asking a second time. Tooling is additive — importing a config that uses
Installomator adds Installomator to your fleet rather than replacing what was
there.

---

## Appearance, display & scaling

The **Display ▾** menu in the header adapts the builder to the screen it's on.
All three settings persist in the browser.

| Setting | Options |
|---|---|
| Appearance | `System` (default) follows the Mac's Light/Dark setting and switches live when macOS flips it, or pin `Light` / `Dark`. |
| Interface scale | `Auto`, or pin anywhere from 90% to 175%. Auto sizes from screen width: 110% past 1900px, 125% past 2400px, 150% past 3000px. |
| Content width | `Comfortable` (the classic narrow column), `Wide`, or `Full width`. |

Scale and content width are independent on purpose: scale magnifies everything, content width
reclaims horizontal space. On a large display, Auto scale plus Wide content is
usually the best combination — scale alone just makes a narrow column bigger.

The XML preview pane sizes itself to the window until you drag the divider,
after which it keeps whatever width you set. Below roughly 1000px of effective
width (viewport width ÷ scale) the layout stacks into a single column.

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

**Reorder** — drag playbooks in the sidebar. Order is cosmetic except in one
case: when the welcome screen's playbook picker is enabled, the first playbook
is the one selected before the user chooses. Which playbook actually runs is
set by `DefaultPlaybook` in global settings.

Click a playbook name to open it. Click the playbook title in the canvas header
to rename or edit its description.

### Selectors (removed)

Older builds chose a playbook per machine by matching a **selector** rule
(hostname regex, model identifier, serial number, flag file, macOS version, or
console user). Selectors are gone from both the runtime and this builder, so
there are no selector fields to fill in.

If you import a config written for an older build, its `Selector` dicts are
dropped on import — re-exporting is the simplest way to clean a legacy config.

To vary the playbook across a fleet, either scope a different `.mobileconfig`
to each MDM smart group, or ship one config and enable the welcome screen's
playbook picker so the user chooses. See
[How the playbook is chosen](mobileconfig-schema.md#how-the-playbook-is-chosen).

### Addon playbooks

Toggle **Addon** on a playbook to exclude it from automatic selection. Addon
playbooks are instead offered to the user in a checkbox picker after the main
run finishes. Steps that already ran during the main run are automatically
skipped.

---

## Steps

Click **+ Add step** in the canvas to create a step, or click any existing step
to open its editor. Each step editor has four tabs.

### The step catalogue

**+ Add step** — and the `+` that fades in between two steps — opens a
searchable catalogue of tasks rather than an empty editor. Pick what you want
to happen and the step arrives with its action, conditions, timeout, blocking
behaviour and icon already filled in.

| Group | Covers |
|---|---|
| Install software | Your MDM's install tasks, your tooling's, macOS built-ins (Rosetta 2, Xcode CLT, software updates), and a local `.pkg`. |
| Wait for something | MDM enrolment, an app appearing, or the user finishing something themselves — the last arriving with a [wait window](#wait-window) and slideshow already set up. |
| Talk to the user | A message, a policy to accept, a slideshow walkthrough, or a video. |
| Flow & custom | Pause, branch checkpoint, custom shell command, blank step. |

A recipe is a starting point, not a track. Every one produces an ordinary step
with nothing locked or hidden, and **Blank step** gives you the empty editor if
you'd rather build it up by hand. Step IDs are derived from the name and made
unique within the playbook, so branch targets have something to point at
immediately.

### The SF Symbol picker

Every icon and logo field in the builder — the organisation **Logo** in
[deployment setup](#deployment-target), step **Icon**, branding **Logo** and
**Banner**, the welcome screen's **Logo / icon**, the playbook picker's
**Icon**, and the add-on picker's **Icon** — has an **SF** button beside it.

It opens a searchable shortlist of about a hundred symbols relevant to setting
up a Mac, grouped by what they're for (progress, install, security, network,
hardware, people, files, media) and labelled in the words you'd search for:
typing `vpn` finds `lock.shield`, `restart` finds `powerplug`. Pick one, choose
an animation, and **Use symbol** writes the `SF=…` token back into the field.

| Control | What it does |
|---|---|
| Search | Matches symbol names, plain-language labels, and group names. |
| Symbol | Free-text — accepts **any** SF Symbol name, not just the shortlist. |
| Animation | `pulse`, `bounce`, `variableColor`, `appear`, `disappear`, `rotate`, plus `breathe` and `wiggle` on macOS 14+. |
| Remove icon | Clears the field. |

The picker lists names rather than drawing the symbols: SF Symbols is a system
font with no web distribution, so a browser has nothing to render. Use Apple's
free [SF Symbols app](https://developer.apple.com/sf-symbols/) to see the
artwork, then paste any name into the **Symbol** field.

### Guided mode

With an MDM set, picking a recipe asks for the handful of values the recipe
can't know — one question per screen, with everything else filled in behind
you. "Run a Jamf policy" asks which custom event and what to call the step, and
that's the whole interaction; the command, timeout and icon are already right.

- The closing question pairs the step **name** with its **icon**, since those
  are the two things shown side by side in the progress window. The icon field
  carries the same **SF** picker as everywhere else.
- **Enter** moves to the next question. In a message box, `⌘`/`Ctrl` + `Enter`
  does, since plain Enter is a newline.
- **Back** revisits an answer. **Skip** appears on optional questions.
- Questions can depend on earlier answers — *Wait for the user* asks how the
  step should know it's finished, then follows up with the right field for the
  check you chose.
- **Open the full editor**, on every screen, hands the half-built step to the
  four-tab editor with your answers applied. Nothing is lost either way.
- **Cancel** discards the step entirely. It isn't added to the playbook until
  the last question.

In [Advanced mode](#advanced-mode) there are no questions: recipes open the
full editor directly, on whichever tab holds the field worth filling in —
Action for a policy step, Conditions for a wait, Behavior for a guided wait.

### Info tab

| Field | Description |
|---|---|
| Name | Displayed in the step list during the run. |
| Description | Shown in the step list subtitle. |
| ID | Optional stable identifier for branching (`OnSuccess` / `OnFailure`). Auto-generated if left blank. |
| Icon | SF Symbol token (`SF=checkmark.circle`), absolute path, or `https://` URL. The **SF** button opens the [symbol picker](#the-sf-symbol-picker). |

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

The picker itself is narrowed to your [deployment target](#deployment-target)
— your MDM, macOS built-ins, your tooling, and Custom. **Show all sources**
beneath it brings back the whole table, and a step already using another MDM's
command keeps that source listed regardless.

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
| `Esc` | Close the current step/profile editor, help centre, or dialog without saving |
| `Enter` (in modal footer) | Confirm / Done |
| `⌥ +` / `⌥ −` | Scale the interface up / down one step |
| `⌥ 0` | Reset the interface scale to 100% |

Option rather than Command, because browsers claim `⌘+` and `⌘−` for their own
page zoom before the page ever sees the keystroke.

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
