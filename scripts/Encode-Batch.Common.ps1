# Encode-Batch.Common.ps1
# Helpers shared by Encode-Batch.ps1 (its orchestrator and worker jobs), Encode-Video.ps1 and
# Convert-DolbyVision.ps1: the log, the status file, running programs (and WSL), copying, and
# probing a video. Dot-source it; it isn't run on its own. Keep it next to those scripts.

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
    # Input is an empty file: a program that inherited this background job's input could wait
    # on it forever (seconv, under Convert-Subtitles, did).
    $inFile = Join-Path $TempDir "$id.in"
    [IO.File]::WriteAllText($inFile, '')
    # Started in the temp folder: Start-Process otherwise uses PowerShell's current folder, and
    # fails with "The directory name is invalid" if that folder no longer exists.
    $p = Start-Process -FilePath $Exe -ArgumentList $argStr -NoNewWindow -PassThru -WorkingDirectory $TempDir `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile -RedirectStandardInput $inFile
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
    Remove-Item -LiteralPath $outFile, $errFile, $inFile -Force -ErrorAction SilentlyContinue
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
