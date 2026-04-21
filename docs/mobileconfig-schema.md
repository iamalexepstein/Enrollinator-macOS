# Mobileconfig schema

> **Tip:** You don't need to edit this XML by hand. Open
> [`tools/profile-builder.html`](../tools/profile-builder.html) in any
> browser for a full visual editor that exports a ready-to-upload
> `.mobileconfig`. This reference documents every key the builder can
> produce.

Enrollinator reads one managed preferences domain: **`com.enrollinator.app`**. The
preferences are deployed as a `.mobileconfig` with a `PayloadContent` entry
whose `PayloadType` is `com.enrollinator.app`.

This document describes every key that entry understands.

> Keys are **CamelCase strings** unless noted. "Array of dicts" means an
> XML `<array>` of `<dict>` elements. Types: `string`, `int` (plist
> `<integer>`), `bool` (plist `<true/>` / `<false/>`), `array`, `dict`.

## Top-level

| Key              | Type            | Required | Description |
|------------------|-----------------|----------|-------------|
| `Branding`       | dict            | no       | Window title, subtitle, logo, accent color, banner, window size. |
| `DefaultPlaybook` | string          | no       | Name of the playbook to use when no selector matches. |
| `AllowClose`     | bool            | no       | If `true`, Enrollinator enables the Done button at the end instead of auto-quitting. Defaults to `false`. |
| `TestMode`       | bool            | no       | If `true`, Enrollinator evaluates conditions but skips every `Action`. In test mode Enrollinator also caps each blocking step's effective timeout at 5 seconds so a rehearsal never actually hangs. Overridable per-profile. Defaults to `false`. |
| `HardwareInfo`   | dict            | no       | Enables a hardware info panel next to the step list. See below. |
| `Help`           | dict            | no       | Enables a "?" help button in the window. Shown contents are configured here. See below. |
| `AddonPicker`    | dict            | no       | Customises the post-install add-on picker window. See below. |
| `Playbooks`      | array of dicts  | **yes**  | One or more playbooks; the first with a matching selector wins. |

### `Branding`

| Key              | Type   | Description |
|------------------|--------|-------------|
| `Title`          | string | Window title. Supports `{token}` substitution — see [Token substitution](#token-substitution). |
| `Subtitle`       | string | Text below the title. Restored as the banner after a blocking step passes (when no `WaitWindow` is used). Supports `{token}` substitution. |
| `Logo`           | string | Absolute path to a PNG/JPG/SVG, an `https://` URL, or an SF Symbol token (`SF=symbol.name` or `SF=symbol.name,animation=type`). Falls back to the SF Symbol `sparkles` if the path is absent or the file cannot be loaded. |
| `Banner`         | string | Optional banner image strapped across the top of the window. Absolute path or `https://` URL. Falls back to a plain gradient when absent or when the image cannot be loaded. |
| `AccentColor`    | string | Hex color (`#0A84FF`) applied to the title font. |
| `TitleFontSize`  | int    | Point size for the window title. Passed to swiftDialog's `--titlefont` option. |
| `MessageFontSize`| int    | Point size for the subtitle / message body. Passed to swiftDialog's `--messagefont` option. |
| `WindowWidth`    | int    | Default `720`. |
| `WindowHeight`   | int    | Default `560`. |

#### Token substitution

`Title` and `Subtitle` may embed the following `{token}` placeholders, which
Enrollinator expands at runtime before passing values to swiftDialog:

| Token              | Expands to |
|--------------------|------------|
| `{console_user}`   | Short username of the logged-in console user. |
| `{hostname}`       | `scutil --get LocalHostName`. |
| `{computer_name}`  | `scutil --get ComputerName`. |
| `{serial_number}`  | Hardware serial number from `system_profiler`. |
| `{model}`          | Marketing model name (e.g. `MacBook Pro`). |
| `{os_version}`     | macOS version string (e.g. `14.4.1`). |
| `{ip_address}`     | Primary IPv4 address. |
| `{uuid}`           | Hardware UUID. |

Example: `"Welcome, {console_user}!"` becomes `"Welcome, alex!"` at runtime.

### `HardwareInfo`

Shows a compact key–value panel next to the step list (rendered via
swiftDialog's `--infobox`). Useful when IT needs the user to read their
serial over the phone during onboarding.

| Key       | Type            | Description |
|-----------|-----------------|-------------|
| `Enabled` | bool            | Set `true` to show the panel. |
| `Fields`  | array of string | Which fields to include, in order. Supported tokens: `console_user`, `hostname`, `computer_name`, `serial_number`, `model`, `os_version`, `ip_address`, `uuid`. |

### `Help`

Populates swiftDialog's built-in `?` help button. When enabled, the button
appears in the top-right of the window and opens a sheet with whatever
contact info you put here.

| Key        | Type            | Description |
|------------|-----------------|-------------|
| `Enabled`  | bool            | Set `true` to show the help button. |
| `Title`    | string          | Heading in the popover. Defaults to "Need help?". |
| `Message`  | string          | Free-form markdown body shown above the contacts list. |
| `Contacts` | array of dicts  | One entry per way to reach IT (see below). |

Each `Contacts` entry:

| Key      | Type   | Description |
|----------|--------|-------------|
| `Label`  | string | The thing being described (`Slack`, `Phone`, `Email`, `Portal`). |
| `Detail` | string | Plain-text value (`#it-help`, `555-123-4567`). Shown if no `URL`. |
| `URL`    | string | Optional link. If set, the entry renders as a markdown link. |

### `AddonPicker`

Customises the swiftDialog checkbox picker that appears after the main
playbook finishes when one or more `Addon: true` playbooks are defined.
All keys are optional; Enrollinator supplies sensible defaults when they
are absent.

| Key               | Type   | Description |
|-------------------|--------|-------------|
| `Title`           | string | Picker window title. Defaults to `"Optional extras"`. |
| `Message`         | string | Markdown body shown above the checkbox list. Defaults to a generic "Select the extras you want to install." message. |
| `Icon`            | string | Absolute path, `https://` URL, or SF Symbol token (`SF=symbol.name` or `SF=symbol.name,animation=type`) for the icon shown in the picker. Defaults to the `Branding.Logo` value. |
| `TitleFontSize`   | int    | Point size for the picker's title font. |
| `MessageFontSize` | int    | Point size for the picker's message body font. |
| `InstallButton`   | string | Label for the confirm button. Defaults to `"Install"`. |
| `SkipButton`      | string | Label for the skip button. Defaults to `"Not now"`. |
| `Width`           | int    | Picker window width in points. Default `520`. |
| `Height`          | int    | Picker window height in points. Default `420`. |

> **Env-var overrides.** The same nine settings can be overridden at runtime
> via environment variables — useful when you need to customise the picker
> without redeploying the `.mobileconfig`. Variable names:
> `ENROLLINATOR_ADDON_TITLE`, `ENROLLINATOR_ADDON_MESSAGE`,
> `ENROLLINATOR_ADDON_ICON`, `ENROLLINATOR_ADDON_TITLE_FONTSIZE`,
> `ENROLLINATOR_ADDON_MSG_FONTSIZE`, `ENROLLINATOR_ADDON_INSTALL_BTN`,
> `ENROLLINATOR_ADDON_SKIP_BTN`, `ENROLLINATOR_ADDON_WIDTH`,
> `ENROLLINATOR_ADDON_HEIGHT`. Environment variables take precedence over
> the `AddonPicker` dict. Set them via a `launchd` override plist or the
> MDM's environment-variable mechanism.

## Playbooks

Each entry in the `Playbooks` array:

| Key           | Type            | Description |
|---------------|-----------------|-------------|
| `Name`        | string          | Must be unique. Used by `DefaultPlaybook` and `--profile`. |
| `Description` | string          | Free-form. Not shown in the UI. |
| `Selector`    | dict            | Optional. If absent, the playbook can only be picked via `DefaultPlaybook` or `--profile`. |
| `TestMode`    | bool            | Optional. Forces test mode for this playbook. Precedence: `--test` CLI flag > top-level `TestMode` > playbook `TestMode`. |
| `Addon`       | bool            | If `true`, this playbook is shown in the post-install add-on picker rather than selected automatically. Default: `false`. |
| `Steps`       | array of dicts  | Steps, in execution order. |

### Addon playbooks

Playbooks with `Addon: true` are excluded from automatic selection. After
the main playbook's steps finish, if any playbooks in the `Playbooks` array
carry `Addon: true`, Enrollinator presents a swiftDialog checkbox picker so
the user can choose which extras to install.

- **Deduplication.** Any step `Id` that was already executed during the main
  playbook run is skipped when an addon playbook runs it, so there is no
  risk of double-installing packages or re-running side-effecting actions.
- **Picker text overrides.** Set the `ENROLLINATOR_ADDON_TITLE` and
  `ENROLLINATOR_ADDON_MESSAGE` environment variables (e.g. via a
  `launchd` override plist) to customise the picker window title and body
  text shown to the user.
- If no addons are selected the picker is dismissed and Enrollinator exits
  normally.

### `Selector`

If multiple keys are set, **all must match** (AND). An empty `Selector`
dict does not count as a match — it is ignored.

| Key                   | Type   | Matches when… |
|-----------------------|--------|---------------|
| `HostnameRegex`       | string | `scutil --get LocalHostName` matches this bash-extended regex. |
| `ModelIdentifierGlob` | string | `sysctl -n hw.model` matches this fnmatch pattern (e.g. `Mac15,*`). |
| `FileExists`          | string | Absolute path exists on disk. Useful for flag files the MDM drops. |

## Steps

Each step:

| Key                    | Type   | Description |
|------------------------|--------|-------------|
| `Id`                   | string | Internal identifier. Required for good logs. |
| `Name`                 | string | Shown in the swiftDialog list. |
| `Description`          | string | Reserved for future use. |
| `Icon`                 | string | Optional icon shown next to the step in the swiftDialog list. Accepts a local absolute path (`/Library/Enrollinator/assets/chrome.png`), an `https://` URL, or an SF Symbol token. SF Symbol format: `SF=symbol.name` or `SF=symbol.name,animation=type`. Supported animation values: `pulse`, `bounce`, `variableColor`, `appear`, `disappear`, `rotate`, `breathe` (macOS 14+), `wiggle` (macOS 14+). Browse symbols at [developer.apple.com/sf-symbols](https://developer.apple.com/sf-symbols/). Leave empty for default row styling. |
| `Action`               | dict   | Optional. Run once before conditions are checked. |
| `Conditions`           | array  | Optional. Evaluated AND-style. |
| `Blocking`             | bool   | If `true` and conditions fail, Enrollinator polls until they pass. |
| `PollIntervalSeconds`  | int    | Poll interval for blocking steps. Default `5`. |
| `TimeoutSeconds`       | int    | Blocking timeout. `0` = no timeout. Default `0`. In test mode, effective timeout is capped at `5`. |
| `ContinueOnFailure`    | bool   | If `true`, a failure marks the step failed but doesn't stop the run. |
| `OnSuccess`            | string | Step `Id` to jump to when this step succeeds. Use the special value `$end` to skip straight to the completion phase (addon picker + done). Default (empty): advance to the next step in the list. |
| `OnFailure`            | string | Step `Id` to jump to when this step fails. Two special values: `$next` advances to the next step despite the failure (equivalent to `ContinueOnFailure` but expressed as a branch); `$end` is not meaningful here since stopping and ending the run are the same outcome on failure. When set, takes precedence over `ContinueOnFailure` for routing. Default (empty): stop the run. |
| `UserPrompt`           | string | Legacy fallback: banner text shown on the main window while a blocking step is waiting. Ignored when `WaitWindow` is set. |
| `WaitWindow`           | dict   | Optional. When the step is blocking, Enrollinator opens this secondary swiftDialog window and leaves it open until the step's conditions pass. See below. |

### `WaitWindow`

| Key               | Type            | Description |
|-------------------|-----------------|-------------|
| `Title`           | string          | Wait window title. Defaults to the step's `Name`. |
| `Message`         | string          | Markdown body. Falls back to `UserPrompt` if unset. |
| `Slideshow`       | array of string | Absolute paths or URLs. More than one image → Enrollinator cycles them every 6 seconds. |
| `Video`           | string          | Absolute path or URL. Wins over `Slideshow` when both are set. |
| `TitleFontSize`   | int             | Point size for the wait window's title font. |
| `MessageFontSize` | int             | Point size for the wait window's message body font. |
| `Width`           | int             | Default `520`. |
| `Height`          | int             | Default `420`. |

### Flow

1. If `Action` is set, run it. Non-zero exit → step fails (unless
   `ContinueOnFailure`).
2. If `Conditions` is empty, step succeeds.
3. Otherwise evaluate conditions. All pass → success.
4. Any fail, `Blocking=true` → poll every `PollIntervalSeconds`, with a
   `WaitWindow` shown (or the `UserPrompt` banner, if no window is
   configured), until they pass or `TimeoutSeconds` elapses.
5. Any fail, `Blocking=false` → step fails (or is skipped if
   `ContinueOnFailure`).

After the step outcome (success or failure) is determined, Enrollinator
resolves the next step using `OnSuccess` / `OnFailure`:

- If the matching key is absent or empty, default behaviour applies
  (advance to the next step in the list, or stop on an unhandled failure).
- If the value is `$end`, Enrollinator skips to the end of the playbook.
- Otherwise, the value is treated as a step `Id`; Enrollinator jumps to
  that step. An unrecognised ID logs a warning and falls back to the
  default "advance" behaviour.

Enrollinator enforces a cycle guard: if the total number of steps executed
exceeds twice the playbook's step count, the run is halted and a warning is
logged. This prevents an infinite loop caused by two steps branching to
each other.

## Actions (`Action.Type`)

### `shell`

| Key                | Type          | Notes |
|--------------------|---------------|-------|
| `Command`          | string (req)  | Passed to `/bin/sh -c`. |
| `RunAsUser`        | string        | `$CONSOLE_USER` or a literal username. |
| `TimeoutSeconds`   | int           | Default `300`. |

### `package`

| Key                | Type          | Notes |
|--------------------|---------------|-------|
| `Path`             | string (req)  | Absolute path to a `.pkg`. |
| `Target`           | string        | Default `/`. |
| `TimeoutSeconds`   | int           | Default `600`. |

### `wait`

Pause for a fixed duration, then succeed. Useful for giving a
freshly-kicked LaunchDaemon a moment to settle before the next step's
conditions fire.

| Key               | Type         | Notes |
|-------------------|--------------|-------|
| `DurationSeconds` | int (req)    | How long to sleep. |

### `dialog`

Pop up a swiftDialog modal with configurable buttons. The step succeeds
iff the user clicks the `ExpectedButton`. Good for "have you read this
policy?" gates and other acknowledgements.

| Key              | Type            | Notes |
|------------------|-----------------|-------|
| `Title`          | string (req)    | Popup title. |
| `Message`        | string (req)    | Popup body (markdown allowed). |
| `Width`          | int             | Default `520`. |
| `Height`         | int             | Default `300`. |
| `Buttons`        | array of string | 1–3 button labels, left-to-right. Default `["OK"]`. |
| `ExpectedButton` | string          | Must match one of `Buttons`. Defaults to the first. |

### `noop`

Succeeds immediately. Useful for steps that are pure condition checks.

## Conditions (`Type`)

### `shell`

| Key                | Type          | Notes |
|--------------------|---------------|-------|
| `Command`          | string (req)  | Exit 0 = pass. |
| `TimeoutSeconds`   | int           | Default `15`. |

### `app_installed`

| Key           | Type    | Notes |
|---------------|---------|-------|
| `BundleId`    | string  | Resolved via Spotlight (`mdfind`). |
| `Path`        | string  | Direct absolute path to an `.app` bundle (skips Spotlight). |
| `MinVersion`  | string  | Dotted version; compared to `CFBundleShortVersionString`. |

Must supply `BundleId` or `Path`.

### `default_browser`

| Key        | Type          | Notes |
|------------|---------------|-------|
| `BundleId` | string (req)  | The bundle id that must own the `http`/`https` scheme in LaunchServices. |

Reads the console user's LaunchServices prefs via `launchctl asuser`.

### `file_exists`

| Key     | Type   | Notes |
|---------|--------|-------|
| `Path`  | string | Absolute path. |
| `Kind`  | string | `file`, `directory`, or `any` (default). |

### `profile_installed`

| Key          | Type          | Notes |
|--------------|---------------|-------|
| `Identifier` | string (req)  | `PayloadIdentifier` to look for in `profiles list -all`. |

### `process_running`

| Key             | Type          | Notes |
|-----------------|---------------|-------|
| `Name`          | string (req)  | Matched with `pgrep -x`. |
| `MinimumCount`  | int           | Default `1`. |

## Command-line flags

`enrollinator.sh` reads the same schema whether the config comes from a
managed-prefs domain, a raw `.mobileconfig`, or a bare plist. The flags:

| Flag                | Purpose |
|---------------------|---------|
| `--config PATH`     | Load a `.mobileconfig` file and extract the `com.enrollinator.app` payload. |
| `--xml PATH`        | Load a bare plist XML file. Schema is rooted at the top level — no `PayloadContent` wrapping required. Handy for dev configs. |
| `--profile NAME`    | Force a specific profile, ignoring selectors. |
| `--domain DOMAIN`   | Override the managed-prefs domain (default `com.enrollinator.app`). |
| `--test`            | Run in test mode: actions are simulated, conditions still evaluate. Does not mark the run completed. |
| `--force`           | Re-run even if `/var/lib/enrollinator/completed` exists. |
| `--dry-run`         | Parse config and print the plan, don't execute. |
| `--skip-root-check` | Allow running as non-root. Dev only — swiftDialog won't appear in user sessions. |

## Adding handlers

Everything above lives in `lib/plugins.sh`. Adding a new type is a case
branch plus a function — see the dispatcher at the top of that file.
