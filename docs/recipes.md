# Recipes

Real-world step definitions you can paste into your `.mobileconfig` or
recreate visually in the
[Profile Builder](../tools/profile-builder.html).
Everything here composes from the generic primitives in
[`lib/plugins.sh`](../lib/plugins.sh); there is no vendor-specific code in
Enrollinator itself.

## ZScaler: installed, running, and tunnel up

```xml
<dict>
    <key>Id</key><string>zscaler-signin</string>
    <key>Name</key><string>Sign in to ZScaler</string>
    <key>Blocking</key><true/>
    <key>PollIntervalSeconds</key><integer>5</integer>
    <key>TimeoutSeconds</key><integer>1800</integer>
    <key>UserPrompt</key>
    <string>Click the ZScaler menu-bar icon and sign in with your corporate account.</string>
    <key>Conditions</key>
    <array>
        <dict>
            <key>Type</key><string>app_installed</string>
            <key>BundleId</key><string>com.zscaler.Zscaler</string>
        </dict>
        <dict>
            <key>Type</key><string>process_running</string>
            <key>Name</key><string>Zscaler</string>
        </dict>
        <!-- Tunnel check: a `utun` interface is up. Works for most macOS
             client VPNs without any vendor-specific tooling. -->
        <dict>
            <key>Type</key><string>shell</string>
            <key>Command</key>
            <string>/sbin/ifconfig 2&gt;/dev/null | /usr/bin/grep -qE '^utun[0-9]+:.*UP'</string>
        </dict>
    </array>
</dict>
```

## GlobalProtect

```xml
<dict>
    <key>Id</key><string>globalprotect</string>
    <key>Name</key><string>Connect to GlobalProtect</string>
    <key>Blocking</key><true/>
    <key>UserPrompt</key>
    <string>Open the GlobalProtect menu-bar icon and connect.</string>
    <key>Conditions</key>
    <array>
        <dict>
            <key>Type</key><string>app_installed</string>
            <key>BundleId</key><string>com.paloaltonetworks.GlobalProtect</string>
        </dict>
        <dict>
            <key>Type</key><string>process_running</string>
            <key>Name</key><string>PanGPA</string>
        </dict>
        <dict>
            <key>Type</key><string>shell</string>
            <key>Command</key>
            <string>/usr/bin/defaults read /Library/Preferences/com.paloaltonetworks.GlobalProtect.client.plist "Palo Alto Networks.GlobalProtect.PanGpHipStatus" 2&gt;/dev/null | /usr/bin/grep -q 'connected'</string>
        </dict>
    </array>
</dict>
```

## CrowdStrike Falcon: installed and communicating

```xml
<dict>
    <key>Id</key><string>falcon</string>
    <key>Name</key><string>Verify CrowdStrike Falcon</string>
    <key>Conditions</key>
    <array>
        <dict>
            <key>Type</key><string>file_exists</string>
            <key>Path</key>
            <string>/Applications/Falcon.app</string>
            <key>Kind</key><string>directory</string>
        </dict>
        <dict>
            <key>Type</key><string>shell</string>
            <!-- Exit 0 if Falcon reports a connected sensor. -->
            <key>Command</key>
            <string>/Applications/Falcon.app/Contents/Resources/falconctl stats 2&gt;/dev/null | /usr/bin/grep -qi 'State:.*connected'</string>
            <key>TimeoutSeconds</key><integer>10</integer>
        </dict>
    </array>
</dict>
```

## FileVault is on

```xml
<dict>
    <key>Id</key><string>filevault</string>
    <key>Name</key><string>FileVault must be enabled</string>
    <key>Blocking</key><true/>
    <key>UserPrompt</key>
    <string>Turn on FileVault in System Settings → Privacy &amp; Security → FileVault.</string>
    <key>Conditions</key>
    <array>
        <dict>
            <key>Type</key><string>shell</string>
            <key>Command</key>
            <string>/usr/bin/fdesetup status 2&gt;/dev/null | /usr/bin/grep -qi 'FileVault is On'</string>
        </dict>
    </array>
</dict>
```

## Set Chrome as default browser

```xml
<dict>
    <key>Id</key><string>chrome-default</string>
    <key>Name</key><string>Set Chrome as your default browser</string>
    <key>Blocking</key><true/>
    <key>UserPrompt</key>
    <string>Open System Settings → Desktop &amp; Dock → Default web browser, and pick Google Chrome.</string>
    <key>Conditions</key>
    <array>
        <dict>
            <key>Type</key><string>default_browser</string>
            <key>BundleId</key><string>com.google.Chrome</string>
        </dict>
    </array>
</dict>
```

## iCloud signed in (best-effort)

```xml
<dict>
    <key>Id</key><string>icloud</string>
    <key>Name</key><string>Sign in to iCloud</string>
    <key>Blocking</key><true/>
    <key>UserPrompt</key>
    <string>Open System Settings → Apple ID and sign in.</string>
    <key>Conditions</key>
    <array>
        <dict>
            <key>Type</key><string>shell</string>
            <key>RunAsUser</key><string>$CONSOLE_USER</string>
            <key>Command</key>
            <string>/usr/bin/defaults read MobileMeAccounts Accounts 2&gt;/dev/null | /usr/bin/grep -q 'AccountID'</string>
        </dict>
    </array>
</dict>
```

## Install Rosetta 2 (one-shot action, tolerate failure)

```xml
<dict>
    <key>Id</key><string>install-rosetta</string>
    <key>Name</key><string>Install Rosetta 2</string>
    <key>Action</key>
    <dict>
        <key>Type</key><string>shell</string>
        <key>Command</key>
        <string>/usr/sbin/softwareupdate --install-rosetta --agree-to-license</string>
        <key>TimeoutSeconds</key><integer>900</integer>
    </dict>
    <key>ContinueOnFailure</key><true/>
</dict>
```

## Run a command as the logged-in user

```xml
<dict>
    <key>Id</key><string>git-config</string>
    <key>Name</key><string>Set a default git config</string>
    <key>Action</key>
    <dict>
        <key>Type</key><string>shell</string>
        <key>RunAsUser</key><string>$CONSOLE_USER</string>
        <key>Command</key>
        <string>/usr/bin/git config --global init.defaultBranch main</string>
    </dict>
</dict>
```

## Verify a configuration profile is installed

```xml
<dict>
    <key>Id</key><string>wifi-profile</string>
    <key>Name</key><string>Verify corporate Wi-Fi profile</string>
    <key>Conditions</key>
    <array>
        <dict>
            <key>Type</key><string>profile_installed</string>
            <key>Identifier</key><string>com.example.wifi</string>
        </dict>
    </array>
</dict>
```

## Optional add-on playbooks

Use `Addon: true` on a playbook to remove it from automatic selection and
offer it in a post-install checkbox picker instead. Steps whose `Id` values
were already run by the main playbook are skipped automatically.

```xml
<key>Playbooks</key>
<array>

    <!-- Main playbook — selected automatically (no Addon key). -->
    <dict>
        <key>Name</key><string>Standard Employee</string>
        <key>Steps</key>
        <array>
            <dict>
                <key>Id</key><string>install-chrome</string>
                <key>Name</key><string>Install Google Chrome</string>
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
            </dict>
        </array>
    </dict>

    <!-- Addon playbook — shown in the post-install picker, not auto-selected. -->
    <dict>
        <key>Name</key><string>Developer Tools</string>
        <key>Addon</key><true/>
        <key>Steps</key>
        <array>
            <dict>
                <key>Id</key><string>install-xcode-clt</string>
                <key>Name</key><string>Install Xcode Command Line Tools</string>
                <key>Action</key>
                <dict>
                    <key>Type</key><string>shell</string>
                    <key>Command</key>
                    <string>/usr/bin/xcode-select --install || true</string>
                </dict>
            </dict>
        </array>
    </dict>

</array>
```

After the main playbook finishes Enrollinator shows a swiftDialog checkbox
picker listing every addon playbook. Steps that were already executed in the
main run are deduped by `Id` and silently skipped.

The picker can be customised via the `AddonPicker` dict in your
`.mobileconfig` (see the schema docs), or at runtime by setting environment
variables in the LaunchDaemon's environment — useful when you want to
override branding without redeploying the profile.

| Environment variable              | What it controls |
|-----------------------------------|-----------------|
| `ENROLLINATOR_ADDON_TITLE`        | Picker window title. |
| `ENROLLINATOR_ADDON_MESSAGE`      | Markdown body shown above the checkbox list. |
| `ENROLLINATOR_ADDON_ICON`         | Absolute path or URL for the icon in the picker window. |
| `ENROLLINATOR_ADDON_INSTALL_BTN`  | Label for the confirm/install button (default: `"Install"`). |
| `ENROLLINATOR_ADDON_SKIP_BTN`     | Label for the skip button (default: `"Not now"`). |
| `ENROLLINATOR_ADDON_TITLE_FONTSIZE` | Point size for the title font. |
| `ENROLLINATOR_ADDON_MSG_FONTSIZE` | Point size for the message body font. |
| `ENROLLINATOR_ADDON_WIDTH`        | Picker window width in points. |
| `ENROLLINATOR_ADDON_HEIGHT`       | Picker window height in points. |

Environment variables take precedence over the `AddonPicker` dict. Set them
via a `launchd` override plist scoped to `com.enrollinator.app`, for example:

```xml
<!-- /Library/LaunchDaemons/com.enrollinator.app.override.plist -->
<key>EnvironmentVariables</key>
<dict>
    <key>ENROLLINATOR_ADDON_TITLE</key>
    <string>Extra tools</string>
    <key>ENROLLINATOR_ADDON_INSTALL_BTN</key>
    <string>Install selected</string>
    <key>ENROLLINATOR_ADDON_SKIP_BTN</key>
    <string>Skip for now</string>
</dict>
```

## Notes on composition

- **Blocking gates** pair well with `app_installed` + `process_running` +
  a `shell` state check. "Installed, running, and doing its job" is three
  orthogonal questions; keeping them separate makes UI messages precise.
- **Tunnel checks** via `utun` are a cheap, vendor-agnostic proxy for
  "VPN is connected". They won't distinguish one vendor's tunnel from
  another's if both are running; pair with an `app_installed`/
  `process_running` check when you need that discrimination.
- **Timeouts** are off by default for blocking steps; set
  `TimeoutSeconds` if you want the run to fail rather than wait forever.
- **UserPrompt** is a single line shown as the banner. Keep it short and
  tell the user exactly where to click.
