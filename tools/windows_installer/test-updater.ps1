param()
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$output = Join-Path $root ('build\windows-installer-tests\' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $output -Force | Out-Null
$version = [regex]::Match((Get-Content (Join-Path $root 'pubspec.yaml') -Raw), '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
if (-not $version.Success) { throw 'Invalid pubspec version.' }
$release = $version.Groups[1].Value
$build = $version.Groups[2].Value
$generated = Join-Path $output 'BuildVersion.g.cs'
[IO.File]::WriteAllText($generated, @"
using System.Reflection;
[assembly: AssemblyVersion("$release.$build")]
[assembly: AssemblyFileVersion("$release.$build")]
[assembly: AssemblyInformationalVersion("$release+$build")]
namespace QingTingInstaller { internal static class BuildVersion {
  internal const string ReleaseVersion = "$release";
  internal const string FullVersion = "$release+$build";
} }
"@, [Text.UTF8Encoding]::new($false))
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$references = @('/r:System.dll', '/r:System.Core.dll', '/r:System.Drawing.dll', '/r:System.Windows.Forms.dll', '/r:System.IO.Compression.dll', '/r:System.IO.Compression.FileSystem.dll', '/r:System.Web.Extensions.dll', '/r:Microsoft.CSharp.dll')
$fixture = Join-Path $output 'qingting.exe'
& $csc /nologo /codepage:65001 /target:winexe "/out:$fixture" $generated (Join-Path $root 'test\windows\UpdateFixture.cs')
if ($LASTEXITCODE -ne 0) { throw 'Failed to compile fixture.' }
$engine = Join-Path $PSScriptRoot 'UpdateEngine.cs'
$harness = Join-Path $output 'UpdateEngineTests.exe'
& $csc /nologo /codepage:65001 "/out:$harness" @references $generated $engine (Join-Path $root 'test\windows\UpdateEngineTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Failed to compile updater tests.' }
# Compile the production form as well; the release packager embeds its payload.
& $csc /nologo /codepage:65001 /target:winexe "/out:$(Join-Path $output 'SetupCompileCheck.exe')" @references $generated $engine (Join-Path $PSScriptRoot 'QingTingSetup.cs')
if ($LASTEXITCODE -ne 0) { throw 'Failed to compile installer UI.' }
& $harness (Join-Path $output 'cases') $fixture
if ($LASTEXITCODE -ne 0) { throw 'Windows updater integration tests failed.' }
Write-Output "Test fixtures retained at $output"
