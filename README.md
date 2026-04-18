# Set-DefaultUserRegistry

PowerShell script that applies registry customizations to the Windows Default User profile (`NTUSER.DAT`). Any new user accounts created after running this script inherit the configured settings.

Settings are defined in an external JSON config file, making it easy to swap profiles or add new customizations without editing the script.

## What It Does

1. Loads the Default User's `NTUSER.DAT` hive into a temporary registry mount
2. Reads settings from `config\default-user-settings.json`
3. Creates registry keys and sets values for each entry
4. Cleanly unloads the hive using GC cleanup (no arbitrary sleep timer)

**Only affects new user profiles.** Existing user accounts are not modified.

## Project Structure

```
Set-DefaultUserRegistry/
├── Set-DefaultUserRegistry.ps1       # Main script
├── config/
│   └── default-user-settings.json    # Settings config (edit this)
├── outputs/                          # Log files (auto-created, git-ignored)
├── README.md
├── LICENSE
└── .gitignore
```

## Usage

```powershell
# Run with default config and default NTUSER.DAT path
.\Set-DefaultUserRegistry.ps1

# Use a custom config file
.\Set-DefaultUserRegistry.ps1 -ConfigPath ".\config\my-custom-settings.json"

# Target a different NTUSER.DAT (e.g., from a mounted image)
.\Set-DefaultUserRegistry.ps1 -HivePath "D:\Users\Default\NTUSER.DAT"
```

Requires **Administrator privileges** and **PowerShell 5.1+**.

## Config File Format

Settings are defined in JSON. Each entry specifies a registry path (relative to the HKCU root) and one or more properties to set. Fields prefixed with `_` are metadata/documentation and are ignored by the script.

```json
{
  "settings": [
    {
      "_category": "Copilot",
      "_description": "Disable Windows Copilot via policy registry key.",
      "_reference": "https://learn.microsoft.com/...",
      "path": "Software\\Policies\\Microsoft\\Windows\\WindowsCopilot",
      "properties": {
        "TurnOffWindowsCopilot": 1
      }
    }
  ]
}
```

**Type detection:** Integer values become `REG_DWORD`. String values become `REG_SZ`.

**Path format:** Paths are relative to the hive root (HKCU equivalent). Do NOT prefix with `SOFTWARE\` unless the key actually lives under `Software\`. For example, `Control Panel\Desktop` is at the root, not under `Software\`.

## Included Settings (Proof of Concept)

The default config disables Windows Copilot and applies basic taskbar customizations:

| Category | Setting | Value | Effect |
|----------|---------|-------|--------|
| Copilot | `TurnOffWindowsCopilot` | 1 | Disables Copilot via policy key |
| Copilot | `ShowCopilotButton` | 0 | Hides Copilot button from taskbar |
| Taskbar | `TaskbarAl` | 0 | Left-aligns taskbar icons |
| Taskbar | `SearchboxTaskbarMode` | 1 | Shows search as icon only |

## Adding Your Own Settings

1. Open `config\default-user-settings.json`
2. Add a new entry to the `settings` array
3. Include `_description` and `_reference` fields pointing to official Microsoft documentation
4. Verify the correct registry path relative to HKCU root
5. Test on a non-production machine first

## Important Notes

- **Copilot policy deprecation:** Microsoft has marked the `TurnOffWindowsCopilot` policy as legacy and plans to deprecate it. It still works on Windows 11 24H2 but future versions may require AppLocker rules instead. See the [Microsoft docs on managing Copilot](https://learn.microsoft.com/en-us/windows/client-management/manage-windows-copilot).
- **Hive locking:** The script uses `[gc]::Collect()` and `[gc]::WaitForPendingFinalizers()` to release .NET handles before unloading the hive, with up to 3 retry attempts. This replaces the 60-second sleep timer used in earlier versions.
- **Documentation requirement:** All settings in the config should be traceable to official Microsoft documentation. Do not add undocumented or reverse-engineered registry values.

## References

- [WindowsAI Policy CSP (TurnOffWindowsCopilot) - Microsoft Learn](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-windowsai)
- [Managing Windows Copilot - Microsoft Learn](https://learn.microsoft.com/en-us/windows/client-management/manage-windows-copilot)
- [Windows 11 Settings Reference - Microsoft Learn](https://learn.microsoft.com/en-us/windows/apps/develop/settings/settings-windows-11)

## License

[MIT](LICENSE)

## Author

**Nash Consulting** — IT/MSP services, systems administration, security, and automation.