# ThuNet-AutoLogin

English | [简体中文](README.zh-CN.md)

[![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D4?style=flat)](#requirements)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE?style=flat)](#requirements)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat)](LICENSE)
[![Source](https://img.shields.io/badge/GitHub-source-24292e?style=flat)](https://github.com/OverDustD7/thu-net-autologin)

Unattended sign-in and reconnection for Tsinghua's srun campus-network portal on a wired wall port. It is meant for a desk or lab machine that should recover its network after boot, sleep/resume or a dropped session without someone logging in by hand.

## Status and support

- Status: maintained, no package release and no CI workflow.
- Supported: Windows 10/11 with Windows PowerShell 5.1 and .NET built-ins; one wired NIC; a Tsinghua campus-network account.
- Not supported: Wi-Fi-only machines, non-Windows systems, and ports that require an interactive browser login before every run.
- Versioning: the repository is used from source; there is no versioned Release.

## Requirements

- Windows PowerShell 5.1. No PowerShell 7 module, Python or third-party program is required.
- .NET Framework built-ins that ship with Windows.
- A wired network adapter on the same port that needs authentication.
- Permission to create a per-user scheduled task; administrator rights are not required.

## Installation

### Recommended: the setup entry point

Copy the repository to the target machine and double-click `Setup-ThuNetAutoLogin.cmd`. It asks for the account and password, stores the credential, registers the per-user logon task, starts the watcher and checks the result. Add `-WhatIf` to see the actions without changing anything.

### Manual: three commands

```powershell
.\Set-ThuNetCredential.ps1
.\ThuNet-Login.ps1 -Status
.\Install-ThuNetAutoLogin.ps1
```

The first command stores the account and password; the second is a diagnostic run; the third registers the task.

## Quick start and success signal

After installation, run the diagnostic once:

```powershell
.\ThuNet-Login.ps1 -Status
```

A line beginning `link   : authenticated, direct internet works` means the wired link is authenticated. `NOT authenticated / unreachable` means it is not; run `.\ThuNet-Login.ps1 -Once` for one login attempt.

## Commands

| Command | What it does |
|---|---|
| `Setup-ThuNetAutoLogin.cmd` | Double-click entry: store credential, register the task, start it and verify |
| `Change-ThuNetCredential.cmd` | Re-enter the account/password, restart the watcher and verify one login |
| `.\ThuNet-Login.ps1 -Status` | Diagnostic: reports account, link state, ac_id and bind address; reads credentials, interfaces, network and browser history, and may write the local log; it does not log in |
| `.\ThuNet-Login.ps1 -SelfTest` | Offline: checks the SRBX1 encoder against a fixed vector; does not read credentials/interfaces/history, use the network, or create runtime directories |
| `.\ThuNet-Login.ps1 -Once` | One login attempt if the link is not authenticated |
| `.\ThuNet-Login.ps1 -Watch -IntervalSeconds 60` | Resident watcher; reconnects when the link drops |
| `.\ThuNet-Login.ps1 -TestLogin` | One login attempt with the raw server response, for troubleshooting |
| `.\ThuNet-Probe.ps1 -Watch` | Probe the portal interception and record evidence |
| `.\Uninstall-ThuNetAutoLogin.ps1` | Remove the scheduled task created by this repository |

Common parameters:

- `-CredentialDir <path>`: credential directory; default `%LOCALAPPDATA%\ThuNetAutoLogin\creds`.
- `-LogDir <path>`: log directory; default `%LOCALAPPDATA%\ThuNetAutoLogin\logs`.
- `-IntervalSeconds <seconds>`: watcher interval.
- `-RunLevel LeastPrivilege` (default) or `HighestAvailable`: task token level.

## Security and credentials

- HTTPS requests use the system certificate chain and hostname validation. TLS 1.2 is the minimum. There is no option to skip certificate validation, no insecure fallback and no custom trust store. A certificate, hostname or TLS-version failure closes the request instead of sending the credential.
- The account name is stored in plain text because `-Show` and the login script must read it without a key. It is personal information even though it is not a password: restrict the file's permissions and do not publish it.
- The password is stored with Windows DPAPI at `CurrentUser` scope in a separate file. Decryption normally requires the protected Windows user context; domain roaming or recovery arrangements can alter portability. Do not treat DPAPI as protection from a compromised current-user process or an administrator. Re-enter credentials for an ordinary machine migration rather than assuming copied files are usable.
- The password is never written to the log, printed to the console or passed on a command line. See [Microsoft CryptProtectData](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata) for DPAPI scope and roaming exceptions.
- `ThuNet-Login.ps1` only reads credentials; `Set-ThuNetCredential.ps1` is the only writer in this repository.

## Self-test

```powershell
.\ThuNet-Login.ps1 -SelfTest
```

This runs only the fixed SRBX1 vector and prints the computed hex plus the expected hex. The vector was recorded from the Python reference implementation; the current test does not call Python. The self-test branch does not create the install, credential or log directories, does not read stored credentials or browser history, does not enumerate network interfaces and does not use the network. Run it after changing PowerShell versions or editing the encoder.

## Configuration, data and permissions

- Install root: `%LOCALAPPDATA%\ThuNetAutoLogin`.
- Credential directory: `%LOCALAPPDATA%\ThuNetAutoLogin\creds` (overridable with `-CredentialDir`).
- Log directory: `%LOCALAPPDATA%\ThuNetAutoLogin\logs` (overridable with `-LogDir`).
- The learned `ac_id` cache lives beside the install root, not in the credential directory.
- The scheduled task runs as the current user with an interactive token and does not require administrator rights.

## Upgrade and uninstall

Upgrade by replacing the repository files and re-running `Setup-ThuNetAutoLogin.cmd`; the credential and log directories are outside the repository. To remove the task:

```powershell
.\Uninstall-ThuNetAutoLogin.ps1
```

The uninstaller removes only a task whose action points at this repository. It leaves credentials and logs in place. To additionally remove stored credentials, run `.\Set-ThuNetCredential.ps1 -Remove` deliberately; this is separate from removing the task.

## Limitations and troubleshooting

- The portal password is the srun/campus-network password, not the Wi-Fi (Tsinghua-Secure) password.
- `ac_id` belongs to the wall port and is discovered and cached; do not hard-code one value.
- The watcher backs off after repeated failures, so a wrong password does not hammer the portal.
- `-Status` is diagnostic, not a pure offline read: it reads credentials, enumerates interfaces, probes the network, reads browser history through `ac_id` discovery, and may write the local log.
- Detailed Chinese troubleshooting, deployment notes, task XML, retry/backoff and the file table are kept in [README.zh-CN.md](README.zh-CN.md), [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md) and [docs/EVOLUTION.md](docs/EVOLUTION.md).

## Development and documentation

- Pure ASCII, BOM-less `.ps1` files are required: Windows PowerShell 5.1 reads a BOM-less script as ANSI/cp936, so a non-ASCII literal can break parsing.
- Main script: `ThuNet-Login.ps1`; credential writer: `Set-ThuNetCredential.ps1`; task installer: `Install-ThuNetAutoLogin.ps1`.
- Design history and known limits: [docs/EVOLUTION.md](docs/EVOLUTION.md), [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md).
- The srun SRBX1 request format follows the `connect.py` implementation in `WhymustIhaveaname/TsinghuaTunet`; the fixed vector is credited there.

## Feedback and security

- Issues: use the [repository issue tracker](https://github.com/OverDustD7/thu-net-autologin/issues) for non-sensitive bug reports.
- Security: no private security-report channel is currently offered. Do not post account names, passwords, cookies, tokens or other sensitive details in a public issue.

## License and third-party notices

MIT, see [LICENSE](LICENSE). The srun protocol implementation is based on the public TsinghuaTunet reference implementation; its attribution is kept in the source header and in [docs/EVOLUTION.md](docs/EVOLUTION.md).