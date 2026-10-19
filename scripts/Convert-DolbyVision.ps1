<#
.SYNOPSIS
    Dolby Vision profile 7 handling for Encode-Batch: decides whether a profile 7 title is
    converted to profile 8.1 or kept as profile 7, and makes the 1080p SDR reference for a title
    kept as profile 7. Built for Windows PowerShell 5.1.

.DESCRIPTION
    Convert (the default):
      copy the source to -WorkDir ("<name> - p7 source.mkv") -> dovi_convert inspect on the copy
      (in WSL; it measures the brightness the enhancement layer adds) -> decide:
        - SIMPLE / SAFE or MEL: convert to 8.1 (convert --yes --include-simple --force --delete),
          then check that it's 8.1 -> "<name> - p8.1.mkv" (Status Converted).
        - COMPLEX FEL with the FEL peak at most -OvershootNits above the base layer's peak:
          converted to 8.1 anyway; the highlights above the base layer's peak are clipped
          (Status Converted, with a Note).
        - Anything else (Complex FEL beyond that, NO L1 METADATA): kept as profile 7; the copy is
          left untouched (Status KeepP7, P7Copy).
      The decision is saved in "<name>.dovi.json" in -DecisionDir. A season stays one format: when
      another title's .dovi.json in -DecisionDir says keep-p7, this one is kept as profile 7 too,
      without inspecting it. A converted copy from an earlier run is reused (and a kept title's
      old conversion is deleted). Before converting it waits until -WorkDir has room for it (about
      twice the copy's size), re-checking every 30 s.

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
.PARAMETER OvershootNits
    Convert: a Complex FEL title is still converted when its FEL peak is at most this many nits
    above the base layer's peak. Default: 100.
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
    -SdrReference: path to NVEncC64.exe. Default: %APPDATA%\NVEnc\NVEncC64.exe.
.PARAMETER WslDistro
    WSL distribution for dovi_convert. Default: the default one.
.PARAMETER WslMountRoot
    Where Windows drives are mounted in WSL. Default: /mnt.
.PARAMETER DoviConvertCmd
    dovi_convert's command in WSL (on PATH for a login shell, or a full path). Default: dovi_convert.
.PARAMETER RemountCmd
    Run once in WSL when a file isn't visible there (e.g. a dropped NAS mount). Default: remount.
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
      WorkSrc   Converted: the 8.1 file to encode from
      Note      Converted: a note for the reports (e.g. highlights clipped), or ""
      P7Copy    KeepP7: the untouched profile 7 copy
      Output    -SdrReference: the reference

.EXAMPLE
    .\Convert-DolbyVision.ps1 -Source 'S:\Sources\Movies\M\M.mkv' -WorkDir 'D:\Work\M'
.EXAMPLE
    .\Convert-DolbyVision.ps1 -SdrReference -Source 'D:\Work\M\M - p7 source.mkv' -Output 'D:\Work\M\M - 1080p ref.mkv' -Crop '0,276,0,276' -Width 1920 -Height 804 -SourcePeak 1000
#>
[CmdletBinding(DefaultParameterSetName = 'Convert')]
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(ParameterSetName = 'Convert')][string]$WorkDir = '',
    [Parameter(ParameterSetName = 'Convert')][string]$DecisionDir = '',
    [Parameter(ParameterSetName = 'Convert')][string]$Basename = '',
    [Parameter(ParameterSetName = 'Convert')][int]$OvershootNits = 100,
    [Parameter(ParameterSetName = 'SdrReference', Mandatory)][switch]$SdrReference,
    [Parameter(ParameterSetName = 'SdrReference', Mandatory)][string]$Output,
    [Parameter(ParameterSetName = 'SdrReference')][string]$Crop = '',
    [Parameter(ParameterSetName = 'SdrReference', Mandatory)][int]$Width,
    [Parameter(ParameterSetName = 'SdrReference', Mandatory)][int]$Height,
    [Parameter(ParameterSetName = 'SdrReference')][int]$SourcePeak = 1000,
    [Parameter(ParameterSetName = 'SdrReference')][string]$NVEncC = '',
    [string]$WslDistro = '',
    [string]$WslMountRoot = '/mnt',
    [string]$DoviConvertCmd = 'dovi_convert',
    [string]$RemountCmd = 'remount',
    [string]$TempDir = [IO.Path]::GetTempPath(),
    [string]$LogPath = '',
    [string]$LogPrefix = '',
    [string]$StatusFile = '',
    [hashtable]$Status = @{},
    [switch]$Plumbing
)

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

$wsl = @{ Distro = $WslDistro; MountRoot = $WslMountRoot; DoviConvertCmd = $DoviConvertCmd; RemountCmd = $RemountCmd }
$tmp = $TempDir
$status = $Status
if (-not $status.ContainsKey('Step')) { $status.Step = 'starting' }
function Step([string]$name) {
    $status.Step = $name; $status.Remove('Pct'); $status.Remove('Detail')
    Set-Status $status
}
$res = [ordered]@{ Status = 'Failed'; Message = ''; WorkSrc = ''; Note = ''; P7Copy = ''; Output = '' }
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

# ---------------------------------------------------------------- profile 7 -> 8.1, or keep
# copy to the work folder -> inspect the copy -> decide:
#   SIMPLE / SAFE or MEL                  -> convert to 8.1
#   COMPLEX FEL within -OvershootNits     -> convert to 8.1 anyway (highlights clipped; noted)
#   COMPLEX FEL beyond it, or NO L1       -> keep as profile 7 (Status KeepP7): Encode-Batch
#                                            finishes the copy as "<name> - 2160p.mkv" (audio
#                                            only) and adds a 1080p SDR title for it
# The decision is saved as "<name>.dovi.json" in -DecisionDir. Once any title there is kept as
# profile 7, its later profile 7 titles follow (a season stays one format); ones already
# finished as 8.1 are left alone.
function Invoke-Convert {
    [void][IO.Directory]::CreateDirectory($workDir)
    $p81 = Get-WorkFile ' - p8.1.mkv'
    $p7copy = Get-WorkFile ' - p7 source.mkv'
    if (-not [IO.File]::Exists($p7copy)) { $p7copy = Join-Path $workDir "$base - p7 source.mkv" }
    $decFile = Join-Path $titleDir "$base.dovi.json"
    $saveDecision = { param([string]$decision, [string]$note, $basePeak, $felPeak, [string]$verdict)
        $o = [ordered]@{ Decision = $decision; Note = $note; BasePeak = $basePeak; FelPeak = $felPeak; Verdict = $verdict
                         Limit = $OvershootNits; Time = (Get-Date).ToString('s') }
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
    if ([IO.Directory]::Exists($titleDir)) {
        foreach ($f in @([IO.Directory]::GetFiles($titleDir, '*.dovi.json') | Where-Object { $_ -ne $decFile })) {
            $o = & $readJson $f
            if ($o -and $o.Decision -eq 'keep-p7') {
                $keepWhy = "the rest of the season follows $([IO.Path]::GetFileName($f) -replace '\.dovi\.json$', ''): $($o.Note)"
                break
            }
        }
    }
    if (-not $keepWhy -and $own -and $own.Decision -eq 'keep-p7') { $keepWhy = [string]$own.Note }
    $doviNote = ''

    if (-not $keepWhy -and [IO.File]::Exists($p81)) {
        Write-Log "Dolby Vision 7: reusing previously converted copy $p81"
        if ($own -and $own.Note) { $doviNote = [string]$own.Note }
    } elseif (-not $keepWhy) {
        $dirW = ConvertTo-WslPath $workDir $wsl.MountRoot
        # No dovi_convert scan on the source first: every profile 7 title is copied and
        # inspected whatever scan would say (it's converted or kept as profile 7 either way).
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
        if ($verdict -match '^(SIMPLE / SAFE|MEL\b)') {
            & $saveDecision 'convert' '' $basePeak $felPeak $verdict
        } elseif ($verdict -match '^COMPLEX' -and $basePeak -gt 0 -and $felPeak -gt 0 -and ($felPeak - $basePeak) -le $OvershootNits) {
            $doviNote = "converted to 8.1 although inspect found Complex FEL: FEL peak $felPeak nits vs base layer $basePeak nits (+$($felPeak - $basePeak), within +$($OvershootNits)); highlights above $basePeak nits are clipped"
            Write-Log "Dolby Vision 7: $doviNote"
            & $saveDecision 'convert-overshoot' $doviNote $basePeak $felPeak $verdict
        } else {
            $keepWhy = if ($verdict -match '^COMPLEX' -and $basePeak -gt 0 -and $felPeak -gt 0) {
                "Complex FEL: FEL peak $felPeak nits vs base layer $basePeak nits (+$($felPeak - $basePeak), over +$($OvershootNits))"
            } else { "inspect VERDICT: $verdict ($peaks)" }
            & $saveDecision 'keep-p7' $keepWhy $basePeak $felPeak $verdict
        }

        if (-not $keepWhy) {
            Wait-WorkSpace ([Math]::Round(2 * (New-Object IO.FileInfo $p7copy).Length / 1GB + 20, 1)) 'convert'
            Step 'dovi_convert convert'
            # --yes: no prompts; --include-simple: --yes alone skips Simple FEL; --force: convert's own
            # quick check would refuse Complex FEL, but inspect (above) already decided;
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
        }
    }

    if ($keepWhy) {
        # Profile 7 route: the untouched copy is finished as "<name> - 2160p.mkv" (audio only),
        # and a 1080p SDR title is made from it. A converted copy from before is no use now.
        if (-not ($own -and $own.Decision -eq 'keep-p7')) { & $saveDecision 'keep-p7' $keepWhy 0 0 '' }
        Write-Log "Dolby Vision 7: keeping as profile 7 ($keepWhy)"
        if ([IO.File]::Exists($p81)) {
            Remove-Item -LiteralPath $p81 -Force -ErrorAction SilentlyContinue
            Write-Log "Deleted the earlier 8.1 conversion $p81 (the season stays profile 7)"
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
    $res.WorkSrc = $p81
    $res.Note = $doviNote
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
        'Converted' { "converted to Dolby Vision 8.1: $($res.WorkSrc)$(if ($res.Note) { " ($($res.Note))" })" }
        'KeepP7'    { "kept as profile 7 ($($res.Message)): $($res.P7Copy)" }
        'Done'      { "1080p SDR reference: $($res.Output)" }
        default     { "FAILED: $($res.Message)" }
    }
    Write-Host $what -ForegroundColor $(if ($res.Status -eq 'Failed') { 'Red' } else { 'Green' })
    if ($res.Status -eq 'Failed') { exit 1 }
}
