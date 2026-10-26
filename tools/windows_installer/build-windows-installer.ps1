param(
  [string]$ReleaseDir = "build\windows\x64\runner\Release",
  [string]$OutputDir = "",
  [string]$Version = ""
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$versionMatch = [regex]::Match((Get-Content (Join-Path $root 'pubspec.yaml') -Raw), '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
if (-not $versionMatch.Success) { throw 'pubspec.yaml must specify a release and build number.' }
$releaseVersion = $versionMatch.Groups[1].Value
$buildNumber = $versionMatch.Groups[2].Value
$fullVersion = "$releaseVersion+$buildNumber"
if ($Version -and $Version -ne $releaseVersion) { throw 'Version must match pubspec.yaml.' }
$Version = $releaseVersion
if (-not $OutputDir) { $OutputDir = "dist\v$Version" }
$dartPath = Join-Path $root '.tooling\flutter\bin\dart.bat'
if (-not (Test-Path -LiteralPath $dartPath)) { $dartPath = (Get-Command dart -ErrorAction Stop).Source }
& $dartPath (Join-Path $root 'tools\sync_version.dart') --check
if ($LASTEXITCODE -ne 0) { throw 'Generated app version is out of date.' }
$releasePath = Resolve-Path (Join-Path $root $ReleaseDir)
$outputPath = Join-Path $root $OutputDir
$payloadPath = Join-Path $outputPath "QingTing-v$fullVersion-windows-x64.zip"
$safeVersion = $Version.Replace(".", "_")
$setupPath = Join-Path $outputPath "QingTingSetup-v$safeVersion.exe"
$sourcePath = Join-Path $PSScriptRoot "QingTingSetup.cs"
$enginePath = Join-Path $PSScriptRoot "UpdateEngine.cs"
$iconPath = Join-Path $root "windows\runner\resources\app_icon.ico"
$cscPath = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"

if (!(Test-Path -LiteralPath $cscPath)) {
  $cscPath = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe"
}
if (!(Test-Path -LiteralPath $cscPath)) {
  throw "C# compiler not found."
}
if (!(Test-Path -LiteralPath (Join-Path $releasePath "qingting.exe"))) {
  throw "qingting.exe not found in release directory: $releasePath"
}
if ((Get-Item -LiteralPath (Join-Path $releasePath 'qingting.exe')).VersionInfo.ProductVersion -ne $fullVersion) {
  throw "Windows release binary must be rebuilt for $fullVersion before packaging."
}
if (!(Test-Path -LiteralPath $sourcePath)) {
  throw "Installer source not found: $sourcePath"
}

New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
$generatedPath = Join-Path $root 'build\windows-installer'
New-Item -ItemType Directory -Path $generatedPath -Force | Out-Null
$versionSource = Join-Path $generatedPath 'BuildVersion.g.cs'
$versionCode = @"
using System.Reflection;
[assembly: AssemblyVersion("$releaseVersion.$buildNumber")]
[assembly: AssemblyFileVersion("$releaseVersion.$buildNumber")]
[assembly: AssemblyInformationalVersion("$fullVersion")]
namespace QingTingInstaller {
    internal static class BuildVersion {
        internal const string FullVersion = "$fullVersion";
        internal const string ReleaseVersion = "$releaseVersion";
    }
}
"@
[IO.File]::WriteAllText($versionSource, $versionCode, [Text.UTF8Encoding]::new($false))

if (Test-Path -LiteralPath $payloadPath) {
  Remove-Item -LiteralPath $payloadPath -Force
}
if (Test-Path -LiteralPath $setupPath) {
  Remove-Item -LiteralPath $setupPath -Force
}

Compress-Archive -Path (Join-Path $releasePath "*") -DestinationPath $payloadPath -CompressionLevel Optimal -Force

$references = @(
  "/reference:System.dll",
  "/reference:System.Core.dll",
  "/reference:System.Drawing.dll",
  "/reference:System.Windows.Forms.dll",
  "/reference:System.IO.Compression.dll",
  "/reference:System.IO.Compression.FileSystem.dll",
  "/reference:Microsoft.CSharp.dll",
  "/reference:System.Web.Extensions.dll"
)

$args = @(
  "/nologo",
  "/target:winexe",
  "/platform:anycpu",
  "/codepage:65001",
  "/optimize+",
  "/out:$setupPath",
  "/resource:$payloadPath,QingTingPayload.zip"
) + $references

if (Test-Path -LiteralPath $iconPath) {
  $args += "/win32icon:$iconPath"
}

$args += $sourcePath
$args += $enginePath
$args += $versionSource

& $cscPath @args

if ($LASTEXITCODE -ne 0) {
  throw "C# installer compilation failed."
}
if (!(Test-Path -LiteralPath $setupPath)) {
  throw "Installer was not produced: $setupPath"
}

$manifest = [ordered]@{
  schemaVersion = 1
  version = $fullVersion
  'windows-x64' = [ordered]@{
    installer = [IO.Path]::GetFileName($setupPath)
    size = (Get-Item -LiteralPath $setupPath).Length
    sha256 = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLowerInvariant()
  }
}
[IO.File]::WriteAllText((Join-Path $outputPath 'qingting-update.json'), ($manifest | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
$checksums = Get-ChildItem -LiteralPath $outputPath -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' -and $_.Extension -ne '.sha256' } | Sort-Object Name | ForEach-Object {
  '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name
}
[IO.File]::WriteAllText((Join-Path $outputPath 'SHA256SUMS.txt'), (($checksums -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))

Get-Item -LiteralPath $setupPath
