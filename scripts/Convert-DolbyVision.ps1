<#
.SYNOPSIS
    Dolby Vision profile 7 handling for Encode-Batch: decides whether a profile 7 title is
    converted to profile 8.1, baked to 8.1 (full enhancement layer) or kept as profile 7, and
    makes the 1080p SDR reference for a title kept as profile 7. Built for Windows PowerShell 5.1.

.DESCRIPTION
    Convert (the default):
      copy the source to -WorkDir ("<name> - p7 source.mkv") -> dovi_convert inspect on the copy
      (in WSL; used only to tell an MEL from an FEL) -> decide:
        - MEL (the enhancement layer is empty): convert to 8.1 with dovi_convert (convert --yes
          --include-simple --force --delete), then check that it's 8.1 -> "<name> - p8.1.mkv"
          (Status Converted).
        - SIMPLE / SAFE or COMPLEX FEL (a full enhancement layer, whatever inspect says it adds):
          bake it: the enhancement layer is applied to the base layer (felbaker, in VapourSynth)
          and the result encoded near-losslessly (NVEncC, HEVC 10-bit CQP -BakeCqp) with the RPU
          converted to 8.1 (dovi_tool -m 2) -> "<name> - baked.mkv", video only (Status
          Converted, Baked; the copy is kept: it's the audio and subtitle source). Steps:
            ffmpeg | dovi_tool demux     -> BL.hevc, EL.hevc   (in "<name> - bake")
            dovi_tool -m 2 extract-rpu   -> RPU_81.bin; dovi_tool info --summary: the frame
                                            count and MaxCLL / MaxFALL (L6)
            vspipe --info bake.vpy       -> checks the script loads (ffms2 indexes the layers)
            vspipe | NVEncC              -> baked.hevc (the source's mastering display,
                                            MaxCLL / MaxFALL from L6, else the source's)
            mkvmerge                     -> "<name> - baked.partial.mkv" (+ the copy's chapters),
                                            checked (frames = RPU frames, Dolby Vision 8.1),
                                            renamed; the "<name> - bake" folder is deleted.
          An interrupted bake picks up after its last finished step (split, encode).
        - NO L1 METADATA (or anything else): kept as profile 7; the copy is left untouched
          (Status KeepP7, P7Copy).
      The decision is saved in "<name>.dovi.json" in -DecisionDir. A season stays one format: when
      another title's .dovi.json in -DecisionDir says keep-p7, this one is kept as profile 7 too,
      without inspecting it; otherwise, when the folder's first title (in name order) was baked
      (an FEL), this one is baked without inspecting it (inspect is slow). An MEL first, or an
      FEL later on, changes nothing: the rest are inspected. A converted or baked copy from an earlier run is reused (and a kept
      title's old one is deleted). Before converting it waits until -WorkDir has room for it
      (about twice the copy's size; a bake, about 2.2 times plus 20 GB), re-checking every 30 s.

      Baking needs VapourSynth with the ffms2 and felbaker plugins (autoloaded: in VapourSynth's
      plugins folder), dovi_tool, ffmpeg (on PATH), mkvmerge and NVEncC.

    -SdrReference:
      a near-lossless 1080p SDR reference from a profile 7 video (its base layer): cropped,
      tone-mapped from HDR (hable, from -SourcePeak nits to 100), scaled to -Width x -Height,
      HEVC 10-bit CQP 12, written to -Output (via "<Output>.partial.mkv"). Reused if -Output
      exists. Encode-Batch encodes the "<name> - 1080p" title from it and scores against it.

    Encode-Batch runs this in its prep worker (with -Plumbing and its title log). It can also
    be run on its own.

.PARAMETER Source
    Convert: the profile 7 source MKV. -SdrReference: the profile 7 video to make the reference from.
.PARAMETER WorkDir
    Convert: where the copy and the converted file go. Default: the source's folder.
.PARAMETER DecisionDir
    Convert: where "<name>.dovi.json" goes, and where the season's other decisions are read
    (Encode-Batch: the title's folder in Dest). Also checked for working files from older runs.
    Default: -WorkDir.
.PARAMETER Basename
    Convert: the name for the working files and the decision. Default: the source's file name.
.PARAMETER DoviTool
    Convert: dovi_tool.exe (for baking): a full path, or on PATH. Default: dovi_tool.
.PARAMETER VsPipe
    Convert: VapourSynth's vspipe.exe (or a portable install's vspipe.bat), for baking: a full
    path, or on PATH. Default: vspipe.
.PARAMETER MkvMerge
    Convert: mkvmerge.exe, for baking. Default: on PATH, else C:\Program Files\MKVToolNix.
.PARAMETER BakeThreads
    Convert: decoder threads for each layer when baking (ffms2 threads=; -1 = all logical CPUs).
    The base layer's decode sets the bake's pace: on an 8-core / 16-thread CPU, 4 gave ~38 fps,
    -1 ~56 fps (all cores busy). Default: -1.
.PARAMETER BakeCqp
    Convert: the baked encode's quality (NVEncC --cqp). Default: 12 (near-lossless).
.PARAMETER SdrReference
    Make the 1080p SDR reference instead (needs -Output, -Width, -Height).
.PARAMETER Output
    -SdrReference: the reference to write.
.PARAMETER Crop
    -SdrReference: pixels to crop first, "Left,Top,Right,Bottom". Default: none.
.PARAMETER Width
    -SdrReference: the reference's width (even).
.PARAMETER Height
    -SdrReference: the reference's height (even).
.PARAMETER SourcePeak
    -SdrReference: the source's peak brightness in nits, for the tone-mapping (its MaxCLL).
    Default: 1000.
.PARAMETER NVEncC
    Baking and -SdrReference: path to NVEncC64.exe. Default: %APPDATA%\NVEnc\NVEncC64.exe.
.PARAMETER WslDistro
    WSL distribution for dovi_convert. Default: the default one.
.PARAMETER WslMountRoot
    Where Windows drives are mounted in WSL. Default: /mnt.
.PARAMETER DoviConvertCmd
    dovi_convert's command in WSL (on PATH for a login shell, or a full path). Default: dovi_convert.
.PARAMETER RemountCmd
    Run in WSL when a file isn't visible there (e.g. a dropped network-drive mount). Default:
    none, and the drive is mounted again as root (wsl -u root mount -t drvfs X: /mnt/x).
.PARAMETER TempDir
    For the scripts run in WSL and the programs' output. Default: your temp folder.
.PARAMETER LogPath
    Log to add to (Encode-Batch: the title's .encode.log). Default: none (screen only).
.PARAMETER LogPrefix
    Put in front of every log line.
.PARAMETER StatusFile
    JSON file for progress (Encode-Batch's console reads it). Default: none.
.PARAMETER Status
    Fields to keep in every status update.
.PARAMETER Plumbing
    For Encode-Batch: nothing on screen; one line of JSON on stdout when done:
      Status    Convert: Converted, KeepP7 or Failed. -SdrReference: Done or Failed.
      Message   why it was kept as profile 7, or why it failed
      WorkSrc   Converted: the 8.1 file to encode from (converted, or baked)
      Note      Converted: a note for the reports (e.g. that it was baked), or ""
      Baked     Converted: true when WorkSrc is the baked file (video only)
      P7Copy    KeepP7: the untouched profile 7 copy. Baked: the copy (the audio and subtitles)
      Output    -SdrReference: the reference

.EXAMPLE
    .\Convert-DolbyVision.ps1 -Source 'S:\Sources\Movies\M\M.mkv' -WorkDir 'D:\Work\M' -DoviTool 'C:\Tools\dovi_tool.exe' -VsPipe 'C:\VapourSynth\vspipe.exe'
.EXAMPLE
    .\Convert-DolbyVision.ps1 -SdrReference -Source 'D:\Work\M\M - p7 source.mkv' -Output 'D:\Work\M\M - 1080p ref.mkv' -Crop '0,276,0,276' -Width 1920 -Height 804 -SourcePeak 1000
#>
[CmdletBinding(DefaultParameterSetName = 'Convert')]
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(ParameterSetName = 'Convert')][string]$WorkDir = '',
    [Parameter(ParameterSetName = 'Convert')][string]$DecisionDir = '',
    [Parameter(ParameterSetName = 'Convert')][string]$Basename = '',
    [Parameter(ParameterSetName = 'Convert')][string]$DoviTool = 'dovi_tool',
    [Parameter(ParameterSetName = 'Convert')][string]$VsPipe = 'vspipe',
    [Parameter(ParameterSetName = 'Convert')][string]$MkvMerge = 'mkvmerge',
    [Parameter(ParameterSetName = 'Convert')][int]$BakeCqp = 12,
    [Parameter(ParameterSetName = 'Convert')][ValidateRange(-1, 64)][int]$BakeThreads = -1,
    [Parameter(ParameterSetName = 'SdrReference', Mandatory)][switch]$SdrReference,
    [Parameter(ParameterSetName = 'SdrReference', Mandatory)][string]$Output,
    [Parameter(ParameterSetName = 'SdrReference')][string]$Crop = '',
    [Parameter(ParameterSetName = 'SdrReference', Mandatory)][int]$Width,
    [Parameter(ParameterSetName = 'SdrReference', Mandatory)][int]$Height,
    [Parameter(ParameterSetName = 'SdrReference')][int]$SourcePeak = 1000,
    [string]$NVEncC = '',
    [string]$WslDistro = '',
    [string]$WslMountRoot = '/mnt',
    [string]$DoviConvertCmd = 'dovi_convert',
    [string]$RemountCmd = '',
    [string]$TempDir = [IO.Path]::GetTempPath(),
    [string]$LogPath = '',
    [string]$LogPrefix = '',
    [string]$StatusFile = '',
    [hashtable]$Status = @{},
    [switch]$Plumbing
)

# Defaults from the settings file (encode-settings.ini) for parameters not given, and paths
# as typed or tab-completed: Shared.ps1, next to this script.
if (-not [IO.File]::Exists((Join-Path $PSScriptRoot 'Shared.ps1'))) { throw "Shared.ps1 not found next to this script ($PSScriptRoot); keep the scripts together." }
. (Join-Path $PSScriptRoot 'Shared.ps1')
$script:SettingsUsed = @(Get-ScriptSettings $MyInvocation.MyCommand $PSBoundParameters)
foreach ($setting in $script:SettingsUsed) { Set-Variable -Name $setting.Name -Value $setting.Value }
foreach ($n in 'Source', 'WorkDir', 'DecisionDir', 'Output', 'TempDir', 'LogPath', 'StatusFile') { Set-Variable -Name $n -Value (Resolve-InputPath (Get-Variable -Name $n -ValueOnly)) }
foreach ($n in 'DoviTool', 'VsPipe', 'MkvMerge', 'NVEncC') { Set-Variable -Name $n -Value (Resolve-InputPath (Get-Variable -Name $n -ValueOnly) -Program) }

# 'Continue', not 'Stop': in Windows PowerShell, 2>&1 on a native program raises terminating
# errors under 'Stop'. Failures are checked explicitly.
$ErrorActionPreference = 'Continue'
# The shared helpers: already loaded when Encode-Batch runs this inside its worker, else from
# Encode-Batch.Common.ps1 next to this script.
if (-not (Get-Command Invoke-Logged -CommandType Function -ErrorAction SilentlyContinue)) {
    $commonPath = Join-Path $PSScriptRoot 'Encode-Batch.Common.ps1'
    if (-not [IO.File]::Exists($commonPath)) { throw "Encode-Batch.Common.ps1 not found next to this script ($commonPath)." }
    . $commonPath
}
$script:Utf8 = New-Object System.Text.UTF8Encoding $false
$script:LogPath = $(if ($LogPath) { $LogPath } else { $null })
$script:StatusFile = $(if ($StatusFile) { $StatusFile } else { $null })
$script:LogPrefix = $LogPrefix
$script:EchoLog = -not $Plumbing
if (-not $NVEncC) { $NVEncC = [IO.Path]::Combine([string]$env:APPDATA, 'NVEnc', 'NVEncC64.exe') }
# ('' = the default, so a caller can pass its settings through as they are)
if (-not $DoviTool) { $DoviTool = 'dovi_tool' }
if (-not $VsPipe) { $VsPipe = 'vspipe' }
if (-not $MkvMerge) { $MkvMerge = 'mkvmerge' }
if ($BakeCqp -le 0) { $BakeCqp = 12 }
if ($BakeThreads -eq 0) { $BakeThreads = -1 }

$wsl = @{ Distro = $WslDistro; MountRoot = $WslMountRoot; DoviConvertCmd = $DoviConvertCmd; RemountCmd = $RemountCmd }
$tmp = $TempDir
$status = $Status
if (-not $status.ContainsKey('Step')) { $status.Step = 'starting' }
function Step([string]$name) {
    $status.Step = $name; $status.Remove('Pct'); $status.Remove('Detail')
    Set-Status $status
}
$res = [ordered]@{ Status = 'Failed'; Message = ''; WorkSrc = ''; Note = ''; Baked = $false; P7Copy = ''; Output = '' }
function Set-Result([string]$st, [string]$msg) { $res.Status = $st; $res.Message = $msg }

if ($SdrReference) {
    $workDir = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Output))
} else {
    $base = $(if ($Basename) { $Basename } else { [IO.Path]::GetFileNameWithoutExtension($Source) })
    $workDir = $(if ($WorkDir) { $WorkDir } else { [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Source)) })
    $titleDir = $(if ($DecisionDir) { $DecisionDir } else { $workDir })
}

# A working file: in the work folder, or in the decision folder (Dest) where earlier runs put it;
# the work folder if neither.
function Get-WorkFile([string]$suffix) {
    $w = Join-Path $workDir "$base$suffix"
    if ([IO.File]::Exists($w)) { return $w }
    $d = Join-Path $titleDir "$base$suffix"
    if ([IO.File]::Exists($d)) { return $d }
    $w
}

# Waits until the work folder has $needGB free (re-checked every 30 s). Encode-Batch gives up on
# the title if nothing else is running that could ever free the space (it reads the status).
function Wait-WorkSpace([double]$needGB, [string]$what) {
    $logged = $false
    while (($freeW = Get-FreeGB $workDir) -lt $needGB) {
        if (-not $logged) { Write-Log "Waiting for space to ${what}: needs $needGB GB free in $workDir, $freeW GB now"; $logged = $true }
        $status.Step = "waiting for space to $what ($needGB GB needed, $freeW GB free)"; Set-Status $status
        Start-Sleep -Seconds 30
    }
    if ($logged) { Write-Log "Space available ($freeW GB free): going on to $what" }
}

# ---------------------------------------------------------------- 1080p SDR reference
function Invoke-SdrReference {
    $res.Output = $Output
    if ([IO.File]::Exists($Output)) {
        Write-Log "Reusing the 1080p SDR reference $Output"
        Set-Result 'Done' ''; return
    }
    $c = @(0, 0, 0, 0)
    if ($Crop) {
        $c = @($Crop -split '[,:]' | ForEach-Object { [int]$_ })
        if ($c.Count -ne 4) { throw "-Crop must be Left,Top,Right,Bottom (got '$Crop')." }
    }
    [void][IO.Directory]::CreateDirectory($workDir)
    Wait-WorkSpace ([Math]::Round(0.6 * (New-Object IO.FileInfo $Source).Length / 1GB + 20, 1)) 'make the 1080p SDR reference'
    Step 'making the 1080p SDR reference'
    $peak = 1000
    if ($SourcePeak -gt 0) { $peak = [int]$SourcePeak }
    $partial = "$Output.partial.mkv"
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    $a = @('--avsw', '--device', '0', '-i', $Source)
    if (($c[0] + $c[1] + $c[2] + $c[3]) -gt 0) { $a += @('--crop', ('{0},{1},{2},{3}' -f $c[0], $c[1], $c[2], $c[3])) }
    $a += @('--output-res', "${Width}x${Height}", '--vpp-resize', 'spline36',
        '--vpp-colorspace', "matrix=bt2020nc:bt709,colorprim=bt2020:bt709,transfer=smpte2084:bt709,range=limited:limited,hdr2sdr=hable,source_peak=$peak,ldr_nits=100",
        '--colormatrix', 'bt709', '--colorprim', 'bt709', '--transfer', 'bt709',
        '--video-metadata', 'clear', '--metadata', 'clear', '--chapter-copy', '-c', 'hevc', '--profile', 'main10', '--output-depth', '10',
        '--cqp', '12', '--preset', 'P7', '--avsync', 'cfr', '-o', $partial)
    Write-Log ("Making the 1080p SDR reference {0}x{1} from {2} (crop L{3} T{4} R{5} B{6}, tone-mapped from {7} nits)" -f $Width, $Height, $Source, $c[0], $c[1], $c[2], $c[3], $peak)
    $r = Invoke-Logged -Exe $NVEncC -ArgList $a -TempDir $tmp -StatusBase $status
    if ($r.ExitCode -ne 0 -or -not [IO.File]::Exists($partial)) { Set-Result 'Failed' "NVEncC failed making the 1080p SDR reference (exit $($r.ExitCode))."; return }
    Move-Item -LiteralPath $partial -Destination $Output -Force -ErrorAction Stop
    Set-Result 'Done' ''
}

# ---------------------------------------------------------------- FEL -> 8.1 by baking
# The enhancement layer is applied to the base layer (felbaker, a VapourSynth plugin) and the
# whole picture is encoded near-losslessly (NVEncC, CQP -BakeCqp) with the RPU converted to 8.1
# (dovi_tool -m 2), so it's encoded like any 8.1 title afterwards. The working files go in
# "<name> - bake" next to the copy and are deleted when it's done:
#   ffmpeg | dovi_tool demux     -> BL.hevc, EL.hevc (the RPU goes with the enhancement layer)
#   dovi_tool -m 2 extract-rpu   -> RPU_81.bin; dovi_tool info --summary: frames, MaxCLL (L6)
#   bake.vpy                     -> ffms2 reads both layers, felbaker bakes them, then 12-bit RGB
#                                   -> 10-bit 4:2:0 BT.2020 PQ (limited range) for the encoder
#   vspipe | NVEncC              -> baked.hevc, with the 8.1 RPU and HDR10 values: the source's
#                                   mastering display, MaxCLL / MaxFALL from L6 (else the source's)
#   mkvmerge (+ the copy's chapters) -> "<name> - baked.partial.mkv": checked (frame count,
#                                   Dolby Vision 8.1), then renamed "<name> - baked.mkv"
# An interrupted bake picks up after the last finished step (demux, encode).
function Find-Program([string]$name, [string]$fallback = '') {
    if ([IO.File]::Exists($name)) { return $name }
    $c = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    if ($fallback -and [IO.File]::Exists($fallback)) { return $fallback }
    throw "$name not found (pass its full path, or add its folder to PATH)."
}

function Invoke-Bake([string]$p7copy, [string]$baked) {
    $doviTool = Find-Program $DoviTool
    $vsPipe = Find-Program $VsPipe
    $mkvMerge = Find-Program $MkvMerge ([IO.Path]::Combine([string]$env:ProgramFiles, 'MKVToolNix', 'mkvmerge.exe'))
    $ffmpeg = Find-Program 'ffmpeg'
    if (-not [IO.File]::Exists($NVEncC)) { throw "NVEncC not found: $NVEncC" }
    $dir = [IO.Path]::GetDirectoryName($baked)
    $bdir = Join-Path $dir "$base - bake"
    [void][IO.Directory]::CreateDirectory($bdir)
    $bl = Join-Path $bdir 'BL.hevc'; $el = Join-Path $bdir 'EL.hevc'; $demuxDone = Join-Path $bdir 'demux.done'
    $rpu = Join-Path $bdir 'RPU_81.bin'; $vpyFile = Join-Path $bdir 'bake.vpy'
    $hevc = Join-Path $bdir 'baked.hevc'; $bakeDone = Join-Path $bdir 'bake.done'
    $partial = Join-Path $dir "$base - baked.partial.mkv"
    $info = Get-SourceInfo $p7copy
    $copyGB = (New-Object IO.FileInfo $p7copy).Length / 1GB
    $haveGB = (@(Get-ChildItem -LiteralPath $bdir -File | Measure-Object -Property Length -Sum).Sum) / 1GB
    # Layers (about the copy's video) + the baked encode (a bit more than that), then its MKV.
    Wait-WorkSpace ([Math]::Round([Math]::Max(20, 2.2 * $copyGB + 20 - $haveGB), 1)) 'bake'

    if (-not [IO.File]::Exists($demuxDone)) {
        Step 'bake: splitting the layers (ffmpeg | dovi_tool demux)'
        Remove-Item -LiteralPath $bl, $el, $rpu, $bakeDone, $hevc -Force -ErrorAction SilentlyContinue
        $line = '{0} -nostdin -hide_banner -loglevel error -i {1} -map 0:v:0 -c:v copy -bsf:v hevc_mp4toannexb -f hevc - | {2} demux - --bl-out {3} --el-out {4}' -f `
            (Format-ShellArg $ffmpeg), (Format-ShellArg $p7copy), (Format-ShellArg $doviTool), (Format-ShellArg $bl), (Format-ShellArg $el)
        $t0 = Get-Date
        $r = Invoke-ShellLines -Lines @($line) -TempDir $tmp -StatusBase $status
        if ($r.ExitCode -ne 0 -or -not [IO.File]::Exists($bl) -or -not [IO.File]::Exists($el)) { Set-Result 'Failed' "splitting the layers failed (exit $($r.ExitCode)). Files left in $bdir for review."; return }
        [IO.File]::WriteAllText($demuxDone, (Get-Date).ToString('s'))
        Write-Log ("Layers split in {0:hh\:mm\:ss}: base {1:N1} GB, enhancement {2:N1} GB" -f ((Get-Date) - $t0), ((New-Object IO.FileInfo $bl).Length / 1GB), ((New-Object IO.FileInfo $el).Length / 1GB))
    } else { Write-Log "Reusing the split layers in $bdir" }

    if (-not [IO.File]::Exists($rpu) -or (New-Object IO.FileInfo $rpu).Length -eq 0) {
        Step 'bake: 8.1 RPU (dovi_tool -m 2 extract-rpu)'
        $r = Invoke-Logged -Exe $doviTool -ArgList @('-m', '2', 'extract-rpu', $el, '-o', $rpu) -TempDir $tmp -StatusBase $status
        if ($r.ExitCode -ne 0 -or -not [IO.File]::Exists($rpu)) { Set-Result 'Failed' "dovi_tool extract-rpu failed (exit $($r.ExitCode)). Files left in $bdir for review."; return }
    }
    $r = Invoke-Logged -Exe $doviTool -ArgList @('info', '-i', $rpu, '--summary') -TempDir $tmp -StatusBase $status
    $frames = 0; $maxCll = ''
    foreach ($l in $r.Lines) {
        if ($l -match '^\s*Frames:\s*(\d+)') { $frames = [long]$Matches[1] }
        if ($l -match 'MaxCLL\D*(\d+)\D+MaxFALL\D*(\d+)' -and [int]$Matches[1] -gt 0) { $maxCll = '{0},{1}' -f $Matches[1], $Matches[2] }
    }
    if ($frames -le 0) { Set-Result 'Failed' "dovi_tool info found no frames in the RPU ($rpu). Files left in $bdir for review."; return }
    if (-not $maxCll -and $info.MaxCll) { $maxCll = $info.MaxCll; Write-Log "No MaxCLL in the RPU's L6: using the source's ($maxCll)" }
    $fps = @([string]$info.Fps -split '/'); if ($fps.Count -ne 2) { $fps = @('24000', '1001') }

    if (-not [IO.File]::Exists($bakeDone)) {
        Remove-Item -LiteralPath $hevc -Force -ErrorAction SilentlyContinue
        $py = { param([string]$p) '"' + $p.Replace('\', '\\').Replace('"', '\"') + '"' }
        $vpy = @"
import vapoursynth as vs
core = vs.core
# felbaker and ffms2 come from VapourSynth's plugin autoloading.
# (the base layer's 2160p decode is the bottleneck: ffms2 reads in order, so its decoder
# threads set the pace; -1 = every logical CPU)
bl = core.ffms2.Source($(& $py $bl), threads=$BakeThreads)
el = core.ffms2.Source($(& $py $el), threads=$BakeThreads)
if bl.num_frames != el.num_frames or bl.num_frames != $($frames):
    raise vs.Error(f'frame counts differ: base layer {bl.num_frames}, enhancement layer {el.num_frames}, RPU $($frames)')
# felbaker's recommended path: VapourSynth's resizer for the enhancement layer and the chroma.
el = core.resize.Spline16(el, width=bl.width, height=bl.height, format=vs.YUV420P10)
baked = core.fel.Bake(bl, el, no_resample=1)
baked = core.resize.Spline16(baked, format=vs.YUV444P12)
rgb = core.fel.ToRGB(baked)
# 12-bit PQ RGB (full range) -> 10-bit 4:2:0 BT.2020 PQ, limited range, for the encoder.
out = core.resize.Spline36(rgb, format=vs.YUV420P10, matrix_s='2020ncl', range_s='limited', chromaloc_s='top_left', dither_type='error_diffusion')
out = core.std.AssumeFPS(out, fpsnum=$($fps[0]), fpsden=$($fps[1]))
out.set_output()
"@
        [IO.File]::WriteAllText($vpyFile, $vpy, $script:Utf8)
        # vspipe runs from its own folder (a portable VapourSynth's vspipe.bat may use paths
        # relative to it). First a check that the script loads (plugins found, layers readable,
        # frame counts match), with VapourSynth's own error if not; ffms2 indexes the layers here.
        $vsDir = [IO.Path]::GetDirectoryName($vsPipe)
        $vsCall = $(if ((Test-IsWindows) -and $vsPipe -match '\.(bat|cmd)$') { 'call ' } else { '' }) + (Format-ShellArg $vsPipe)
        Step 'bake: indexing the layers (vspipe --info)'
        $r = Invoke-ShellLines -Lines @("$vsCall --info $(Format-ShellArg $vpyFile)") -WorkingDir $vsDir -TempDir $tmp -StatusBase $status
        if ($r.ExitCode -ne 0) { Set-Result 'Failed' "the bake script didn't load in VapourSynth (exit $($r.ExitCode); its error is in the log above). Files left in $bdir for review."; return }

        $enc = @('--y4m', '-i', '-', '-c', 'hevc', '--profile', 'main10', '--output-depth', '10', '--cqp', "$BakeCqp", '--preset', 'P7', '--multipass', '2pass-full',
                 '--colormatrix', 'bt2020nc', '--colorprim', 'bt2020', '--transfer', 'smpte2084', '--colorrange', 'limited', '--chromaloc', '2',
                 '--dolby-vision-rpu', $rpu, '--dolby-vision-profile', '8.1')
        if ($info.MasterDisplay) { $enc += @('--master-display', $info.MasterDisplay) } else { Write-Log 'WARNING: the source has no mastering display metadata; none written.' }
        if ($maxCll) { $enc += @('--max-cll', $maxCll) }
        $enc += @('-o', $hevc)
        $line = '{0} -c y4m {1} - | {2} {3}' -f (Format-ShellArg $vsPipe), (Format-ShellArg $vpyFile), (Format-ShellArg $NVEncC), (($enc | ForEach-Object { Format-ShellArg $_ }) -join ' ')
        Step 'bake: baking and encoding (vspipe | NVEncC)'
        Write-Log ("Baking {0} frames into 8.1 (decoder threads {4}, CQP {1}; HDR10: master-display {2}, max-cll {3})" -f $frames, $BakeCqp, $(if ($info.MasterDisplay) { $info.MasterDisplay } else { 'none' }), $(if ($maxCll) { $maxCll } else { 'none' }), $(if ($BakeThreads -lt 0) { 'all' } else { $BakeThreads }))
        $t0 = Get-Date
        $r = Invoke-ShellLines -Lines @($line) -WorkingDir $vsDir -TempDir $tmp -StatusBase $status -ProgressFrames $frames
        $secs = [Math]::Max(1.0, ((Get-Date) - $t0).TotalSeconds)
        $encoded = 0
        foreach ($l in $r.Lines) { if ($l -match '^\s*encoded (\d+) frames') { $encoded = [long]$Matches[1] } }
        if ($r.ExitCode -ne 0 -or -not [IO.File]::Exists($hevc)) { Set-Result 'Failed' "vspipe | NVEncC failed (exit $($r.ExitCode)). Files left in $bdir for review."; return }
        if ($encoded -ne $frames) { Set-Result 'Failed' "the bake encoded $encoded frames, but the RPU has $frames. Files left in $bdir for review."; return }
        Write-Log ("Baked {0} frames in {1:hh\:mm\:ss} ({2:N1} fps): {3:N1} GB" -f $encoded, [TimeSpan]::FromSeconds([int]$secs), ($encoded / $secs), ((New-Object IO.FileInfo $hevc).Length / 1GB))
        [IO.File]::WriteAllText($bakeDone, (Get-Date).ToString('s'))
    } else { Write-Log "Reusing the baked encode $hevc" }
    # The layers aren't needed any more: room for the MKV.
    Get-ChildItem -LiteralPath $bdir -File | Where-Object { $_.Name -match '^(BL|EL)\.hevc' } | Remove-Item -Force -ErrorAction SilentlyContinue

    Step 'bake: MKV (mkvmerge)'
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    # (the copy adds only its chapters)
    $r = Invoke-Logged -Exe $mkvMerge -ArgList @('-q', '--output', $partial, '--default-duration', "0:$($fps[0])/$($fps[1])p", $hevc,
        '-A', '-D', '-S', '-B', '-M', '-T', '--no-global-tags', $p7copy) -TempDir $tmp -StatusBase $status
    if ($r.ExitCode -gt 1 -or -not [IO.File]::Exists($partial)) { Set-Result 'Failed' "mkvmerge failed (exit $($r.ExitCode)). Files left in $bdir for review."; return }
    $chk = Get-SourceInfo $partial
    if ($chk.Dv -ne 'P8.1') { Set-Result 'Failed' "the baked file reports '$($chk.Dv)', not P8.1 ($($chk.DvDetail)). Files left for review: $partial"; return }
    Move-Item -LiteralPath $partial -Destination $baked -Force -ErrorAction Stop
    Remove-Item -LiteralPath $bdir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Baked into Dolby Vision 8.1: $baked"
    $script:BakeOk = $true
}

# ---------------------------------------------------------------- profile 7 -> 8.1, or keep
# copy to the work folder -> inspect the copy (dovi_convert, only to tell MEL from FEL: its
# Simple / Complex call isn't reliable) -> decide:
#   MEL                       -> convert to 8.1 (dovi_convert: drops the empty enhancement layer)
#   SIMPLE / COMPLEX FEL      -> bake to 8.1 (Invoke-Bake: the enhancement layer is applied)
#   NO L1 METADATA (or other) -> keep as profile 7 (Status KeepP7): Encode-Batch finishes the copy
#                                as "<name> - 2160p.mkv" (audio only) and adds a 1080p SDR title
# The decision is saved as "<name>.dovi.json" in -DecisionDir. Once any title there is kept as
# profile 7, its later profile 7 titles follow (a season stays one format); ones already
# finished as 8.1 are left alone. When the folder's first title was baked (an FEL), the later
# ones are baked too without being inspected.
function Invoke-Convert {
    [void][IO.Directory]::CreateDirectory($workDir)
    $p81 = Get-WorkFile ' - p8.1.mkv'
    $baked = Get-WorkFile ' - baked.mkv'
    $p7copy = Get-WorkFile ' - p7 source.mkv'
    if (-not [IO.File]::Exists($p7copy)) { $p7copy = Join-Path $workDir "$base - p7 source.mkv" }
    $decFile = Join-Path $titleDir "$base.dovi.json"
    $saveDecision = { param([string]$decision, [string]$note, $basePeak, $felPeak, [string]$verdict)
        $o = [ordered]@{ Decision = $decision; Note = $note; BasePeak = $basePeak; FelPeak = $felPeak; Verdict = $verdict; Time = (Get-Date).ToString('s') }
        [IO.File]::WriteAllText($decFile, ($o | ConvertTo-Json -Compress), $script:Utf8) }
    $readJson = { param($f) try { [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { $null } }
    # An older version's "unsafe" flag: re-checked under the current rules.
    $legacy = Join-Path $titleDir "$base - p7 source.mkv.review.txt"
    if ([IO.File]::Exists($legacy)) {
        Write-Log "Removing the unsafe flag from an earlier version ($(@(Get-Content -LiteralPath $legacy -TotalCount 1)[0])): re-checking with the current rules"
        Remove-Item -LiteralPath $legacy -Force -ErrorAction SilentlyContinue
    }
    $own = if ([IO.File]::Exists($decFile)) { & $readJson $decFile } else { $null }
    $keepWhy = ''
    $followBake = ''
    if ([IO.Directory]::Exists($titleDir)) {
        $others = @([IO.Directory]::GetFiles($titleDir, '*.dovi.json') | Where-Object { $_ -ne $decFile })
        foreach ($f in $others) {
            $o = & $readJson $f
            if ($o -and $o.Decision -eq 'keep-p7') {
                $keepWhy = "the rest of the season follows $([IO.Path]::GetFileName($f) -replace '\.dovi\.json$', ''): $($o.Note)"
                break
            }
        }
        # The folder's FIRST profile 7 title (in name order, as Encode-Batch takes them) was an
        # FEL: the rest are baked without an inspect (it's slow; a season is all FEL or all MEL in
        # practice, and baking an MEL loses nothing). Only the first one counts: an MEL first, or
        # an FEL later on, changes nothing. Kept as profile 7 (above) still wins.
        $names = @(@($others | ForEach-Object { [IO.Path]::GetFileName($_) -replace '\.dovi\.json$', '' }) + $base | Sort-Object)
        if ($names.Count -gt 1 -and $names[0] -ne $base) {
            $o = & $readJson (Join-Path $titleDir "$($names[0]).dovi.json")
            if ($o -and $o.Decision -eq 'bake') {
                $followBake = "FEL baked into 8.1 (the season follows its first title, $($names[0]): $(if ($o.Verdict) { $o.Verdict } else { 'FEL' }); not inspected)"
            }
        }
    }
    if (-not $keepWhy -and $own -and $own.Decision -eq 'keep-p7') { $keepWhy = [string]$own.Note }
    $doviNote = ''
    $isBaked = $false
    $out = $p81

    if (-not $keepWhy -and [IO.File]::Exists($baked)) {
        Write-Log "Dolby Vision 7: reusing the earlier baked copy $baked"
        if ($own -and $own.Note) { $doviNote = [string]$own.Note }
        $isBaked = $true; $out = $baked
    } elseif (-not $keepWhy -and [IO.File]::Exists($p81)) {
        Write-Log "Dolby Vision 7: reusing previously converted copy $p81"
        if ($own -and $own.Note) { $doviNote = [string]$own.Note }
    } elseif (-not $keepWhy) {
        $dirW = ConvertTo-WslPath $workDir $wsl.MountRoot
        # No dovi_convert scan on the source first: every profile 7 title is copied and
        # inspected whatever scan would say (it's converted, baked or kept as profile 7).
        if (-not [IO.File]::Exists($p7copy)) {
            Step 'copying p7 source'
            $srcLen = (New-Object IO.FileInfo $Source).Length
            Write-Log ("Copying source to {0} ({1:N1} GB, {2} GB free there)" -f $p7copy, ($srcLen / 1GB), (Get-FreeGB $workDir))
            $c0 = Get-Date
            Copy-FileWithProgress -Src $Source -Dst $p7copy -StatusBase $status
            $secs = [Math]::Max([double]1, ((Get-Date) - $c0).TotalSeconds)
            Write-Log ("Copied in {0} ({1:N0} MB/s)" -f [TimeSpan]::FromSeconds([int]$secs), ($srcLen / 1MB / $secs))
        } else {
            Write-Log "Reusing existing local copy $p7copy"
        }
        $copyW = ConvertTo-WslPath $p7copy $wsl.MountRoot

        $mode = ''
        if ($own -and $own.Decision -eq 'bake') {
            # (an interrupted bake: inspect already decided)
            $mode = 'bake'; $doviNote = [string]$own.Note
            Write-Log "Dolby Vision 7: baking, as decided before ($doviNote)"
        } elseif ($followBake) {
            $mode = 'bake'; $doviNote = $followBake
            Write-Log "Dolby Vision 7: $followBake"
            & $saveDecision 'bake' $doviNote 0 0 ''
        } else {
            Step 'dovi_convert inspect'
            $r = Invoke-Wsl -Wsl $wsl -TempDir $tmp -NeedPaths @($copyW) -StatusBase $status `
                -Body ("cd {0} && {1} inspect {2}" -f (ConvertTo-BashQuoted $dirW), $wsl.DoviConvertCmd, (ConvertTo-BashQuoted $copyW))
            $verdict = $null; $basePeak = 0; $felPeak = 0
            foreach ($l in $r.Lines) {
                if ($l -match '^\s*VERDICT:\s*(.+?)\s*$') { $verdict = $Matches[1] }
                elseif ($l -match '^\s*Base Layer Peak[^:]*:\s*(\d+)') { $basePeak = [int]$Matches[1] }
                elseif ($l -match '^\s*FEL Peak Brightness:\s*(\d+)') { $felPeak = [int]$Matches[1] }
            }
            # dovi_convert's verdicts: "SIMPLE / SAFE", "MEL (Minimal Enhancement Layer)",
            # "COMPLEX FEL (Active Brightness Expansion)", "NO L1 METADATA".
            if ($r.ExitCode -ne 0 -or -not $verdict) {
                $last = @($r.Lines | Where-Object { $_.Trim() } | Select-Object -Last 1)
                Set-Result 'Failed' ("dovi_convert inspect failed (exit {0}){1}. Local copy kept: {2}" -f $r.ExitCode, $(if ($last.Count) { ": $($last[0].Trim())" }), $p7copy)
                return
            }
            $peaks = if ($basePeak -gt 0 -and $felPeak -gt 0) { "FEL peak $felPeak nits, base layer $basePeak nits" } else { 'peaks not reported' }
            Write-Log "dovi_convert inspect: VERDICT: $verdict ($peaks)"
            if ($verdict -match '^MEL\b') {
                $mode = 'convert'
                & $saveDecision 'convert' '' $basePeak $felPeak $verdict
            } elseif ($verdict -match '^(SIMPLE|COMPLEX)\b') {
                $mode = 'bake'
                $doviNote = "FEL baked into 8.1 (inspect: $verdict; $peaks)"
                & $saveDecision 'bake' $doviNote $basePeak $felPeak $verdict
            } else {
                $keepWhy = "inspect VERDICT: $verdict ($peaks)"
                & $saveDecision 'keep-p7' $keepWhy $basePeak $felPeak $verdict
            }
        }

        if ($mode -eq 'convert') {
            Wait-WorkSpace ([Math]::Round(2 * (New-Object IO.FileInfo $p7copy).Length / 1GB + 20, 1)) 'convert'
            Step 'dovi_convert convert'
            # --yes: no prompts; --include-simple: --yes alone skips Simple FEL; --force: convert's
            # own quick check may disagree with inspect (above), which already decided;
            # --delete: removes the renamed original (.bak.dovi_convert) once converted.
            $before = @(Get-ChildItem -LiteralPath $workDir -File | ForEach-Object { $_.Name })
            $r = Invoke-Wsl -Wsl $wsl -TempDir $tmp -NeedPaths @($copyW) -StatusBase $status `
                -Body ("cd {0} && {1} convert --yes --include-simple --force --delete {2}" -f (ConvertTo-BashQuoted $dirW), $wsl.DoviConvertCmd, (ConvertTo-BashQuoted $copyW))
            $after = @(Get-ChildItem -LiteralPath $workDir -File | ForEach-Object { $_.Name })
            $new = @($after | Where-Object { $before -notcontains $_ })
            if ($new.Count) { Write-Log "New files after convert: $($new -join ', ')" }
            if ($r.ExitCode -ne 0) { Set-Result 'Failed' "dovi_convert convert failed (exit $($r.ExitCode)). Files left in place for review."; return }
            $chk = Get-SourceInfo $p7copy
            if ($chk.Dv -ne 'P8.1') { Set-Result 'Failed' "after conversion the copy reports '$($chk.Dv)', not P8.1 ($($chk.DvDetail)). Files left in place for review."; return }
            $p81 = Join-Path ([IO.Path]::GetDirectoryName($p7copy)) "$base - p8.1.mkv"
            Move-Item -LiteralPath $p7copy -Destination $p81 -Force -ErrorAction Stop
            Write-Log "Converted to Dolby Vision 8.1: $p81"
            $out = $p81
        } elseif ($mode -eq 'bake') {
            # The copy stays: it's the title's audio and subtitle source (the baked file has video only).
            $baked = Join-Path ([IO.Path]::GetDirectoryName($p7copy)) "$base - baked.mkv"
            $script:BakeOk = $false
            [void](Invoke-Bake $p7copy $baked)
            if (-not $script:BakeOk) { return }
            $isBaked = $true; $out = $baked
        }
    }

    if ($keepWhy) {
        # Profile 7 route: the untouched copy is finished as "<name> - 2160p.mkv" (audio only),
        # and a 1080p SDR title is made from it. An 8.1 copy from before is no use now.
        if (-not ($own -and $own.Decision -eq 'keep-p7')) { & $saveDecision 'keep-p7' $keepWhy 0 0 '' }
        Write-Log "Dolby Vision 7: keeping as profile 7 ($keepWhy)"
        foreach ($old in $p81, $baked) {
            if ([IO.File]::Exists($old)) {
                Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
                Write-Log "Deleted the earlier 8.1 copy $old (the season stays profile 7)"
            }
        }
        if (-not [IO.File]::Exists($p7copy)) {
            Step 'copying p7 source'
            Write-Log "Copying source to $p7copy ($(Get-FreeGB $workDir) GB free there)"
            Copy-FileWithProgress -Src $Source -Dst $p7copy -StatusBase $status
        }
        Set-Result 'KeepP7' $keepWhy
        $res.P7Copy = $p7copy
        return
    }
    Set-Result 'Converted' ''
    $res.WorkSrc = $out
    $res.Note = $doviNote
    $res.Baked = $isBaked
    if ($isBaked) { $res.P7Copy = $p7copy }
}

try {
    if ($SdrReference) { Invoke-SdrReference } else { Invoke-Convert }
} catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-LogRaw ($_.ScriptStackTrace)
    Set-Result 'Failed' $_.Exception.Message
}

if ($Plumbing) {
    [pscustomobject]$res | ConvertTo-Json -Compress
} else {
    $what = switch ($res.Status) {
        'Converted' { "$(if ($res.Baked) { 'baked' } else { 'converted' }) to Dolby Vision 8.1: $($res.WorkSrc)$(if ($res.Note) { " ($($res.Note))" })" }
        'KeepP7'    { "kept as profile 7 ($($res.Message)): $($res.P7Copy)" }
        'Done'      { "1080p SDR reference: $($res.Output)" }
        default     { "FAILED: $($res.Message)" }
    }
    Write-Host $what -ForegroundColor $(if ($res.Status -eq 'Failed') { 'Red' } else { 'Green' })
    if ($res.Status -eq 'Failed') { exit 1 }
}
