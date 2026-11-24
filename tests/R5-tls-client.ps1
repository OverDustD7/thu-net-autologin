param(
    [Parameter(Mandatory=$true)][string]$Source,
    [Parameter(Mandatory=$true)][string]$Url,
    [ValidateSet('default','pin')][string]$Mode = 'default',
    [string]$Pin = ''
)
$ErrorActionPreference = 'Stop'

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Source, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count -gt 0) {
    Write-Output ('PARSE_ERROR=' + ($errors | ForEach-Object { $_.Message }) -join '; ')
    exit 3
}
$wanted = @('Set-BindDelegate', 'Invoke-Plain')
$funcs = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and ($wanted -contains $node.Name)
}, $true)
if (-not $funcs -or $funcs.Count -ne 2) {
    Write-Output ('FUNCTION_EXTRACT_FAILED=' + $funcs.Count)
    exit 3
}
foreach ($fn in $funcs) { Invoke-Expression $fn.Extent.Text }

$script:BindIp = $null
$script:Pin = $Pin
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

if ($Mode -eq 'pin') {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
        param($request, $certificate, $chain, $errors)
        if (-not $certificate) { return $false }
        return ($certificate.GetCertHashString() -eq $script:Pin)
    }
} else {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null
}

try {
    $body = Invoke-Plain $Url
    Write-Output ('OK=' + $body)
    exit 0
} catch {
    Write-Output ('ERR=' + $_.Exception.GetType().FullName)
    $inner = $_.Exception.InnerException
    $n = 0
    while ($inner) {
        $n++
        Write-Output ('INNER' + $n + '=' + $inner.GetType().FullName)
        $inner = $inner.InnerException
    }
    exit 0
}