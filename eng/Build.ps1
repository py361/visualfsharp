#
# This script controls the F# build process. This encompasess everything from build, testing to
# publishing of NuGet packages. The intent is to structure it to allow for a simple flow of logic
# between the following phases:
#
#   - restore
#   - build
#   - sign
#   - pack
#   - test
#   - publish
#
# Each of these phases has a separate command which can be executed independently. For instance
# it's fine to call `build.ps1 -build -testDesktop` followed by repeated calls to
# `.\build.ps1 -testDesktop`.

[CmdletBinding(PositionalBinding=$false)]
param (
    [string][Alias('c')]$configuration = "Debug",
    [string][Alias('v')]$verbosity = "m",
    [string]$msbuildEngine = "vs",

    # Actions
    [switch][Alias('r')]$restore,
    [switch][Alias('b')]$build,
    [switch]$rebuild,
    [switch]$sign,
    [switch]$pack,
    [switch]$publish,
    [switch]$launch,
    [switch]$help,

    # Options
    [switch][Alias('proto')]$bootstrap,
    [string]$bootstrapConfiguration = "Proto",
    [string]$bootstrapTfm = "net46",
    [switch][Alias('bl')]$binaryLog,
    [switch]$ci,
    [switch]$official,
    [switch]$procdump,
    [switch]$deployExtensions,
    [switch]$prepareMachine,
    [switch]$useGlobalNuGetCache = $true,
    [switch]$warnAsError = $true,

    # Test actions
    # TODO: use these instead:
    #       testDesktop     total 25m of tests  alias 'test'
    #                    => tests\fsharp\FSharpSuite.Tests.fsproj (15m)
    #                    => tests\FSharp.Compiler.UnitTests\FSharp.Compiler.UnitTests.fsproj why not coreclr? (1m)
    #                    => tests\FSharp.Build.UnitTests\FSharp.Build.UnitTests.fsproj (1m)
    #                    => tests\FSharp.Core.UnitTests\FSharp.Core.UnitTests.fsproj (4m)
    #       testCoreClr     total 25m of tests
    #                    => tests\fsharp\FSharpSuite.Tests.fsproj (15m)
    #                    => tests\FSharp.Compiler.UnitTests\FSharp.Compiler.UnitTests.fsproj (not run as coreclr?) (1m)
    #                    => tests\FSharp.Build.UnitTests\FSharp.Build.UnitTests.fsproj (1m)
    #                    => tests\FSharp.Core.UnitTests\FSharp.Core.UnitTests.fsproj (4m)
    #       testFSharpQA => tests\fsharpqa\testenv\bin\runall.pl (25m)
    #       testVs       => vsintegration\tests\GetTypesVS.UnitTests\GetTypesVS.UnitTests.fsproj (1m)
    #                    => vsintegration\tests\UnitTests\VisualFSharp.UnitTests.fsproj (15m)
    #       testFcs      => fcs\FSharp.Compiler.Service.Tests\FSharp.Compiler.Service.Tests.fsproj (4m)
    [switch][Alias('test')]$testDesktop,
    [switch]$testCoreClr,
    [switch]$testFSharpQA,
    [switch]$testVs,
    [switch]$testFcs,

    [parameter(ValueFromRemainingArguments=$true)][string[]]$properties)

Set-StrictMode -version 2.0
$ErrorActionPreference = "Stop"

function Print-Usage() {
    Write-Host "Common settings:"
    Write-Host "  -configuration <value>    Build configuration: 'Debug' or 'Release' (short: -c)"
    Write-Host "  -verbosity <value>        Msbuild verbosity: q[uiet], m[inimal], n[ormal], d[etailed], and diag[nostic]"
    Write-Host "  -deployExtensions         Deploy built vsixes"
    Write-Host "  -binaryLog                Create MSBuild binary log (short: -bl)"
    Write-Host ""
    Write-Host "Actions:"
    Write-Host "  -restore                  Restore packages (short: -r)"
    Write-Host "  -build                    Build main solution (short: -b)"
    Write-Host "  -rebuild                  Rebuild main solution"
    Write-Host "  -pack                     Build NuGet packages, VS insertion manifests and installer"
    Write-Host "  -sign                     Sign our binaries"
    Write-Host "  -publish                  Publish build artifacts (e.g. symbols)"
    Write-Host "  -launch                   Launch Visual Studio in developer hive"
    Write-Host "  -help                     Print help and exit"
    Write-Host ""
    Write-Host "Test actions"
    Write-Host "  -testDesktop              Run tests against full .NET Framework"
    Write-Host "  -testCoreClr              Run tests against CoreCLR"
    Write-Host "  -testFSharpQA             Run F# Cambridge tests"
    Write-Host "  -testVs                   Run F# editor unit tests"
    Write-Host "  -testFcs                  Run FCS tests"
    Write-Host ""
    Write-Host "Advanced settings:"
    Write-Host "  -ci                       Set when running on CI server"
    Write-Host "  -official                 Set when building an official build"
    Write-Host "  -bootstrap                Build using a bootstrap compiler"
    Write-Host "  -msbuildEngine <value>    Msbuild engine to use to run build ('dotnet', 'vs', or unspecified)."
    Write-Host "  -procdump                 Monitor test runs with procdump"
    Write-Host "  -prepareMachine           Prepare machine for CI run, clean up processes after build"
    Write-Host "  -useGlobalNuGetCache      Use global NuGet cache."
    Write-Host ""
    Write-Host "Command line arguments starting with '/p:' are passed through to MSBuild."
}

# Process the command line arguments and establish defaults for the values which are not
# specified.
function Process-Arguments() {
    if ($help -or (($properties -ne $null) -and ($properties.Contains("/help") -or $properties.Contains("/?")))) {
       Print-Usage
       exit 0
    }

    foreach ($property in $properties) {
        if (!$property.StartsWith("/p:", "InvariantCultureIgnoreCase")) {
            Write-Host "Invalid argument: $property"
            Print-Usage
            exit 1
        }
    }
}

function Update-Arguments() {
    if (-Not (Test-Path "$ArtifactsDir\Bootstrap\fsc.exe")) {
        $script:bootstrap = $True
    }
}

function BuildSolution() {
    # VisualFSharp.sln can't be built with dotnet due to WPF, WinForms and VSIX build task dependencies
    $solution = "VisualFSharp.sln"

    Write-Host "$($solution):"

    $bl = if ($binaryLog) { "/bl:" + (Join-Path $LogDir "Build.binlog") } else { "" }
    $projects = Join-Path $RepoRoot $solution
    $officialBuildId = if ($official) { $env:BUILD_BUILDNUMBER } else { "" }
    $toolsetBuildProj = InitializeToolset
    $quietRestore = !$ci
    $testTargetFrameworks = if ($testCoreClr) { "netcoreapp2.1" } else { "" }

    # Do not set the property to true explicitly, since that would override value projects might set.
    $suppressExtensionDeployment = if (!$deployExtensions) { "/p:DeployExtension=false" } else { "" }

    MSBuild $toolsetBuildProj `
        $bl `
        /p:Configuration=$configuration `
        /p:Projects=$projects `
        /p:RepoRoot=$RepoRoot `
        /p:Restore=$restore `
        /p:Build=$build `
        /p:Test=$testCoreClr `
        /p:Rebuild=$rebuild `
        /p:Pack=$pack `
        /p:Sign=$sign `
        /p:Publish=$publish `
        /p:ContinuousIntegrationBuild=$ci `
        /p:OfficialBuildId=$officialBuildId `
        /p:BootstrapBuildPath=$bootstrapDir `
        /p:QuietRestore=$quietRestore `
        /p:QuietRestoreBinaryLog=$binaryLog `
        /p:TestTargetFrameworks=$testTargetFrameworks `
        $suppressExtensionDeployment `
        @properties
}

function TestUsingNUnit([string] $testProject, [string] $targetFramework) {
    $dotnetPath = InitializeDotNetCli
    $dotnetExe = Join-Path $dotnetPath "dotnet.exe"
    $args = "test $testProject --no-restore --no-build -c $configuration -f $targetFramework -r $ArtifactsDir\TestResults\$configuration"
    Exec-Console $dotnetExe $args
}

try {
    Process-Arguments

    . (Join-Path $PSScriptRoot "build-utils.ps1")

    Update-Arguments

    Push-Location $RepoRoot

    if ($bootstrap) {
        $bootstrapDir = Make-BootstrapBuild
    }

    if ($restore -or $build -or $rebuild -or $pack -or $sign -or $publish) {
        BuildSolution
    }

    $desktopTargetFramework = "net46"
    $coreclrTargetFramework = "netcoreapp2.0"

    if ($testDesktop -or $ci) {
        TestUsingNUnit -testProject "$RepoRoot\tests\FSharp.Compiler.UnitTests\FSharp.Compiler.UnitTests.fsproj" -targetFramework $desktopTargetFramework
        TestUsingNUnit -testProject "$RepoRoot\tests\FSharp.Build.UnitTests\FSharp.Build.UnitTests.fsproj" -targetFramework $desktopTargetFramework
        TestUsingNUnit -testProject "$RepoRoot\tests\FSharp.Core.UnitTests\FSharp.Core.UnitTests.fsproj" -targetFramework $desktopTargetFramework
        TestUsingNUnit -testProject "$RepoRoot\tests\fsharp\FSharpSuite.Tests.fsproj" -targetFramework $desktopTargetFramework
    }

    if ($testCoreClr -or $ci) {
        TestUsingNUnit -testProject "$RepoRoot\tests\FSharp.Compiler.UnitTests\FSharp.Compiler.UnitTests.fsproj" -targetFramework $coreclrTargetFramework # not run as coreclr?
        TestUsingNUnit -testProject "$RepoRoot\tests\FSharp.Build.UnitTests\FSharp.Build.UnitTests.fsproj" -targetFramework $coreclrTargetFramework
        TestUsingNUnit -testProject "$RepoRoot\tests\FSharp.Core.UnitTests\FSharp.Core.UnitTests.fsproj" -targetFramework $coreclrTargetFramework
        TestUsingNUnit -testProject "$RepoRoot\tests\fsharp\FSharpSuite.Tests.fsproj" -targetFramework $coreclrTargetFramework
    }

    if ($testFSharpQA -or $ci) {
        Push-Location "tests\fsharpqa\source"
        $resultsRoot = "$ArtifactsDir\TestResults\$configuration"
        $testLogPrefix = "test-fsharpqa-"
        $resultsLog = "$testLogPrefix-results.log"
        $errorLog = "$testLogPrefix-errors.log"
        $failLog = "$testLogPrefix-fail.log"
        $perlExe = "path\to\perl.exe"
        Exec-Console $perlExe "$repoRoot\tests\fsharpqa\testenv\bin\runall.pl -resultsroot $resultsRoot -results $resultsLog -log $errorLog -fail $failLog -cleanup:no"
        Pop-Location
    }

    if ($testVs -or $ci) {
        TestUsingNUnit -testProject "$RepoRoot\vsintegration\tests\GetTypesVS.UnitTests\GetTypesVS.UnitTests.fsproj" -targetFramework $desktopTargetFramework
        TestUsingNUnit -testProject "$RepoRoot\vsintegration\tests\UnitTests\VisualFSharp.UnitTests.fsproj" -targetFramework $desktopTargetFramework
    }

    if ($testFcs -or $ci) {
        TestUsingNUnit -testProject "$RepoRoot\fcs\FSharp.Compiler.Service.Tests\FSharp.Compiler.Service.Tests.fsproj" -targetFramework $desktopTargetFramework
        TestUsingNUnit -testProject "$RepoRoot\fcs\FSharp.Compiler.Service.Tests\FSharp.Compiler.Service.Tests.fsproj" -targetFramework $coreclrTargetFramework
    }

    ExitWithExitCode 0
}
catch {
    Write-Host $_
    Write-Host $_.Exception
    Write-Host $_.ScriptStackTrace
    ExitWithExitCode 1
}
finally {
    Pop-Location
}
