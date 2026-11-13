# jenv-core.ps1 - management commands for jenv-win (compatible with Windows PowerShell 5.1 and pwsh 7+).
# Called by bin\jenv.cmd and bin\jenv. Not meant to be run directly.
$ErrorActionPreference = 'Stop'

$LibExec     = $PSScriptRoot
$Root        = Split-Path -Parent $LibExec
$VersionsDir = Join-Path $Root 'versions'
$ShimsDir    = Join-Path $Root 'shims'
$GlobalFile  = Join-Path $Root 'version'
$CurrentLink = Join-Path $Root 'current'
$BeginMark   = '# >>> jenv >>>'
$EndMark     = '# <<< jenv <<<'

. (Join-Path $LibExec 'jenv-env.ps1')
. (Join-Path $LibExec 'jenv-winenv.ps1')

# ---------------------------------------------------------------- helpers

function Fail([string]$Message) {
    [Console]::Error.WriteLine("jenv: $Message")
    exit 1
}

function Write-Text([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-Jdk([string]$Dir) { return (Test-Path -LiteralPath (Join-Path $Dir 'bin\javac.exe')) }
function Get-JdkHome([string]$Name) { return (JenvJdkHome $Root $Name) }

function Get-JdkInfo([string]$Dir) {
    $ver = $null
    $rel = Join-Path $Dir 'release'
    if (Test-Path -LiteralPath $rel) {
        $m = Select-String -LiteralPath $rel -Pattern '^JAVA_VERSION="?([^"\r\n]+)"?' | Select-Object -First 1
        if ($m) { $ver = $m.Matches[0].Groups[1].Value }
    }
    $major = $null
    if ($ver) {
        $parts = $ver -split '[._+-]'
        if ($parts[0] -eq '1' -and $parts.Count -gt 1) { $major = $parts[1] } else { $major = $parts[0] }
    }
    return [pscustomobject]@{ Version = $ver; Major = $major }
}

function Get-Registered {
    # name -> path
    $map = @{}
    if (Test-Path -LiteralPath $VersionsDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $VersionsDir -File)) {
            $map[$f.Name] = JenvReadLine $f.FullName
        }
    }
    return $map
}

# What the shims (and 'jenv exec') would use: session override > nearest .java-version > global.
function Resolve-Active {
    if ($env:JENV_VERSION) { return @{ Name = $env:JENV_VERSION.Trim(); Source = 'session override (jenv use)' } }
    return (JenvFindDefault $Root (Get-Location).ProviderPath)
}

function Get-ActiveJdk {
    $a = Resolve-Active
    if (-not $a) { Fail "no Java version selected. Run 'jenv global <name>' (see 'jenv list')." }
    $jdk = Get-JdkHome $a.Name
    if (-not $jdk) { Fail "version '$($a.Name)' (set by $($a.Source)) is not registered. See 'jenv list'." }
    return [pscustomobject]@{ Name = $a.Name; Source = $a.Source; Home = $jdk }
}

function Assert-Registered([string]$Name) {
    if (-not (JenvValidName $Name)) { Fail "invalid version name '$Name' (use letters, digits, . _ + -)." }
    if (-not (Get-JdkHome $Name)) { Fail "version '$Name' is not registered. See 'jenv list'." }
}

function Update-Current([string]$Jdk) {
    # 'current' is a junction to the global JDK, so JAVA_HOME=<jenv>\current always follows 'jenv global'.
    try { [IO.Directory]::Delete($CurrentLink) } catch { }
    if ($Jdk) { New-Item -ItemType Junction -Path $CurrentLink -Target $Jdk | Out-Null }
}

# ---------------------------------------------------------------- rehash

function Get-ShimTools {
    $wanted = @()
    foreach ($line in (Get-Content -LiteralPath (Join-Path $LibExec 'tools.txt'))) {
        $t = $line.Trim()
        if ($t.Length -gt 0 -and -not $t.StartsWith('#')) { $wanted += $t }
    }
    $available = @{}
    foreach ($p in (Get-Registered).Values) {
        if (-not $p) { continue }
        $bin = Join-Path $p 'bin'
        if (-not (Test-Path -LiteralPath $bin)) { continue }
        foreach ($exe in (Get-ChildItem -LiteralPath $bin -Filter '*.exe' -File -ErrorAction SilentlyContinue)) {
            $available[[IO.Path]::GetFileNameWithoutExtension($exe.Name).ToLower()] = $true
        }
    }
    if ($available.Count -gt 0) { return @($wanted | Where-Object { $available.ContainsKey($_.ToLower()) }) }
    return @('java', 'javac', 'javaw', 'jar', 'javadoc', 'keytool', 'jshell')
}

function Invoke-Rehash {
    New-Item -ItemType Directory -Force -Path $ShimsDir | Out-Null
    New-Item -ItemType Directory -Force -Path $VersionsDir | Out-Null
    $tools = Get-ShimTools

    $cmdTpl = (Get-Content -Raw -LiteralPath (Join-Path $LibExec 'shim.cmd')) -replace "`r?`n", "`r`n"
    $shTpl  = (Get-Content -Raw -LiteralPath (Join-Path $LibExec 'shim.sh'))  -replace "`r?`n", "`n"

    Get-ChildItem -LiteralPath $ShimsDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
    foreach ($t in $tools) {
        [IO.File]::WriteAllText((Join-Path $ShimsDir "$t.cmd"), $cmdTpl, [Text.Encoding]::ASCII)
        Write-Text (Join-Path $ShimsDir $t) $shTpl
    }
    Write-Output ("Rehashed: {0} shim(s) in {1}" -f $tools.Count, $ShimsDir)
}

# ---------------------------------------------------------------- add / remove / scan

function Add-Version([string]$Name, [string]$Path, [switch]$Quiet) {
    if (-not (JenvValidName $Name)) { Fail "invalid version name '$Name' (use letters, digits, . _ + -)." }
    try { $full = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath.TrimEnd('\') }
    catch { Fail "path not found: $Path" }
    if (-not (Test-Jdk $full)) { Fail "'$full' is not a JDK (bin\javac.exe not found)." }
    New-Item -ItemType Directory -Force -Path $VersionsDir | Out-Null
    $existed = Test-Path -LiteralPath (Join-Path $VersionsDir $Name)
    Write-Text (Join-Path $VersionsDir $Name) ($full + "`n")
    if (-not $Quiet) {
        if ($existed) { Write-Output "Updated $Name -> $full" } else { Write-Output "Added $Name -> $full" }
    }
    # keep the junction fresh if this is the global version
    if ((JenvReadLine $GlobalFile) -eq $Name) { Update-Current $full }
}

function Get-ScanRoots([string[]]$Extra) {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($e in $Extra) { if ($e) { $roots.Add($e) } }
    $bases = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432) | Where-Object { $_ }
    $vendors = 'Java', 'Eclipse Adoptium', 'Eclipse Foundation', 'Microsoft', 'Zulu', 'Amazon Corretto',
               'BellSoft', 'Semeru', 'IBM', 'Temurin', 'OpenJDK', 'AdoptOpenJDK', 'RedHat', 'GraalVM',
               'Oracle', 'SapMachine', 'Liberica'
    foreach ($b in $bases) { foreach ($v in $vendors) { $roots.Add((Join-Path $b $v)) } }
    if ($env:USERPROFILE) {
        $roots.Add((Join-Path $env:USERPROFILE '.jdks'))             # IntelliJ IDEA downloads
        $roots.Add((Join-Path $env:USERPROFILE 'scoop\apps'))        # Scoop
    }
    return $roots
}

function Invoke-Scan([string[]]$Extra) {
    $registered = Get-Registered
    $byPath = @{}
    foreach ($k in $registered.Keys) { if ($registered[$k]) { $byPath[$registered[$k].ToLower()] = $k } }

    $added = 0
    $seen = @{}
    foreach ($r in (Get-ScanRoots $Extra)) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $cands = @()
        if (Test-Jdk $r) { $cands += $r }
        foreach ($d in (Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue)) {
            if (Test-Jdk $d.FullName) { $cands += $d.FullName }
            elseif (Test-Jdk (Join-Path $d.FullName 'current')) { $cands += (Join-Path $d.FullName 'current') }
        }
        foreach ($c in $cands) {
            $full = (Resolve-Path -LiteralPath $c).ProviderPath.TrimEnd('\')
            $key = $full.ToLower()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            if ($byPath.ContainsKey($key)) { Write-Output ("  already registered as {0}: {1}" -f $byPath[$key], $full); continue }

            $info = Get-JdkInfo $full
            $leaf = Split-Path -Leaf $full
            if ($leaf -eq 'current') { $leaf = Split-Path -Leaf (Split-Path -Parent $full) }
            $leaf = $leaf -replace '[^A-Za-z0-9._+-]', '_'

            $name = $null
            if ($info.Major) {
                if (-not $registered.ContainsKey($info.Major)) { $name = $info.Major }
                else { $name = "$($info.Major)-$leaf" }
            } else { $name = $leaf }
            if ($registered.ContainsKey($name)) { Write-Output "  skipped (name '$name' already used): $full"; continue }
            if (-not (JenvValidName $name)) { Write-Output "  skipped (bad name '$name'): $full"; continue }

            Add-Version $name $full -Quiet
            $registered[$name] = $full
            $byPath[$key] = $name
            $added++
            Write-Output ("  added {0,-16} {1,-12} {2}" -f $name, $info.Version, $full)
        }
    }
    Write-Output "Scan finished: $added new JDK(s)."
    if ($added -gt 0) { Invoke-Rehash }
}

# ---------------------------------------------------------------- shell profiles (init --install / --remove)

function Get-ProfilePaths {
    $docs = [Environment]::GetFolderPath('MyDocuments')
    return @(
        (Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
        (Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1')
    )
}

function Test-Block([string]$File) {
    if (-not (Test-Path -LiteralPath $File)) { return $false }
    return ([IO.File]::ReadAllText($File)).Contains($BeginMark)
}

function Remove-Block([string]$File) {
    if (-not (Test-Path -LiteralPath $File)) { return $false }
    $text = [IO.File]::ReadAllText($File)
    $pattern = '(?s)\r?\n?' + [regex]::Escape($BeginMark) + '.*?' + [regex]::Escape($EndMark) + '\r?\n?'
    $new = [regex]::Replace($text, $pattern, "`n")
    if ($new -eq $text) { return $false }
    [IO.File]::WriteAllText($File, $new, (New-Object System.Text.UTF8Encoding($false)))
    return $true
}

function Add-Block([string]$File, [string]$Body) {
    $dir = Split-Path -Parent $File
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [void](Remove-Block $File)
    [IO.File]::AppendAllText($File, "`n$BeginMark`n$Body`n$EndMark`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Install-ShellIntegration {
    $init = Join-Path $Root 'bin\jenv-init.ps1'
    foreach ($p in (Get-ProfilePaths)) {
        # only touch the PowerShell 7 profile if PowerShell 7 has been used on this machine
        if ($p -like '*\PowerShell\*' -and -not (Test-Path -LiteralPath (Split-Path -Parent $p))) { continue }
        Add-Block $p ('. "' + $init + '"')
        Write-Output "  updated $p"
    }
    $rc = Join-Path $env:USERPROFILE '.bashrc'
    Add-Block $rc 'eval "$(command jenv init)"'
    Write-Output "  updated $rc"
    Write-Output 'Open a new PowerShell / Git Bash window to load it.'
}

function Remove-ShellIntegration {
    $files = @(Get-ProfilePaths) + @((Join-Path $env:USERPROFILE '.bashrc'))
    foreach ($f in $files) { if (Remove-Block $f) { Write-Output "  cleaned $f" } }
    Write-Output 'Shell integration removed.'
}

# ---------------------------------------------------------------- doctor

$script:DocProblems = 0
$script:DocWarnings = 0
function DocOk([string]$m)   { Write-Output "  [ ok ] $m" }
function DocInfo([string]$m) { Write-Output "  [info] $m" }
function DocWarn([string]$m) { $script:DocWarnings++; Write-Output "  [warn] $m" }
function DocFail([string]$m) { $script:DocProblems++; Write-Output "  [FAIL] $m" }

function Test-HasJava([string]$Dir) {
    try {
        foreach ($n in 'java.exe', 'java.cmd', 'java.bat') {
            if (Test-Path -LiteralPath (Join-Path $Dir $n)) { return $true }
        }
    } catch { }
    return $false
}

function Invoke-Doctor {
    Write-Output "jenv-win doctor ($Root)"
    $reg = Get-Registered
    $active = $env:JENV_ACTIVE

    Write-Output ''
    Write-Output 'Environment'
    if (-not $env:JENV_HOME) { DocWarn 'JENV_HOME is not set (the shims fall back to their own folder, but install.ps1 normally sets it).' }
    elseif ((JenvNorm $env:JENV_HOME) -ne (JenvNorm $Root)) { DocFail "JENV_HOME points to '$($env:JENV_HOME)' but this jenv lives in '$Root'. Re-run install.ps1 from here." }
    else { DocOk "JENV_HOME = $($env:JENV_HOME)" }

    $jh = $env:JAVA_HOME
    $activeHome = $null
    if ($active) { $activeHome = Get-JdkHome $active }
    if (-not $jh) { DocWarn "JAVA_HOME is not set. Set it to $CurrentLink (install.ps1 does this)." }
    elseif ((JenvNorm $jh) -eq (JenvNorm $CurrentLink)) { DocOk "JAVA_HOME = $jh (follows 'jenv global')" }
    elseif ($activeHome -and (JenvNorm $jh) -eq (JenvNorm $activeHome)) { DocOk "JAVA_HOME = $jh (activated: $active)" }
    else { DocWarn "JAVA_HOME = $jh is not managed by jenv, so mvn/gradle/IDEs ignore jenv. Expected $CurrentLink - or run 'jenv use'." }

    Write-Output ''
    Write-Output 'PATH'
    $entries = @(($env:PATH -split ';') | Where-Object { $_ })
    $norm = @($entries | ForEach-Object { JenvNorm $_ })
    $shimsN = JenvNorm $ShimsDir
    $binN = JenvNorm (Join-Path $Root 'bin')
    if ($norm -notcontains $shimsN) { DocFail "the shims folder is not on PATH: $ShimsDir (if you just installed, open a NEW terminal)." }
    else { DocOk 'shims folder is on PATH' }
    if ($norm -notcontains $binN) { DocWarn "the bin folder is not on PATH: $Root\bin ('jenv' only works through its full path)." }
    else { DocOk 'bin folder is on PATH' }

    $hits = @()
    foreach ($e in $entries) {
        $dir = [Environment]::ExpandEnvironmentVariables($e).Trim('"')
        if (Test-HasJava $dir) { $hits += $dir }
    }
    $expectedFirst = $shimsN
    $expectedLabel = 'the jenv shim'
    if ($active -and $env:JENV_BIN) { $expectedFirst = JenvNorm $env:JENV_BIN; $expectedLabel = "the activated JDK ($active)" }
    if ($hits.Count -eq 0) { DocWarn "no 'java' found on PATH at all (run 'jenv rehash' if the shims are missing)." }
    elseif ((JenvNorm $hits[0]) -eq $expectedFirst) { DocOk "'java' resolves to $expectedLabel" }
    else { DocFail "'java' resolves to $($hits[0]) before $expectedLabel. Remove that PATH entry, or move the jenv shims in front (README: Troubleshooting)." }
    $others = @($hits | Where-Object { (JenvNorm $_) -ne $shimsN -and (JenvNorm $_) -ne $expectedFirst })
    if ($others.Count -gt 0) { DocInfo ('other java locations on PATH: ' + ($others -join '; ')) }

    Write-Output ''
    Write-Output 'Shims'
    if (-not (Test-Path -LiteralPath (Join-Path $ShimsDir 'java.cmd'))) { DocFail "no java.cmd shim in $ShimsDir - run 'jenv rehash'." }
    else {
        $missing = @(Get-ShimTools | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ShimsDir "$_.cmd")) })
        if ($missing.Count -gt 0) { DocWarn ('missing shims for: ' + ($missing -join ', ') + " - run 'jenv rehash'.") }
        else { DocOk ("{0} shim(s) present" -f @(Get-ChildItem -LiteralPath $ShimsDir -Filter '*.cmd' -File).Count) }
    }
    $bashShim = Join-Path $ShimsDir 'java'
    if (Test-Path -LiteralPath $bashShim) {
        if (([IO.File]::ReadAllText($bashShim)).Contains("`r")) { DocFail "the Git Bash shims have CRLF line endings - run 'jenv rehash'." }
        else { DocOk 'Git Bash shims have LF line endings' }
    } else { DocWarn "no Git Bash shim (java) - run 'jenv rehash'." }

    Write-Output ''
    Write-Output 'JDKs'
    if ($reg.Count -eq 0) { DocWarn "no JDKs registered - run 'jenv scan' or 'jenv add <name> <jdk-home>'." }
    else {
        foreach ($n in ($reg.Keys | Sort-Object)) {
            $p = $reg[$n]
            if (-not $p) { DocFail "$n has an empty registry entry - 'jenv remove $n' and add it again." }
            elseif (-not (Test-Jdk $p)) { DocFail "$n -> $p no longer contains a JDK (bin\javac.exe missing). Reinstall it or 'jenv remove $n'." }
            else { DocOk ("{0,-14} {1,-12} {2}" -f $n, (Get-JdkInfo $p).Version, $p) }
        }
    }

    Write-Output ''
    Write-Output 'Selection'
    $g = JenvReadLine $GlobalFile
    if (-not $g) { DocWarn "no global version - run 'jenv global <name>'." }
    elseif (-not $reg.ContainsKey($g)) { DocFail "the global version '$g' is not registered." }
    else {
        DocOk "global = $g"
        $linkTarget = $null
        try { $item = Get-Item -LiteralPath $CurrentLink -Force -ErrorAction Stop; $linkTarget = @($item.Target)[0] } catch { }
        if ($linkTarget) { $linkTarget = $linkTarget -replace '^\\\?\?\\', '' }
        if (-not $linkTarget) { DocFail "the junction $CurrentLink is missing - run 'jenv global $g' to recreate it." }
        elseif ((JenvNorm $linkTarget) -ne (JenvNorm $reg[$g])) { DocFail "the junction $CurrentLink points to $linkTarget but global is $($reg[$g]) - run 'jenv global $g'." }
        else { DocOk "JAVA_HOME junction -> $($reg[$g])" }
    }
    $loc = JenvFindLocal (Get-Location).ProviderPath
    if ($loc) {
        if ($reg.ContainsKey($loc.Name)) { DocOk "local = $($loc.Name) ($($loc.Source))" }
        else { DocFail "$($loc.Source) names '$($loc.Name)', which is not registered ('jenv list')." }
    } else { DocInfo 'no .java-version in this directory tree' }
    if ($env:JENV_VERSION) {
        if ($reg.ContainsKey($env:JENV_VERSION)) { DocOk "session override = $($env:JENV_VERSION)" }
        else { DocFail "the session override '$($env:JENV_VERSION)' is not registered." }
    }
    if ($active) {
        if (-not $reg.ContainsKey($active)) { DocFail "the activated version '$active' is not registered." }
        elseif (-not $env:JENV_BIN) { DocWarn "JENV_ACTIVE is set but JENV_BIN is not - run 'jenv deactivate' then 'jenv use'." }
        elseif ($norm -notcontains (JenvNorm $env:JENV_BIN)) { DocWarn "activated '$active' but $($env:JENV_BIN) is no longer on PATH - run 'jenv use' again." }
        else { DocOk "activated = $active (PATH and JAVA_HOME point at it)" }
    } else { DocInfo "nothing activated in this session; java/javac follow the shims (run 'jenv use' to also set JAVA_HOME and PATH)." }
    $sel = Resolve-Active
    if (-not $sel) { DocWarn 'no Java version is selected at all.' }
    else {
        $sp = Get-JdkHome $sel.Name
        if ($sp -and (Test-Jdk $sp)) { DocOk ("selected = {0} {1}" -f $sel.Name, (Get-JdkInfo $sp).Version) }
        else { DocFail "the selected version '$($sel.Name)' (set by $($sel.Source)) is not usable." }
    }

    Write-Output ''
    Write-Output 'Windows environment (persistent USER / SYSTEM variables)'
    $gHome = $null
    if ($g -and $reg.ContainsKey($g)) { $gHome = $reg[$g] }
    foreach ($w in 'Machine', 'User') {
        $lbl = WinLabel $w
        $jhRaw = WinGetRaw $w 'JAVA_HOME'
        if (-not $jhRaw) { DocInfo "$lbl JAVA_HOME is not set."; continue }
        $jhVal = [Environment]::ExpandEnvironmentVariables($jhRaw.Value)
        if (-not (Test-Path -LiteralPath $jhVal)) { DocWarn "$lbl JAVA_HOME = $jhVal does not exist. Fix: jenv sync --$(if ($w -eq 'Machine') { 'system' } else { 'user' })"; continue }
        if ($gHome -and ((JenvNorm $jhVal) -eq (JenvNorm $gHome))) { DocOk "$lbl JAVA_HOME = $jhVal (matches the global version '$g')" }
        elseif ((JenvNorm $jhVal) -eq (JenvNorm $CurrentLink)) { DocOk "$lbl JAVA_HOME = $jhVal (jenv's 'current' junction)" }
        else { DocInfo "$lbl JAVA_HOME = $jhVal (differs from global; 'jenv sync --$(if ($w -eq 'Machine') { 'system' } else { 'user' })' makes it match)" }
    }

    Write-Output ''
    Write-Output 'Shell integration'
    $psOk =@(Get-ProfilePaths | Where-Object { Test-Block $_ }).Count -gt 0
    $bashOk = Test-Block (Join-Path $env:USERPROFILE '.bashrc')
    if ($psOk) { DocOk 'PowerShell profile loads jenv (use / deactivate / init work in PowerShell)' }
    else { DocWarn "PowerShell: 'jenv use' cannot change the session yet - run 'jenv init --install'." }
    if ($bashOk) { DocOk 'Git Bash ~/.bashrc loads jenv' }
    else { DocWarn "Git Bash: 'jenv use' cannot change the session yet - run 'jenv init --install'." }
    DocInfo 'cmd.exe needs no setup: jenv.cmd applies use / deactivate / init directly.'
    if ($psOk) {
        $pol = 'Undefined'
        try {
            $pol = [string](Get-ExecutionPolicy -Scope CurrentUser)
            if ($pol -eq 'Undefined') { $pol = [string](Get-ExecutionPolicy -Scope LocalMachine) }
        } catch { }
        if ($pol -eq 'Undefined' -or $pol -eq 'Restricted' -or $pol -eq 'AllSigned') {
            DocWarn "PowerShell execution policy is '$pol', so your profile will not load. Fix: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
        }
    }

    Write-Output ''
    if ($script:DocProblems -eq 0 -and $script:DocWarnings -eq 0) { Write-Output 'Everything looks good.' }
    else { Write-Output ("{0} problem(s), {1} warning(s)." -f $script:DocProblems, $script:DocWarnings) }
    if ($script:DocProblems -gt 0) { exit 1 }
}

# ---------------------------------------------------------------- usage

function Show-Usage {
@'
jenv-win - Java environments for cmd, PowerShell and Git Bash

  jenv add <name> <jdk-home>   Register an installed JDK (quote paths with spaces)
  jenv remove <name>           Unregister a JDK; never deletes the installation
  jenv list                    List registered JDKs
  jenv use <name>              Activate a session override
  jenv use                     Clear override and activate nearest local/global choice
  jenv deactivate              Restore PATH and JAVA_HOME from before activation
  jenv local [name|unset]      Read, write, or remove this folder's .java-version
  jenv global [name|unset]     Read, write, or clear the saved default
  jenv global <name> --user|--system|--both
                               ...and also write it to the Windows USER / SYSTEM
                               environment variables (JAVA_HOME and the Java PATH entry)
  jenv sync --user|--system|--both
                               Copy the current global version into those Windows variables
  jenv current                Show the currently activated environment
  jenv doctor                  Diagnose JDK paths and command resolution
  jenv init                    Apply local/global choice if one exists (for profiles)

More:
  jenv scan [dir ...]          Register JDKs found in common install locations (and dir ...)
  jenv which <tool>            Print the real path of a JDK tool, e.g. javac
  jenv exec <cmd> [args]       Run a command with JAVA_HOME/PATH set to the selected JDK
  jenv rehash                  Regenerate the shims (after editing libexec\tools.txt)
  jenv init --install|--remove Add/remove jenv in your PowerShell and Git Bash profiles
  jenv root                    Print the jenv folder

Precedence: session override > nearest .java-version > saved global default.
After changing directories, run jenv use to apply that project's version.
Global means this manager's default. It only touches the Windows environment variables when
you add --user, --system or --both (see 'jenv sync' below).

Windows environment (persistent, picked up by NEW terminals and programs):
  jenv global 17 --both        Set the global version, then JAVA_HOME + Java PATH entry in USER and SYSTEM
  jenv sync --system           Apply the current global version to SYSTEM only (asks for admin rights)
  jenv sync --user --no-path   Change only JAVA_HOME, leave PATH alone (jenv's shims keep choosing java)
  jenv sync --both --whatif    Show what would change, change nothing
  jenv sync --show             Show the current Windows JAVA_HOME / Java PATH entries
  jenv sync --both --restore   Put back the values saved before the last change (see the backups folder)
  Other options: --add-path (add a Java entry if PATH has none), --only-known (only touch entries that
  belong to the old JAVA_HOME), --file <backup.json> (with --restore).
'@ | Write-Output
}

# ---------------------------------------------------------------- Windows environment (global --user/--system, sync)

function Read-WinFlags([string[]]$Items) {
    $o = [pscustomobject]@{
        User = $false; System = $false; NoPath = $false; AddPath = $false; Strict = $false
        WhatIf = $false; Restore = $false; Show = $false; Elevated = $false; File = $null; Positional = @()
    }
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $a = $Items[$i]
        switch ($a.ToLower()) {
            '--user'       { $o.User = $true }
            '--system'     { $o.System = $true }
            '--machine'    { $o.System = $true }
            '--both'       { $o.User = $true; $o.System = $true }
            '--no-path'    { $o.NoPath = $true }
            '--add-path'   { $o.AddPath = $true }
            '--only-known' { $o.Strict = $true }
            '--whatif'     { $o.WhatIf = $true }
            '--dry-run'    { $o.WhatIf = $true }
            '--restore'    { $o.Restore = $true }
            '--show'       { $o.Show = $true }
            '--elevated'   { $o.Elevated = $true }
            '--unset'      { $o.Positional += 'unset' }
            '--file' {
                if ($i + 1 -ge $Items.Count) { throw "--file needs a path." }
                $i++
                $o.File = $Items[$i]
            }
            default {
                if ($a.StartsWith('--')) { throw "unknown option '$a'. Run 'jenv help'." }
                $o.Positional += $a
            }
        }
    }
    if ($o.NoPath -and $o.AddPath) { throw '--no-path and --add-path cannot be combined.' }
    return $o
}

# Applies the global version (or a backup, with --restore) to the persistent Windows environment.
# Never returns a value: it sets $script:WinExit (0 = ok, 1 = failed).
function Invoke-WinSync($o) {
    $script:WinExit = 0
    try {
        if ($o.Show) { WinShow $Root; return }

        $scopes = @()
        if ($o.System) { $scopes += 'Machine' }
        if ($o.User)   { $scopes += 'User' }
        if ($scopes.Count -eq 0) { throw "choose a target: --user, --system or --both (or --show to just look)." }

        $newHome = $null
        $state = $null
        $known = @()
        if (-not $o.Restore) {
            $g = JenvReadLine $GlobalFile
            if (-not $g) { throw "no global version set. Run 'jenv global <name>' first." }
            $newHome = Get-JdkHome $g
            if (-not $newHome -or -not (Test-Jdk $newHome)) { throw "the global version '$g' is not usable (JDK missing at $newHome)." }
            $newHome = $newHome.TrimEnd('\', '/')
            $state = WinGetState
            $known = WinKnownBins $Root $state $newHome
            Write-Host ("Windows environment <- global version {0} ({1})" -f $g, $newHome)
        } else {
            Write-Host 'Restoring the Windows environment from backup'
        }
        $opts = [pscustomobject]@{ NoPath = $o.NoPath; AddPath = $o.AddPath; Strict = $o.Strict; WhatIf = $o.WhatIf }

        # USER first: it never needs admin rights and must be written by the signed-in user.
        if ($scopes -contains 'User') {
            if ($o.Restore) { WinRestoreScope $Root 'User' $o.File $o.WhatIf }
            else { WinSyncScope $Root 'User' $newHome $opts $state $known }
        }

        if ($scopes -contains 'Machine') {
            if ((WinIsAdmin) -or $o.WhatIf) {
                if ($o.Restore) { WinRestoreScope $Root 'Machine' $o.File $o.WhatIf }
                else { WinSyncScope $Root 'Machine' $newHome $opts $state $known }
            } else {
                # The elevated copy handles ONLY the SYSTEM scope; the global version is already saved.
                $childArgs = @('sync', '--system')
                if ($o.Restore) { $childArgs += '--restore' }
                if ($o.File)    { $childArgs += '--file'; $childArgs += ('"{0}"' -f $o.File) }
                if ($o.NoPath)  { $childArgs += '--no-path' }
                if ($o.AddPath) { $childArgs += '--add-path' }
                if ($o.Strict)  { $childArgs += '--only-known' }
                $childArgs += '--elevated'
                $code = WinElevate $PSCommandPath $childArgs
                if ($code -ne 0) { throw 'the SYSTEM update failed - see the administrator window for the reason.' }
                Write-Host 'SYSTEM environment: updated in the administrator window.'
            }
        }

        if ($o.WhatIf) { Write-Host '(dry run - nothing was changed)'; return }
        if (-not $o.Restore) {
            Write-Host 'Result'
            WinVerify $Root $newHome
        }
        Write-Host 'Open a NEW terminal to see it: running terminals keep the environment they started with.'
    } catch {
        [Console]::Error.WriteLine('jenv: ' + $_.Exception.Message)
        $script:WinExit = 1
    } finally {
        # an elevated window closes when the script ends; keep it open so the result can be read
        if ($o.Elevated) { [void](Read-Host 'Press Enter to close this window') }
    }
}

# ---------------------------------------------------------------- dispatch

$cmd = if ($args.Count -gt 0) { [string]$args[0] } else { 'help' }
$rest = @()
if ($args.Count -gt 1) { $rest = @($args[1..($args.Count - 1)] | ForEach-Object { [string]$_ }) }

switch ($cmd) {
    { $_ -in 'help', '-h', '--help', '/?' } { Show-Usage }

    'root' { Write-Output $Root }

    { $_ -in 'list', 'versions', 'ls' } {
        $reg = Get-Registered
        if ($reg.Count -eq 0) { Write-Output "No JDKs registered yet. Try 'jenv scan' or 'jenv add <name> <jdk-home>'."; break }
        $sel = Resolve-Active
        $gName = JenvReadLine $GlobalFile
        $loc = JenvFindLocal (Get-Location).ProviderPath
        foreach ($name in ($reg.Keys | Sort-Object)) {
            $p = $reg[$name]
            $mark = ' '
            if ($sel -and $sel.Name -eq $name) { $mark = '*' }
            $tags = @()
            if ($gName -eq $name) { $tags += 'global' }
            if ($loc -and $loc.Name -eq $name) { $tags += 'local' }
            if ($env:JENV_VERSION -eq $name) { $tags += 'override' }
            if ($env:JENV_ACTIVE -eq $name) { $tags += 'activated' }
            $tagText = ''
            if ($tags.Count -gt 0) { $tagText = '  [' + ($tags -join ', ') + ']' }
            $ver = ''
            $note = ''
            if ($p -and (Test-Jdk $p)) { $ver = (Get-JdkInfo $p).Version } else { $note = '  (missing!)' }
            Write-Output ("{0} {1,-16} {2,-12} {3}{4}{5}" -f $mark, $name, $ver, $p, $note, $tagText)
        }
        if ($sel) { Write-Output ''; Write-Output ("* selected: {0} (set by {1})" -f $sel.Name, $sel.Source) }
    }

    'scan'   { Invoke-Scan $rest }

    'add' {
        if ($rest.Count -lt 2) { Fail 'usage: jenv add <name> <jdk-home>' }
        Add-Version $rest[0] $rest[1]
        Invoke-Rehash
    }

    { $_ -in 'remove', 'rm', 'uninstall' } {
        if ($rest.Count -lt 1) { Fail 'usage: jenv remove <name>' }
        $n = $rest[0]
        if (-not (JenvValidName $n)) { Fail "invalid version name '$n'." }
        $f = Join-Path $VersionsDir $n
        if (-not (Test-Path -LiteralPath $f)) { Fail "version '$n' is not registered." }
        Remove-Item -LiteralPath $f -Force
        if ((JenvReadLine $GlobalFile) -eq $n) {
            Remove-Item -LiteralPath $GlobalFile -Force
            Update-Current $null
            Write-Output "Removed $n (it was the global version - pick another with 'jenv global <name>')."
        } else { Write-Output "Removed $n." }
        if ($env:JENV_ACTIVE -eq $n) { Write-Output "Note: $n is still activated in this session; run 'jenv deactivate'." }
        Invoke-Rehash
    }

    'global' {
        try { $wf = Read-WinFlags $rest } catch { Fail $_.Exception.Message }
        $wantWin = ($wf.User -or $wf.System)
        if ($wf.Positional.Count -gt 1) { Fail "usage: jenv global [name|unset] [--user|--system|--both]" }
        if ($wf.Positional.Count -eq 0) {
            if ($wantWin) { Fail "usage: jenv global <name> --user|--system|--both  (or 'jenv sync' to apply the current global)" }
            $g = JenvReadLine $GlobalFile
            if ($g) { Write-Output $g } else { Fail "no global version set. Use 'jenv global <name>'." }
        } elseif ($wf.Positional[0] -eq 'unset') {
            if ($wantWin) { Fail "'jenv global unset' does not change the Windows variables. Use 'jenv sync --restore --user|--system|--both' to put back saved values." }
            if (Test-Path -LiteralPath $GlobalFile) { Remove-Item -LiteralPath $GlobalFile -Force }
            Update-Current $null
            Write-Output 'Global version unset.'
        } else {
            $name = $wf.Positional[0]
            Assert-Registered $name
            Write-Text $GlobalFile ($name + "`n")
            Update-Current (Get-JdkHome $name)
            Write-Output ("Global version is now {0} ({1})" -f $name, (Get-JdkHome $name))
            if ($wantWin) {
                Write-Output ''
                Invoke-WinSync $wf
                if ($script:WinExit -ne 0) { exit $script:WinExit }
            }
        }
    }

    'sync' {
        try { $wf = Read-WinFlags $rest } catch { Fail $_.Exception.Message }
        if ($wf.Positional.Count -gt 0) { Fail "'jenv sync' takes no version name (it uses the global version). Try: jenv global <name> --both" }
        Invoke-WinSync $wf
        exit $script:WinExit
    }

    'local' {
        $target = Join-Path (Get-Location).ProviderPath '.java-version'
        if ($rest.Count -eq 0) {
            $loc = JenvFindLocal (Get-Location).ProviderPath
            if ($loc) { Write-Output $loc.Name } else { Fail 'no local version set in this directory tree.' }
        } elseif ($rest[0] -eq 'unset' -or $rest[0] -eq '--unset') {
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force; Write-Output 'Removed .java-version.' }
            else { Write-Output 'No .java-version in this directory.' }
        } else {
            Assert-Registered $rest[0]
            Write-Text $target ($rest[0] + "`n")
            Write-Output ("Wrote {0} ({1}). Run 'jenv use' to apply it to this session." -f $target, $rest[0])
        }
    }

    { $_ -in 'current', 'version' } {
        $sel = Resolve-Active
        $act = $env:JENV_ACTIVE
        if (-not $sel -and -not $act) { Fail "nothing selected or activated. Use 'jenv use <name>' or 'jenv global <name>'." }
        if ($act) {
            $how = 'from local/global'
            if ($env:JENV_VERSION) { $how = 'session override' }
            Write-Output ("Activated : {0} ({1})" -f $act, $how)
            Write-Output ("JAVA_HOME : {0}" -f $env:JAVA_HOME)
            $ap = Get-JdkHome $act
            if ($ap -and (Test-Jdk $ap)) { Write-Output ("JDK       : {0}  [{1}]" -f $ap, (Get-JdkInfo $ap).Version) }
        } else {
            Write-Output 'Activated : none (java/javac resolve through the jenv shims)'
        }
        if ($sel) {
            Write-Output ("Selected  : {0} (set by {1})" -f $sel.Name, $sel.Source)
            if ($act -ne $sel.Name) { Write-Output "Hint      : run 'jenv use' to apply the selected version to JAVA_HOME and PATH." }
        }
    }

    'doctor' { Invoke-Doctor }

    'init' {
        # Plain 'jenv init' is applied by the wrappers (jenv.cmd, bin\jenv, the PowerShell function).
        $a = ''
        if ($rest.Count -gt 0) { $a = $rest[0].ToLower() }
        if ($a -eq '--install') { Install-ShellIntegration }
        elseif ($a -eq '--remove') { Remove-ShellIntegration }
        else { Fail "'jenv init' must run through the jenv wrapper (jenv.cmd, bin\jenv, or the PowerShell function from bin\jenv-init.ps1). Options here: --install, --remove." }
    }

    '__env' {
        # internal: used by jenv.cmd. Prints NAME=value lines; empty values become __UNSET__.
        if ($rest.Count -lt 1) { Fail 'usage: __env <use|deactivate|init> [name]' }
        $nm = ''
        if ($rest.Count -gt 1) { $nm = $rest[1] }
        try { $plan = JenvPlan $Root $rest[0] $nm (Get-Location).ProviderPath }
        catch { Fail $_.Exception.Message }
        foreach ($k in $plan.Keys) {
            $v = [string]$plan[$k]
            if ($v.Length -eq 0) { $v = '__UNSET__' }
            [Console]::Out.WriteLine(('{0}={1}' -f $k, $v))
        }
    }

    { $_ -in 'use', 'deactivate' } {
        Fail "'jenv $cmd' must run through the jenv wrapper (jenv.cmd, bin\jenv, or the PowerShell function from bin\jenv-init.ps1)."
    }

    'which' {
        if ($rest.Count -lt 1) { Fail 'usage: jenv which <tool>' }
        $j = Get-ActiveJdk
        $exe = Join-Path $j.Home ("bin\{0}.exe" -f $rest[0])
        if (-not (Test-Path -LiteralPath $exe)) { Fail "'$($rest[0])' is not available in JDK '$($j.Name)' ($($j.Home))." }
        Write-Output $exe
    }

    'exec' {
        if ($rest.Count -lt 1) { Fail 'usage: jenv exec <command> [args...]' }
        $j = Get-ActiveJdk
        $env:JAVA_HOME = $j.Home
        $env:PATH = (Join-Path $j.Home 'bin') + ';' + $env:PATH
        $c = $rest[0]
        $cargs = @()
        if ($rest.Count -gt 1) { $cargs = @($rest[1..($rest.Count - 1)]) }
        & $c @cargs
        if ($null -eq $LASTEXITCODE) { exit 0 }
        exit $LASTEXITCODE
    }

    'rehash' { Invoke-Rehash }

    default { Fail "unknown command '$cmd'. Run 'jenv help'." }
}
