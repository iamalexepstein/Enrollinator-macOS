# AI conversion guide

**Audience: a language model, not a human.**

This file is a self-contained instruction set for converting an existing macOS
post-enrollment setup artifact — a DEPNotify script, a Jamf "Setup Your Mac"
policy, a SplashBuddy config, an Iru (Kandji) Liftoff blueprint, a homegrown
swiftDialog wrapper, or a plain bash provisioning script — into an Enrollinator
`.mobileconfig`.

**How to use it:** paste this whole file into the model, then paste (or attach)
the artifact to be converted — a real script or profile, whole, not a tidied
excerpt — and ask for the conversion. The model returns a `.mobileconfig` you
can save and load straight into the Profile Builder
(`tools/profile-builder.html`) to view and edit. Everything the model needs
about Enrollinator's schema is below; it does not need the rest of the repo, and
it must not invent keys that are not listed here.

---

## 0. Your role and mission

You are converting one **source artifact** (script, plist, JSON, or blueprint)
into one **Enrollinator configuration**: a `.mobileconfig` containing a
`com.enrollinator.app` payload.

Enrollinator is an MDM-agnostic macOS onboarding runner. It is a bash script
started by a LaunchDaemon at first boot, running as **root**, that reads a
config and drives a [swiftDialog](https://github.com/swiftDialog/swiftDialog)
progress window. The config is the entire program: branding, playbooks, steps,
actions, conditions, and branching all live in it. There is no imperative
scripting layer of your own to write — you express the source's logic as data.

Your answer always has three parts, in this order — the **conversion plan**,
the **`.mobileconfig`**, then the **caveats**. §6 defines the exact shape of
each. Never emit only the XML: the plan and the caveats are the part a human can
actually check.

---

## 1. Hard rules

1. **Do not invent keys, action types, or condition types.** The complete set is
   in §3. If a source behaviour has no mapping, say so in the caveats — do not
   approximate it with a key you wish existed.
2. **Everything runs as root unless you say otherwise.** Any command touching a
   user's home directory or preference domain needs
   `RunAsUser` = `$CONSOLE_USER`. Getting this wrong on a `Blocking` step means
   the run waits forever. This is the single most common conversion bug.
3. **Escape XML.** Inside `<string>` elements, `&` → `&amp;`, `<` → `&lt;`,
   `>` → `&gt;`. Shell redirects like `2>/dev/null` become `2&gt;/dev/null`.
   Do not use CDATA — plist consumers do not expect it.
4. **Use absolute paths to binaries** in shell commands (`/usr/bin/grep`,
   `/usr/sbin/installer`). The daemon's `PATH` is not a login shell's.
5. **Preserve the source's order.** Provisioning order encodes real
   dependencies. Do not reorder steps to look tidier; only move something when
   the source itself has an explicit dependency you are making correct, and
   note the move in the plan.
6. **Conditions gate; actions do.** A step's `Action` runs first, then its
   `Conditions` are evaluated AND-style. A condition is a question about the
   machine's state, never a way to get work done.
7. **A step that only checks state uses `Type: noop`** (or no `Action` at all).
   Do not fabricate a no-op shell command like `/usr/bin/true`.
8. **Flag every secret.** API tokens, license keys, passwords, and enrollment
   secrets found in the source must never be copied into the `.mobileconfig` —
   a profile is readable on-device. List them in the caveats and tell the human
   to deliver them another way.
9. **The source file is the authority.** The mapping tables in §5 describe the
   *common* shapes of these tools. Read the actual artifact; where it disagrees
   with the table, the artifact wins.
10. **Say when you are unsure.** A step you guessed at, marked as such, is
    useful. A confident wrong bundle ID is not.

---

## 2. The execution model

Understand this before mapping anything.

```
LaunchDaemon (root, at boot)
  └─ enrollinator.sh
       ├─ waits for a console user
       ├─ reads config (bundled XML, or managed prefs from the .mobileconfig)
       ├─ resolves exactly ONE playbook
       ├─ optional WelcomeScreen  (+ optional playbook picker)
       ├─ walks the playbook's Steps in order, honouring OnSuccess/OnFailure
       ├─ optional add-on picker  (playbooks marked Addon: true)
       └─ writes /var/lib/enrollinator/completed, runs `jamf recon` if present
```

**Per-step flow:**

1. If `Action` is set, run it. Non-zero exit → the step fails (unless
   `ContinueOnFailure`).
2. If `Conditions` is empty → success.
3. Otherwise evaluate all conditions. All pass → success.
4. Any condition fails **and** `Blocking` is `true` → poll every
   `PollIntervalSeconds` — showing a `WaitWindow`, or the `UserPrompt` banner if
   no window is configured — until they pass or `TimeoutSeconds` elapses
   (`0` = forever, and `0` is the default).
5. Any condition fails and `Blocking` is `false` → the step fails, or is
   skipped if `ContinueOnFailure`.

Then routing: `OnSuccess` / `OnFailure` name a step `Id` to jump to.
`OnSuccess: $end` skips to the completion phase. `OnFailure: $next` continues
despite the failure. Empty means "advance to the next step" on success and
"stop the run" on failure. An unrecognised ID logs a warning and falls back to
advancing. A cycle guard halts the run once executed steps exceed twice the
playbook's step count.

**Consequences for your conversion:**

- Steps are a *list with jumps*, not a call graph. There are no loops, no
  variables, no data passed between steps. A source script that computes a
  value in step 3 and uses it in step 7 must have that logic pushed down into a
  single `shell` action, or into a helper script you tell the human to ship.
- There is no rollback. A failed step stops the run (or branches); it does not
  undo earlier steps.
- Progress UI is automatic. Every step is a row in the swiftDialog list. Source
  code that manually paints progress bars, list items, or status text is UI
  plumbing that Enrollinator replaces — delete it rather than porting it.

---

## 3. Schema ground truth

This is the complete, authoritative key set. Keys are CamelCase. Types are
plist types: `string`, `int` (`<integer>`), `bool` (`<true/>` / `<false/>`),
`array`, `dict`.

### 3.1 Top level

| Key | Type | Notes |
|---|---|---|
| `Playbooks` | array of dicts | **Required.** One or more playbooks. |
| `DefaultPlaybook` | string | Name of the playbook to run. Matched exactly, case-sensitively. A name with no match is a fatal error (exit `2`). |
| `Branding` | dict | Title, subtitle, logo, colour, window size. |
| `HardwareInfo` | dict | Device-info panel beside the step list. |
| `Help` | dict | `?` button with IT contact details. |
| `WelcomeScreen` | dict | Pre-run dialog, optional playbook picker. |
| `AddonPicker` | dict | Customises the post-run add-on picker. |
| `AllowClose` | bool | `true` → enable a Done button instead of auto-quitting. Default `false`. |
| `TestMode` | bool | `true` → evaluate conditions but skip `shell`, `package`, and `wait` actions. `dialog` actions still run. Blocking steps still open their UI, with the timeout capped at 5s. Default `false`. |
| `JamfRecon` | bool | `false` → skip the automatic `jamf recon` after a successful run. Default `true`, and only when the jamf binary exists. |
| `InstallSwiftDialog` | bool | `true` → download and install swiftDialog if missing. Default `false`. Prefer deploying swiftDialog as a managed package: this needs `api.github.com` reachable at enrollment time, which is often exactly when it is not. |
| `SwiftDialogTeamID` | string | Developer ID team the downloaded swiftDialog must be signed by. Default `PWA5E9TQ59`. Only relevant with `InstallSwiftDialog`. |
| `BlurScreen` | bool | Blur the desktop behind the UI. Default `false`. |
| `AlwaysOnTop` | bool | Keep the window above others. Default `true`. |

### 3.2 `Branding`

`Title`, `Subtitle` (strings, `{token}` substitution), `Logo` (absolute path,
`https://` URL, or `SF=symbol.name[,animation=type]`), `Banner` (path or URL),
`AccentColor` (hex, e.g. `#0A84FF`), `TitleFontSize` (int),
`MessageFontSize` (int), `WindowWidth` (int, default `720`),
`WindowHeight` (int, default `560`), `QuitKey` (single char, replaces ⌘Q).

**Tokens** usable in `Title`/`Subtitle` (and in `HardwareInfo` `text:` lines):
`{console_user}`, `{full_name}`, `{hostname}`, `{computer_name}`,
`{serial_number}`, `{model}`, `{model_name}`, `{os_version}`, `{ip_address}`,
`{uuid}`.

### 3.3 `HardwareInfo`

`Enabled` (bool), `Fields` (array of string, rendered top to bottom). Each
entry is either a field name (`console_user`, `full_name`, `hostname`,
`computer_name`, `serial_number`, `model`, `model_name`, `os_version`,
`ip_address`, `uuid`), or `text:<body>` for a literal line with tokens
expanded, or `spacer` for a blank line.

### 3.4 `Help`

`Enabled` (bool), `Title` (string, default "Need help?"), `Message` (markdown),
`Contacts` (array of dicts, each `Label` / `Detail` / optional `URL`).

### 3.5 `WelcomeScreen`

`Enabled` (bool, default `false`), `Title`, `Message` (markdown), `Button`
(default `"Get Started"`), `DeferButton` (empty hides it; deferring exits
cleanly so the daemon re-triggers), `MaxDeferrals` (int), `Logo`,
`TitleFontSize`, `MessageFontSize`, `Width` (default `600`), `Height`
(default `450`), `Slideshow` (array — see §3.9), `Video` (path or URL; wins
over `Slideshow`; swiftDialog hides the message body when a video is present),
`VideoAutoplay` (bool), `Blur` (bool), `AlwaysOnTop` (bool), and
`PlaybookPicker` (dict).

`PlaybookPicker`: `Enabled` (bool), `Playbooks` (array of string — names must
match `Playbooks[*].Name` exactly), `Title` (default `"Choose your setup"`),
`Message`, `Icon`, `HideIcon` (bool), `Width` (default `520`), `Height`
(default `300`). The selection overrides `DefaultPlaybook` for that run only,
and is skipped when the user defers.

### 3.6 `AddonPicker`

`Title` (default `"Optional extras"`), `Message`, `Icon`, `TitleFontSize`,
`MessageFontSize`, `InstallButton` (default `"Install"`), `SkipButton`
(default `"Not now"`), `Width` (default `500`), `Height` (default `360`).
All nine are overridable at runtime by `ENROLLINATOR_ADDON_*` environment
variables, which take precedence over the dict.

### 3.7 Playbook

| Key | Type | Notes |
|---|---|---|
| `Name` | string | Must be unique. Referenced by `DefaultPlaybook` and `--profile`. |
| `Steps` | array of dicts | In execution order. |
| `Description` | string | Free-form; not shown in the main UI. |
| `Addon` | bool | `true` → excluded from automatic selection, offered in the post-run checkbox picker instead. |
| `TestMode` | bool | Forces test mode for this playbook. Precedence: `--test` > top-level `TestMode` > playbook `TestMode`. |

**`Selector` is removed.** Older configs had a `Selector` dict
(`HostnameRegex`, `ModelIdentifierGlob`, …). The runtime ignores it silently.
Never emit one. There is **no automatic per-machine playbook selection** —
nothing inspects hostname, model, serial, or OS version. To vary the playbook
across a fleet, either scope a different `.mobileconfig` per MDM smart group,
or ship one config and let the welcome screen's picker ask the user. If the
source artifact branches on machine attributes, this is the most important
thing to raise in your caveats (see §7).

Playbook resolution order: `--profile` → `DefaultPlaybook` → the only playbook
if exactly one exists → the first playbook if `PlaybookPicker.Enabled` →
otherwise exit `2`.

Add-on playbooks: steps whose `Id` already ran in the main playbook are skipped
automatically, so shared IDs never double-install. A playbook named as the
default is left out of the picker even if marked `Addon: true`.

### 3.8 Step

| Key | Type | Notes |
|---|---|---|
| `Id` | string | Internal identifier. Required in practice — branching and add-on dedup both key off it, and logs are unreadable without it. |
| `Name` | string | The row shown in the swiftDialog list. |
| `Icon` | string | Absolute path, `https://` URL, or `SF=symbol.name[,animation=type]`. Animations: `pulse`, `bounce`, `variableColor`, `appear`, `disappear`, `rotate`, `breathe` (macOS 14+), `wiggle` (macOS 14+). |
| `Description` | string | Reserved for future use. |
| `Action` | dict | Optional; runs before conditions. |
| `Conditions` | array of dicts | Optional; AND-style. |
| `Blocking` | bool | `true` → poll failing conditions instead of failing. |
| `PollIntervalSeconds` | int | Default `5`. |
| `TimeoutSeconds` | int | Blocking timeout. `0` = no timeout, and that is the default. |
| `ContinueOnFailure` | bool | Mark failed, keep going. |
| `OnSuccess` | string | Step `Id`, or `$end`. |
| `OnFailure` | string | Step `Id`, or `$next`. Takes precedence over `ContinueOnFailure` for routing. |
| `UserPrompt` | string | Legacy one-line banner while blocking. Ignored when `WaitWindow` is set. |
| `WaitWindow` | dict | Secondary window shown while the step blocks. |

`WaitWindow`: `Title` (defaults to the step `Name`), `Message` (markdown; falls
back to `UserPrompt`), `Slideshow`, `Video`, `VideoAutoplay`, `TitleFontSize`,
`MessageFontSize`, `Width` (default `520`), `Height` (default `420`), `Blur`,
`AlwaysOnTop`.

### 3.9 Slideshow entries

Wherever a `Slideshow` array appears (`WelcomeScreen`, `WaitWindow`, `dialog`
action), each entry is either a plain `<string>` path/URL, or a dict with
`Image`, `Title`, and `Message`. Multiple frames cycle (or advance on click, on
the welcome screen).

### 3.10 Actions (`Action.Type`)

Exactly five. There are no others.

**`shell`** — `Command` (string, required; run via `/bin/sh -c`),
`RunAsUser` (`$CONSOLE_USER` or a literal username; runs via
`launchctl asuser` + `sudo -H -u`, so `HOME` and the preference domain are the
target user's), `TimeoutSeconds` (default `300`).

**`package`** — `Path` (absolute path to a `.pkg`, required), `Target`
(default `/`), `TimeoutSeconds` (default `600`).

**`wait`** — `DurationSeconds` (int, required). Sleep, then succeed. Use it to
let a freshly-kicked daemon settle before the next step's conditions fire.

**`dialog`** — `Title` (required), `Message` (required, markdown), `Buttons`
(array of 1–3 labels, default `["OK"]`), `ExpectedButton` (must be one of
`Buttons`; defaults to the first), `Width` (default `520`), `Height`
(default `300`), plus `TitleFontSize`, `MessageFontSize`, `Blur`,
`AlwaysOnTop`, `Slideshow`, `Video`, `VideoAutoplay`. The step succeeds **iff**
the user clicks `ExpectedButton` — this is the acknowledgement gate (EULA,
policy read-and-accept).

**`noop`** — succeeds immediately. For steps that are pure condition checks.

Steps may also set `Action.Blur` (bool) to blur the desktop for that step.

### 3.11 Conditions (`Type`)

Exactly six. There are no others.

**`shell`** — `Command` (required; exit 0 = pass), `RunAsUser`,
`TimeoutSeconds` (default `15`). Without `RunAsUser` this runs as **root**;
anything reading `~` or a per-user domain will inspect `/var/root` and can
never pass.

**`app_installed`** — `BundleId` (resolved via `mdfind`) **or** `Path` (direct
path to an `.app`, skipping Spotlight); optional `MinVersion` (dotted, compared
to `CFBundleShortVersionString`). Prefer `Path` when you know it: Spotlight
indexing is not guaranteed to be warm during first-boot provisioning.

**`default_browser`** — `BundleId` (required). Reads the console user's
LaunchServices prefs.

**`file_exists`** — `Path`, `Kind` (`file`, `directory`, or `any` — default).

**`profile_installed`** — `Identifier` (required; a `PayloadIdentifier` looked
for in `profiles list -all`).

**`process_running`** — `Name` (required; matched with `pgrep -x`, so it must
be the exact process name), `MinimumCount` (default `1`).

### 3.12 Runtime facts worth knowing

- Installed at `/usr/local/enrollinator/`; LaunchDaemon label
  `com.enrollinator.app`; logs at `/var/log/enrollinator.log` (plus
  `.stdout.log` / `.stderr.log`); completion flag at
  `/var/lib/enrollinator/completed`.
- Convention for shipped assets and packages: `/Library/Enrollinator/assets/`
  and `/Library/Enrollinator/packages/`. Anything you reference by absolute
  path must be delivered there by some other means — say so in the caveats.
- Flags: `--config PATH` (a `.mobileconfig`), `--xml PATH` (a bare plist),
  `--profile NAME`, `--domain DOMAIN`, `--test`, `--force`, `--dry-run`,
  `--skip-root-check`.

---

## 4. The conversion procedure

Work in this order. Do not start writing XML until step 4.

### Step 0 — Ask, only for what the source cannot tell you

You are in a conversation, so ask before guessing the few things a source file
genuinely does not contain — but ask once, briefly, and only for these:

- the org's reverse-DNS identifier (for the `Payload*` fields);
- branding the source lacks — logo/banner path or URL, accent colour — if you
  want more than the defaults;
- whether app installs the source delegated to an MDM should **stay** with the
  MDM (verify-only steps) or become `package` actions you point at shipped pkgs.

Everything else — bundle IDs, process names, icons, timeouts — you assume with a
sensible default and flag in the caveats (rule 10). Do not hold up the whole
conversion waiting on those; a complete draft the human corrects beats a
questionnaire.

### Step 1 — Inventory

Read the source top to bottom and list every discrete unit of work. One line
per unit: what it does, what it needs first, and whether it can fail
harmlessly. Include the things that are easy to miss: pre-flight checks,
waits and sleeps, reboots, `caffeinate`, cleanup at the end.

### Step 2 — Classify each unit

Put every unit in exactly one bucket:

| Bucket | Becomes |
|---|---|
| **UI plumbing** — progress bars, status text, window setup, list painting | Nothing. Enrollinator does this. Delete it. |
| **Install** — a pkg, an app, an MDM-triggered install | A step with a `package` or `shell` action, plus an `app_installed` / `file_exists` condition to verify it. |
| **Configure** — defaults writes, symlinks, config files | A step with a `shell` action. Check whether it is per-user (`RunAsUser`). |
| **Verify** — a check with no side effects | A step with `Action.Type: noop` (or no action) and conditions. |
| **Gate** — wait for the human to do something | A `Blocking` step with conditions and a `WaitWindow`. |
| **Acknowledge** — the user must read and accept something | A step with a `dialog` action and an `ExpectedButton`. |
| **Branch** — `if`/`case` on a machine or user attribute | Either conditions on a step plus `OnSuccess`/`OnFailure`, or separate playbooks. See §7. |
| **Won't convert** | The caveats list. Do not fake it. |

### Step 3 — Decide the playbook shape

- One linear flow → one playbook.
- Distinct personas (Engineering / Design / Standard) that the source picks
  between → one playbook each, plus either a scoped profile per group or
  `WelcomeScreen.PlaybookPicker`.
- Optional extras the user chooses → a playbook with `Addon: true`.
- Small conditional divergence inside one flow → keep one playbook and use
  `OnSuccess` / `OnFailure`.

Set `DefaultPlaybook` unless there is exactly one playbook.

### Step 4 — Write the steps

For each unit, in source order:

- Give it a stable, kebab-case `Id` (`install-chrome`, `zscaler-signin`).
  IDs are the branch targets and the add-on dedup key; keep them meaningful.
- Write a `Name` the end user will read on their first day. "Installing Google
  Chrome", not `install_chrome_pkg_v2`.
- Choose an `Icon` — an SF Symbol is usually right (`SF=globe`,
  `SF=lock.shield`, `SF=shippingbox`, `SF=checkmark.seal`).
- Move the work into `Action`, the proof into `Conditions`.
- Set `ContinueOnFailure: true` for anything the source treated as best-effort
  (a `|| true`, an ignored exit code, an "optional" comment).
- Set a `TimeoutSeconds` on every `Blocking` step unless the source genuinely
  intends to wait forever. The default is `0` — forever — and an unattended
  first-boot Mac stuck on a blocked step is a support ticket.

### Step 5 — Write the chrome

`Branding` from the source's window title / logo / colours. `WelcomeScreen` if
the source had an intro screen. `Help` if the source displayed IT contact
details anywhere. `HardwareInfo` if it showed serial numbers or asset info.

### Step 6 — Wrap and check

Wrap in the `.mobileconfig` skeleton (§6), then run the checklist in §8.

---

## 5. Source-specific mapping

Key names and command spellings below were checked against each tool's own
documentation (sources in §11). They are still only the *stock* shape of each
tool: DEPNotify and Setup Your Mac in particular are forked and hand-edited at
almost every site that runs them. Read the real artifact; where it differs from
this section, the artifact wins.

### 5.1 DEPNotify

DEPNotify is driven by writing command lines to a control file (commonly
`/var/tmp/depnotify.log`). The wrapper script does the actual work; DEPNotify
only draws.

| Source pattern | Enrollinator |
|---|---|
| `Command: MainTitle:` / `MainText:` | `Branding.Title` / `Branding.Subtitle` |
| `Command: Image:` / logo path | `Branding.Logo` |
| `Command: Determinate:` and the step counter | Nothing — the step list is the progress bar |
| `Status: <text>` before each unit of work | The `Name` of the step doing that work |
| The command that follows each `Status:` | That step's `Action` |
| `Command: MainText:` mid-run asking the user to act | A `Blocking` step with a `WaitWindow` |
| `Command: ContinueButton:` | A final acknowledgement — a `dialog` action, or `AllowClose: true` if it is the last thing in the run |
| `Command: ContinueButtonEULA:` | A `dialog` action whose `ExpectedButton` is the accept button — this is the read-and-accept gate |
| `ContinueButtonRegister:` / `Web:` / `Logout:` / `Restart:` | Not converted — registration forms, logout, and restart have no equivalent (§7) |
| `Command: Alert:` | A `dialog` action |
| `Command: Quit:` / `Command: Restart:` | End of run; a reboot is a caveat (§7) |
| The registration/plist-reading plumbing | Not converted — flag it |

A DEPNotify wrapper is usually the cleanest conversion: each `Status:` line is
one step, and the command between two `Status:` lines is that step's action.

### 5.2 Jamf "Setup Your Mac" style policy JSON

**The input is almost always the whole `Setup-Your-Mac-via-Dialog.bash`
script — thousands of lines — not a tidy JSON file.** The JSON you want is
embedded in it as single-quoted heredoc-style variables. Find these first
(names confirmed against the stock script; forks rename freely, so search, don't
assume a line number):

| In the script | Holds | Converts to |
|---|---|---|
| `policyJSON='…'` | the `steps` array (each step's `listitem`, `icon`, `progresstext`, `trigger_list`) | the playbook's `Steps` — see the field table below |
| `welcomeJSON='…'` | the welcome dialog: title, message, an `infobox`, and a `selectItems` list of dropdowns | `WelcomeScreen` (title/message), `HardwareInfo` (the `infobox`), and `PlaybookPicker` (see the `Configuration` selector below) |
| `symConfiguration=…` fed by a `Configuration` dropdown in `welcomeJSON` | which named preset runs (stock values: `Required`, `Recommended`, `Complete` — forks differ) | **one playbook per preset**, wired to `WelcomeScreen.PlaybookPicker` so the user picks the same way. This is the single biggest structural mapping in a SYM conversion. |
| `completionActionOption` (script param `$7`, default `"Restart Attended"`; values include `Restart*`, `Shut Down*`, `Log Out*`, `Sleep`, `Quit`, `wait`) | what happens when the run ends | a reboot/logout is a §7 caveat; `Quit`/`wait` ≈ `AllowClose: true` |
| `welcomeDialog` (script param `$6`: `userInput` / `video` / `messageOnly` / `false`) | whether and how the welcome screen shows | `WelcomeScreen.Enabled`, and `Video` when it is `video` |
| `overlayicon`, `bannerImage`, `welcomeBannerImage` | branding art (often a Jamf Self Service URL or a hosted URL) | `Branding.Logo` / `Branding.Banner` — a Jamf-hosted URL may not be reachable at enrollment; flag it |
| The `helpmessage` / `welcomeMessage` text | support contacts, hardcoded **inside the strings** — stock SYM has no `supportTeam*` variables | `Help` (pull the phone/email/KB out of the prose into `Contacts`) |
| Other Jamf params (`$4` scriptLog, `$5` debugMode, `$8` requiredMinimumBuild, `$9` outdatedOsAction) | operational knobs, not onboarding steps | mostly **not converted**; `requiredMinimumBuild`/`outdatedOsAction` are OS-gate logic you'd reproduce as a `shell` condition only if you actually want the gate |

Once you have `policyJSON`, each step maps like this:

| Source field (typical name) | Enrollinator |
|---|---|
| `listitem` / step name | `Name` |
| `icon` (a hash of a Jamf-hosted icon) | `Icon` — the hash is meaningless outside Jamf's icon server; substitute an SF Symbol or a reachable `https://` URL and flag it |
| `progresstext` | Fold into `Name`, or use it as the `WaitWindow.Message` when the step blocks |
| `trigger_list` entry's `trigger` (a Jamf custom event) | `shell` action: `/usr/local/bin/jamf policy -event <trigger>` |
| A `trigger_list` with **several** entries | `trigger_list` is an array, so one `listitem` can fire several policies. Either chain them with `&amp;&amp;` in one `shell` action, or split into one step per trigger — splitting gives the user better progress detail |
| `validation` = a path | `file_exists`, or `app_installed` with `Path` |
| `validation` = `None` | No conditions; consider `ContinueOnFailure: true` |
| `validation` = `Local` or `Remote` | A `shell` condition that reproduces the check explicitly. `Remote` runs a separate Jamf policy to validate; you must find that policy's script and inline its logic |
| `validation` = `Recon` | Nothing — Enrollinator runs `jamf recon` automatically after a successful run (`JamfRecon`, default `true`). Drop the step |
| Configuration/branding block at the top | `Branding` + `WelcomeScreen` |

Note in the caveats that `jamf policy -event` keeps a Jamf dependency: the
resulting config is Enrollinator-shaped but not yet MDM-agnostic. Replacing
each trigger with a `package` action pointed at a deployed pkg is the
follow-up that makes it portable.

### 5.3 Installomator invocations

`installomator.sh <label> [options]` maps to a `shell` action:

```xml
<key>Action</key>
<dict>
    <key>Type</key><string>shell</string>
    <key>Command</key>
    <string>/usr/local/Installomator/Installomator.sh googlechromepkg NOTIFY=silent BLOCKING_PROCESS_ACTION=ignore</string>
    <key>TimeoutSeconds</key><integer>900</integer>
</dict>
```

Notes:

- **The path is not standardised.** `/usr/local/Installomator/Installomator.sh`
  is the common deployment location, not a documented default. Copy whatever
  path the source actually uses, and list it in the caveats as a prerequisite.
- **Raise `TimeoutSeconds`.** Installomator downloads before it installs; the
  `shell` default of 300s is not enough for a large app on a slow first-boot
  network. 900s is a reasonable floor.
- **Silence its UI.** `NOTIFY=silent` stops Installomator's own notifications
  fighting the Enrollinator window. Valid `NOTIFY` values are `success`
  (default), `silent`, and `all`.
- **Mind `BLOCKING_PROCESS_ACTION`.** The default is `tell_user`, which prompts
  and waits — during unattended first-boot provisioning that stalls the step
  until its timeout. `ignore` is the right choice on a fresh Mac where nothing
  is open yet. Other valid values: `silent_fail`, `prompt_user`,
  `prompt_user_then_kill`, `prompt_user_loop`, `tell_user_then_kill`, `kill`.
- **Always pair with a condition.** Installomator can fail quietly; an
  `app_installed` condition turns that into a visibly failed step.

### 5.4 Iru (formerly Kandji) — Liftoff, blueprints, custom scripts

| Source | Enrollinator |
|---|---|
| Liftoff screen branding | `Branding` + `WelcomeScreen` |
| Liftoff "dependencies" the user waits on | `Blocking` steps with `WaitWindow` |
| Blueprint library items (Auto Apps, custom apps) | Either leave them to the MDM and use a verify-only step (`app_installed`), or convert to a `package` action if you ship the pkg |
| Custom Script library items (audit/enforce) | The audit half → `shell` condition; the enforce half → `shell` action |
| Blueprint assignment rules | Nothing — Enrollinator has no per-machine selection. Scope the profile per group instead (§7) |

The natural Iru conversion often keeps app installs in the MDM and uses
Enrollinator purely for the *visible* onboarding: welcome, verification, and
user-action gates.

### 5.5 SplashBuddy

SplashBuddy watches an install log and shows a list of applications. Its
preferences live in the `io.fti.SplashBuddy` domain (commonly
`/Library/Preferences/io.fti.SplashBuddy.plist`), and its assets under
`/Library/Application Support/SplashBuddy/`.

| Source | Enrollinator |
|---|---|
| `applicationsArray` entry (`displayName`, `description`, `iconRelativePath`) | One step: `Name`, `Icon` |
| `packageName` | An `app_installed` or `file_exists` condition — note this is a *package* name, not a bundle ID, so you must map it to the app it installs |
| `canContinue: false` | The step is required: make it `Blocking`, or leave `ContinueOnFailure` unset so a failure stops the run |
| `canContinue: true` | `ContinueOnFailure: true` |
| The install mechanism (Jamf policies triggered elsewhere) | A `package` or `shell` action, or a verify-only step if the MDM still installs it |
| The final "all done" screen | `AllowClose: true`, or a final `dialog` action |

SplashBuddy is *passive* — it watches installs someone else started. If the
installs are still MDM-driven, convert each entry into a verify-only step
(`noop` action + condition), and consider making them `Blocking` with a
timeout so the window waits for the MDM the way SplashBuddy did.

### 5.6 Plain bash provisioning script

| Source | Enrollinator |
|---|---|
| A function or a commented block | One step |
| `installer -pkg X -target /` | `package` action |
| `curl … && installer …` | `shell` action, or split: download step + `package` step |
| `sudo -u "$USER" defaults write …` | `shell` action with `RunAsUser: $CONSOLE_USER` |
| `until [ condition ]; do sleep 5; done` | `Blocking` step + `shell` condition + `PollIntervalSeconds` |
| `if ! <check>; then <fix>; fi` | Step with the fix as `Action` and the check as a condition; or two steps wired with `OnFailure` |
| `|| true`, ignored exit codes | `ContinueOnFailure: true` |
| `exit 1` on a fatal error | Leave `OnFailure` empty — the default is to stop |
| `sleep N` between units | `wait` action with `DurationSeconds` |
| `echo`/`logger` progress lines | Nothing — the step list is the log |
| Trap/cleanup handlers | Not converted — flag it |

### 5.7 Homegrown swiftDialog wrapper

The script's own dialog command-file writes are all UI plumbing: delete them
and let Enrollinator own the window. Keep only the work between the writes.
`--listitem` entries become steps, `--infobox` content becomes `HardwareInfo`,
`--helpmessage` becomes `Help`, and window geometry becomes `Branding`.

### 5.8 Octory / other watcher-style tools

Same shape as SplashBuddy: the tool watches, something else installs. Convert
each watched item into a verify-only step, and decide per item whether it
should block.

### 5.9 When the source is itself a configuration profile

Sometimes the input is not a script but another `.mobileconfig` / `.plist`.
Decide which of two kinds it is before converting:

- **Another onboarding tool's config** — an Octory `.plist`, an Iru/Kandji
  export, a swiftDialog wrapper's plist. Treat it as that tool (§5.4–5.8): read
  the payload, pull out the steps and branding, and rebuild them as an
  Enrollinator playbook.
- **A generic app/settings profile** — payloads like `com.apple.ManagedClient`,
  a `defaults` domain, a Wi-Fi/VPN/certificate payload. **This is not an
  onboarding flow at all**, and it is not Enrollinator's job to re-deliver it.
  Say so plainly, then offer the two things Enrollinator *can* do with it:
  - **Verify it landed** — a `profile_installed` condition keyed on the
    profile's `PayloadIdentifier`, so the run confirms the MDM delivered it.
  - **Reproduce a specific setting** — only if the source is a plain preferences
    payload and the user wants Enrollinator to set it: a `shell` action running
    `defaults write` (with `RunAsUser: $CONSOLE_USER` for a per-user domain).
    Do not try to reproduce Wi-Fi, VPN, certificate, or FileVault payloads this
    way — those must stay with the MDM.

  Do not wrap a whole app profile's keys into the `com.enrollinator.app`
  schema; the schema in §3 is the only thing Enrollinator reads, and unrelated
  payload keys mean nothing to it.

---

## 6. Output contract

Your answer has three parts, in this exact order. §9 shows a complete example of
all three. Never emit fewer than three.

### Part 1 — Conversion plan

A table with one row per unit of work from your §4 inventory, in source order.
Use these columns exactly:

| # | Source unit | Step `Id` | Realized as | Notes |
|---|---|---|---|---|
| 1 | what the source does | the `Id` you gave it | the action/condition/branch shape | anything the human should know |

Rules for the table:

- **Every** inventory unit gets a row — nothing is dropped silently.
- A unit you did not convert gets a row with the `Id` column blank and
  `Realized as` = `not converted`, and a `Notes` cell pointing at the §7 reason.
- A unit that became UI plumbing you deleted also gets a row, so the human can
  see you saw it.

### Part 2 — The `.mobileconfig`

Emit one complete file. Replace `com.example` with the organisation's
reverse-DNS identifier, and generate a fresh UUID for every payload
(`uuidgen`-shaped, uppercase).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadType</key><string>Configuration</string>
    <key>PayloadVersion</key><integer>1</integer>
    <key>PayloadIdentifier</key><string>com.example.enrollinator</string>
    <key>PayloadUUID</key><string>REPLACE-WITH-A-FRESH-UUID</string>
    <key>PayloadDisplayName</key><string>Enrollinator</string>
    <key>PayloadDescription</key><string>macOS onboarding flow driven by Enrollinator.</string>
    <key>PayloadOrganization</key><string>Example, Inc.</string>
    <key>PayloadScope</key><string>System</string>

    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadType</key><string>com.enrollinator.app</string>
            <key>PayloadIdentifier</key><string>com.example.enrollinator.config</string>
            <key>PayloadUUID</key><string>REPLACE-WITH-A-FRESH-UUID</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>PayloadDisplayName</key><string>Enrollinator configuration</string>

            <!-- ===== Everything from §3 goes here ===== -->
            <key>Branding</key>
            <dict>
                <key>Title</key><string>Welcome, {console_user}!</string>
                <key>Subtitle</key><string>We're getting your Mac ready.</string>
                <key>AccentColor</key><string>#0A84FF</string>
            </dict>

            <key>DefaultPlaybook</key><string>Standard</string>
            <key>Playbooks</key>
            <array>
                <dict>
                    <key>Name</key><string>Standard</string>
                    <key>Steps</key>
                    <array>
                        <!-- steps -->
                    </array>
                </dict>
            </array>
        </dict>

        <!-- Optional but recommended: stops the user disabling the daemon in
             System Settings → Login Items & Extensions. -->
        <dict>
            <key>PayloadType</key><string>com.apple.servicemanagement</string>
            <key>PayloadIdentifier</key><string>com.example.enrollinator.servicemanagement</string>
            <key>PayloadUUID</key><string>REPLACE-WITH-A-FRESH-UUID</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>PayloadDisplayName</key><string>Enrollinator background item</string>
            <key>Rules</key>
            <array>
                <dict>
                    <key>RuleType</key><string>LabelPrefix</string>
                    <key>RuleValue</key><string>com.enrollinator</string>
                </dict>
            </array>
        </dict>
    </array>
</dict>
</plist>
```

If the human asked for a bare plist instead (for `--xml` / a pkg-bundled
config), emit only the inner schema — `Branding`, `Playbooks`, and the rest —
at the top level of the plist, with no `PayloadContent` wrapping.

### Part 3 — Caveats

A bullet list. Write one bullet for each of:

- every assumption you made (a default you chose, an order you fixed);
- every guess (a bundle ID, a process name, an icon, a timeout) — say *why* it
  is a guess and how the human can confirm it;
- every asset referenced by absolute path that the config does not itself ship
  (pkgs, logos, banners, videos, third-party binaries);
- everything from §7 that appeared in the source.

Each bullet names the specific thing and states what the human must do before
deploying. A caveats list that just says "verify everything" is not acceptable —
be concrete, as the §9 example is.

### Loading your output into the Profile Builder

The human's next move is almost always to open your `.mobileconfig` in the
Profile Builder (`tools/profile-builder.html`) to view and edit it. Produce
output that imports cleanly, and tell them how:

- **The importer needs a `com.enrollinator.app` payload.** A full
  `.mobileconfig` must carry it inside `PayloadContent` (the §6 skeleton does);
  a bare plist must have `Playbooks` at the top level. Anything else is rejected
  with "Unrecognized file". This is why you must not bury the config in some
  other payload type.
- **The builder silently drops what it does not recognise.** It rebuilds each
  step from its own template, so a step key that is not in §3 vanishes on
  import — no error, just missing data. An unknown `Action`/condition `Type`
  survives but cannot be edited in the UI. Both are invisible failures. Sticking
  to §3 is what makes the round-trip lossless; this is a second, stronger reason
  behind hard rule 1.
- **`JamfRecon` is the one documented key the builder cannot see.** It is a real
  runtime key (§3.1) but the builder neither imports nor re-exports it — a human
  who round-trips the file through the builder will lose it. If you set
  `JamfRecon: false`, call that out in the caveats so they re-add it (or manage
  recon another way).
- **Deliver it as a file, not a wall of text.** Emit the `.mobileconfig` as one
  fenced block the human can copy, tell them to save it as e.g.
  `enrollinator.mobileconfig`, and then either drag it onto the builder or use
  its **Import** control. Icons you left as `SF=` guesses can be swapped with
  the builder's **SF** picker; say so when you guessed one.

---

## 7. What does not convert — always flag these

Put each of these in the caveats with a concrete recommendation. Never
silently drop one, and never approximate one with a step that pretends.

| Source behaviour | Why | Say this instead |
|---|---|---|
| **Per-machine branching** (hostname regex, model glob, serial prefix, AD group, OS version) | There is no `Selector` and no automatic selection. | Scope a different `.mobileconfig` per MDM smart group, or use `WelcomeScreen.PlaybookPicker` and let the user choose. A `shell` condition plus `OnFailure` handles small divergences inside one flow. |
| **Mid-run reboot** | The run does not survive a restart; the completion flag governs re-runs. | Move the reboot to the end, or make it a final step, and note that anything after it will not run. |
| **Prompting the user for input** (name, department, asset tag) | No text-entry action exists — `dialog` returns which button was clicked, nothing more. | Collect it in the MDM's enrollment flow, or keep a small helper script and invoke it from a `shell` action. |
| **Passing values between steps** | Steps share no state. | Collapse the producer and consumer into one `shell` action, or write to a file in one step and read it in the next. |
| **Loops over a list** | No loop construct. | Unroll into explicit steps, or put the loop inside one `shell` action. |
| **Secrets** (API tokens, license keys, enrollment secrets) | A profile is readable on-device. | Deliver via the MDM's secure mechanism or a pkg payload; reference the file from a `shell` action. |
| **Per-user LaunchAgents / login items** | Enrollinator runs as root at boot, before a full user session in the general case. | Ship them in the pkg; use a `shell` action with `RunAsUser` only to load them. |
| **FileVault key escrow, MDM commands, Apple Business Manager calls** | Not Enrollinator's job. | Leave with the MDM; verify with `profile_installed` or a `shell` condition if you want the run to check. |
| **Assets referenced by absolute path** (logos, banners, pkgs, videos) | The config references them; it does not ship them. | List every path and tell the human to deliver them, conventionally under `/Library/Enrollinator/`. |
| **Jamf icon IDs, MDM-internal identifiers** | Not resolvable outside that MDM. | Substitute an SF Symbol or a hosted URL and mark it as a guess. |
| **`caffeinate` / sleep prevention** | Not a config key. | Handle it in the LaunchDaemon or a first `shell` action, and say which you chose. |

---

## 8. Self-check before you answer

Run through this list explicitly. If a line fails, fix it before answering.

**Validity**

- [ ] Every key you used appears in §3. No invented keys.
- [ ] Every `Action.Type` is one of `shell`, `package`, `wait`, `dialog`, `noop`.
- [ ] Every condition `Type` is one of `shell`, `app_installed`,
      `default_browser`, `file_exists`, `profile_installed`, `process_running`.
- [ ] Every `<key>` has exactly one value element after it; arrays contain
      `<dict>`/`<string>` as the schema requires.
- [ ] `&`, `<`, `>` are escaped inside every `<string>`.
- [ ] Booleans are `<true/>`/`<false/>`, integers are `<integer>`, and no
      integer is quoted as a string.
- [ ] Every payload has a distinct `PayloadUUID`.

**Correctness**

- [ ] `DefaultPlaybook` names a playbook that exists, spelled exactly.
- [ ] Every `OnSuccess` / `OnFailure` names a real step `Id`, or `$end` / `$next`.
- [ ] Step `Id`s are unique within a playbook; IDs shared across playbooks are
      deliberate (they are the add-on dedup key).
- [ ] Every command reading `~`, `defaults read <domain>`, or LaunchServices
      has `RunAsUser` set to `$CONSOLE_USER`.
- [ ] Every `Blocking` step has a `TimeoutSeconds`, or a stated reason not to.
- [ ] Every `Blocking` step has a `WaitWindow` or `UserPrompt` that tells the
      user exactly where to click.
- [ ] Every install step has a condition proving it worked.
- [ ] Long-running commands have a `TimeoutSeconds` above the 300s default.
- [ ] Shell commands use absolute binary paths.
- [ ] `ExpectedButton` on every `dialog` action is one of its `Buttons`.
- [ ] No `Selector` key anywhere.
- [ ] No secrets in the file.

**Completeness**

- [ ] Your answer has all three parts from §6, in order: plan, `.mobileconfig`,
      caveats.
- [ ] Every unit from the §4 inventory appears as a row in the plan, either as a
      step or as an explicit non-conversion with a reason.
- [ ] Every absolute path referenced is listed in the caveats as something the
      human must deliver.
- [ ] Every guess (bundle ID, process name, icon, timeout) is marked as a guess.

**Then tell the human how to verify.** These are the commands that check your
work, and you should quote them:

```bash
plutil -lint /path/to/your.mobileconfig
```

```bash
sudo /usr/local/enrollinator/enrollinator.sh --config /path/to/your.mobileconfig --dry-run
```

```bash
sudo /usr/local/enrollinator/enrollinator.sh --config /path/to/your.mobileconfig --test --force
```

`--dry-run` prints the resolved plan without executing. `--test` walks the real
UI and evaluates conditions but skips `shell`, `package`, and `wait` actions,
capping blocking timeouts at 5 seconds — it is the rehearsal. Also mention the
Profile Builder (`tools/profile-builder.html`, opened in any browser): it
imports the generated `.mobileconfig` and previews the whole run on a mock
desktop, which is the fastest way for a human to sanity-check your output.

---

## 9. Worked example

**Source** — a fragment of a DEPNotify wrapper script:

```bash
echo "Status: Installing Google Chrome" >> "$DEP_LOG"
/usr/local/bin/jamf policy -event install-chrome

echo "Status: Installing company VPN" >> "$DEP_LOG"
/usr/sbin/installer -pkg /tmp/ZScaler.pkg -target / || true

echo "Command: MainText: Please sign in to ZScaler from the menu bar." >> "$DEP_LOG"
until /sbin/ifconfig | grep -qE '^utun[0-9]+:.*UP'; do sleep 5; done

echo "Status: Setting default browser" >> "$DEP_LOG"
sudo -u "$CONSOLE_USER" /usr/local/bin/defaultbrowser chrome
```

**Part 1 — Plan**

| # | Source unit | Step `Id` | Realized as | Notes |
|---|---|---|---|---|
| 1 | `jamf policy -event install-chrome` | `install-chrome` | `shell` action + `app_installed` | Keeps the Jamf dependency; flagged |
| 2 | `installer -pkg ZScaler.pkg` + `\|\| true` | `install-zscaler` | `package` action, `ContinueOnFailure` | `/tmp` path replaced with `/Library/Enrollinator/packages/` |
| 3 | `until … utun … UP` | `zscaler-signin` | `Blocking` + `WaitWindow` | Timeout added — source waited forever |
| 4 | `sudo -u … defaultbrowser chrome` | `chrome-default` | `shell` action, `RunAsUser` + `default_browser` condition | |
| — | `Status:` / `MainText:` writes | — | not converted | UI plumbing; Enrollinator owns the window |

**Part 2 — The `.mobileconfig`** (steps only here; the wrapper is as in §6 Part 2):

```xml
<dict>
    <key>Id</key><string>install-chrome</string>
    <key>Name</key><string>Installing Google Chrome</string>
    <key>Icon</key><string>SF=globe</string>
    <key>Action</key>
    <dict>
        <key>Type</key><string>shell</string>
        <key>Command</key><string>/usr/local/bin/jamf policy -event install-chrome</string>
        <key>TimeoutSeconds</key><integer>900</integer>
    </dict>
    <key>Conditions</key>
    <array>
        <dict>
            <key>Type</key><string>app_installed</string>
            <key>Path</key><string>/Applications/Google Chrome.app</string>
        </dict>
    </array>
</dict>

<dict>
    <key>Id</key><string>install-zscaler</string>
    <key>Name</key><string>Installing company VPN</string>
    <key>Icon</key><string>SF=lock.shield</string>
    <key>Action</key>
    <dict>
        <key>Type</key><string>package</string>
        <key>Path</key><string>/Library/Enrollinator/packages/ZScaler.pkg</string>
        <key>TimeoutSeconds</key><integer>600</integer>
    </dict>
    <!-- Source used `|| true`. -->
    <key>ContinueOnFailure</key><true/>
</dict>

<dict>
    <key>Id</key><string>zscaler-signin</string>
    <key>Name</key><string>Sign in to ZScaler</string>
    <key>Icon</key><string>SF=lock.shield,animation=pulse</string>
    <key>Blocking</key><true/>
    <key>PollIntervalSeconds</key><integer>5</integer>
    <!-- Source looped forever; 30 minutes so an unattended Mac eventually fails. -->
    <key>TimeoutSeconds</key><integer>1800</integer>
    <key>WaitWindow</key>
    <dict>
        <key>Title</key><string>Sign in to ZScaler</string>
        <key>Message</key><string>Click the **ZScaler** icon in your menu bar and sign in with your work account. This window closes on its own once you are connected.</string>
    </dict>
    <key>Conditions</key>
    <array>
        <dict>
            <key>Type</key><string>process_running</string>
            <key>Name</key><string>Zscaler</string>
        </dict>
        <dict>
            <key>Type</key><string>shell</string>
            <key>Command</key><string>/sbin/ifconfig 2&gt;/dev/null | /usr/bin/grep -qE '^utun[0-9]+:.*UP'</string>
        </dict>
    </array>
</dict>

<dict>
    <key>Id</key><string>chrome-default</string>
    <key>Name</key><string>Setting your default browser</string>
    <key>Icon</key><string>SF=checkmark.seal</string>
    <key>Action</key>
    <dict>
        <key>Type</key><string>shell</string>
        <key>RunAsUser</key><string>$CONSOLE_USER</string>
        <key>Command</key><string>/usr/local/bin/defaultbrowser chrome</string>
    </dict>
    <key>Conditions</key>
    <array>
        <dict>
            <key>Type</key><string>default_browser</string>
            <key>BundleId</key><string>com.google.Chrome</string>
        </dict>
    </array>
</dict>
```

**Part 3 — Caveats**

- `install-chrome` still calls `jamf policy`, so the config is not yet
  MDM-agnostic. Replace it with a `package` action pointed at a deployed
  Chrome pkg to finish the job.
- `ZScaler.pkg` was read from `/tmp` in the source, which does not survive a
  reboot. Moved to `/Library/Enrollinator/packages/ZScaler.pkg`; that file must
  be delivered by the pkg or the MDM.
- `/usr/local/bin/defaultbrowser` is a third-party binary and must be present
  before this step runs.
- The process name `Zscaler` is a guess — `process_running` uses `pgrep -x`, so
  verify the exact name with `pgrep -l -i zscaler` on a working Mac.
- The `utun` check matches any VPN tunnel, not specifically ZScaler's. Paired
  with `process_running` it is good enough for a gate; it is not an assertion
  about which vendor's tunnel is up.
- The source blocked forever on ZScaler sign-in. A 30-minute timeout was added
  so an unattended Mac fails visibly instead of hanging; remove
  `TimeoutSeconds` if waiting forever was intentional.

---

## 10. Further reference

If the human has the repo available, these go deeper than this file:

- [`docs/mobileconfig-schema.md`](mobileconfig-schema.md) — every key, every handler.
- [`docs/recipes.md`](recipes.md) — copy-pasteable gates for VPNs, EDRs, FileVault, browsers.
- [`docs/deployment.md`](deployment.md) — pkg, LaunchDaemon, MDM delivery, Jamf reporting.
- [`docs/profile-builder.md`](profile-builder.md) — the visual editor, which imports and previews whatever you generate.
- [`examples/enrollinator.mobileconfig`](../examples/enrollinator.mobileconfig) — a full, commented reference config.

---

## 11. Sources for §5

The source-tool key names, command spellings, and valid values in §5 were
checked against these, August 2026:

- DEPNotify commands and the `/var/tmp/depnotify.log` control file —
  [jamf/DEPNotify wiki](https://github.com/jamf/DEPNotify/wiki)
- Setup Your Mac `policyJSON` (`steps`, `listitem`, `icon`, `progresstext`,
  `trigger_list`, `trigger`, `validation`) —
  [Setup Your Mac: Under-the-hood](https://snelson.us/2023/11/sym-under-the-hood/)
  and [dan-snelson/dialog-scripts](https://github.com/dan-snelson/dialog-scripts/blob/main/Setup%20Your%20Mac/Setup-Your-Mac-via-Dialog.bash)
- SplashBuddy `applicationsArray` keys —
  [macadmins/SplashBuddy wiki](https://github.com/macadmins/SplashBuddy/wiki/30---kickstart-guide)
- Installomator `NOTIFY` and `BLOCKING_PROCESS_ACTION` values —
  [Installomator wiki: Configuration and Variables](https://github.com/Installomator/Installomator/wiki/Configuration-and-Variables)

The Iru/Liftoff and Octory sections in §5 are shape-level guidance about how
those tools are structured, not transcribed key names, and were not verified
against vendor documentation. Treat them as weaker than the rest of §5.
