param(
    [Parameter(Mandatory=$true)][string]$ProjectRoot,
    [Parameter(Mandatory=$true)][string]$EvidenceDir
)
$ErrorActionPreference = 'Stop'
$checks = New-Object System.Collections.Generic.List[object]
$transcript = New-Object System.Collections.Generic.List[string]
function Add-Check([string]$name, [string]$status, [string]$detail) {
    $checks.Add([pscustomobject]@{ name=$name; status=$status; detail=$detail })
    $transcript.Add(('{0}: {1} - {2}' -f $status, $name, $detail))
}
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$winPs = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$temp = (New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ('r5-regression-' + [guid]::NewGuid().ToString('n')))).FullName
$serverProc = $null
$cert = $null
$rsa = $null
try {
    $login = Join-Path $ProjectRoot 'ThuNet-Login.ps1'
    $credScript = Join-Path $ProjectRoot 'Set-ThuNetCredential.ps1'
    $readme = Join-Path $ProjectRoot 'README.md'
    $readmeZh = Join-Path $ProjectRoot 'README.zh-CN.md'
    $source = Get-Content -LiteralPath $login -Raw -Encoding ASCII

    $psFiles = @(Get-ChildItem -LiteralPath $ProjectRoot, (Join-Path $ProjectRoot 'tests') -File |
        Where-Object { $_.Extension -in '.ps1', '.vbs', '.cmd' })
    $asciiFail = @()
    foreach ($f in $psFiles) {
        $b = [System.IO.File]::ReadAllBytes($f.FullName)
        if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $asciiFail += ($f.Name + ':BOM') }
        if (@($b | Where-Object { $_ -gt 127 }).Count -gt 0) { $asciiFail += ($f.Name + ':non-ascii') }
    }
    if ($asciiFail.Count -eq 0) { Add-Check 'ascii_bom' 'PASS' ('checked ' + $psFiles.Count + ' script/launcher files') }
    else { Add-Check 'ascii_bom' 'FAIL' ($asciiFail -join ', ') }

    $parseFail = @()
    foreach ($f in ($psFiles | Where-Object { $_.Extension -eq '.ps1' })) {
        $cmd = '$e=$null;$t=$null;[void][System.Management.Automation.Language.Parser]::ParseFile(''' + $f.FullName + ''',[ref]$t,[ref]$e); if($e){$e|ForEach-Object{$_.Message}}else{"PARSE_OK"}'
        $r = & $winPs -NoProfile -Command $cmd 2>&1 | Out-String
        if ($r -notmatch 'PARSE_OK') { $parseFail += ($f.Name + ': ' + $r.Trim()) }
    }
    if ($parseFail.Count -eq 0) { Add-Check 'ps51_parse' 'PASS' 'all .ps1 parsed by Windows PowerShell 5.1' }
    else { Add-Check 'ps51_parse' 'FAIL' ($parseFail -join ' | ') }

    $stTemp = Join-Path $temp 'selftest'
    New-Item -ItemType Directory -Path $stTemp -Force | Out-Null
    $stOut = & $winPs -NoProfile -File (Join-Path $ProjectRoot 'tests\R5-selftest.ps1') -Source $login -TempRoot $stTemp -CredDir (Join-Path $stTemp 'creds') 2>&1 | Out-String
    $transcript.Add('SELFTEST_OUTPUT:'); $transcript.Add($stOut.Trim())
    $netCount = [regex]::Match($stOut, 'NETCOUNT=(\d+)').Groups[1].Value
    $hasMatch = $stOut -match 'OUT=MATCH:'
    $leaks = @()
    foreach ($p in 'credential dir', 'wired address', 'ac_id', 'R5-SENTINEL-ACCOUNT') { if ($stOut -match [regex]::Escape($p)) { $leaks += $p } }
    $runDir = Test-Path (Join-Path $stTemp 'ThuNetAutoLogin')
    if ($netCount -eq '0' -and $hasMatch -and -not $runDir -and $leaks.Count -eq 0) {
        Add-Check 'selftest_offline' 'PASS' 'NETCOUNT=0, MATCH, no runtime dir, no credential/interface/history output'
    } else {
        Add-Check 'selftest_offline' 'FAIL' ('NETCOUNT=' + $netCount + ' MATCH=' + $hasMatch + ' runDir=' + $runDir + ' leaks=' + ($leaks -join ','))
    }
    $expectedHex = '94aca64aba9027ba06b0c67399e92be1950dd5aa0fb88ab65d813481500e70fcead4dbf6dc415a8a7d5393814cfb4d0387a03db7ea3168cdd9408e66be0aea2be19d6d86639f013208379246c9a9a9cb58f12fab891eb5222b9c8a837f0abd1de058146c408eda9247d660e7'
    $srcHex = [regex]::Match($source, "SelfTestExpectedHex\s*=\s*'([0-9a-f]+)'").Groups[1].Value
    if ($srcHex -eq $expectedHex) { Add-Check 'fixed_vector_preserved' 'PASS' 'expected SRBX1 hex unchanged' }
    else { Add-Check 'fixed_vector_preserved' 'FAIL' 'expected hex differs from fixture' }

    $certPath = Join-Path $temp 'fixture-cert.pem'
    $keyPath = Join-Path $temp 'fixture-key.pem'
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=127.0.0.1', $rsa,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $san = New-Object System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder
    $san.AddIpAddress([System.Net.IPAddress]::Loopback)
    $req.CertificateExtensions.Add($san.Build())
    $req.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $false))
    $eku = [System.Security.Cryptography.OidCollection]::new()
    [void]$eku.Add([System.Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
    $req.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($eku, $false))
    $cert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddDays(1))
    [System.IO.File]::WriteAllText($certPath, $cert.ExportCertificatePem(), (New-Object System.Text.ASCIIEncoding))
    [System.IO.File]::WriteAllText($keyPath, $rsa.ExportPkcs8PrivateKeyPem(), (New-Object System.Text.ASCIIEncoding))
    $thumb = $cert.GetCertHashString()

    function Invoke-TlsCase([string]$mode, [string]$pin) {
        $ready = Join-Path $temp ('ready-' + $mode + '.txt')
        $result = Join-Path $temp ('result-' + $mode + '.txt')
        $serverArgs = @((Join-Path $ProjectRoot 'tests\R5-tls-server.py'),'--cert',$certPath,'--key',$keyPath,'--ready',$ready,'--result',$result)
        $python = Get-Command python -CommandType Application | Select-Object -First 1
        $startInfo = [Diagnostics.ProcessStartInfo]::new($python.Source)
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        foreach ($arg in $serverArgs) { $startInfo.ArgumentList.Add($arg) }
        $sp = [Diagnostics.Process]::Start($startInfo)
        $script:serverProc = $sp
        $ok = $false
        for ($i = 0; $i -lt 100; $i++) {
            if (Test-Path $ready) { $ok = $true; break }
            if ($sp.HasExited) { break }
            Start-Sleep -Milliseconds 100
        }
        if (-not $ok) { throw 'TLS server did not become ready' }
        $port = (Get-Content $ready -Raw).Trim()
        $clientArgs = @('-NoProfile','-File',(Join-Path $ProjectRoot 'tests\R5-tls-client.ps1'),'-Source',$login,'-Url',('https://127.0.0.1:' + $port + '/'),'-Mode',$mode)
        if ($pin) { $clientArgs += @('-Pin',$pin) }
        $clientOut = & $winPs @clientArgs 2>&1 | Out-String
        $transcript.Add(('TLS_' + $mode + '_CLIENT:')); $transcript.Add($clientOut.Trim())
        if (-not $sp.WaitForExit(16000)) { throw 'TLS fixture did not exit within its deadline' }
        $serverResult = if (Test-Path $result) { (Get-Content $result -Raw).Trim() } else { 'missing' }
        $transcript.Add(('TLS_' + $mode + '_SERVER=' + $serverResult))
        $exitCode = $sp.ExitCode
        $sp.Dispose()
        $script:serverProc = $null
        if ($exitCode -ne 0) { throw 'TLS fixture exited with an error' }
        return [pscustomobject]@{ client=$clientOut; server=$serverResult }
    }
    $tlsDefault = Invoke-TlsCase 'default' ''
    $defaultRejected = ($tlsDefault.client -match 'ERR=') -and ($tlsDefault.client -match 'AuthenticationException') -and ($tlsDefault.server -ne 'served')
    if ($defaultRejected) { Add-Check 'tls_default_reject' 'PASS' 'default validation rejected the untrusted loopback certificate' }
    else { Add-Check 'tls_default_reject' 'FAIL' ($tlsDefault.client.Trim()) }
    $tlsPin = Invoke-TlsCase 'pin' $thumb
    $pinOk = ($tlsPin.client -match 'OK=R5-TLS-FIXTURE') -and ($tlsPin.server -eq 'served')
    if ($pinOk) { Add-Check 'tls_exact_pin_positive' 'PASS' 'exact fixture certificate pin accepted, server served 200' }
    else { Add-Check 'tls_exact_pin_positive' 'FAIL' ($tlsPin.client.Trim() + ' server=' + $tlsPin.server) }
    $hasTls12 = $source -match 'SecurityProtocol\s*=\s*\[System\.Net\.SecurityProtocolType\]::Tls12'
    $hasTls11 = $source -match 'Tls11'
    $hasNullCallback = $source -match 'ServerCertificateValidationCallback\s*=\s*\$null'
    $hasTrueCallback = $source -match 'ServerCertificateValidationCallback\s*=\s*\{\s*\$true\s*\}'
    if ($hasTls12 -and -not $hasTls11 -and $hasNullCallback -and -not $hasTrueCallback) {
        Add-Check 'tls_source_policy' 'PASS' 'Tls12 only, default callback, no insecure true callback'
    } else {
        Add-Check 'tls_source_policy' 'FAIL' ('Tls12=' + $hasTls12 + ' Tls11=' + $hasTls11 + ' nullCallback=' + $hasNullCallback + ' trueCallback=' + $hasTrueCallback)
    }

    $credText = Get-Content -LiteralPath $credScript -Raw -Encoding ASCII
    if ($credText -match 'personal information' -and $credText -match '\{\{ACCOUNT\}\}' -and $credText -notmatch 'not a secret' -and $credText -notmatch '2021000000') {
        Add-Check 'credential_comment' 'PASS' 'account treated as personal info; numeric example replaced by placeholder'
    } else {
        Add-Check 'credential_comment' 'FAIL' 'comment still says not a secret or numeric example remains'
    }
    $linkFail = @()
    foreach ($md in @($readme, $readmeZh)) {
        $text = Get-Content -LiteralPath $md -Raw -Encoding UTF8
        foreach ($m in [regex]::Matches($text, '\]\(([^)]+)\)')) {
            $target = $m.Groups[1].Value
            if ($target -match '^(https?://|mailto:|#)') { continue }
            $path = ($target -split '#')[0]
            if (-not (Test-Path (Join-Path $ProjectRoot $path))) { $linkFail += ((Split-Path $md -Leaf) + ' -> ' + $target) }
        }
        if ($text -match '[A-Za-z]:\\' -or $text -match 'C:\\Users\\') { $linkFail += ((Split-Path $md -Leaf) + ': absolute path') }
    }
    if ($linkFail.Count -eq 0) { Add-Check 'readme_links' 'PASS' 'relative links resolve; no absolute paths' }
    else { Add-Check 'readme_links' 'FAIL' ($linkFail -join ' | ') }
    $en = Get-Content -LiteralPath $readme -Raw -Encoding UTF8
    $zh = Get-Content -LiteralPath $readmeZh -Raw -Encoding UTF8
    $facts = ($en -match 'TLS 1\.2') -and ($en -match 'certificate') -and ($en -match 'SelfTest') -and ($en -match 'Status') -and ($en -match 'MIT') -and ($zh -match 'TLS') -and ($zh -match '1\.2') -and ($zh -match 'SelfTest') -and ($zh -match 'MIT')
    if ($facts) { Add-Check 'readme_core_facts' 'PASS' 'TLS, self-test, status and license facts present in both languages' }
    else { Add-Check 'readme_core_facts' 'FAIL' 'one or more core facts missing' }

    $fileHashes = @()
    foreach ($name in 'README.md','README.zh-CN.md','ThuNet-Login.ps1','Set-ThuNetCredential.ps1','tests/R5-tls-client.ps1','tests/R5-tls-server.py','tests/R5-selftest.ps1','tests/R5-regression.ps1') {
        $p = Join-Path $ProjectRoot $name
        if (Test-Path $p) {
            $fileHashes += [pscustomobject]@{ file=$name; bytes=(Get-Item $p).Length; sha256=(Get-FileHash $p -Algorithm SHA256).Hash.ToLower() }
        }
    }
    $head = (& git -C $ProjectRoot rev-parse HEAD 2>$null | Out-String).Trim()
} finally {
    if ($serverProc) {
        try {
            if (-not $serverProc.WaitForExit(16000)) { throw 'TLS fixture still running; fixture files retained' }
        } finally { $serverProc.Dispose() }
    }
    if ($cert) { $cert.Dispose() }
    if ($rsa) { $rsa.Dispose() }
    $fixtureDirs = @($temp, (Join-Path $temp 'selftest'), (Join-Path $temp 'selftest\creds'), (Join-Path $temp 'selftest\logs'))
    foreach ($dir in $fixtureDirs) {
        if ((Test-Path -LiteralPath $dir) -and ((Get-Item -LiteralPath $dir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Unexpected linked fixture directory; fixture files retained'
        }
    }
    foreach ($relativePath in @('fixture-cert.pem', 'fixture-key.pem', 'ready-default.txt', 'result-default.txt',
        'ready-pin.txt', 'result-pin.txt', 'selftest\creds\ThuNet-user.txt', 'selftest\creds\ThuNet-ac_id.txt')) {
        [IO.File]::Delete((Join-Path $temp $relativePath))
    }
    for ($i = $fixtureDirs.Count - 1; $i -ge 0; $i--) {
        if (Test-Path -LiteralPath $fixtureDirs[$i]) { [IO.Directory]::Delete($fixtureDirs[$i], $false) }
    }
}
$result = [ordered]@{
    checked_at = (Get-Date).ToString('o')
    head = $head
    checks = $checks
    files = $fileHashes
    temp_cleaned = (-not (Test-Path -LiteralPath $temp))
}
[System.IO.File]::WriteAllText((Join-Path $EvidenceDir 'r5-test-result.json'), ($result | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $EvidenceDir 'r5-test-transcript.txt'), ($transcript -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Output ($result | ConvertTo-Json -Depth 8)
if ($checks | Where-Object status -eq 'FAIL') { exit 1 }
