<#
.SYNOPSIS
    Slice OpenCane printables to G-code headlessly, and VERIFY what came out.

.DESCRIPTION
    Creality Print 7.2 is an Orca fork and accepts Orca's command-line
    arguments, so the whole slice can run without touching the GUI:

        .\scripts\slice_gcode.ps1 -Plate bore -Material PLA

    G-code lands in hardware/mount_screwless/gcode/, which is gitignored.

    WHY THIS SCRIPT EXISTS, AND WHY IT PRINTS A VERIFICATION BLOCK

    On 2026-09-12 a plate was sliced for PETG and carried to a printer whose
    CFS had four PLA spools in it. The file would have run its own
    `START_PRINT EXTRUDER_TEMP=250 BED_TEMP=80` against PLA. It was caught by
    reading the G-code header by hand, which is not a process you can rely on
    at 2 a.m.

    So this script re-opens every file it writes and echoes the four numbers
    that decide whether the print is safe:

        filament_type      what the slicer thinks it is making
        START_PRINT ...    what the machine will ACTUALLY heat to
        time / weight      what it will cost you

    START_PRINT is the one that matters. Creality's machine profile
    substitutes the temperatures into that macro call AT SLICE TIME, so the
    number is frozen into the file. Re-tagging the spool on the printer does
    not change it. The filament slot you pick on the touchscreen decides
    which plastic gets fed to that temperature, and nothing checks that they
    agree - which is why the output tells you the slot to use by name.

    MATERIAL -> SLOT
    The slot numbers below are for the machines in the room on 2026-09-12 and
    are NOT a property of the design. Check the Filament Selection screen
    before every print: not every machine has PETG loaded, and on one of them
    all four slots are PLA. If the screen shows `PETG -> [blank]`, that
    machine cannot print a PETG file - do not force it onto a PLA slot.

.PARAMETER Plate
    What to slice.
      bore     - the 5 bore-gauge rings. Settles the cane diameter.
      thread   - threaded stub + ring. Settles thr_clear.
      dovetail - 3 tenon/socket pairs. Settles dt_clear.
      coupons  - all three rows on one plate.
      arm      - the arm. The one REAL part that needs no measurement first:
                 its tenons are drawn at dt_section(0) and the pawl is fixed
                 geometry, so neither pole_d nor dt_clear reaches it.
      collar | ring | cradle | socket | lock
               - real parts. These DO depend on pole_d, so do not print them
                 until the bore rings have been read.

.PARAMETER Material
    PLA (220C nozzle / 55C bed) or PETG (250C / 80C). Sets the filament
    profile; the temperatures come from that profile, not from this script.

.PARAMETER Walls
    Override wall_loops. Use 4 for the bore rings: at the profile default of
    2 a 10 mm ring flexes under thumb pressure, so a bore that is genuinely
    too tight still feels like it "goes on" and the gauge reads large.

.PARAMETER OutDir
    Where to write. Defaults to hardware/mount_screwless/gcode/.

.EXAMPLE
    .\scripts\slice_gcode.ps1 -Plate bore -Material PLA -Walls 4
    .\scripts\slice_gcode.ps1 -Plate coupons -Material PETG -Walls 4
    .\scripts\slice_gcode.ps1 -Plate arm -Material PLA
#>
[CmdletBinding()]
param(
    [ValidateSet('bore', 'thread', 'dovetail', 'coupons', 'arm',
                 'collar', 'ring', 'cradle', 'socket', 'lock')]
    [string]$Plate = 'bore',

    [ValidateSet('PLA', 'PETG')]
    [string]$Material = 'PLA',

    [ValidateRange(1, 10)]
    [int]$Walls = 0,          # 0 = leave the profile alone

    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$repo   = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $repo 'hardware\mount_screwless'
$stlDir = Join-Path $srcDir 'stl'
if (-not $OutDir) { $OutDir = Join-Path $srcDir 'gcode' }

# ------------------------------------------------------------------ locate
$exe = 'C:\Program Files\Creality\Creality Print 7.2\CrealityPrint.exe'
if ($env:CREALITY_PRINT -and (Test-Path $env:CREALITY_PRINT)) { $exe = $env:CREALITY_PRINT }
if (-not (Test-Path $exe)) {
    throw "Creality Print not found at '$exe'. Set `$env:CREALITY_PRINT to the exe."
}

# Vendor profiles ship with the app and live under Roaming. The version
# folder is 7.0 even though the app is 7.2 - do not "correct" that.
$vendor = Join-Path $env:APPDATA 'Creality\Creality Print\7.0\system\Creality'
$machineProfile  = Join-Path $vendor 'machine\SPARKX i7 0.4 nozzle.json'
$processProfile  = Join-Path $vendor 'process\0.20mm Standard @SPARKX i7 0.4 nozzle.json'
$filamentProfile = Join-Path $vendor $(
    if ($Material -eq 'PETG') { 'filament\Generic PETG @SPARKX i7 0.4 nozzle.json' }
    else                      { 'filament\Hyper PLA @SPARKX i7 0.4 nozzle.json'    }
)
foreach ($p in @($machineProfile, $processProfile, $filamentProfile)) {
    if (-not (Test-Path $p)) { throw "Profile not found: $p" }
}

# ------------------------------------------------------- wall_loops override
# Written next to the vendor profile rather than into it: `inherits` is
# resolved by name against the loaded vendor presets, so a copy in a scratch
# directory still inherits fdm_process_creality_common correctly.
if ($Walls -gt 0) {
    $tmpProc = Join-Path ([IO.Path]::GetTempPath()) "opencane_proc_${Walls}wall.json"
    $j = Get-Content $processProfile -Raw | ConvertFrom-Json
    $j.wall_loops = "$Walls"
    $j.name = "0.20mm Standard ${Walls}wall @SPARKX i7 0.4 nozzle"
    $j | ConvertTo-Json -Depth 30 | Set-Content $tmpProc -Encoding utf8
    $processProfile = $tmpProc
}

# ------------------------------------------------------------------ models
$models = switch ($Plate) {
    'bore'     { @('coupons_bore.stl') }
    'thread'   { @('coupons_thread.stl') }
    'dovetail' { @('coupons_dovetail.stl') }
    'coupons'  { @('coupons_bore.stl', 'coupons_thread.stl', 'coupons_dovetail.stl') }
    default    { @("$Plate.stl") }
}
$paths = foreach ($m in $models) {
    $f = Join-Path $stlDir $m
    if (-not (Test-Path $f)) { throw "Missing $f - run .\scripts\build_stl.ps1 first." }
    $f
}

# -------------------------------------------------------------------- slice
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$work = Join-Path ([IO.Path]::GetTempPath()) ("opencane_slice_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null

Write-Host "Slicing $Plate in $Material$(if ($Walls) { " at $Walls walls" }) ..." -ForegroundColor Cyan
# Build the argument list as a flat array. Do NOT use backtick line
# continuations with a splatted @paths here: one trailing space after a
# backtick silently truncates the command and you get an empty output
# directory with no error from the exe.
$argv = @('--load-settings', "$machineProfile;$processProfile",
          '--load-filaments', $filamentProfile,
          '--slice', '0', '--arrange', '1',
          '--outputdir', $work) + $paths
# Both halves of this line are load-bearing. Do not "tidy" either away.
#
# `2>&1 | Out-String` - Creality Print writes its ENTIRE log to stderr at
# [error] level, including on a completely successful slice. Left
# unredirected, the call returns instantly with an empty $LASTEXITCODE and
# writes no G-code at all, which looks exactly like "the model does not fit
# the bed". Redirecting and piping makes PowerShell drain the stream and the
# slice runs to completion. This is the OPPOSITE of scripts/build_stl.ps1,
# where 2>&1 must be avoided because it trips $? on OpenSCAD's clean exits -
# same shell, same version, opposite fix, because the two exes use the
# streams differently. Verified both ways on 2026-09-12.
#
# Relaxing $ErrorActionPreference - with the redirect in place the stderr
# lines arrive as ErrorRecords, and under 'Stop' the first one still aborts.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try   { $log = & $exe @argv 2>&1 | Out-String }
finally { $ErrorActionPreference = $prevEAP }

$made = Get-ChildItem $work -Filter '*.gcode' -ErrorAction SilentlyContinue
if (-not $made) {
    $tail = if ($log) { $log.Substring([Math]::Max(0, $log.Length - 1200)) } else { '(no output)' }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    throw "Slice produced no G-code. Check that the models fit the 260x260 bed.`nSlicer said:`n$tail"
}

# ------------------------------------------------------------------ verify
# Everything below is the point of the script. Read it before you print.
$gc = $made[0].FullName
# The settings Orca reports live in a comment block at the END of the file,
# not the top - only the START_PRINT call and the thumbnail are near the
# head. Reading just the head made every field below come back empty, which
# silently disabled the material guard. Read both ends.
# 1200 is not arbitrary: on a 319k-line plate the block runs from about 600
# lines before EOF (filament used, printing time, filament_type) down to 36
# lines before EOF (wall_loops). -Tail 400 clipped the first three and the
# guard below then could not read them.
$meta = @(Get-Content $gc -TotalCount 400) + @(Get-Content $gc -Tail 1200)
function Field([string]$pattern) {
    $m = $meta | Select-String -Pattern $pattern | Select-Object -First 1
    if ($m) { $m.ToString().Trim() } else { $null }
}
$ftype = (Field '^; filament_type\s*=') -replace '^;\s*filament_type\s*=\s*', ''
$start = Field 'START_PRINT'
$time  = (Field '^; estimated printing time \(normal mode\)') -replace '^.*=\s*', ''
$grams = (Field '^; filament used \[g\]') -replace '^.*=\s*', ''
$wl    = (Field '^; wall_loops\s*=') -replace '^.*=\s*', ''

if (-not $start) { throw "No START_PRINT line in the sliced file - refusing to name it safe." }
if ($start -notmatch 'EXTRUDER_TEMP=(\d+)\s+BED_TEMP=(\d+)') {
    throw "START_PRINT line is not in the expected form: $start"
}
$nozzleT = [int]$Matches[1]
$bedT    = [int]$Matches[2]

# The slicer's own idea of the material must agree with what we asked for.
# If these disagree the filament profile lookup picked the wrong file and
# every temperature above is untrustworthy. An EMPTY value is also a failure,
# not a pass: it means the field was not found, and a guard that cannot read
# the file must not silently approve it.
if (-not $ftype) {
    throw "Could not read filament_type out of the sliced file. Refusing to call it safe."
}
if ($ftype.Trim() -ne $Material) {
    throw "Asked for $Material but the G-code says filament_type = $ftype. Refusing to write it."
}
# Cross-check the temperature against the material as well, so a profile
# that is edited later cannot quietly ship PLA temperatures on a PETG plate.
$expect = if ($Material -eq 'PETG') { 250 } else { 220 }
if ($nozzleT -ne $expect) {
    Write-Warning "$Material normally runs $expect C but this file says $nozzleT C. Check the filament profile before printing."
}

$slot = if ($Material -eq 'PETG') { 'slot2' } else { 'slot3or4' }
$tag  = ($time -replace '\s', '')
$name = "{0}_{1}__{2}_{3}.gcode" -f $Material, $slot, $Plate, $tag
$dest = Join-Path $OutDir $name
Move-Item $gc $dest -Force
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "  $name" -ForegroundColor Green
Write-Host "  material   $Material  (filament_type = $ftype)"
Write-Host "  nozzle     $nozzleT C"
Write-Host "  bed        $bedT C"
Write-Host "  walls      $wl"
Write-Host "  time       $time"
Write-Host "  weight     $grams g"
Write-Host "  start line $start"
Write-Host ""
Write-Host "  LOAD IT ON A $Material SLOT. On the machines in the room that is" -ForegroundColor Yellow
Write-Host "  $(if ($Material -eq 'PETG') { 'slot 2' } else { 'slot 3 or 4' }) - but CHECK the Filament Selection screen, because not every" -ForegroundColor Yellow
Write-Host "  machine is loaded the same. If it shows '$Material -> [blank]' that" -ForegroundColor Yellow
Write-Host "  machine has no $Material and the print will be wrong at $nozzleT C." -ForegroundColor Yellow
Write-Host ""
Write-Host "Wrote $dest" -ForegroundColor Green
