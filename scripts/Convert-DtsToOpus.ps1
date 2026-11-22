<#
.SYNOPSIS
    Converts every DTS-HD MA (no DTS:X) audio track in a library's MKVs to Opus, in place of
    the original track: same position, language and flags, everything else in the file left
    exactly as it is. For files finished before Add-BluRayAudio stored DTS-HD MA as Opus, and
    for files whose audio was fixed by hand. Built for Windows PowerShell 5.1.

.DESCRIPTION
    For every .mkv under -Root (not .remux.mkv or .partial.mkv files), each audio track that
    ffprobe reports as plain "DTS-HD MA", in mono, stereo, 5.1, 6.1 or 7.1, is converted. The
    rules and settings are Add-BluRayAudio's:
      - Opus at 96 kbps per full channel: 96 mono, 192 stereo, 480 for 5.1, 576 for 6.1, 672
        for 7.1. A "5.1(side)" track is relabelled 5.1 (the same channels, not remixed).
      - Named "Opus 5.1 from DTS-HD MA" when the track had the plain name ("DTS-HD MA 5.1") or
        none; any other name (e.g. a commentary's) is kept.
      - Tagged ADD_BLURAYAUDIO = "Keep; from DTS-HD MA 5.1 master", so Add-BluRayAudio keeps
        it as the master on a later run.
      - DTS:X is object-based and kept, and so is anything ffprobe can't positively identify:
        an ffprobe older than 6.1 says "DTS-HD MA" for DTS:X too, so it stops the script.
    Only the converted tracks change. The new file is built with mkvmerge from the original
    (every other track, chapters, tags and attachments copied) plus the Opus tracks, in the
    original track order. Nothing else is touched: track order, default and forced flags,
    names, languages, commentary flags and timing all carry over.

    Each new file is checked before it's kept: same length (within 2 s), the same tracks in
    the same order (only the DTS-HD MA tracks now Opus, same channel counts), each Opus
    track's start matching the DTS track's (within 15 ms), its length matching (within 1 s),
    the same chapters, and Dolby Vision still there. A file that fails is deleted and the
    original left alone.

    Output, like Add-BluRayAudio:
      without -Replace  "<name>.remux.mkv" next to the original, for review. Run again with
                        -Replace to swap the reviewed ones in (quick check only).
      with -Replace     the original replaced once the new file passes its checks.
    Logs: everything goes to a run log on your Desktop, and each title's part also goes into
    its folder's "encode logs.zip" as "<name>.dts-opus.log" (added to the zip if there is one,
    else in a new "encode logs.zip"; appended to on later runs).

.PARAMETER Root
    The media folder to search (all sub-folders), or a single .mkv.
.PARAMETER Replace
    Replace each original with its new file (see above).
.PARAMETER Force
    Redo a title even if a .remux.mkv exists (overwriting it).
.PARAMETER TempDir
    Where the Opus tracks are encoded before muxing. Default: the system temp folder.
.PARAMETER LogPath
    The run log. Default: "Convert-DtsToOpus <date> <time>.log" on your Desktop.
.PARAMETER Ffmpeg
    ffmpeg. Default: ffmpeg on PATH.
.PARAMETER FfProbe
    ffprobe (6.1 or later). Default: ffprobe on PATH.
.PARAMETER MkvMerge
    mkvmerge. Default: on PATH, else in MKVToolNix's default folder.

.EXAMPLE
    .\Convert-DtsToOpus.ps1 -Root 'L:\Library\Movies' -WhatIf
    Lists the tracks it would convert, and changes nothing.
.EXAMPLE
    .\Convert-DtsToOpus.ps1 -Root 'L:\Library\Movies\Movie (2001) [tmdbid-12345]'
    Writes .remux.mkv files to review; run again with -Replace to swap them in.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Root,
    [switch]$Replace,
    [switch]$Force,
    [string]$TempDir = '',
    [string]$LogPath = '',
    [string]$Ffmpeg = 'ffmpeg',
    [string]$FfProbe = 'ffprobe',
    [string]$MkvMerge = 'mkvmerge'
)

# Defaults from the settings file (encode-settings.ini) for parameters not given, and paths
# as typed or tab-completed: Shared.ps1, next to this script.
if (-not [IO.File]::Exists((Join-Path $PSScriptRoot 'Shared.ps1'))) { throw "Shared.ps1 not found next to this script ($PSScriptRoot); keep the scripts together." }
. (Join-Path $PSScriptRoot 'Shared.ps1')
$script:SettingsUsed = @(Get-ScriptSettings $MyInvocation.MyCommand $PSBoundParameters)
foreach ($setting in $script:SettingsUsed) { Set-Variable -Name $setting.Name -Value $setting.Value -WhatIf:$false }
$Root = Resolve-InputPath $Root; $TempDir = Resolve-InputPath $TempDir; $LogPath = Resolve-InputPath $LogPath
foreach ($n in 'Ffmpeg', 'FfProbe', 'MkvMerge') { Set-Variable -Name $n -Value (Resolve-InputPath (Get-Variable -Name $n -ValueOnly) -Program) -WhatIf:$false }

# 'Continue': under 'Stop', Windows PowerShell turns a native program's stderr into errors.
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$script:Utf8 = New-Object Text.UTF8Encoding($false)

# Same as Add-BluRayAudio: 96 kbps per full channel (the LFE costs next to nothing).
$OpusKbps = @{ 1 = 96; 2 = 192; 6 = 480; 7 = 576; 8 = 672 }
$OkLayouts = @('mono', 'stereo', '5.1', '5.1(side)', '6.1', '7.1')
$KeepTagName = 'ADD_BLURAYAUDIO'

# ---------------------------------------------------------------- tools and log

function Find-Program([string]$Name, [string[]]$Fallbacks = @()) {
    if ([IO.File]::Exists($Name)) { return $Name }
    $c = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    foreach ($fb in $Fallbacks) { if ($fb -and [IO.File]::Exists($fb)) { return $fb } }
    ''
}
$Ffmpeg = Find-Program $Ffmpeg; if (-not $Ffmpeg) { throw 'ffmpeg not found (pass -Ffmpeg)' }
$FfProbe = Find-Program $FfProbe; if (-not $FfProbe) { throw 'ffprobe not found (pass -FfProbe)' }
$MkvMerge = Find-Program $MkvMerge @([IO.Path]::Combine([string]$env:ProgramFiles, 'MKVToolNix', 'mkvmerge.exe'))
if (-not $MkvMerge) { throw 'mkvmerge not found (MKVToolNix; pass -MkvMerge)' }
if (-not $TempDir) { $TempDir = [IO.Path]::GetTempPath() }
if (-not [IO.Directory]::Exists($TempDir)) { throw "-TempDir not found: $TempDir" }
if (-not $LogPath) {
    $LogPath = Join-Path ([Environment]::GetFolderPath('Desktop')) ("Convert-DtsToOpus {0:yyyy-MM-dd HH-mm-ss}.log" -f (Get-Date))
}

# Every line goes to the console and the run log, and (while a title is being worked on) to
# that title's log, which ends up in its folder's "encode logs.zip".
$script:TitleLog = $null
function Write-Log([string]$Text = '', [string]$Color = '') {
    if ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
    $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $Text
    if (-not $WhatIfPreference) { try { [IO.File]::AppendAllText($LogPath, $line + "`r`n", $script:Utf8) } catch { } }
    if ($null -ne $script:TitleLog) { $script:TitleLog.Add($line) }
}

# A native program's output (stdout and stderr) as lines, and its exit code in $LASTEXITCODE.
function Invoke-Tool([string]$Exe, [string[]]$ArgList) {
    $out = & $Exe @ArgList 2>&1
    @($out | ForEach-Object { [string]$_ })
}

# ffprobe's JSON for a file (streams, format, chapters); $null if it can't read it.
function Get-Probe([string]$File) {
    $j = (& $FfProbe -v quiet -show_streams -show_format -show_chapters -of json $File 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0 -or -not $j) { return $null }
    try { $j | ConvertFrom-Json } catch { $null }
}

# Whether this ffprobe tells DTS:X from DTS-HD MA (added to FFmpeg in March 2023, released in
# 6.1): from its version, or for a build from git, its date. (Same as Add-BluRayAudio.)
function Test-FfprobeKnowsDtsX {
    $script:FfprobeVersion = 'of unknown version'
    try { $v = [string](& $FfProbe -version 2>$null | Select-Object -First 1) } catch { return $false }
    if ($v -match 'version\s+(\S+)') { $script:FfprobeVersion = $Matches[1] }
    if ($v -match 'version\s+n?(\d+)\.(\d+)') { return ([version]"$($Matches[1]).$($Matches[2])" -ge [version]'6.1') }
    if ($v -match '(20\d\d)-?([01]\d)-?([0-3]\d)') { return ([int]"$($Matches[1])$($Matches[2])$($Matches[3])" -ge 20230401) }
    $false
}
if (-not (Test-FfprobeKnowsDtsX)) { throw "ffprobe $($script:FfprobeVersion) can't tell DTS:X from DTS-HD MA; 6.1 or later is needed (pass -FfProbe)." }

function Get-ChannelLabel([int]$Ch) {
    switch ($Ch) { 1 { '1.0' } 2 { '2.0' } 3 { '2.1' } 6 { '5.1' } 7 { '6.1' } 8 { '7.1' } default { "$Ch ch" } }
}
function Get-Num($v) { if ($null -eq $v -or "$v" -eq '' -or "$v" -eq 'N/A') { return 0.0 }; [double]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture) }
function Get-Tag($Stream, [string]$Name) {
    if (-not $Stream.tags) { return '' }
    foreach ($p in $Stream.tags.PSObject.Properties) { if ($p.Name -match "^$Name(-\w+)?$") { return [string]$p.Value } }
    ''
}
function Get-Disp($Stream, [string]$Name) { if ($Stream.disposition -and $Stream.disposition.PSObject.Properties[$Name]) { [int]$Stream.disposition.$Name } else { 0 } }
# A track's length from mkvmerge's DURATION tag ("01:15:47.668000000"), in seconds; 0 if none.
function Get-TagSeconds($Stream) {
    $d = Get-Tag $Stream 'DURATION'
    if ($d -match '^(\d+):(\d\d):(\d\d(\.\d+)?)$') { return [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + (Get-Num $Matches[3]) }
    0.0
}
function Test-DolbyVision($Stream) { [bool](@($Stream.side_data_list | Where-Object { $_ -and [string]$_.side_data_type -like 'DOVI*' }).Count) }

# ---------------------------------------------------------------- the zip

# Adds (or appends to) "<name>.dts-opus.log" in the folder's "encode logs.zip", creating the
# zip if there isn't one. Works on a copy, swapped in at the end, so an interrupted write
# can't damage the zip.
function Add-ToLogsZip([string]$Dir, [string]$EntryName, [string]$Text) {
    $zip = Join-Path $Dir 'encode logs.zip'
    $tmp = "$zip.tmp"
    if ([IO.File]::Exists($zip)) { Copy-Item -LiteralPath $zip -Destination $tmp -Force -WhatIf:$false }
    $z = [IO.Compression.ZipFile]::Open($tmp, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $old = ''
        $e = $z.GetEntry($EntryName)
        if ($e) {
            $sr = New-Object IO.StreamReader($e.Open(), [Text.Encoding]::UTF8)
            try { $old = $sr.ReadToEnd() } finally { $sr.Dispose() }
            $e.Delete()
            if ($old -and -not $old.EndsWith("`n")) { $old += "`r`n" }
            if ($old) { $old += "`r`n" }
        }
        $e = $z.CreateEntry($EntryName)
        $sw = New-Object IO.StreamWriter($e.Open(), $script:Utf8)
        try { $sw.Write($old + $Text) } finally { $sw.Dispose() }
    } finally { $z.Dispose() }
    Move-Item -LiteralPath $tmp -Destination $zip -Force -WhatIf:$false
}

# ---------------------------------------------------------------- one file

# The DTS-HD MA tracks of a probe that become Opus, and why any others are kept.
function Get-Plan($Probe) {
    $audio = @($Probe.streams | Where-Object { $_.codec_type -eq 'audio' })
    $todo = New-Object System.Collections.Generic.List[object]
    $kept = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $audio.Count; $i++) {
        $s = $audio[$i]
        if ([string]$s.codec_name -ne 'dts') { continue }
        $prof = [string]$s.profile; $lay = [string]$s.channel_layout; $ch = [int]$s.channels
        if ($prof -ne 'DTS-HD MA') { if ($prof -like 'DTS-HD MA*') { $kept.Add("a:$i $prof (object-based)") }; continue }
        if (($lay -and $OkLayouts -notcontains $lay) -or (-not $lay -and @(1, 2, 6, 8) -notcontains $ch)) { $kept.Add("a:$i DTS-HD MA, layout '$lay' (Opus would remap it)"); continue }
        $label = Get-ChannelLabel $ch
        $name = Get-Tag $s 'title'
        $newName = if (-not $name -or $name -eq "DTS-HD MA $label") { "Opus $label from DTS-HD MA" } else { $name }
        $kbps = if ($OpusKbps.ContainsKey($ch)) { $OpusKbps[$ch] } else { 96 * [Math]::Max(1, $ch - 1) }
        $todo.Add([pscustomobject]@{
            Pos = $i; Stream = $s; Channels = $ch; Label = $label; Kbps = $kbps; OldName = $name; NewName = $newName
            Keep = "Keep; from DTS-HD MA $label master"; Start = (Get-Num $s.start_time); Seconds = (Get-TagSeconds $s)
            Temp = ''; TagsFile = ''; SyncMs = 0
        })
    }
    [pscustomobject]@{ Audio = $audio; Todo = $todo; Kept = $kept }
}

# Checks a new file against the original; returns the problems found (none = it passed).
function Test-NewFile($Orig, $New, $Plan) {
    $p = New-Object System.Collections.Generic.List[string]
    $oLen = Get-Num $Orig.format.duration; $nLen = Get-Num $New.format.duration
    if ([Math]::Abs($oLen - $nLen) -gt 2) { $p.Add(("length {0:N1}s, the original's is {1:N1}s" -f $nLen, $oLen)) }
    foreach ($type in 'video', 'audio', 'subtitle', 'attachment') {
        $a = @($Orig.streams | Where-Object { $_.codec_type -eq $type }).Count; $b = @($New.streams | Where-Object { $_.codec_type -eq $type }).Count
        if ($a -ne $b) { $p.Add("$b $type track(s), the original has $a") }
    }
    if (@($Orig.chapters).Count -ne @($New.chapters).Count) { $p.Add("$(@($New.chapters).Count) chapters, the original has $(@($Orig.chapters).Count)") }
    $ov = @($Orig.streams | Where-Object { $_.codec_type -eq 'video' }) | Select-Object -First 1
    $nv = @($New.streams | Where-Object { $_.codec_type -eq 'video' }) | Select-Object -First 1
    if ($ov -and (Test-DolbyVision $ov) -and -not ($nv -and (Test-DolbyVision $nv))) { $p.Add('Dolby Vision missing') }
    # Track order: the same codec and channels at every position, but Opus where DTS-HD MA was.
    $order = @($Orig.streams | Where-Object { $_.codec_type -in 'video', 'audio', 'subtitle' })
    $norder = @($New.streams | Where-Object { $_.codec_type -in 'video', 'audio', 'subtitle' })
    $conv = @{}; foreach ($t in $Plan.Todo) { $conv[[int]$t.Stream.index] = $t }
    for ($k = 0; $k -lt [Math]::Min($order.Count, $norder.Count); $k++) {
        $o = $order[$k]; $n = $norder[$k]
        $want = if ($conv.ContainsKey([int]$o.index)) { 'opus' } else { [string]$o.codec_name }
        if ([string]$n.codec_name -ne $want -or [int]$n.channels -ne [int]$o.channels -or $n.codec_type -ne $o.codec_type) {
            $p.Add("track $k is $($n.codec_type) $($n.codec_name) $([int]$n.channels) ch, expected $($o.codec_type) $want $([int]$o.channels) ch")
        }
    }
    # The Opus tracks: name, flags, timing.
    $oVidStart = if ($ov) { Get-Num $ov.start_time } else { 0.0 }
    $nVidStart = if ($nv) { Get-Num $nv.start_time } else { 0.0 }
    $nAudio = @($New.streams | Where-Object { $_.codec_type -eq 'audio' })
    foreach ($t in $Plan.Todo) {
        if ($t.Pos -ge $nAudio.Count) { continue }
        $n = $nAudio[$t.Pos]
        if ((Get-Tag $n 'title') -ne $t.NewName) { $p.Add("a:$($t.Pos) is named '$(Get-Tag $n 'title')', expected '$($t.NewName)'") }
        foreach ($d in 'default', 'forced', 'comment') {
            if ((Get-Disp $n $d) -ne (Get-Disp $t.Stream $d)) { $p.Add("a:$($t.Pos) $d flag is $(Get-Disp $n $d), the original's is $(Get-Disp $t.Stream $d)") }
        }
        $offMs = [int][Math]::Round((((Get-Num $n.start_time) - $nVidStart) - ($t.Start - $oVidStart)) * 1000)
        if ([Math]::Abs($offMs) -gt 15) { $p.Add("a:$($t.Pos) starts $offMs ms off from the DTS track") }
        $ns = Get-TagSeconds $n
        if ($t.Seconds -gt 0 -and $ns -gt 0 -and [Math]::Abs($ns - $t.Seconds) -gt 1) { $p.Add(("a:{0} is {1:N1}s long, the DTS track {2:N1}s" -f $t.Pos, $ns, $t.Seconds)) }
    }
    , $p
}

function Invoke-File([IO.FileInfo]$File) {
    $dir = $File.DirectoryName
    $base = [IO.Path]::GetFileNameWithoutExtension($File.Name)
    $remux = Join-Path $dir "$base.remux.mkv"
    $partial = Join-Path $dir "$base.remux.partial.mkv"

    $orig = Get-Probe $File.FullName
    if (-not $orig) { Write-Log "  ffprobe can't read it; skipped" 'Yellow'; return 'Failed' }
    $plan = Get-Plan $orig
    foreach ($k in $plan.Kept) { Write-Log "  kept: $k" 'DarkGray' }
    if (-not $plan.Todo.Count) { return 'None' }

    # A reviewed .remux.mkv from an earlier run: with -Replace, a quick check and it's swapped in.
    if ([IO.File]::Exists($remux) -and -not $Force) {
        if (-not $Replace) { Write-Log "  $base.remux.mkv exists; review it, then run with -Replace to use it (or -Force to redo)" 'Yellow'; return 'Skipped' }
        $r = Get-Probe $remux
        $bad = if ($r) { Test-NewFile $orig $r $plan } else { , @('ffprobe can''t read it') }
        if (@($bad).Count) { Write-Log "  the existing .remux.mkv fails its check: $(@($bad) -join '; '); use -Force to redo it" 'Red'; return 'Failed' }
        if (-not $PSCmdlet.ShouldProcess($File.FullName, 'Replace with the reviewed .remux.mkv')) { return 'Planned' }
        Move-Item -LiteralPath $remux -Destination $File.FullName -Force
        Write-Log '  replaced with the reviewed .remux.mkv' 'Green'
        return 'Done'
    }

    foreach ($t in $plan.Todo) {
        Write-Log ("  a:{0}  {1} -> Opus {2} at {3} kbps, named '{4}'{5}" -f $t.Pos, $(if ($t.OldName) { "'$($t.OldName)'" } else { 'DTS-HD MA (unnamed)' }), $t.Label, $t.Kbps, $t.NewName,
            $(if (Get-Disp $t.Stream 'default') { ' [default]' } elseif (Get-Disp $t.Stream 'comment') { ' [commentary]' }))
    }
    if (-not $PSCmdlet.ShouldProcess($File.FullName, "Convert $($plan.Todo.Count) DTS-HD MA track(s) to Opus$(if ($Replace) { ' and replace the original' })")) { return 'Planned' }

    # mkvmerge's track IDs, in file order, line up with ffprobe's video / audio / subtitle streams.
    $j = (& $MkvMerge -J $File.FullName 2>$null) -join "`n"
    try { $ids = @(($j | ConvertFrom-Json).tracks) } catch { $ids = @() }
    $mkvAudio = @($ids | Where-Object { $_.type -eq 'audio' })
    if ($mkvAudio.Count -ne $plan.Audio.Count) { Write-Log "  mkvmerge sees $($mkvAudio.Count) audio track(s), ffprobe $($plan.Audio.Count); skipped" 'Red'; return 'Failed' }

    $temps = New-Object System.Collections.Generic.List[string]
    try {
        # 1. Encode each DTS-HD MA track (Add-BluRayAudio's settings).
        foreach ($t in $plan.Todo) {
            $t.Temp = Join-Path $TempDir ('dts2opus-' + [guid]::NewGuid().ToString('N') + '.mka'); $temps.Add($t.Temp)
            $a = @('-v', 'error', '-nostdin', '-y', '-i', $File.FullName, '-map', "0:a:$($t.Pos)", '-map_metadata', '-1', '-map_chapters', '-1',
                '-c:a', 'libopus', '-b:a', "$($t.Kbps)k")
            # Opus surround only takes the standard layouts: "5.1(side)" is relabelled 5.1 (the
            # same channels, in the same order), and -mapping_family 1 is Opus's surround mode.
            if ($t.Channels -eq 6) { $a += @('-af', 'channelmap=channel_layout=5.1') } elseif ($t.Channels -eq 8) { $a += @('-af', 'channelmap=channel_layout=7.1') }
            if ($t.Channels -gt 2) { $a += @('-mapping_family', '1') }
            $a += @('-f', 'matroska', $t.Temp)
            Write-Log "  encoding a:$($t.Pos)..."
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $out = Invoke-Tool $Ffmpeg $a
            if ($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($t.Temp)) { Write-Log "  ffmpeg failed (exit $LASTEXITCODE): $($out -join ' | ')" 'Red'; return 'Failed' }
            # Keep the DTS track's start: the encode's own start is measured, and a difference is
            # put back with mkvmerge --sync. (Under 15 ms is Opus's encoder delay, which players
            # skip, not an offset.)
            $tp = Get-Probe $t.Temp
            $ts = @($tp.streams | Where-Object { $_.codec_type -eq 'audio' }) | Select-Object -First 1
            $t.SyncMs = [int][Math]::Round(($t.Start - (Get-Num $ts.start_time)) * 1000)
            if ([Math]::Abs($t.SyncMs) -le 15) { $t.SyncMs = 0 }
            $t.TagsFile = Join-Path $TempDir ('dts2opus-' + [guid]::NewGuid().ToString('N') + '.xml'); $temps.Add($t.TagsFile)
            [IO.File]::WriteAllText($t.TagsFile, "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`n<Tags><Tag><Targets></Targets><Simple><Name>$KeepTagName</Name><String>$([Security.SecurityElement]::Escape($t.Keep))</String></Simple></Tag></Tags>", $script:Utf8)
            Write-Log ("  encoded a:{0} in {1:N0}s ({2:N0} MB){3}" -f $t.Pos, $sw.Elapsed.TotalSeconds, ((Get-Item -LiteralPath $t.Temp).Length / 1MB), $(if ($t.SyncMs) { "; start corrected by $($t.SyncMs) ms" }))
        }

        # 2. mkvmerge: the original without its DTS-HD MA tracks, plus the Opus tracks, in the
        # original's track order.
        $convIds = @{}
        foreach ($t in $plan.Todo) { $convIds[[int]$mkvAudio[$t.Pos].id] = $t }
        $keepAudio = @($mkvAudio | Where-Object { -not $convIds.ContainsKey([int]$_.id) } | ForEach-Object { $_.id })
        $m = New-Object System.Collections.Generic.List[string]
        $m.AddRange([string[]]@('--output', $partial))
        if ($keepAudio.Count) { $m.AddRange([string[]]@('--audio-tracks', ($keepAudio -join ','))) } else { $m.Add('--no-audio') }
        $m.Add($File.FullName)
        $fileNo = 1
        $order = New-Object System.Collections.Generic.List[string]
        foreach ($tr in ($ids | Sort-Object { [int]$_.id })) {
            if ($tr.type -notin 'video', 'audio', 'subtitles') { continue }
            if ($tr.type -eq 'audio' -and $convIds.ContainsKey([int]$tr.id)) {
                $t = $convIds[[int]$tr.id]
                $lang = if ($tr.properties.PSObject.Properties['language_ietf'] -and $tr.properties.language_ietf) { $tr.properties.language_ietf } elseif ($tr.properties.language) { $tr.properties.language } else { 'und' }
                $m.AddRange([string[]]@('--language', "0:$lang", '--track-name', "0:$($t.NewName)",
                    '--default-track-flag', "0:$(if (Get-Disp $t.Stream 'default') { 'yes' } else { 'no' })",
                    '--forced-display-flag', "0:$(if (Get-Disp $t.Stream 'forced') { 'yes' } else { 'no' })",
                    '--commentary-flag', "0:$(if (Get-Disp $t.Stream 'comment') { 'yes' } else { 'no' })",
                    '--original-flag', "0:$(if (Get-Disp $t.Stream 'original') { 'yes' } else { 'no' })",
                    '--tags', "0:$($t.TagsFile)", '--no-chapters', '--no-global-tags'))
                if ($t.SyncMs) { $m.AddRange([string[]]@('--sync', "0:$($t.SyncMs)")) }
                $m.Add($t.Temp)
                $order.Add("${fileNo}:0"); $fileNo++
            } else {
                $order.Add("0:$($tr.id)")
            }
        }
        $m.AddRange([string[]]@('--track-order', ($order -join ',')))
        Write-Log "  muxing..."
        $out = Invoke-Tool $MkvMerge $m.ToArray()
        if ($LASTEXITCODE -gt 1 -or -not [IO.File]::Exists($partial)) { Write-Log "  mkvmerge failed (exit $LASTEXITCODE): $(@($out | Select-Object -Last 5) -join ' | ')" 'Red'; return 'Failed' }

        # 3. Check it.
        $new = Get-Probe $partial
        $bad = if ($new) { Test-NewFile $orig $new $plan } else { , @('ffprobe can''t read it') }
        if (@($bad).Count) {
            Write-Log "  CHECK FAILED, new file deleted, original untouched:" 'Red'
            foreach ($b in $bad) { Write-Log "    $b" 'Red' }
            return 'Failed'
        }
        $saved = ($File.Length - (Get-Item -LiteralPath $partial).Length) / 1GB
        Write-Log ("  checked: same tracks, order, flags, timing and chapters; {0:N2} GB smaller" -f $saved) 'Green'
        if ($Replace) {
            Move-Item -LiteralPath $partial -Destination $File.FullName -Force
            Write-Log '  original replaced' 'Green'
        } else {
            Move-Item -LiteralPath $partial -Destination $remux -Force
            Write-Log "  written: $base.remux.mkv (review it, then run with -Replace)" 'Green'
        }
        return 'Done'
    } finally {
        foreach ($t in $temps) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue -WhatIf:$false }
        if ([IO.File]::Exists($partial)) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue -WhatIf:$false }
    }
}

# ---------------------------------------------------------------- main

if ([IO.File]::Exists($Root)) { $files = @(Get-Item -LiteralPath $Root) }
elseif ([IO.Directory]::Exists($Root)) {
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.mkv' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '\.(remux|partial)\.mkv$' } | Sort-Object FullName)
} else { throw "-Root not found: $Root" }

Write-Log "Convert-DtsToOpus $(if ($WhatIfPreference) { '(-WhatIf: nothing is changed)' } elseif ($Replace) { '(-Replace)' } else { '(writing .remux.mkv files for review)' })" 'Cyan'
Write-Log "Root: $Root; $($files.Count) MKV(s); ffprobe $($script:FfprobeVersion)"
if (-not $WhatIfPreference) { Write-Log "Log: $LogPath" }
$count = @{ Done = 0; Planned = 0; Skipped = 0; Failed = 0; None = 0 }
$started = Get-Date
$n = 0
foreach ($f in $files) {
    $n++
    Write-Progress -Activity 'DTS-HD MA to Opus' -Status "$n of $($files.Count): $($f.Name)" -PercentComplete (100 * $n / [Math]::Max(1, $files.Count))
    # A file with nothing to convert is only mentioned if it has a DTS track that's kept.
    $probe = Get-Probe $f.FullName
    if ($probe -and -not @($probe.streams | Where-Object { $_.codec_type -eq 'audio' -and [string]$_.codec_name -eq 'dts' }).Count) { $count.None++; continue }
    $script:TitleLog = New-Object System.Collections.Generic.List[string]
    Write-Log ''
    Write-Log "==== [$n/$($files.Count)] $($f.FullName)" 'Yellow'
    $result = 'Failed'
    try { $result = Invoke-File $f } catch { Write-Log "  ERROR: $($_.Exception.Message)" 'Red' }
    $count[$result]++
    if ($result -eq 'None') { Write-Log '  nothing to convert' 'DarkGray' }
    # The title's log into its folder's "encode logs.zip" (not for -WhatIf, or nothing done).
    if ($result -in 'Done', 'Failed' -and -not $WhatIfPreference) {
        $entry = "$([IO.Path]::GetFileNameWithoutExtension($f.Name)).dts-opus.log"
        try { Add-ToLogsZip $f.DirectoryName $entry (($script:TitleLog + @("Result: $result")) -join "`r`n") ; Write-Host "  log added to encode logs.zip ($entry)" -ForegroundColor DarkGray }
        catch { Write-Log "  couldn't add the log to encode logs.zip: $($_.Exception.Message)" 'Yellow' }
    }
    $script:TitleLog = $null
}
Write-Progress -Activity 'DTS-HD MA to Opus' -Completed
Write-Log ''
Write-Log ("Done: {0}   Planned (-WhatIf): {1}   Skipped: {2}   Failed: {3}   Nothing to convert: {4}   ({5:N0} min)" -f
    $count.Done, $count.Planned, $count.Skipped, $count.Failed, $count.None, ((Get-Date) - $started).TotalMinutes) $(if ($count.Failed) { 'Red' } else { 'Green' })
