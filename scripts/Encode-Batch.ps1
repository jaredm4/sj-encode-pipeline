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
          <name>.mks                   subtitle backup from Add-BluRayAudio, until the folder is done
          <folder> - subtitles.zip     all of the folder's subtitle backups, once every title in it is done
          <name>.encode.log            everything that happened to this title, every run
          <name>.audio.log             Add-BluRayAudio's own log (every detail of the audio step)
          <name>.crop.json             CropDetect's result (delete it to redo the crop)
          <name>.results.json          machine-readable variant results
          <name>.final.json            what was kept, and the finishing progress
          <name>.dovi.json             Dolby Vision 7 decision: converted, converted with clipped
                                       highlights, or kept as profile 7 (see "Dolby Vision 7")
          <name> - 2160p.mkv           a title kept as Dolby Vision 7: the original video, with audio
          <name> - 1080p.mkv           ...and its 1080p SDR copy (searched and finished like any title;
                                       its files are named "<name> - 1080p.*")
          <variant name>\<name>.mkv    one folder per variant while a title is in progress
          <variant name>\<name>.vmaf.txt  (and kept afterwards in fixed mode / -KeepVariants)

      WorkDir (default: Dest)\<same sub-folders>\
          <name> - source.mkv          local copy of the source, until the title is finished
          <name> - p7 source.mkv       Dolby Vision 7 copy being checked / converted
          <name> - p8.1.mkv            converted Dolby Vision 7 copy, until the title is finished
          <name> - 1080p ref.mkv       near-lossless 1080p SDR reference for a 1080p copy, until it's finished

      Dest\_encode-batch_<timestamp>.log / .md          this run's log and summary (what it touched)
      Dest\_encode-batch_all.md / .csv                  every title under -Source, from all runs; only
                                                       written once the whole batch is complete

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
         (and writes its subtitle backup, <name>.mks). It runs with -Plumbing: its details go
         to <name>.audio.log, and what it reports back (the audio tracks and their roles, the
         dropped tracks and why, any sync shift, the subtitle backup, warnings) goes into
         final.json, the title's .encode.log and the reports. Warnings include "SUBTITLES TO
         FIX" when the audio had to be shifted (OCR'd subtitles need the same shift).
      2. The suggested MKV moves up to Dest\<same sub-folders>\<name>.mkv, and the subtitle backup
         to <name>.mks next to it.
      3. This title's other variants (and their VMAF files) are deleted. Variant folders left
         empty are removed once every title in the folder is done.
      When every title in a folder (e.g. a season) is done, its <name>.mks files are bundled into
      "<folder> - subtitles.zip" there (stored, not compressed; added to it if it exists), so
      Jellyfin doesn't see them. Loose .mks files from earlier runs are bundled the same way.
      Progress is saved in <name>.final.json, so an interrupted finish resumes where it was,
      and a finished one is skipped on later runs (its pick still guides its folder).
      If the audio step fails, nothing is moved or deleted. Titles with no passing variant
      keep all their variants for review; after reviewing them, re-run with -UseSourceFallback
      to finish those titles with their source instead (the local copy, or a fresh copy of the
      source, goes through the same steps, and the failed encodes are deleted). For Dolby
      Vision 7 titles the converted "<name> - p8.1.mkv" is used. A Dolby Vision 7 title's
      p8.1 copy is deleted once it's finished. -NoAudio / -KeepVariants skip steps 1 / 3.
      Fixed mode (-Variants) never does any of this.

    Work is a queue, not one thread per title:
      - Prep (one title at a time, no encoder slot used): probe with ffprobe (and mediainfo when
        installed); skip VC-1 (-SkipVC1) and Dolby Vision other than 7 / 8.1. For profile 7:
        see "Dolby Vision 7" below. Then CropDetect -Plumbing for the Suggested crop.
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

    Local copies (-LocalCopy, default on): prep copies each source to Dest\...\<name> - source.mkv
    (next title's copy is made while the current ones encode). Everything reads that copy, and
    it's deleted when the title is finished (after the audio step), or right away if it ends
    without a suggested variant. An interrupted copy is redone; a complete one is reused.
    (Dolby Vision 7 titles use their converted "<name> - p8.1.mkv" copy instead.) Local copies
    go to -WorkDir (default: Dest).

    Disk space is checked before each title starts. Dest needs -MinFreeGB free (for the encodes);
    the work drive needs room for the local copy, or -MinFreeDoviGB for a Dolby Vision 7 title
    that still has to be downloaded and converted (one with its copy already there doesn't).
    With no -WorkDir, both come out of Dest. At most -MaxDoviTitles Dolby Vision 7 titles hold
    work files at once. When there isn't enough space, new titles wait until finished titles
    free some (copies, p8.1 files and other variants are deleted); if nothing is left running
    to free any, the run stops starting titles. A Dolby Vision 7 title's conversion also waits
    for room (about twice the copy's size) after its inspect, for the same reason.

    Dolby Vision 7: dovi_convert scan (on the source) -> copy to -WorkDir -> dovi_convert inspect
    (the copy; it measures the brightness the enhancement layer adds) -> decide:
      - SIMPLE / SAFE or MEL: convert to 8.1 (convert --yes --include-simple --force --delete),
        then verify it's 8.1. Encoded like any HDR title, with its Dolby Vision 8.1 metadata.
      - COMPLEX FEL with the FEL peak at most -DoviOvershootNits (100) above the base layer's
        peak: converted to 8.1 anyway; the highlights above the base layer's peak are clipped.
        Logged ("DOVI ..."), and noted in the reports.
      - Anything else (Complex FEL beyond that, NO L1 METADATA): kept as profile 7. The untouched
        copy gets the audio (and subtitle backup) only and becomes "<name> - 2160p.mkv"; a second
        title "<name> - 1080p" is added: a near-lossless 1080p SDR reference is made from the
        profile 7 video (cropped, tone-mapped, scaled to fit 1920x1080, in -WorkDir) and searched
        and finished like any title, ending as "<name> - 1080p.mkv". Logged ("KEEP P7 ..."), and
        noted in the reports. Its "% of source" is relative to that reference.
    The decision is saved in "<name>.dovi.json". A season stays one format: once a title in a
    folder is kept as profile 7, the folder's later Dolby Vision 7 titles are too (titles already
    finished, or already converted and in progress, stay 8.1; check the reports for those).

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
        @{ Cqp = 22; Aq = 4 },
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

    [int]$MinFreeGB = 200,
    [int]$MinFreeDoviGB = 400,

    # Where the big working files go: local copies of sources ("<name> - source.mkv"), Dolby
    # Vision 7 copies and their converted "<name> - p8.1.mkv". Mirrors the folders under -Source.
    # Point it at another drive so these don't compete with the encodes for space; it can change
    # between runs (files left in the old place are just made again; ones in Dest are still found).
    # Default: Dest.
    [string]$WorkDir = '',

    # At most this many Dolby Vision 7 titles hold files in -WorkDir at once (downloading,
    # converting, or encoding from the converted copy). Others wait their turn.
    [ValidateRange(1, 4)][int]$MaxDoviTitles = 2,

    # VMAF bar a variant must meet to pass.
    [double]$MinMean = 93.5,
    [double]$MinP1 = 80,
    [double]$MinMin = 75,

    # Size rules, as video stream % of the source's video stream (see .DESCRIPTION).
    [double]$MaxPct = 70,        # hard cap: bigger variants don't pass
    [double]$TargetPct = 20,     # the search aims here; the passer closest to it is suggested

    # Top bar: a passing variant under -TargetPct that also meets ALL of these is good enough to
    # take the extra space savings. The search stops climbing toward -TargetPct, and the biggest
    # such variant is suggested (e.g. animation that compresses very well). -TopMean 101 turns it off.
    [double]$TopMean = 97,
    [double]$TopP1 = 85,
    [double]$TopMin = 80,

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

    # Ladder mode: a title where no variant passes is finished with its SOURCE instead (copied
    # into place, then audio, subtitle backup, move up, failed encodes deleted), rather than left
    # for review. Off by default: review the failures first, then re-run with this.
    [switch]$UseSourceFallback,

    # Copy each source to Dest (next to its log, as "<name> - source.mkv") during prep, so the
    # encodes, VMAF scoring, CropDetect and Add-BluRayAudio all read it locally instead of from
    # the NAS. Deleted once the title is finished. -LocalCopy:$false reads from the NAS directly.
    [bool]$LocalCopy = $true,

    [string]$NVEncC = (Join-Path $env:APPDATA 'NVEnc\NVEncC64.exe'),
    [string]$CropDetect = (Join-Path $PSScriptRoot 'CropDetect.ps1'),
    # How NVEncC decodes the source. avsw (default) = on the CPU, leaving the GPU's video decoder
    # to compare_encode, which decodes two streams per score on it; avhw = on the GPU's decoder.
    [ValidateSet('avhw', 'avsw')][string]$Decoder = 'avsw',

    # WSL side. Commands must be on PATH for a login shell (bash -l), or give full paths.
    [string]$WslDistro,
    [string]$WslMountRoot = '/mnt',
    [string]$CompareEncodeCmd = 'compare_encode',
    [string]$DoviConvertCmd = 'dovi_convert',

    # Dolby Vision 7 titles whose enhancement layer adds brightness (Complex FEL) are still
    # converted to 8.1 when inspect's FEL peak is at most this many nits above the base layer's
    # peak (the highlights above the base layer's peak are clipped; noted in the log and reports).
    # Above it, the title is kept as profile 7 ("<name> - 2160p.mkv", audio only) plus a 1080p
    # SDR copy ("<name> - 1080p.mkv", searched and finished like any other title).
    [int]$DoviOvershootNits = 100,
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

    # Copies a file via "<Dest>.partial" (renamed when complete), reporting progress to the status
    # file. Large sequential reads: much faster from a NAS than the encoders' own small reads.
    function Copy-FileWithProgress {
        param([string]$Src, [string]$Dst, [hashtable]$StatusBase = @{})
        $part = "$Dst.partial"
        $total = (New-Object IO.FileInfo $Src).Length
        $buf = New-Object byte[] (8MB)
        $in = New-Object IO.FileStream($Src, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read, 1MB, [IO.FileOptions]::SequentialScan)
        try {
            $out = New-Object IO.FileStream($part, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None, 1MB)
            try {
                $done = 0L; $t0 = Get-Date; $last = [DateTime]::MinValue
                while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                    $out.Write($buf, 0, $n); $done += $n
                    if (((Get-Date) - $last).TotalSeconds -ge 2) {
                        $last = Get-Date
                        $secs = [Math]::Max([double]0.1, ((Get-Date) - $t0).TotalSeconds)
                        $st = @{} + $StatusBase
                        $st.Pct = [Math]::Round(100.0 * $done / [Math]::Max([double]1, [double]$total), 1)
                        $st.Detail = '{0:N1} of {1:N1} GB, {2:N0} MB/s' -f ($done / 1GB), ($total / 1GB), ($done / 1MB / $secs)
                        Set-Status $st
                    }
                }
            } finally { $out.Dispose() }
        } finally { $in.Dispose() }
        if ((New-Object IO.FileInfo $part).Length -ne $total) { throw "copy of $Src is incomplete" }
        Move-Item -LiteralPath $part -Destination $Dst -Force -ErrorAction Stop
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
                foreach ($line0 in $parts) {
                    # Colour/cursor codes (e.g. dovi_convert prints "\e[1mAction:\e[0m ...") would break matching.
                    $line = $line0 -replace '\x1b\[[0-9;?]*[ -/]*[@-~]', ''
                    # Animated spinner frames (dovi_convert: "Extracting RPU...  <spinner> (0m 05s)").
                    if ($line -match '[\u2800-\u28FF|/\\-] \(\d+m \d{2}s\)\s*$') { continue }
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
export NO_COLOR=1
exec </dev/null
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
    # Top bar: also passes TopMean/TopP1/TopMin while under TargetPct. If any variant does, the
    # biggest of those is suggested instead (take the savings rather than climb to TargetPct).
    function Test-TopBar {
        param($Row, [double]$TargetPct, [double]$TopMean, [double]$TopP1, [double]$TopMin)
        $null -ne $Row.Pct -and $Row.Pct -le $TargetPct -and $Row.Mean -ge $TopMean -and $Row.P1 -ge $TopP1 -and $Row.Min -ge $TopMin
    }

    function Set-Suggestion {
        param($Rows, [double]$MinMean, [double]$MinP1, [double]$MinMin, [double]$MaxPct = 65, [double]$TargetPct = 20,
            [double]$TopMean = 1000, [double]$TopP1 = 1000, [double]$TopMin = 1000)
        foreach ($r in $Rows) {
            foreach ($k in 'Pass', 'OverCap', 'Dominated', 'Suggested', 'Top') {
                if ($r.PSObject.Properties[$k]) { $r.$k = $false } else { $r | Add-Member -NotePropertyName $k -NotePropertyValue $false }
            }
            if ($r.PSObject.Properties['Hint']) { $r.Hint = '' } else { $r | Add-Member -NotePropertyName Hint -NotePropertyValue '' }
            if ($r.PSObject.Properties['Why']) { $r.Why = '' } else { $r | Add-Member -NotePropertyName Why -NotePropertyValue '' }
        }
        $scored = @($Rows | Where-Object { (Get-VariantClass $_ $MinMean $MinP1 $MinMin $MaxPct) -ne 'error' })
        foreach ($r in $scored) {
            $c = Get-VariantClass $r $MinMean $MinP1 $MinMin $MaxPct
            $r.Pass = $c -eq 'pass'
            $r.OverCap = $c -like '*overcap'
            $why = @()
            if ($r.Mean -lt $MinMean) { $why += 'mean {0:0.00} < {1}' -f $r.Mean, $MinMean }
            if ($r.P1 -lt $MinP1) { $why += 'p1 {0:0.00} < {1}' -f $r.P1, $MinP1 }
            if ($r.Min -lt $MinMin) { $why += 'min {0:0.00} < {1}' -f $r.Min, $MinMin }
            if ($r.OverCap) { $why += '{0:0.#}% > {1}% cap' -f $r.Pct, $MaxPct }
            $r.Why = $why -join ', '
            foreach ($o in $scored) {
                if ($o -eq $r) { continue }
                $noWorse = $o.VideoGB -le $r.VideoGB -and $o.Mean -ge $r.Mean -and $o.P1 -ge $r.P1 -and $o.Min -ge $r.Min
                $better = $o.VideoGB -lt $r.VideoGB -or $o.Mean -gt $r.Mean -or $o.P1 -gt $r.P1 -or $o.Min -gt $r.Min
                if ($noWorse -and $better) { $r.Dominated = $true; break }
            }
        }
        $passers = @($scored | Where-Object { $_.Pass })
        if (-not $passers.Count) { return $null }
        $top = @($passers | Where-Object { Test-TopBar $_ $TargetPct $TopMean $TopP1 $TopMin })
        foreach ($r in $top) { $r.Top = $true }
        if ($top.Count) {
            $pick = @($top | Sort-Object @{ Expression = { $_.Pct }; Descending = $true }, VideoGB)[0]
            $pick.Suggested = $true
            return $pick.Name
        }
        $pick = @($passers | Sort-Object @{ Expression = { if ($null -eq $_.Pct) { 1e9 } else { [Math]::Abs($_.Pct - $TargetPct) } } }, VideoGB)[0]
        $pick.Suggested = $true
        return $pick.Name
    }

    # For a title where nothing passed (call after Set-Suggestion): the nearest miss, i.e. the
    # highest-mean variant under the size cap (or the smallest one if all are over it), and why.
    function Get-ClosestMiss {
        param($Rows)
        $scored = @($Rows | Where-Object { $_.PSObject.Properties['Why'] -and $_.Why })
        if (-not $scored.Count) { return '' }
        $under = @($scored | Where-Object { -not $_.OverCap })
        $r = if ($under.Count) { @($under | Sort-Object Mean -Descending)[0] } else { @($scored | Sort-Object VideoGB)[0] }
        '{0} {1:0.00}/{2:0.00}/{3:0.00} at {4:0.#}% ({5})' -f $r.Name, $r.Mean, $r.P1, $r.Min, $r.Pct, $r.Why
    }

    # One step of the ladder search. Rungs are indexed weakest/smallest (0) to strongest/biggest.
    # $Tried maps rung index -> finished row, or $null while it's queued / encoding / scoring.
    # Returns the rung to encode next, -1 to wait for the ones in flight, or -2 when finished.
    #   - Start rungs first (all at once, so both encoder slots can take one).
    #   - Some pass: if the smallest passer is still above TargetPct, try the next smaller rung;
    #     if the biggest passer is below TargetPct, try the next bigger one, unless a passer under
    #     TargetPct meets the top bar (TopMean/TopP1/TopMin). Otherwise finished.
    #   - None pass: passes the bar but over the cap -> try smaller; fails the bar -> try bigger.
    #   - Never repeats a rung, so it always ends (at worst at an end of the ladder).
    #   - $Skip: rungs to treat as already answered (see Get-KnownRungReason); never proposed.
    function Get-LadderNext {
        param([hashtable]$Tried, [int]$Count, [int[]]$Start, [double]$MinMean, [double]$MinP1, [double]$MinMin,
            [double]$MaxPct = 65, [double]$TargetPct = 20, [hashtable]$Skip = @{},
            [double]$TopMean = 1000, [double]$TopP1 = 1000, [double]$TopMin = 1000)
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
            # Under TargetPct but over the top bar: good enough, don't climb for size.
            $topHit = @($ok | Where-Object { Test-TopBar $Tried[$_] $TargetPct $TopMean $TopP1 $TopMin }).Count
            if ($null -ne $hiPct -and $hiPct -lt $TargetPct -and -not $topHit -and (& $open ($hi + 1))) { return $hi + 1 }
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
            if ($r.PSObject.Properties['Top'] -and $r.Top) { $notes += 'top bar' }
            if ($r.PSObject.Properties['Hint'] -and $r.Hint) { $notes += $r.Hint }
            if ($r.PSObject.Properties['Why'] -and $r.Why) { $notes += $r.Why }
            elseif ($r.PSObject.Properties['OverCap'] -and $r.OverCap) { $notes += 'over the size cap' }
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
    $workDir = if ($Cfg.PSObject.Properties['WorkDir'] -and $Cfg.WorkDir) { [string]$Cfg.WorkDir } else { $titleDir }
    # A working file: in the work folder, or in Dest where earlier runs put it; the work folder if neither.
    function Get-WorkFile([string]$suffix) {
        $w = Join-Path $workDir "$base$suffix"
        if ([IO.File]::Exists($w)) { return $w }
        $d = Join-Path $titleDir "$base$suffix"
        if ([IO.File]::Exists($d)) { return $d }
        $w
    }
    $tmp = $Cfg.TempDir
    $wsl = $Cfg.Wsl
}

$PrepBody = {
    $status = @{ Step = 'preparing'; Variant = ''; Index = 0; Count = 0 }
    function Step([string]$name) {
        $status.Step = $name; $status.Remove('Pct'); $status.Remove('Detail')
        Set-Status $status
    }
    function Done([string]$st, [string]$reason, $workSrc = $null, $isDv81 = $false, $crop = $null, $localCopy = $null) {
        if ($reason) { Write-Log "PREP: $st - $reason" } else { Write-Log "PREP: $st" }
        [pscustomobject]@{ Status = $st; Reason = $reason; WorkSrc = $workSrc; IsDv81 = [bool]$isDv81; Crop = $crop; LocalCopy = $localCopy
                           Seconds = [int]((Get-Date) - $t0).TotalSeconds }
    }

    # Waits until the work folder has $needGB free (re-checked every 30 s). The main loop gives up
    # on the title if nothing else is running that could ever free the space.
    function Wait-WorkSpace([double]$needGB, [string]$what) {
        $logged = $false
        while (($freeW = Get-FreeGB $workDir) -lt $needGB) {
            if (-not $logged) { Write-Log "Waiting for space to ${what}: needs $needGB GB free in $workDir, $freeW GB now"; $logged = $true }
            $status.Step = "waiting for space to $what ($needGB GB needed, $freeW GB free)"; Set-Status $status
            Start-Sleep -Seconds 30
        }
        if ($logged) { Write-Log "Space available ($freeW GB free): going on to $what" }
    }

    # 1080p SDR copy of a title kept as Dolby Vision 7 (the main loop adds these titles). Makes a
    # near-lossless 1080p SDR reference from the profile 7 video (its base layer: cropped, tone-mapped
    # from HDR, scaled to fit 1920x1080), which the ladder then encodes from and scores against.
    function Invoke-DerivedPrep {
        $refPath = Join-Path $workDir "$($Cfg.ParentBase) - 1080p ref.mkv"
        $parentCrop = Join-Path $titleDir "$($Cfg.ParentBase).crop.json"
        $myCrop = Join-Path $titleDir "$base.crop.json"
        $src = @($Cfg.RefSources | Where-Object { $_ -and [IO.File]::Exists($_) } | Select-Object -First 1)
        $crop = $null
        if ([IO.File]::Exists($parentCrop)) { try { $crop = [IO.File]::ReadAllText($parentCrop) | ConvertFrom-Json } catch { } }
        if (-not $crop -and $src.Count) {
            Step 'CropDetect'
            $cdArgs = @{ Source = $src[0]; Plumbing = $true }
            if ($Cfg.PSObject.Properties['CropHw'] -and $Cfg.CropHw) { $cdArgs.HwDecode = $true }
            Write-Log "> CropDetect -Source `"$($src[0])`" -Plumbing$(if ($cdArgs.HwDecode) { ' -HwDecode' })"
            $cdOut = & $Cfg.CropDetect @cdArgs 6>&1 3>&1
            foreach ($o in $cdOut) {
                $txt = if ($o -is [System.Management.Automation.InformationRecord]) { [string]$o.MessageData } else { [string]$o }
                if ($txt -match '^\s*\{.*"Width".*\}\s*$') { $crop = $txt | ConvertFrom-Json; [IO.File]::WriteAllText($parentCrop, $txt.Trim(), $script:Utf8) }
                elseif ($txt.Trim() -and $txt.Trim() -notmatch '^[.x]+$') { Write-LogRaw "    $($txt.TrimEnd())" }
            }
        }
        if (-not $crop) { return (Done 'Failed' 'no crop for the 1080p copy (CropDetect failed, or no profile 7 video left to read).') }
        # Fit the cropped picture in 1920x1080, even dimensions.
        $cw = [int]$crop.Width; $ch = [int]$crop.Height
        $scale = [Math]::Min([double]1, [Math]::Min(1920.0 / $cw, 1080.0 / $ch))
        $w = [int](2 * [Math]::Round($cw * $scale / 2)); $h = [int](2 * [Math]::Round($ch * $scale / 2))
        if (-not [IO.File]::Exists($refPath)) {
            if (-not $src.Count) { return (Done 'Failed' 'the profile 7 video to make the 1080p copy from is gone (local copy, finished 2160p file and source all missing).') }
            [void][IO.Directory]::CreateDirectory($workDir)
            Wait-WorkSpace ([Math]::Round(0.6 * (New-Object IO.FileInfo $src[0]).Length / 1GB + 20, 1)) 'make the 1080p SDR reference'
            Step 'making the 1080p SDR reference'
            $peak = 1000
            if ($Cfg.SourcePeak -gt 0) { $peak = [int]$Cfg.SourcePeak }
            $partial = "$refPath.partial.mkv"
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            $a = @('--avsw', '--device', '0', '-i', $src[0])
            if (($crop.Left + $crop.Top + $crop.Right + $crop.Bottom) -gt 0) { $a += @('--crop', ('{0},{1},{2},{3}' -f $crop.Left, $crop.Top, $crop.Right, $crop.Bottom)) }
            $a += @('--output-res', "${w}x${h}", '--vpp-resize', 'spline36',
                '--vpp-colorspace', "matrix=bt2020nc:bt709,colorprim=bt2020:bt709,transfer=smpte2084:bt709,range=limited:limited,hdr2sdr=hable,source_peak=$peak,ldr_nits=100",
                '--colormatrix', 'bt709', '--colorprim', 'bt709', '--transfer', 'bt709',
                '--video-metadata', 'clear', '--metadata', 'clear', '--chapter-copy', '-c', 'hevc', '--profile', 'main10', '--output-depth', '10',
                '--cqp', '12', '--preset', 'P7', '--avsync', 'cfr', '-o', $partial)
            Write-Log ("Making the 1080p SDR reference {0}x{1} from {2} (crop L{3} T{4} R{5} B{6}, tone-mapped from {7} nits)" -f $w, $h, $src[0], $crop.Left, $crop.Top, $crop.Right, $crop.Bottom, $peak)
            $r = Invoke-Logged -Exe $Cfg.NVEncC -ArgList $a -TempDir $tmp -StatusBase $status
            if ($r.ExitCode -ne 0 -or -not [IO.File]::Exists($partial)) { return (Done 'Failed' "NVEncC failed making the 1080p SDR reference (exit $($r.ExitCode)).") }
            Move-Item -LiteralPath $partial -Destination $refPath -Force -ErrorAction Stop
        } else {
            Write-Log "Reusing the 1080p SDR reference $refPath"
        }
        # For the reports: the original picture, its crop, and the final 1080p size.
        $show = [ordered]@{ SourceWidth = $crop.SourceWidth; SourceHeight = $crop.SourceHeight; Width = $w; Height = $h
                            Left = $crop.Left; Top = $crop.Top; Right = $crop.Right; Bottom = $crop.Bottom; Scaled = $true }
        [IO.File]::WriteAllText($myCrop, ($show | ConvertTo-Json -Compress), $script:Utf8)
        # The encodes take the reference as is (already cropped and scaled).
        $none = [pscustomobject]@{ Left = 0; Top = 0; Right = 0; Bottom = 0; Width = $w; Height = $h; SourceWidth = $w; SourceHeight = $h }
        $ready = Done 'Ready' '' $refPath $false $none $null
        $ready | Add-Member -NotePropertyName RefWidth -NotePropertyValue $w
        $ready | Add-Member -NotePropertyName RefHeight -NotePropertyValue $h
        $ready
    }

    function Invoke-Prep {
      try {
        Write-LogRaw ''
        Write-LogRaw ('=' * 100)
        Write-Log "Encode-Batch run $($Cfg.RunId): $($Cfg.SourceFile)"
        Write-Log ("Source: {0} {1}x{2} {3} fps, {4}, HDR={5}, Dolby Vision={6}" -f $Cfg.Info.Codec, $Cfg.Info.Width, $Cfg.Info.Height, $Cfg.Info.Fps, [TimeSpan]::FromSeconds([int]$Cfg.Info.Duration), $Cfg.Info.Hdr, $Cfg.Info.Dv)
        Write-Log "  ($($Cfg.Info.DvDetail))"
        if ($Cfg.Info.Hdr) { Write-Log ("  HDR: {0}  master-display {1}  max-cll {2}  HDR10+ {3}" -f (@($Cfg.Info.ColorArgs) -join ' '), $(if ($Cfg.Info.MasterDisplay) { $Cfg.Info.MasterDisplay } else { 'none' }), $(if ($Cfg.Info.MaxCll) { $Cfg.Info.MaxCll } else { 'none' }), $Cfg.Info.Hdr10Plus) }

        if ($Cfg.PSObject.Properties['Derived'] -and $Cfg.Derived) { return (Invoke-DerivedPrep) }

        $workSrc = $Cfg.SourceFile
        $isDv81 = ($Cfg.Info.Dv -eq 'P8.1')
        $localCopy = $null

        # ---------------------------------------------------------------- local copy
        if ($Cfg.LocalCopy -and $Cfg.Info.Dv -ne 'P7') {
            [void][IO.Directory]::CreateDirectory($workDir)
            $lc = Get-WorkFile ' - source.mkv'
            $srcLen = (New-Object IO.FileInfo $Cfg.SourceFile).Length
            if ([IO.File]::Exists($lc) -and (New-Object IO.FileInfo $lc).Length -eq $srcLen) {
                Write-Log "Reusing local copy $lc"
                $workSrc = $lc; $localCopy = $lc
            } else {
                $free = Get-FreeGB $workDir
                $needGB = [Math]::Round($srcLen / 1GB, 1)
                if ($free - $needGB -lt 10) {
                    Write-Log "Not enough space for a local copy ($needGB GB, $free GB free): reading the source from its original location."
                } else {
                    Step 'copying source'
                    Write-Log ("Copying source to {0} ({1} GB, {2} GB free)" -f $lc, $needGB, $free)
                    $c0 = Get-Date
                    Copy-FileWithProgress -Src $Cfg.SourceFile -Dst $lc -StatusBase $status
                    $secs = [Math]::Max([double]1, ((Get-Date) - $c0).TotalSeconds)
                    Write-Log ("Copied in {0} ({1:N0} MB/s)" -f [TimeSpan]::FromSeconds([int]$secs), ($srcLen / 1MB / $secs))
                    $workSrc = $lc; $localCopy = $lc
                }
            }
        }

        # ---------------------------------------------------------------- Dolby Vision profile 7
        # scan on the source -> copy to the work folder -> inspect the copy -> decide:
        #   SIMPLE / SAFE or MEL                    -> convert to 8.1
        #   COMPLEX FEL within -DoviOvershootNits   -> convert to 8.1 anyway (highlights clipped; noted)
        #   COMPLEX FEL beyond it, or NO L1         -> keep as profile 7 (status 'KeepP7'): the main loop
        #                                              finishes the copy as "<name> - 2160p.mkv" (audio
        #                                              only) and adds a 1080p SDR title for it
        # The decision is saved as "<name>.dovi.json" in Dest. Once any title in a folder is kept as
        # profile 7, the folder's later profile 7 titles follow (a season stays one format); ones
        # already finished as 8.1 are left alone.
        if ($Cfg.Info.Dv -eq 'P7') {
            [void][IO.Directory]::CreateDirectory($workDir)
            $p81 = Get-WorkFile ' - p8.1.mkv'
            $p7copy = Get-WorkFile ' - p7 source.mkv'
            if (-not [IO.File]::Exists($p7copy)) { $p7copy = Join-Path $workDir "$base - p7 source.mkv" }
            $decFile = Join-Path $titleDir "$base.dovi.json"
            $saveDecision = { param([string]$decision, [string]$note, $basePeak, $felPeak, [string]$verdict)
                $o = [ordered]@{ Decision = $decision; Note = $note; BasePeak = $basePeak; FelPeak = $felPeak; Verdict = $verdict
                                 Limit = $Cfg.DoviOvershootNits; Time = (Get-Date).ToString('s') }
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
            foreach ($f in @([IO.Directory]::GetFiles($titleDir, '*.dovi.json') | Where-Object { $_ -ne $decFile })) {
                $o = & $readJson $f
                if ($o -and $o.Decision -eq 'keep-p7') {
                    $keepWhy = "the rest of the season follows $([IO.Path]::GetFileName($f) -replace '\.dovi\.json$', ''): $($o.Note)"
                    break
                }
            }
            if (-not $keepWhy -and $own -and $own.Decision -eq 'keep-p7') { $keepWhy = [string]$own.Note }
            $doviNote = ''

            if (-not $keepWhy -and [IO.File]::Exists($p81)) {
                Write-Log "Dolby Vision 7: reusing previously converted copy $p81"
                if ($own -and $own.Note) { $doviNote = [string]$own.Note }
            } elseif (-not $keepWhy) {
                $dirW = ConvertTo-WslPath $workDir $wsl.MountRoot
                Step 'dovi_convert scan'
                $srcW = ConvertTo-WslPath $Cfg.SourceFile $wsl.MountRoot
                $r = Invoke-Wsl -Wsl $wsl -TempDir $tmp -NeedPaths @($srcW) -StatusBase $status `
                    -Body ("cd /tmp && {0} scan {1}" -f $wsl.DoviConvertCmd, (ConvertTo-BashQuoted $srcW))
                $action = $null; $dvStatus = ''
                foreach ($l in $r.Lines) {
                    if ($l -match '^\s*Action:\s*(.+?)\s*$') { $action = $Matches[1] }
                    elseif ($l -match '^\s*Status:\s*(.+?)\s*$') { $dvStatus = $Matches[1] }
                }
                if ($r.ExitCode -ne 0 -or -not $action) {
                    $last = @($r.Lines | Where-Object { $_.Trim() } | Select-Object -Last 1)
                    return (Done 'Skipped' ("dovi_convert scan failed (exit {0}){1}." -f $r.ExitCode, $(if ($last.Count) { ": $($last[0].Trim())" })))
                }
                Write-Log "dovi_convert scan: $dvStatus -> Action: $action (inspect decides)"
                # CONVERT / CONVERT* / SKIP (Complex) / MANUAL CHECK all go on to inspect, which measures the
                # brightness properly. Anything else (an error, not profile 7) stops here.
                if ($action -notmatch '^(CONVERT\*?|SKIP|MANUAL CHECK)$') { return (Done 'Skipped' "dovi_convert scan says $dvStatus, Action: $action.") }

                if (-not [IO.File]::Exists($p7copy)) {
                    Step 'copying p7 source'
                    $srcLen = (New-Object IO.FileInfo $Cfg.SourceFile).Length
                    Write-Log ("Copying source to {0} ({1:N1} GB, {2} GB free there)" -f $p7copy, ($srcLen / 1GB), (Get-FreeGB $workDir))
                    $c0 = Get-Date
                    Copy-FileWithProgress -Src $Cfg.SourceFile -Dst $p7copy -StatusBase $status
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
                    return (Done 'Failed' ("dovi_convert inspect failed (exit {0}){1}. Local copy kept: {2}" -f $r.ExitCode, $(if ($last.Count) { ": $($last[0].Trim())" }), $p7copy))
                }
                $peaks = if ($basePeak -gt 0 -and $felPeak -gt 0) { "FEL peak $felPeak nits, base layer $basePeak nits" } else { 'peaks not reported' }
                Write-Log "dovi_convert inspect: VERDICT: $verdict ($peaks)"
                if ($verdict -match '^(SIMPLE / SAFE|MEL\b)') {
                    & $saveDecision 'convert' '' $basePeak $felPeak $verdict
                } elseif ($verdict -match '^COMPLEX' -and $basePeak -gt 0 -and $felPeak -gt 0 -and ($felPeak - $basePeak) -le $Cfg.DoviOvershootNits) {
                    $doviNote = "converted to 8.1 although inspect found Complex FEL: FEL peak $felPeak nits vs base layer $basePeak nits (+$($felPeak - $basePeak), within +$($Cfg.DoviOvershootNits)); highlights above $basePeak nits are clipped"
                    Write-Log "Dolby Vision 7: $doviNote"
                    & $saveDecision 'convert-overshoot' $doviNote $basePeak $felPeak $verdict
                } else {
                    $keepWhy = if ($verdict -match '^COMPLEX' -and $basePeak -gt 0 -and $felPeak -gt 0) {
                        "Complex FEL: FEL peak $felPeak nits vs base layer $basePeak nits (+$($felPeak - $basePeak), over +$($Cfg.DoviOvershootNits))"
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
                    if ($r.ExitCode -ne 0) { return (Done 'Failed' "dovi_convert convert failed (exit $($r.ExitCode)). Files left in place for review.") }
                    $chk = Get-SourceInfo $p7copy
                    if ($chk.Dv -ne 'P8.1') { return (Done 'Failed' "after conversion the copy reports '$($chk.Dv)', not P8.1 ($($chk.DvDetail)). Files left in place for review.") }
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
                    Copy-FileWithProgress -Src $Cfg.SourceFile -Dst $p7copy -StatusBase $status
                }
                $r0 = Done 'KeepP7' $keepWhy
                $r0 | Add-Member -NotePropertyName P7Copy -NotePropertyValue $p7copy
                return $r0
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
        $ready = Done 'Ready' '' $workSrc $isDv81 $crop $localCopy
        if ($Cfg.Info.Dv -eq 'P7' -and $doviNote) { $ready | Add-Member -NotePropertyName DoviNote -NotePropertyValue $doviNote }
        return $ready
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
    $res = [ordered]@{ Status = 'Failed'; Error = ''; Final = $doc.Final; FreedGB = 0; Deleted = 0; Audio = ''; AudioWarnings = @() }
    function Save-Doc([string]$state) {
        $doc.State = $state
        [IO.File]::WriteAllText($Cfg.FinalJson, ($doc | ConvertTo-Json -Depth 6), $script:Utf8)
    }
    function Invoke-Finalize {
      try {
        Write-Log "---- Finishing: $($doc.Variant) -> $($doc.Final)"
        $winner = $doc.Winner
        $winnerDir = [IO.Path]::GetDirectoryName($winner)
        if ($doc.PSObject.Properties['FromSource'] -and $doc.FromSource -and -not [IO.File]::Exists($winner) -and -not [IO.File]::Exists($doc.Final)) {
            [void][IO.Directory]::CreateDirectory($winnerDir)
            $status.Step = 'putting the source in place'; Set-Status $status
            if ($doc.PSObject.Properties['LinkFrom'] -and $doc.LinkFrom -and [IO.File]::Exists($doc.LinkFrom)) {
                # Kept as Dolby Vision 7: a hard link to the untouched local copy (same folder, no copying).
                try {
                    [void](New-Item -ItemType HardLink -Path $winner -Target $doc.LinkFrom -ErrorAction Stop)
                    Write-Log "Kept as Dolby Vision 7: $([IO.Path]::GetFileName($winner)) linked to the local copy $($doc.LinkFrom)"
                } catch {
                    Write-Log "Couldn't link to the local copy ($($_.Exception.Message)); copying it instead"
                    Copy-FileWithProgress -Src $doc.LinkFrom -Dst $winner -StatusBase $status
                }
            } elseif ($doc.SourceVideo -and [IO.File]::Exists($doc.SourceVideo)) {
                Write-Log "No variant passed: using the converted Dolby Vision copy $($doc.SourceVideo)"
                Copy-FileWithProgress -Src $doc.SourceVideo -Dst $winner -StatusBase $status
            } elseif ($doc.LocalCopy -and [IO.File]::Exists($doc.LocalCopy)) {
                if ($doc.PSObject.Properties['KeepP7'] -and $doc.KeepP7) { Write-Log "Kept as Dolby Vision 7: the untouched local copy becomes $([IO.Path]::GetFileName($doc.Final))" }
                else { Write-Log "No variant passed: using the local copy of the source" }
                Move-Item -LiteralPath $doc.LocalCopy -Destination $winner -ErrorAction Stop
                $doc.LocalCopy = ''
            } else {
                Write-Log "No variant passed: copying the source from $($doc.Source)"
                Copy-FileWithProgress -Src $doc.Source -Dst $winner -StatusBase $status
            }
            Save-Doc 'source in place'
        }
        if (-not $Cfg.NoAudio -and -not $doc.AudioDone) {
            if (-not [IO.File]::Exists($winner)) { $res.Error = "suggested encode not found: $winner"; Write-Log "FINISH FAILED: $($res.Error)"; return }
            $status.Step = 'adding audio (Add-BluRayAudio)'; Set-Status $status
            # Audio and subtitles come from a local copy when there is one (the source's local copy, or a
            # Dolby Vision title's converted 8.1 copy, which keeps every audio and subtitle track);
            # the NAS source otherwise.
            $audioSrc = $doc.Source
            if ($doc.LocalCopy -and [IO.File]::Exists($doc.LocalCopy)) { $audioSrc = $doc.LocalCopy }
            elseif ($doc.PSObject.Properties['AudioSource'] -and $doc.AudioSource -and [IO.File]::Exists($doc.AudioSource)) { $audioSrc = $doc.AudioSource }
            # -Plumbing: its details go to <name>.audio.log, and it reports back one line of JSON
            # (tracks, what was dropped, sync shift, subtitle backup, warnings), kept in final.json.
            $audioLog = Join-Path $titleDir "$base.audio.log"
            $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Cfg.AddAudio, '-Source', $audioSrc, '-Dest', $winner, '-Replace',
                   '-LogPath', $audioLog, '-Plumbing')
            Write-Log "> Add-BluRayAudio -Source `"$audioSrc`" -Dest `"$winner`" -Replace -LogPath `"$audioLog`" -Plumbing"
            $r = Invoke-Logged -Exe $Cfg.Exe -ArgList $a -TempDir $tmp -StatusBase $status -ProgressPattern '^\x00$' -Quiet
            $info = $null
            foreach ($l in $r.Lines) {
                if ($l.TrimStart().StartsWith('{')) { try { $info = $l | ConvertFrom-Json } catch { Write-LogRaw "    $l" } }
                else { Write-LogRaw "    $l" }
            }
            if ($info) { $doc | Add-Member -NotePropertyName Audio -NotePropertyValue $info -Force }
            if ($r.ExitCode -ne 0) {
                $why = "exit $($r.ExitCode)"
                if ($info -and $info.Status -eq 'Failed') { $why = $info.Message }
                elseif ($info -and $info.Subtitles -and $info.Subtitles.Error) { $why = "subtitle backup: $($info.Subtitles.Error)" }
                $res.Error = "Add-BluRayAudio failed: $why (see $audioLog)"
                Write-Log "FINISH FAILED: $($res.Error); nothing moved or deleted"
                if ($info) { Save-Doc $doc.State }
                return
            }
            $n = @(& ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 $winner 2>$null | Where-Object { "$_".Trim() }).Count
            if ($n -lt 1) { $res.Error = 'no audio track in the result'; Write-Log "FINISH FAILED: $($res.Error); nothing moved or deleted"; return }
            if ($info) {
                Write-Log "Audio ($($info.Status)): $($info.Summary)"
                foreach ($d in @($info.Dropped)) { if ($d) { Write-Log "  dropped: audio $($d.SourceTrack) $($d.Name)$(if ($d.Title) { " '$($d.Title)'" }) - $($d.Reason)" } }
                if ($info.Subtitles -and $info.Subtitles.File) { Write-Log "  subtitle backup: $($info.Subtitles.File), $($info.Subtitles.Tracks) track(s)" }
                foreach ($w in @($info.Warnings)) { if ($w) { Write-Log "  WARNING: $w" } }
            } else {
                Write-Log "Audio added: $n track(s) (no details reported; see $audioLog)"
            }
            $doc.AudioDone = $true
            Save-Doc 'audio added'
        }
        if ($doc.PSObject.Properties['Audio'] -and $doc.Audio) {
            $res.Audio = [string]$doc.Audio.Summary
            $res.AudioWarnings = @($doc.Audio.Warnings | Where-Object { $_ })
        }
        # Move up to the mirrored folder (with the subtitle backup).
        $status.Step = 'moving into place'; Set-Status $status
        if ([IO.File]::Exists($winner)) {
            if ([IO.File]::Exists($doc.Final)) { $res.Error = "$($doc.Final) already exists; not overwriting it"; Write-Log "FINISH FAILED: $($res.Error)"; return }
            if ([IO.Path]::GetPathRoot($winner) -ne [IO.Path]::GetPathRoot($doc.Final)) {
                Copy-FileWithProgress -Src $winner -Dst $doc.Final -StatusBase $status   # another drive: with progress
                Remove-Item -LiteralPath $winner -Force -ErrorAction Stop
            } else {
                Move-Item -LiteralPath $winner -Destination $doc.Final -ErrorAction Stop
            }
            Write-Log "Moved to $($doc.Final)"
        } elseif (-not [IO.File]::Exists($doc.Final)) {
            $res.Error = "neither $winner nor $($doc.Final) exists"; Write-Log "FINISH FAILED: $($res.Error)"; return
        }
        $subName = [IO.Path]::GetFileNameWithoutExtension($winner) + '.mks'   # Add-BluRayAudio's subtitle backup
        $subs = Join-Path $winnerDir $subName
        if ([IO.File]::Exists($subs)) { Move-Item -LiteralPath $subs -Destination (Join-Path $titleDir $subName) -Force -ErrorAction Stop }
        Save-Doc 'moved'
        if ([IO.Path]::GetFileName($winnerDir) -eq '_2160p' -and [IO.Directory]::Exists($winnerDir) -and -not @([IO.Directory]::GetFileSystemEntries($winnerDir)).Count) {
            Remove-Item -LiteralPath $winnerDir -Force -ErrorAction SilentlyContinue
        }
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
                # (empty variant folders are removed when the whole folder is done: another
                # title in it may be about to encode into this one)
            }
            $res.Deleted = $count
            $res.FreedGB = [Math]::Round($bytes / 1GB, 2)
            Write-Log ("Deleted {0} file(s) from the other variants, {1} GB freed" -f $count, $res.FreedGB)
        }
        Save-Doc 'done'
        if ($doc.PSObject.Properties['WorkFiles']) {
            foreach ($wf in @($doc.WorkFiles)) {
                if (-not $wf -or -not [IO.File]::Exists($wf)) { continue }
                # A title kept as profile 7 and its 1080p copy share the local profile 7 copy (both read
                # their audio from it): whichever finishes last deletes it.
                if ($doc.PSObject.Properties['SharedFinalJson'] -and $doc.SharedFinalJson -and $wf -like '* - p7 source.mkv') {
                    $pd = $null; try { $pd = [IO.File]::ReadAllText($doc.SharedFinalJson) | ConvertFrom-Json } catch { }
                    if (-not ($pd -and $pd.State -eq 'done')) { Write-Log "Keeping $wf (shared with $([IO.Path]::GetFileName($doc.SharedFinalJson) -replace '\.final\.json$', ''), not finished yet)"; continue }
                }
                $gb = [Math]::Round((New-Object IO.FileInfo $wf).Length / 1GB, 1)
                Remove-Item -LiteralPath $wf -Force -ErrorAction SilentlyContinue
                if (-not [IO.File]::Exists($wf)) { Write-Log "Deleted $wf, $gb GB"; $res.FreedGB = [Math]::Round($res.FreedGB + $gb, 2) }
            }
        }
        if ($doc.LocalCopy -and [IO.File]::Exists($doc.LocalCopy)) {
            $gb = [Math]::Round((New-Object IO.FileInfo $doc.LocalCopy).Length / 1GB, 1)
            Remove-Item -LiteralPath $doc.LocalCopy -Force -ErrorAction SilentlyContinue
            if (-not [IO.File]::Exists($doc.LocalCopy)) { Write-Log "Local copy deleted: $($doc.LocalCopy), $gb GB"; $res.FreedGB = [Math]::Round($res.FreedGB + $gb, 2) }
        }
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
$workRoot = if ($WorkDir) { (Resolve-UserPath $WorkDir).TrimEnd('\', '/') } else { $dstRoot }
if (-not ([IO.File]::Exists($srcPath) -or [IO.Directory]::Exists($srcPath))) { throw "Source not found: $srcPath" }
[void][IO.Directory]::CreateDirectory($dstRoot)

# One run per Dest at a time: two runs would copy, encode and delete the same files.
$lockPath = Join-Path $dstRoot '_encode-batch.lock'
if ([IO.File]::Exists($lockPath)) {
    $other = $null
    try { $other = [IO.File]::ReadAllText($lockPath) | ConvertFrom-Json } catch { }
    $p = if ($other -and $other.Pid) { Get-Process -Id ([int]$other.Pid) -ErrorAction SilentlyContinue } else { $null }
    if ($p -and $p.Id -ne $PID -and $p.ProcessName -match '^(powershell|pwsh)$' -and
        ([Math]::Abs(($p.StartTime - [datetime]$other.Started).TotalSeconds) -lt 5)) {
        throw "Another Encode-Batch is already running on $dstRoot (PID $($other.Pid), started $($other.Started)). Stop it first, or delete $lockPath if that's wrong."
    }
}

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
if ($workRoot -ne $dstRoot) {
    [void][IO.Directory]::CreateDirectory($workRoot)
    Write-Log "Work:   $workRoot ($(Get-FreeGB $workRoot) GB free): local copies and Dolby Vision 7 conversions"
}
if ($fixedMode) { Write-Log "Mode: fixed variants" } else { Write-Log "Mode: ladder search, target $TargetPct% of the source, cap $MaxPct% (rungs weakest first)" }
$ri = 0
foreach ($s in $specs) { Write-Log ("{0} '{1}': {2}" -f $(if ($fixedMode) { 'Variant' } else { "Rung $ri" }), $s.Name, ($s.Args -join ' ')); $ri++ }
Write-Log "Bar: mean >= $MinMean, p1 >= $MinP1, min >= $MinMin, video <= $MaxPct% of the source's; top bar (under $TargetPct%, good enough): mean >= $TopMean, p1 >= $TopP1, min >= $TopMin"

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
        -not $_.FullName.StartsWith($workRoot + $sep, [StringComparison]::OrdinalIgnoreCase) -and
        $_.Name -notmatch ' - p7 source\.mkv$| - p8\.1\.mkv$| - source\.mkv$|\.partial\.mkv$'
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
        WorkDir = $(if ($rel) { Join-Path $workRoot $rel } else { $workRoot })
        Folder = $f.DirectoryName   # titles in the same source folder share ladder starting points
        Order = $titleList.Count
        State = 'queued'          # queued -> prepping -> ready -> done | skipped | failed
        Info = $null; Prep = $null; Tasks = @(); Start = $null; Reason = ''; StartRungs = $null; WaitingOn = ''; Seeded = $false; Skipped = @{}; SkipLogged = @()
        Finalize = ''; FinalDoc = $null; FinalJson = (Join-Path $titleDir "$base.final.json"); Resolved = ''
        IsDerived = $false; ParentBase = ''; HoldFor = $null; RefSources = @(); SourcePeak = 0
    })
}

# ---------------------------------------------------------------- run
$results = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[object]
$finished = New-Object System.Collections.Generic.List[object]
$doviNotes = New-Object System.Collections.Generic.List[object]
$running = @{}                       # job id -> info
$slots = New-Object object[] $Threads
$vmafSlots = New-Object object[] $VmafThreads
$stopDispatch = $false
$script:spaceWaitLogged = ''
$prepStatusFile = Join-Path $tempDir 'prep.json'
$folderSeed = @{}                    # source folder -> rung index the last finished title there picked
$folderRef = @{}                     # source folder -> @{ Name; Pick; Rows } (see Set-FolderMemory)
$specNames = @($specs | ForEach-Object { $_.Name })

# A title kept as Dolby Vision 7 gets a 1080p SDR copy: its own title "<name> - 1080p", right after
# it in the list, made from the profile 7 video (the local copy, else the finished 2160p file, else
# the source) and searched/finished like any other. Its parent's finish (which moves the local
# copy away) waits until the 1080p reference exists (HoldFor).
function Add-DerivedTitle($t) {
    $dBase = "$($t.Base) - 1080p"
    $have = @($titleList | Where-Object { $_.IsDerived -and $_.Base -eq $dBase -and $_.TitleDir -eq $t.TitleDir })
    if ($have.Count) { $t.HoldFor = $have[0]; return $have[0] }
    $peak = 0
    if ($t.Info -and $t.Info.MaxCll) { [void][int]::TryParse(([string]$t.Info.MaxCll -split ',')[0], [ref]$peak) }
    $d = [pscustomobject]@{
        File = $t.File; Rel = ($t.Rel -replace '\.mkv$', ' - 1080p.mkv'); TitleDir = $t.TitleDir; Base = $dBase
        LogPath = (Join-Path $t.TitleDir "$dBase.encode.log"); WorkDir = $t.WorkDir
        Folder = "$($t.Folder)|1080p"   # 1080p copies share ladder starting points only with each other
        Order = $t.Order + 0.5; State = 'queued'
        Info = $null; Prep = $null; Tasks = @(); Start = $null; Reason = ''; StartRungs = $null; WaitingOn = ''; Seeded = $false; Skipped = @{}; SkipLogged = @()
        Finalize = ''; FinalDoc = $null; FinalJson = (Join-Path $t.TitleDir "$dBase.final.json"); Resolved = ''
        IsDerived = $true; ParentBase = $t.Base; HoldFor = $null; CropHw = $false
        RefSources = @((Get-WorkFile $t ' - p7 source.mkv'), (Join-Path $t.TitleDir "$($t.Base) - 2160p.mkv"), $t.File)
        SourcePeak = $peak
    }
    $titleList.Insert($titleList.IndexOf($t) + 1, $d)
    $t.HoldFor = $d
    $d
}

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

# ---- subtitle bundles: <folder> - subtitles.zip once every title of the folder is done
$zipDirs = @{}                       # Dest folders with subtitle backups waiting to be bundled

function Get-LooseSubtitles([string]$Dir) {
    if (-not [IO.Directory]::Exists($Dir)) { return @() }
    @([IO.Directory]::GetFiles($Dir, '*.mks') | Where-Object { [IO.Path]::GetExtension($_) -eq '.mks' })
}

function Test-FolderDone([string]$Dir) {
    foreach ($o in $titleList) {
        if ($o.TitleDir -ne $Dir) { continue }
        if ($o.State -eq 'queued' -or $o.State -eq 'prepping' -or $o.State -eq 'ready') { return $false }
        if ($o.Finalize -eq 'pending' -or $o.Finalize -eq 'running') { return $false }
    }
    $true
}

# Adds the folder's loose .mks files to "<folder> - subtitles.zip" (stored, no compression),
# keeping what's already in it, then deletes the loose files once the zip is verified.
function Compress-FolderSubtitles([string]$Dir) {
    $loose = @(Get-LooseSubtitles $Dir)
    if (-not $loose.Count) { return }
    $zip = Join-Path $Dir ((Split-Path -Leaf $Dir) + ' - subtitles.zip')
    $part = "$zip.partial"
    try {
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $stored = [IO.Compression.CompressionLevel]::NoCompression
        $new = @{}; foreach ($f in $loose) { $new[[IO.Path]::GetFileName($f)] = $true }
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        $outFs = New-Object IO.FileStream($part, [IO.FileMode]::CreateNew)
        $out = New-Object IO.Compression.ZipArchive($outFs, [IO.Compression.ZipArchiveMode]::Create)
        try {
            if ([IO.File]::Exists($zip)) {   # carry over what's already bundled (streamed, not in memory)
                $in = [IO.Compression.ZipFile]::OpenRead($zip)
                try {
                    foreach ($e in $in.Entries) {
                        if ($new.ContainsKey($e.FullName)) { continue }
                        $ne = $out.CreateEntry($e.FullName, $stored); $ne.LastWriteTime = $e.LastWriteTime
                        $src = $e.Open(); $dst = $ne.Open()
                        try { $src.CopyTo($dst) } finally { $dst.Dispose(); $src.Dispose() }
                    }
                } finally { $in.Dispose() }
            }
            foreach ($f in $loose) { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($out, $f, [IO.Path]::GetFileName($f), $stored) }
        } finally { $out.Dispose(); $outFs.Dispose() }
        $chk = [IO.Compression.ZipFile]::OpenRead($part)
        try {
            foreach ($f in $loose) {
                $e = $chk.GetEntry([IO.Path]::GetFileName($f))
                if (-not $e -or $e.Length -ne (New-Object IO.FileInfo $f).Length) { throw "verification failed for $([IO.Path]::GetFileName($f))" }
            }
            $total = $chk.Entries.Count
        } finally { $chk.Dispose() }
        Move-Item -LiteralPath $part -Destination $zip -Force -ErrorAction Stop
        foreach ($f in $loose) { Remove-Item -LiteralPath $f -Force -ErrorAction Stop }
        Write-Log ("ZIP   {0}: {1} subtitle backup(s) added to {2} ({3} in total)" -f $Dir, $loose.Count, (Split-Path -Leaf $zip), $total) 'Cyan'
    } catch {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        Write-Log "Couldn't bundle the subtitle backups in ${Dir}: $($_.Exception.Message) (loose .mks files kept)" 'Yellow'
    }
}

# Once nothing in the folder is in progress: bundle its subtitle backups and remove the variant
# folders (rungs, _source) that finishing left empty.
function Invoke-SubtitleBundles {
    foreach ($d in @($zipDirs.Keys)) {
        if (-not (Test-FolderDone $d)) { continue }
        $zipDirs.Remove($d)
        Compress-FolderSubtitles $d
        foreach ($name in @($specs | ForEach-Object { $_.Name }) + '_source') {
            $vd = Join-Path $d $name
            if ([IO.Directory]::Exists($vd) -and -not @([IO.Directory]::GetFileSystemEntries($vd)).Count) {
                Remove-Item -LiteralPath $vd -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# $Resolved: set when nothing more will happen to this title with the current settings (it
# counts as complete for the whole-batch report), e.g. 'Skipped' for VC-1.
function Add-Skip($t, [string]$reason, [string]$Resolved = '') {
    $t.State = 'skipped'; $t.Reason = $reason; $t.Resolved = $Resolved
    if (Get-LooseSubtitles $t.TitleDir) { $zipDirs[$t.TitleDir] = $true }
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
        $i = Get-LadderNext -Tried $Tried -Count $specs.Count -Start $Start -MinMean $MinMean -MinP1 $MinP1 -MinMin $MinMin -MaxPct $MaxPct -TargetPct $TargetPct -Skip $Skipped -TopMean $TopMean -TopP1 $TopP1 -TopMin $TopMin
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
        if ($null -ne $pick.Pct -and $pick.Pct -lt $TargetPct -and -not $pick.Top) { $pick.Hint = "under $TargetPct%: try a lower CQP / more AQ" }
        return
    }
    $i = Get-RungIndex $sugg
    $byRung = @{}
    foreach ($task in $t.Tasks) { if ($task.State -eq 'done' -and $task.Row) { $byRung[[int]$task.Rung] = $task.Row } }
    Set-FolderMemory $t.Folder $t.Base $byRung $i
    if ($null -ne $pick.Pct -and $pick.Pct -lt $TargetPct -and $i -eq $specs.Count - 1 -and -not $pick.Top) { $pick.Hint = "under $TargetPct% at the strongest rung: add a lower-CQP rung" }
    elseif ($null -ne $pick.Pct -and $pick.Pct -gt $TargetPct -and $i -eq 0) { $pick.Hint = "over $TargetPct% at the weakest rung: a higher-CQP rung may pass smaller" }
}

function Get-VariantDirs($t) { @($specs | ForEach-Object { Join-Path $t.TitleDir $_.Name }) }

# The title's local source copy ("<name> - source.mkv"), if there is one.
# A working file ("<name> - source.mkv", " - p7 source.mkv", " - p8.1.mkv"): in the work folder,
# or in Dest where runs without -WorkDir (or older versions) put it; the work folder if neither.
function Get-WorkFile($t, [string]$suffix) {
    $w = Join-Path $t.WorkDir "$($t.Base)$suffix"
    if ([IO.File]::Exists($w)) { return $w }
    $d = Join-Path $t.TitleDir "$($t.Base)$suffix"
    if ([IO.File]::Exists($d)) { return $d }
    $w
}

function Get-LocalCopyPath($t) {
    if ($t.Prep -and $t.Prep.PSObject.Properties['LocalCopy'] -and $t.Prep.LocalCopy) { return [string]$t.Prep.LocalCopy }
    $lc = Get-WorkFile $t ' - source.mkv'
    if ([IO.File]::Exists($lc)) { return $lc }
    ''
}

# Deletes the local copy (and with -Dovi, a Dolby Vision 7 title's p7 copy and converted p8.1 too).
function Remove-LocalCopy($t, [string]$why, [switch]$Dovi) {
    $lc = Get-LocalCopyPath $t
    $list = @($lc, $(if ($lc) { "$lc.partial" }), (Join-Path $t.WorkDir "$($t.Base) - source.mkv.partial"))
    if ($Dovi) {
        $keepCopy = $false
        if ($t.HoldFor) {
            $dd = $null; try { $dd = [IO.File]::ReadAllText($t.HoldFor.FinalJson) | ConvertFrom-Json } catch { }
            $keepCopy = -not ($dd -and $dd.State -eq 'done')   # its 1080p copy still needs it for audio
        }
        foreach ($wf in @(Get-DoviWorkFiles $t)) {
            if ($keepCopy -and $wf -like '* - p7 source.mkv') { continue }
            $list += @($wf, "$wf.partial")
        }
    }
    foreach ($f in $list) {
        if (-not $f -or -not [IO.File]::Exists($f)) { continue }
        $gb = [Math]::Round((Get-Item -LiteralPath $f).Length / 1GB, 1)
        try {
            Remove-Item -LiteralPath $f -Force -ErrorAction Stop
            Add-LogText $t.LogPath ("{0:yyyy-MM-dd HH:mm:ss}  Local copy deleted ({1}): {2}, {3} GB`r`n" -f (Get-Date), $why, $f, $gb)
        } catch { Write-Log "Couldn't delete local copy ${f}: $($_.Exception.Message)" 'Yellow' }
    }
}

# Queues the finish (audio, move up, delete the rest) for a title with a suggested variant.
function Request-Finalize($t, $rows, [string]$sugg) {
    $doc = [ordered]@{
        Title = $t.Rel; Source = $t.File; Variant = $sugg
        Winner = (Join-Path (Join-Path $t.TitleDir $sugg) "$($t.Base).mkv")
        Final = (Join-Path $t.TitleDir "$($t.Base).mkv")
        AudioDone = [bool]$NoAudio; State = 'pending'; Variants = @($rows); LocalCopy = (Get-LocalCopyPath $t)
        WorkFiles = @(Get-DoviWorkFiles $t); AudioSource = (Get-AudioSourceCopy $t)
        SharedFinalJson = $(if ($t.IsDerived) { Join-Path $t.TitleDir "$($t.ParentBase).final.json" } else { '' })
    }
    [IO.File]::WriteAllText($t.FinalJson, ($doc | ConvertTo-Json -Depth 6), $script:Utf8)
    $t.FinalDoc = [pscustomobject]$doc
    $t.Finalize = 'pending'
}

# A local file to take the audio from when there's no plain local copy: a Dolby Vision title's
# converted 8.1 copy (same audio and subtitle tracks as the source). Not for 1080p copies, whose
# reference has no audio. '' = use the source.
function Get-AudioSourceCopy($t) {
    if ($t.IsDerived) {
        $pc = Get-ParentP7Copy $t
        if ($pc -and [IO.File]::Exists($pc)) { return $pc }
        return ''
    }
    $p81 = Get-WorkFile $t ' - p8.1.mkv'
    if ([IO.File]::Exists($p81)) { return $p81 }
    ''
}

# A 1080p copy's parent's local profile 7 copy (work folder, or Dest from older runs).
function Get-ParentP7Copy($t) {
    foreach ($d in $t.WorkDir, $t.TitleDir) {
        $f = Join-Path $d "$($t.ParentBase) - p7 source.mkv"
        if ([IO.File]::Exists($f)) { return $f }
    }
    ''
}

# A Dolby Vision 7 title's converted copy (and any leftover p7 copy), or a 1080p copy's SDR
# reference: deleted once the title is finished.
function Get-DoviWorkFiles($t) {
    if ($t.IsDerived) {
        $ref = if ($t.Prep) { [string]$t.Prep.WorkSrc } else { Join-Path $t.WorkDir "$($t.ParentBase) - 1080p ref.mkv" }
        return @(@($ref, (Get-ParentP7Copy $t)) | Where-Object { $_ -and [IO.File]::Exists($_) })
    }
    @(' - p8.1.mkv', ' - p7 source.mkv' | ForEach-Object { Get-WorkFile $t $_ } | Where-Object { [IO.File]::Exists($_) })
}

# A title kept as Dolby Vision 7: its untouched local copy gets the audio and becomes
# "<name> - 2160p.mkv" (same finishing steps as -UseSourceFallback, no encode).
# A finish that can start now: pending, and (for a profile 7 title) its 1080p copy has made its
# reference from the local copy the finish is about to move away.
function Test-FinalizeReady($t) {
    $t.Finalize -eq 'pending' -and -not ($t.HoldFor -and
        ($t.HoldFor.State -eq 'prepping' -or ($t.HoldFor.State -eq 'queued' -and -not $stopDispatch)))
}

# The 2160p file starts as a hard link to the local copy (in the work folder, no extra space):
# Add-BluRayAudio reads the untouched copy and replaces the link with the remux. The copy stays
# for the 1080p copy's audio and is deleted when that one is finished.
function Request-FinalizeP7($t, [string]$p7copy, [string]$why) {
    $name = "$($t.Base) - 2160p.mkv"
    $doc = [ordered]@{
        Title = $t.Rel; Source = $t.File; Variant = 'p7 original'; FromSource = $true; KeepP7 = $why
        Winner = (Join-Path (Join-Path ([IO.Path]::GetDirectoryName($p7copy)) '_2160p') $name)
        Final = (Join-Path $t.TitleDir $name)
        SourceVideo = ''; LinkFrom = $p7copy; AudioSource = $p7copy
        AudioDone = [bool]$NoAudio; State = 'pending'; Variants = @(); LocalCopy = ''; WorkFiles = @($p7copy)
        SharedFinalJson = (Join-Path $t.TitleDir "$($t.Base) - 1080p.final.json")
    }
    [IO.File]::WriteAllText($t.FinalJson, ($doc | ConvertTo-Json -Depth 6), $script:Utf8)
    $t.FinalDoc = [pscustomobject]$doc
    $t.Finalize = 'pending'
}

# -UseSourceFallback: finish a title that has no passing variant with its source instead.
function Request-FinalizeSource($t, $rows) {
    $p81 = Get-WorkFile $t ' - p8.1.mkv'
    if ($t.IsDerived -and $t.Prep) { $p81 = [string]$t.Prep.WorkSrc }   # 1080p copy: its SDR reference is "the source"
    $doc = [ordered]@{
        Title = $t.Rel; Source = $t.File; Variant = 'source'; FromSource = $true
        Winner = (Join-Path (Join-Path $t.TitleDir '_source') "$($t.Base).mkv")
        Final = (Join-Path $t.TitleDir "$($t.Base).mkv")
        SourceVideo = $(if ([IO.File]::Exists($p81)) { $p81 } else { '' })
        AudioDone = [bool]$NoAudio; State = 'pending'; Variants = @($rows); LocalCopy = (Get-LocalCopyPath $t)
        WorkFiles = @(Get-DoviWorkFiles $t); AudioSource = (Get-AudioSourceCopy $t)
        SharedFinalJson = $(if ($t.IsDerived) { Join-Path $t.TitleDir "$($t.ParentBase).final.json" } else { '' })
    }
    [IO.File]::WriteAllText($t.FinalJson, ($doc | ConvertTo-Json -Depth 6), $script:Utf8)
    $t.FinalDoc = [pscustomobject]$doc
    $t.Finalize = 'pending'
    Add-LogText $t.LogPath ("{0:yyyy-MM-dd HH:mm:ss}  -UseSourceFallback: no variant passed, so the source will be finished instead.`r`n" -f (Get-Date))
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
        $sugg = Set-Suggestion -Rows $rows -MinMean $MinMean -MinP1 $MinP1 -MinMin $MinMin -MaxPct $MaxPct -TargetPct $TargetPct -TopMean $TopMean -TopP1 $TopP1 -TopMin $TopMin
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

    $topPick = $sugg -and @($rows | Where-Object { $_.Suggested -and $_.PSObject.Properties['Top'] -and $_.Top }).Count
    $verdict = if ($sugg) { $sugg + $(if ($topPick) { " (meets the top bar under $TargetPct%: taking the savings)" } elseif ($hint) { " ($hint)" } else { '' }) } elseif ($done) { "none - no variant passes within the cap, keep the original; closest: $(Get-ClosestMiss $rows)" } else { 'none' }
    $lines = @('', ('{0:yyyy-MM-dd HH:mm:ss}  Bar: mean >= {1}, p1 >= {2}, min >= {3}, size <= {4}%, target {5}%. Suggested: {6}' -f `
        (Get-Date), $MinMean, $MinP1, $MinMin, $MaxPct, $TargetPct, $verdict))
    $lines += Format-VariantTable $rows
    foreach ($k in @($t.Skipped.Keys | Sort-Object)) { $lines += "  ($($t.Skipped[$k]))" }
    $lines += ('{0:yyyy-MM-dd HH:mm:ss}  RESULT: {1}{2}' -f (Get-Date), $st, $(if ($res.Reason) { " - $($res.Reason)" } else { '' }))
    Add-LogText $t.LogPath (($lines -join "`r`n") + "`r`n")
    [IO.File]::WriteAllText((Join-Path $t.TitleDir "$($t.Base).results.json"), ($res | ConvertTo-Json -Depth 5), $script:Utf8)
    if ($finishing -and $sugg) { Request-Finalize $t $rows $sugg }
    elseif ($finishing -and $UseSourceFallback -and -not $fixedMode -and -not $SkipVmaf -and $done) { Request-FinalizeSource $t $rows }
    else {
        if ($st -eq 'Done') { $t.Resolved = $(if ($fixedMode) { 'Done (fixed variants)' } elseif ($sugg) { 'Searched (finishing off)' } elseif ($SkipVmaf) { 'Encoded (no VMAF)' } else { 'No variant passed' }) }
        if ($finishing -and -not $SkipVmaf) { Add-LogText $t.LogPath ("{0:yyyy-MM-dd HH:mm:ss}  No suggested variant: all variants kept for review.`r`n" -f (Get-Date)) }
        Remove-LocalCopy $t $(if ($sugg) { 'title finished' } else { 'title finished without a suggested variant' })
    }

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
        CropDetect = $CropDetect; MinFreeDoviGB = $MinFreeDoviGB; LocalCopy = [bool]$LocalCopy; WorkDir = $t.WorkDir; DoviOvershootNits = $DoviOvershootNits
        NVEncC = $NVEncC; Derived = [bool]$t.IsDerived; ParentBase = $t.ParentBase; CropHw = [bool]($t.IsDerived -and $t.CropHw); RefSources = @($t.RefSources); SourcePeak = $t.SourcePeak
    }
    $job = Start-Job -ScriptBlock $PrepWorker -ArgumentList ($cfg | ConvertTo-Json -Depth 6 -Compress)
    $running[$job.Id] = [pscustomobject]@{ Job = $job; Kind = 'prep'; Title = $t; Task = $null; Slot = -1; Start = Get-Date; StatusFile = $prepStatusFile }
}

function Start-Finalize($t) {
    $t.Finalize = 'running'
    # (a title kept as Dolby Vision 7 finishes its own local copy, already named in its doc)
    if (-not ($t.FinalDoc.PSObject.Properties['KeepP7'] -and $t.FinalDoc.KeepP7)) {
        $t.FinalDoc | Add-Member -NotePropertyName LocalCopy -NotePropertyValue (Get-LocalCopyPath $t) -Force
        # (a finish saved by an older version doesn't name the local 8.1 copy to take the audio from)
        if (-not ($t.FinalDoc.PSObject.Properties['AudioSource'] -and $t.FinalDoc.AudioSource -and [IO.File]::Exists([string]$t.FinalDoc.AudioSource))) {
            $t.FinalDoc | Add-Member -NotePropertyName AudioSource -NotePropertyValue (Get-AudioSourceCopy $t) -Force
        }
    }
    $statusFile = Join-Path $tempDir 'finish.json'
    Remove-Item -LiteralPath $statusFile -Force -ErrorAction SilentlyContinue
    $cfg = @{
        Helpers = $Helpers.ToString(); EnvPath = $env:PATH; RunId = $runId
        BaseName = $t.Base; TitleDir = $t.TitleDir; LogPath = $t.LogPath; StatusFile = $statusFile; TempDir = $tempDir; Wsl = $wsl
        Doc = $t.FinalDoc; FinalJson = $t.FinalJson
        VariantDirs = @(Get-VariantDirs $t) + @($(if ($t.FinalDoc.PSObject.Properties['FromSource'] -and $t.FinalDoc.FromSource) { Split-Path -Parent $t.FinalDoc.Winner }))
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
            if (@($all | Where-Object { $_ }).Count -eq $specs.Count) { Add-Skip $t 'all variants already finished' 'Done (fixed variants)'; continue }
        } else {
            # Finished (or being finished) by an earlier run: final.json.
            if ([IO.File]::Exists($t.FinalJson)) {
                $fd = $null
                try { $fd = [IO.File]::ReadAllText($t.FinalJson) | ConvertFrom-Json } catch { }
                if ($fd -and $fd.Variant) {
                    Set-FolderMemoryFromRows $t $fd.Variants $fd.Variant
                    if ($fd.State -eq 'done') { Remove-LocalCopy $t 'left over from an earlier run' -Dovi; Add-Skip $t "finished: $($fd.Variant) -> $($fd.Final)"; continue }
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
                $best = Set-Suggestion -Rows @($tried.Values) -MinMean $MinMean -MinP1 $MinP1 -MinMin $MinMin -MaxPct $MaxPct -TargetPct $TargetPct -TopMean $TopMean -TopP1 $TopP1 -TopMin $TopMin
                if (($best -or $UseSourceFallback) -and $finishing) {
                    # Searched by an earlier run but not finished: finish it now (no prep needed);
                    # with -UseSourceFallback, titles where nothing passed are finished with the source.
                    $tasks = @(); foreach ($k in @($tried.Keys | Sort-Object)) { $tasks += [pscustomobject]@{ Spec = $specs[$k]; Rung = [int]$k; Index = $tasks.Count + 1; State = 'done'; Row = $tried[$k] } }
                    $t.Tasks = $tasks; $t.StartRungs = @(); $t.State = 'ready'
                    Write-Log "DONE  $($t.Rel): ladder search already finished on disk" 'Cyan'
                    Complete-Title $t
                    continue
                }
                if ($best) { Set-FolderMemory $t.Folder $t.Base $tried (Get-RungIndex $best) }
                Remove-LocalCopy $t 'left over from an earlier run'
                Add-Skip $t ("ladder search already finished ({0})" -f $(if ($best) { "suggested: $best" } else { "no rung passed; closest: $(Get-ClosestMiss @($tried.Values))" })) $(if ($best) { 'Searched (finishing off)' } else { 'No variant passed' })
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

        if ($t.IsDerived -and -not $t.Info) {
            # The 1080p SDR copy: the parent's picture info, minus HDR / Dolby Vision (sizes come from prep).
            $pi = $null
            $par = @($titleList | Where-Object { -not $_.IsDerived -and $_.Base -eq $t.ParentBase -and $_.TitleDir -eq $t.TitleDir })
            if ($par.Count -and $par[0].Info) { $pi = $par[0].Info }
            if (-not $pi) { try { $pi = Get-SourceInfo $t.File } catch { Add-Skip $t "probe failed: $($_.Exception.Message)"; continue } }
            if (-not $t.SourcePeak -and $pi.MaxCll) { $pk = 0; if ([int]::TryParse(([string]$pi.MaxCll -split ',')[0], [ref]$pk)) { $t.SourcePeak = $pk } }
            $t.CropHw = ($pi.Width -ge 3800)
            $t.Info = [pscustomobject]@{ Codec = 'hevc'; Width = 1920; Height = 1080; Fps = $pi.Fps; Duration = $pi.Duration; Transfer = 'bt709'
                Hdr = $false; Hdr10Plus = $false; ColorArgs = @(); MasterDisplay = ''; MaxCll = ''; Dv = 'None'; DvDetail = '1080p SDR copy of a profile 7 title' }
        }
        if (-not $t.Info) { try { $t.Info = Get-SourceInfo $t.File } catch { Add-Skip $t "probe failed: $($_.Exception.Message)"; continue } }
        $info = $t.Info
        if ($SkipVC1 -and $info.Codec -eq 'vc1') { Add-Skip $t 'VC-1 source (-SkipVC1)' 'Skipped'; continue }
        if ($info.Dv -ne 'None' -and $info.Dv -ne 'P7' -and $info.Dv -ne 'P8.1') { Add-Skip $t "unsupported Dolby Vision: $($info.Dv) [$($info.DvDetail)]" 'Skipped'; continue }
        if ($info.Dv -eq 'P7' -and -not $doviAvailable) { Add-Skip $t 'Dolby Vision 7 but dovi_convert is unavailable'; continue }
        $isP7 = ($info.Dv -eq 'P7')
        # Dolby Vision 7: at most -MaxDoviTitles hold work files at once (this one waits its turn).
        if ($isP7) {
            $inFlight = @($titleList | Where-Object { $_ -ne $t -and $_.Info -and $_.Info.Dv -eq 'P7' -and
                ($_.State -eq 'prepping' -or $_.State -eq 'ready' -or $_.Finalize -eq 'pending' -or $_.Finalize -eq 'running') }).Count
            if ($inFlight -ge $MaxDoviTitles) { continue }
        }

        [void][IO.Directory]::CreateDirectory($t.TitleDir)
        [void][IO.Directory]::CreateDirectory($t.WorkDir)
        $free = Get-FreeGB $t.TitleDir
        $workFree = Get-FreeGB $t.WorkDir
        $sameDrive = ([IO.Path]::GetPathRoot($t.TitleDir) -eq [IO.Path]::GetPathRoot($t.WorkDir))
        # What it still needs to copy into the work folder (nothing if a complete copy is there).
        $needGB = 0; $workNeed = 0; $workWhy = ''
        if ($isP7) {
            $p81 = Get-WorkFile $t ' - p8.1.mkv'; $p7c = Get-WorkFile $t ' - p7 source.mkv'
            if (-not [IO.File]::Exists($p81) -and -not [IO.File]::Exists($p7c)) { $workNeed = $MinFreeDoviGB; $workWhy = "$MinFreeDoviGB GB (-MinFreeDoviGB) to download and convert Dolby Vision 7" }
        } elseif ($LocalCopy -and -not $t.IsDerived) {
            $srcLen = (Get-Item -LiteralPath $t.File).Length
            $lc = Get-WorkFile $t ' - source.mkv'
            if (-not ([IO.File]::Exists($lc) -and (Get-Item -LiteralPath $lc).Length -eq $srcLen)) {
                $needGB = [Math]::Round($srcLen / 1GB, 1)
                $workNeed = $needGB + 20; $workWhy = "$needGB GB for its local copy + 20"
            }
        }
        $short = ''; $shortKey = ''
        if ($sameDrive) {
            $want = [Math]::Max([double]($MinFreeGB + $needGB), [double]$(if ($isP7) { $workNeed } else { 0 }))
            if ($free -lt $want) { $shortKey = "$($t.Rel)|dest"; $short = "only $free GB free on $dstRoot ($($t.Rel) needs $want GB: -MinFreeGB $MinFreeGB$(if ($workWhy) { "; $workWhy" }))" }
        } else {
            if ($free -lt $MinFreeGB) { $shortKey = "$($t.Rel)|dest"; $short = "only $free GB free on $dstRoot ($($t.Rel) needs -MinFreeGB $MinFreeGB for the encodes)" }
            elseif ($workFree -lt $workNeed) { $shortKey = "$($t.Rel)|work"; $short = "only $workFree GB free on the work drive $workRoot ($($t.Rel) needs $workWhy)" }
        }
        if ($short) {
            $busy = $running.Count -or @($titleList | Where-Object { $_.State -eq 'prepping' -or $_.State -eq 'ready' -or $_.Finalize -eq 'pending' -or $_.Finalize -eq 'running' }).Count
            if (-not $busy) {
                $script:stopDispatch = $true
                Write-Log "$(($short.Substring(0,1)).ToUpper())$($short.Substring(1)), and nothing left running to free space: not starting any more titles." 'Red'
            } elseif ($script:spaceWaitLogged -ne $shortKey) {
                $script:spaceWaitLogged = $shortKey
                Write-Log "$(($short.Substring(0,1)).ToUpper())$($short.Substring(1)): waiting for titles in progress to finish and free space." 'Yellow'
            }
            return $null
        }
        if ($script:spaceWaitLogged) { $script:spaceWaitLogged = ''; Write-Log "Enough space again: starting titles." 'Green' }
        Write-Log ("PREP  {0}  ({1}{2}, {3} GB free{4})  log: {5}" -f $t.Rel, $info.Codec,
            $(if ($info.Dv -ne 'None') { ", DV $($info.Dv)" } elseif ($info.Hdr) { ', HDR' } else { '' }), $free,
            $(if (-not $sameDrive) { ", work drive $workFree GB" } else { '' }), $t.LogPath) 'Cyan'
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

# ---- whole-batch report: every title under -Source, from what's saved on disk (any run)
function Read-JsonFile([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return $null }
    try { [IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { $null }
}

# Crop (<name>.crop.json) and audio (what Add-BluRayAudio reported, kept in final.json) for the reports.
function Get-TitleExtras($t, $fd) {
    $audio = $null
    if ($fd -and $fd.PSObject.Properties['Audio']) { $audio = $fd.Audio }
    $dvBase = if ($t.IsDerived) { $t.ParentBase } else { $t.Base }
    [pscustomobject]@{ Crop = (Read-JsonFile (Join-Path $t.TitleDir "$($t.Base).crop.json")); Audio = $audio
                       Dovi = (Read-JsonFile (Join-Path $t.TitleDir "$dvBase.dovi.json")); Derived = [bool]$t.IsDerived }
}

# One line on what happened to a Dolby Vision 7 title (from "<name>.dovi.json"), or ''.
function Format-DoviNote($ex) {
    $d = $ex.Dovi
    if (-not $d) { return '' }
    switch ([string]$d.Decision) {
        'convert'           { 'profile 7 converted to 8.1' + $(if ($d.Verdict) { " (inspect: $($d.Verdict))" }) }
        'convert-overshoot' { [string]$d.Note }
        'keep-p7'           { if ($ex.Derived) { "1080p SDR copy of a title kept as profile 7 ($($d.Note))" } else { "kept as profile 7 ($($d.Note)); a 1080p SDR copy is made alongside" } }
        default             { '' }
    }
}

# Markdown bullets: video dimensions and crop, audio tracks, subtitles to fix, audio warnings.
function Format-TitleExtras($ex, [string]$pick) {
    $dn = Format-DoviNote $ex
    if ($dn) { "- **Dolby Vision:** $dn" }
    $c = $ex.Crop
    if ($c -and $pick -eq 'p7 original') {
        "- **Video:** source $($c.SourceWidth)x$($c.SourceHeight), kept as is (the profile 7 original, not cropped or encoded)"
        $c = $null
    }
    if ($c) {
        $cropText = if (($c.Top + $c.Bottom + $c.Left + $c.Right) -gt 0) {
            "crop top $($c.Top), bottom $($c.Bottom), left $($c.Left), right $($c.Right)"
        } else { 'no crop' }
        $line = "- **Video:** source $($c.SourceWidth)x$($c.SourceHeight), encoded $($c.Width)x$($c.Height) ($cropText$(if ($c.PSObject.Properties['Scaled'] -and $c.Scaled) { ', scaled to fit 1080p, SDR' }))"
        if ($pick -eq 'source') { $line += '; the finished file is the uncropped source' }
        $line
    }
    $a = $ex.Audio
    if ($a) {
        $line = "- **Audio:** $(if ($a.Summary) { $a.Summary } else { 'none reported' })"
        $drops = @($a.Dropped | Where-Object { $_ } | ForEach-Object { "audio $($_.SourceTrack) $($_.Name) ($($_.Reason))" })
        if ($drops.Count) { $line += "; dropped: $($drops -join ', ')" }
        $line
        if ($a.SubtitleShift) { "- **Subtitles to fix:** $($a.SubtitleShift)" }
        $warn = @($a.Warnings | Where-Object { $_ -and $_ -notlike 'SUBTITLES TO FIX:*' })
        if ($warn.Count) { "- **Audio warnings:** $($warn -join '; ')" }
    }
}

# CSV columns for the same (repeated on each of a title's rows).
function Get-ExtrasColumns($ex) {
    $c = $ex.Crop; $a = $ex.Audio
    [ordered]@{
        DolbyVision = (Format-DoviNote $ex)
        SourceWidth = $(if ($c) { $c.SourceWidth }); SourceHeight = $(if ($c) { $c.SourceHeight })
        EncodedWidth = $(if ($c) { $c.Width }); EncodedHeight = $(if ($c) { $c.Height })
        CropTop = $(if ($c) { $c.Top }); CropBottom = $(if ($c) { $c.Bottom }); CropLeft = $(if ($c) { $c.Left }); CropRight = $(if ($c) { $c.Right })
        Audio = $(if ($a) { [string]$a.Summary } else { '' })
        AudioTracks = $(if ($a) { @($a.Tracks | Where-Object { $_ }).Count })
        AudioDropped = $(if ($a) { (@($a.Dropped | Where-Object { $_ } | ForEach-Object { "audio $($_.SourceTrack) $($_.Name) ($($_.Reason))" })) -join '; ' } else { '' })
        AudioSyncMs = $(if ($a) { $a.SyncMs })
        SubtitleShift = $(if ($a) { [string]$a.SubtitleShift } else { '' })
        AudioWarnings = $(if ($a) { (@($a.Warnings | Where-Object { $_ -and $_ -notlike 'SUBTITLES TO FIX:*' })) -join '; ' } else { '' })
    }
}

# Where a title stands overall. Resolved = nothing more will happen with the current settings.
function Get-TitleOutcome($t) {
    $o = [ordered]@{ Title = $t.Rel; Outcome = ''; Detail = ''; Pick = ''; Final = ''; Rows = @(); Resolved = $false; LogPath = $t.LogPath; Extras = $null }
    $fd = Read-JsonFile $t.FinalJson
    $o.Extras = Get-TitleExtras $t $fd
    $rj = Read-JsonFile (Join-Path $t.TitleDir "$($t.Base).results.json")
    if ($fd -and $fd.State -eq 'done') {
        $o.Outcome = switch ([string]$fd.Variant) { 'source' { 'Finished with the source' } 'p7 original' { 'Kept as Dolby Vision 7' } default { 'Finished' } }
        $o.Pick = [string]$fd.Variant; $o.Final = [string]$fd.Final; $o.Rows = @($fd.Variants); $o.Resolved = $true
    } else {
        if ($rj) { $o.Rows = @($rj.Variants) }
        if ($fd) { $o.Outcome = 'Not finished'; $o.Detail = "finishing stopped at: $($fd.State)" }
        elseif ($t.Resolved) { $o.Outcome = $t.Resolved; $o.Detail = $t.Reason; $o.Resolved = $true }
        else {
            switch ($t.State) {
                'queued'   { $o.Outcome = 'Not started' }
                'prepping' { $o.Outcome = 'Interrupted' }
                'ready'    { $o.Outcome = 'Interrupted' }
                'failed'   { $o.Outcome = 'Failed'; $o.Detail = $t.Reason }
                'skipped'  { $o.Outcome = 'Skipped'; $o.Detail = $t.Reason }
                default    { $o.Outcome = 'Not finished'; $o.Detail = $t.Reason }
            }
        }
    }
    $o.Rows = @($o.Rows | Where-Object { $_ })
    if ($o.Rows.Count -and -not $SkipVmaf) {
        [void](Set-Suggestion -Rows $o.Rows -MinMean $MinMean -MinP1 $MinP1 -MinMin $MinMin -MaxPct $MaxPct -TargetPct $TargetPct -TopMean $TopMean -TopP1 $TopP1 -TopMin $TopMin)
        if ($o.Pick) { foreach ($r in $o.Rows) { $r.Suggested = ($r.Name -eq $o.Pick) } }
        if ($o.Outcome -eq 'No variant passed') { $o.Detail = "original kept; closest: $(Get-ClosestMiss $o.Rows)" }
    }
    [pscustomobject]$o
}

# _encode-batch_all.md / .csv in Dest: every title found under -Source, all runs. Only written
# when the whole batch is complete (every title finished, or settled: nothing passed, skipped).
function Write-BatchReport {
    $outs = @($titleList | ForEach-Object { Get-TitleOutcome $_ })
    $open = @($outs | Where-Object { -not $_.Resolved })
    if ($open.Count) {
        Write-Log ("Whole-batch report not written yet: {0} of {1} title(s) still to do ({2})." -f $open.Count, $outs.Count,
            ((@($open | Group-Object Outcome | ForEach-Object { "$($_.Count) $($_.Name.ToLower())" })) -join ', '))
        return
    }
    $srcGB = 0.0; $finGB = 0.0; $nSized = 0
    foreach ($o in $outs) {
        if ($o.Outcome -notlike 'Finished*') { continue }
        $ref = @($o.Rows | Where-Object { $_.Pct -gt 0 -and $_.VideoGB -gt 0 } | Select-Object -First 1)
        if (-not $ref.Count) { continue }
        $s = $ref[0].VideoGB / $ref[0].Pct * 100
        $f = if ($o.Pick -eq 'source') { $s } else { @($o.Rows | Where-Object { $_.Name -eq $o.Pick } | ForEach-Object { $_.VideoGB })[0] }
        if ($null -eq $f) { continue }
        $srcGB += $s; $finGB += $f; $nSized++
    }
    $count = { param($name) @($outs | Where-Object { $_.Outcome -eq $name }).Count }
    $md = New-Object System.Collections.Generic.List[string]
    $md.Add('# Encode-Batch: all titles')
    $md.Add('')
    $md.Add("- **Source:** ``$srcPath``")
    $md.Add("- **Dest:** ``$dstRoot``")
    $md.Add("- **Updated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm') (run $runId)")
    $md.Add("- **Mode:** $(if ($fixedMode) { 'fixed variants' } else { "ladder search ($(($specs | ForEach-Object { $_.Name }) -join ', '))" })")
    $md.Add("- **Bar:** mean >= $MinMean, p1 >= $MinP1, min >= $MinMin, video <= $MaxPct% of the source's; target $TargetPct%; top bar mean >= $TopMean, p1 >= $TopP1, min >= $TopMin.")
    $md.Add(("- **Titles:** {0} total: {1} finished, {2} finished with the source, {3} kept as Dolby Vision 7, {4} nothing passed (original kept), {5} skipped" -f
        $outs.Count, (& $count 'Finished'), (& $count 'Finished with the source'), (& $count 'Kept as Dolby Vision 7'), (& $count 'No variant passed'), (& $count 'Skipped')))
    if ($nSized) {
        $md.Add(("- **Video:** {0} finished title(s): sources {1:N1} GB -> {2:N1} GB ({3:N0}% of the source, {4:N1} GB saved)" -f
            $nSized, $srcGB, $finGB, (100 * $finGB / [Math]::Max([double]0.001, $srcGB)), ($srcGB - $finGB)))
    }
    $toFix = @($outs | Where-Object { $_.Extras.Audio -and $_.Extras.Audio.SubtitleShift } | Sort-Object Title)
    if ($toFix.Count) {
        $md.Add('')
        $md.Add("## Subtitles to fix ($($toFix.Count))")
        $md.Add('')
        $md.Add('The audio was shifted to match the encode, so subtitles OCR''d from the source need the same shift.')
        $md.Add('')
        foreach ($o in $toFix) { $md.Add("- ``$($o.Title)``: $($o.Extras.Audio.SubtitleShift)") }
    }
    $csv = New-Object System.Collections.Generic.List[object]
    foreach ($o in @($outs | Sort-Object Title)) {
        $md.Add('')
        $md.Add("## $($o.Title)")
        $md.Add('')
        $line = switch -Wildcard ($o.Outcome) {
            'Finished'                 { "Finished: $($o.Pick) -> ``$($o.Final)``" }
            'Finished with the source' { "Finished with the source (no variant passed) -> ``$($o.Final)``" }
            'Kept as Dolby Vision 7'   { "Kept as Dolby Vision 7 (audio only) -> ``$($o.Final)``" }
            default                    { "$($o.Outcome)$(if ($o.Detail) { ": $($o.Detail)" })" }
        }
        $md.Add("$line. Log: ``$($o.LogPath)``")
        $extra = @(Format-TitleExtras $o.Extras $o.Pick)
        if ($extra.Count) { $md.Add(''); foreach ($x in $extra) { $md.Add($x) } }
        $cols = Get-ExtrasColumns $o.Extras
        if ($o.Rows.Count) {
            $md.Add('')
            Format-VariantTable $o.Rows | ForEach-Object { $md.Add($_) }
            foreach ($v in $o.Rows) {
                $row = [ordered]@{
                    Title = $o.Title; Outcome = $o.Outcome; Pick = $o.Pick; FinalFile = $o.Final; Variant = $v.Name
                    Picked = [bool]$v.Suggested; Pass = [bool]$v.Pass; Notes = $(if ($v.PSObject.Properties['Why']) { $v.Why } else { '' })
                    Mean = $v.Mean; P1 = $v.P1; Min = $v.Min; VideoGB = $v.VideoGB; PctOfSource = $v.Pct; Mbps = $v.Mbps; Model = $v.Model
                }
                foreach ($k in $cols.Keys) { $row[$k] = $cols[$k] }
                $csv.Add([pscustomobject]$row)
            }
        } else {
            $row = [ordered]@{
                Title = $o.Title; Outcome = $o.Outcome; Pick = $o.Pick; FinalFile = $o.Final; Variant = ''; Picked = $false; Pass = $false
                Notes = $o.Detail; Mean = $null; P1 = $null; Min = $null; VideoGB = $null; PctOfSource = $null; Mbps = $null; Model = ''
            }
            foreach ($k in $cols.Keys) { $row[$k] = $cols[$k] }
            $csv.Add([pscustomobject]$row)
        }
    }
    $mdAll = Join-Path $dstRoot '_encode-batch_all.md'
    [IO.File]::WriteAllLines($mdAll, $md, $script:Utf8)
    $csv | Export-Csv -LiteralPath (Join-Path $dstRoot '_encode-batch_all.csv') -NoTypeInformation -Encoding UTF8
    Write-Log "Whole batch complete: $mdAll (and _encode-batch_all.csv)" 'Cyan'
}

# Dolby Vision 7 titles kept as profile 7 by an earlier run: bring back their 1080p copies.
foreach ($t in $titleList.ToArray()) {
    $dec = Join-Path $t.TitleDir "$($t.Base).dovi.json"
    if (-not [IO.File]::Exists($dec)) { continue }
    try { $o = [IO.File]::ReadAllText($dec) | ConvertFrom-Json } catch { continue }
    if ($o.Decision -eq 'keep-p7') { [void](Add-DerivedTitle $t) }
}

[IO.File]::WriteAllText($lockPath, (@{ Pid = $PID; Started = (Get-Process -Id $PID).StartTime.ToString('o'); RunId = $runId } | ConvertTo-Json -Compress))
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
                if ($res.Status -eq 'KeepP7') {
                    # Kept as Dolby Vision 7: finish the copy as "- 2160p" (audio only) and add the 1080p SDR title.
                    $d = Add-DerivedTitle $t
                    Request-FinalizeP7 $t ([string]$res.P7Copy) ([string]$res.Reason)
                    $t.State = 'done'; $t.Reason = $res.Reason
                    $doviNotes.Add([pscustomobject]@{ Title = $t.Rel; Note = "kept as profile 7 ($($res.Reason)): finished as $($t.Base) - 2160p.mkv (audio only), plus a 1080p SDR copy" })
                    $results.Add([pscustomobject]@{ Title = $t.Rel; Status = 'Kept as Dolby Vision 7'; Reason = "$($res.Reason); finishing as $($t.Base) - 2160p.mkv, 1080p SDR copy queued"
                                                    Suggested = $null; Variants = @(); Seconds = [int]((Get-Date) - $t.Start).TotalSeconds; LogPath = $t.LogPath })
                    Write-Log "KEEP P7 $($t.Rel): $($res.Reason). Finishing it as '$($t.Base) - 2160p.mkv' (audio only); added $($d.Rel) (1080p SDR copy)" 'Yellow'
                    continue
                }
                if ($res.PSObject.Properties['DoviNote'] -and $res.DoviNote) {
                    $doviNotes.Add([pscustomobject]@{ Title = $t.Rel; Note = [string]$res.DoviNote })
                    Write-Log "DOVI  $($t.Rel): $($res.DoviNote)" 'Yellow'
                }
                if ($res.Status -eq 'Ready' -and $t.IsDerived -and $res.PSObject.Properties['RefWidth']) { $t.Info.Width = [int]$res.RefWidth; $t.Info.Height = [int]$res.RefHeight }
                if ($res.Status -ne 'Ready') {
                    Remove-LocalCopy $t "prep $($res.Status.ToLower())"
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
                if ($res.Status -eq 'Done') { $zipDirs[$t.TitleDir] = $true }
                $finished.Add([pscustomobject]@{ Title = $t.Rel; Variant = $t.FinalDoc.Variant; Status = $res.Status; Final = $res.Final; FreedGB = $res.FreedGB; Error = $res.Error
                                                 Audio = [string]$res.Audio; AudioWarnings = @($res.AudioWarnings | Where-Object { $_ }) })
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

        Invoke-SubtitleBundles

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
            $ft = @($titleList | Where-Object { Test-FinalizeReady $_ } | Select-Object -First 1)
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

        # A Dolby Vision 7 prep waiting for room to convert, with nothing else running that could
        # ever free it (checked after handing out work, so a title between encodes isn't missed): give up on that title instead of waiting forever.
        $pr = @($running.Values | Where-Object { $_.Kind -eq 'prep' })
        if ($pr.Count -and $running.Count -eq 1 -and -not @($titleList | Where-Object { Test-FinalizeReady $_ }).Count) {
            $st = $null
            try { if ([IO.File]::Exists($pr[0].StatusFile)) { $st = [IO.File]::ReadAllText($pr[0].StatusFile) | ConvertFrom-Json } } catch { }
            if ($st -and $st.Step -like 'waiting for space*') {
                $t = $pr[0].Title
                Stop-Job -Job $pr[0].Job -ErrorAction SilentlyContinue; Remove-Job -Job $pr[0].Job -Force -ErrorAction SilentlyContinue
                $running.Remove($pr[0].Job.Id)
                Write-Progress -Id 99 -Activity "Preparing $($t.Rel)" -Completed
                $t.State = 'failed'; $t.Reason = "not enough space on the work drive to convert, and nothing left running to free any ($($st.Step)); the local copy is kept"
                Add-LogText $t.LogPath ("{0:yyyy-MM-dd HH:mm:ss}  PREP: Failed - {1}`r`n" -f (Get-Date), $t.Reason)
                $results.Add([pscustomobject]@{ Title = $t.Rel; Status = 'Failed'; Reason = $t.Reason; Suggested = $null; Variants = @()
                                                Seconds = [int]((Get-Date) - $t.Start).TotalSeconds; LogPath = $t.LogPath })
                Write-Log "TITLE $($t.Rel): Failed - $($t.Reason)" 'Red'
            }
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
                    $pct = [int][Math]::Min([double]100, [Math]::Max([double]0, [double]$st.Pct))
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
    Invoke-SubtitleBundles
} finally {
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
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
    $md.Add("- **Bar:** mean >= $MinMean, p1 >= $MinP1, min >= $MinMin, video <= $MaxPct% of the source's; top bar mean >= $TopMean, p1 >= $TopP1, min >= $TopMin.")
    $md.Add("- **Suggested:** the passing variant closest to $TargetPct% of the source, either direction; but if any variant under $TargetPct% meets the top bar, the biggest of those. None = keep the original.")
    $md.Add("- **Titles:** $(@($results | Where-Object Status -eq 'Done').Count) done, $(@($results | Where-Object Status -eq 'Partial').Count) partial, $(@($results | Where-Object { $_.Status -in 'Failed', 'Skipped' }).Count) failed/skipped while running, $($skipped.Count) skipped before starting, $($unfinished.Count) interrupted, $notStarted not started")
    foreach ($res in $results) {
        $md.Add('')
        $md.Add("## $($res.Title)")
        $md.Add('')
        $line = "$($res.Status), $([TimeSpan]::FromSeconds([int]$res.Seconds))"
        if ($res.Reason) { $line += " - $($res.Reason)" }
        $md.Add("$line. Log: ``$($res.LogPath)``")
        $tt = @($titleList | Where-Object { $_.Rel -eq $res.Title } | Select-Object -First 1)
        if ($tt.Count) {
            $fdx = Read-JsonFile $tt[0].FinalJson
            $extra = @(Format-TitleExtras (Get-TitleExtras $tt[0] $fdx) $(if ($fdx) { [string]$fdx.Variant } else { '' }))
            if ($extra.Count) { $md.Add(''); foreach ($x in $extra) { $md.Add($x) } }
        }
        $rows = @($res.Variants)
        if ($rows.Count) {
            $md.Add('')
            Format-VariantTable $rows | ForEach-Object { $md.Add($_) }
        }
    }
    if ($finished.Count) {
        $md.Add('')
        $md.Add('## Finished (audio added, moved into place, other variants deleted)')
        $md.Add('')
        foreach ($f in $finished) {
            if ($f.Status -eq 'Done') {
                $md.Add("- ``$($f.Title)``: $($f.Variant) -> ``$($f.Final)``$(if ($f.FreedGB) { ", $($f.FreedGB) GB freed" })")
                if ($f.Audio) { $md.Add("  - audio: $($f.Audio)") }
            } else { $md.Add("- **FAILED** ``$($f.Title)``: $($f.Error)") }
            foreach ($w in @($f.AudioWarnings)) { if ($w) { $md.Add("  - **$(if ($w -like 'SUBTITLES TO FIX:*') { $w } else { "audio warning: $w" })**") } }
        }
    }
    if ($doviNotes.Count) {
        $md.Add('')
        $md.Add('## Dolby Vision 7 decisions this run')
        $md.Add('')
        foreach ($n in $doviNotes) { $md.Add("- ``$($n.Title)``: $($n.Note)") }
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
    try { Write-BatchReport } catch { Write-Log "Couldn't write the whole-batch report: $($_.Exception.Message)" 'Yellow' }
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    $tmpParent = Split-Path -Parent $tempDir
    if ([IO.Directory]::Exists($tmpParent) -and -not (Get-ChildItem -LiteralPath $tmpParent -Force)) { Remove-Item -LiteralPath $tmpParent -Force -ErrorAction SilentlyContinue }
    Write-Log "Finished in $($elapsed.ToString('hh\:mm\:ss')). Summary: $mdPath" 'Cyan'
}
