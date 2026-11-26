# Manual Windows channel. Run on the maintainer signing machine.
param([Parameter(Mandatory = $true)][string]$Path)
$ErrorActionPreference = "Stop"
$signature = Get-AuthenticodeSignature -LiteralPath $Path
$cert = $signature.SignerCertificate
if ($signature.Status -ne "Valid" -or -not $cert -or -not $signature.TimeStamperCertificate) {
    throw "Invalid project signature or missing timestamp: $Path ($($signature.Status))"
}
$expected = "702fe416370910bccfc36ed67e7e128c587d7303d1c8aab66da63bdfb8fd04ef"
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $actual = [BitConverter]::ToString($sha.ComputeHash($cert.RawData)).Replace("-", "")
} finally {
    $sha.Dispose()
}
if ($actual -ne $expected -or $cert.Subject -ne $cert.Issuer) {
    throw "Unexpected project signing certificate: $Path"
}
Write-Host "[OK] Project signature, certificate pin and timestamp verified: $Path"
