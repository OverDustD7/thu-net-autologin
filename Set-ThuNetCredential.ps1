# Set-ThuNetCredential.ps1 - store the campus network account for ThuNet-Login.ps1.
#
# This is the ONLY script in this repository that writes credentials.  ThuNet-Login.ps1 reads
# them and never writes; if it cannot find them it tells the user to run this script.
#
# HOW THE PASSWORD IS STORED
#   The account name goes into a plain text file (it is not a secret, and it has to be readable
#   without any key so that -Show and the login script can display it).
#   The password is encrypted with Windows DPAPI and written to a separate file as a hex string.
#   ConvertFrom-SecureString without a -Key encrypts with ProtectedData at the CurrentUser scope,
#   which is exactly the property this design wants:
#     * only the Windows user who ran this script can decrypt it;
#     * it is bound to this Windows installation, so copying the file to another computer (the
#       laptop) does NOT work - the decryption fails and the fix is to run this script there;
#     * no key material is stored anywhere, so there is no key file to protect.
#   The password is never echoed to the console, never written to a log and never passed on a
#   command line (a command line is visible to other processes and lands in shell history).
#
# THIS FILE MUST STAY PURE ASCII - see the header of ThuNet-Login.ps1 for why (PowerShell 5.1
# reads a BOM-less script as ANSI/cp936 and a non-ASCII literal corrupts the parse).
#
# USAGE
#   Set-ThuNetCredential.ps1                    ask for account and password, store them
#   Set-ThuNetCredential.ps1 -User 2021000000  pre-fill the account name, still ask for password
#   Set-ThuNetCredential.ps1 -Show             show the account name and whether a password is set
#   Set-ThuNetCredential.ps1 -Remove           delete the stored credential files
#   Set-ThuNetCredential.ps1 -CredentialDir <path>

param(
    [switch]$Show,
    [switch]$Remove,
    [string]$User,
    [string]$CredentialDir
)

$ErrorActionPreference = 'Stop'

if (-not $CredentialDir) {
    $CredentialDir = Join-Path (Join-Path $env:LOCALAPPDATA 'ThuNetAutoLogin') 'creds'
}
$UserFile = Join-Path $CredentialDir 'ThuNet-user.txt'
$PassFile = Join-Path $CredentialDir 'ThuNet-pass.dpapi'

# A credential set created by an earlier hand-rolled script may live under different names in the
# same directory.  Read those too, so -Show/-Remove work on a directory whose credentials were not
# created here; anything this script WRITES always uses the ThuNet-* names above.
function Find-Existing([string]$base) {
    foreach ($n in @("ThuNet-$base", "portal-$base")) {
        $p = Join-Path $CredentialDir $n
        if (Test-Path $p) { return $p }
    }
    return $null
}

if ($Show) {
    $uf = Find-Existing 'user.txt'
    $pf = Find-Existing 'pass.dpapi'
    Write-Host ('credential dir : ' + $CredentialDir)
    if (-not $uf -and -not $pf) {
        Write-Host 'account        : not set'
        return
    }
    if ($uf) {
        # Decode explicitly as UTF8: Set-Content -Encoding UTF8 on PowerShell 5.1 writes a BOM,
        # and Get-Content hides it, so read the raw text and strip any BOM character.
        $u = ((Get-Content $uf -Raw) -replace "^\uFEFF", '').Trim()
        Write-Host ('account        : ' + $u + '   (from ' + $uf + ')')
    } else {
        Write-Host 'account        : missing (password file exists but the account file does not)'
    }
    if ($pf) {
        # Report only WHETHER a password is set and whether it can be read HERE.  The password
        # itself is never decrypted for display and never printed.
        $readable = $false
        try {
            $enc = (Get-Content $pf -Raw).Trim()
            $sec = ConvertTo-SecureString $enc
            $null = (New-Object System.Net.NetworkCredential('', $sec)).Password
            $readable = $true
        } catch { $readable = $false }
        if ($readable) {
            Write-Host ('password       : set (DPAPI, CurrentUser scope - readable by this user on this machine)')
        } else {
            Write-Host ('password       : set but NOT decryptable here - the file was encrypted by another')
            Write-Host ('                 Windows user or on another machine. Run this script without')
            Write-Host ('                 -Show on THIS machine to store a usable credential.')
        }
    } else {
        Write-Host 'password       : not set'
    }
    return
}

if ($Remove) {
    $any = $false
    foreach ($base in @('user.txt', 'pass.dpapi')) {
        $p = Find-Existing $base
        if ($p) {
            Remove-Item -Path $p -Force
            Write-Host ('removed ' + $p)
            $any = $true
        }
    }
    if (-not $any) { Write-Host ('nothing to remove in ' + $CredentialDir) }
    return
}

if (-not (Test-Path $CredentialDir)) { New-Item -ItemType Directory -Path $CredentialDir -Force | Out-Null }

Write-Host 'Storing the campus network account for ThuNet-Login.ps1.'
Write-Host 'The password is encrypted with Windows DPAPI (CurrentUser scope): only this Windows'
Write-Host 'user on this machine can decrypt it. Every other machine needs its own run.'
Write-Host ''

$account = $User
if (-not $account) {
    $account = Read-Host 'Account (student id or username)'
}
$account = ($account -replace "^\uFEFF", '').Trim()
if (-not $account) { Write-Host 'No account given, nothing stored.'; exit 1 }

# Read-Host -AsSecureString keeps the typed characters out of the console and out of the history.
# It is asked twice because there is no way to display what was typed to confirm it afterwards.
# A mismatch RE-ASKS instead of voiding the run.  The first version printed "The two passwords
# differ, nothing stored" and exited, which from the outside looked like nothing had been checked at
# all: reported 2026-10-24 by a user who typed them differently and only found out the run had been
# discarded when the machine kept using the old credential.  Three attempts, then give up loudly.
$MAX_ATTEMPTS = 3
$p1 = $null
$sec1 = $null
for ($attempt = 1; $attempt -le $MAX_ATTEMPTS; $attempt++) {
    if ($attempt -gt 1) { Write-Host ('Try again (' + $attempt + '/' + $MAX_ATTEMPTS + ') - press Ctrl+C to abort.') }
    $s1 = Read-Host -AsSecureString 'Password (not echoed)'
    $s2 = Read-Host -AsSecureString 'Password again'
    $q1 = (New-Object System.Net.NetworkCredential('', $s1)).Password
    $q2 = (New-Object System.Net.NetworkCredential('', $s2)).Password
    if (-not $q1) {
        Write-Host 'Empty password - not stored on this attempt.'
        $q1 = $null; $q2 = $null; $s1 = $null; $s2 = $null
        continue
    }
    if ($q1 -eq $q2) {
        $p1 = $q1
        $sec1 = $s1
        $q1 = $null; $q2 = $null; $s1 = $null; $s2 = $null
        break
    }
    Write-Host 'The two entries differ - nothing stored yet.'
    $q1 = $null; $q2 = $null; $s1 = $null; $s2 = $null
}
if (-not $p1) {
    Write-Host ''
    Write-Host ('Gave up after ' + $MAX_ATTEMPTS + ' attempts - NOTHING was stored.')
    Write-Host 'Any credential already on this machine is still in place. Run this script again when ready.'
    exit 1
}
$p2 = $p1
$sec2 = $sec1

try {
    Set-Content -Path $UserFile -Value $account -Encoding UTF8 -NoNewline
    ConvertFrom-SecureString $sec1 | Set-Content -Path $PassFile -Encoding ASCII -NoNewline
} catch {
    Write-Host ('Could not write the credential files: ' + $_.Exception.Message)
    exit 1
} finally {
    # Drop the plaintext copies as soon as they are no longer needed.  This does not scrub the
    # strings out of the managed heap (a .NET string cannot be wiped in place), it only makes the
    # window in which they are reachable as short as the work requires.
    $p1 = $null; $p2 = $null
    $sec1 = $null; $sec2 = $null
}

Write-Host ''
Write-Host ('Stored account {0} in {1}' -f $account, $UserFile)
Write-Host ('Stored the DPAPI-encrypted password in {0}' -f $PassFile)
Write-Host 'Verify with: ThuNet-Login.ps1 -Status      (read-only, logs nothing)'
