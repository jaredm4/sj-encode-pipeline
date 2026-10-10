<#
.SYNOPSIS
    Encodes every Blu-ray/UHD source MKV under -Source with NVEncC, scores each encode against its source
    with compare_encode (VMAF, via WSL), and searches a ladder of quality settings for the encode
    that meets your quality bar at a size closest to -TargetPct of the source. Built for Windows
    PowerShell 5.1.

.DESCRIPTION
    For each .mkv found (recursively) under -Source, mirrored into -Dest:

      Dest\<same sub-folders>\
          <name>.mkv                   the finished encode, with audio (ladder mode, see below)
          <name>.mks.originals         subtitle backup from Add-BluRayAudio
          <name>.encode.log            everything that happened to this title, every run
          <name>.audio.log             Add-BluRayAudio's own log
          <name>.results.json          machine-readable variant results
          <name>.final.json            what was kept, and the finishing progress
          <name> - p8.1.mkv            only for Dolby Vision profile 7 sources (converted copy, kept)
          <variant name>\<name>.mkv    one folder per variant while a title is in progress
          <variant name>\<name>.vmaf.txt  (and kept afterwards in fixed mode / -KeepVariants)

      Dest\_encode-batch_<timestamp>.log / .md / .csv   run log, summary table, summary data

    Two modes:
      Ladder (default): -Ladder is a list of rungs, weakest/smallest first (cqp28 aq8 ... cqp20
        aq8). Each title tries rungs one at a time, steering by the VMAF results so far (below),
        so most titles only need one to three encodes.
      Fixed: pass -Variants and every title gets exactly those encodes, no search.

    Ladder search, per title:
      - Start: the first title in a source folder starts with two rungs (one either side of the
        middle) so both encoder slots work on it. The other titles in that folder wait for its
        final pick, then all start from that one rung, in parallel. While they wait the slots take
        titles from other folders (e.g. other seasons when -Source is a show), or idle. If the first
        title finds no passing rung, the next one searches from scratch. Folders don't share picks.
      - Then, once every rung in flight is scored:
          some pass: smallest passer still above -TargetPct -> try the next smaller rung;
                     biggest passer below -TargetPct        -> try the next bigger rung;
                     otherwise finished.
          none pass: passes the bar but over -MaxPct -> try smaller; fails the bar -> try bigger.
        A rung is never repeated, so the search always ends, at worst at an end of the ladder.
      - Folder memory: when the next step is a rung right next to the folder's pick, and the title
        that set the pick already tried it (and lost), it's skipped if this title's result at the
        pick is about the same (-SimilarPct, -SimilarVmaf). E.g. E01: cqp22 17%, cqp20 25% -> picks
        cqp22; E02 at cqp22 17.5% doesn't re-try cqp20. The skip is noted in the title's log.

    Pass and suggestion (sizes are each variant's video stream as % of the source's video stream,
    measured by compare_encode, so audio tracks don't count on either side):
      - Pass = mean >= -MinMean, p1 >= -MinP1, min >= -MinMin, size <= -MaxPct (hard cap), and no
        VMAF alignment warning.
      - Suggested = the passing variant closest to -TargetPct, either direction (ties: smaller).
      - No passing variant = keep the original.
      - A note is added when the ladder itself was the limit: the pick is under -TargetPct at the
        strongest rung (add a lower-CQP rung) or over it at the weakest (add a higher-CQP rung).
        In fixed mode, a pick under -TargetPct gets the note "try a lower CQP / more AQ".

    Finishing a title (ladder mode, when a variant is suggested), one title at a time:
      1. Add-BluRayAudio -Source <source MKV> -Dest <suggested variant> -Replace adds the audio
         (and writes its subtitle backup, <name>.mks.originals). Its output goes into the
         title's .encode.log, and its own log file is moved from the Desktop to
         <name>.audio.log next to it.
      2. The suggested MKV (and subtitle backup) move up to Dest\<same sub-folders>\<name>.mkv.
      3. This title's other variants (and their VMAF files) are deleted; empty variant folders
         are removed.
      Progress is saved in <name>.final.json, so an interrupted finish resumes where it was,
      and a finished one is skipped on later runs (its pick still guides its folder).
      If the audio step fails, nothing is moved or deleted. Titles with no passing variant
      keep all their variants for review. -NoAudio / -KeepVariants skip steps 1 / 3.
      Fixed mode (-Variants) never does any of this.

    Work is a queue, not one thread per title:
      - Prep (one title at a time, no encoder slot used): probe with ffprobe (and mediainfo when
        installed); skip VC-1 (-SkipVC1) and Dolby Vision other than 7 / 8.1. For profile 7:
        dovi_convert scan (on the source) -> copy to Dest -> inspect (local copy, only for CONVERT*)
        -> convert --backup --delete -> verify it's now 8.1; anything not clearly safe is skipped and
        logged, the local copy kept for review. Then CropDetect -Plumbing for the Suggested crop.
      - Encodes (up to -Threads at once, GPU): each free slot takes the next encode of the oldest
        title that has one ready, so an earlier title's next rung always goes first. A title waiting on VMAF to choose its next rung doesn't hold a
        slot; the slot moves on to another title. Up to -Threads + 2 searches from scratch are in
        progress at once; titles starting from their folder's pick aren't limited and are prepped
        one ahead, as is one title per folder that's waiting for its folder's pick.
      - VMAF (up to -VmafThreads at once, CPU): each finished encode is scored with
        compare_encode --full (exact crop) while the encoder slot moves on.

    Two variants of one title share its .encode.log; every line is prefixed with the variant name.

    Re-running is safe: finished variants (and their VMAF results) are reused, half-written encodes
    are redone, and a title whose search (or fixed variant list) is finished is skipped. In ladder
    mode, variant folders that aren't rungs (e.g. from an older fixed run) are left alone.

    Disk space (Dest's drive) is checked before each title starts: below -MinFreeGB no new titles
    are started (running ones finish); a profile 7 title needs -MinFreeDoviGB, otherwise it's skipped.

.PARAMETER Ladder
    Rungs for the search, weakest/smallest first. Same keys as -Variants.

.PARAMETER Variants
    Fixed mode: one hashtable per encode, every title. Keys:
      Cqp        int   -> --cqp N
      Aq         int   -> --aq --aq-strength N   (omit or 0 -> --no-aq)
      AqTemporal bool  -> --aq-temporal
      Extra      string or string[] of extra NVEncC args (split on spaces if a string)
      Name       folder name (default built from the above, e.g. "cqp22 aq4")

.EXAMPLE
    .\Encode-Batch.ps1 -Source "S:\Sources\Shows\Show (2004) [tmdbid-12345]" -Dest "D:\Encodes"

.EXAMPLE
    .\Encode-Batch.ps1 -Source S:\Sources\Movies -Dest D:\Encodes `
        -Ladder @{Cqp=30;Aq=8}, @{Cqp=28;Aq=8}, @{Cqp=26;Aq=8}, @{Cqp=24;Aq=8}, @{Cqp=22;Aq=8}

.EXAMPLE
    .\Encode-Batch.ps1 -Source S:\Sources\Movies -Dest D:\Encodes -Threads 1 `
        -Variants @{Cqp=22;Aq=4}, @{Cqp=24;Aq=8}, @{Cqp=26;Aq=8}

.EXAMPLE
    .\Encode-Batch.ps1 -Source S:\Sources\Movies -Dest D:\Encodes -SkipVC1:$false
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Dest,

    # Ladder mode (default): rungs, weakest/smallest first.
    [hashtable[]]$Ladder = @(
        @{ Cqp = 28; Aq = 8 },
        @{ Cqp = 26; Aq = 8 },
        @{ Cqp = 24; Aq = 8 },
        @{ Cqp = 22; Aq = 8 },
        @{ Cqp = 20; Aq = 8 }
    ),

    # Fixed mode: give this to encode exactly these variants for every title (no search).
    [hashtable[]]$Variants,

    # Encoder slots: how many variants (of any titles) encode at once.
    [ValidateRange(1, 2)][int]$Threads = 2,

    # VMAF slots: how many compare_encode runs (CPU, in WSL) at once, alongside the encodes.
    [ValidateRange(1, 4)][int]$VmafThreads = 2,

    # Skip VC-1 sources (encodes from them don't currently pass VMAF alignment). -SkipVC1:$false to include.
    [bool]$SkipVC1 = $true,

    [int]$MinFreeGB = 100,
    [int]$MinFreeDoviGB = 400,

    # VMAF bar a variant must meet to pass.
    [double]$MinMean = 93.5,
    [double]$MinP1 = 80,
    [double]$MinMin = 75,

    # Size rules, as video stream % of the source's video stream (see .DESCRIPTION).
    [double]$MaxPct = 65,        # hard cap: bigger variants don't pass
    [double]$TargetPct = 20,     # the search aims here; the passer closest to it is suggested

    # Folder memory: a later title skips a rung next to its folder's pick when the title that set
    # the pick already tried that rung and this title's result at the pick is about the same:
    # same pass/fail, size within SimilarPct points, and (stepping smaller) VMAF not better by
    # more than SimilarVmaf on mean/p1/min. 0 turns it off.
    [double]$SimilarPct = 3,
    [double]$SimilarVmaf = 1,

    # Ladder mode, once a title has a suggested variant: add the Blu-ray audio to it with
    # Add-BluRayAudio (-Replace), move it up to the mirrored folder (Dest\...\<name>.mkv), and
    # delete this title's other variants. -NoAudio skips the audio, -KeepVariants the deleting.
    [string]$AddBluRayAudio = (Join-Path $PSScriptRoot 'Add-BluRayAudio.ps1'),
    [switch]$NoAudio,
    [switch]$KeepVariants,

    [string]$NVEncC = (Join-Path $env:APPDATA 'NVEnc\NVEncC64.exe'),
    [string]$CropDetect = (Join-Path $PSScriptRoot 'CropDetect.ps1'),
    [ValidateSet('avhw', 'avsw')][string]$Decoder = 'avhw',

    # WSL side. Commands must be on PATH for a login shell (bash -l), or give full paths.
    [string]$WslDistro,
    [string]$WslMountRoot = '/mnt',
    [string]$CompareEncodeCmd = 'compare_encode',
    [string]$DoviConvertCmd = 'dovi_convert',
    [string]$RemountCmd = 'remount',

    # Encode only; don't run compare_encode.
    [switch]$SkipVmaf
)

$ErrorActionPreference = 'Stop'
$started = Get-Date
$runId = $started.ToString('yyyyMMdd_HHmmss')

# =====================================================================================
# Helpers shared by the orchestrator and the worker jobs (jobs are separate processes,
# so these are passed in as text and dot-sourced there).
# =====================================================================================
$Helpers = {
    $script:LogPath = $null
    $script:EchoLog = $false
    $script:StatusFile = $null
    $script:LogPrefix = ''
    $script:Utf8 = New-Object System.Text.UTF8Encoding $false

    # Several processes (two variants of one title) can write the same log. Take the file
    # exclusively for each write (readers like Get-Content -Wait are still allowed) and retry
    # briefly if another writer has it.
    function Add-LogText {
        param([string]$Path, [string]$Text)
        if (-not $Path) { return }
        $bytes = $script:Utf8.GetBytes($Text)
        for ($try = 0; $try -lt 400; $try++) {
            try {
                $fs = New-Object IO.FileStream($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::Read)
                try { [void]$fs.Seek(0, [IO.SeekOrigin]::End); $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
                return
            } catch [IO.IOException] { Start-Sleep -Milliseconds 25 }
        }
    }

    function Write-Log {
        param([string]$Message, [string]$Color = 'Gray')
        $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}{2}' -f (Get-Date), $script:LogPrefix, $Message
        Add-LogText $script:LogPath ($line + "`r`n")
        if ($script:EchoLog) { Write-Host $line -ForegroundColor $Color }
    }

    function Write-LogRaw {
        param([string]$Text)
        if ($script:LogPrefix -and $Text) { $Text = $Text -replace '^( {0,4})', ('$1' + $script:LogPrefix.Replace('$', '$$')) }
        Add-LogText $script:LogPath ($Text + "`r`n")
    }

    function Set-Status {
        param([hashtable]$Status)
        if (-not $script:StatusFile) { return }
        try {
            $tmp = $script:StatusFile + '.tmp'
            [IO.File]::WriteAllText($tmp, ($Status | ConvertTo-Json -Compress), $script:Utf8)
            Move-Item -LiteralPath $tmp -Destination $script:StatusFile -Force
        } catch { }
    }

    # Windows command-line quoting (CommandLineToArgvW rules).
    function Join-Args {
        param([string[]]$ArgList)
        ($ArgList | ForEach-Object {
            $s = [string]$_
            if ($s -eq '') { '""' }
            elseif ($s -notmatch '[\s"]') { $s }
            else { '"' + (($s -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
        }) -join ' '
    }

    function ConvertTo-BashQuoted {
        param([string]$Text)
        "'" + ($Text -replace "'", "'\''") + "'"
    }

    function ConvertTo-WslPath {
        param([string]$Path, [string]$MountRoot = '/mnt')
        if ($Path.StartsWith('/')) { return $Path }   # already a Linux path
        if ($Path -match '^([A-Za-z]):\\?(.*)$') {
            return ($MountRoot.TrimEnd('/') + '/' + $Matches[1].ToLower() + '/' + ($Matches[2] -replace '\\', '/')).TrimEnd('/')
        }
        throw "Can't map '$Path' into WSL (only drive-letter paths are supported, not UNC)."
    }

    function Get-FreeGB {
        param([string]$Path)
        $root = [IO.Path]::GetPathRoot($Path)
        if (-not $root -or $root.StartsWith('\\')) { throw "Free-space check needs a drive-letter path: '$Path'." }
        [Math]::Round((New-Object IO.DriveInfo $root).AvailableFreeSpace / 1GB, 1)
    }

    # Runs a program, streaming stdout+stderr into the log (minus progress lines, which go to the
    # status file instead). Returns ExitCode and the logged Lines.
    function Invoke-Logged {
        param(
            [Parameter(Mandatory)][string]$Exe,
            [Parameter(Mandatory)][string[]]$ArgList,
            [string]$TempDir = [IO.Path]::GetTempPath(),
            [hashtable]$StatusBase = @{},
            [string]$ProgressPattern = '^\[(\d+(?:\.\d+)?)%\]\s*(.*)$',
            [switch]$Quiet
        )
        $argStr = Join-Args $ArgList
        if (-not $Quiet) { Write-Log "> $Exe $argStr" }
        $id = [guid]::NewGuid().ToString('N')
        $outFile = Join-Path $TempDir "$id.out"
        $errFile = Join-Path $TempDir "$id.err"
        $p = Start-Process -FilePath $Exe -ArgumentList $argStr -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $null = $p.Handle   # keeps ExitCode available after exit (Windows PowerShell quirk)
        $st = @{} + $StatusBase; $st.Pid = $p.Id; $st.Exe = [IO.Path]::GetFileNameWithoutExtension($Exe)
        Set-Status $st

        $lines = New-Object System.Collections.Generic.List[string]
        $streams = @()
        foreach ($f in $outFile, $errFile) {
            $streams += [pscustomobject]@{ File = $f; Reader = $null; Pending = '' }
        }
        $throttle = @{ Last = [DateTime]::MinValue }

        $drain = {
            param([bool]$Final)
            foreach ($s in $streams) {
                if (-not $s.Reader) {
                    if (-not [IO.File]::Exists($s.File)) { continue }
                    $fs = New-Object IO.FileStream($s.File, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                    $s.Reader = New-Object IO.StreamReader($fs, $script:Utf8)
                }
                $chunk = $s.Reader.ReadToEnd()
                if (-not $chunk -and -not $Final) { continue }
                $text = $s.Pending + $chunk
                $parts = [regex]::Split($text, '\r\n|\r|\n')
                if ($Final) { $s.Pending = '' }
                else {
                    $s.Pending = $parts[-1]
                    # (careful: 0..-1 in PowerShell is "first and last", not empty)
                    if ($parts.Count -gt 1) { $parts = $parts[0..($parts.Count - 2)] } else { $parts = @() }
                }
                foreach ($line in $parts) {
                    if ($line -match $ProgressPattern) {
                        if (((Get-Date) - $throttle.Last).TotalSeconds -ge 2) {
                            $st.Pct = [double]$Matches[1]; $st.Detail = $Matches[2]
                            Set-Status $st
                            $throttle.Last = Get-Date
                        }
                    } elseif ($line.Trim()) {
                        $lines.Add($line)
                        if (-not $Quiet) { Write-LogRaw "    $line" }
                    }
                }
            }
        }

        while (-not $p.HasExited) {
            & $drain $false
            Start-Sleep -Milliseconds 500
        }
        $p.WaitForExit()
        & $drain $false
        & $drain $true
        foreach ($s in $streams) { if ($s.Reader) { $s.Reader.Dispose() } }
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
        if (-not $Quiet) { Write-Log "  exit code $($p.ExitCode)" }
        [pscustomobject]@{ ExitCode = $p.ExitCode; Lines = $lines.ToArray() }
    }

    # Runs a bash snippet inside WSL as a login shell. Paths listed in -NeedPaths are checked
    # first; if any are missing the remount command is run once (serialised with flock).
    function Invoke-Wsl {
        param(
            [Parameter(Mandatory)][string]$Body,
            [string[]]$NeedPaths = @(),
            [Parameter(Mandatory)]$Wsl,
            [string]$TempDir = [IO.Path]::GetTempPath(),
            [hashtable]$StatusBase = @{},
            [switch]$Quiet
        )
        $need = ($NeedPaths | ForEach-Object { ConvertTo-BashQuoted $_ }) -join ' '
        $prelude = @'
set -u
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"; fi
eb_ensure_visible() {
  local p missing=0
  for p in "$@"; do [ -e "$p" ] || missing=1; done
  [ "$missing" -eq 0 ] && return 0
  echo "[encode-batch] not visible in WSL; running remount"
  ( flock -w 300 9 || exit 0; timeout 180 __REMOUNT__ </dev/null ) 9>/tmp/encode-batch-remount.lock
  for p in "$@"; do
    [ -e "$p" ] || { echo "[encode-batch] still not visible in WSL after remount: $p"; return 97; }
  done
}
'@
        $prelude = $prelude.Replace('__REMOUNT__', $Wsl.RemountCmd)
        $script = $prelude + "`n"
        if ($need) { $script += "eb_ensure_visible $need || exit `$?`n" }
        $script += $Body + "`n"
        $shFile = Join-Path $TempDir ([guid]::NewGuid().ToString('N') + '.sh')
        [IO.File]::WriteAllText($shFile, ($script -replace "`r`n", "`n"), $script:Utf8)
        $a = @()
        if ($Wsl.Distro) { $a += @('-d', $Wsl.Distro) }
        $a += @('-e', 'bash', '-l', (ConvertTo-WslPath $shFile $Wsl.MountRoot))
        $env:WSL_UTF8 = '1'
        try {
            Invoke-Logged -Exe 'wsl.exe' -ArgList $a -TempDir $TempDir -StatusBase $StatusBase -Quiet:$Quiet
        } finally {
            Remove-Item -LiteralPath $shFile -Force -ErrorAction SilentlyContinue
        }
    }

    # ffprobe (+ mediainfo when available) summary of the first video stream.
    function Get-SourceInfo {
        param([string]$Path)
        $ErrorActionPreference = 'Continue'
        $raw = & ffprobe -v error -select_streams v:0 -show_streams -show_format -of json $Path 2>$null
        if (-not $raw) { throw "ffprobe could not read '$Path'." }
        $j = ($raw -join "`n") | ConvertFrom-Json
        $s = @($j.streams)[0]
        if (-not $s) { throw "No video stream in '$Path'." }

        $ffDv = $null
        if ($s.PSObject.Properties['side_data_list']) {
            foreach ($sd in @($s.side_data_list)) {
                if ($sd.side_data_type -eq 'DOVI configuration record') {
                    $ffDv = [pscustomobject]@{ Profile = [int]$sd.dv_profile; Compat = [int]$sd.dv_bl_signal_compatibility_id }
                }
            }
        }
        $ffClass = 'None'
        if ($ffDv) {
            $ffClass = switch ($ffDv.Profile) {
                7 { 'P7' }
                8 { switch ($ffDv.Compat) { 1 { 'P8.1' } 2 { 'P8.2' } 4 { 'P8.4' } default { "P8 (compat $($ffDv.Compat))" } } }
                default { "P$($ffDv.Profile)" }
            }
        }

        $miClass = $null; $miText = ''
        if (Get-Command mediainfo -ErrorAction SilentlyContinue) {
            try {
                $miRaw = & mediainfo --Output=JSON $Path 2>$null
                $mj = ($miRaw -join "`n") | ConvertFrom-Json
                $vt = @($mj.media.track | Where-Object { $_.'@type' -eq 'Video' })[0]
                $miClass = 'None'
                if ($vt -and $vt.PSObject.Properties['HDR_Format']) { $miText = [string]$vt.HDR_Format }
                if ($vt -and $vt.PSObject.Properties['HDR_Format'] -and $vt.HDR_Format -match 'Dolby Vision') {
                    $fmt = @($vt.HDR_Format -split ' / ')
                    $idx = 0
                    for ($k = 0; $k -lt $fmt.Count; $k++) { if ($fmt[$k] -match 'Dolby Vision') { $idx = $k; break } }
                    $prof = ''; $comp = ''
                    if ($vt.PSObject.Properties['HDR_Format_Profile']) {
                        $ps = @($vt.HDR_Format_Profile -split ' / ')
                        if ($idx -lt $ps.Count) { $prof = $ps[$idx] } else { $prof = $ps[0] }
                    }
                    if ($vt.PSObject.Properties['HDR_Format_Compatibility']) {
                        $cs = @($vt.HDR_Format_Compatibility -split ' / ')
                        if ($idx -lt $cs.Count) { $comp = $cs[$idx] }
                    }
                    $miText = "$($vt.HDR_Format) | $prof | $comp"
                    if ($prof -match 'dv[a-z0-9]{2}\.(\d{2})') {
                        $pn = [int]$Matches[1]
                        $miClass = switch ($pn) {
                            7 { 'P7' }
                            8 { if ($comp -match 'HDR10') { 'P8.1' } elseif ($comp -match 'HLG') { 'P8.4' } elseif ($comp -match 'SDR') { 'P8.2' } else { "P8 ($comp)" } }
                            default { "P$pn" }
                        }
                    } else { $miClass = 'DV (unknown profile)' }
                }
            } catch { $miClass = $null }
        }

        # Use both opinions: any disagreement about Dolby Vision is a reason to stop, not guess.
        $dv = $ffClass
        if ($null -ne $miClass -and $miClass -ne $ffClass) {
            if ($ffClass -eq 'None') { $dv = $miClass } elseif ($miClass -ne 'None') { $dv = "Mismatch (ffprobe $ffClass, mediainfo $miClass)" }
        }

        $dur = 0.0
        if ($j.format -and $j.format.PSObject.Properties['duration']) {
            [void][double]::TryParse([string]$j.format.duration, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$dur)
        }
        $trc = ''; if ($s.PSObject.Properties['color_transfer']) { $trc = [string]$s.color_transfer }
        $fps = '24000/1001'; if ($s.PSObject.Properties['r_frame_rate'] -and $s.r_frame_rate -match '^\d+/\d+$') { $fps = $s.r_frame_rate }
        $hdr = ($trc -eq 'smpte2084' -or $trc -eq 'arib-std-b67')

        # HDR only: read the static metadata and whether HDR10+ is present, the way FastFlix does,
        # so NVEncC gets explicit values instead of relying on "auto"/"copy".
        $colorArgs = @(); $masterDisplay = ''; $maxCll = ''; $hdr10Plus = $false
        if ($hdr) {
            $okMatrix = 'bt709', 'bt2020nc', 'bt2020c', 'smpte170m', 'bt470bg'
            $okPrim = 'bt709', 'bt2020', 'smpte170m', 'bt470bg', 'smpte432'
            if ($s.PSObject.Properties['color_space'] -and $okMatrix -contains $s.color_space) { $colorArgs += @('--colormatrix', [string]$s.color_space) }
            $colorArgs += @('--transfer', $trc)
            if ($s.PSObject.Properties['color_primaries'] -and $okPrim -contains $s.color_primaries) { $colorArgs += @('--colorprim', [string]$s.color_primaries) }

            $side = @()
            if ($s.PSObject.Properties['side_data_list']) { $side += @($s.side_data_list) }
            $fr = & ffprobe -v error -select_streams v:0 -read_intervals '%+#6' -show_frames -show_entries 'frame=side_data_list' -of json $Path 2>$null
            if ($fr) {
                try { foreach ($f in @((($fr -join "`n") | ConvertFrom-Json).frames)) { if ($f.PSObject.Properties['side_data_list']) { $side += @($f.side_data_list) } } } catch { }
            }
            $num = {
                param($v)
                $t = [string]$v
                if ($t -match '^(-?[\d.]+)/([\d.]+)$') { [double]$Matches[1] / [double]$Matches[2] } else { [double]$t }
            }
            $md = $side | Where-Object { $_.side_data_type -eq 'Mastering display metadata' -and $_.PSObject.Properties['red_x'] } | Select-Object -First 1
            if ($md) {
                $c = { param($v) [int][Math]::Round((& $num $v) * 50000) }
                $l = { param($v) [long][Math]::Round((& $num $v) * 10000) }
                $masterDisplay = 'G({0},{1})B({2},{3})R({4},{5})WP({6},{7})L({8},{9})' -f `
                    (& $c $md.green_x), (& $c $md.green_y), (& $c $md.blue_x), (& $c $md.blue_y),
                    (& $c $md.red_x), (& $c $md.red_y), (& $c $md.white_point_x), (& $c $md.white_point_y),
                    (& $l $md.max_luminance), (& $l $md.min_luminance)
            }
            $cl = $side | Where-Object { $_.side_data_type -eq 'Content light level metadata' } | Select-Object -First 1
            if ($cl -and ([int]$cl.max_content -gt 0 -or [int]$cl.max_average -gt 0)) { $maxCll = '{0},{1}' -f [int]$cl.max_content, [int]$cl.max_average }
            $hdr10Plus = [bool]($side | Where-Object { $_.side_data_type -match '2094-40|HDR10\+' } | Select-Object -First 1)
            if (-not $hdr10Plus -and $miText -match '2094') { $hdr10Plus = $true }
        }

        [pscustomobject]@{
            Codec     = [string]$s.codec_name
            Width     = [int]$s.width
            Height    = [int]$s.height
            Fps       = $fps
            Duration  = $dur
            Transfer  = $trc
            Hdr       = $hdr
            Hdr10Plus = $hdr10Plus
            ColorArgs = $colorArgs
            MasterDisplay = $masterDisplay
            MaxCll    = $maxCll
            Dv        = $dv
            DvDetail  = "ffprobe=$ffClass mediainfo=$(if ($null -eq $miClass) { 'n/a' } else { $miClass }) $miText".Trim()
        }
    }

    function Read-VmafResult {
        param([string[]]$Lines)
        $r = [ordered]@{ Mean = $null; P1 = $null; Min = $null; VideoGB = $null; SourceGB = $null; Pct = $null; Mbps = $null; Model = ''; Warning = $false }
        foreach ($l in $Lines) {
            if ($l -match '^\s*pooled\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)') {
                $r.Mean = [double]$Matches[1]; $r.P1 = [double]$Matches[2]; $r.Min = [double]$Matches[3]
            } elseif ($l -match '^Sizes.*?original ([\d.]+) GB, encode ([\d.]+) GB \((\d+)% of original\), encode avg ([\d.]+) Mbps') {
                $r.SourceGB = [double]$Matches[1]; $r.VideoGB = [double]$Matches[2]; $r.Pct = [double]$Matches[3]; $r.Mbps = [double]$Matches[4]
                # compare_encode rounds to a whole percent; recompute to 0.1 so close variants still order.
                if ($r.SourceGB -gt 0) { $r.Pct = [Math]::Round($r.VideoGB / $r.SourceGB * 100, 1) }
            } elseif ($l -match '^VMAF model: (\S+)') {
                $r.Model = $Matches[1]
            } elseif ($l -match 'WARNING: (alignment differs|no shift|durations differ)') {
                $r.Warning = $true
            }
        }
        if ($null -ne $r.P1 -and $r.P1 -le 0) { $r.Warning = $true }
        [pscustomobject]$r
    }

    # Pass = mean/p1/min at or above the bar, at most MaxPct of the source (video stream vs video
    # stream), and no VMAF alignment warning.
    function Get-VariantClass {
        param($Row, [double]$MinMean, [double]$MinP1, [double]$MinMin, [double]$MaxPct)
        if ($Row.Status -ne 'Done' -or $null -eq $Row.Mean -or $null -eq $Row.VideoGB -or $Row.Warning) { return 'error' }
        $q = $Row.Mean -ge $MinMean -and $Row.P1 -ge $MinP1 -and $Row.Min -ge $MinMin
        $over = $null -ne $Row.Pct -and $Row.Pct -gt $MaxPct
        if ($q -and -not $over) { 'pass' } elseif ($q) { 'overcap' } elseif ($over) { 'fail+overcap' } else { 'fail' }
    }

    # Marks Pass / OverCap / Dominated / Suggested (and clears Hint) on variant rows, in place.
    # Suggested = the passing variant whose size is closest to TargetPct of the source, either
    # direction; ties go to the smaller file. Returns its name, or $null when nothing passes.
    function Set-Suggestion {
        param($Rows, [double]$MinMean, [double]$MinP1, [double]$MinMin, [double]$MaxPct = 65, [double]$TargetPct = 20)
        foreach ($r in $Rows) {
            foreach ($k in 'Pass', 'OverCap', 'Dominated', 'Suggested') {
                if ($r.PSObject.Properties[$k]) { $r.$k = $false } else { $r | Add-Member -NotePropertyName $k -NotePropertyValue $false }
            }
            if ($r.PSObject.Properties['Hint']) { $r.Hint = '' } else { $r | Add-Member -NotePropertyName Hint -NotePropertyValue '' }
        }
        $scored = @($Rows | Where-Object { (Get-VariantClass $_ $MinMean $MinP1 $MinMin $MaxPct) -ne 'error' })
        foreach ($r in $scored) {
            $c = Get-VariantClass $r $MinMean $MinP1 $MinMin $MaxPct
            $r.Pass = $c -eq 'pass'
            $r.OverCap = $c -like '*overcap'
            foreach ($o in $scored) {
                if ($o -eq $r) { continue }
                $noWorse = $o.VideoGB -le $r.VideoGB -and $o.Mean -ge $r.Mean -and $o.P1 -ge $r.P1 -and $o.Min -ge $r.Min
                $better = $o.VideoGB -lt $r.VideoGB -or $o.Mean -gt $r.Mean -or $o.P1 -gt $r.P1 -or $o.Min -gt $r.Min
                if ($noWorse -and $better) { $r.Dominated = $true; break }
            }
        }
        $passers = @($scored | Where-Object { $_.Pass })
        if (-not $passers.Count) { return $null }
        $pick = @($passers | Sort-Object @{ Expression = { if ($null -eq $_.Pct) { 1e9 } else { [Math]::Abs($_.Pct - $TargetPct) } } }, VideoGB)[0]
        $pick.Suggested = $true
        return $pick.Name
    }

    # One step of the ladder search. Rungs are indexed weakest/smallest (0) to strongest/biggest.
    # $Tried maps rung index -> finished row, or $null while it's queued / encoding / scoring.
    # Returns the rung to encode next, -1 to wait for the ones in flight, or -2 when finished.
    #   - Start rungs first (all at once, so both encoder slots can take one).
    #   - Some pass: if the smallest passer is still above TargetPct, try the next smaller rung;
    #     if the biggest passer is below TargetPct, try the next bigger one. Otherwise finished.
    #   - None pass: passes the bar but over the cap -> try smaller; fails the bar -> try bigger.
    #   - Never repeats a rung, so it always ends (at worst at an end of the ladder).
    #   - $Skip: rungs to treat as already answered (see Get-KnownRungReason); never proposed.
    function Get-LadderNext {
        param([hashtable]$Tried, [int]$Count, [int[]]$Start, [double]$MinMean, [double]$MinP1, [double]$MinMin,
            [double]$MaxPct = 65, [double]$TargetPct = 20, [hashtable]$Skip = @{})
        foreach ($i in @($Start)) { if ($i -ge 0 -and $i -lt $Count -and -not $Tried.ContainsKey($i) -and -not $Skip.ContainsKey($i)) { return $i } }
        foreach ($k in @($Tried.Keys)) { if ($null -eq $Tried[$k]) { return -1 } }
        $ok = @(); $overcap = @(); $fail = @()
        foreach ($k in @($Tried.Keys)) {
            switch (Get-VariantClass $Tried[$k] $MinMean $MinP1 $MinMin $MaxPct) {
                'pass' { $ok += [int]$k } 'overcap' { $overcap += [int]$k } 'fail' { $fail += [int]$k }
            }
        }
        $open = { param([int]$i) $i -ge 0 -and $i -lt $Count -and -not $Tried.ContainsKey($i) -and -not $Skip.ContainsKey($i) }
        if ($ok.Count) {
            $lo = [int]($ok | Measure-Object -Minimum).Minimum
            $hi = [int]($ok | Measure-Object -Maximum).Maximum
            $loPct = $Tried[$lo].Pct; $hiPct = $Tried[$hi].Pct
            if (($null -eq $loPct -or $loPct -gt $TargetPct) -and (& $open ($lo - 1))) { return $lo - 1 }
            if ($null -ne $hiPct -and $hiPct -lt $TargetPct -and (& $open ($hi + 1))) { return $hi + 1 }
            return -2
        }
        if ($overcap.Count) { $i = [int]($overcap | Measure-Object -Minimum).Minimum - 1; if (& $open $i) { return $i } }
        if ($fail.Count) { $i = [int]($fail | Measure-Object -Maximum).Maximum + 1; if (& $open $i) { return $i } }
        -2
    }

    # Whether rung $Rung can be skipped for a title because its folder's reference title already
    # answered it. $Ref = @{ Name; Pick (rung it chose); Rows (rung -> row it encoded) }.
    # Only for a neighbour of the reference's pick: the reference tried both and chose its pick, so
    # if this title's result at that pick is about the same (same pass/fail, size within
    # SimilarPct points, and when stepping smaller, quality not better by more than SimilarVmaf),
    # the neighbour would very likely lose again. Returns the reason, or '' to encode it.
    function Get-KnownRungReason {
        param($Ref, [hashtable]$Tried, [int]$Rung, [string[]]$Names, [double]$MinMean, [double]$MinP1, [double]$MinMin,
            [double]$MaxPct = 65, [double]$SimilarPct = 3, [double]$SimilarVmaf = 1)
        if ($SimilarPct -le 0 -or -not $Ref -or [Math]::Abs($Rung - $Ref.Pick) -ne 1) { return '' }
        $p = [int]$Ref.Pick
        $mine = $Tried[$p]; $theirs = $Ref.Rows[$p]; $theirsN = $Ref.Rows[$Rung]
        if (-not $mine -or -not $theirs -or -not $theirsN) { return '' }
        $cm = Get-VariantClass $mine $MinMean $MinP1 $MinMin $MaxPct
        if ($cm -eq 'error' -or $cm -ne (Get-VariantClass $theirs $MinMean $MinP1 $MinMin $MaxPct)) { return '' }
        if ((Get-VariantClass $theirsN $MinMean $MinP1 $MinMin $MaxPct) -eq 'error') { return '' }
        if ($null -eq $mine.Pct -or $null -eq $theirs.Pct -or [Math]::Abs($mine.Pct - $theirs.Pct) -gt $SimilarPct) { return '' }
        if ($Rung -lt $p) {
            foreach ($k in 'Mean', 'P1', 'Min') { if ($mine.$k -gt $theirs.$k + $SimilarVmaf) { return '' } }
        }
        $nTheirs = if ($null -ne $theirsN.Pct) { '{0:0.#}%' -f $theirsN.Pct } else { 'n/a' }
        "skipped {0}: {1} was {2:0.#}% at {3} (this title {4:0.#}%) and its {0} ({5}, {6:0.00}/{7:0.00}/{8:0.00}) lost to {3}" -f `
            $Names[$Rung], $Ref.Name, $theirs.Pct, $Names[$p], $mine.Pct, $nTheirs, $theirsN.Mean, $theirsN.P1, $theirsN.Min
    }

    function Format-VariantTable {
        param($Rows)
        $out = @('| Variant | Mean | p1 | Min | Video GB | % src | Mbps | Notes |', '|---|---|---|---|---|---|---|---|')
        foreach ($r in $Rows) {
            $notes = @()
            if ($r.Suggested) { $notes += '**suggested**' }
            if ($r.Pass -and -not $r.Suggested) { $notes += 'passes' }
            if ($r.PSObject.Properties['Hint'] -and $r.Hint) { $notes += $r.Hint }
            if ($r.PSObject.Properties['OverCap'] -and $r.OverCap) { $notes += 'over the size cap' }
            if ($r.Dominated) { $notes += 'dominated' }
            if ($r.Warning) { $notes += 'VMAF alignment warning' }
            if ($null -ne $r.Mbps -and $r.Mbps -gt 40) { $notes += 'avg > 40 Mbps (HEVC L5.1 Main limit)' }
            if ($r.Status -ne 'Done') { $notes += $r.Status }
            if ($r.Error) { $notes += $r.Error }
            $f = { param($v, $fmt) if ($null -eq $v) { '-' } else { $fmt -f $v } }
            $name = if ($r.Suggested) { "**$($r.Name)**" } else { $r.Name }
            $out += '| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} |' -f $name,
                (& $f $r.Mean '{0:0.00}'), (& $f $r.P1 '{0:0.00}'), (& $f $r.Min '{0:0.00}'),
                (& $f $r.VideoGB '{0:0.00}'), (& $f $r.Pct '{0:0.#}%'), (& $f $r.Mbps '{0:0.0}'), ($notes -join ', ')
        }
        $out
    }
}

# =====================================================================================
# Workers. Each runs in its own job process; config arrives (and the result leaves) as JSON,
# because job serialization only keeps one level of nesting and would turn argument arrays
# into the string "System.Object[]".
#   Prep worker:    one per title, one at a time. Dolby Vision 7 conversion + crop detection.
#   Variant worker: one per (title, variant), up to -Threads at once. Encode + VMAF.
# =====================================================================================
$WorkerHeader = {
    param([string]$CfgJson)
    # 'Continue', not 'Stop': in Windows PowerShell, 2>&1 on a native program (ffprobe, and the
    # ffmpeg calls inside CropDetect) raises terminating errors under 'Stop'. Failures that must
    # stop the job are checked explicitly or use -ErrorAction Stop.
    $ErrorActionPreference = 'Continue'
    $ProgressPreference = 'SilentlyContinue'
    $Cfg = $CfgJson | ConvertFrom-Json
    $env:PATH = $Cfg.EnvPath
    try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }   # no console in a job; best effort
    . ([scriptblock]::Create($Cfg.Helpers))
    $script:LogPath = $Cfg.LogPath
    $script:StatusFile = $Cfg.StatusFile
    $t0 = Get-Date
    $base = $Cfg.BaseName
    $titleDir = $Cfg.TitleDir
    $tmp = $Cfg.TempDir
    $wsl = $Cfg.Wsl
}

$PrepBody = {
    $status = @{ Step = 'preparing'; Variant = ''; Index = 0; Count = 0 }
    function Step([string]$name) {
        $status.Step = $name; $status.Remove('Pct'); $status.Remove('Detail')
        Set-Status $status
    }
    function Done([string]$st, [string]$reason, $workSrc = $null, $isDv81 = $false, $crop = $null) {
        if ($reason) { Write-Log "PREP: $st - $reason" } else { Write-Log "PREP: $st" }
        [pscustomobject]@{ Status = $st; Reason = $reason; WorkSrc = $workSrc; IsDv81 = [bool]$isDv81; Crop = $crop
                           Seconds = [int]((Get-Date) - $t0).TotalSeconds }
    }

    function Invoke-Prep {
      try {
        Write-LogRaw ''
        Write-LogRaw ('=' * 100)
        Write-Log "Encode-Batch run $($Cfg.RunId): $($Cfg.SourceFile)"
        Write-Log ("Source: {0} {1}x{2} {3} fps, {4}, HDR={5}, Dolby Vision={6}" -f $Cfg.Info.Codec, $Cfg.Info.Width, $Cfg.Info.Height, $Cfg.Info.Fps, [TimeSpan]::FromSeconds([int]$Cfg.Info.Duration), $Cfg.Info.Hdr, $Cfg.Info.Dv)
        Write-Log "  ($($Cfg.Info.DvDetail))"
        if ($Cfg.Info.Hdr) { Write-Log ("  HDR: {0}  master-display {1}  max-cll {2}  HDR10+ {3}" -f (@($Cfg.Info.ColorArgs) -join ' '), $(if ($Cfg.Info.MasterDisplay) { $Cfg.Info.MasterDisplay } else { 'none' }), $(if ($Cfg.Info.MaxCll) { $Cfg.Info.MaxCll } else { 'none' }), $Cfg.Info.Hdr10Plus) }

        $workSrc = $Cfg.SourceFile
        $isDv81 = ($Cfg.Info.Dv -eq 'P8.1')

        # ---------------------------------------------------------------- Dolby Vision profile 7
        if ($Cfg.Info.Dv -eq 'P7') {
            $p81 = Join-Path $titleDir "$base - p8.1.mkv"
            $p7copy = Join-Path $titleDir "$base - p7 source.mkv"
            $review = "$p7copy.review.txt"
            if ([IO.File]::Exists($p81)) {
                Write-Log "Dolby Vision 7: reusing previously converted copy $p81"
            } elseif ([IO.File]::Exists($review)) {
                return (Done 'Skipped' "Dolby Vision 7 copy was flagged for manual review in an earlier run ($review). Delete that file to retry.")
            } else {
                Step 'dovi_convert scan'
                $srcW = ConvertTo-WslPath $Cfg.SourceFile $wsl.MountRoot
                $r = Invoke-Wsl -Wsl $wsl -TempDir $tmp -NeedPaths @($srcW) -StatusBase $status `
                    -Body ("cd /tmp && {0} scan {1}" -f $wsl.DoviConvertCmd, (ConvertTo-BashQuoted $srcW))
                $action = $null
                foreach ($l in $r.Lines) { if ($l -match '^\s*Action:\s*(\S+)') { $action = $Matches[1] } }
                if ($r.ExitCode -ne 0 -or -not $action) { return (Done 'Skipped' "dovi_convert scan failed (exit $($r.ExitCode)).") }
                if ($action -ne 'CONVERT' -and $action -ne 'CONVERT*') { return (Done 'Skipped' "dovi_convert scan says Action: $action.") }

                $free = Get-FreeGB $titleDir
                if ($free -lt $Cfg.MinFreeDoviGB) { return (Done 'Skipped' "only $free GB free; Dolby Vision 7 conversion needs $($Cfg.MinFreeDoviGB) GB.") }

                if (-not [IO.File]::Exists($p7copy)) {
                    Step 'copying p7 source'
                    Write-Log "Copying source to $p7copy ($free GB free)"
                    $part = "$p7copy.partial"
                    Copy-Item -LiteralPath $Cfg.SourceFile -Destination $part -Force -ErrorAction Stop
                    Move-Item -LiteralPath $part -Destination $p7copy -Force -ErrorAction Stop
                } else {
                    Write-Log "Reusing existing local copy $p7copy"
                }
                $copyW = ConvertTo-WslPath $p7copy $wsl.MountRoot
                $dirW = ConvertTo-WslPath $titleDir $wsl.MountRoot

                if ($action -eq 'CONVERT*') {
                    Step 'dovi_convert inspect'
                    $r = Invoke-Wsl -Wsl $wsl -TempDir $tmp -NeedPaths @($copyW) -StatusBase $status `
                        -Body ("cd {0} && {1} inspect {2}" -f (ConvertTo-BashQuoted $dirW), $wsl.DoviConvertCmd, (ConvertTo-BashQuoted $copyW))
                    $verdict = $null
                    foreach ($l in $r.Lines) { if ($l -match '^\s*VERDICT:\s*(.+?)\s*$') { $verdict = $Matches[1] } }
                    if ($r.ExitCode -ne 0 -or $verdict -ne 'SAFE') {
                        $why = if ($verdict) { "VERDICT: $verdict" } else { "inspect failed (exit $($r.ExitCode))" }
                        [IO.File]::WriteAllText($review, ("{0}`r`n`r`n{1}" -f $why, ($r.Lines -join "`r`n")), $script:Utf8)
                        return (Done 'Skipped' "Dolby Vision 7 needs manual review ($why). Local copy kept: $p7copy")
                    }
                }

                Step 'dovi_convert convert'
                $before = @(Get-ChildItem -LiteralPath $titleDir -File | ForEach-Object { $_.Name })
                $r = Invoke-Wsl -Wsl $wsl -TempDir $tmp -NeedPaths @($copyW) -StatusBase $status `
                    -Body ("cd {0} && {1} convert --backup --delete {2}" -f (ConvertTo-BashQuoted $dirW), $wsl.DoviConvertCmd, (ConvertTo-BashQuoted $copyW))
                $after = @(Get-ChildItem -LiteralPath $titleDir -File | ForEach-Object { $_.Name })
                $new = @($after | Where-Object { $before -notcontains $_ })
                if ($new.Count) { Write-Log "New files after convert: $($new -join ', ')" }
                if ($r.ExitCode -ne 0) { return (Done 'Failed' "dovi_convert convert failed (exit $($r.ExitCode)). Files left in place for review.") }
                $chk = Get-SourceInfo $p7copy
                if ($chk.Dv -ne 'P8.1') { return (Done 'Failed' "after conversion the copy reports '$($chk.Dv)', not P8.1 ($($chk.DvDetail)). Files left in place for review.") }
                Move-Item -LiteralPath $p7copy -Destination $p81 -Force -ErrorAction Stop
                Write-Log "Converted to Dolby Vision 8.1: $p81"
            }
            $workSrc = $p81
            $isDv81 = $true
        }

        # ---------------------------------------------------------------- crop
        # Cached per title so a rerun doesn't rescan the whole film. Delete <name>.crop.json to redo.
        $cropFile = Join-Path $titleDir "$base.crop.json"
        $crop = $null
        if ([IO.File]::Exists($cropFile)) {
            try { $crop = [IO.File]::ReadAllText($cropFile) | ConvertFrom-Json; Write-Log "Reusing crop from $cropFile" } catch { $crop = $null }
        }
        if (-not $crop) {
            Step 'CropDetect'
            $cdArgs = @{ Source = $workSrc; Plumbing = $true }
            if ($Cfg.Info.Width -ge 3800) { $cdArgs.HwDecode = $true }
            Write-Log "> CropDetect -Source `"$workSrc`" -Plumbing$(if ($cdArgs.HwDecode) { ' -HwDecode' })"
            $cdOut = & $Cfg.CropDetect @cdArgs 6>&1 3>&1
            foreach ($o in $cdOut) {
                $txt = if ($o -is [System.Management.Automation.InformationRecord]) { [string]$o.MessageData } else { [string]$o }
                if ($txt -match '^\s*\{.*"Width".*\}\s*$') { $crop = $txt | ConvertFrom-Json; [IO.File]::WriteAllText($cropFile, $txt.Trim(), $script:Utf8) }
                elseif ($txt.Trim() -and $txt.Trim() -notmatch '^[.x]+$') { Write-LogRaw "    $($txt.TrimEnd())" }
            }
        }
        if (-not $crop) { return (Done 'Failed' 'CropDetect did not return a crop.') }
        Write-Log ("Crop: {0}x{1} (L{2} T{3} R{4} B{5}) from {6}x{7}" -f $crop.Width, $crop.Height, $crop.Left, $crop.Top, $crop.Right, $crop.Bottom, $crop.SourceWidth, $crop.SourceHeight)
        return (Done 'Ready' '' $workSrc $isDv81 $crop)
      } catch {
        Write-Log "ERROR: $($_.Exception.Message)"
        Write-LogRaw ($_.ScriptStackTrace)
        return (Done 'Failed' $_.Exception.Message)
      }
    }

    $final = @(Invoke-Prep) | Where-Object { $_ -and $_.PSObject.Properties['WorkSrc'] } | Select-Object -Last 1
    'EB_RESULT:' + ($final | ConvertTo-Json -Depth 6 -Compress)
}

# Shared setup for the encode and VMAF workers of one variant.
$VariantCommon = {
    $v = $Cfg.Variant
    $script:LogPrefix = "[$($v.Name)] "
    $status = @{ Step = 'starting'; Variant = $v.Name; Index = $Cfg.Index; Count = $Cfg.Count }
    function Step([string]$name) {
        $status.Step = $name; $status.Remove('Pct'); $status.Remove('Detail')
        Set-Status $status
    }
    $crop = $Cfg.Crop
    $workSrc = $Cfg.WorkSrc
    $hasCrop = ($crop.Left + $crop.Top + $crop.Right + $crop.Bottom) -gt 0
    $refCrop = '{0}:{1}:{2}:{3}' -f $crop.Width, $crop.Height, $crop.Left, $crop.Top
    $vdir = Join-Path $titleDir $v.Name
    $final = Join-Path $vdir "$base.mkv"
    $vmafFile = Join-Path $vdir "$base.vmaf.txt"
    $row = [pscustomobject][ordered]@{
        Name = $v.Name; Status = 'Failed'; Error = ''; File = $final; EncodeSec = $null
        Mean = $null; P1 = $null; Min = $null; VideoGB = $null; Pct = $null; Mbps = $null
        Model = ''; Warning = $false; Pass = $false; OverCap = $false; Dominated = $false; Suggested = $false; Hint = ''
    }
}

# Encoder slot: NVEncC only. Returns Status 'Encoded' (or 'Done' with -SkipVmaf) or 'Failed'.
$EncodeBody = {
    function Invoke-Encode {
      try {
        Write-Log "---- $($Cfg.Label): $($v.Name) - encode"
        [void][IO.Directory]::CreateDirectory($vdir)
        $partial = Join-Path $vdir "$base.partial.mkv"
        if ([IO.File]::Exists($final)) {
            Write-Log "Encode already exists, reusing: $final"
        } else {
            $free = Get-FreeGB $vdir
            if ($free -lt 10) { $row.Error = "only $free GB free"; Write-Log "Skipping encode: $($row.Error)"; return }
            if ([IO.File]::Exists($partial)) { Remove-Item -LiteralPath $partial -Force }
            Step 'encoding'
            $a = @("--$($Cfg.Decoder)", '--device', '0', '-i', $workSrc)
            if ($hasCrop) { $a += @('--crop', ('{0},{1},{2},{3}' -f $crop.Left, $crop.Top, $crop.Right, $crop.Bottom)) }
            $a += @('--video-metadata', 'clear', '--metadata', 'clear', '--chapter-copy', '-c', 'hevc')
            $a += @($v.Args)
            $a += @('--bref-mode', 'middle', '--preset', 'P7', '--tier', 'main', '--level', '5.1', '--chromaloc', 'auto', '--colorrange', 'auto')
            # Only pass the HDR / HDR10+ / Dolby Vision options a source actually has (FastFlix
            # always adds the "copy" ones). Their avhw implementation re-orders frames by
            # timestamp to match the metadata, so there's no reason to involve it otherwise.
            $colorArgs = @($Cfg.Info.ColorArgs | Where-Object { $_ })
            if ($Cfg.Info.Hdr -and $colorArgs.Count) { $a += $colorArgs }
            else { $a += @('--colormatrix', 'auto', '--transfer', 'auto', '--colorprim', 'auto') }
            if ($Cfg.Info.Hdr) {
                if ($Cfg.Info.MasterDisplay) { $a += @('--master-display', $Cfg.Info.MasterDisplay) } else { Write-Log 'WARNING: HDR source without mastering display metadata; none written.' }
                if ($Cfg.Info.MaxCll) { $a += @('--max-cll', $Cfg.Info.MaxCll) }
            }
            if ($Cfg.Info.Hdr10Plus) { $a += @('--dhdr10-info', 'copy') }
            if ($Cfg.IsDv81) {
                $a += @('--dolby-vision-rpu', 'copy', '--dolby-vision-profile', 'copy')
                if ($hasCrop) { $a += @('--dolby-vision-rpu-prm', 'crop=true') }
            }
            $a += @('--output-depth', '10', '--multipass', '2pass-full', '--mv-precision', 'Auto', '--avsync', 'cfr', '-o', $partial)
            $a = @($a | Where-Object { $null -ne $_ -and "$_" -ne '' })
            $e0 = Get-Date
            $r = Invoke-Logged -Exe $Cfg.NVEncC -ArgList $a -TempDir $tmp -StatusBase $status
            $row.EncodeSec = [int]((Get-Date) - $e0).TotalSeconds
            if ($r.ExitCode -ne 0 -or -not [IO.File]::Exists($partial) -or (Get-Item -LiteralPath $partial).Length -eq 0) {
                $row.Error = "NVEncC exit $($r.ExitCode)"
                Write-Log "Encode FAILED: $($row.Error)"
                return
            }
            Move-Item -LiteralPath $partial -Destination $final -Force -ErrorAction Stop
            # A score left over from an earlier encode of this variant no longer applies.
            if ([IO.File]::Exists($vmafFile)) { Remove-Item -LiteralPath $vmafFile -Force -ErrorAction Stop; Write-Log "Removed the old VMAF result (it was for a previous encode)." }
            Write-Log ("Encoded in {0}: {1}" -f [TimeSpan]::FromSeconds($row.EncodeSec), $final)
        }
        $row.Status = $(if ($Cfg.SkipVmaf) { 'Done' } else { 'Encoded' })
      } catch {
        $row.Error = $_.Exception.Message
        Write-Log "ERROR: $($_.Exception.Message)"
        Write-LogRaw ($_.ScriptStackTrace)
      }
    }
    [void](Invoke-Encode)
    'EB_RESULT:' + ($row | ConvertTo-Json -Depth 4 -Compress)
}

# VMAF slot (CPU): compare_encode --full in WSL on a finished encode.
$VmafBody = {
    function Invoke-Vmaf {
      try {
        Write-Log "---- $($Cfg.Label): $($v.Name) - VMAF"
        if (-not [IO.File]::Exists($final)) { $row.Error = "encode not found: $final"; Write-Log "VMAF FAILED: $($row.Error)"; return }
        $lines = $null
        if ([IO.File]::Exists($vmafFile)) {
            $prev = [IO.File]::ReadAllLines($vmafFile)
            if ((Read-VmafResult $prev).Mean) { $lines = $prev; Write-Log "VMAF result already exists, reusing: $vmafFile" }
        }
        if (-not $lines) {
            Step 'VMAF (compare_encode --full)'
            $srcW = ConvertTo-WslPath $workSrc $wsl.MountRoot
            $encW = ConvertTo-WslPath $final $wsl.MountRoot
            $workW = "/tmp/encode-batch_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
            $body = "cd /tmp && WORK={0} REF_CROP={1} FPS={2} {3} --full {4} {5}; rc=`$?; rm -rf {0}; exit `$rc" -f `
                (ConvertTo-BashQuoted $workW), (ConvertTo-BashQuoted $refCrop), (ConvertTo-BashQuoted $Cfg.Info.Fps),
                $wsl.CompareEncodeCmd, (ConvertTo-BashQuoted $srcW), (ConvertTo-BashQuoted $encW)
            $r = Invoke-Wsl -Wsl $wsl -TempDir $tmp -NeedPaths @($srcW, $encW) -StatusBase $status -Body $body
            $lines = $r.Lines
            [IO.File]::WriteAllLines($vmafFile, $lines, $script:Utf8)
            if ($r.ExitCode -ne 0) { $row.Error = "compare_encode exit $($r.ExitCode)" }
        }
        $vm = Read-VmafResult $lines
        foreach ($k in 'Mean', 'P1', 'Min', 'VideoGB', 'Pct', 'Mbps', 'Model', 'Warning') { $row.$k = $vm.$k }
        if ($null -eq $row.Mean) {
            if (-not $row.Error) { $row.Error = 'no VMAF score in output' }
            Write-Log "VMAF FAILED: $($row.Error)"
            return
        }
        $row.Status = 'Done'
        Write-Log ("VMAF mean {0:0.00} p1 {1:0.00} min {2:0.00}, video {3} GB ({4}% of source), {5} Mbps{6}" -f `
            $row.Mean, $row.P1, $row.Min, $row.VideoGB, $row.Pct, $row.Mbps, $(if ($row.Warning) { '  [alignment warning]' }))
      } catch {
        $row.Error = $_.Exception.Message
        Write-Log "ERROR: $($_.Exception.Message)"
        Write-LogRaw ($_.ScriptStackTrace)
      }
    }
    [void](Invoke-Vmaf)
    'EB_RESULT:' + ($row | ConvertTo-Json -Depth 4 -Compress)
}

# Finish a title: audio into the suggested variant, move it up, delete the other variants.
# Progress is kept in <name>.final.json (Cfg.Doc) so an interrupted finish resumes safely.
$FinalizeBody = {
    $script:LogPrefix = '[finish] '
    $status = @{ Step = 'finishing'; Variant = $Cfg.Doc.Variant; Index = 0; Count = 0 }
    $doc = $Cfg.Doc
    $res = [ordered]@{ Status = 'Failed'; Error = ''; Final = $doc.Final; FreedGB = 0; Deleted = 0; Audio = '' }
    function Save-Doc([string]$state) {
        $doc.State = $state
        [IO.File]::WriteAllText($Cfg.FinalJson, ($doc | ConvertTo-Json -Depth 6), $script:Utf8)
    }
    function Invoke-Finalize {
      try {
        Write-Log "---- Finishing: $($doc.Variant) -> $($doc.Final)"
        $winner = $doc.Winner
        $winnerDir = [IO.Path]::GetDirectoryName($winner)
        if (-not $Cfg.NoAudio -and -not $doc.AudioDone) {
            if (-not [IO.File]::Exists($winner)) { $res.Error = "suggested encode not found: $winner"; Write-Log "FINISH FAILED: $($res.Error)"; return }
            $status.Step = 'adding audio (Add-BluRayAudio)'; Set-Status $status
            $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Cfg.AddAudio, '-Source', $doc.Source, '-Dest', $winner, '-Replace')
            $r = Invoke-Logged -Exe $Cfg.Exe -ArgList $a -TempDir $tmp -StatusBase $status -ProgressPattern '^\x00$'
            # Its own log goes to the Desktop; keep it with the title instead.
            foreach ($l in $r.Lines) {
                if ($l -match '^\s*Log saved to (.+?)\s*$' -and [IO.File]::Exists($Matches[1])) {
                    Move-Item -LiteralPath $Matches[1] -Destination (Join-Path $titleDir "$base.audio.log") -Force -ErrorAction SilentlyContinue
                }
            }
            if ($r.ExitCode -ne 0) { $res.Error = "Add-BluRayAudio exit $($r.ExitCode) (details above in this log)"; Write-Log "FINISH FAILED: $($res.Error); nothing moved or deleted"; return }
            $n = @(& ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 $winner 2>$null | Where-Object { "$_".Trim() }).Count
            if ($n -lt 1) { $res.Error = 'no audio track in the result'; Write-Log "FINISH FAILED: $($res.Error); nothing moved or deleted"; return }
            $res.Audio = "$n audio track(s)"
            Write-Log "Audio added: $n track(s)"
            $doc.AudioDone = $true
            Save-Doc 'audio added'
        }
        # Move up to the mirrored folder (with the subtitle backup).
        $status.Step = 'moving into place'; Set-Status $status
        if ([IO.File]::Exists($winner)) {
            if ([IO.File]::Exists($doc.Final)) { $res.Error = "$($doc.Final) already exists; not overwriting it"; Write-Log "FINISH FAILED: $($res.Error)"; return }
            Move-Item -LiteralPath $winner -Destination $doc.Final -ErrorAction Stop
            Write-Log "Moved to $($doc.Final)"
        } elseif (-not [IO.File]::Exists($doc.Final)) {
            $res.Error = "neither $winner nor $($doc.Final) exists"; Write-Log "FINISH FAILED: $($res.Error)"; return
        }
        $subs = Join-Path $winnerDir "$base.mks.originals"
        if ([IO.File]::Exists($subs)) { Move-Item -LiteralPath $subs -Destination (Join-Path $titleDir "$base.mks.originals") -Force -ErrorAction Stop }
        Save-Doc 'moved'
        # Delete this title's files in every variant folder (the other encodes, VMAF results,
        # leftovers), then any variant folder left empty.
        if (-not $Cfg.KeepVariants) {
            $status.Step = 'deleting the other variants'; Set-Status $status
            $bytes = 0L; $count = 0
            foreach ($d in @($Cfg.VariantDirs)) {
                if (-not [IO.Directory]::Exists($d)) { continue }
                foreach ($f in @([IO.Directory]::GetFiles($d))) {
                    $name = [IO.Path]::GetFileName($f)
                    if (-not $name.StartsWith("$base.", [StringComparison]::OrdinalIgnoreCase)) { continue }
                    $bytes += (New-Object IO.FileInfo $f).Length
                    Remove-Item -LiteralPath $f -Force -ErrorAction Stop
                    $count++
                }
                if (-not @([IO.Directory]::GetFileSystemEntries($d)).Count) { Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue }
            }
            $res.Deleted = $count
            $res.FreedGB = [Math]::Round($bytes / 1GB, 2)
            Write-Log ("Deleted {0} file(s) from the other variants, {1} GB freed" -f $count, $res.FreedGB)
        }
        Save-Doc 'done'
        $res.Status = 'Done'
      } catch {
        $res.Error = $_.Exception.Message
        Write-Log "FINISH FAILED: $($_.Exception.Message)"
        Write-LogRaw ($_.ScriptStackTrace)
      }
    }
    [void](Invoke-Finalize)
    'EB_RESULT:' + ([pscustomobject]$res | ConvertTo-Json -Depth 4 -Compress)
}

$PrepWorker = [scriptblock]::Create($WorkerHeader.ToString() + "`n" + $PrepBody.ToString())
$EncodeWorker = [scriptblock]::Create($WorkerHeader.ToString() + "`n" + $VariantCommon.ToString() + "`n" + $EncodeBody.ToString())
$VmafWorker = [scriptblock]::Create($WorkerHeader.ToString() + "`n" + $VariantCommon.ToString() + "`n" + $VmafBody.ToString())
$FinalizeWorker = [scriptblock]::Create($WorkerHeader.ToString() + "`n" + $FinalizeBody.ToString())

# =====================================================================================
# Orchestrator
# =====================================================================================
. $Helpers

function Resolve-UserPath([string]$Path) {
    # Tab completion escapes [ ] with backticks; accept both forms.
    foreach ($c in @($Path, ($Path -replace '`(.)', '$1'))) {
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($c)
        if ([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)) { return $full }
    }
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

$srcPath = Resolve-UserPath $Source
$sep = [IO.Path]::DirectorySeparatorChar
$dstRoot = (Resolve-UserPath $Dest).TrimEnd('\', '/')
if (-not ([IO.File]::Exists($srcPath) -or [IO.Directory]::Exists($srcPath))) { throw "Source not found: $srcPath" }
[void][IO.Directory]::CreateDirectory($dstRoot)

$script:LogPath = Join-Path $dstRoot "_encode-batch_$runId.log"
$script:EchoLog = $true
# Under Dest (not %TEMP%, which can be an 8.3 short path WSL can't resolve). Holds the small
# bash scripts handed to WSL, redirected tool output and the per-slot status files.
$tempDir = Join-Path (Join-Path $dstRoot '_encode-batch_tmp') $runId
[void][IO.Directory]::CreateDirectory($tempDir)

# ---------------------------------------------------------------- variants
$invalid = [IO.Path]::GetInvalidFileNameChars()
function ConvertTo-VariantSpec($v) {
    $argList = @()
    $name = ''
    if ($v.ContainsKey('Cqp')) { $argList += @('--cqp', [string]$v.Cqp); $name = "cqp$($v.Cqp)" }
    if ($v.ContainsKey('Aq') -and [int]$v.Aq -gt 0) {
        $argList += @('--aq', '--aq-strength', [string]$v.Aq); $name += " aq$($v.Aq)"
    } elseif (-not ($v.ContainsKey('AqTemporal') -and $v.AqTemporal)) {
        $argList += '--no-aq'
    }
    if ($v.ContainsKey('AqTemporal') -and $v.AqTemporal) { $argList += '--aq-temporal'; $name += ' aqt' }
    if ($v.ContainsKey('Extra') -and $v.Extra) {
        if ($v.Extra -is [string]) { $argList += @($v.Extra -split '\s+' | Where-Object { $_ }) } else { $argList += @($v.Extra) }
        $name += ' extra'
    }
    if ($v.ContainsKey('Name') -and $v.Name) { $name = [string]$v.Name }
    $name = $name.Trim()
    if (-not $v.ContainsKey('Cqp') -and -not ($v.ContainsKey('Extra') -and $v.Extra)) { throw "Variant needs Cqp (or a rate control in Extra): $(($v.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ')" }
    if (-not $name -or $name.IndexOfAny($invalid) -ge 0) { throw "Variant name '$name' isn't a valid folder name; set Name." }
    @{ Name = $name; Args = $argList }
}
$fixedMode = $null -ne $Variants -and $Variants.Count -gt 0
$specs = @()
foreach ($v in $(if ($fixedMode) { $Variants } else { $Ladder })) {
    $spec = ConvertTo-VariantSpec $v
    if (@($specs | Where-Object { $_.Name -eq $spec.Name }).Count) { throw "Two variants are both named '$($spec.Name)'; give one a Name." }
    $specs += $spec
}
if (-not $specs.Count) { throw 'No variants: -Ladder is empty.' }
if (-not $fixedMode -and $SkipVmaf) { throw 'The ladder search needs VMAF scores. Use -Variants (fixed mode) with -SkipVmaf.' }

# ---------------------------------------------------------------- preflight
Write-Log "Encode-Batch $runId" 'Cyan'
Write-Log "Source: $srcPath"
Write-Log "Dest:   $dstRoot ($(Get-FreeGB $dstRoot) GB free)"
if ($fixedMode) { Write-Log "Mode: fixed variants" } else { Write-Log "Mode: ladder search, target $TargetPct% of the source, cap $MaxPct% (rungs weakest first)" }
$ri = 0
foreach ($s in $specs) { Write-Log ("{0} '{1}': {2}" -f $(if ($fixedMode) { 'Variant' } else { "Rung $ri" }), $s.Name, ($s.Args -join ' ')); $ri++ }
Write-Log "Bar: mean >= $MinMean, p1 >= $MinP1, min >= $MinMin, video <= $MaxPct% of the source's"

Write-Log ("Slots: {0} encode (GPU){1}" -f $Threads, $(if ($SkipVmaf) { ', VMAF off' } else { ", $VmafThreads VMAF (CPU)" }))

foreach ($tool in 'ffprobe', 'ffmpeg') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool not found on PATH (needed for probing and CropDetect)." }
}
if (-not (Get-Command mediainfo -ErrorAction SilentlyContinue)) {
    Write-Log 'mediainfo not on PATH: Dolby Vision detection will rely on ffprobe alone.' 'Yellow'
}
if (-not [IO.File]::Exists($NVEncC)) { throw "NVEncC not found: $NVEncC" }
$CropDetect = Resolve-UserPath $CropDetect
if (-not [IO.File]::Exists($CropDetect)) { throw "CropDetect.ps1 not found: $CropDetect (pass -CropDetect)." }
if (-not (Select-String -LiteralPath $CropDetect -Pattern '\$Plumbing' -Quiet)) { throw "$CropDetect has no -Plumbing switch; use the updated CropDetect.ps1." }
# Catch a damaged copy (e.g. a stray character from copy/paste) now, not once per title.
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($CropDetect, [ref]$null, [ref]$parseErrors)
if ($parseErrors) {
    $pe = $parseErrors[0]
    throw ("{0} has a syntax error at line {1}, char {2}: {3}`n    {4}" -f $CropDetect, $pe.Extent.StartLineNumber, $pe.Extent.StartColumnNumber, $pe.Message, $pe.Extent.StartScriptPosition.Line.Trim())
}


$finishing = -not $fixedMode -and -not ($NoAudio -and $KeepVariants)
if (-not $fixedMode -and -not $NoAudio) {
    $AddBluRayAudio = Resolve-UserPath $AddBluRayAudio
    if (-not [IO.File]::Exists($AddBluRayAudio)) { throw "Add-BluRayAudio.ps1 not found: $AddBluRayAudio (pass -AddBluRayAudio, or -NoAudio)." }
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($AddBluRayAudio, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw ("{0} has a syntax error at line {1}: {2}" -f $AddBluRayAudio, $parseErrors[0].Extent.StartLineNumber, $parseErrors[0].Message) }
    if (-not (Get-Command mkvmerge -ErrorAction SilentlyContinue)) { throw 'mkvmerge not on PATH (Add-BluRayAudio needs it): add "C:\Program Files\MKVToolNix" to PATH, or use -NoAudio.' }
}
if (-not $fixedMode) {
    Write-Log ("Finishing: {0}" -f $(if (-not $finishing) { 'off (-NoAudio -KeepVariants)' } else {
        (@($(if (-not $NoAudio) { "audio with $AddBluRayAudio" }), 'move the pick up to the mirrored folder', $(if (-not $KeepVariants) { 'delete the other variants' })) | Where-Object { $_ }) -join ', ' }))
}

$wsl = @{ Distro = $WslDistro; MountRoot = $WslMountRoot; CompareEncodeCmd = $CompareEncodeCmd; DoviConvertCmd = $DoviConvertCmd; RemountCmd = $RemountCmd }
$doviAvailable = $false
$checkBody = @(
    "for c in $(ConvertTo-BashQuoted ($CompareEncodeCmd -split ' ')[0]) $(ConvertTo-BashQuoted ($DoviConvertCmd -split ' ')[0]) $(ConvertTo-BashQuoted ($RemountCmd -split ' ')[0]); do"
    '  if p=$(command -v "$c"); then echo "FOUND $c $p"; else echo "MISSING $c"; fi'
    'done'
) -join "`n"
$chk = Invoke-Wsl -Wsl $wsl -TempDir $tempDir -Body $checkBody -Quiet
foreach ($l in $chk.Lines) { Write-Log "WSL: $l" }
$found = @($chk.Lines | Where-Object { $_ -match '^FOUND ' } | ForEach-Object { ($_ -split ' ')[1] })
if (-not $SkipVmaf -and $found -notcontains ($CompareEncodeCmd -split ' ')[0]) {
    throw "compare_encode isn't reachable from a WSL login shell ('$CompareEncodeCmd'). If it's an alias, pass the script's full path with -CompareEncodeCmd, or use -SkipVmaf."
}
$doviAvailable = $found -contains ($DoviConvertCmd -split ' ')[0]

# The NAS mounts in WSL drop regularly. Check now, while you're still at the keyboard, rather
# than finding out from a log in the morning.
function Test-WslSees([string[]]$Paths) {
    $body = (@($Paths | ForEach-Object { 'if [ -e {0} ]; then echo "OK {1}"; else echo "MISSING {1}"; fi' -f (ConvertTo-BashQuoted (ConvertTo-WslPath $_ $WslMountRoot)), $_ })) -join "`n"
    @((Invoke-Wsl -Wsl $wsl -TempDir $tempDir -Body $body -Quiet).Lines | Where-Object { $_ -like 'MISSING *' } | ForEach-Object { $_.Substring(8) })
}
$mustSee = @($srcPath, $dstRoot)
$missing = Test-WslSees $mustSee
$deadline = (Get-Date).AddSeconds(90)
while ($missing.Count -and (Get-Date) -lt $deadline) {
    $bar = '!' * 78
    Write-Host ''
    Write-Host $bar -ForegroundColor Red
    Write-Host '  WSL CAN''T SEE THESE PATHS (NAS mount dropped?):' -ForegroundColor Red
    foreach ($m in $missing) { Write-Host "    $m" -ForegroundColor Yellow }
    Write-Host '  VMAF scoring and Dolby Vision conversion run inside WSL and will fail.' -ForegroundColor Red
    Write-Host '  Run "remount" in WSL now, then press Enter to check again.' -ForegroundColor Red
    Write-Host '  Ctrl+C cancels. Continuing anyway in 90 s.' -ForegroundColor Red
    Write-Host $bar -ForegroundColor Red
    $pressed = $false
    while (-not $pressed -and (Get-Date) -lt $deadline) {
        try { if ([Console]::KeyAvailable) { $k = [Console]::ReadKey($true); if ($k.Key -eq 'Enter') { $pressed = $true } } } catch { }
        Start-Sleep -Milliseconds 200
    }
    $missing = Test-WslSees $mustSee
    if (-not $missing.Count) { Write-Log 'WSL can see Source and Dest now.' 'Green' }
}
if ($missing.Count) { Write-Log "WARNING: WSL still can't see: $($missing -join ', '). Continuing; each WSL step will try $RemountCmd once." 'Red' }
else { Write-Log 'WSL can see Source and Dest.' }
if (-not $doviAvailable) { Write-Log "dovi_convert not reachable from WSL; Dolby Vision 7 titles will be skipped." 'Yellow' }
if ($found -notcontains ($RemountCmd -split ' ')[0]) { Write-Log "remount not reachable from WSL; dropped NAS mounts can't be repaired automatically." 'Yellow' }

# ---------------------------------------------------------------- find sources
if ([IO.File]::Exists($srcPath)) {
    $srcRoot = [IO.Path]::GetDirectoryName($srcPath)
    $files = @(Get-Item -LiteralPath $srcPath)
} else {
    $srcRoot = $srcPath.TrimEnd('\', '/')
    $files = @(Get-ChildItem -LiteralPath $srcRoot -Recurse -File -Filter '*.mkv' | Where-Object {
        $_.Extension -eq '.mkv' -and
        -not $_.FullName.StartsWith($dstRoot + $sep, [StringComparison]::OrdinalIgnoreCase) -and
        $_.Name -notmatch ' - p7 source\.mkv$| - p8\.1\.mkv$|\.partial\.mkv$'
    } | Sort-Object FullName)
}
Write-Log "Found $($files.Count) .mkv file(s)." 'Cyan'
if (-not $files.Count) { return }

$titleList = New-Object System.Collections.Generic.List[object]
foreach ($f in $files) {
    $rel = $f.DirectoryName.Substring([Math]::Min($srcRoot.Length, $f.DirectoryName.Length)).TrimStart('\', '/')
    $titleDir = if ($rel) { Join-Path $dstRoot $rel } else { $dstRoot }
    $base = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    $titleList.Add([pscustomobject]@{
        File = $f.FullName; Rel = $(if ($rel) { Join-Path $rel $f.Name } else { $f.Name })
        TitleDir = $titleDir; Base = $base; LogPath = (Join-Path $titleDir "$base.encode.log")
        Folder = $f.DirectoryName   # titles in the same source folder share ladder starting points
        Order = $titleList.Count
        State = 'queued'          # queued -> prepping -> ready -> done | skipped | failed
        Info = $null; Prep = $null; Tasks = @(); Start = $null; Reason = ''; StartRungs = $null; WaitingOn = ''; Seeded = $false; Skipped = @{}; SkipLogged = @()
        Finalize = ''; FinalDoc = $null; FinalJson = (Join-Path $titleDir "$base.final.json")
    })
}

# ---------------------------------------------------------------- run
$results = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[object]
$finished = New-Object System.Collections.Generic.List[object]
$running = @{}                       # job id -> info
$slots = New-Object object[] $Threads
$vmafSlots = New-Object object[] $VmafThreads
$stopDispatch = $false
$prepStatusFile = Join-Path $tempDir 'prep.json'
$folderSeed = @{}                    # source folder -> rung index the last finished title there picked
$folderRef = @{}                     # source folder -> @{ Name; Pick; Rows } (see Set-FolderMemory)
$specNames = @($specs | ForEach-Object { $_.Name })
$maxActive = $Threads + 2            # searches from scratch prepped or in progress at once (fixed mode: titles)

function New-Row($spec, [string]$file) {
    [pscustomobject][ordered]@{
        Name = $spec.Name; Status = 'Failed'; Error = ''; File = $file; EncodeSec = $null
        Mean = $null; P1 = $null; Min = $null; VideoGB = $null; Pct = $null; Mbps = $null
        Model = ''; Warning = $false; Pass = $false; OverCap = $false; Dominated = $false; Suggested = $false; Hint = ''
    }
}

# A variant is finished when its encode exists and (unless -SkipVmaf) its .vmaf.txt has a score.
# Returns the row for a finished variant, or $null.
function Get-FinishedRow($t, $spec) {
    $vdir = Join-Path $t.TitleDir $spec.Name
    $file = Join-Path $vdir "$($t.Base).mkv"
    if (-not [IO.File]::Exists($file)) { return $null }
    $row = New-Row $spec $file
    if ($SkipVmaf) { $row.Status = 'Done'; return $row }
    $vf = Join-Path $vdir "$($t.Base).vmaf.txt"
    if (-not [IO.File]::Exists($vf)) { return $null }
    $vm = Read-VmafResult ([IO.File]::ReadAllLines($vf))
    if ($null -eq $vm.Mean) { return $null }
    foreach ($k in 'Mean', 'P1', 'Min', 'VideoGB', 'Pct', 'Mbps', 'Model', 'Warning') { $row.$k = $vm.$k }
    $row.Status = 'Done'
    $row
}

function Add-Skip($t, [string]$reason) {
    $t.State = 'skipped'; $t.Reason = $reason
    $skipped.Add([pscustomobject]@{ Title = $t.Rel; Reason = $reason })
    Write-Log "SKIP  $($t.Rel): $reason" 'DarkYellow'
}

function Get-RungIndex([string]$name) {
    for ($i = 0; $i -lt $specs.Count; $i++) { if ($specs[$i].Name -eq $name) { return $i } }
    -1
}

# Ladder state of a title: rung index -> finished row, or $null while queued/encoding/scoring.
function Get-Tried($t) {
    $h = @{}
    foreach ($task in $t.Tasks) { $h[[int]$task.Rung] = $(if ($task.State -eq 'done') { $task.Row } else { $null }) }
    $h
}

# One ladder step that also skips rungs the folder's reference title already answered (adds them
# to $Skipped, rung -> reason). Used for running titles and for the "finished on disk?" check.
function Get-LadderStepFor([hashtable]$Tried, $Start, [string]$Folder, [string]$Self, [hashtable]$Skipped) {
    $ref = if ($folderRef.ContainsKey($Folder) -and $folderRef[$Folder].Name -ne $Self) { $folderRef[$Folder] } else { $null }
    while ($true) {
        $i = Get-LadderNext -Tried $Tried -Count $specs.Count -Start $Start -MinMean $MinMean -MinP1 $MinP1 -MinMin $MinMin -MaxPct $MaxPct -TargetPct $TargetPct -Skip $Skipped
        if ($i -lt 0 -or -not $ref) { return $i }
        $why = Get-KnownRungReason -Ref $ref -Tried $Tried -Rung $i -Names $specNames -MinMean $MinMean -MinP1 $MinP1 -MinMin $MinMin -MaxPct $MaxPct -SimilarPct $SimilarPct -SimilarVmaf $SimilarVmaf
        if (-not $why) { return $i }
        $Skipped[$i] = $why
    }
}

function Get-LadderStep($t) {
    $before = $t.Skipped.Count
    $i = Get-LadderStepFor (Get-Tried $t) $t.StartRungs $t.Folder $t.Base $t.Skipped
    if ($t.Skipped.Count -gt $before) {
        foreach ($k in @($t.Skipped.Keys)) {
            if ($t.SkipLogged -contains $k) { continue }
            $t.SkipLogged += $k
            Add-LogText $t.LogPath ("{0:yyyy-MM-dd HH:mm:ss}  LADDER: {1}`r`n" -f (Get-Date), $t.Skipped[$k])
            Write-Log ("KNOWN {0}: {1}" -f $t.Rel, $t.Skipped[$k]) 'DarkCyan'
        }
    }
    $i
}

# Folder memory after a title finishes: $folderSeed = its pick (where the next titles start);
# $folderRef = the title whose neighbouring rungs later titles may skip (only replaced by a title
# that itself tried a neighbour of its pick, or that picked a different rung).
function Set-FolderMemory([string]$Folder, [string]$Name, [hashtable]$Rows, [int]$Pick) {
    $folderSeed[$Folder] = $Pick
    $triedNeighbour = $Rows.ContainsKey($Pick - 1) -or $Rows.ContainsKey($Pick + 1)
    $old = if ($folderRef.ContainsKey($Folder)) { $folderRef[$Folder] } else { $null }
    if ($triedNeighbour -or -not $old -or $old.Pick -ne $Pick) {
        $folderRef[$Folder] = @{ Name = $Name; Pick = $Pick; Rows = $Rows }
    }
}

# A title that has to wait before it can start: ladder mode, nothing started yet, its folder has no
# pick yet, and an earlier title in the same folder is still being prepped or searched. Returns
# that earlier title (or $null). It starts from that title's final pick once it finishes, so
# titles in one folder don't each spend encodes finding the same answer. If it finishes without
# a pass, the next title in the folder searches from scratch and the rest wait on that one.
function Get-WaitingOn($t) {
    if ($fixedMode -or @($t.Tasks).Count -or $folderSeed.ContainsKey($t.Folder)) { return $null }
    foreach ($o in $titleList) {
        if ($o.Order -ge $t.Order) { break }
        if ($o.Folder -eq $t.Folder -and ($o.State -eq 'prepping' -or $o.State -eq 'ready')) { return $o }
    }
    $null
}

# A prepped / in-progress title that is (or will be) searching the ladder from scratch, as opposed
# to one starting from its folder's pick or waiting for one. Only these count against the cap.
function Test-Searching($t) {
    if ($t.State -ne 'prepping' -and $t.State -ne 'ready') { return $false }
    if ($fixedMode) { return $true }
    if ($null -ne $t.StartRungs) { return -not $t.Seeded }
    -not $folderSeed.ContainsKey($t.Folder) -and -not (Get-WaitingOn $t)
}

# Where a title's search starts, decided when an encoder slot first asks for it. $null = wait.
function Get-StartRungs($t) {
    $mid = [int][Math]::Floor(($specs.Count - 1) / 2)
    if ($folderSeed.ContainsKey($t.Folder)) { return @{ Rungs = @($folderSeed[$t.Folder]); Seeded = $true; Why = 'pick of the last finished title in this folder' } }
    $w = Get-WaitingOn $t
    if ($w) {
        if ($t.WaitingOn -ne $w.Base) {
            $t.WaitingOn = $w.Base
            Write-Log ("WAIT  {0}: starts from the pick of {1} once it finishes" -f $t.Rel, $w.Base) 'DarkCyan'
        }
        return $null
    }
    if ($Threads -lt 2 -or $specs.Count -lt 3) { return @{ Rungs = @($mid); Why = 'middle rung' } }
    @{ Rungs = @([Math]::Max(0, $mid - 1), [Math]::Min($specs.Count - 1, $mid + 1)); Why = 'no pick in this folder yet: one rung either side of the middle' }
}

# The next task an encoder slot should take from this title, creating it in ladder mode. $null if none now.
function Get-NextTask($t) {
    $next = @($t.Tasks | Where-Object { $_.State -eq 'pending' } | Select-Object -First 1)
    if ($next.Count) { return $next[0] }
    if ($fixedMode) { return $null }
    if ($null -eq $t.StartRungs) {
        if (@($t.Tasks).Count) { $t.StartRungs = @() }
        else {
            $st = Get-StartRungs $t
            if (-not $st) { return $null }
            $t.StartRungs = @($st.Rungs)
            $t.Seeded = [bool]$st.Seeded
            Write-Log ("START {0}: {1} ({2})" -f $t.Rel, (($t.StartRungs | ForEach-Object { $specs[$_].Name }) -join ' + '), $st.Why) 'Cyan'
            Add-LogText $t.LogPath ("{0:yyyy-MM-dd HH:mm:ss}  LADDER: start with {1} ({2})`r`n" -f (Get-Date), (($t.StartRungs | ForEach-Object { $specs[$_].Name }) -join ' + '), $st.Why)
        }
    }
    $i = Get-LadderStep $t
    if ($i -lt 0) { return $null }
    $task = [pscustomobject]@{ Spec = $specs[$i]; Rung = $i; Index = @($t.Tasks).Count + 1; State = 'pending'; Row = $null }
    $t.Tasks = @($t.Tasks) + $task
    if (@($t.Tasks).Count -gt @($t.StartRungs).Count) {
        Add-LogText $t.LogPath ("{0:yyyy-MM-dd HH:mm:ss}  LADDER: next rung {1}`r`n" -f (Get-Date), $specs[$i].Name)
        Write-Log ("NEXT  {0}: {1}" -f $t.Rel, $specs[$i].Name) 'Cyan'
    }
    $task
}

# True when nothing is left to do for a ready title.
function Test-TitleFinished($t) {
    if (@($t.Tasks | Where-Object { $_.State -ne 'done' }).Count) { return $false }
    if ($fixedMode) { return $true }
    if ($null -eq $t.StartRungs -and -not @($t.Tasks).Count) { return $false }
    (Get-LadderStep $t) -eq -2
}

function Get-TaskLabel($t, $task) {
    if ($fixedMode) { 'variant {0}/{1}' -f $task.Index, @($t.Tasks).Count } else { 'try {0}' -f $task.Index }
}

# Ladder-limit notes on the pick, and the folder's starting point for the next title.
function Set-LadderHint($t, $rows, [string]$sugg) {
    if (-not $sugg) { return }
    $pick = @($rows | Where-Object { $_.Name -eq $sugg })[0]
    if ($fixedMode) {
        if ($null -ne $pick.Pct -and $pick.Pct -lt $TargetPct) { $pick.Hint = "under $TargetPct%: try a lower CQP / more AQ" }
        return
    }
    $i = Get-RungIndex $sugg
    $byRung = @{}
    foreach ($task in $t.Tasks) { if ($task.State -eq 'done' -and $task.Row) { $byRung[[int]$task.Rung] = $task.Row } }
    Set-FolderMemory $t.Folder $t.Base $byRung $i
    if ($null -ne $pick.Pct -and $pick.Pct -lt $TargetPct -and $i -eq $specs.Count - 1) { $pick.Hint = "under $TargetPct% at the strongest rung: add a lower-CQP rung" }
    elseif ($null -ne $pick.Pct -and $pick.Pct -gt $TargetPct -and $i -eq 0) { $pick.Hint = "over $TargetPct% at the weakest rung: a higher-CQP rung may pass smaller" }
}

function Get-VariantDirs($t) { @($specs | ForEach-Object { Join-Path $t.TitleDir $_.Name }) }

# Queues the finish (audio, move up, delete the rest) for a title with a suggested variant.
function Request-Finalize($t, $rows, [string]$sugg) {
    $doc = [ordered]@{
        Title = $t.Rel; Source = $t.File; Variant = $sugg
        Winner = (Join-Path (Join-Path $t.TitleDir $sugg) "$($t.Base).mkv")
        Final = (Join-Path $t.TitleDir "$($t.Base).mkv")
        AudioDone = [bool]$NoAudio; State = 'pending'; Variants = @($rows)
    }
    [IO.File]::WriteAllText($t.FinalJson, ($doc | ConvertTo-Json -Depth 6), $script:Utf8)
    $t.FinalDoc = [pscustomobject]$doc
    $t.Finalize = 'pending'
}

# Folder memory from a finished title's saved rows (results / final.json), by variant name.
function Set-FolderMemoryFromRows($t, $rows, [string]$pick) {
    $byRung = @{}
    foreach ($r in @($rows)) { $i = Get-RungIndex $r.Name; if ($i -ge 0) { $byRung[$i] = $r } }
    $pi = Get-RungIndex $pick
    if ($pi -ge 0) { Set-FolderMemory $t.Folder $t.Base $byRung $pi }
}

function Complete-Title($t) {
    $rows = @($t.Tasks | Sort-Object $(if ($fixedMode) { 'Index' } else { 'Rung' }) | ForEach-Object { $_.Row })
    $sugg = $null
    if (-not $SkipVmaf) {
        $sugg = Set-Suggestion -Rows $rows -MinMean $MinMean -MinP1 $MinP1 -MinMin $MinMin -MaxPct $MaxPct -TargetPct $TargetPct
        Set-LadderHint $t $rows $sugg
    }
    $hint = if ($sugg) { @($rows | Where-Object { $_.Suggested })[0].Hint } else { '' }
    $done = @($rows | Where-Object { $_.Status -eq 'Done' }).Count
    $st = if ($done -eq $rows.Count) { 'Done' } elseif ($done) { 'Partial' } else { 'Failed' }
    $t.State = 'done'
    $secs = if ($t.Start) { [int]((Get-Date) - $t.Start).TotalSeconds } else { 0 }
    $res = [pscustomobject][ordered]@{
        Title = $t.Rel; Status = $st; Reason = $(if ($st -ne 'Done') { "$done of $($rows.Count) variants finished" } else { '' })
        Suggested = $sugg; Hint = $hint; Variants = $rows; Seconds = $secs; LogPath = $t.LogPath
    }
    $results.Add($res)

    $verdict = if ($sugg) { $sugg + $(if ($hint) { " ($hint)" } else { '' }) } elseif ($done) { 'none - no variant passes within the cap, keep the original' } else { 'none' }
    $lines = @('', ('{0:yyyy-MM-dd HH:mm:ss}  Bar: mean >= {1}, p1 >= {2}, min >= {3}, size <= {4}%, target {5}%. Suggested: {6}' -f `
        (Get-Date), $MinMean, $MinP1, $MinMin, $MaxPct, $TargetPct, $verdict))
    $lines += Format-VariantTable $rows
    foreach ($k in @($t.Skipped.Keys | Sort-Object)) { $lines += "  ($($t.Skipped[$k]))" }
    $lines += ('{0:yyyy-MM-dd HH:mm:ss}  RESULT: {1}{2}' -f (Get-Date), $st, $(if ($res.Reason) { " - $($res.Reason)" } else { '' }))
    Add-LogText $t.LogPath (($lines -join "`r`n") + "`r`n")
    [IO.File]::WriteAllText((Join-Path $t.TitleDir "$($t.Base).results.json"), ($res | ConvertTo-Json -Depth 5), $script:Utf8)
    if ($finishing -and $sugg) { Request-Finalize $t $rows $sugg }
    elseif ($finishing -and -not $SkipVmaf) { Add-LogText $t.LogPath ("{0:yyyy-MM-dd HH:mm:ss}  No suggested variant: all variants kept for review.`r`n" -f (Get-Date)) }

    $color = switch ($st) { 'Done' { 'Green' } 'Partial' { 'Yellow' } default { 'Red' } }
    $msg = "TITLE {0}: {1} in {2}, {3} encode(s)" -f $t.Rel, $st, [TimeSpan]::FromSeconds($secs), $rows.Count
    if (-not $SkipVmaf -and $done) { $msg += " - suggested: $verdict" }
    if ($res.Reason) { $msg += " - $($res.Reason)" }
    Write-Log $msg $(if ($color -eq 'Green' -and -not $sugg -and -not $SkipVmaf) { 'Yellow' } else { $color })
}

function Start-Prep($t) {
    $t.State = 'prepping'; $t.Start = Get-Date
    Remove-Item -LiteralPath $prepStatusFile -Force -ErrorAction SilentlyContinue
    $cfg = @{
        Helpers = $Helpers.ToString(); EnvPath = $env:PATH; RunId = $runId
        SourceFile = $t.File; BaseName = $t.Base; TitleDir = $t.TitleDir; LogPath = $t.LogPath
        StatusFile = $prepStatusFile; TempDir = $tempDir; Info = $t.Info; Wsl = $wsl
        CropDetect = $CropDetect; MinFreeDoviGB = $MinFreeDoviGB
    }
    $job = Start-Job -ScriptBlock $PrepWorker -ArgumentList ($cfg | ConvertTo-Json -Depth 6 -Compress)
    $running[$job.Id] = [pscustomobject]@{ Job = $job; Kind = 'prep'; Title = $t; Task = $null; Slot = -1; Start = Get-Date; StatusFile = $prepStatusFile }
}

function Start-Finalize($t) {
    $t.Finalize = 'running'
    $statusFile = Join-Path $tempDir 'finish.json'
    Remove-Item -LiteralPath $statusFile -Force -ErrorAction SilentlyContinue
    $cfg = @{
        Helpers = $Helpers.ToString(); EnvPath = $env:PATH; RunId = $runId
        BaseName = $t.Base; TitleDir = $t.TitleDir; LogPath = $t.LogPath; StatusFile = $statusFile; TempDir = $tempDir; Wsl = $wsl
        Doc = $t.FinalDoc; FinalJson = $t.FinalJson; VariantDirs = (Get-VariantDirs $t)
        AddAudio = $AddBluRayAudio; Exe = (Get-Process -Id $PID).Path; NoAudio = [bool]$NoAudio; KeepVariants = [bool]$KeepVariants
    }
    $job = Start-Job -ScriptBlock $FinalizeWorker -ArgumentList ($cfg | ConvertTo-Json -Depth 8 -Compress)
    $running[$job.Id] = [pscustomobject]@{ Job = $job; Kind = 'finalize'; Title = $t; Task = $null; Slot = -1; Start = Get-Date; StatusFile = $statusFile; Label = 'FINISH' }
    Write-Log ("FINISH {0} :: {1}" -f $t.Rel, $t.FinalDoc.Variant) 'Green'
}

function Start-Variant($t, $task, [int]$slot, [string]$kind) {
    $task.State = $(if ($kind -eq 'encode') { 'encoding' } else { 'scoring' })
    $statusFile = Join-Path $tempDir "$kind$slot.json"
    Remove-Item -LiteralPath $statusFile -Force -ErrorAction SilentlyContinue
    $cfg = @{
        Helpers = $Helpers.ToString(); EnvPath = $env:PATH; RunId = $runId
        BaseName = $t.Base; TitleDir = $t.TitleDir; LogPath = $t.LogPath; StatusFile = $statusFile; TempDir = $tempDir
        Info = $t.Info; WorkSrc = $t.Prep.WorkSrc; IsDv81 = $t.Prep.IsDv81; Crop = $t.Prep.Crop
        Variant = $task.Spec; Index = $task.Index; Count = @($t.Tasks).Count; Label = (Get-TaskLabel $t $task)
        Decoder = $Decoder; NVEncC = $NVEncC; Wsl = $wsl; SkipVmaf = [bool]$SkipVmaf
    }
    if ($kind -eq 'encode') {
        $job = Start-Job -ScriptBlock $EncodeWorker -ArgumentList ($cfg | ConvertTo-Json -Depth 6 -Compress)
        $slots[$slot] = $job.Id
        $label = 'ENCODE [{0}]' -f ($slot + 1)
    } else {
        $job = Start-Job -ScriptBlock $VmafWorker -ArgumentList ($cfg | ConvertTo-Json -Depth 6 -Compress)
        $vmafSlots[$slot] = $job.Id
        $label = 'VMAF   [V{0}]' -f ($slot + 1)
    }
    $running[$job.Id] = [pscustomobject]@{ Job = $job; Kind = $kind; Title = $t; Task = $task; Slot = $slot; Start = Get-Date; StatusFile = $statusFile; Label = $label }
    Write-Log ("{0} {1} :: {2} ({3})" -f $label, $t.Rel, $task.Spec.Name, (Get-TaskLabel $t $task)) 'Green'
}

# Picks the next title to prepare, skipping (without starting a job) titles that are finished,
# unsupported, or that the disk can't take. Returns $null when nothing should be prepped now.
function Get-NextPrepTitle {
    foreach ($t in $titleList) {
        if ($t.State -ne 'queued') { continue }
        if ($fixedMode) {
            $all = @($specs | ForEach-Object { Get-FinishedRow $t $_ })
            if (@($all | Where-Object { $_ }).Count -eq $specs.Count) { Add-Skip $t 'all variants already finished'; continue }
        } else {
            # Finished (or being finished) by an earlier run: final.json.
            if ([IO.File]::Exists($t.FinalJson)) {
                $fd = $null
                try { $fd = [IO.File]::ReadAllText($t.FinalJson) | ConvertFrom-Json } catch { }
                if ($fd -and $fd.Variant) {
                    Set-FolderMemoryFromRows $t $fd.Variants $fd.Variant
                    if ($fd.State -eq 'done') { Add-Skip $t "finished: $($fd.Variant) -> $($fd.Final)"; continue }
                    if ($finishing) {
                        $t.FinalDoc = $fd; $t.Finalize = 'pending'; $t.State = 'done'
                        Write-Log "RESUME finishing $($t.Rel) ($($fd.State)): $($fd.Variant)" 'Cyan'
                        continue
                    }
                }
            }
            # Search already finished on disk? Then skip, but let its pick seed the folder.
            $tried = @{}
            for ($i = 0; $i -lt $specs.Count; $i++) { $fr = Get-FinishedRow $t $specs[$i]; if ($fr) { $tried[$i] = $fr } }
            if ($tried.Count -and (Get-LadderStepFor $tried @() $t.Folder $t.Base @{}) -eq -2) {
                $best = Set-Suggestion -Rows @($tried.Values) -MinMean $MinMean -MinP1 $MinP1 -MinMin $MinMin -MaxPct $MaxPct -TargetPct $TargetPct
                if ($best -and $finishing) {
                    # Searched by an earlier run but not finished: finish it now (no prep needed).
                    $tasks = @(); foreach ($k in @($tried.Keys | Sort-Object)) { $tasks += [pscustomobject]@{ Spec = $specs[$k]; Rung = [int]$k; Index = $tasks.Count + 1; State = 'done'; Row = $tried[$k] } }
                    $t.Tasks = $tasks; $t.StartRungs = @(); $t.State = 'ready'
                    Write-Log "DONE  $($t.Rel): ladder search already finished on disk" 'Cyan'
                    Complete-Title $t
                    continue
                }
                if ($best) { Set-FolderMemory $t.Folder $t.Base $tried (Get-RungIndex $best) }
                Add-Skip $t ("ladder search already finished ({0})" -f $(if ($best) { "suggested: $best" } else { 'no rung passed' }))
                continue
            }
        }
        # The cap (-Threads + 2) only limits searches from scratch. A title whose folder already has
        # a pick is cheap and goes first (titles are taken in order, so e.g. the rest of Season 01
        # before anything from Season 02+). A title that would only wait for a folder-mate's pick
        # is prepped one ahead per folder, so it can start the moment the pick lands.
        if (-not $fixedMode -and $folderSeed.ContainsKey($t.Folder)) { }
        elseif (Get-WaitingOn $t) {
            if (@($titleList | Where-Object { $_.Folder -eq $t.Folder -and ($_.State -eq 'prepping' -or $_.State -eq 'ready') -and -not @($_.Tasks).Count }).Count) { continue }
        } elseif (@($titleList | Where-Object { Test-Searching $_ }).Count -ge $maxActive) { continue }

        try { $t.Info = Get-SourceInfo $t.File } catch { Add-Skip $t "probe failed: $($_.Exception.Message)"; continue }
        $info = $t.Info
        if ($SkipVC1 -and $info.Codec -eq 'vc1') { Add-Skip $t 'VC-1 source (-SkipVC1)'; continue }
        if ($info.Dv -ne 'None' -and $info.Dv -ne 'P7' -and $info.Dv -ne 'P8.1') { Add-Skip $t "unsupported Dolby Vision: $($info.Dv) [$($info.DvDetail)]"; continue }
        if ($info.Dv -eq 'P7' -and -not $doviAvailable) { Add-Skip $t 'Dolby Vision 7 but dovi_convert is unavailable'; continue }

        [void][IO.Directory]::CreateDirectory($t.TitleDir)
        $free = Get-FreeGB $t.TitleDir
        if ($free -lt $MinFreeGB) {
            $script:stopDispatch = $true
            Write-Log "Only $free GB free on $dstRoot (< $MinFreeGB GB): not starting any more titles." 'Red'
            return $null
        }
        if ($info.Dv -eq 'P7' -and $free -lt $MinFreeDoviGB -and -not [IO.File]::Exists((Join-Path $t.TitleDir "$($t.Base) - p8.1.mkv"))) {
            Add-Skip $t "Dolby Vision 7 needs $MinFreeDoviGB GB free, have $free GB"; continue
        }
        Write-Log ("PREP  {0}  ({1}{2}, {3} GB free)  log: {4}" -f $t.Rel, $info.Codec,
            $(if ($info.Dv -ne 'None') { ", DV $($info.Dv)" } elseif ($info.Hdr) { ', HDR' } else { '' }), $free, $t.LogPath) 'Cyan'
        return $t
    }
    $null
}

function Test-MoreWork {
    if ($running.Count) { return $true }
    foreach ($t in $titleList) {
        if ($t.State -eq 'ready' -or $t.Finalize -eq 'pending') { return $true }
        if ($t.State -eq 'queued' -and -not $stopDispatch) { return $true }
    }
    $false
}

try {
    while (Test-MoreWork) {

        # ---- collect finished jobs
        foreach ($id in @($running.Keys)) {
            $r = $running[$id]
            if ($r.Job.State -notin 'Completed', 'Failed', 'Stopped') { continue }
            $jobErr = $null
            $out = @(Receive-Job -Job $r.Job -ErrorAction SilentlyContinue -ErrorVariable jobErr)
            Remove-Job -Job $r.Job -Force
            $running.Remove($id)
            $res = $null
            $resLine = $out | Where-Object { $_ -is [string] -and $_.StartsWith('EB_RESULT:') } | Select-Object -Last 1
            if ($resLine) { try { $res = $resLine.Substring(10) | ConvertFrom-Json } catch { } }
            $why = if ($jobErr) { ($jobErr | Select-Object -First 1).ToString() } else { "job ended in state $($r.Job.State) without a result" }
            $t = $r.Title

            if ($r.Kind -eq 'prep') {
                Write-Progress -Id 99 -Activity "Preparing $($t.Rel)" -Completed
                if (-not $res) { $res = [pscustomobject]@{ Status = 'Failed'; Reason = $why } }
                if ($res.Status -ne 'Ready') {
                    $t.State = $(if ($res.Status -eq 'Skipped') { 'skipped' } else { 'failed' }); $t.Reason = $res.Reason
                    $results.Add([pscustomobject]@{ Title = $t.Rel; Status = $res.Status; Reason = $res.Reason; Suggested = $null; Variants = @()
                                                    Seconds = [int]((Get-Date) - $t.Start).TotalSeconds; LogPath = $t.LogPath })
                    Write-Log "TITLE $($t.Rel): $($res.Status) - $($res.Reason)" $(if ($res.Status -eq 'Skipped') { 'DarkYellow' } else { 'Red' })
                    continue
                }
                $t.Prep = $res
                $tasks = @()
                for ($i = 0; $i -lt $specs.Count; $i++) {
                    $spec = $specs[$i]
                    $fin = Get-FinishedRow $t $spec
                    $state = 'pending'; $row = $fin
                    if ($fin) { $state = 'done' }
                    elseif (-not $SkipVmaf -and [IO.File]::Exists((Join-Path (Join-Path $t.TitleDir $spec.Name) "$($t.Base).mkv"))) {
                        $state = 'encoded'; $row = New-Row $spec (Join-Path (Join-Path $t.TitleDir $spec.Name) "$($t.Base).mkv")   # encode kept from an earlier run
                    } elseif (-not $fixedMode) { continue }   # ladder: only rungs an earlier run already started
                    $tasks += [pscustomobject]@{ Spec = $spec; Rung = $i; Index = $tasks.Count + 1; State = $state; Row = $row }
                }
                $t.Tasks = $tasks
                if (-not $fixedMode -and $tasks.Count) { $t.StartRungs = @(); $t.Seeded = $folderSeed.ContainsKey($t.Folder) }   # resume the search from what's on disk
                $t.State = 'ready'
                $todo = @($tasks | Where-Object { $_.State -eq 'pending' }).Count
                $toScore = @($tasks | Where-Object { $_.State -eq 'encoded' }).Count
                $reused = @($tasks | Where-Object { $_.State -eq 'done' }).Count
                if ($fixedMode) {
                    Write-Log ("READY {0}: crop {1}x{2}, {3} of {4} variants to encode{5}" -f $t.Rel, $res.Crop.Width, $res.Crop.Height, $todo, $tasks.Count,
                        $(if ($toScore) { ", $toScore already encoded to score" } else { '' })) 'Cyan'
                } else {
                    Write-Log ("READY {0}: crop {1}x{2}{3}" -f $t.Rel, $res.Crop.Width, $res.Crop.Height,
                        $(if ($tasks.Count) { ", resuming: $reused rung(s) finished, $toScore to score" } else { '' })) 'Cyan'
                }
                if (Test-TitleFinished $t) { Complete-Title $t }
            } elseif ($r.Kind -eq 'finalize') {
                Write-Progress -Id 21 -Activity 'finish' -Completed
                if (-not $res) { $res = [pscustomobject]@{ Status = 'Failed'; Error = $why; FreedGB = 0; Deleted = 0; Final = $t.FinalDoc.Final } }
                $t.Finalize = $res.Status
                $finished.Add([pscustomobject]@{ Title = $t.Rel; Variant = $t.FinalDoc.Variant; Status = $res.Status; Final = $res.Final; FreedGB = $res.FreedGB; Error = $res.Error })
                if ($res.Status -eq 'Done') {
                    Write-Log ("FINISHED {0}: {1} -> {2}{3}" -f $t.Rel, $t.FinalDoc.Variant, $res.Final,
                        $(if ($res.Deleted) { ", other variants deleted ($($res.Deleted) file(s), $($res.FreedGB) GB)" } else { '' })) 'Green'
                } else {
                    Write-Log ("FINISH FAILED {0}: {1} (variants kept; see {2})" -f $t.Rel, $res.Error, $t.LogPath) 'Red'
                }
                continue
            } elseif ($r.Kind -eq 'encode') {
                $slots[$r.Slot] = $null
                Write-Progress -Id ($r.Slot + 1) -Activity 'encode' -Completed
                if (-not $res) { $res = New-Row $r.Task.Spec ''; $res.Error = $why }
                $r.Task.Row = $res
                $r.Task.State = $(if ($res.Status -eq 'Encoded') { 'encoded' } else { 'done' })
                $msg = "ENCODED [{0}] {1} :: {2}: {3}" -f ($r.Slot + 1), $t.Rel, $res.Name, $res.Status
                if ($null -ne $res.EncodeSec) { $msg += " in $([TimeSpan]::FromSeconds([int]$res.EncodeSec))" }
                if ($res.Error) { $msg += " - $($res.Error)" }
                Write-Log $msg $(if ($res.Status -eq 'Failed') { 'Red' } else { 'Green' })
            } else {
                $vmafSlots[$r.Slot] = $null
                Write-Progress -Id ($r.Slot + 11) -Activity 'vmaf' -Completed
                if (-not $res) { $res = New-Row $r.Task.Spec ''; $res.Error = $why }
                if ($r.Task.Row -and $null -ne $r.Task.Row.EncodeSec) { $res.EncodeSec = $r.Task.Row.EncodeSec }
                $r.Task.Row = $res; $r.Task.State = 'done'
                $msg = "SCORED [V{0}] {1} :: {2}: {3}" -f ($r.Slot + 1), $t.Rel, $res.Name, $res.Status
                if ($null -ne $res.Mean) { $msg += (", VMAF {0:0.00}/{1:0.00}/{2:0.00}, {3} GB" -f $res.Mean, $res.P1, $res.Min, $res.VideoGB) }
                if ($res.Error) { $msg += " - $($res.Error)" }
                Write-Log $msg $(if ($res.Status -eq 'Done') { 'Green' } else { 'Red' })
            }
            if ($t.State -eq 'ready' -and (Test-TitleFinished $t)) { Complete-Title $t }
        }

        # ---- hand encodes to free encoder slots, oldest title first (in ladder mode a title
        #      waiting on VMAF to choose its next rung has nothing to hand out; the slot moves on)
        $free = [Array]::IndexOf($slots, $null)
        $idleSlot = $false
        while ($free -ge 0) {
            $next = $null
            foreach ($t in $titleList) {
                if ($t.State -ne 'ready') { continue }
                $next = Get-NextTask $t
                if ($next) { break }
            }
            if (-not $next) { $idleSlot = $true; break }
            Start-Variant $t $next $free 'encode'
            $free = [Array]::IndexOf($slots, $null)
        }

        # ---- hand finished encodes to free VMAF slots, oldest first
        $free = [Array]::IndexOf($vmafSlots, $null)
        while ($free -ge 0) {
            $next = $null
            foreach ($t in $titleList) {
                if ($t.State -ne 'ready') { continue }
                $next = $t.Tasks | Where-Object { $_.State -eq 'encoded' } | Select-Object -First 1
                if ($next) { break }
            }
            if (-not $next) { break }
            Start-Variant $t $next $free 'vmaf'
            $free = [Array]::IndexOf($vmafSlots, $null)
        }

        # ---- finish titles (audio, move up, delete the rest), one at a time, oldest first
        if (-not @($running.Values | Where-Object { $_.Kind -eq 'finalize' }).Count) {
            $ft = @($titleList | Where-Object { $_.Finalize -eq 'pending' } | Select-Object -First 1)
            if ($ft.Count) { Start-Finalize $ft[0] }
        }

        # ---- prepare the next title, one at a time: when an encoder slot found nothing to do, or
        #      when no prepared title has an encode waiting (keeps one ready ahead). Get-NextPrepTitle
        #      also caps titles in progress at -Threads + 2.
        $prepRunning = @($running.Values | Where-Object { $_.Kind -eq 'prep' }).Count
        $waiting = 0
        foreach ($t in $titleList) {
            if ($t.State -ne 'ready') { continue }
            if ((-not $fixedMode -and $null -eq $t.StartRungs -and -not (Get-WaitingOn $t)) -or @($t.Tasks | Where-Object { $_.State -eq 'pending' }).Count) { $waiting++ }
        }
        if (-not $prepRunning -and -not $stopDispatch -and ($idleSlot -or -not $waiting)) {
            $t = Get-NextPrepTitle
            if ($t) { Start-Prep $t }
        }

        # ---- progress display: one bar per encoder slot, one for prep
        foreach ($r in $running.Values) {
            $st = $null
            try { if ([IO.File]::Exists($r.StatusFile)) { $st = [IO.File]::ReadAllText($r.StatusFile) | ConvertFrom-Json } } catch { }
            $elapsed = ((Get-Date) - $r.Start).ToString('hh\:mm\:ss')
            $text = "starting  [$elapsed]"; $pct = -1
            if ($st) {
                $text = $st.Step
                if ($st.PSObject.Properties['Pct'] -and $null -ne $st.Pct) {
                    $pct = [int][Math]::Min(100, [Math]::Max(0, [double]$st.Pct))
                    $text += " $($st.Pct)% - $($st.Detail)"
                }
                $text += "  [$elapsed]"
            }
            if ($r.Kind -eq 'finalize') {
                Write-Progress -Id 21 -Activity ("FINISH {0} :: {1}" -f $r.Title.Rel, $r.Title.FinalDoc.Variant) -Status $text -PercentComplete -1
            } elseif ($r.Kind -eq 'prep') {
                Write-Progress -Id 99 -Activity "Preparing $($r.Title.Rel)" -Status $text -PercentComplete $pct
            } else {
                $pid0 = if ($r.Kind -eq 'encode') { $r.Slot + 1 } else { $r.Slot + 11 }
                Write-Progress -Id $pid0 -Activity ("{0} {1} :: {2} ({3})" -f $r.Label.Trim(), $r.Title.Rel, $r.Task.Spec.Name, (Get-TaskLabel $r.Title $r.Task)) -Status $text -PercentComplete $pct
            }
        }
        Start-Sleep -Seconds 2
    }
} finally {
    # Ctrl+C or an error: stop workers and anything they launched on the Windows side.
    foreach ($r in @($running.Values)) {
        try {
            $st = [IO.File]::ReadAllText($r.StatusFile) | ConvertFrom-Json
            if ($st.Pid) {
                $p = Get-Process -Id $st.Pid -ErrorAction SilentlyContinue
                if ($p -and $p.Id -ne $PID -and $p.ProcessName -match '^(NVEncC64|NVEncC|wsl|powershell|pwsh)$') { Stop-Process -Id $st.Pid -Force -ErrorAction SilentlyContinue }
            }
        } catch { }
        Stop-Job -Job $r.Job -ErrorAction SilentlyContinue
        Remove-Job -Job $r.Job -Force -ErrorAction SilentlyContinue
        $what = if ($r.Kind -eq 'prep') { 'prep' } elseif ($r.Kind -eq 'finalize') { 'finishing (resumes next run)' } else { "$($r.Task.Spec.Name) ($($r.Kind))" }
        Write-Log "ABORTED $($r.Title.Rel) :: $what (partial encodes are redone next run)" 'Red'
    }
    $notStarted = @($titleList | Where-Object { $_.State -eq 'queued' }).Count
    $unfinished = @($titleList | Where-Object { $_.State -in 'ready', 'prepping' })

    # ---------------------------------------------------------------- summary
    $elapsed = (Get-Date) - $started
    $md = New-Object System.Collections.Generic.List[string]
    $md.Add("# Encode-Batch $runId")
    $md.Add('')
    $md.Add("- **Source:** ``$srcPath``")
    $md.Add("- **Dest:** ``$dstRoot``")
    $md.Add("- **Elapsed:** $($elapsed.ToString('hh\:mm\:ss'))")
    $md.Add("- **Mode:** $(if ($fixedMode) { 'fixed variants' } else { "ladder search ($(($specs | ForEach-Object { $_.Name }) -join ', '))" })")
    $md.Add("- **Bar:** mean >= $MinMean, p1 >= $MinP1, min >= $MinMin, video <= $MaxPct% of the source's.")
    $md.Add("- **Suggested:** the passing variant closest to $TargetPct% of the source, either direction. None = keep the original.")
    $md.Add("- **Titles:** $(@($results | Where-Object Status -eq 'Done').Count) done, $(@($results | Where-Object Status -eq 'Partial').Count) partial, $(@($results | Where-Object { $_.Status -in 'Failed', 'Skipped' }).Count) failed/skipped while running, $($skipped.Count) skipped before starting, $($unfinished.Count) interrupted, $notStarted not started")
    $csv = New-Object System.Collections.Generic.List[object]
    foreach ($res in $results) {
        $md.Add('')
        $md.Add("## $($res.Title)")
        $md.Add('')
        $line = "$($res.Status), $([TimeSpan]::FromSeconds([int]$res.Seconds))"
        if ($res.Reason) { $line += " - $($res.Reason)" }
        $md.Add("$line. Log: ``$($res.LogPath)``")
        $rows = @($res.Variants)
        if ($rows.Count) {
            $md.Add('')
            Format-VariantTable $rows | ForEach-Object { $md.Add($_) }
            foreach ($v in $rows) {
                $csv.Add([pscustomobject]@{
                    Title = $res.Title; Variant = $v.Name; Status = $v.Status; Suggested = $v.Suggested; Hint = $v.Hint; Pass = $v.Pass
                    OverCap = $v.OverCap; Dominated = $v.Dominated; Mean = $v.Mean; P1 = $v.P1; Min = $v.Min; VideoGB = $v.VideoGB
                    PctOfSource = $v.Pct; Mbps = $v.Mbps; Model = $v.Model; AlignmentWarning = $v.Warning
                    EncodeSeconds = $v.EncodeSec; Error = $v.Error; File = $v.File
                })
            }
        }
    }
    if ($finished.Count) {
        $md.Add('')
        $md.Add('## Finished (audio added, moved into place, other variants deleted)')
        $md.Add('')
        foreach ($f in $finished) {
            if ($f.Status -eq 'Done') { $md.Add("- ``$($f.Title)``: $($f.Variant) -> ``$($f.Final)``$(if ($f.FreedGB) { ", $($f.FreedGB) GB freed" })") }
            else { $md.Add("- **FAILED** ``$($f.Title)``: $($f.Error)") }
        }
    }
    $pendingFinish = @($titleList | Where-Object { $_.Finalize -eq 'pending' -or $_.Finalize -eq 'running' })
    if ($pendingFinish.Count) {
        $md.Add('')
        $md.Add("$($pendingFinish.Count) title(s) still to finish; the next run does that first.")
    }
    if ($skipped.Count) {
        $md.Add('')
        $md.Add('## Skipped before starting')
        $md.Add('')
        foreach ($s in $skipped) { $md.Add("- ``$($s.Title)``: $($s.Reason)") }
    }
    $mdPath = Join-Path $dstRoot "_encode-batch_$runId.md"
    [IO.File]::WriteAllLines($mdPath, $md, $script:Utf8)
    if ($csv.Count) { $csv | Export-Csv -LiteralPath (Join-Path $dstRoot "_encode-batch_$runId.csv") -NoTypeInformation -Encoding UTF8 }
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    $tmpParent = Split-Path -Parent $tempDir
    if ([IO.Directory]::Exists($tmpParent) -and -not (Get-ChildItem -LiteralPath $tmpParent -Force)) { Remove-Item -LiteralPath $tmpParent -Force -ErrorAction SilentlyContinue }
    Write-Log "Finished in $($elapsed.ToString('hh\:mm\:ss')). Summary: $mdPath" 'Cyan'
}
