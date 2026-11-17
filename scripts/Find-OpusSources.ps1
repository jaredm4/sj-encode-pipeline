<#
.SYNOPSIS
    Lists the Opus audio tracks in a library and what each was encoded from, to find the ones
    made from a Dolby TrueHD (or MLP) master. Those lost the TrueHD's dialogue level, so they
    play louder than the disc's other tracks. With -Rename, also names every track the
    pipeline encoded after its source ("Opus 5.1 from DTS-HD MA"), as Add-BluRayAudio now
    does, using mkvpropedit (in place, no remux). Built for Windows PowerShell 5.1.

.DESCRIPTION
    Every .mkv under -Root is read with ffprobe. For each audio track that isn't a commentary,
    whether the pipeline encoded it, and from what, comes from the first of these that has it:
      1. Opus only: the track's tag, ADD_BLURAYAUDIO = "Keep; from <source> master", which
         Add-BluRayAudio puts on every master it converts to Opus.
      2. Its name, when it already says it ("Opus 2.0 from TrueHD", from Nov 2026 on).
      3. Encode-Batch's records for the title, loose in the folder or in its
         "encode logs.zip": <name>.final.json (each audio track's source, and whether it was
         encoded), else <name>.audio.log (Add-BluRayAudio's "Planned audio" lines).
      4. Add-BluRayAudio logs from runs by hand ("Add-BluRayAudio*.log") in the same folder:
         the "Planned audio" lines in the section for this file (the last one, if it ran more
         than once).
    A later source that disagrees is shown in the Note column.

    The audit (always): every Opus track with fewer than 6 channels (all channel counts with
    -AllChannels), sorted into:
      From TrueHD/MLP   made from a Dolby TrueHD or MLP master: the ones to look at.
      Unknown           no tag, name, record or log found it: check by hand.
      Other             made from PCM, FLAC, ALAC or DTS-HD MA (fine). Counted; listed with -ShowAll.

    -Rename: every encoded track (Opus, the AC-3 / AAC default tracks, FLAC from early runs)
    whose source is known gets a name like Add-BluRayAudio's: "<codec> <channels> from
    <source>", with the source's channels only when they differ ("Dolby Digital 5.1 from
    TrueHD Atmos 7.1"). Copied tracks (e.g. a TrueHD's own AC-3 core) aren't touched. A track
    is only renamed when its name is still the plain one ("Opus 5.1", or none); one with any
    other name, or whose sources disagree, is listed and left alone. Each file's tracks are
    renamed in one mkvpropedit call. -WhatIf shows the renames without making them.

.PARAMETER Root
    The media folder to search (all sub-folders).
.PARAMETER AllChannels
    Audit Opus tracks of every channel count, not only those under 6 channels.
.PARAMETER ShowAll
    Also list the "Other" Opus tracks, and the encoded tracks -Rename leaves alone.
.PARAMETER Rename
    Name encoded tracks after their source (see above). With -WhatIf: only show what would change.
.PARAMETER CsvPath
    Also save every track found as a CSV here (with Group and NewName columns). Default: none.
.PARAMETER FfProbe
    ffprobe. Default: ffprobe on PATH.
.PARAMETER MkvPropEdit
    mkvpropedit (for -Rename). Default: on PATH, else in MKVToolNix's default folder.

.EXAMPLE
    .\Find-OpusSources.ps1 -Root 'L:\Library'
.EXAMPLE
    .\Find-OpusSources.ps1 -Root 'L:\Library' -Rename -WhatIf
    Lists the renames it would make, and changes nothing.
.EXAMPLE
    .\Find-OpusSources.ps1 -Root 'L:\Library\Shows' -AllChannels -ShowAll -CsvPath "$HOME\Desktop\opus-sources.csv"
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Root,
    [switch]$AllChannels,
    [switch]$ShowAll,
    [switch]$Rename,
    [string]$CsvPath = '',
    [string]$FfProbe = 'ffprobe',
    [string]$MkvPropEdit = 'mkvpropedit'
)

# Defaults from the settings file (encode-settings.ini) for parameters not given, and paths
# as typed or tab-completed: Shared.ps1, next to this script.
if (-not [IO.File]::Exists((Join-Path $PSScriptRoot 'Shared.ps1'))) { throw "Shared.ps1 not found next to this script ($PSScriptRoot); keep the scripts together." }
. (Join-Path $PSScriptRoot 'Shared.ps1')
$script:SettingsUsed = @(Get-ScriptSettings $MyInvocation.MyCommand $PSBoundParameters)
foreach ($setting in $script:SettingsUsed) { Set-Variable -Name $setting.Name -Value $setting.Value }
$Root = Resolve-InputPath $Root; $CsvPath = Resolve-InputPath $CsvPath
$FfProbe = Resolve-InputPath $FfProbe -Program; $MkvPropEdit = Resolve-InputPath $MkvPropEdit -Program

# 'Continue': under 'Stop', Windows PowerShell turns a native program's stderr into errors.
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
if (-not [IO.Directory]::Exists($Root)) { throw "-Root not found: $Root" }

# A program: a path, or a command on PATH (or one of -Fallbacks) -> its full path; '' if none.
function Find-Program([string]$Name, [string[]]$Fallbacks = @()) {
    if ([IO.File]::Exists($Name)) { return $Name }
    $c = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    foreach ($fb in $Fallbacks) { if ($fb -and [IO.File]::Exists($fb)) { return $fb } }
    ''
}
$FfProbe = Find-Program $FfProbe
if (-not $FfProbe) { throw 'ffprobe not found (pass -FfProbe)' }
if ($Rename) {
    $MkvPropEdit = Find-Program $MkvPropEdit @([IO.Path]::Combine([string]$env:ProgramFiles, 'MKVToolNix', 'mkvpropedit.exe'))
    if (-not $MkvPropEdit) { throw 'mkvpropedit not found (MKVToolNix; pass -MkvPropEdit)' }
}

# ---------------------------------------------------------------- names

function Get-ChannelLabel([int]$Ch) {
    switch ($Ch) { 1 { '1.0' } 2 { '2.0' } 3 { '2.1' } 6 { '5.1' } 7 { '6.1' } 8 { '7.1' } default { "$Ch ch" } }
}

# A codec as Add-BluRayAudio names its tracks.
function Get-CodecLabel([string]$Codec) {
    switch ($Codec) { 'opus' { 'Opus' } 'ac3' { 'Dolby Digital' } 'aac' { 'AAC' } 'flac' { 'FLAC' } default { '' } }
}

# A source as recorded ("Dolby TrueHD + Dolby Atmos 7.1", "PCM 5.1", "DTS-HD MA") -> its short
# name and channel label, as Add-BluRayAudio's Get-SourceLabel names them ("TrueHD Atmos", "7.1").
function Split-Source([string]$Source) {
    $name = $Source.Trim(); $ch = ''
    if ($name -match '^(.+?)\s+(\d\.\d|\d+ ch)$') { $name = $Matches[1]; $ch = $Matches[2] }
    $short = switch ($name) {
        'Dolby TrueHD + Dolby Atmos' { 'TrueHD Atmos' }
        'Dolby TrueHD'               { 'TrueHD' }
        'DTS-HD MA + DTS:X'          { 'DTS:X' }
        'DTS-HD MA + DTS:X IMAX'     { 'DTS:X IMAX' }
        'PCM'                        { 'LPCM' }
        'Meridian Lossless Packing'  { 'MLP' }
        default                      { $name }
    }
    [pscustomobject]@{ Name = $short; Channels = $ch }
}

# ---------------------------------------------------------------- reading the records

# A folder's "encode logs.zip": its .final.json and .audio.log entries, by file name.
$zipCache = @{}
function Get-ZipTexts([string]$Dir) {
    if ($zipCache.ContainsKey($Dir)) { return $zipCache[$Dir] }
    $h = @{}
    $zip = Join-Path $Dir 'encode logs.zip'
    if ([IO.File]::Exists($zip)) {
        try {
            $in = [IO.Compression.ZipFile]::OpenRead($zip)
            try {
                foreach ($e in $in.Entries) {
                    if ($e.Name -notlike '*.final.json' -and $e.Name -notlike '*.audio.log') { continue }
                    $sr = New-Object IO.StreamReader($e.Open(), [Text.Encoding]::UTF8)
                    try { $h[$e.Name] = $sr.ReadToEnd() } finally { $sr.Dispose() }
                }
            } finally { $in.Dispose() }
        } catch { Write-Host "  WARNING: can't read $zip`: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    $zipCache[$Dir] = $h
    $h
}

# A title file's text: loose in the folder, else from its "encode logs.zip". $null if neither.
function Read-TitleText([string]$Dir, [string]$Name) {
    $p = Join-Path $Dir $Name
    if ([IO.File]::Exists($p)) { try { return [IO.File]::ReadAllText($p) } catch { } }
    $z = Get-ZipTexts $Dir
    if ($z.ContainsKey($Name)) { return $z[$Name] }
    $null
}

# A folder's final.json files, by the finished file's name (from Final, else <name>.mkv).
$finalCache = @{}
function Get-FinalDocs([string]$Dir) {
    if ($finalCache.ContainsKey($Dir)) { return $finalCache[$Dir] }
    $h = @{}
    $names = @()
    $names += @(Get-ChildItem -LiteralPath $Dir -File -Filter '*.final.json' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $names += @((Get-ZipTexts $Dir).Keys | Where-Object { $_ -like '*.final.json' })
    foreach ($n in ($names | Select-Object -Unique)) {
        $text = Read-TitleText $Dir $n
        if (-not $text) { continue }
        try { $d = $text | ConvertFrom-Json } catch { continue }
        $base = $n -replace '\.final\.json$', ''
        $mkv = if ($d.PSObject.Properties['Final'] -and $d.Final) { @([string]$d.Final -split '[\\/]')[-1] } else { "$base.mkv" }
        $h[$mkv.ToLowerInvariant()] = [pscustomobject]@{ Base = $base; Doc = $d }
    }
    $finalCache[$Dir] = $h
    $h
}

# Add-BluRayAudio's "Planned audio" lines for the tracks it encoded, from a log's text:
#   a:0  Dolby Digital 5.1    new, encoded from Dolby TrueHD 7.1 at 640 kbps; ...  [default]
#   a:2  Opus 2.0             audio 3: Dolby TrueHD encoded to Opus at 192 kbps (tagged Keep)
#   a:1  FLAC 5.1             audio 0: PCM converted to FLAC (lossless)
# (An Opus / FLAC note doesn't say the source's channels: they're the track's.)
function Get-PlannedEncodes([string]$Text) {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($l in ($Text -split "`r?`n")) {
        if ($l -notmatch 'a:(\d+)\s+(Opus|Dolby Digital|AAC|FLAC) (\d\.\d)\b') { continue }
        $idx = [int]$Matches[1]; $codec = $Matches[2]; $layout = $Matches[3]
        $src = ''
        if ($l -match 'new, encoded from (.+?) at \d+ kbps') { $src = $Matches[1].Trim() }
        elseif ($l -match 'audio \d+: (.+?) (?:encoded to Opus at|converted to FLAC)') { $src = "$($Matches[1].Trim()) $layout" }
        if (-not $src) { continue }
        $list.Add([pscustomobject]@{ Index = $idx; Codec = $codec; Layout = $layout; Source = $src })
    }
    , $list
}

# The by-hand Add-BluRayAudio logs in a folder, split into one section per title:
# "==== [1/3] <file name>" up to the next header. Keyed by the file's name without .mkv or
# .remux.mkv; a later section for the same title replaces an earlier one (logs read oldest first).
function Get-TitleKey([string]$Name) { ($Name -replace '\.mkv$', '' -replace '\.remux$', '').ToLowerInvariant() }
$handCache = @{}
function Get-HandSections([string]$Dir) {
    if ($handCache.ContainsKey($Dir)) { return $handCache[$Dir] }
    $h = @{}
    $logs = @(Get-ChildItem -LiteralPath $Dir -File -Filter 'Add-BluRayAudio*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    foreach ($lf in $logs) {
        try { $lines = [IO.File]::ReadAllLines($lf.FullName) } catch { continue }
        $cur = $null; $buf = $null
        foreach ($l in $lines + @('==== [0/0] <end>')) {
            if ($l -match '==== \[\d+/\d+\] (.+?)\s*$') {
                if ($cur) { $h[$cur] = [pscustomobject]@{ Log = $lf.Name; Text = ($buf -join "`n") } }
                $cur = Get-TitleKey $Matches[1]; $buf = New-Object System.Collections.Generic.List[string]
                continue
            }
            if ($cur) { $buf.Add($l) }
        }
    }
    $handCache[$Dir] = $h
    $h
}

# The planned line for this track: the same position, codec and layout, else the only line
# with that codec and layout.
function Select-Planned($Planned, [int]$Index, [string]$Codec, [string]$Layout) {
    $hit = @($Planned | Where-Object { $_.Index -eq $Index -and $_.Codec -eq $Codec -and $_.Layout -eq $Layout })
    if ($hit.Count) { return $hit[0] }
    $hit = @($Planned | Where-Object { $_.Codec -eq $Codec -and $_.Layout -eq $Layout })
    if ($hit.Count -eq 1) { return $hit[0] }
    $null
}

# ---------------------------------------------------------------- scan

$rows = New-Object System.Collections.Generic.List[object]
$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.mkv' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '\.partial\.mkv$' })
$n = 0; $warn = 0
foreach ($f in $files) {
    $n++
    Write-Progress -Activity 'Reading MKVs with ffprobe' -Status "$n of $($files.Count): $($f.Name)" -PercentComplete (100 * $n / [Math]::Max(1, $files.Count))
    $json = (& $FfProbe -v quiet -select_streams a -show_entries 'stream=index,codec_name,channels,bit_rate:stream_tags:stream_disposition=default,comment' -of json $f.FullName 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0 -or -not $json) { Write-Host "  WARNING: ffprobe couldn't read $($f.FullName); skipped" -ForegroundColor Yellow; $warn++; continue }
    try { $streams = @(($json | ConvertFrom-Json).streams) } catch { Write-Host "  WARNING: ffprobe's output for $($f.FullName) isn't JSON; skipped" -ForegroundColor Yellow; $warn++; continue }

    $fin = (Get-FinalDocs $f.DirectoryName)[$f.Name.ToLowerInvariant()]
    $finTracks = @()
    $planned = $null; $plannedFrom = ''
    if ($fin) {
        $d = $fin.Doc
        if ($d.PSObject.Properties['Audio'] -and $d.Audio -and $d.Audio.PSObject.Properties['Tracks']) { $finTracks = @($d.Audio.Tracks) }
        $alog = Read-TitleText $f.DirectoryName "$($fin.Base).audio.log"
        if ($alog) { $planned = Get-PlannedEncodes $alog; $plannedFrom = "$($fin.Base).audio.log" }
    } else {
        $base = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        $alog = Read-TitleText $f.DirectoryName "$base.audio.log"
        if ($alog) { $planned = Get-PlannedEncodes $alog; $plannedFrom = "$base.audio.log" }
    }
    $sec = (Get-HandSections $f.DirectoryName)[(Get-TitleKey $f.Name)]
    $handPlanned = if ($sec) { Get-PlannedEncodes $sec.Text } else { $null }

    for ($i = 0; $i -lt $streams.Count; $i++) {
        $st = $streams[$i]
        $codec = [string]$st.codec_name
        $codecLabel = Get-CodecLabel $codec
        if (-not $codecLabel) { continue }
        $ch = [int]$st.channels
        $layout = Get-ChannelLabel $ch
        $tags = $st.tags
        $title = ''; $tagSrc = ''; $bps = ''
        if ($tags) {
            foreach ($p in $tags.PSObject.Properties) {
                if ($p.Name -match '^title$') { $title = [string]$p.Value }
                elseif ($p.Name -match '^BPS(-\w+)?$') { $bps = [string]$p.Value }
                elseif ($p.Name -match '^ADD_BLURAYAUDIO(-\w+)?$' -and [string]$p.Value -match '\bfrom (.+?)( master)?\s*$') { $tagSrc = $Matches[1].Trim() }
            }
        }
        $role = 'master'
        if ($st.disposition) {
            if ([int]$st.disposition.default -eq 1) { $role = 'default' } elseif ([int]$st.disposition.comment -eq 1) { $role = 'commentary' }
        }
        if ($role -eq 'commentary' -or $title -match '^Commentary') { continue }
        $kbps = 0
        if ($st.PSObject.Properties['bit_rate'] -and $st.bit_rate) { $kbps = [int][Math]::Round([double]$st.bit_rate / 1000) }
        if (-not $kbps -and $bps -match '^\d+$') { $kbps = [int][Math]::Round([double]$bps / 1000) }

        # Every source found for it, in order of trust.
        $found = New-Object System.Collections.Generic.List[object]
        if ($tagSrc) { $found.Add([pscustomobject]@{ Source = $tagSrc; Evidence = 'track tag' }) }
        if ($title -match "^$([regex]::Escape($codecLabel)) \S+ from (.+)$") { $found.Add([pscustomobject]@{ Source = $Matches[1].Trim(); Evidence = 'track name' }) }
        $t = @($finTracks | Where-Object { [int]$_.Track -eq $i -and [string]$_.Codec -eq $codec -and [int]$_.Channels -eq $ch })
        if (-not $t.Count) { $t = @($finTracks | Where-Object { [string]$_.Codec -eq $codec -and [int]$_.Channels -eq $ch }); if ($t.Count -ne 1) { $t = @() } }
        if ($t.Count -and [string]$t[0].Made -eq 'encoded' -and [string]$t[0].SourceName) {
            $found.Add([pscustomobject]@{ Source = [string]$t[0].SourceName; Evidence = "$($fin.Base).final.json" })
        } elseif (-not $t.Count -and $planned) {
            $pl = Select-Planned $planned $i $codecLabel $layout
            if ($pl) { $found.Add([pscustomobject]@{ Source = $pl.Source; Evidence = $plannedFrom }) }
        }
        if ($handPlanned) {
            $pl = Select-Planned $handPlanned $i $codecLabel $layout
            if ($pl) { $found.Add([pscustomobject]@{ Source = $pl.Source; Evidence = $sec.Log }) }
        }
        # Not an Opus track, and nothing says this pipeline encoded it: a copied track.
        if ($codec -ne 'opus' -and -not $found.Count) { continue }

        $src = ''; $evidence = ''; $note = ''; $conflict = $false
        if ($found.Count) {
            $src = $found[0].Source; $evidence = $found[0].Evidence
            $s0 = Split-Source $src
            $other = @($found | Select-Object -Skip 1 | Where-Object { (Split-Source $_.Source).Name -ne $s0.Name })
            if ($other.Count) { $note = ($other | ForEach-Object { "$($_.Evidence) says $($_.Source)" }) -join '; '; $conflict = $true }
        }
        $group = ''
        if ($codec -eq 'opus') {
            $group = if (-not $src) { 'Unknown' } elseif ($src -match 'TrueHD|\bMLP\b|Meridian') { 'From TrueHD/MLP' } else { 'Other' }
            if ($group -ne 'From TrueHD/MLP' -and $note -match 'TrueHD|\bMLP\b|Meridian') { $group = 'From TrueHD/MLP' }
        }

        # The name Add-BluRayAudio would give it now, and whether to set it.
        $newName = ''; $renameNote = ''
        if ($src) {
            $s = Split-Source $src
            $from = $s.Name
            if ($s.Channels -and $s.Channels -ne $layout) { $from += " $($s.Channels)" }
            $newName = "$codecLabel $layout from $from"
        }
        $plain = "$codecLabel $layout"
        if (-not $src) { $renameNote = 'source unknown' }
        elseif ($conflict) { $renameNote = 'sources disagree' }
        elseif ($title -eq $newName) { $renameNote = 'already named' }
        elseif ($title -match ' from ') { $renameNote = 'already has a "from" name' }
        elseif ($title -and $title -ne $plain) { $renameNote = 'has its own name' }

        $rows.Add([pscustomobject]@{
            Group = $group; File = $f.Name; Track = "a:$i"; Pos = $i; Codec = $codec; Channels = $ch
            Audio = "$codecLabel $layout$(if ($kbps) { " $kbps kbps" })"; Role = $role
            Title = $title; Source = $(if ($src) { $src } else { '?' }); Evidence = $evidence; Note = $note
            NewName = $(if (-not $renameNote) { $newName } else { '' }); RenameNote = $renameNote
            Folder = $f.DirectoryName; Path = $f.FullName
        })
    }
}
Write-Progress -Activity 'Reading MKVs with ffprobe' -Completed

# ---------------------------------------------------------------- audit

$opus = @($rows | Where-Object { $_.Codec -eq 'opus' -and ($AllChannels -or $_.Channels -lt 6) })
$affected = @($opus | Where-Object { $_.Group -eq 'From TrueHD/MLP' })
$unknown = @($opus | Where-Object { $_.Group -eq 'Unknown' })
$other = @($opus | Where-Object { $_.Group -eq 'Other' })
$scope = if ($AllChannels) { 'Opus tracks' } else { 'Opus tracks under 6 channels' }
Write-Host ''
Write-Host ("MKVs read: {0}; {1}: {2} (from TrueHD/MLP: {3} in {4} file(s); unknown: {5}; other: {6}); {7} warning(s)." -f `
    $n, $scope, $opus.Count, $affected.Count, @($affected | Select-Object -ExpandProperty File -Unique).Count, $unknown.Count, $other.Count, $warn)
if ($affected.Count) {
    Write-Host 'From a TrueHD / MLP master (its dialogue level was lost):' -ForegroundColor Cyan
    $affected | Format-Table File, Track, Audio, Role, Source, Evidence, Note, Folder -AutoSize | Out-String -Width 320 | Write-Host
}
if ($unknown.Count) {
    Write-Host 'Source unknown (no tag, name, record or log found it; check by hand):' -ForegroundColor Yellow
    $unknown | Format-Table File, Track, Audio, Role, Title, Folder -AutoSize | Out-String -Width 320 | Write-Host
}
if ($ShowAll -and $other.Count) {
    Write-Host 'From other masters (PCM, FLAC, ALAC, DTS-HD MA):' -ForegroundColor DarkGray
    $other | Format-Table File, Track, Audio, Role, Source, Evidence, Note, Folder -AutoSize | Out-String -Width 320 | Write-Host
}

# ---------------------------------------------------------------- rename

if ($Rename) {
    $todo = @($rows | Where-Object { $_.NewName })
    $left = @($rows | Where-Object { -not $_.NewName -and $_.RenameNote -ne 'already named' })
    $done = 0; $failed = 0
    Write-Host ''
    Write-Host ("Encoded tracks: {0}; to rename: {1} in {2} file(s); already named: {3}; left alone: {4}." -f $rows.Count, $todo.Count,
        @($todo | Select-Object -ExpandProperty Path -Unique).Count, @($rows | Where-Object { $_.RenameNote -eq 'already named' }).Count, $left.Count)
    foreach ($g in ($todo | Group-Object Path)) {
        $a = New-Object System.Collections.Generic.List[string]
        foreach ($r in $g.Group) {
            Write-Host ("  {0}  {1}: '{2}' -> '{3}'  ({4})" -f $r.File, $r.Track, $r.Title, $r.NewName, $r.Evidence)
            $a.AddRange([string[]]@('--edit', "track:a$($r.Pos + 1)", '--set', "name=$($r.NewName)"))
        }
        if ($WhatIfPreference) { continue }   # (the lines above are the dry run)
        if ($PSCmdlet.ShouldProcess($g.Name, "rename $($g.Group.Count) audio track(s)")) {
            $out = & $MkvPropEdit $g.Name $a.ToArray() 2>&1
            if ($LASTEXITCODE -gt 1) {
                Write-Host "  FAILED (mkvpropedit exit $LASTEXITCODE): $($g.Name)`n    $(@($out) -join "`n    ")" -ForegroundColor Red
                $failed += $g.Group.Count
            } else { $done += $g.Group.Count }
        }
    }
    if ($left.Count -and ($ShowAll -or @($left | Where-Object { $_.RenameNote -ne 'source unknown' }).Count)) {
        Write-Host 'Left alone (encoded, but not renamed):' -ForegroundColor Yellow
        $shown = if ($ShowAll) { $left } else { @($left | Where-Object { $_.RenameNote -ne 'source unknown' }) }
        $shown | Format-Table File, Track, Audio, Title, RenameNote, Source, Note, Folder -AutoSize | Out-String -Width 320 | Write-Host
    }
    if ($WhatIfPreference) { Write-Host "-WhatIf: nothing renamed." -ForegroundColor Cyan }
    else { Write-Host "Renamed: $done track(s)$(if ($failed) { "; failed: $failed" })." -ForegroundColor $(if ($failed) { 'Red' } else { 'Green' }) }
}

if ($CsvPath -and $rows.Count) {
    $rows | Select-Object Group, File, Track, Audio, Role, Title, Source, Evidence, Note, NewName, RenameNote, Folder |
        Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8 -WhatIf:$false
    Write-Host "Saved: $CsvPath"
}
