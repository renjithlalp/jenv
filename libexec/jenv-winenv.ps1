# jenv-winenv.ps1 - read and write the PERSISTENT Windows environment (USER and SYSTEM variables).
# Dot-sourced by jenv-core.ps1. Needs jenv-env.ps1 (JenvNorm, JenvReadLine) to be loaded first.
#
# - Uses the registry API, never setx: setx truncates PATH at 1024 characters and expands %VARS%.
# - PATH is always written as REG_EXPAND_SZ so existing %VAR% entries keep working.
# - Only the Java entry in PATH is replaced (in place); everything else is left exactly as it was.
# - Before a scope is changed its old JAVA_HOME and PATH are saved in <jenv>\backups.
# - Output goes through Write-Host and functions return nothing unless stated, so a caller can
#   never mistake a message for a return value. Problems are reported with 'throw'.

$script:WinMachineSub = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'

function WinLabel([string]$Which) { if ($Which -eq 'Machine') { return 'SYSTEM' } else { return 'USER' } }

function WinOpenKey([string]$Which, [bool]$Writable) {
    if ($Which -eq 'Machine') {
        return [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($script:WinMachineSub, $Writable)
    }
    return [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $Writable)
}

# Returns @{ Value; Kind } or $null when the variable does not exist. %VARS% are NOT expanded.
function WinGetRaw([string]$Which, [string]$Name) {
    $k = WinOpenKey $Which $false
    if (-not $k) { return $null }
    try {
        $v = $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $v) { return $null }
        return [pscustomobject]@{ Value = [string]$v; Kind = [string]$k.GetValueKind($Name) }
    } finally { $k.Close() }
}

# $Value $null deletes the variable.
function WinSetRaw([string]$Which, [string]$Name, [object]$Value, [string]$Kind) {
    $k = WinOpenKey $Which $true
    if (-not $k) { throw ("cannot open the {0} environment for writing." -f (WinLabel $Which)) }
    try {
        if ($null -eq $Value) { $k.DeleteValue($Name, $false) }
        else { $k.SetValue($Name, [string]$Value, [Microsoft.Win32.RegistryValueKind]$Kind) }
    } finally { $k.Close() }
}

function WinIsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Tells running programs (Explorer, new terminals) that the environment changed.
function WinBroadcast {
    try {
        if (-not ('JenvWin.Native' -as [type])) {
            Add-Type -Namespace JenvWin -Name Native -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        }
        $r = [UIntPtr]::Zero
        [void][JenvWin.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$r)
    } catch { }
}

# State of both scopes: .Machine / .User, each with .JavaHome and .Path (raw objects or $null).
function WinGetState {
    $s = [ordered]@{}
    foreach ($w in 'Machine', 'User') {
        $s[$w] = [pscustomobject]@{ JavaHome = (WinGetRaw $w 'JAVA_HOME'); Path = (WinGetRaw $w 'Path') }
    }
    return $s
}

# ---------------------------------------------------------------- PATH logic

function WinHasJava([string]$Dir) {
    try {
        if (-not $Dir -or $Dir -match '%') { return $false }
        return ((Test-Path -LiteralPath (Join-Path $Dir 'java.exe')) -or (Test-Path -LiteralPath (Join-Path $Dir 'javac.exe')))
    } catch { return $false }
}

# Normalized "<home>\bin" and "<home>\jre\bin" of every JDK home that may appear in an old PATH.
function WinKnownBins([string]$Root, $State, [string]$NewHome) {
    $homes = @($NewHome, $env:JAVA_HOME, (Join-Path $Root 'current'))
    foreach ($w in 'Machine', 'User') {
        if ($State[$w].JavaHome) { $homes += [Environment]::ExpandEnvironmentVariables($State[$w].JavaHome.Value) }
    }
    $bins = @()
    foreach ($h in $homes) {
        if (-not $h) { continue }
        $b = $h.Trim().Trim('"').TrimEnd('\', '/')
        if (-not $b) { continue }
        $bins += (JenvNorm ($b + '\bin'))
        $bins += (JenvNorm ($b + '\jre\bin'))
    }
    return @($bins | Select-Object -Unique)
}

# What kind of Java entry is this PATH entry?
#   'ref'   -> %JAVA_HOME%\bin (or ...\jre\bin)
#   'known' -> the bin folder of a JAVA_HOME that is being replaced
#   'java'  -> any other folder that contains java.exe / javac.exe (Oracle javapath, old JDK folders, ...)
#   $null   -> not a Java entry (jenv's shims hold java.cmd only, so they never match)
function WinEntryKind([string]$Entry, [string[]]$KnownBins, [bool]$Strict) {
    $n = JenvNorm $Entry
    if ($n -match '^%java_home%[\\/](jre[\\/])?bin$') { return 'ref' }
    $expanded = [Environment]::ExpandEnvironmentVariables($Entry).Trim().Trim('"')
    $x = JenvNorm $expanded
    foreach ($b in $KnownBins) { if ($b -and $x -eq $b) { return 'known' } }
    if ($Strict) { return $null }
    $sysRoot = JenvNorm $env:SystemRoot
    if ($sysRoot -and $x.StartsWith($sysRoot)) { return $null }
    if (WinHasJava $expanded) { return 'java' }
    return $null
}

# Replaces the first Java entry of a PATH value with the new JDK's bin and drops other Java entries.
# Returns @{ Value; Found; Notes }. Nothing to do when Notes is empty.
function WinNewPath([string]$Raw, [string]$NewHome, [string[]]$KnownBins, [bool]$Strict, [bool]$AddIfMissing) {
    $newBin = $NewHome.TrimEnd('\', '/') + '\bin'
    $out = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]
    $placed = $false
    foreach ($e in ($Raw -split ';')) {
        if ([string]::IsNullOrWhiteSpace($e)) { continue }
        $kind = WinEntryKind $e $KnownBins $Strict
        if (-not $kind) { $out.Add($e); continue }
        if (-not $placed) {
            $placed = $true
            if ($kind -eq 'ref') { $repl = '%JAVA_HOME%\bin' } else { $repl = $newBin }
            $out.Add($repl)
            if ($e -ne $repl) { $notes.Add("replaced '$e' with '$repl'") }
        } else {
            $notes.Add("removed  '$e'")
        }
    }
    if (-not $placed -and $AddIfMissing) {
        $out.Insert(0, $newBin)
        $notes.Add("added    '$newBin' at the front")
    }
    return [pscustomobject]@{ Value = ($out -join ';'); Found = $placed; Notes = @($notes) }
}

# ---------------------------------------------------------------- backup / restore

function WinBackupDir([string]$Root) { return (Join-Path $Root 'backups') }
function WinSuffix([string]$Which) { if ($Which -eq 'Machine') { return 'system' } else { return 'user' } }

function WinBackup([string]$Root, [string]$Which, $St) {
    $dir = WinBackupDir $Root
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $obj = [ordered]@{ Scope = $Which; Time = (Get-Date).ToString('s'); JavaHome = $null; Path = $null }
    if ($St.JavaHome) { $obj.JavaHome = [ordered]@{ Value = $St.JavaHome.Value; Kind = $St.JavaHome.Kind } }
    if ($St.Path)     { $obj.Path     = [ordered]@{ Value = $St.Path.Value;     Kind = $St.Path.Kind } }
    $file = Join-Path $dir ('backup-{0}-{1}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), (WinSuffix $Which))
    [IO.File]::WriteAllText($file, ($obj | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  backup saved: $file"
}

# ---------------------------------------------------------------- sync one scope

# $Opts: NoPath, AddPath, Strict, WhatIf (booleans). Writes JAVA_HOME and the Java PATH entry of ONE scope.
function WinSyncScope([string]$Root, [string]$Which, [string]$NewHome, $Opts, $State, [string[]]$KnownBins) {
    $label = WinLabel $Which
    $st = $State[$Which]
    Write-Host "$label environment"

    $oldHome = $null
    $homeKind = 'String'
    if ($st.JavaHome) {
        $oldHome = $st.JavaHome.Value
        if ($st.JavaHome.Kind -eq 'ExpandString') { $homeKind = 'ExpandString' }
    }
    $homeChanges = $true
    if ($oldHome -and ((JenvNorm $oldHome) -eq (JenvNorm $NewHome))) { $homeChanges = $false }

    $pathRes = $null
    if (-not $Opts.NoPath) {
        $raw = ''
        if ($st.Path) { $raw = $st.Path.Value }
        $pathRes = WinNewPath $raw $NewHome $KnownBins $Opts.Strict $Opts.AddPath
    }
    $pathChanges = ($pathRes -and $pathRes.Notes.Count -gt 0)

    if (($homeChanges -or $pathChanges) -and -not $Opts.WhatIf) { WinBackup $Root $Which $st }

    # JAVA_HOME
    $was = '(not set)'
    if ($oldHome) { $was = $oldHome }
    if (-not $homeChanges) { Write-Host "  JAVA_HOME : already $NewHome" }
    elseif ($Opts.WhatIf) { Write-Host "  JAVA_HOME : would change $was  ->  $NewHome" }
    else {
        WinSetRaw $Which 'JAVA_HOME' $NewHome $homeKind
        Write-Host "  JAVA_HOME : $was  ->  $NewHome"
    }

    # PATH
    if ($Opts.NoPath) { Write-Host '  PATH      : left alone (--no-path)' }
    elseif ($pathChanges) {
        $prefix = '  PATH      : '
        if ($Opts.WhatIf) { $prefix = '  PATH      : would change - ' }
        foreach ($n in $pathRes.Notes) { Write-Host ($prefix + $n); $prefix = '              ' }
        if (-not $Opts.WhatIf) { WinSetRaw $Which 'Path' $pathRes.Value 'ExpandString' }
    }
    elseif ($pathRes.Found) { Write-Host '  PATH      : Java entry already correct' }
    else { Write-Host "  PATH      : no Java entry found (jenv's shims resolve java; use --add-path to add one)" }

    if (($homeChanges -or $pathChanges) -and -not $Opts.WhatIf) { WinBroadcast }
}

function WinRestoreScope([string]$Root, [string]$Which, [string]$File, [bool]$WhatIf) {
    $label = WinLabel $Which
    Write-Host "$label environment"
    if (-not $File) {
        $latest = Get-ChildItem -LiteralPath (WinBackupDir $Root) -Filter ('backup-*-{0}.json' -f (WinSuffix $Which)) -File -ErrorAction SilentlyContinue |
                  Sort-Object Name -Descending | Select-Object -First 1
        if (-not $latest) { throw "no $label backup found in $(WinBackupDir $Root)." }
        $File = $latest.FullName
    }
    if (-not (Test-Path -LiteralPath $File)) { throw "backup file not found: $File" }
    $b = [IO.File]::ReadAllText($File) | ConvertFrom-Json
    if ($b.Scope -ne $Which) { throw "$File is a $($b.Scope) backup, not a $Which one." }
    Write-Host "  from $File (taken $($b.Time))"
    foreach ($pair in @(@('JAVA_HOME', 'JavaHome'), @('Path', 'Path'))) {
        $name = $pair[0]
        $item = $b.($pair[1])
        if ($null -eq $item) {
            if ($WhatIf) { Write-Host "  $name : would be deleted (it did not exist)" }
            else { WinSetRaw $Which $name $null 'String'; Write-Host "  $name : deleted (it did not exist before)" }
        } else {
            if ($WhatIf) { Write-Host "  $name : would be restored" }
            else { WinSetRaw $Which $name $item.Value $item.Kind; Write-Host "  $name : restored" }
        }
    }
    if (-not $WhatIf) { WinBroadcast }
}

# ---------------------------------------------------------------- show / verify

function WinJavaEntries([string]$Raw) {
    $found = @()
    if (-not $Raw) { return $found }
    foreach ($e in ($Raw -split ';')) {
        if ([string]::IsNullOrWhiteSpace($e)) { continue }
        $k = WinEntryKind $e @() $false
        if ($k) { $found += $e }
    }
    return $found
}

# Effective JAVA_HOME and the first java.exe on the combined PATH, as a NEW process would see them.
# Prints findings. When $NewHome is given, anything not pointing at it is reported as a warning.
function WinVerify([string]$Root, [string]$NewHome) {
    $st = WinGetState
    $eff = $null
    $src = ''
    if ($st.User.JavaHome) { $eff = $st.User.JavaHome.Value; $src = 'USER' }
    elseif ($st.Machine.JavaHome) { $eff = $st.Machine.JavaHome.Value; $src = 'SYSTEM' }

    if (-not $eff) {
        Write-Host '  [warn] JAVA_HOME is not set in USER or SYSTEM.'
    } else {
        $effExp = [Environment]::ExpandEnvironmentVariables($eff)
        if ($NewHome -and ((JenvNorm $effExp) -ne (JenvNorm $NewHome))) {
            Write-Host "  [warn] new terminals will use JAVA_HOME = $effExp (from $src), not $NewHome."
            if ($src -eq 'USER') { Write-Host '         The USER value overrides the SYSTEM one - run again with --user (or --both).' }
        } else {
            Write-Host "  [ ok ] new terminals get JAVA_HOME = $effExp (from $src)"
        }
        $firstDir = $null
        foreach ($w in 'Machine', 'User') {
            if (-not $st[$w].Path) { continue }
            foreach ($e in ($st[$w].Path.Value -split ';')) {
                if ([string]::IsNullOrWhiteSpace($e)) { continue }
                $dir = ($e -replace '(?i)%JAVA_HOME%', $effExp)
                $dir = [Environment]::ExpandEnvironmentVariables($dir).Trim().Trim('"')
                if (WinHasJava $dir) { $firstDir = $dir; break }
            }
            if ($firstDir) { break }
        }
        if (-not $firstDir) {
            Write-Host "  [info] no java.exe folder on the Windows PATH; 'java' resolves through the jenv shims."
        } elseif ($NewHome -and ((JenvNorm $firstDir) -ne (JenvNorm ($NewHome.TrimEnd('\', '/') + '\bin')))) {
            Write-Host "  [warn] new terminals will find java.exe in $firstDir first, not in the new JDK."
        } else {
            Write-Host "  [ ok ] new terminals find java.exe first in $firstDir"
        }
        $shims = JenvNorm (Join-Path $Root 'shims')
        $allEntries = @()
        foreach ($w in 'Machine', 'User') { if ($st[$w].Path) { $allEntries += ($st[$w].Path.Value -split ';') } }
        $shimAt = -1
        $javaAt = -1
        for ($i = 0; $i -lt $allEntries.Count; $i++) {
            $n = JenvNorm ([Environment]::ExpandEnvironmentVariables($allEntries[$i]))
            if ($n -eq $shims -and $shimAt -lt 0) { $shimAt = $i }
            if ($javaAt -lt 0 -and $allEntries[$i] -and (WinEntryKind $allEntries[$i] @() $false)) { $javaAt = $i }
        }
        if ($javaAt -ge 0 -and ($shimAt -lt 0 -or $javaAt -lt $shimAt)) {
            Write-Host "  [info] java.exe comes before jenv's shims on PATH, so a .java-version file will not change 'java'."
            Write-Host "         (use --no-path next time to change only JAVA_HOME and keep the shims in charge)"
        }
    }
}

function WinShow([string]$Root) {
    $st = WinGetState
    foreach ($w in 'Machine', 'User') {
        Write-Host ((WinLabel $w) + ' environment')
        if ($st[$w].JavaHome) { Write-Host ("  JAVA_HOME : {0}  [{1}]" -f $st[$w].JavaHome.Value, $st[$w].JavaHome.Kind) }
        else { Write-Host '  JAVA_HOME : (not set)' }
        $entries = @(WinJavaEntries $(if ($st[$w].Path) { $st[$w].Path.Value } else { '' }))
        if ($entries.Count -eq 0) { Write-Host '  PATH      : no Java entries' }
        else {
            $prefix = '  PATH      : '
            foreach ($e in $entries) { Write-Host ($prefix + $e); $prefix = '              ' }
        }
    }
    Write-Host 'Effective for new terminals'
    WinVerify $Root ''
}

# ---------------------------------------------------------------- elevation

# Runs jenv-core.ps1 again in an elevated window and returns its exit code.
function WinElevate([string]$CoreScript, [string[]]$ScriptArgs) {
    $exe = (Get-Process -Id $PID).Path
    $line = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $CoreScript, ($ScriptArgs -join ' ')
    Write-Host 'Administrator rights are needed for the SYSTEM environment - a UAC prompt will open.'
    try { $p = Start-Process -FilePath $exe -ArgumentList $line -Verb RunAs -Wait -PassThru -ErrorAction Stop }
    catch { throw 'the UAC prompt was cancelled or elevation failed; the SYSTEM environment was not changed.' }
    return $p.ExitCode
}
