# Release preparation

Record the exact commit, current edits, source components, intended channel and candidate hash. Preserve existing changes and machine-local credentials/logs before edits; source-only changes do not update installed tasks or public history.

## Source and offline checks

Parse changed PowerShell with Windows PowerShell 5.1 and check ASCII/no BOM. Run the fixed-vector `-SelfTest` only after reviewing its early offline branch. It must not initialize runtime directories, resolve credentials, enumerate interfaces, discover ac_id or access the network. Keep the recorded vector constants unchanged.

Run `tests/R5-regression.ps1` with PowerShell 7 and Python, passing the repository root as `-ProjectRoot` and a private directory outside the repository as `-EvidenceDir`. It checks default rejection of an untrusted loopback certificate and acceptance of the exact fixture certificate in the positive control. The fixture exits on its own, and cleanup removes only the named test files and empty test directories. Keep production certificate validation enabled and leave the trust store untouched.

## Privacy and distribution

Inspect actual candidate bytes, source comments, examples, logs, document metadata and applicable history. Exclude machine-local install state, account/DPAPI files, browser data, `.migration/`, private reports and temporary TLS keys. Account names are personal information. A negative pattern scan without a full identity dictionary is not a privacy pass.

## Runtime and release

Real login, diagnostic Status, DPAPI, browser discovery, installation and task startup have separate side effects. Use only an explicitly authorized test account and machine for those checks; do not silently substitute a real account for a fixture. Record which checks were not performed.

Do not claim current public source or installed tasks are fixed by local edits. Prepare rollback using this round's before copies and preserve wanted data. Push, release, task changes, old-asset replacement, history rewriting and credential rotation require their own authorization.
