# jenv-win

A small, dependency-free Java version manager for Windows that behaves the same in
**cmd.exe**, **PowerShell** and **Git Bash**. Pure scripts, nothing to compile; the only
requirement is Windows PowerShell 5.1, which ships with Windows.

(The original [jenv](https://github.com/jenv/jenv) is a bash tool and does not run natively on Windows.
This project follows its idea: `global` / `local` / session versions, `.java-version` files, shims.)

## Commands

```
jenv add <name> <jdk-home>   Register an installed JDK (quote paths with spaces)
jenv remove <name>           Unregister a JDK; never deletes the installation
jenv list                    List registered JDKs
jenv use <name>              Activate a session override
jenv use                     Clear override and activate nearest local/global choice
jenv deactivate              Restore PATH and JAVA_HOME from before activation
jenv local [name|unset]      Read, write, or remove this folder's .java-version
jenv global [name|unset]     Read, write, or clear the saved default
jenv current                 Show the currently activated environment
jenv doctor                  Diagnose JDK paths and command resolution
jenv init                    Apply local/global choice if one exists (for profiles)

More:
jenv scan [dir ...]          Register JDKs found in common install locations (and dir ...)
jenv which <tool>            Print the real path of a JDK tool, e.g. javac
jenv exec <cmd> [args]       Run a command with JAVA_HOME/PATH set to the selected JDK
jenv rehash                  Regenerate the shims (after editing libexec\tools.txt)
jenv init --install|--remove Add/remove jenv in your PowerShell and Git Bash profiles
```

Precedence: **session override** (`jenv use <name>`) > **nearest `.java-version`** (`jenv local`) > **saved global default** (`jenv global`).
After changing directories, run `jenv use` to apply that project's version to `JAVA_HOME` and `PATH`.
"Global" means this manager's default, not Windows machine environment variables.

## Install

1. Put this folder somewhere permanent, e.g. `C:\tools\jenv-win` (it keeps its own state in `versions\`, `shims\`).
2. Run in PowerShell or cmd:

   ```
   powershell -ExecutionPolicy Bypass -File C:\tools\jenv-win\install.ps1 -ShellIntegration
   ```

   This is user-level only (no admin). It sets `JENV_HOME`, `JAVA_HOME`, puts `shims` and `bin` at the front of your
   user `Path`, scans for installed JDKs and registers them. `-ShellIntegration` additionally lets `jenv use`,
   `jenv deactivate` and `jenv init` change your PowerShell and Git Bash sessions (cmd.exe needs nothing).
   Use `-SkipScan` to skip the JDK scan.
3. **Open a new terminal**, then:

   ```
   jenv list
   jenv global 21
   jenv doctor          # checks that everything is wired up
   ```

Uninstall: `powershell -ExecutionPolicy Bypass -File C:\tools\jenv-win\install.ps1 -Uninstall`

### Manual environment variable setup (instead of install.ps1)

Set these as **User** environment variables (Win+R, `sysdm.cpl`, Advanced, Environment Variables):

| Variable | Value |
|---|---|
| `JENV_HOME` | `C:\tools\jenv-win` |
| `JAVA_HOME` | `%JENV_HOME%\current` |
| `Path` (add at the top) | `%JENV_HOME%\shims` and `%JENV_HOME%\bin` |

Then, in a new terminal, run `jenv scan` (or `jenv add`) and `jenv global <name>`. For `jenv use` in PowerShell and
Git Bash run `jenv init --install` (adds one block to your PowerShell profile(s) and `~/.bashrc`; `jenv init --remove`
takes it out again).

## How it works

Two layers cooperate:

1. **Shims (automatic).** `shims\java.cmd`, `javac.cmd`, ... (cmd, PowerShell) and extensionless `shims\java`, ...
   (Git Bash) pick the JDK from session override > `.java-version` > global every time they run, so `java` and
   `javac` follow the folder you are in without any command.
2. **Activation (explicit).** `jenv use` sets `JAVA_HOME` and puts the JDK's `bin` first on `PATH` for that terminal,
   so Maven, Gradle, IDE launchers and every other tool in the JDK see the same version. `jenv deactivate` puts
   `PATH` and `JAVA_HOME` back exactly as they were.

State lives in:

| Item | Purpose |
|---|---|
| `versions\<name>` | One text file per registered JDK holding its install path |
| `version` | The global version name |
| `current` (junction) | Always points at the global JDK, so `JAVA_HOME=%JENV_HOME%\current` is right in new terminals |
| `.java-version` | Per-project version name (searched in the current directory and upwards) |

Session variables set by `use` / `deactivate` (never written to the registry): `JENV_VERSION` (the override),
`JENV_ACTIVE`, `JENV_BIN`, `JENV_ORIG_JAVA_HOME`. They are shared between shells, so a Git Bash started from an
activated PowerShell inherits the activation.

## Typical session

```
jenv add corretto-21 "C:\Program Files\Amazon Corretto\jdk21.0.4_7"
jenv global 21                 # default for every new terminal
cd C:\work\legacy-app
jenv local 8                   # writes .java-version here (commit it)
jenv use                       # apply it: JAVA_HOME and PATH now point at JDK 8
jenv current
jenv use 17                    # one-off override for this terminal
jenv deactivate                # back to how the terminal started
jenv doctor
```

## Troubleshooting

Start with `jenv doctor`; it checks JENV_HOME, JAVA_HOME, PATH order, shims, registered JDKs, the global junction,
`.java-version`, activation state, profile hooks and the PowerShell execution policy, and tells you what to fix.

- **`java -version` still shows the old Java.** Something earlier in `Path` wins. System `Path` entries come before user
  `Path` entries, and Oracle's installer adds `C:\Program Files\Common Files\Oracle\Java\javapath` there. Remove such
  entries, or add `<jenv>\shims` to the *System* Path above them. `where java` (cmd) / `which -a java` (Git Bash) shows the order.
- **`mvn` / `gradle` use a different Java than `java`.** They read `JAVA_HOME`, which follows `global` automatically
  but follows a `.java-version` only after `jenv use` (or use `jenv exec mvn ...`).
- **`jenv use` has no effect in PowerShell / Git Bash.** Run `jenv init --install` and open a new window.
  Loading a PowerShell profile needs a script-capable policy: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.
- **Re-sourcing `~/.bashrc`:** the installed line is `eval "$(command jenv init)"`; keep the word `command`, it bypasses
  the `jenv` shell function.
- **Creating `.java-version` by hand.** Use `jenv local <name>`. `echo 17 > .java-version` in Windows PowerShell 5.1
  writes UTF-16, which the shims cannot read.
- **Ctrl+C in cmd.exe asks "Terminate batch job (Y/N)?"** That is cmd's standard behavior for any `.cmd` launcher.
- **A tool is missing from the shims.** Add its name to `libexec\tools.txt` and run `jenv rehash`.
- **Moved the folder?** Run `install.ps1` again from the new location.
