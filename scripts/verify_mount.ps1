<#
.SYNOPSIS
    Test the screwless mount before anything goes to a printer.

.DESCRIPTION
    Runs hardware/mount_screwless/verify.scad through OpenSCAD for every
    check, measures what comes out with scripts/stl_tools.js, and compares
    against what SHOULD have come out. Exit code 1 if anything is wrong.

        .\scripts\verify_mount.ps1            # everything, ~2 minutes
        .\scripts\verify_mount.ps1 -Quick     # skips the sweeps

    What it proves, in order:
      1. Nothing that must not touch, touches: phone vs cradle (with the
         camera plateau and lenses), phone vs arm, arm vs cradle, cane vs
         everything, ring vs collar thread, arm vs collar.
      2. The things that must touch, do: the collet squeeze; a cane that
         is too big for the bore.
      3. The thread works as a mechanism: the ring lifted 0.75 / 2.25 mm
         and turned the matching fraction of a turn stays clear of the
         collar's teeth, and turned the WRONG way it does not; its cone
         only meets the collar's cone in the last collet_squeeze /
         (cone_taper / cone_len) mm (7.5 mm at the shipped numbers);
         axial slack per flank is thr_axial/2 + thr_clear * flank slope
         (0.49 mm at the shipped numbers - see the comment at the sweep;
         NOT just thr_axial/2).
      4. The ring is the collar joint's lock: the arm lifted 0.4 mm is free
         (that is its gap), lifted 1 mm it hits the ring.
      5. The collar, ring, arm and cradle STLs are one solid shell each,
         and the print-orientation overhang report for the arm and the
         cradle looks as documented (printed for a human; not a PASS/FAIL).
         Socket, lock, coupons and the ball tip are NOT shell-checked.

    A full run prints 32 PASS/FAIL lines (11 + 2 + 13 + 2 + 4); -Quick
    prints 17. Older docs say "30 checks"; count the Say calls, not the docs.

    CALLERS / TESTS
    Run by hand on the Windows CAD machine after build_stl.ps1 (section 5
    reads its STLs: on a fresh clone they are missing and fail, after a
    parameter change they are stale) and before slice_gcode.ps1. This
    script IS the mount's test suite; nothing runs it automatically. Needs
    OpenSCAD with the Manifold backend (always passed here, unlike
    build_stl.ps1) and node.

    The preview cannot do any of this: it draws overlaps in colour and
    they look like nothing at all. Each of these checks caught a real
    defect on 2026-09-12; see CHANGELOG.md, Step 25 (the pass that built
    this harness), and Step 21 for the thread and bore findings.

.PARAMETER Quick
    Skip the kinematic sweeps (3 and 4).
#>
[CmdletBinding()]
param([switch]$Quick)

$ErrorActionPreference = 'Stop'
$repo   = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $repo 'hardware\mount_screwless'
$harn   = Join-Path $srcDir 'verify.scad'
$tools  = Join-Path $PSScriptRoot 'stl_tools.js'
# Scratch dir for the intersection STLs; old ones are deleted at start.
$work   = Join-Path ([IO.Path]::GetTempPath()) 'opencane_verify'
New-Item -ItemType Directory -Force -Path $work | Out-Null
Get-ChildItem "$work\*.stl" -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item $_.FullName -Force }

# same search as build_stl.ps1 (returns only the path; the Fast flag is not
# needed because --backend=manifold is always passed below)
function Find-OpenScad {
    if ($env:OPENSCAD -and (Test-Path $env:OPENSCAD)) { return $env:OPENSCAD }
    $snap = Get-ChildItem -Path (Join-Path $env:USERPROFILE 'Tools\OpenSCAD-*\openscad.com') -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($snap) { return $snap.FullName }
    if (Test-Path 'C:\Program Files\OpenSCAD\openscad.com') { return 'C:\Program Files\OpenSCAD\openscad.com' }
    throw "OpenSCAD not found. See build_stl.ps1."
}
$scad = Find-OpenScad
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw "node is not on the PATH; stl_tools.js needs it." }

# Number of failed checks; any makes the script exit 1.
$fails = 0
# Print one PASS/FAIL line and count failures ($script: scope, because the
# function's own $fails would be a new local).
function Say($ok, $text) {
    if ($ok) { Write-Host ("  PASS  " + $text) -ForegroundColor Green }
    else     { Write-Host ("  FAIL  " + $text) -ForegroundColor Red; $script:fails++ }
}
# Volume of the overlap a check renders, in mm3. 0 for an empty result.
# The -D value is escaped with \" because that is the only quoting that
# reaches the exe intact from Windows PowerShell 5.1 (see build_stl.ps1).
# $check names a branch in verify.scad (`check == "..."`); $extra adds -D
# overrides such as delta / rot_sign / shift / lift / test_cane.
function Overlap([string]$check, [string[]]$extra = @()) {
    $out = Join-Path $work ("{0}_{1}.stl" -f $check, ([guid]::NewGuid().ToString('N').Substring(0, 6)))
    $argv = @('--backend=manifold', '--export-format', 'binstl', '-o', $out, '-D', ('check=\"' + $check + '\"')) + $extra + @($harn)
    $log = & $scad @argv 2>&1 | Out-String
    # -cmatch and anchored: OpenSCAD's own status line says 'NoError'.
    if ($log -cmatch '(?m)^ERROR:') { throw "OpenSCAD error in check '$check':`n$log" }
    # No STL = OpenSCAD found nothing to export (it exits non-zero for EMPTY
    # geometry, which is why the exit code is not read). That is the empty
    # result the "must be empty" checks want.
    # ⚠ Any other failure that writes no STL and prints no ^ERROR: line also
    # returns 0 here and PASSES a must-be-empty check; and an unparseable
    # stl_tools line returns -1, which also passes "-lt 5". A suspicious
    # 0.00 on a check that used to show slivers deserves a look.
    if (-not (Test-Path $out)) { return 0.0 }
    $line = & node $tools vol $out
    if ($line -match '\s(-?[\d.]+) cm3') { return [double]$Matches[1] * 1000 } else { return -1 }
}

Write-Host "OpenSCAD: $scad" -ForegroundColor Cyan
Write-Host "`n1. must be empty (coplanar slivers under 5 mm3 are allowed)" -ForegroundColor Cyan
foreach ($c in 'phone_cradle', 'plateau_cradle', 'phone_parts', 'arm_phone', 'cane_parts', 'cane_collar',
               'ring_thread', 'arm_collar', 'arm_cradle', 'arm_ring', 'cradle_parts') {
    $v = Overlap $c
    Say ($v -lt 5) ("{0,-16} {1,8:n2} mm3" -f $c, $v)
}

Write-Host "`n2. must NOT be empty" -ForegroundColor Cyan
# ⚠ The numbers in the messages below (27.65 + 0.40 bore, ~830 mm3 at
# collet_squeeze 0.6) and the literals in sections 3 and 4 mirror
# hardware/mount_screwless/screwless_mount.scad; update them with it.
$v = Overlap 'ring_cone';  Say ($v -gt 300) ("ring_cone        {0,8:n0} mm3  (the collet squeeze; ~830 at collet_squeeze 0.6)" -f $v)
$v = Overlap 'cane_fit' @('-D', 'test_cane=28.75'); Say ($v -gt 500) ("cane_fit 28.75   {0,8:n0} mm3  (a 28.75 cane vs the 27.65 + 0.40 bore must clash)" -f $v)

if (-not $Quick) {
    Write-Host "`n3. thread as a mechanism" -ForegroundColor Cyan
    foreach ($d in 0.75, 2.25) {
        $right = Overlap 'ring_at_thread' @('-D', "delta=$d", '-D', 'rot_sign=1')
        $wrong = Overlap 'ring_at_thread' @('-D', "delta=$d", '-D', 'rot_sign=-1')
        Say ($right -lt 5 -and $wrong -gt 50) ("lifted {0} mm: turned with the helix {1,6:n1} mm3, against it {2,6:n1} mm3" -f $d, $right, $wrong)
    }
    # Literals: collet_squeeze 0.60, cone_taper 1.60, cone_len 20.0 (screwless_mount.scad).
    $engage = 0.6 / (1.6 / 20)   # collet_squeeze / (cone_taper / cone_len): where the cone should start touching
    foreach ($d in 0, 3, 6, 9, 12, 15, 18) {
        $v = Overlap 'ring_at_cone' @('-D', "delta=$d", '-D', 'rot_sign=1')
        if ($d -lt $engage - 0.5) { Say ($v -gt 50) ("cone, ring {0,2} mm up: {1,7:n1} mm3 - squeezing" -f $d, $v) }
        else                      { Say ($v -lt 5)  ("cone, ring {0,2} mm up: {1,7:n1} mm3 - free (engages below {2:n1} mm)" -f $d, $v, $engage) }
    }
    # Effective axial slack per flank is NOT just thr_axial/2: the flanks are
    # sloped (thr_pitch * (thr_duty - thr_crest) axial per thr_depth radial =
    # 0.58), so the radial clearance shifts the female flank outward AND
    # sideways. slack = thr_axial/2 + thr_clear * slope = 0.225 + 0.45 * 0.58
    # = 0.49 mm at the shipped numbers. The chord-profile thread that
    # preceded 2026-09-12 had near-vertical flanks and no such term, which
    # is why the bench's [0.35, 0.25] nut jammed on it and why a printed
    # ring on this thread rocks about 1 mm at the top when loose - and not
    # at all once it bears on the cone.
    # Literals: thr_pitch 3.00, thr_duty 0.30, thr_crest 0.067, thr_depth 1.20,
    # thr_axial 0.45 and thr_clear 0.45 (screwless_mount.scad; nut 3 of the coupon).
    $slope = 3.0 * (0.30 - 0.067) / 1.2
    $slack = 0.45 / 2 + 0.45 * $slope
    foreach ($s in ($slack - 0.15), ($slack - 0.05), ($slack + 0.05), ($slack + 0.15)) {
        $s = [math]::Round($s, 2)
        $v = Overlap 'ring_shift_thread' @('-D', "shift=$s")
        if ($s -lt $slack) { Say ($v -lt 5) ("flank slack: ring shifted {0} mm, {1,6:n1} mm3 - free (slack {2:n2})" -f $s, $v, $slack) }
        else               { Say ($v -gt 5) ("flank slack: ring shifted {0} mm, {1,6:n1} mm3 - touching (slack {2:n2})" -f $s, $v, $slack) }
    }

    Write-Host "`n4. the ring locks the arm" -ForegroundColor Cyan
    $v = Overlap 'arm_lift_ring' @('-D', 'lift=0.4'); Say ($v -lt 1)  ("arm lifted 0.4 mm: {0,6:n1} mm3 - free (its gap under the ring is 0.5)" -f $v)
    $v = Overlap 'arm_lift_ring' @('-D', 'lift=1');   Say ($v -gt 1)  ("arm lifted 1.0 mm: {0,6:n1} mm3 - stopped by the ring" -f $v)
}

Write-Host "`n5. printables are single shells (run build_stl.ps1 first)" -ForegroundColor Cyan
$stl = Join-Path $srcDir 'stl'
foreach ($p in 'collar', 'ring', 'arm', 'cradle') {
    $f = Join-Path $stl "$p.stl"
    if (-not (Test-Path $f)) { Say $false "$p.stl missing - run .\scripts\build_stl.ps1"; continue }
    $line = (& node $tools shells $f | Select-Object -First 1)
    Say ($line -match 'shells \d+ \(1 with volume\)') $line
}
Write-Host "`n   overhang report, print orientation (the cradle's plate, rails and caps need support; nothing else should)" -ForegroundColor Cyan
foreach ($p in 'arm', 'cradle') { $f = Join-Path $stl "$p.stl"; if (Test-Path $f) { & node $tools overhang $f | ForEach-Object { "      $_" } } }

Write-Host ""
if ($fails) { Write-Host "$fails check(s) FAILED. Do not print." -ForegroundColor Red; exit 1 }
Write-Host "All checks passed." -ForegroundColor Green
