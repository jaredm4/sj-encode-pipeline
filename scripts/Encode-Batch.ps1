<#
.SYNOPSIS
    Encodes every Blu-ray/UHD source MKV under -Source into several NVEncC quality variants, scores each
    against its source with compare_encode (VMAF, via WSL), and suggests the smallest variant
    that meets your quality bar. Built for Windows PowerShell 5.1.

.DESCRIPTION
    For each .mkv found (recursively) under -Source, mirrored into -Dest:

      Dest\<same sub-folders>\
          <name>.encode.log            everything that happened to this title, every run
          <name>.results.json          machine-readable variant results
          <name> - p8.1.mkv            only for Dolby Vision profile 7 sources (converted copy, kept)
          <variant name>\<name>.mkv    one folder per variant; same filename as the source
          <variant name>\<name>.vmaf.txt

      Dest\_encode-batch_<timestamp>.log / .md / .csv   run log, summary table, summary data

    Work is a queue, not one thread per title:
      - Prep (one title at a time, no encoder slot used): probe with ffprobe (and mediainfo when
        installed); skip VC-1 (-SkipVC1) and Dolby Vision other than 7 / 8.1. For profile 7:
        dovi_convert scan (on the source) -> copy to Dest -> inspect (local copy, only for CONVERT*)
        -> convert --backup --delete -> verify it's now 8.1; anything not clearly safe is skipped and
        logged, the local copy kept for review. Then CropDetect -Plumbing for the Suggested crop.
      - Encodes (up to -Threads at once, GPU): each slot takes the next variant of the oldest prepared
        title. So 2 slots and 3 variants run A1+A2, then A3+B1, then B2+B3. The next title is
        prepped while the slots are busy.
      - VMAF (up to -VmafThreads at once, CPU): each finished encode is scored with
        compare_encode --full (exact crop) while the encoder slot moves on to the next variant.
      - When a title's variants are all done: mark which pass the bar and suggest one (below).

    Suggestion (sizes are each variant's video stream as % of the source's, from compare_encode):
      1. Pass = mean >= -MinMean, p1 >= -MinP1, min >= -MinMin, size <= -MaxPct (hard cap), and no
         VMAF alignment warning.
      2. If any passers are <= -BudgetPct, the best quality of those wins (highest p1, then min,
         then mean).
      3. Otherwise the smallest passer wins, except that passers within -TieMarginPct of its size
         count as the same size and the best quality of those wins.
      4. If the pick is under -HeadroomPct (soft minimum) it's still the pick, but flagged
         "headroom": there's room to try a lower CQP or more AQ on that title.

    Two variants of one title share its .encode.log; every line is prefixed with the variant name.

    Re-running is safe: finished variants (and their VMAF results) are reused, half-written encodes
    are redone, and a title whose variants are all finished is skipped.

    Disk space (Dest's drive) is checked before each title starts: below -MinFreeGB no new titles
    are started (running ones finish); a profile 7 title needs -MinFreeDoviGB, otherwise it's skipped.

.PARAMETER Variants
    One hashtable per finished encode. Keys:
      Cqp        int   -> --cqp N
      Aq         int   -> --aq --aq-strength N   (omit or 0 -> --no-aq)
      AqTemporal bool  -> --aq-temporal
      Extra      string or string[] of extra NVEncC args (split on spaces if a string)
      Name       folder name (default built from the above, e.g. "cqp22 aq4")

.EXAMPLE
    .\Encode-Batch.ps1 -Source "S:\Sources\Shows\Show (2004) [tmdbid-12345]" -Dest "D:\Encodes"

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

    [hashtable[]]$Variants = @(
        @{ Cqp = 22 },
        @{ Cqp = 22; Aq = 4 },
        @{ Cqp = 24; Aq = 8 }
    ),

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

    # Size rules for the suggestion, as video stream % of the source's video stream (see .DESCRIPTION).
    [double]$MaxPct = 65,        # hard cap: bigger variants don't pass
    [double]$BudgetPct = 35,     # soft cap: best quality at or under this wins, else the smallest passer
    [double]$HeadroomPct = 20,   # soft minimum: a pick under this is flagged "headroom"
    [double]$TieMarginPct = 3,   # passers within this % of the smallest size count as the same size

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
                $r.SourceGB = [double]$Matches[1]; $r.VideoGB = [double]$Matches[2]; $r.Pct = [int]$Matches[3]; $r.Mbps = [double]$Matches[4]
            } elseif ($l -match '^VMAF model: (\S+)') {
                $r.Model = $Matches[1]
            } elseif ($l -match 'WARNING: (alignment differs|no shift|durations differ)') {
                $r.Warning = $true
            }
        }
        if ($null -ne $r.P1 -and $r.P1 -le 0) { $r.Warning = $true }
        [pscustomobject]$r
    }

    # Marks Pass / OverCap / Dominated / Suggested / Headroom on variant result objects (in place).
    # Budget rule (sizes are the video stream as % of the source's):
    #   1. Pass = mean/p1/min at or above the bar, <= MaxPct of the source, no alignment warning.
    #   2. Passers at or under BudgetPct: the best quality of those (p1, then min, then mean).
    #   3. Otherwise the smallest passer; passers within TieMarginPct (relative) of its size count
    #      as a tie and the best quality of those wins.
    #   4. Headroom: the pick is under HeadroomPct, so a lower CQP / more AQ is probably affordable.
    function Set-Suggestion {
        param($Rows, [double]$MinMean, [double]$MinP1, [double]$MinMin,
            [double]$MaxPct = 65, [double]$BudgetPct = 35, [double]$HeadroomPct = 20, [double]$TieMarginPct = 3)
        foreach ($r in $Rows) {
            foreach ($k in 'Pass', 'OverCap', 'Dominated', 'Suggested', 'Headroom') {
                if ($r.PSObject.Properties[$k]) { $r.$k = $false } else { $r | Add-Member -NotePropertyName $k -NotePropertyValue $false }
            }
        }
        $scored = @($Rows | Where-Object { $null -ne $_.Mean -and -not $_.Warning -and $null -ne $_.VideoGB })
        foreach ($r in $scored) {
            $r.OverCap = ($null -ne $r.Pct -and $r.Pct -gt $MaxPct)
            $r.Pass = ($r.Mean -ge $MinMean -and $r.P1 -ge $MinP1 -and $r.Min -ge $MinMin -and -not $r.OverCap)
            foreach ($o in $scored) {
                if ($o -eq $r) { continue }
                $noWorse = $o.VideoGB -le $r.VideoGB -and $o.Mean -ge $r.Mean -and $o.P1 -ge $r.P1 -and $o.Min -ge $r.Min
                $better = $o.VideoGB -lt $r.VideoGB -or $o.Mean -gt $r.Mean -or $o.P1 -gt $r.P1 -or $o.Min -gt $r.Min
                if ($noWorse -and $better) { $r.Dominated = $true; break }
            }
        }
        $passers = @($scored | Where-Object { $_.Pass })
        if (-not $passers.Count) { return $null }
        $byQuality = @(@{ Expression = 'P1'; Descending = $true }, @{ Expression = 'Min'; Descending = $true },
            @{ Expression = 'Mean'; Descending = $true }, @{ Expression = 'VideoGB'; Descending = $false })
        $inBudget = @($passers | Where-Object { $null -ne $_.Pct -and $_.Pct -le $BudgetPct })
        if ($inBudget.Count) {
            $pick = @($inBudget | Sort-Object $byQuality)[0]
        } else {
            $smallest = @($passers | Sort-Object VideoGB)[0].VideoGB
            $limit = $smallest * (1 + $TieMarginPct / 100)
            $pick = @($passers | Where-Object { $_.VideoGB -le $limit } | Sort-Object $byQuality)[0]
        }
        $pick.Suggested = $true
        if ($null -ne $pick.Pct -and $pick.Pct -lt $HeadroomPct) { $pick.Headroom = $true }
        return $pick.Name
    }

    function Format-VariantTable {
        param($Rows)
        $out = @('| Variant | Mean | p1 | Min | Video GB | % src | Mbps | Notes |', '|---|---|---|---|---|---|---|---|')
        foreach ($r in $Rows) {
            $notes = @()
            if ($r.Suggested) { $notes += '**suggested**' }
            if ($r.Pass -and -not $r.Suggested) { $notes += 'passes' }
            if ($r.Headroom) { $notes += 'headroom: under the soft minimum, try a lower CQP / more AQ' }
            if ($r.OverCap) { $notes += 'over the size cap' }
            if ($r.Dominated) { $notes += 'dominated' }
            if ($r.Warning) { $notes += 'VMAF alignment warning' }
            if ($null -ne $r.Mbps -and $r.Mbps -gt 40) { $notes += 'avg > 40 Mbps (HEVC L5.1 Main limit)' }
            if ($r.Status -ne 'Done') { $notes += $r.Status }
            if ($r.Error) { $notes += $r.Error }
            $f = { param($v, $fmt) if ($null -eq $v) { '-' } else { $fmt -f $v } }
            $name = if ($r.Suggested) { "**$($r.Name)**" } else { $r.Name }
            $out += '| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} |' -f $name,
                (& $f $r.Mean '{0:0.00}'), (& $f $r.P1 '{0:0.00}'), (& $f $r.Min '{0:0.00}'),
                (& $f $r.VideoGB '{0:0.00}'), (& $f $r.Pct '{0}%'), (& $f $r.Mbps '{0:0.0}'), ($notes -join ', ')
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
        Model = ''; Warning = $false; Pass = $false; OverCap = $false; Dominated = $false; Suggested = $false; Headroom = $false
    }
}

# Encoder slot: NVEncC only. Returns Status 'Encoded' (or 'Done' with -SkipVmaf) or 'Failed'.
$EncodeBody = {
    function Invoke-Encode {
      try {
        Write-Log "---- Variant $($Cfg.Index)/$($Cfg.Count): $($v.Name) - encode"
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
        Write-Log "---- Variant $($Cfg.Index)/$($Cfg.Count): $($v.Name) - VMAF"
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

$PrepWorker = [scriptblock]::Create($WorkerHeader.ToString() + "`n" + $PrepBody.ToString())
$EncodeWorker = [scriptblock]::Create($WorkerHeader.ToString() + "`n" + $VariantCommon.ToString() + "`n" + $EncodeBody.ToString())
$VmafWorker = [scriptblock]::Create($WorkerHeader.ToString() + "`n" + $VariantCommon.ToString() + "`n" + $VmafBody.ToString())

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
$specs = @()
foreach ($v in $Variants) {
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
    if (@($specs | Where-Object { $_.Name -eq $name }).Count) { throw "Two variants are both named '$name'; give one a Name." }
    $specs += @{ Name = $name; Args = $argList }
}

# ---------------------------------------------------------------- preflight
Write-Log "Encode-Batch $runId" 'Cyan'
Write-Log "Source: $srcPath"
Write-Log "Dest:   $dstRoot ($(Get-FreeGB $dstRoot) GB free)"
foreach ($s in $specs) { Write-Log ("Variant '{0}': {1}" -f $s.Name, ($s.Args -join ' ')) }
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
        State = 'queued'          # queued -> prepping -> ready -> done | skipped | failed
        Info = $null; Prep = $null; Tasks = @(); Start = $null; Reason = ''
    })
}

# ---------------------------------------------------------------- run
$results = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[object]
$running = @{}                       # job id -> info
$slots = New-Object object[] $Threads
$vmafSlots = New-Object object[] $VmafThreads
$stopDispatch = $false
$prepStatusFile = Join-Path $tempDir 'prep.json'

function New-Row($spec, [string]$file) {
    [pscustomobject][ordered]@{
        Name = $spec.Name; Status = 'Failed'; Error = ''; File = $file; EncodeSec = $null
        Mean = $null; P1 = $null; Min = $null; VideoGB = $null; Pct = $null; Mbps = $null
        Model = ''; Warning = $false; Pass = $false; OverCap = $false; Dominated = $false; Suggested = $false; Headroom = $false
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

function Get-PendingCount {
    $n = 0
    foreach ($t in $titleList) { if ($t.State -eq 'ready') { $n += @($t.Tasks | Where-Object { $_.State -eq 'pending' }).Count } }
    $n
}

function Complete-Title($t) {
    $rows = @($t.Tasks | Sort-Object Index | ForEach-Object { $_.Row })
    $sugg = $null
    if (-not $SkipVmaf) {
        $sugg = Set-Suggestion -Rows $rows -MinMean $MinMean -MinP1 $MinP1 -MinMin $MinMin `
            -MaxPct $MaxPct -BudgetPct $BudgetPct -HeadroomPct $HeadroomPct -TieMarginPct $TieMarginPct
    }
    $headroom = [bool]@($rows | Where-Object { $_.Suggested -and $_.Headroom }).Count
    $done = @($rows | Where-Object { $_.Status -eq 'Done' }).Count
    $st = if ($done -eq $rows.Count) { 'Done' } elseif ($done) { 'Partial' } else { 'Failed' }
    $t.State = 'done'
    $secs = if ($t.Start) { [int]((Get-Date) - $t.Start).TotalSeconds } else { 0 }
    $res = [pscustomobject][ordered]@{
        Title = $t.Rel; Status = $st; Reason = $(if ($st -ne 'Done') { "$done of $($rows.Count) variants finished" } else { '' })
        Suggested = $sugg; Headroom = $headroom; Variants = $rows; Seconds = $secs; LogPath = $t.LogPath
    }
    $results.Add($res)

    $lines = @('', ('{0:yyyy-MM-dd HH:mm:ss}  Bar: mean >= {1}, p1 >= {2}, min >= {3}, size <= {4}% (budget {5}%, soft min {6}%). Suggested: {7}{8}' -f `
        (Get-Date), $MinMean, $MinP1, $MinMin, $MaxPct, $BudgetPct, $HeadroomPct,
        $(if ($sugg) { $sugg } else { 'none (no variant passes)' }),
        $(if ($headroom) { " - under $HeadroomPct% of the source, consider a variant with a lower CQP / more AQ" } else { '' })))
    $lines += Format-VariantTable $rows
    $lines += ('{0:yyyy-MM-dd HH:mm:ss}  RESULT: {1}{2}' -f (Get-Date), $st, $(if ($res.Reason) { " - $($res.Reason)" } else { '' }))
    Add-LogText $t.LogPath (($lines -join "`r`n") + "`r`n")
    [IO.File]::WriteAllText((Join-Path $t.TitleDir "$($t.Base).results.json"), ($res | ConvertTo-Json -Depth 5), $script:Utf8)

    $color = switch ($st) { 'Done' { 'Green' } 'Partial' { 'Yellow' } default { 'Red' } }
    $msg = "TITLE {0}: {1} in {2}" -f $t.Rel, $st, [TimeSpan]::FromSeconds($secs)
    if ($sugg) { $msg += " - suggested: $sugg"; if ($headroom) { $msg += " (headroom: under $HeadroomPct%, consider bumping)" } } elseif (-not $SkipVmaf -and $done) { $msg += ' - no variant passes the bar' }
    if ($res.Reason) { $msg += " - $($res.Reason)" }
    Write-Log $msg $color
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

function Start-Variant($t, $task, [int]$slot, [string]$kind) {
    $task.State = $(if ($kind -eq 'encode') { 'encoding' } else { 'scoring' })
    $statusFile = Join-Path $tempDir "$kind$slot.json"
    Remove-Item -LiteralPath $statusFile -Force -ErrorAction SilentlyContinue
    $cfg = @{
        Helpers = $Helpers.ToString(); EnvPath = $env:PATH; RunId = $runId
        BaseName = $t.Base; TitleDir = $t.TitleDir; LogPath = $t.LogPath; StatusFile = $statusFile; TempDir = $tempDir
        Info = $t.Info; WorkSrc = $t.Prep.WorkSrc; IsDv81 = $t.Prep.IsDv81; Crop = $t.Prep.Crop
        Variant = $task.Spec; Index = $task.Index; Count = $t.Tasks.Count
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
    Write-Log ("{0} {1} :: {2} ({3}/{4})" -f $label, $t.Rel, $task.Spec.Name, $task.Index, $t.Tasks.Count) 'Green'
}

# Picks the next title to prepare, skipping (without starting a job) titles that are finished,
# unsupported, or that the disk can't take. Returns $null when nothing should be prepped now.
function Get-NextPrepTitle {
    foreach ($t in $titleList) {
        if ($t.State -ne 'queued') { continue }
        $all = @($specs | ForEach-Object { Get-FinishedRow $t $_ })
        if (@($all | Where-Object { $_ }).Count -eq $specs.Count) { Add-Skip $t 'all variants already finished'; continue }

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
        if ($t.State -eq 'ready' -and @($t.Tasks | Where-Object { $_.State -eq 'pending' -or $_.State -eq 'encoded' }).Count) { return $true }
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
                $i = 0
                foreach ($spec in $specs) {
                    $i++
                    $fin = Get-FinishedRow $t $spec
                    $state = 'pending'; $row = $fin
                    if ($fin) { $state = 'done' }
                    elseif (-not $SkipVmaf -and [IO.File]::Exists((Join-Path (Join-Path $t.TitleDir $spec.Name) "$($t.Base).mkv"))) {
                        $state = 'encoded'; $row = New-Row $spec (Join-Path (Join-Path $t.TitleDir $spec.Name) "$($t.Base).mkv")   # encode kept from an earlier run
                    }
                    $tasks += [pscustomobject]@{ Spec = $spec; Index = $i; State = $state; Row = $row }
                }
                $t.Tasks = $tasks
                $t.State = 'ready'
                $todo = @($tasks | Where-Object { $_.State -eq 'pending' }).Count
                $toScore = @($tasks | Where-Object { $_.State -eq 'encoded' }).Count
                Write-Log ("READY {0}: crop {1}x{2}, {3} of {4} variants to encode{5}" -f $t.Rel, $res.Crop.Width, $res.Crop.Height, $todo, $tasks.Count,
                    $(if ($toScore) { ", $toScore already encoded to score" } else { '' })) 'Cyan'
                if (-not ($todo + $toScore)) { Complete-Title $t }
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
            if ($t.State -eq 'ready' -and -not @($t.Tasks | Where-Object { $_.State -ne 'done' }).Count) { Complete-Title $t }
        }

        # ---- hand variants to free encoder slots, oldest title first
        $free = [Array]::IndexOf($slots, $null)
        while ($free -ge 0) {
            $next = $null
            foreach ($t in $titleList) {
                if ($t.State -ne 'ready') { continue }
                $next = $t.Tasks | Where-Object { $_.State -eq 'pending' } | Select-Object -First 1
                if ($next) { break }
            }
            if (-not $next) { break }
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

        # ---- prepare the next title while the slots are busy: one at a time, and only when
        #      fewer variants are waiting than there are slots (keeps one title ahead, not more)
        $prepRunning = @($running.Values | Where-Object { $_.Kind -eq 'prep' }).Count
        if (-not $prepRunning -and -not $stopDispatch -and (Get-PendingCount) -lt $Threads) {
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
            if ($r.Kind -eq 'prep') {
                Write-Progress -Id 99 -Activity "Preparing $($r.Title.Rel)" -Status $text -PercentComplete $pct
            } else {
                $pid0 = if ($r.Kind -eq 'encode') { $r.Slot + 1 } else { $r.Slot + 11 }
                Write-Progress -Id $pid0 -Activity ("{0} {1} :: {2} ({3}/{4})" -f $r.Label.Trim(), $r.Title.Rel, $r.Task.Spec.Name, $r.Task.Index, $r.Title.Tasks.Count) -Status $text -PercentComplete $pct
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
                if ($p -and $p.ProcessName -match '^(NVEncC64|NVEncC|wsl)$') { Stop-Process -Id $st.Pid -Force -ErrorAction SilentlyContinue }
            }
        } catch { }
        Stop-Job -Job $r.Job -ErrorAction SilentlyContinue
        Remove-Job -Job $r.Job -Force -ErrorAction SilentlyContinue
        $what = if ($r.Kind -eq 'prep') { 'prep' } else { "$($r.Task.Spec.Name) ($($r.Kind))" }
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
    $md.Add("- **Bar:** mean >= $MinMean, p1 >= $MinP1, min >= $MinMin, video <= $MaxPct% of the source.")
    $md.Add("- **Suggested:** best quality (p1, min, mean) at or under $BudgetPct% of the source; if none, the smallest passer (within $TieMarginPct% counts as a tie, best quality wins). **Headroom** = the pick is under $HeadroomPct%, worth trying a lower CQP / more AQ.")
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
                    Title = $res.Title; Variant = $v.Name; Status = $v.Status; Suggested = $v.Suggested; Headroom = $v.Headroom; Pass = $v.Pass
                    OverCap = $v.OverCap; Dominated = $v.Dominated; Mean = $v.Mean; P1 = $v.P1; Min = $v.Min; VideoGB = $v.VideoGB
                    PctOfSource = $v.Pct; Mbps = $v.Mbps; Model = $v.Model; AlignmentWarning = $v.Warning
                    EncodeSeconds = $v.EncodeSec; Error = $v.Error; File = $v.File
                })
            }
        }
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
