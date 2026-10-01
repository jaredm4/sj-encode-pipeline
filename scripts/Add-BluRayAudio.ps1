<#
.SYNOPSIS
    Rebuilds the audio of encoded MP4s from their Blu-ray source MKVs: a compatible
    default track inside the MP4, and the lossless master in a matching external .mka.

.DESCRIPTION
    Works on one pair of files, or on whole folders.

    Single mode: -Source is the MKV and -Dest is the encoded MP4.

    Batch mode:  -Source and -Dest are mirrored folder trees (or the same folder). Every
                 MKV under -Source (recursively) is matched only to the MP4 at the same
                 relative path under -Dest, with the same file name:
                   S:\Sources\Shows\Show Name (2024)\Season 01\Show Name (2024) S01E01 Episode Title.mkv
                   L:\Library\Shows\Show Name (2024)\Season 01\Show Name (2024) S01E01 Episode Title.mp4
                 - A folder whose MKVs have no mirrored MP4 at all is skipped.
                 - In a partly matched folder, the matched pairs are processed and each
                   MKV without a mirrored MP4 is listed with the path that was expected.
                 Everything skipped or failed is listed in the summary at the end.
                 One failed pair doesn't stop the batch.

    Every run (including -WhatIf previews) also saves the summary to a log file on
    your Desktop, named after the start time, e.g.
    "Add-BluRayAudio 2026-10-01 193512.log"

    For each pair:
    1. Checks that the MP4 and MKV are the same length (within 2 s), to catch mismatched
       pairs before doing any work.
    2. Masters: every lossless track in the MKV (TrueHD incl. Atmos, DTS-HD MA incl.
       DTS:X and its built-in DTS core, PCM, FLAC, ALAC, MLP). Separate lossy tracks
       (AC-3, E-AC-3, DTS, AAC, Opus...) are not masters. The source's Default flag is
       ignored. All masters are kept together in one external "<name>.mka" next to the
       MP4, which Jellyfin (10.8+) shows as extra audio tracks. PCM becomes FLAC (still
       lossless).
    3. Main track (what the MP4's compatibility track is made from): the master with
       the most channels (then highest bitrate, then first in the list); it goes first
       in the .mka. If the source has no lossless track, the best lossy track is used
       the same way and the title is listed in its own section of the log. If that
       track is AC-3, E-AC-3 or AAC it goes into the MP4 as-is and no .mka is made;
       anything else (e.g. lossy DTS) is converted for the MP4 and the original is
       kept in the .mka, so nothing from the disc is lost.
       -SourceTrack overrides the choice (single mode only).
    4. If the MP4 already has audio, it is left untouched and only the .mka is made.
       Skipped if the .mka already exists, if there is nothing to keep in a .mka, or if
       the MP4 already contains lossless audio (listed for review instead).
       Otherwise (the MP4 has no audio), the audio is rebuilt with a full remux, and the
       MP4 gets one compatibility track made from the main track:
         - AC-3, E-AC-3 or AAC: copied as-is.
         - Other stereo or mono: AAC (-AacBitrate).
         - Other surround: a new AC-3 5.1 track (-Ac3Bitrate).
       The .mka is written in the same pass. With -EmbedMaster its tracks go into the
       MP4 as extra tracks instead.
    5. All other source audio tracks are dropped. Chapters come from the MKV; the video
       is copied from the MP4 untouched. Title metadata is set from the file name,
       following the Apple/iTunes MP4 tag convention (read by Apple TV, Infuse, Plex,
       Kodi, VLC). Bracketed parts like " [tmdbid-1234]" are removed and trailing ".tag"
       parts become " [tag]" at the end of the title.
         Episodes: "Show Name (2024) S01E04 Episode Title" -> title "Episode Title", show
                   "Show Name", season 1, episode 4, episode ID "S01E04", year 2024,
                   media kind TV Show.
         Movies:   "Name, Inc. (2001) [tmdbid-12345] - 2160p.imax" -> title
                   "Name, Inc. (2001) - 2160p [imax]", year 2001, media kind Movie.
       The video track gets the same title. The planned metadata is shown in the log,
       also with -WhatIf.
    6. Verifies the result: track counts, the .mka, Dolby Vision (if the MP4 had it) and
       that audio and video lengths match. With -Replace, the original MP4 is only
       replaced after these checks pass.

    Remux output without -Replace: "<name>.remux.mp4" (and "<name>.remux.mka") next to
                                   the MP4.
    Remux output with -Replace:    the MP4 is replaced in place and the master saved as
                                   "<name>.mka" next to it. If .remux files from an
                                   earlier run without -Replace exist, they are verified
                                   and used as-is instead of remuxing again. So you can:
                                   run once, check the .remux files, then run again with
                                   -Replace to swap them in.
    An extracted-only .mka is always written straight to "<name>.mka" (via a temporary
    "<name>.mka.partial" that is renamed once verified). If you rename an MP4 later,
    rename its .mka to match, or Jellyfin won't find it.

    Re-running is safe: MP4s that now have audio and a .mka are skipped.

.PARAMETER Source
    Required. The source MKV (single mode), or the root folder of the MKV tree to search
    recursively (batch mode). Must be the same kind as -Dest: both files or both folders.
    Alias: -SourceFile.
.PARAMETER Dest
    Required. The encoded MP4 (single mode), or the root folder of the mirrored MP4 tree
    (batch mode). Can be the same folder as -Source.
    Alias: -VideoFile.
.PARAMETER SourceTrack
    Single mode only. Use this source audio track as the main track (the one the MP4's
    compatibility track is made from) instead of auto-detecting it. 0-based, counting
    audio tracks only (the same numbering as ffmpeg's 1:a:N and the "Pos" column the
    script prints). Doesn't change which tracks are masters.
    Default: -1 (auto-detect: the master with the most channels, or the best lossy
    track if there is no lossless one).
.PARAMETER AacBitrate
    AAC bitrate in kbps for stereo sources, which become a single AAC 2.0 track.
    Mono sources are capped at 256 (AAC's per-channel limit).
    Allowed: 96-576. Default: 512.
.PARAMETER Ac3Bitrate
    AC-3 (Dolby Digital) bitrate in kbps for the 5.1 compatibility track made from
    surround sources.
    Allowed: 384, 448, 512, 576, 640 (640 is AC-3's maximum). Default: 640.
.PARAMETER AudioLanguage
    ISO 639-2 three-letter language tag written on every audio track the script
    creates (MP4 tracks and the .mka).
    Default: eng.
.PARAMETER EmbedMaster
    For MP4s without audio: put the lossless master inside the MP4 as a second audio
    track instead of an external .mka. TrueHD inside MP4 isn't readable by some players
    (e.g. VLC). MP4s that already have audio are skipped when this is set.
    Default: off (master goes to an external .mka).
.PARAMETER Replace
    For MP4s without audio: replace each original MP4 with the remuxed file once it
    passes verification, and save the master as "<name>.mka". If "<name>.remux.mp4"
    (and "<name>.remux.mka") already exist from an earlier run, they are verified and
    used instead of remuxing again; otherwise the remux is created first.
    Has no effect on MP4s that already have audio (their .mka is always written
    straight to "<name>.mka").
    Default: off (writes "<name>.remux.mp4" and "<name>.remux.mka" next to the original).
.PARAMETER Force
    Redo remuxes even if .remux.mp4 / .remux.mka files exist (overwriting them, also
    with -Replace), and re-extract .mka files that already exist.
    Default: off (existing outputs are skipped and listed).
.PARAMETER WhatIf
    Built-in PowerShell switch. Show the matching and every plan, including the exact
    ffmpeg commands, without writing anything.

.EXAMPLE
    .\Add-BluRayAudio.ps1 -Source 'S:\Sources\Shows' -Dest 'L:\Library\Shows' -WhatIf
    Shows the matching and every plan without writing anything.
.EXAMPLE
    .\Add-BluRayAudio.ps1 -Source 'S:\Sources\Shows' -Dest 'L:\Library\Shows' -Replace
    Processes the whole tree, replacing MP4s in place.
.EXAMPLE
    .\Add-BluRayAudio.ps1 -Source '.\S01E01.mkv' -Dest '.\S01E01.mp4'
    Single pair, writing S01E01.remux.mp4 (and S01E01.remux.mka) next to the MP4.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][Alias('SourceFile')][string]$Source,
    [Parameter(Mandatory)][Alias('VideoFile')][string]$Dest,
    [int]$SourceTrack = -1,
    [ValidateRange(96, 576)][int]$AacBitrate = 512,
    [ValidateSet(384, 448, 512, 576, 640)][int]$Ac3Bitrate = 640,
    [ValidatePattern('^[a-z]{3}$')][string]$AudioLanguage = 'eng',
    [switch]$EmbedMaster,
    [switch]$Replace,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$script:Cmdlet = $PSCmdlet

# ================================================================ helpers

function Get-Tool([string]$Name) {
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $cmd) { throw "'$Name' was not found on PATH. Install it or add its folder to PATH." }
    return $cmd.Source
}

function Get-Field($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value } else { return $null }
}

function ConvertTo-Number($Value) {
    $n = 0.0
    $ok = [double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$n)
    if ($ok) { return $n } else { return 0.0 }
}

function Get-ChannelLabel([int]$Channels) {
    switch ($Channels) {
        8 { return '7.1' }
        7 { return '6.1' }
        6 { return '5.1' }
        2 { return '2.0' }
        1 { return '1.0' }
    }
    return "$Channels ch"
}

function Get-FriendlyName([string]$Codec, [string]$codecProfile) {
    if ($Codec -in @('dts', 'truehd') -and $codecProfile -and $codecProfile -ne 'unknown' -and $codecProfile -notmatch '^-?\d+$') {
        return $codecProfile   # e.g. "DTS-HD MA", "DTS-HD MA + DTS:X", "Dolby TrueHD + Dolby Atmos"
    }
    switch -Regex ($Codec) {
        '^truehd$' { return 'Dolby TrueHD' }
        '^dts$'    { return 'DTS' }
        '^ac3$'    { return 'Dolby Digital' }
        '^eac3$'   { return 'Dolby Digital Plus' }
        '^flac$'   { return 'FLAC' }
        '^aac$'    { return 'AAC' }
        '^pcm_'    { return 'PCM' }
    }
    return $Codec.ToUpper()
}

function Test-Lossless([string]$Codec, [string]$codecProfile) {
    if ($Codec -match '^(truehd|mlp|flac|alac|pcm_.*)$') { return $true }
    if ($Codec -eq 'dts' -and $codecProfile -like 'DTS-HD MA*') { return $true }
    return $false
}

function Format-Arg([string]$Arg) {
    if ($Arg -eq '' -or $Arg -match '[\s"]') { return '"' + ($Arg -replace '"', '\"') + '"' }
    return $Arg
}

function Get-Streams([string]$File) {
    $json = & $script:ffprobe -v error -show_streams -of json $File | Out-String
    if ($LASTEXITCODE -ne 0) { throw "ffprobe failed on $File" }
    return @((ConvertFrom-Json $json).streams)
}

function Get-Format([string]$File) {
    $json = & $script:ffprobe -v error -show_format -of json $File | Out-String
    if ($LASTEXITCODE -ne 0) { throw "ffprobe failed on $File" }
    return (ConvertFrom-Json $json).format
}

function Test-DolbyVision($VideoStream) {
    $sideData = @(Get-Field $VideoStream 'side_data_list')
    return [bool](@($sideData | Where-Object { (Get-Field $_ 'side_data_type') -like 'DOVI*' }).Count)
}

function New-OutputTrack([int]$SrcPos, [string]$Codec, [int]$Kbps, [int]$Ac, [string]$Title, [string]$Note) {
    return [pscustomobject]@{ SrcPos = $SrcPos; Codec = $Codec; Kbps = $Kbps; Ac = $Ac; Title = $Title; Note = $Note }
}

function New-Result([string]$Status, [string]$Message) {
    return [pscustomobject]@{ Status = $Status; Message = $Message }
}

# ffprobe doesn't read track titles back from MP4 files (ffmpeg writes them where
# MediaInfo, Jellyfin and players read them), so MP4 titles are checked with the
# MediaInfo CLI when it's installed. Returns $null if MediaInfo isn't available.
function Get-Mp4Titles([string]$File) {
    if (-not $script:mediainfo) { return $null }
    $v = (& $script:mediainfo '--Inform=Video;%Title%|' $File | Out-String).Trim()
    $a = (& $script:mediainfo '--Inform=Audio;%Title%|' $File | Out-String).Trim()
    return [pscustomobject]@{
        Video = ($v -split '\|')[0]
        Audio = @($a -split '\|')
    }
}

# Title metadata from the MP4's file name (without extension), following the Apple/iTunes
# MP4 tag convention read by Apple TV, Infuse, Plex, Kodi and VLC.
# - Bracketed parts like " [tmdbid-1234]" are removed.
# - Trailing ".tag" parts become " [tag]" at the end of the title. A ".tag" counts only
#   if it has no spaces, isn't all digits, and the dot isn't followed by a space
#   (so "Name, Inc. (2001)" and "Dr. Name" are safe).
# Episodes (the name contains SxxEyy):
#   "Show Name (2024) S01E04 Episode Title"
#     -> Title "Episode Title", Show "Show Name", Season 1, Episode 4, EpisodeId "S01E04", Year 2024
# Movies:
#   "Name, Inc. (2001) [tmdbid-12345] - 2160p.imax"
#     -> Title "Name, Inc. (2001) - 2160p [imax]", Year 2001
function Get-TitleInfo([string]$BaseName) {
    $name = $BaseName.Trim()
    $tags = [Collections.Generic.List[string]]::new()
    while ($name -match '^(.*\S)\.([^\s.\[\]()]+)$' -and $Matches[2] -notmatch '^\d+$') {
        $tags.Insert(0, $Matches[2])
        $name = $Matches[1]
    }
    $name = $name -replace '\s*\[[^\]]*\]', ''     # drop [tmdbid-...] and other bracketed bits
    $name = $name -replace '\s+-\s*$', ''            # no dangling " -" at the end
    $name = ($name -replace '\s{2,}', ' ').Trim()
    $tagSuffix = ($tags | ForEach-Object { " [$_]" }) -join ''

    $info = [pscustomobject]@{
        Kind = 'Movie'; Title = ''; Show = ''; Season = 0; Episode = 0; EpisodeId = ''; Year = ''
    }

    if ($name -match '^(?<show>.+?)\s+(?<id>S(?<s>\d{1,3})E(?<e>\d{1,4})(?:-?E\d{1,4})*)(?:\s+(?:-\s+)?(?<ep>.*))?$') {
        $show = $Matches['show'].Trim()
        $id = $Matches['id'].ToUpper()
        $season = [int]$Matches['s']
        $episode = [int]$Matches['e']
        $epName = ([string]$Matches['ep']).Trim()

        $show = ($show -replace '\s*-$', '').Trim()
        if ($show -match '^(.*?)\s*\((\d{4})\)$') {
            $info.Year = $Matches[2]
            $show = $Matches[1].Trim()
        }
        if (-not $epName) { $epName = $id }

        $info.Kind = 'Episode'
        $info.Title = $epName + $tagSuffix
        $info.Show = $show
        $info.Season = $season
        $info.Episode = $episode
        $info.EpisodeId = $id
    } else {
        if ($name -match '\((\d{4})\)') { $info.Year = $Matches[1] }
        $info.Title = $name + $tagSuffix
    }
    return $info
}

# ffmpeg arguments for one Matroska audio output holding every master track.
# $InputIndex is the ffmpeg input number of the source MKV.
function Get-MkaArgs($Tracks, [int]$InputIndex, [string]$OutPath) {
    $a = [Collections.Generic.List[string]]::new()
    foreach ($t in $Tracks) { $a.AddRange([string[]]@('-map', "$($InputIndex):a:$($t.SrcPos)")) }
    $a.AddRange([string[]]@('-map_metadata', '-1', '-map_chapters', '-1',
        '-metadata', "title=$(($Tracks | ForEach-Object { $_.Title }) -join ' / ')"))
    for ($i = 0; $i -lt $Tracks.Count; $i++) {
        $t = $Tracks[$i]
        $a.AddRange([string[]]@("-c:a:$i", $t.Codec, "-disposition:a:$i", '0',
            "-metadata:s:a:$i", "language=$AudioLanguage", "-metadata:s:a:$i", "title=$($t.Title)"))
    }
    $a.AddRange([string[]]@('-f', 'matroska', $OutPath))
    return ,$a.ToArray()
}

function Get-TitleSummary($Info) {
    $year = ''
    if ($Info.Year) { $year = ", $($Info.Year)" }
    if ($Info.Kind -eq 'Episode') {
        return "title '$($Info.Title)' (TV: $($Info.Show), season $($Info.Season), episode $($Info.Episode) [$($Info.EpisodeId)]$year)"
    }
    return "title '$($Info.Title)' (movie$year)"
}

# ================================================================ one pair

function Invoke-AudioRebuild([string]$SourceFile, [string]$VideoFile) {

    $dir = [IO.Path]::GetDirectoryName($VideoFile)
    $base = [IO.Path]::GetFileNameWithoutExtension($VideoFile)
    $masterMka = Join-Path $dir ($base + '.mka')   # where Jellyfin looks for the external master
    $titleInfo = Get-TitleInfo $base
    $videoTitle = $titleInfo.Title
    $titleDesc = Get-TitleSummary $titleInfo
    $reuse = $false

    # ------------------------------------------------ inspect the MP4
    $videoFormat = Get-Format $VideoFile
    $videoAll = Get-Streams $VideoFile
    $videoStreams = @($videoAll | Where-Object { $_.codec_type -eq 'video' })
    $mp4Audio = @($videoAll | Where-Object { $_.codec_type -eq 'audio' })
    if ($videoStreams.Count -eq 0) { throw "No video stream found in $VideoFile" }
    $videoCodec = [string]$videoStreams[0].codec_name
    $videoHasDv = Test-DolbyVision $videoStreams[0]

    # MP4 with audio already: leave it alone and only extract the master to a .mka.
    $extractOnly = $mp4Audio.Count -gt 0

    if ($extractOnly) {
        $mp4Lossless = @($mp4Audio | Where-Object { Test-Lossless ([string]$_.codec_name) ([string](Get-Field $_ 'profile')) })
        if ($mp4Lossless.Count -gt 0) {
            return New-Result 'Skipped' "MP4 already contains lossless audio ($(($mp4Lossless | ForEach-Object { $_.codec_name }) -join ', ')); review by hand"
        }
        if ($EmbedMaster) {
            return New-Result 'Skipped' 'MP4 already has audio (-EmbedMaster only applies to MP4s without audio)'
        }
        if ((Test-Path -LiteralPath $masterMka) -and -not $Force) {
            return New-Result 'Skipped' 'MP4 has audio and the .mka already exists'
        }
        Write-Host ("MP4 already has {0} audio track(s) ({1}); leaving it as-is, extracting the master only." -f
            $mp4Audio.Count, (($mp4Audio | ForEach-Object { "$($_.codec_name) $(Get-ChannelLabel ([int]$_.channels))" }) -join ', '))
    } else {
        # With -Replace these are work files that get renamed over the originals at the end.
        $OutFile = Join-Path $dir ($base + '.remux.mp4')
        $extFile = Join-Path $dir ($base + '.remux.mka')
        $finalMka = $null
        if ($Replace) { $finalMka = $masterMka }

        $haveRemux = Test-Path -LiteralPath $OutFile
        $haveRemuxMka = Test-Path -LiteralPath $extFile
        if (-not $Force -and ($haveRemux -or $haveRemuxMka)) {
            if (-not $haveRemux) {
                return New-Result 'Skipped' "leftover $([IO.Path]::GetFileName($extFile)) without a .remux.mp4 (delete it, or use -Force)"
            }
            if (-not $Replace) {
                return New-Result 'Skipped' 'remux files from an earlier run exist; review them, then run with -Replace to use them (or -Force to redo)'
            }
            $reuse = $true   # -Replace with an existing remux: verify it and use it instead of redoing it
        }
    }

    # ------------------------------------------------ check the pair
    $srcFormat = Get-Format $SourceFile
    $vLen = ConvertTo-Number (Get-Field $videoFormat 'duration')
    $sLen = ConvertTo-Number (Get-Field $srcFormat 'duration')
    if ($vLen -gt 0 -and $sLen -gt 0 -and [Math]::Abs($vLen - $sLen) -gt 2) {
        throw ("Length mismatch: MP4 is {0:N0}s, MKV is {1:N0}s. Is this the right pair?" -f $vLen, $sLen)
    }

    $srcStreams = Get-Streams $SourceFile
    if (-not $extractOnly) {
        $srcVideo = @($srcStreams | Where-Object { $_.codec_type -eq 'video' })
        $sourceHasDv = ($srcVideo.Count -gt 0) -and (Test-DolbyVision $srcVideo[0])
        if ($sourceHasDv -and -not $videoHasDv) {
            Write-Warning 'The source has Dolby Vision but the encoded video does not. The output will be HDR10 only.'
        }
    }

    # ------------------------------------------------ inspect source audio
    $srcAudio = @($srcStreams | Where-Object { $_.codec_type -eq 'audio' })
    if ($srcAudio.Count -eq 0) { throw "No audio tracks found in $SourceFile" }

    $audio = @(for ($i = 0; $i -lt $srcAudio.Count; $i++) {
        $s = $srcAudio[$i]
        $codec = [string]$s.codec_name
        $codecProfile = [string](Get-Field $s 'profile')
        $tags = Get-Field $s 'tags'
        $bitrate = ConvertTo-Number (Get-Field $s 'bit_rate')
        if ($bitrate -le 0) { $bitrate = ConvertTo-Number (Get-Field $tags 'BPS') }
        if ($bitrate -le 0) { $bitrate = ConvertTo-Number (Get-Field $tags 'BPS-eng') }

        [pscustomobject]@{
            Pos      = $i
            Codec    = $codec
            Name     = Get-FriendlyName $codec $codecProfile
            Channels = [int](ConvertTo-Number (Get-Field $s 'channels'))
            BitRate  = $bitrate
            Lossless = Test-Lossless $codec $codecProfile
            Title    = [string](Get-Field $tags 'title')
        }
    })

    Write-Host 'Audio tracks in source:'
    $audio | Format-Table -AutoSize Pos, Name,
        @{ n = 'Ch';   e = { Get-ChannelLabel $_.Channels } },
        @{ n = 'kbps'; e = { if ($_.BitRate -gt 0) { [math]::Round($_.BitRate / 1000) } else { '?' } } },
        Lossless, Title | Out-Host

    # ------------------------------------------------ masters and the main track
    # The Default flag is ignored: it doesn't reflect the disc.
    # Masters = every lossless track (a DTS-HD MA track keeps its DTS core inside it;
    # separate lossy DTS tracks are not masters).
    $masters = @($audio | Where-Object Lossless)

    # Best track = most channels, then highest bitrate, then first in the list.
    function Select-BestTrack($Tracks) {
        $best = $null
        foreach ($t in $Tracks) {
            if (-not $best -or $t.Channels -gt $best.Channels -or
                ($t.Channels -eq $best.Channels -and $t.BitRate -gt $best.BitRate)) { $best = $t }
        }
        return $best
    }

    # Main track = what the MP4's compatibility track is made from.
    $script:FlagNoLossless = ($masters.Count -eq 0)
    if ($SourceTrack -ge 0) {
        if ($SourceTrack -ge $audio.Count) { throw "There is no audio track $SourceTrack (0-$($audio.Count - 1))." }
        $pick = $audio[$SourceTrack]
        $why = 'chosen with -SourceTrack'
    } elseif ($masters.Count -gt 0) {
        $pick = Select-BestTrack $masters
        $why = 'lossless track with the most channels'
    } else {
        $pick = Select-BestTrack $audio
        $why = 'NO LOSSLESS TRACK in the source; best lossy track'
        Write-Warning 'The source has no lossless audio track.'
    }

    $srcLabel = "$($pick.Name) $(Get-ChannelLabel $pick.Channels)"
    Write-Host "Main track: audio $($pick.Pos) - $srcLabel ($why)"

    # Lossy formats that go into the MP4 as-is (every target player handles them).
    $copyable = $pick.Codec -in @('ac3', 'eac3', 'aac')

    # Kept in the .mka: every master, main one first. With no lossless tracks, a main
    # track that has to be converted for the MP4 (e.g. lossy DTS) is kept there instead,
    # so the original is never lost.
    $keep = @($masters | Where-Object { $_.Pos -eq $pick.Pos }) + @($masters | Where-Object { $_.Pos -ne $pick.Pos })
    if ($masters.Count -eq 0 -and -not $copyable) { $keep = @($pick) }

    $masterTracks = [Collections.Generic.List[object]]::new()
    foreach ($m in $keep) {
        if ($m.Codec -like 'pcm_*') {
            $masterTracks.Add((New-OutputTrack $m.Pos 'flac' 0 0 "FLAC $(Get-ChannelLabel $m.Channels)" "audio $($m.Pos): PCM converted to FLAC (lossless)"))
        } else {
            $note = "audio $($m.Pos): copied"
            if (-not $m.Lossless) { $note = "audio $($m.Pos): copied (original lossy track, kept because the MP4 gets a converted copy)" }
            $masterTracks.Add((New-OutputTrack $m.Pos 'copy' 0 0 "$($m.Name) $(Get-ChannelLabel $m.Channels)" $note))
        }
    }
    $mastersLabel = ($masterTracks | ForEach-Object { $_.Title }) -join ', '
    $keepPos = @($keep | ForEach-Object { $_.Pos })   # source positions kept in the .mka

    # ================================================ path 1: extract the masters only
    if ($extractOnly) {
        if ($masterTracks.Count -eq 0) {
            return New-Result 'Skipped' "MP4 has audio; the source has no lossless track, and its best track ($srcLabel) needs no .mka"
        }

        $partial = Join-Path $dir ($base + '.mka.partial')   # not a media extension, so Jellyfin ignores it
        $argArray = [string[]](@('-hide_banner', '-y', '-i', $SourceFile) + (Get-MkaArgs $masterTracks 0 $partial))

        Write-Host "Master(s) -> $masterMka"
        foreach ($m in $masterTracks) { Write-Host ("  {0,-40} {1}" -f $m.Title, $m.Note) }
        foreach ($d in @($audio | Where-Object { $_.Pos -notin $keepPos })) {
            Write-Host "  not kept (lossy): audio $($d.Pos) - $($d.Name) $(Get-ChannelLabel $d.Channels)" -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-Host ((Format-Arg $script:ffmpeg) + ' ' + (($argArray | ForEach-Object { Format-Arg $_ }) -join ' ')) -ForegroundColor Cyan
        Write-Host ''

        if (-not $script:Cmdlet.ShouldProcess($masterMka, 'Extract master audio with ffmpeg')) {
            return New-Result 'Planned' "extract $mastersLabel to .mka; MP4 untouched, video title unchanged"
        }

        & $script:ffmpeg @argArray
        if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed with exit code $LASTEXITCODE" }

        $problems = [Collections.Generic.List[string]]::new()
        $extAudio = @(Get-Streams $partial | Where-Object { $_.codec_type -eq 'audio' })
        foreach ($s in $extAudio) {
            Write-Host ("  .mka:  {0,-7} {1,-4} {2}" -f $s.codec_name,
                (Get-ChannelLabel ([int]$s.channels)), (Get-Field (Get-Field $s 'tags') 'title'))
        }
        if ($extAudio.Count -ne $masterTracks.Count) {
            $problems.Add("expected $($masterTracks.Count) audio track(s) in the .mka, found $($extAudio.Count)")
        }
        $mLen = ConvertTo-Number (Get-Field (Get-Format $partial) 'duration')
        if ($vLen -gt 0 -and $mLen -gt 0 -and [Math]::Abs($vLen - $mLen) -gt 2) {
            $problems.Add(("the .mka is {0:N0}s but the MP4 is {1:N0}s" -f $mLen, $vLen))
        }
        if ($problems.Count -gt 0) {
            throw "Verification failed ($($problems -join '; ')). Output left for inspection: $partial"
        }

        Move-Item -LiteralPath $partial -Destination $masterMka -Force
        Write-Host '  .mka created.' -ForegroundColor Green
        return New-Result 'Done' "extracted $mastersLabel to .mka; MP4 untouched, video title unchanged"
    }

    # ================================================ path 2: full remux (MP4 has no audio)
    $outputs = [Collections.Generic.List[object]]::new()
    $externals = [Collections.Generic.List[object]]::new()

    if ($copyable) {
        $outputs.Add((New-OutputTrack $pick.Pos 'copy' 0 0 $srcLabel 'copied as-is'))
    } elseif ($pick.Channels -le 2) {
        $kbps = $AacBitrate
        if ($pick.Channels -eq 1) { $kbps = [Math]::Min($AacBitrate, 256) }
        $outputs.Add((New-OutputTrack $pick.Pos 'aac' $kbps 0 "AAC $(Get-ChannelLabel $pick.Channels)" "encoded from $srcLabel at $kbps kbps"))
    } else {
        $ac = 0
        if ($pick.Channels -gt 6) { $ac = 6 }
        $outputs.Add((New-OutputTrack $pick.Pos 'ac3' $Ac3Bitrate $ac "Dolby Digital $(Get-ChannelLabel ([Math]::Min($pick.Channels, 6)))" "encoded from $srcLabel at $Ac3Bitrate kbps"))
    }
    foreach ($m in $masterTracks) {
        if ($EmbedMaster) { $outputs.Add($m) } else { $externals.Add($m) }
    }

    # e.g. "Dolby Digital 5.1 (from Dolby TrueHD + Dolby Atmos 7.1) to MP4, Dolby TrueHD + Dolby Atmos 7.1 to .mka"
    $mp4Parts = foreach ($o in $outputs) {
        if ($o.Codec -eq 'copy') { $o.Title } else { "$($o.Title) (from $srcLabel)" }
    }
    $remuxLabel = "$($mp4Parts -join ', ') to MP4"
    if ($externals.Count -gt 0) {
        $remuxLabel += ", $(($externals | ForEach-Object { $_.Title }) -join ', ') to .mka"
    }

    $mkaAfter = $extFile
    if ($Replace) { $mkaAfter = $finalMka }
    if ($externals.Count -eq 0 -and (Test-Path -LiteralPath $mkaAfter)) {
        Write-Warning "$([IO.Path]::GetFileName($mkaAfter)) exists but this title has no external master; Jellyfin would still show it as an audio track."
    }

    $ffArgs = [Collections.Generic.List[string]]::new()
    $ffArgs.AddRange([string[]]@('-hide_banner', '-i', $VideoFile, '-i', $SourceFile, '-map', '0:v:0'))
    foreach ($o in $outputs) { $ffArgs.AddRange([string[]]@('-map', "1:a:$($o.SrcPos)")) }
    $ffArgs.AddRange([string[]]@('-map_chapters', '1', '-c:v', 'copy'))
    if ($videoCodec -eq 'hevc') { $ffArgs.AddRange([string[]]@('-tag:v', 'hvc1')) }
    # Video track title, plus Apple/iTunes-style file-level tags.
    $ffArgs.AddRange([string[]]@('-metadata:s:v:0', "title=$videoTitle", '-metadata', "title=$videoTitle"))
    if ($titleInfo.Year) { $ffArgs.AddRange([string[]]@('-metadata', "date=$($titleInfo.Year)")) }
    if ($titleInfo.Kind -eq 'Episode') {
        $ffArgs.AddRange([string[]]@(
            '-metadata', "show=$($titleInfo.Show)",
            '-metadata', "season_number=$($titleInfo.Season)",
            '-metadata', "episode_sort=$($titleInfo.Episode)",
            '-metadata', "episode_id=$($titleInfo.EpisodeId)",
            '-metadata', 'media_type=10'))   # 10 = TV Show
    } else {
        $ffArgs.AddRange([string[]]@('-metadata', 'media_type=9'))   # 9 = Movie
    }

    for ($i = 0; $i -lt $outputs.Count; $i++) {
        $o = $outputs[$i]
        $ffArgs.AddRange([string[]]@("-c:a:$i", $o.Codec))
        if ($o.Kbps -gt 0) { $ffArgs.AddRange([string[]]@("-b:a:$i", "$($o.Kbps)k")) }
        if ($o.Ac -gt 0) { $ffArgs.AddRange([string[]]@("-ac:a:$i", "$($o.Ac)")) }
        $disp = '0'
        if ($i -eq 0) { $disp = 'default' }
        $ffArgs.AddRange([string[]]@("-disposition:a:$i", $disp,
            "-metadata:s:a:$i", "language=$AudioLanguage", "-metadata:s:a:$i", "title=$($o.Title)"))
    }

    $ffArgs.AddRange([string[]]@('-strict', 'experimental', '-movflags', '+faststart'))
    if ($Force) { $ffArgs.Add('-y') } else { $ffArgs.Add('-n') }
    $ffArgs.Add($OutFile)

    if ($externals.Count -gt 0) {
        # Second output in the same pass: every master in one Matroska audio file.
        $ffArgs.AddRange([string[]](Get-MkaArgs $externals 1 $extFile))
    }

    Write-Host "Metadata: $titleDesc"
    Write-Host 'Planned output audio (full remux; the MP4 has no audio):'
    for ($i = 0; $i -lt $outputs.Count; $i++) {
        $o = $outputs[$i]
        $flag = ''
        if ($i -eq 0) { $flag = '  [default]' }
        Write-Host ("  a:{0}  {1,-40} {2}{3}" -f $i, $o.Title, $o.Note, $flag)
    }
    foreach ($m in $externals) { Write-Host ("  .mka {0,-40} {1}" -f $m.Title, $m.Note) }
    foreach ($d in @($audio | Where-Object { $_.Pos -ne $pick.Pos -and $_.Pos -notin $keepPos })) {
        Write-Host "  dropped: audio $($d.Pos) - $($d.Name) $(Get-ChannelLabel $d.Channels)" -ForegroundColor DarkGray
    }
    if ($Replace) {
        Write-Host "Replaces: $VideoFile"
        if ($externals.Count -gt 0) { Write-Host "Master:   $finalMka" }
    } else {
        Write-Host "Output:   $OutFile"
        if ($externals.Count -gt 0) { Write-Host "          $extFile" }
    }
    Write-Host ''

    if ($reuse) {
        Write-Host "Using the existing remux from an earlier run (it will be verified first):" -ForegroundColor Yellow
        Write-Host "  $OutFile"
        if ($externals.Count -gt 0) { Write-Host "  $extFile" }
        Write-Host ''
        $action = 'Replace with the existing remux files'
        $what = 'replace with existing remux'
    } else {
        $argArray = $ffArgs.ToArray()
        Write-Host ((Format-Arg $script:ffmpeg) + ' ' + (($argArray | ForEach-Object { Format-Arg $_ }) -join ' ')) -ForegroundColor Cyan
        Write-Host ''
        $action = 'Rebuild audio with ffmpeg'
        $what = 'remux'
    }

    if (-not $script:Cmdlet.ShouldProcess($VideoFile, $action)) {
        return New-Result 'Planned' "${what}: $remuxLabel; $titleDesc"
    }

    if (-not $reuse) {
        & $script:ffmpeg @argArray
        if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed with exit code $LASTEXITCODE" }
    }

    # ------------------------------------------------ verify
    $problems = [Collections.Generic.List[string]]::new()
    $notes = [Collections.Generic.List[string]]::new()
    $outStreams = Get-Streams $OutFile
    $outVideo = @($outStreams | Where-Object { $_.codec_type -eq 'video' })
    $outAudio = @($outStreams | Where-Object { $_.codec_type -eq 'audio' })

    Write-Host "`nResult:"
    $mi = Get-Mp4Titles $OutFile
    if (-not $mi) {
        Write-Host '  video title: (not checked; install the MediaInfo CLI to check titles)'
    } elseif ($outVideo.Count -gt 0) {
        Write-Host "  video title: $($mi.Video)"
        if ($mi.Video -ne $videoTitle) {
            $notes.Add("video title is '$($mi.Video)', expected '$videoTitle' (use -Force to redo the remux)")
        }
    }
    for ($i = 0; $i -lt $outAudio.Count; $i++) {
        $s = $outAudio[$i]
        $t = ''
        if ($mi -and $i -lt $mi.Audio.Count) { $t = $mi.Audio[$i] }
        Write-Host ("  audio: {0,-7} {1,-4} default={2}  {3}" -f $s.codec_name,
            (Get-ChannelLabel ([int]$s.channels)), (Get-Field (Get-Field $s 'disposition') 'default'), $t)
    }
    if ($outAudio.Count -ne $outputs.Count) {
        $problems.Add("expected $($outputs.Count) audio track(s) in the MP4, found $($outAudio.Count)")
    }

    # Full length compared with the original MP4: catches a remux that was cut short.
    $outFormat = Get-Format $OutFile
    $oLen = ConvertTo-Number (Get-Field $outFormat 'duration')

    $fTags = Get-Field $outFormat 'tags'
    $want = [ordered]@{ title = $videoTitle }
    if ($titleInfo.Kind -eq 'Episode') {
        $want['show'] = $titleInfo.Show
        $want['episode_id'] = $titleInfo.EpisodeId
    }
    foreach ($k in $want.Keys) {
        $got = [string](Get-Field $fTags $k)
        if ($got -ne $want[$k]) {
            $notes.Add("file-level $k is '$got', expected '$($want[$k])' (use -Force to redo the remux)")
        }
    }
    $line = "  metadata: title '$(Get-Field $fTags 'title')'"
    if ($titleInfo.Kind -eq 'Episode') {
        $line += ", show '$(Get-Field $fTags 'show')', $(Get-Field $fTags 'episode_id')"
    }
    Write-Host $line
    if ($vLen -gt 0 -and [Math]::Abs($vLen - $oLen) -gt 2) {
        $problems.Add(("the remux is {0:N0}s but the original MP4 is {1:N0}s" -f $oLen, $vLen))
    }

    if ($outVideo.Count -gt 0 -and $outAudio.Count -gt 0) {
        $vDur = ConvertTo-Number (Get-Field $outVideo[0] 'duration')
        $aDur = ConvertTo-Number (Get-Field $outAudio[0] 'duration')
        if ($vDur -gt 0 -and $aDur -gt 0 -and [Math]::Abs($vDur - $aDur) -gt 2) {
            $problems.Add(("audio is {0:N0}s but video is {1:N0}s" -f $aDur, $vDur))
        }
    }

    if ($externals.Count -gt 0) {
        if (Test-Path -LiteralPath $extFile) {
            $extAudio = @(Get-Streams $extFile | Where-Object { $_.codec_type -eq 'audio' })
            foreach ($s in $extAudio) {
                Write-Host ("  .mka:  {0,-7} {1,-4} {2}" -f $s.codec_name,
                    (Get-ChannelLabel ([int]$s.channels)), (Get-Field (Get-Field $s 'tags') 'title'))
            }
            if ($extAudio.Count -ne $externals.Count) {
                $problems.Add("expected $($externals.Count) audio track(s) in the .mka, found $($extAudio.Count)")
            }
            $mLen = ConvertTo-Number (Get-Field (Get-Format $extFile) 'duration')
            if ($vLen -gt 0 -and $mLen -gt 0 -and [Math]::Abs($vLen - $mLen) -gt 2) {
                $problems.Add(("the .mka is {0:N0}s but the MP4 is {1:N0}s" -f $mLen, $vLen))
            }
        } else {
            $problems.Add("the external .mka is missing: $([IO.Path]::GetFileName($extFile))")
        }
    }

    $outHasDv = ($outVideo.Count -gt 0) -and (Test-DolbyVision $outVideo[0])
    if ($outHasDv) {
        Write-Host '  Dolby Vision configuration record: present' -ForegroundColor Green
    } elseif ($videoHasDv) {
        $problems.Add('the encoded video had Dolby Vision, but the output does not')
    } else {
        Write-Host '  Dolby Vision: none (not in the encoded video)'
    }

    foreach ($n in $notes) { Write-Warning $n }
    if ($problems.Count -gt 0) {
        throw "Verification failed ($($problems -join '; ')). Output left for inspection: $OutFile"
    }

    if ($Replace) {
        Move-Item -LiteralPath $OutFile -Destination $VideoFile -Force
        if ($externals.Count -gt 0) { Move-Item -LiteralPath $extFile -Destination $finalMka -Force }
        Write-Host '  Original MP4 replaced.' -ForegroundColor Green
    }

    $msg = "${what}: $remuxLabel; $titleDesc"
    if ($reuse -and $notes.Count -gt 0) { $msg += "; NOTE: $($notes -join '; ')" }
    return New-Result 'Done' $msg
}

# ================================================================ main

$startTime = Get-Date
$logPath = Join-Path ([Environment]::GetFolderPath('Desktop')) `
    ('Add-BluRayAudio {0:yyyy-MM-dd HHmmss}.log' -f $startTime)

$script:ffmpeg = Get-Tool 'ffmpeg'
$script:ffprobe = Get-Tool 'ffprobe'
$script:mediainfo = Get-Command 'mediainfo' -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty Source   # optional: only used to check MP4 titles

if (-not (Test-Path -LiteralPath $Source)) { throw "Source not found: $Source" }
if (-not (Test-Path -LiteralPath $Dest)) { throw "Dest not found: $Dest" }
$Source = (Resolve-Path -LiteralPath $Source).ProviderPath
$Dest = (Resolve-Path -LiteralPath $Dest).ProviderPath
$batch = Test-Path -LiteralPath $Source -PathType Container
if ($batch -ne (Test-Path -LiteralPath $Dest -PathType Container)) {
    throw '-Source and -Dest must both be files, or both be folders.'
}

$pairs       = [Collections.Generic.List[object]]::new()
$done        = [Collections.Generic.List[string]]::new()
$planned     = [Collections.Generic.List[string]]::new()
$skipped     = [Collections.Generic.List[string]]::new()
$failed      = [Collections.Generic.List[string]]::new()
$skippedDirs = [Collections.Generic.List[string]]::new()
$unmatched   = [Collections.Generic.List[string]]::new()
$noLosslessTitles  = [Collections.Generic.List[string]]::new()

if (-not $batch) {
    $pairs.Add([pscustomobject]@{ Source = $Source; Video = $Dest })
} else {
    if ($SourceTrack -ge 0) { throw '-SourceTrack only works with single files.' }

    $srcRoot = $Source.TrimEnd('\', '/')
    $dstRoot = $Dest.TrimEnd('\', '/')

    # Each MKV maps to exactly one MP4: same relative folder under Dest, same base name.
    $mkvs = @(Get-ChildItem -LiteralPath $srcRoot -Recurse -File | Where-Object { $_.Extension -eq '.mkv' })
    foreach ($group in ($mkvs | Group-Object DirectoryName | Sort-Object Name)) {
        $relDir = $group.Name.Substring($srcRoot.Length).TrimStart('\', '/')
        $mirrorDir = $dstRoot
        if ($relDir) { $mirrorDir = Join-Path $dstRoot $relDir }

        $matched = [Collections.Generic.List[object]]::new()
        $missing = [Collections.Generic.List[string]]::new()
        foreach ($mkv in ($group.Group | Sort-Object Name)) {
            $mp4 = Join-Path $mirrorDir ($mkv.BaseName + '.mp4')
            if (Test-Path -LiteralPath $mp4 -PathType Leaf) {
                $matched.Add([pscustomobject]@{ Source = $mkv.FullName; Video = $mp4 })
            } else {
                $missing.Add("$($mkv.FullName)`n      expected: $mp4")
            }
        }

        if ($matched.Count -eq 0) {
            $why = 'mirrored folder exists, but none of the MP4 names match'
            if (-not (Test-Path -LiteralPath $mirrorDir -PathType Container)) { $why = 'mirrored folder does not exist' }
            $skippedDirs.Add("$($group.Name)  ($($group.Count) MKV(s))`n      expected: $mirrorDir`n      $why")
        } else {
            foreach ($m in $matched) { $pairs.Add($m) }
            foreach ($m in $missing) { $unmatched.Add($m) }
        }
    }
    Write-Host ("Found {0} MKV(s): {1} matched, {2} unmatched in partly matched folders, {3} folder(s) skipped." -f
        $mkvs.Count, $pairs.Count, $unmatched.Count, $skippedDirs.Count)
}

for ($n = 0; $n -lt $pairs.Count; $n++) {
    $p = $pairs[$n]
    # Folders are mirrored, so the file name alone identifies each title.
    $name = [IO.Path]::GetFileName($p.Video)
    Write-Host ("`n==== [{0}/{1}] {2}" -f ($n + 1), $pairs.Count, $name) -ForegroundColor Yellow
    try {
        $script:FlagNoLossless = $false
        $r = Invoke-AudioRebuild $p.Source $p.Video
        if ($script:FlagNoLossless) { $noLosslessTitles.Add("$name  ($($r.Status): $($r.Message))") }
        switch ($r.Status) {
            'Done'    { $done.Add("$name  ($($r.Message))") }
            'Planned' { $planned.Add("$name  ($($r.Message))") }
            'Skipped' { $skipped.Add("$name  ($($r.Message))"); Write-Host "Skipped: $($r.Message)" -ForegroundColor DarkGray }
        }
    } catch {
        $failed.Add("$name`n      $($_.Exception.Message)")
        Write-Warning $_.Exception.Message
    }
}

# ================================================================ summary

$lines = [Collections.Generic.List[string]]::new()
$lines.Add("Add-BluRayAudio summary")
$lines.Add("Started:  $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))")
$lines.Add("Finished: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))")
if ($WhatIfPreference) { $lines.Add('Mode:     -WhatIf preview (nothing was written)') }
$lines.Add("Source: $Source")
$lines.Add("Dest:   $Dest")
$lines.Add(("Done: {0}   Planned (dry run): {1}   Skipped: {2}   Failed: {3}" -f
    $done.Count, $planned.Count, $skipped.Count, $failed.Count))

function Add-Section([string]$Title, $Items) {
    if ($Items.Count -eq 0) { return }
    $lines.Add('')
    $lines.Add("$Title ($($Items.Count)):")
    foreach ($item in $Items) { $lines.Add("  $item") }
}
Add-Section 'FAILED' $failed
Add-Section 'Folders skipped: no mirrored MP4s' $skippedDirs
Add-Section 'MKVs without a mirrored MP4 (in otherwise matched folders)' $unmatched
Add-Section 'No lossless audio in the source (best lossy track used)' $noLosslessTitles
Add-Section 'Skipped' $skipped
Add-Section 'Planned (dry run)' $planned
Add-Section 'Done' $done

Write-Host ''
Write-Host ('=' * 70)
foreach ($l in $lines) { Write-Host $l }

try {
    Set-Content -LiteralPath $logPath -Value $lines -Encoding UTF8 -WhatIf:$false
    Write-Host "`nLog saved to $logPath"
} catch {
    Write-Warning "Could not write the log to ${logPath}: $($_.Exception.Message)"
}

if ($failed.Count -gt 0) { exit 1 }
