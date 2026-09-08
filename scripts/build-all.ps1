<#
.SYNOPSIS
    Builds the designer, and optionally its test suite, with every supported
    Delphi release installed on this machine.

.DESCRIPTION
    One source tree, one .dproj, three compilers. Each release is built in its
    own child process so that rsvars.bat can put that release's bin directory
    on PATH without the releases interfering with each other - the executable
    resolves rtl<n>.bpl at process start, so a build that inherited the wrong
    PATH would produce a program that cannot run.

    Output lands in bin\Win32\<Config>\<release>\, which VallentaDesigner.Common.props
    derives from $(BDS). Nothing here passes the release to MSBuild.

.PARAMETER Config
    Debug (default) or Release.

.PARAMETER Release
    Studio numbers to build, e.g. 22.0. Defaults to every supported release
    found installed.

.PARAMETER Test
    Also build and run the test suite for each release. Requires DUNITX.

.EXAMPLE
    .\scripts\build-all.ps1
.EXAMPLE
    .\scripts\build-all.ps1 -Config Release -Test
.EXAMPLE
    .\scripts\build-all.ps1 -Release 22.0 -Test
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Config = 'Debug',

    [string[]] $Release,

    [switch] $Test
)

$ErrorActionPreference = 'Stop'

# Studio number -> product name. Adding a release here is half the job; the
# other half is IdeVersion and PackageSuffix in Core.Settings.pas.
$Supported = [ordered]@{
    '22.0' = 'Delphi 11 Alexandria'
    '23.0' = 'Delphi 12 Athens'
    '37.0' = 'Delphi 13 Florence'
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
$AppProj = Join-Path $RepoRoot 'VallentaDesigner.dproj'
$TestProj = Join-Path $RepoRoot 'tests\VallentaDesignerTests.dproj'

function Get-StudioRoot([string] $Version) {
    foreach ($hive in @('HKCU:', 'HKLM:')) {
        $key = "$hive\Software\Embarcadero\BDS\$Version"
        if (Test-Path $key) {
            $root = (Get-ItemProperty $key -ErrorAction SilentlyContinue).RootDir
            if ($root) { return $root.TrimEnd('\') }
        }
    }
    return $null
}

# Runs one command line under that release's rsvars.bat, in a child cmd so the
# PATH it sets does not leak into the next release's build.
function Invoke-InStudio([string] $StudioRoot, [string] $CommandLine) {
    $rsvars = Join-Path $StudioRoot 'bin\rsvars.bat'
    # 2>&1 inside cmd, so the streams are merged before PowerShell sees them.
    # Windows PowerShell turns a native command's stderr into an ErrorRecord,
    # which $ErrorActionPreference='Stop' would treat as fatal - and design
    # packages do write to stderr: EurekaLog prints a frozen-application notice
    # during a passing test run.
    $line = 'call "' + $rsvars + '" && ' + $CommandLine + ' 2>&1'
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # Out-Host, not the pipeline: anything left on the pipeline would be
        # returned alongside the exit code and the caller would compare against it.
        & cmd.exe /c $line | Out-Host
    } finally {
        $ErrorActionPreference = $prev
    }
    return $LASTEXITCODE
}

# A resident core holds the executable open and the link step cannot replace it.
$core = Get-Process VallentaDesigner -ErrorAction SilentlyContinue
if ($core) {
    $pids = $core.Id -join ', '
    Write-Warning "A designer core is running (PID $pids). Quit it from its tray icon, or the link step will fail on a locked executable."
}

if ($Test -and -not $env:DUNITX) {
    throw 'DUNITX is not set. The suite compiles upstream DUnitX from source; ' +
          'clone https://github.com/VSoftTechnologies/DUnitX and point DUNITX at it.'
}

if (-not $Release) {
    $Release = @($Supported.Keys)
} else {
    # -Release 22.0 unquoted reaches here as "22": PowerShell parses the bare
    # token as a number first and the trailing .0 is gone by then.
    $Release = @($Release | ForEach-Object {
        if ($_ -match '^\d+$') { "$_.0" } else { $_ }
    })
}

$results = @()

foreach ($v in $Release) {
    if (-not $Supported.Contains($v)) {
        Write-Warning "Skipping $v - not a supported release."
        continue
    }

    $root = Get-StudioRoot $v
    if (-not $root -or -not (Test-Path (Join-Path $root 'bin\rsvars.bat'))) {
        Write-Host ("-- {0} ({1}): not installed, skipped" -f $v, $Supported[$v]) -ForegroundColor DarkGray
        continue
    }

    Write-Host ("== {0} ({1}) {2} ==" -f $v, $Supported[$v], $Config) -ForegroundColor Cyan

    $common = '/t:Build /p:Config=' + $Config + ' /p:Platform=Win32 /nologo /v:m'
    $row = [pscustomobject]@{
        Release = $v
        Product = $Supported[$v]
        App     = 'skipped'
        Tests   = 'skipped'
        Suite   = 'skipped'
    }

    $code = Invoke-InStudio $root ('msbuild "' + $AppProj + '" ' + $common)
    if ($code -eq 0) { $row.App = 'ok' } else { $row.App = "FAILED ($code)" }

    if ($Test -and $code -eq 0) {
        $code = Invoke-InStudio $root ('msbuild "' + $TestProj + '" ' + $common)
        if ($code -eq 0) { $row.Tests = 'ok' } else { $row.Tests = "FAILED ($code)" }

        if ($code -eq 0) {
            # Fixtures are found by walking up from the executable, so the suite
            # is run from the repository root.
            $exe = Join-Path $RepoRoot ('tests\bin\Win32\' + $Config + '\' + $v + '\VallentaDesignerTests.exe')
            Push-Location $RepoRoot
            try {
                $code = Invoke-InStudio $root ('"' + $exe + '"')
            } finally {
                Pop-Location
            }
            # The runner exits with the number of failures plus errors.
            if ($code -eq 0) { $row.Suite = 'all passed' } else { $row.Suite = "$code failed" }
        }
    }

    $results += $row
}

Write-Host ''
Write-Host '== summary ==' -ForegroundColor Cyan
$results | Format-Table Release, Product, App, Tests, Suite -AutoSize

$bad = @($results | Where-Object { $_.App -like 'FAILED*' -or $_.Tests -like 'FAILED*' -or $_.Suite -like '*failed' })
if ($bad.Count -gt 0) { exit 1 }
if ($results.Count -eq 0) { Write-Warning 'Nothing was built.'; exit 1 }
exit 0
