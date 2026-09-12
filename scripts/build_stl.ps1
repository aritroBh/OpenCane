<#
.SYNOPSIS
    Render every OpenCane printable to STL.

.DESCRIPTION
    One command, no arguments needed:

        .\scripts\build_stl.ps1

    STLs land in hardware/mount_screwless/stl/, which is gitignored.
    Never commit an STL - the .scad file is the source of truth and the
    STL is a build artifact that goes stale the moment a parameter moves.

    WHICH OPENSCAD
    The 2021.01 release that winget installs has no Manifold backend and
    takes about SEVEN MINUTES to render the threaded collar. A 2025
    development snapshot renders the same part in under a second. This
    script looks for a snapshot first and only falls back to 2021.01,
    with a warning, if it cannot find one.

    Search order:
      1. $env:OPENSCAD                       (set this to override)
      2. C:\Users\<you>\Tools\OpenSCAD-*     (portable snapshot)
      3. C:\Program Files\OpenSCAD           (winget release)

    To get a snapshot: download the portable zip from
    https://files.openscad.org/snapshots/ and unzip it into
    %USERPROFILE%\Tools\.

.PARAMETER Part
    Render one part instead of all of them.
    collar | ring | arm | cradle | coupons

.PARAMETER Png
    Also write a preview PNG next to each STL.
#>
[CmdletBinding()]
param(
    [ValidateSet('all', 'collar', 'ring', 'arm', 'cradle', 'coupons')]
    [string]$Part = 'all',
    [switch]$Png
)

$ErrorActionPreference = 'Stop'
$repo    = Split-Path -Parent $PSScriptRoot
$srcDir  = Join-Path $repo 'hardware\mount_screwless'
$outDir  = Join-Path $srcDir 'stl'
$mainScad    = Join-Path $srcDir 'screwless_mount.scad'
$couponScad  = Join-Path $srcDir 'coupons.scad'

# ---------------------------------------------------------------- locate
function Find-OpenScad {
    if ($env:OPENSCAD -and (Test-Path $env:OPENSCAD)) {
        return [pscustomobject]@{ Path = $env:OPENSCAD; Fast = $true }
    }
    $toolsGlob = Join-Path $env:USERPROFILE 'Tools\OpenSCAD-*\openscad.com'
    $snap = Get-ChildItem -Path $toolsGlob -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($snap) { return [pscustomobject]@{ Path = $snap.FullName; Fast = $true } }

    $rel = 'C:\Program Files\OpenSCAD\openscad.com'
    if (Test-Path $rel) { return [pscustomobject]@{ Path = $rel; Fast = $false } }

    throw "OpenSCAD not found. Install a snapshot into $env:USERPROFILE\Tools\ or run: winget install OpenSCAD.OpenSCAD"
}

$scad = Find-OpenScad
Write-Host "OpenSCAD: $($scad.Path)" -ForegroundColor Cyan
if (-not $scad.Fast) {
    Write-Warning "This is the 2021.01 release - no Manifold backend. The collar and ring take several MINUTES each."
    Write-Warning "Grab a snapshot from https://files.openscad.org/snapshots/ and unzip to $env:USERPROFILE\Tools\ ."
}
$backend = if ($scad.Fast) { @('--backend=manifold') } else { @() }

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# ------------------------------------------------------------------ render
# Windows PowerShell 5.1 eats the double quotes around an -D value before
# the exe ever sees them, so `part="collar"` arrives as `part=collar` and
# OpenSCAD renders nothing. Escaping them as \" is what survives. Do not
# "tidy" these back into plain quotes.
$targets = @(
    @{ Name = 'collar';  Scad = $mainScad;   Def = 'part=\"collar\"' },
    @{ Name = 'ring';    Scad = $mainScad;   Def = 'part=\"ring\"'   },
    @{ Name = 'arm';     Scad = $mainScad;   Def = 'part=\"arm\"'    },
    @{ Name = 'cradle';  Scad = $mainScad;   Def = 'part=\"cradle\"' },
    @{ Name = 'coupons'; Scad = $couponScad; Def = 'what=\"all\"'    }
)
if ($Part -ne 'all') { $targets = $targets | Where-Object { $_.Name -eq $Part } }

$fail = 0
foreach ($t in $targets) {
    $stl = Join-Path $outDir "$($t.Name).stl"
    if (Test-Path $stl) { Remove-Item $stl -Force }
    Write-Host ("  {0,-9} -> {1}" -f $t.Name, (Split-Path -Leaf $stl)) -NoNewline
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # no 2>&1 here: in 5.1 it wraps native stderr in ErrorRecords and
    # trips $? even on a clean exit.
    # binstl: OpenSCAD still defaults to ASCII STL, which is ~5x larger
    # and makes Creality Print sluggish on the threaded parts.
    $argv = @() + $backend + @('--export-format', 'binstl', '-o', $stl,
                               '-D', $t.Def, $t.Scad)
    $out  = & $scad.Path @argv
    $code = $LASTEXITCODE
    $sw.Stop()

    if ($code -ne 0 -or -not (Test-Path $stl)) {
        Write-Host "  FAILED (exit $code)" -ForegroundColor Red
        $out | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
        $fail++
        continue
    }
    $kb = [math]::Round((Get-Item $stl).Length / 1KB)
    Write-Host ("  ok  {0,6:n1}s  {1,7} KB" -f $sw.Elapsed.TotalSeconds, $kb) -ForegroundColor Green
    # 'NoError' contains 'ERROR'; match only real diagnostics.
    $out | Select-String -Pattern 'WARNING:', 'ERROR:' |
        ForEach-Object { Write-Host "      $_" -ForegroundColor Yellow }

    if ($Png) {
        # NOT $png - that is the -Png switch, and PowerShell vars are
        # case-insensitive, so assigning to it clobbers the parameter.
        $pngPath = Join-Path $outDir "$($t.Name).png"
        $pargv = @() + $backend + @('-o', $pngPath, '--imgsize=900,900',
                                    '--viewall', '--autocenter', '-D', $t.Def, $t.Scad)
        & $scad.Path @pargv | Out-Null
    }
}

Write-Host ""
if ($fail -gt 0) {
    Write-Host "$fail part(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "STLs in $outDir" -ForegroundColor Green
Write-Host "Import them into Creality Print. Print coupons.stl FIRST - see hardware/mount_screwless/README.md." -ForegroundColor Green
