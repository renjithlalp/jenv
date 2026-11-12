# jenv shell integration for PowerShell. Part of jenv-win.
# Dot-source it from your profile (install.ps1 -ShellIntegration or 'jenv init --install' does this):
#     . "C:\path\to\jenv-win\bin\jenv-init.ps1"
# It defines a 'jenv' function so that 'jenv use', 'jenv deactivate' and 'jenv init' can change
# THIS session (a child process cannot). Every other command is passed to bin\jenv.cmd.

if (-not $env:JENV_HOME -and $PSScriptRoot) { $env:JENV_HOME = Split-Path -Parent $PSScriptRoot }
. (Join-Path $env:JENV_HOME 'libexec\jenv-env.ps1')

function jenv {
    $cmd = ''
    if ($args.Count -gt 0) { $cmd = [string]$args[0] }
    $isEnv = ($cmd -eq 'use') -or ($cmd -eq 'deactivate') -or ($cmd -eq 'init' -and $args.Count -eq 1)
    if ($isEnv) {
        $name = ''
        if ($args.Count -gt 1) { $name = [string]$args[1] }
        try {
            $plan = JenvPlan $env:JENV_HOME $cmd $name (Get-Location).ProviderPath
            JenvApply $plan
        } catch {
            Write-Error ('jenv: ' + $_.Exception.Message)
        }
        return
    }
    & (Join-Path $env:JENV_HOME 'bin\jenv.cmd') @args
}

# Apply the local/global choice for the directory this session starts in (silent if there is none).
jenv init
