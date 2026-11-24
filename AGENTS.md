# Project work

Read the root README and `docs/RELEASING.md` before release work. Keep PowerShell source ASCII without a BOM for Windows PowerShell 5.1. Preserve existing task ownership checks and user data.

The safe fixed-vector check is `powershell.exe -NoProfile -File .\ThuNet-Login.ps1 -SelfTest`. `-Status` is a diagnostic that can read credentials, interfaces and browser history, use the network and write logs; it is not an offline smoke test.

Never weaken HTTPS certificate/hostname validation or add an insecure fallback to make a test pass. Keep account identifiers private. Do not read real credentials, DPAPI material or browser history for documentation checks. Do not create, change or remove scheduled tasks as verification without specific authorization.

Validate actual source/distribution bytes, relevant history and metadata. Reuse unchanged test evidence within its scope, record failures and unverified coverage, and keep private evidence outside the repository. Publication, history edits and credential rotation require separate authorization.
