param(
    # Creating a permanent signing identity requires the owner's explicit choice.
    [switch]$Create,
    [string]$JavaHome,
    [string]$SigningDirectory = (Join-Path $env:USERPROFILE '.dropo-signing/google-play')
)
$ErrorActionPreference = 'Stop'
if (-not $Create) { throw 'Use -Create only after the owner authorizes a new Google Play upload key.' }
if (-not $IsWindows) { throw 'This key initializer requires Windows ACLs.' }
if (-not $JavaHome) { $JavaHome = $env:JAVA_HOME }
$keytool = Join-Path $JavaHome 'bin/keytool.exe'
if (-not (Test-Path -LiteralPath $keytool -PathType Leaf)) { throw 'Pass a Java JDK with keytool via -JavaHome.' }
if (-not [IO.Path]::IsPathRooted($SigningDirectory)) { throw 'SigningDirectory must be absolute.' }
$directory = [IO.Path]::GetFullPath($SigningDirectory)
$repository = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot))
if ($directory.TrimEnd('\', '/') -eq [IO.Path]::GetPathRoot($directory).TrimEnd('\', '/')) {
    throw 'SigningDirectory must be a dedicated directory, not a drive root.'
}
if ($directory -eq $repository -or $directory.StartsWith($repository + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Private signing material must stay outside the repository.'
}
$keystore = Join-Path $directory 'dropo-upload.keystore'
$properties = Join-Path $directory 'android-upload-signing.properties'
$certificate = Join-Path $directory 'dropo-upload-cert.pem'
foreach ($target in @($keystore, $properties, $certificate)) {
    if (Test-Path -LiteralPath $target) { throw 'Signing files already exist; refusing to overwrite a permanent identity.' }
}
if ((Test-Path -LiteralPath $directory) -and @(Get-ChildItem -LiteralPath $directory -Force).Count -ne 0) {
    throw 'SigningDirectory must be new or empty. Refusing to change permissions on an existing collection of files.'
}
# Inspect the complete existing ancestor chain before any creation or ACL change.
$ancestor = [IO.DirectoryInfo]::new($directory)
while ($null -ne $ancestor) {
    if ($ancestor.Exists -and ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'SigningDirectory and its ancestors must not be reparse points.'
    }
    $ancestor = $ancestor.Parent
}
if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory | Out-Null }
if ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw 'SigningDirectory must not be a reparse point.'
}
$owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetOwner($owner)
$acl.SetAccessRuleProtection($true, $false)
foreach ($sid in @($owner, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $directory -AclObject $acl
# Passwords are generated artifacts, never source files or command-line arguments.
$password = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
$previousPassword = [Environment]::GetEnvironmentVariable('DROPO_UPLOAD_KEYTOOL_PASSWORD', 'Process')
try {
    $env:DROPO_UPLOAD_KEYTOOL_PASSWORD = $password
    # Persist the recovery material before creating the permanent key. CreateNew
    # refuses concurrent replacement; Flush(true) commits it to disk.
    $content = "storeFile=$($keystore.Replace('\', '/'))`nstorePassword=$password`nkeyAlias=dropo-upload`nkeyPassword=$password`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($content)
    $stream = [IO.FileStream]::new($properties, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    $output = & $keytool -genkeypair -keystore $keystore -storetype PKCS12 -alias dropo-upload `
        -keyalg RSA -keysize 3072 -sigalg SHA256withRSA -validity 10000 `
        -dname 'CN=Dropo Upload, OU=Dropo, O=Dropo by sunnydjam' `
        -storepass:env DROPO_UPLOAD_KEYTOOL_PASSWORD -keypass:env DROPO_UPLOAD_KEYTOOL_PASSWORD 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Upload key generation failed; inspect the signing directory before retrying.' }
    $output = & $keytool -exportcert -rfc -keystore $keystore -alias dropo-upload -file $certificate `
        -storepass:env DROPO_UPLOAD_KEYTOOL_PASSWORD 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Key saved, but public certificate export failed.' }
    $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem([IO.File]::ReadAllText($certificate))
    try { $fingerprint = $cert.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant() }
    finally { $cert.Dispose() }
    [pscustomobject]@{
        PropertiesPath = $properties
        KeystorePath = $keystore
        PublicCertificatePath = $certificate
        Alias = 'dropo-upload'
        CertificateSHA256 = $fingerprint
        Access = 'Current Windows user, SYSTEM and Administrators only'
    }
} finally {
    [Environment]::SetEnvironmentVariable('DROPO_UPLOAD_KEYTOOL_PASSWORD', $previousPassword, 'Process')
    $password = $null
    $content = $null
    $bytes = $null
}
