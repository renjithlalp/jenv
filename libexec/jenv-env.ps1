# jenv-env.ps1 - shared, side-effect-free helpers for jenv-win.
# Dot-sourced by libexec\jenv-core.ps1 and bin\jenv-init.ps1.
# Every name is prefixed 'Jenv' so it cannot clash with anything in a user's PowerShell session.
# Nothing in here calls 'exit' or writes to the console; problems are reported with 'throw'.

function JenvNorm([string]$p) {
    if (-not $p) { return '' }
    return $p.Trim().Trim('"').TrimEnd('\', '/').ToLowerInvariant()
}

function JenvReadLine([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $line = Get-Content -LiteralPath $Path -TotalCount 1 -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($null -eq $line) { return $null }
    $line = ([string]$line).Trim()
    if ($line.Length -eq 0) { return $null }
    return $line
}

function JenvValidName([string]$Name) { return ($Name -match '^[A-Za-z0-9][A-Za-z0-9._+-]*$') }

function JenvJdkHome([string]$Root, [string]$Name) {
    return (JenvReadLine (Join-Path (Join-Path $Root 'versions') $Name))
}

# Nearest .java-version, searching $Dir and its parents. Returns @{Name;Source} or $null.
function JenvFindLocal([string]$Dir) {
    $d = $Dir
    while ($d) {
        $f = Join-Path $d '.java-version'
        $v = JenvReadLine $f
        if ($v) { return @{ Name = $v; Source = $f } }
        $p = Split-Path -Parent $d
        if (-not $p -or $p -eq $d) { break }
        $d = $p
    }
    return $null
}

# local > global (ignores any session override). Returns @{Name;Source} or $null.
function JenvFindDefault([string]$Root, [string]$Dir) {
    $l = JenvFindLocal $Dir
    if ($l) { return $l }
    $gf = Join-Path $Root 'version'
    $g = JenvReadLine $gf
    if ($g) { return @{ Name = $g; Source = $gf } }
    return $null
}

# Returns the PATH entries of $PathValue (as an array) without the entries listed in $Drop.
function JenvStripPath([string]$PathValue, [string[]]$Drop) {
    $dropSet = @{}
    foreach ($d in $Drop) { if ($d) { $dropSet[(JenvNorm $d)] = $true } }
    $keep = @()
    $sep = [regex]::Escape([string][IO.Path]::PathSeparator)
    foreach ($e in ($PathValue -split $sep)) {
        if (-not $e) { continue }
        if ($dropSet.ContainsKey((JenvNorm $e))) { continue }
        $keep += $e
    }
    return $keep
}

# Computes the environment changes for 'use', 'deactivate' and 'init'.
# Returns an ordered hashtable: variable name -> new value ($null or '' means "remove it").
#
# Environment variables used (all set/cleared only by this function):
#   JENV_VERSION          session override chosen with 'jenv use <name>'
#   JENV_ACTIVE           name of the JDK that is currently activated in this session
#   JENV_BIN              the <jdk>\bin folder that activation put at the front of PATH
#   JENV_ORIG_JAVA_HOME   JAVA_HOME as it was before the first activation
function JenvPlan([string]$Root, [string]$Action, [string]$Name, [string]$Dir) {
    $plan = [ordered]@{}
    $sep = [string][IO.Path]::PathSeparator
    $active = [Environment]::GetEnvironmentVariable('JENV_ACTIVE')
    $curBin = [Environment]::GetEnvironmentVariable('JENV_BIN')
    $path   = [Environment]::GetEnvironmentVariable('PATH')

    if ($Action -eq 'deactivate') {
        if ($active) {
            $plan['PATH']      = @(JenvStripPath $path @($curBin)) -join $sep
            $plan['JAVA_HOME'] = [Environment]::GetEnvironmentVariable('JENV_ORIG_JAVA_HOME')
        }
        foreach ($k in 'JENV_VERSION', 'JENV_ACTIVE', 'JENV_BIN', 'JENV_ORIG_JAVA_HOME') { $plan[$k] = $null }
        return $plan
    }

    if ($Action -eq 'use' -and $Name) {
        if (-not (JenvValidName $Name)) { throw "invalid version name '$Name'." }
        $selName  = $Name
        $override = $Name
    } else {
        $sel = JenvFindDefault $Root $Dir
        if (-not $sel) {
            if ($Action -eq 'init') { return $plan }      # nothing to apply, stay silent
            throw "no .java-version or global version found. Use 'jenv use <name>' or 'jenv global <name>'."
        }
        $selName  = $sel.Name
        $override = $null                                  # clears any session override
    }

    $jdk = JenvJdkHome $Root $selName
    if (-not $jdk) { throw "version '$selName' is not registered. Run 'jenv list'." }
    $bin = Join-Path $jdk 'bin'
    if (-not (Test-Path -LiteralPath $bin)) { throw "JDK for '$selName' was not found at $jdk" }

    if (-not $active) { $plan['JENV_ORIG_JAVA_HOME'] = [Environment]::GetEnvironmentVariable('JAVA_HOME') }
    $plan['JENV_VERSION'] = $override
    $plan['JENV_ACTIVE']  = $selName
    $plan['JENV_BIN']     = $bin
    $plan['JAVA_HOME']    = $jdk
    $plan['PATH']         = (@($bin) + @(JenvStripPath $path @($curBin, $bin))) -join $sep
    return $plan
}

function JenvApply($Plan) {
    foreach ($k in $Plan.Keys) {
        $v = $Plan[$k]
        if ([string]::IsNullOrEmpty([string]$v)) { [Environment]::SetEnvironmentVariable($k, $null, 'Process') }
        else { [Environment]::SetEnvironmentVariable($k, [string]$v, 'Process') }
    }
}
