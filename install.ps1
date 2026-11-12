<#
.SYNOPSIS
  Installs jenv-win for the current user (user-level environment variables only, no admin needed).

.DESCRIPTION
  - sets JENV_HOME to this folder
  - sets JAVA_HOME to <this folder>\current (a junction that 'jenv global' re-points)
  - puts <this folder>\shims and <this folder>\bin at the front of your USER Path
  - registers JDKs it can find (skip with -SkipScan)
  - optional: -ShellIntegration enables 'jenv use / deactivate / init' in your PowerShell and Git Bash profiles

  Run it with:   powershell -ExecutionPolicy Bypass -File .\install.ps1
  Undo it with:  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
  Open a NEW terminal afterwards - existing terminals keep their old environment.
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$ShellIntegration,
    [switch]$SkipScan
)

$ErrorActionPreference = 'Stop'
$Root    = $PSScriptRoot
$Shims   = Join-Path $Root 'shims'
$Bin     = Join-Path $Root 'bin'
$Current = Join-Path $Root 'current'
$Core    = Join-Path $Root 'libexec\jenv-core.ps1'

function Invoke-Core {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Core @args
}

function Get-UserPathRaw {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    try { return [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    finally { $key.Close() }
}

function Set-UserPathRaw([string]$Value) {
    # Written as REG_EXPAND_SZ so existing %VAR% entries keep working.
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try { $key.SetValue('Path', $Value, [Microsoft.Win32.RegistryValueKind]::ExpandString) }
    finally { $key.Close() }
}

function Remove-PathEntries([string[]]$Entries, [string[]]$Drop) {
    $dropSet = @{}
    foreach ($d in $Drop) { $dropSet[$d.TrimEnd('\').ToLower()] = $true }
    return @($Entries | Where-Object { $_ -and -not $dropSet.ContainsKey($_.TrimEnd('\').ToLower()) })
}

# ------------------------------------------------------------------ uninstall
if ($Uninstall) {
    $entries = (Get-UserPathRaw) -split ';'
    Set-UserPathRaw ((Remove-PathEntries $entries @($Shims, $Bin)) -join ';')

    $userJavaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'User')
    $prev = [Environment]::GetEnvironmentVariable('JENV_PREV_JAVA_HOME', 'User')
    if ($userJavaHome -and $userJavaHome.TrimEnd('\') -ieq $Current) {
        [Environment]::SetEnvironmentVariable('JAVA_HOME', $(if ($prev) { $prev } else { $null }), 'User')
    }
    [Environment]::SetEnvironmentVariable('JENV_PREV_JAVA_HOME', $null, 'User')
    [Environment]::SetEnvironmentVariable('JENV_HOME', $null, 'User')   # also broadcasts the change

    try { [IO.Directory]::Delete($Current) } catch { }
    Invoke-Core init --remove

    Write-Host 'jenv-win removed from your user environment. This folder was left in place; delete it if you like.'
    Write-Host 'Open a new terminal for the change to take effect.'
    return
}

# ------------------------------------------------------------------ install
Write-Host "Installing jenv-win from $Root"

try { Get-ChildItem -LiteralPath $Root -Recurse -File | Unblock-File } catch { }
New-Item -ItemType Directory -Force -Path (Join-Path $Root 'versions') | Out-Null

# 1. register JDKs and generate shims
if ($SkipScan) { Invoke-Core rehash } else { Invoke-Core scan }

# 2. environment variables (user scope)
$oldJavaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'User')
if ($oldJavaHome -and $oldJavaHome.TrimEnd('\') -ine $Current) {
    Write-Host "Note: your user JAVA_HOME was '$oldJavaHome'. It is replaced by '$Current' (old value saved in JENV_PREV_JAVA_HOME)."
    [Environment]::SetEnvironmentVariable('JENV_PREV_JAVA_HOME', $oldJavaHome, 'User')
}

# 3. PATH (registry write first, then SetEnvironmentVariable below broadcasts the change)
$entries = (Get-UserPathRaw) -split ';'
$entries = Remove-PathEntries $entries @($Shims, $Bin)
Set-UserPathRaw ((@($Shims, $Bin) + $entries) -join ';')

[Environment]::SetEnvironmentVariable('JAVA_HOME', $Current, 'User')
[Environment]::SetEnvironmentVariable('JENV_HOME', $Root, 'User')

# 4. warn about other Java installs that sit earlier in PATH than the user PATH
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$shadow = @()
foreach ($e in ($machinePath -split ';')) {
    if (-not $e) { continue }
    $dir = [Environment]::ExpandEnvironmentVariables($e)
    if (Test-Path -LiteralPath (Join-Path $dir 'java.exe')) { $shadow += $dir }
}
if ($shadow.Count -gt 0) {
    Write-Host ''
    Write-Host 'WARNING: these SYSTEM Path entries contain java.exe and are searched BEFORE your user Path,'
    Write-Host '         so they will shadow the jenv shims:'
    $shadow | ForEach-Object { Write-Host "           $_" }
    Write-Host '         Remove them (System Properties > Environment Variables > System variables > Path),'
    Write-Host '         or put the jenv shims folder in the SYSTEM Path above them. See README, "Troubleshooting".'
}

# 5. optional shell integration (makes 'jenv use / deactivate / init' work in PowerShell and Git Bash)
if ($ShellIntegration) {
    Invoke-Core init --install
}

Write-Host ''
Write-Host 'Done. Open a NEW terminal, then:'
Write-Host '    jenv list                # registered JDKs'
Write-Host '    jenv global <name>       # pick the default'
Write-Host '    jenv doctor              # check that everything is wired up'
if (-not $ShellIntegration) {
    Write-Host ''
    Write-Host "Tip: run 'jenv init --install' to enable 'jenv use' in PowerShell and Git Bash"
    Write-Host '     (cmd.exe works already).'
}
