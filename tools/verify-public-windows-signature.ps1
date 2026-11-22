param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$ExpectedCertificateSHA256
)
$ErrorActionPreference='Stop'
if($ExpectedCertificateSHA256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'Stable publication requires the reviewed public signing certificate SHA256.'}
$file=Get-Item -LiteralPath $Path
if(-not $file.PSIsContainer -and ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0){
 $signature=Get-AuthenticodeSignature -LiteralPath $file.FullName
}else{throw 'A normal installer file is required.'}
if($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate){throw 'Stable publication requires a publicly trusted Authenticode signature.'}
$actual=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($signature.SignerCertificate.RawData))
if($actual -ine $ExpectedCertificateSHA256){throw 'Installer publisher certificate does not match the reviewed signer.'}
if(-not $signature.TimeStamperCertificate){throw 'Stable publication requires a trusted timestamp.'}
$eku=@($signature.SignerCertificate.Extensions | Where-Object {$_.Oid.Value -eq '2.5.29.37'} | ForEach-Object {$_.EnhancedKeyUsages} | ForEach-Object {$_.Value})
if($eku -notcontains '1.3.6.1.5.5.7.3.3'){throw 'Publisher certificate does not authorize code signing.'}
Write-Host 'Public publisher, signature and timestamp verified.'
