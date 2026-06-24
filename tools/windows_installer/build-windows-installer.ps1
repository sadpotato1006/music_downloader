param(
  [string]$ReleaseDir = "build\windows\x64\runner\Release",
  [string]$OutputDir = "dist",
  [string]$Version = "1.2.4"
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$releasePath = Resolve-Path (Join-Path $root $ReleaseDir)
$outputPath = Join-Path $root $OutputDir
$payloadPath = Join-Path $outputPath "QingTingPayload.zip"
$safeVersion = $Version.Replace(".", "_")
$setupPath = Join-Path $outputPath "QingTingSetup-v$safeVersion.exe"
$sourcePath = Join-Path $PSScriptRoot "QingTingSetup.cs"
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
if (!(Test-Path -LiteralPath $sourcePath)) {
  throw "Installer source not found: $sourcePath"
}

New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

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
  "/reference:Microsoft.CSharp.dll"
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

& $cscPath @args

if ($LASTEXITCODE -ne 0) {
  throw "C# installer compilation failed."
}
if (!(Test-Path -LiteralPath $setupPath)) {
  throw "Installer was not produced: $setupPath"
}

Get-Item -LiteralPath $setupPath
