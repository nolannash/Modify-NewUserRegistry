<#
.SYNOPSIS
    Applies registry customizations to the Default User NTUSER.DAT hive.

.DESCRIPTION
    Loads the Default User's NTUSER.DAT registry hive, applies settings from a JSON
    configuration file, then cleanly unloads the hive. Any new user profiles created
    after running this script will inherit the configured settings.

    Settings are defined in config\default-user-settings.json. Each entry specifies a
    registry path (relative to HKCU root) and one or more properties to set. Integer
    values are written as REG_DWORD, string values as REG_SZ.

    This script fixes common pitfalls with default user hive modification:
    - Paths are relative to the hive root (no hardcoded SOFTWARE\ prefix)
    - Uses GC cleanup instead of arbitrary sleep before hive unload
    - Validates JSON config before making any changes

.PARAMETER ConfigPath
    Path to the JSON configuration file. Defaults to config\default-user-settings.json
    in the script's directory.

.PARAMETER HivePath
    Path to the Default User NTUSER.DAT file. Defaults to C:\Users\Default\NTUSER.DAT.

.EXAMPLE
    .\Set-DefaultUserRegistry.ps1
    Applies default settings from the included config file.

.EXAMPLE
    .\Set-DefaultUserRegistry.ps1 -ConfigPath ".\config\custom-settings.json"
    Applies settings from a custom config file.

.NOTES
    Author:         Nash Consulting
    Requires:       PowerShell 5.1+, Administrator privileges
    Compatibility:  Windows 10/11

    Changes only affect NEW user profiles created after this script runs.
    Existing user profiles are not modified.

    References:
    - See config\default-user-settings.json for per-setting documentation and sources

.LINK
    https://github.com/nolannash/Set-DefaultUserRegistry
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config\default-user-settings.json"),
    [string]$HivePath   = "C:\Users\Default\NTUSER.DAT"
)

# --- Configuration ---
$LogDir    = Join-Path $PSScriptRoot "outputs"
$LogFile   = Join-Path $LogDir "Set-DefaultUserRegistry_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$HiveKey   = "HKU\DefaultUserTemp"
$DriveName = "DefaultUserHive"

# --- Helper Functions ---

function Write-Log {
    <#
    .SYNOPSIS
        Writes a message to both the console (with color) and the log file.
    #>
    param(
        [string]$Message,
        [ConsoleColor]$Color = 'White'
    )
    Write-Host $Message -ForegroundColor $Color
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $LogFile -Value "[$timestamp] $Message"
}

function Import-RegistryHive {
    <#
    .SYNOPSIS
        Loads a registry hive file and maps it as a PowerShell drive.

    .DESCRIPTION
        Uses reg.exe to load a .DAT hive file into a specified registry key path,
        then creates a PSDrive for convenient PowerShell access. If a drive with
        the same name already exists (e.g., from a previous failed run), it is
        removed first.

    .PARAMETER File
        Full path to the .DAT hive file to load.

    .PARAMETER Key
        Registry key path to mount the hive under (e.g., 'HKU\TempHive').

    .PARAMETER Name
        Name for the PSDrive that maps to the loaded hive.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ })]
        [string]$File,

        [Parameter(Mandatory)]
        [ValidatePattern('^(HKLM\\|HKU\\)[a-zA-Z0-9_\\]+$')]
        [string]$Key,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-zA-Z0-9_]+$')]
        [string]$Name
    )

    # Remove stale drive from previous run if present
    $existingDrive = Get-PSDrive -Name $Name -ErrorAction SilentlyContinue
    if ($null -ne $existingDrive) {
        Write-Log "  Removing stale PSDrive '$Name' from previous run." -Color Yellow
        Remove-PSDrive -Name $Name -Force -ErrorAction SilentlyContinue

        # Also try to unload the stale hive
        $null = Start-Process -FilePath "$env:WINDIR\System32\reg.exe" `
                              -ArgumentList "unload `"$Key`"" `
                              -NoNewWindow -PassThru -Wait
    }

    # Load the hive via reg.exe
    $process = Start-Process -FilePath "$env:WINDIR\System32\reg.exe" `
                             -ArgumentList "load `"$Key`" `"$File`"" `
                             -NoNewWindow -PassThru -Wait

    if ($process.ExitCode -ne 0) {
        throw "Failed to load hive '$File' at '$Key'. reg.exe exit code: $($process.ExitCode). Verify the file exists and is not locked."
    }

    # Create PSDrive for the loaded hive
    try {
        New-PSDrive -Name $Name -PSProvider Registry -Root $Key -Scope Script | Out-Null
    }
    catch {
        # If PSDrive creation fails, unload the hive to avoid orphans
        $null = Start-Process -FilePath "$env:WINDIR\System32\reg.exe" `
                              -ArgumentList "unload `"$Key`"" `
                              -NoNewWindow -PassThru -Wait
        throw "Hive loaded but PSDrive creation failed: $($_.Exception.Message)"
    }
}

function Remove-RegistryHive {
    <#
    .SYNOPSIS
        Removes the PSDrive and unloads a previously loaded registry hive.

    .DESCRIPTION
        Removes the PowerShell drive mapping, forces garbage collection to release
        any .NET handles on the hive, then uses reg.exe to unload it. Retries the
        unload up to 3 times if the hive is still locked.

    .PARAMETER Name
        Name of the PSDrive associated with the loaded hive.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    # Get the root key path before removing the drive
    $drive = Get-PSDrive -Name $Name -ErrorAction Stop
    $key   = $drive.Root

    # Remove the PSDrive
    Remove-PSDrive -Name $Name -Force

    # Force garbage collection to release .NET handles on the hive.
    # This replaces the arbitrary 60-second sleep from the original script.
    # .NET's registry provider can hold handles that prevent reg.exe unload.
    [gc]::Collect()
    [gc]::WaitForPendingFinalizers()

    # Attempt unload with retry (hive can briefly remain locked after GC)
    $maxRetries = 3
    for ($i = 1; $i -le $maxRetries; $i++) {
        $process = Start-Process -FilePath "$env:WINDIR\System32\reg.exe" `
                                 -ArgumentList "unload `"$key`"" `
                                 -NoNewWindow -PassThru -Wait

        if ($process.ExitCode -eq 0) {
            return
        }

        if ($i -lt $maxRetries) {
            Write-Log "  Hive unload attempt $i failed (exit code $($process.ExitCode)). Retrying in 2 seconds..." -Color Yellow
            Start-Sleep -Seconds 2
            [gc]::Collect()
            [gc]::WaitForPendingFinalizers()
        }
    }

    throw "Failed to unload hive '$key' after $maxRetries attempts. The hive may still be loaded — check with 'reg query $key' and unload manually if needed."
}

# --- Initialize ---

if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}
Set-Content -Path $LogFile -Value "Set-DefaultUserRegistry - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

Write-Log "Set-DefaultUserRegistry" -Color Green
Write-Log "Computer: $env:COMPUTERNAME | User: $env:USERNAME | Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# --- Validate Inputs ---

Write-Log ""
Write-Log "Validating inputs..." -Color Cyan

if (-not (Test-Path $HivePath)) {
    Write-Log "  [FAIL] NTUSER.DAT not found at: $HivePath" -Color Red
    Write-Log "         Verify the path or pass a custom path with -HivePath." -Color Red
    exit 1
}
Write-Log "  Hive path: $HivePath"

if (-not (Test-Path $ConfigPath)) {
    Write-Log "  [FAIL] Config file not found at: $ConfigPath" -Color Red
    Write-Log "         Verify the path or pass a custom path with -ConfigPath." -Color Red
    exit 1
}
Write-Log "  Config path: $ConfigPath"

# Load and validate JSON config
try {
    $configRaw = Get-Content -Path $ConfigPath -Raw -ErrorAction Stop
    $config    = $configRaw | ConvertFrom-Json -ErrorAction Stop

    if (-not $config.settings -or $config.settings.Count -eq 0) {
        throw "Config file contains no 'settings' entries."
    }

    Write-Log "  Config loaded: $($config.settings.Count) setting(s) found." -Color Green
}
catch {
    Write-Log "  [FAIL] Failed to parse config: $($_.Exception.Message)" -Color Red
    exit 1
}

# --- Load Hive ---

Write-Log ""
Write-Log "Loading Default User hive..." -Color Cyan

try {
    Import-RegistryHive -File $HivePath -Key $HiveKey -Name $DriveName
    Write-Log "  [OK] Hive loaded at ${DriveName}:\" -Color Green
}
catch {
    Write-Log "  [FAIL] $($_.Exception.Message)" -Color Red
    exit 1
}

# --- Apply Settings ---

Write-Log ""
Write-Log "Applying registry settings..." -Color Cyan

$appliedCount = 0
$errorCount   = 0

foreach ($setting in $config.settings) {
    # Build the full path: PSDrive root + path from config
    $fullPath = "${DriveName}:\$($setting.path)"

    # Log what we're doing (use _category and _description if present)
    $category = if ($setting._category) { "[$($setting._category)] " } else { "" }
    $desc     = if ($setting._description) { $setting._description } else { $setting.path }
    Write-Log ""
    Write-Log "  ${category}$desc"
    Write-Log "  Path: $($setting.path)"

    try {
        # Create the key if it doesn't exist
        if (-not (Test-Path $fullPath)) {
            New-Item -Path $fullPath -Force | Out-Null
            Write-Log "    Created key." -Color Yellow
        }

        # Set each property
        # ConvertFrom-Json turns JSON objects into PSCustomObject, so we iterate NoteProperties
        $properties = $setting.properties
        foreach ($prop in $properties.PSObject.Properties) {
            $propName  = $prop.Name
            $propValue = $prop.Value

            # Determine registry type from the JSON value type
            # Integers → DWORD, Strings → String
            $propType = if ($propValue -is [int] -or $propValue -is [long]) {
                'DWord'
            } else {
                'String'
            }

            Set-ItemProperty -Path $fullPath -Name $propName -Value $propValue -Type $propType -Force
            Write-Log "    Set $propName = $propValue ($propType)" -Color Green
        }

        $appliedCount++
    }
    catch {
        Write-Log "    [ERROR] $($_.Exception.Message)" -Color Red
        $errorCount++
    }
}

# --- Unload Hive ---

Write-Log ""
Write-Log "Unloading Default User hive..." -Color Cyan

try {
    Remove-RegistryHive -Name $DriveName
    Write-Log "  [OK] Hive unloaded successfully." -Color Green
}
catch {
    Write-Log "  [WARN] $($_.Exception.Message)" -Color Red
    Write-Log "  You may need to manually unload: reg unload `"$HiveKey`"" -Color Yellow
}

# --- Summary ---

Write-Log ""
Write-Log ("=" * 60) -Color Cyan
Write-Log "  Summary" -Color Cyan
Write-Log ("=" * 60) -Color Cyan
Write-Log "  Settings applied: $appliedCount"
Write-Log "  Errors: $errorCount"

if ($errorCount -eq 0) {
    Write-Log ""
    Write-Log "  All settings applied successfully." -Color Green
    Write-Log "  New user profiles will inherit these settings." -Color Green
}
else {
    Write-Log ""
    Write-Log "  Some settings failed. Review the log for details." -Color Yellow
}

Write-Log ""
Write-Log "Log saved to: $LogFile" -Color Cyan