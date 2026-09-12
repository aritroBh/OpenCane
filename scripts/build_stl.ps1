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
    collar | ring | arm | cradle | coupons | socket | lock
    coupons_bore | coupons_thread | coupons_dovetail   - one coupon ROW at a
                                                time (the names slice_gcode.ps1 asks for)
    coupons_next                                - thread + dovetail rows, bore done
    swivel_test | ball_lower | ball_upper | ball_stem   - rolling ball tip

.PARAMETER Png
    Also write a preview PNG next to each STL.

.PARAMETER PoleD
    Render the two cane-dependent parts (collar and ring) for a different
    cane diameter without editing the .scad, and name the files for it:
    -PoleD 28.75 writes collar_pole28.75.stl and ring_pole28.75.stl.
    Nothing else depends on pole_d. Use it to have the collar for every
    candidate diameter sliced and on the stick before the bore rings have
    been read.
#>
[CmdletBinding()]
param(
    [ValidateSet('all', 'collar', 'ring', 'arm', 'cradle', 'coupons', 'socket', 'lock',
                 'coupons_bore', 'coupons_thread', 'coupons_dovetail', 'coupons_next',
                 'swivel_test', 'ball_lower', 'ball_upper', 'ball_stem')]
    [string]$Part = 'all',
    [switch]$Png,
    [double]$PoleD = 0
)

$ErrorActionPreference = 'Stop'
$repo    = Split-Path -Parent $PSScriptRoot
$srcDir  = Join-Path $repo 'hardware\mount_screwless'
$outDir  = Join-Path $srcDir 'stl'
$mainScad    = Join-Path $srcDir 'screwless_mount.scad'
$couponScad  = Join-Path $srcDir 'coupons.scad'
$tipScad     = Join-Path $repo 'hardware/cane_tip/ball_tip.scad'

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
    @{ Name = 'coupons'; Scad = $couponScad; Def = 'what=\"all\"'    },
    # The single-row coupon plates. slice_gcode.ps1 asks for these by name
    # (-Plate bore | thread | dovetail), so rendering only the combined
    # 'coupons' above left the runbook's very first command with no STL.
    @{ Name = 'coupons_bore';     Scad = $couponScad; Def = 'what=\"bore\"'     },
    @{ Name = 'coupons_thread';   Scad = $couponScad; Def = 'what=\"thread\"'   },
    @{ Name = 'coupons_dovetail'; Scad = $couponScad; Def = 'what=\"dovetail\"' },
    @{ Name = 'coupons_next';     Scad = $couponScad; Def = 'what=\"next\"'     },
    # Ball-joint parts. Only needed when joint = "ball" in the .scad;
    # harmless to render either way, and cheap.
    @{ Name = 'socket';  Scad = $mainScad;   Def = 'part=\"socket\"' },
    @{ Name = 'lock';    Scad = $mainScad;   Def = 'part=\"lock\"'   },
    # Rolling ball tip (hardware/cane_tip/ball_tip.scad). swivel_test FIRST -
    # it is 9 cm3 and decides whether a printed swivel spins at all.
    @{ Name = 'swivel_test'; Scad = $tipScad; Def = 'part=\"swivel_test\"' },
    @{ Name = 'ball_lower';  Scad = $tipScad; Def = 'part=\"lower\"'       },
    @{ Name = 'ball_upper';  Scad = $tipScad; Def = 'part=\"upper\"'       },
    @{ Name = 'ball_stem';   Scad = $tipScad; Def = 'part=\"stem\"'        }
)
if ($Part -ne 'all') { $targets = $targets | Where-Object { $_.Name -eq $Part } }

# A pole_d override only means something for the main file's parts, and the
# arm is drawn at nominal so it never changes. Everything else gets the
# extra -D and a file name that says which cane it is for.
$poleTag = if ($PoleD -gt 0) { '_pole' + $PoleD.ToString([Globalization.CultureInfo]::InvariantCulture) } else { '' }
# The inner parentheses are load-bearing: in PowerShell the comma binds
# tighter than +, so @('-D', 'pole_d=' + $x) is THREE elements and OpenSCAD
# prints its usage screen.
$poleDef = if ($PoleD -gt 0) { @('-D', ('pole_d=' + $PoleD.ToString([Globalization.CultureInfo]::InvariantCulture))) } else { @() }
# Only the collar and the ring are sized by pole_d. The cradle, the socket
# and the lock render byte-identical for any cane, and the arm is nominal.
function Uses-PoleD($t) { $PoleD -gt 0 -and $t.Name -in @('collar', 'ring') }

$fail = 0
foreach ($t in $targets) {
    $stl = Join-Path $outDir ("{0}{1}.stl" -f $t.Name, $(if (Uses-PoleD $t) { $poleTag } else { '' }))
    if (Test-Path $stl) { Remove-Item $stl -Force }
    Write-Host ("  {0,-9} -> {1}" -f $t.Name, (Split-Path -Leaf $stl)) -NoNewline
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # no 2>&1 here: in 5.1 it wraps native stderr in ErrorRecords and
    # trips $? even on a clean exit.
    # binstl: OpenSCAD still defaults to ASCII STL, which is ~5x larger
    # and makes Creality Print sluggish on the threaded parts.
    $argv = @() + $backend + @('--export-format', 'binstl', '-o', $stl,
                               '-D', $t.Def) + $(if (Uses-PoleD $t) { $poleDef } else { @() }) + @($t.Scad)
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
        $pngPath = [IO.Path]::ChangeExtension($stl, '.png')
        $pargv = @() + $backend + @('-o', $pngPath, '--imgsize=900,900',
                                    '--viewall', '--autocenter', '-D', $t.Def) + $(if (Uses-PoleD $t) { $poleDef } else { @() }) + @($t.Scad)
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
