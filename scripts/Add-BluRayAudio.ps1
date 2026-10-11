<#
.SYNOPSIS
    Rebuilds the audio of encoded MKVs from their Blu-ray source MKVs: a compatible
    default track first, then commentary, then every lossless master. Muxed with
    mkvmerge; new audio is encoded with ffmpeg.

.DESCRIPTION
    Works on one pair of files, or on whole mirrored folder trees.

    Single mode: -Source is the source MKV and -Dest is the encoded video (.mkv, or an
                 older .mp4 to migrate).

    Batch mode:  -Source and -Dest are two different, mirrored folder trees. Every MKV
                 under -Source (recursively) is matched only to the file at the same
                 relative path under -Dest with the same name: "<name>.mkv", or else
                 "<name>.mp4" (an older encode, migrated to MKV by this script):
                   S:\Sources\Shows\Show (2010)\Season 01\Show (2010) S01E05 Episode Title.mkv
                   L:\Library\Shows\Show (2010)\Season 01\Show (2010) S01E05 Episode Title.mkv
                 - A folder whose MKVs have no mirrored file at all is skipped.
                 - In a partly matched folder, the matched pairs are processed and each
                   MKV without a mirrored file is listed with the path that was expected.
                 Everything skipped or failed is listed in the summary at the end.
                 One failed pair doesn't stop the batch.

    Every run (including -WhatIf previews) also saves the summary to a log file on
    your Desktop, named after the start time, e.g.
    "Add-BluRayAudio 2026-10-01 193512.log"

    For each pair:
    1. Checks that the encoded file and the source MKV are the same length (within 2 s).
    2. Masters: every lossless track in the source (TrueHD incl. Atmos, DTS-HD MA incl.
       DTS:X and its built-in DTS core, PCM, FLAC, ALAC, MLP). The source's Default flag
       is ignored. Main track: the master with the most channels (then highest
       bitrate, then first in the list). -SourceTrack overrides it (single mode only).
    3. Default (compatibility) track, chosen from the main track:
         - TrueHD 5.1 or more: its AC-3 core, copied (448 kbps or more). The core is
           the AC-3 with the same disc stream ID (the SOURCE_ID tag), or else the
           AC-3 right after the TrueHD. No core, or one under 448 kbps, is an ERROR:
           the source MKV is probably missing tracks.
         - Other masters of 5.1 or more (DTS-HD MA, PCM...): an existing 5.1 AC-3 that
           the comparison (step 4) shows is the same mix, copied. Otherwise a new
           AC-3 5.1 (-Ac3Bitrate).
         - Stereo or mono masters: an existing lossy track with the same channel count
           (not DTS) that is the same mix, copied. Otherwise a new AAC (-AacBitrate).
         - No lossless track at all: the best lossy track (listed in its own summary
           section). AC-3, E-AC-3 or AAC is copied as-is; anything else (e.g. lossy
           DTS) is converted (AC-3 5.1 or AAC) and the original is kept as a master.
    4. Comparison: each lossy track that could be a copy or a commentary is compared
       with the main track in 5 clips of up to 60 s (at 15-75% of the runtime). Both
       are mixed to mono and their loudness is measured 10 times a second. Two shares
       are counted: moments where the track is clearly LOUDER than the main track
       predicts (someone talking over the film), and moments where it is clearly
       QUIETER (something missing, e.g. an isolated score). Then:
         - louder 15%+ in at least 4 of the 5 clips -> commentary (kept automatically,
           if stereo or mono). A commentator talks through the whole film; a different
           mix, like an original theatrical stereo mix, only differs in some scenes.
         - louder 3%+ in some clip, but quieter under 10% -> narration / audio
           description (dropped): the film plus a narrator, nothing removed.
         - louder and quieter both under 3% -> same mix as the main track (usable as
           the default track).
         - anything else -> a different mix (dropped).
       Every compared track is listed in the summary with its result. The cutoffs and
       clip settings are at the top of the script, for tuning.
    5. Output track order: default track, then commentary (flagged as commentary),
       then every master (main one first). Everything else is dropped. PCM, FLAC and
       ALAC masters (channel-based, no Atmos/DTS:X objects) are stored as Opus to save
       space: 96 kbps mono, 192 stereo, 384 for 5.1, 672 for 7.1 ($OpusKbps at the top).
       TrueHD and DTS-HD MA masters are always copied unchanged. Chapters come from the
       source MKV.
       Metadata comes from the file name, using Matroska's tag scheme: bracketed parts
       like " [tmdbid-1234]" are removed and trailing ".tag" parts become " [tag]".
         Episodes: "Show Name (2024) S01E04 Episode Title" -> title "Episode Title", show
                   "Show Name", season 1, episode 4, year 2024.
         Movies:   "Name, Inc. (2001) [tmdbid-12345] - 2160p.imax" -> title
                   "Name, Inc. (2001) - 2160p [imax]", year 2001.
       The file title and the video track name are set to the title.
       If the encoded MKV's audio already matches this plan, the title is skipped.
    Sync: if the encoder moved the video's start time (e.g. the source video starts at
       0.5 s and the encode at 0), or dropped the source's first frames (sources that start
       mid-sequence, found by comparing frame counts), every audio track is shifted by the
       same amount with mkvmerge --sync, so it stays in sync with the picture. After muxing, each audio
       track's start relative to the video must match the source's within 50 ms.
    Duplicate commentary: a lossless track (not the main track) that is the same audio
       as a kept commentary (compared directly, both directions under 10%) is dropped;
       the lossy commentary is kept.
    6. Warns when a kept track's length in the source differs from the video by more
       than 2 s (e.g. a main track that ends early). That's how the disc is.
       Verifies the result: the tracks match the plan, each track is as long as its
       source track, the file is as long as the original, the default track is set and
       Dolby Vision survived (if the encoded video had it).

    The remux is written as "<name>.remux.mkv.partial" and only renamed once it passes
    verification; a failed one stays ".partial" for inspection (Jellyfin ignores it).
    Output without -Replace: "<name>.remux.mkv" next to the original, for review.
    Output with -Replace:    "<name>.mkv" replaced in place (an .mp4 original is
                             deleted after its .mkv replacement is verified).
    Reviewing first: run without -Replace, check the .remux.mkv files, then run again
    with -Replace. A .remux.mkv has already passed full verification, so -Replace only
    gives it a quick check (opens, has audio, same length, Dolby Vision kept) and swaps
    it in, with no source analysis or comparisons. -Force redoes it from scratch.

    Subtitle backup: if the source MKV has subtitle tracks (e.g. PGS), they are all
    copied, unchanged, into one Matroska subtitle file next to the encoded file, as a
    backup for when the source MKVs are deleted. The ".originals" extension keeps
    Jellyfin from showing it as an extra subtitle. It follows the same flow as the
    remux: "<name>.remux.mks.originals" for review without -Replace, then
    "<name>.mks.originals" (moved into place by -Replace, or written directly with
    -Replace). Verified by its track count; existing backups are skipped. This runs
    for every title, even when the audio needs no changes.
    New audio is encoded to temporary files in your local temp folder, which are
    deleted afterwards.

    Requires ffmpeg, ffprobe and mkvmerge (MKVToolNix) on PATH. MKVToolNix installs
    to "C:\Program Files\MKVToolNix", which is not on PATH by default.

.PARAMETER Source
    Required. The source MKV (single mode), or the root folder of the source MKV tree
    (batch mode). Must be the same kind as -Dest: both files or both folders.
    Alias: -SourceFile.
.PARAMETER Dest
    Required. The encoded .mkv or .mp4 (single mode), or the root folder of the mirrored
    encoded tree (batch mode). Must be a different folder from -Source.
    Alias: -VideoFile.
.PARAMETER SourceTrack
    Single mode only. Use this source audio track as the main track (the one the
    default track is made from) instead of auto-detecting it. Doesn't change which
    tracks are masters. Track numbers work as described under -PassthruCommentaries.
    Default: -1 (auto-detect: the master with the most channels, or the best lossy
    track if there is no lossless one).
.PARAMETER PassthruCommentaries
    Single mode only: overrides which commentary tracks are kept for this one file.
    Without this option (the default, and always in batch mode), every stereo or mono
    track the comparison detects as commentary is kept.
      -PassthruCommentaries 2,3
          Keep exactly these source audio tracks as commentary, copied as-is.
      -PassthruCommentaries None
          Keep no commentary for this file (e.g. if the comparison got it wrong).
    TRACK NUMBERS: 0 = the first AUDIO track in the source MKV. Video and subtitle
    tracks are not counted. Use the "Pos" column the script prints (run with -WhatIf).
      - MediaInfo's "Audio #1" is Pos 0 (subtract 1).
      - Don't use MKVToolNix track IDs: those count the video track too.
    Default: automatic (keep every detected commentary).
.PARAMETER PassthruTitles
    Titles for the tracks given as numbers in -PassthruCommentaries, one per track, in
    the same order. Separate them with commas, and use double quotes (needed for names
    with an apostrophe):
      -PassthruCommentaries 2,3 -PassthruTitles "Director's Commentary","Cast Commentary"
    Only works with track numbers (not with None, and not in batch mode).
    Default: "Commentary" for every kept track.
.PARAMETER AacBitrate
    AAC bitrate in kbps for a new default track made from a stereo source.
    Mono sources are capped at 256 (AAC's per-channel limit).
    Allowed: 96-576. Default: 512.
.PARAMETER Ac3Bitrate
    AC-3 (Dolby Digital) bitrate in kbps for a new 5.1 default track.
    Allowed: 384, 448, 512, 576, 640 (640 is AC-3's maximum). Default: 640.
.PARAMETER AudioLanguage
    ISO 639-2 three-letter language tag written on every audio track.
    Default: eng.
.PARAMETER Replace
    Replace each original with its remux once it passes verification ("<name>.mkv";
    an .mp4 original is deleted). Uses an existing "<name>.remux.mkv" from an earlier
    run if there is one (after a quick check, without redoing any analysis); otherwise
    the remux is created first.
    Default: off (writes "<name>.remux.mkv" next to the original).
.PARAMETER Force
    Redo remuxes even if a .remux.mkv exists (overwriting it, also with -Replace), even
    if the encoded MKV's audio already matches the plan, and redo subtitle backups
    even if they exist.
    Default: off.
.PARAMETER WhatIf
    Built-in PowerShell switch. Show the matching, the comparisons and every plan,
    including the exact ffmpeg and mkvmerge commands, without writing anything.

.EXAMPLE
    .\Add-BluRayAudio.ps1 -Source 'S:\Sources\Shows' -Dest 'L:\Library\Shows' -WhatIf
    Previews the whole tree.
.EXAMPLE
    .\Add-BluRayAudio.ps1 -Source 'S:\Sources\Shows' -Dest 'L:\Library\Shows' -Replace
    Processes the whole tree, replacing the encoded files in place.
.EXAMPLE
    .\Add-BluRayAudio.ps1 -Source '.\sources\Movie.mkv' -Dest '.\encodes\Movie.mkv' -PassthruCommentaries 3 -PassthruTitles "Director's Commentary"
    Single pair, keeping the source's 4th audio track (Pos 3) as a titled commentary.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][Alias('SourceFile')][string]$Source,
    [Parameter(Mandatory)][Alias('VideoFile')][string]$Dest,
    [int]$SourceTrack = -1,
    [string[]]$PassthruCommentaries = @(),
    [string[]]$PassthruTitles = @(),
    [ValidateRange(96, 576)][int]$AacBitrate = 512,
    [ValidateSet(384, 448, 512, 576, 640)][int]$Ac3Bitrate = 640,
    [ValidatePattern('^[a-z]{3}$')][string]$AudioLanguage = 'eng',
    [switch]$Replace,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$script:Cmdlet = $PSCmdlet

# ---- Tunables (adjust after testing on your discs) ----
$CommentaryMinPercent = 15    # louder share a clip needs to count toward commentary...
$CommentaryMinClips   = 4     # ...in at least this many clips (a commentator talks throughout)
$NarrationMinPercent  = 3     # louder share at or above (in any clip): narration...
$NarrationMaxQuieter  = 10    # ...if its quieter share stays below this (nothing removed)
$SameMixMaxPercent    = 3     # louder and quieter shares both below this: same mix
$CommentaryCopyMaxPercent = 10  # lossless track vs a kept commentary, both below this: a copy of it
$CoreMinKbps          = 448   # minimum bitrate for a TrueHD's AC-3 core
# Opus bitrates (kbps) for channel-based lossless masters (PCM, FLAC, ALAC), which have no
# object audio to preserve. Xiph's top recommendations x1.5 for headroom (as 128 -> 192
# for stereo). libopus allows at most 256 kbps per channel.
$OpusKbps = @{ 1 = 96; 2 = 192; 6 = 384; 8 = 672 }
$CheckClipCount       = 5     # comparison clips per title, spread over 15-75% of the runtime
$CheckClipSeconds     = 60    # longest clip length

# Note: PowerShell variable names are case-insensitive, so names in the same scope
# differ by more than case. Property shorthand like "ForEach-Object Name" is avoided:
# it honors -WhatIf and then returns nothing ("ForEach-Object { $_.Name }" is used).

# ================================================================ helpers

function Get-Tool([string]$ToolName) {
    $cmd = Get-Command $ToolName -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $cmd) { throw "'$ToolName' was not found on PATH. Install it or add its folder to PATH." }
    return $cmd.Source
}

function Get-Field($Object, [string]$FieldName) {
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$FieldName]
    if ($prop) { return $prop.Value } else { return $null }
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

function Get-FriendlyName([string]$CodecName, [string]$CodecProfile) {
    if ($CodecName -in @('dts', 'truehd') -and $CodecProfile -and $CodecProfile -ne 'unknown' -and $CodecProfile -notmatch '^-?\d+$') {
        return $CodecProfile   # e.g. "DTS-HD MA", "DTS-HD MA + DTS:X", "Dolby TrueHD + Dolby Atmos"
    }
    switch -Regex ($CodecName) {
        '^truehd$' { return 'Dolby TrueHD' }
        '^dts$'    { return 'DTS' }
        '^ac3$'    { return 'Dolby Digital' }
        '^eac3$'   { return 'Dolby Digital Plus' }
        '^flac$'   { return 'FLAC' }
        '^alac$'   { return 'ALAC' }
        '^mlp$'    { return 'Meridian Lossless Packing' }
        '^opus$'   { return 'Opus' }
        '^aac$'    { return 'AAC' }
        '^pcm_'    { return 'PCM' }
    }
    return $CodecName.ToUpper()
}

function Test-Lossless([string]$CodecName, [string]$CodecProfile) {
    if ($CodecName -match '^(truehd|mlp|flac|alac|pcm_.*)$') { return $true }
    if ($CodecName -eq 'dts' -and $CodecProfile -like 'DTS-HD MA*') { return $true }
    return $false
}

function Format-Arg([string]$Arg) {
    if ($Arg -eq '' -or $Arg -match '[\s"]') { return '"' + ($Arg -replace '"', '\"') + '"' }
    return $Arg
}

function Format-Command([string]$Exe, [string[]]$ArgList) {
    return (Format-Arg $Exe) + ' ' + (($ArgList | ForEach-Object { Format-Arg $_ }) -join ' ')
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

# mkvmerge's view of a file's tracks (its track IDs are what mkvmerge options use).
function Get-MkvTracks([string]$File) {
    $json = & $script:mkvmerge -J $File | Out-String
    if ($LASTEXITCODE -ne 0) { throw "mkvmerge couldn't read $File" }
    return @((ConvertFrom-Json $json).tracks)
}

# Length of one stream in seconds: ffprobe's duration, or the DURATION tag muxers and
# mkvmerge write into MKVs (e.g. "00:43:00.586666666"). 0 if unknown.
function Get-StreamSeconds($Stream) {
    $secs = ConvertTo-Number (Get-Field $Stream 'duration')
    if ($secs -gt 0) { return $secs }
    $tags = Get-Field $Stream 'tags'
    foreach ($key in @('DURATION', 'DURATION-eng')) {
        $text = [string](Get-Field $tags $key)
        if ($text -match '^(\d+):(\d{2}):(\d{2}(?:\.\d+)?)$') {
            return [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + (ConvertTo-Number $Matches[3])
        }
    }
    return 0.0
}

# e.g. 2580.5867 -> "0:43:00.587"
function Format-Duration([double]$Seconds) {
    return [TimeSpan]::FromSeconds($Seconds).ToString('h\:mm\:ss\.fff')
}

# Number of frames in a video stream: the NUMBER_OF_FRAMES tag mkvmerge (and others) write
# (instant), else ffprobe counts the packets (reads the whole file, so a few seconds on a
# local disk, longer over the network).
function Get-FrameCount([string]$File, $VideoStream) {
    $tags = Get-Field $VideoStream 'tags'
    foreach ($key in @('NUMBER_OF_FRAMES', 'NUMBER_OF_FRAMES-eng')) {
        $n = ConvertTo-Number (Get-Field $tags $key)
        if ($n -gt 0) { return [long]$n }
    }
    $out = (& $script:ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 $File | Out-String).Trim()
    return [long](ConvertTo-Number $out)
}

# Seconds per frame from "24000/1001"-style rates (0 if unknown).
function Get-FrameSeconds($VideoStream) {
    foreach ($key in @('r_frame_rate', 'avg_frame_rate')) {
        $rate = [string](Get-Field $VideoStream $key)
        if ($rate -match '^(\d+)/(\d+)$' -and [double]$Matches[1] -gt 0) {
            return [double]$Matches[2] / [double]$Matches[1]
        }
    }
    return 0.0
}

function Test-DolbyVision($VideoStream) {
    $sideData = @(Get-Field $VideoStream 'side_data_list')
    return [bool](@($sideData | Where-Object { (Get-Field $_ 'side_data_type') -like 'DOVI*' }).Count)
}

# "codec channels" for each audio stream, e.g. "ac3 6", "truehd 8"; compared with the plan.
function Get-AudioLayout($Streams) {
    return @($Streams | Where-Object { $_.codec_type -eq 'audio' } |
        ForEach-Object { "$($_.codec_name) $([int]$_.channels)" })
}

# One planned output audio track.
#   From:   'source' (copied from the source MKV) or 'encode' (made with ffmpeg)
#   Layout: what ffprobe should report for it afterwards
function New-OutputTrack([string]$From, [int]$SrcPos, [string]$Codec, [int]$Kbps, [int]$Ac,
                         [string]$Title, [string]$Note, [string]$Layout) {
    return [pscustomobject]@{
        From = $From; SrcPos = $SrcPos; Codec = $Codec; Kbps = $Kbps; Ac = $Ac
        Title = $Title; Note = $Note; Layout = $Layout
        IsDefault = $false; IsCommentary = $false; TempFile = ''
    }
}

# e.g. "audio 3: Dolby Digital 2.0, 192 kbps, 'Stereo'"
function Get-TrackDesc($Track) {
    $desc = "audio $($Track.Pos): $($Track.Name) $(Get-ChannelLabel $Track.Channels)"
    if ($Track.BitRate -gt 0) { $desc += ", $([math]::Round($Track.BitRate / 1000)) kbps" }
    if ($Track.Title) { $desc += ", '$($Track.Title)'" }
    return $desc
}

# Opus bitrate for a channel count: the table above, else 64 kbps per channel.
function Get-OpusKbps([int]$Channels) {
    if ($OpusKbps.ContainsKey($Channels)) { return $OpusKbps[$Channels] }
    return [Math]::Min(256 * $Channels, 64 * [Math]::Max(1, $Channels))
}

function New-Result([string]$Status, [string]$Message) {
    return [pscustomobject]@{ Status = $Status; Message = $Message }
}

# Loudness of one audio track over a clip, 10 values per second (dB). The track is mixed
# to mono first, so where the dialogue sits (centre vs left/right) doesn't matter.
# The values go through a tiny temp file in the local Windows temp folder.
function Get-LoudnessCurve([string]$File, [int]$AudioPos, [double]$Start, [double]$Length) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('abr-' + [guid]::NewGuid().ToString('N') + '.f32')
    $inv = [Globalization.CultureInfo]::InvariantCulture
    try {
        & $script:ffmpeg -v error -nostdin -ss $Start.ToString($inv) -t $Length.ToString($inv) -i $File `
            -map "0:a:$AudioPos" -af 'aformat=channel_layouts=mono,aeval=val(0)*val(0),aresample=10:filter_size=256' `
            -f f32le -y $tmp
        if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed measuring audio track $AudioPos" }
        $bytes = [IO.File]::ReadAllBytes($tmp)
        $count = [int][Math]::Floor($bytes.Length / 4)
        $curve = New-Object double[] $count
        for ($i = 0; $i -lt $count; $i++) {
            $power = [double][BitConverter]::ToSingle($bytes, $i * 4)
            if ($power -lt 1e-9) { $power = 1e-9 }
            $curve[$i] = 10 * [Math]::Log10($power)
        }
        return ,$curve
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
}

# Share (%) of moments where $Other is more than 6 dB louder than predicted from $Main
# (a straight-line fit of Other's loudness against Main's). Swap the arguments to count
# moments where Other is quieter than predicted.
function Get-ExtraSoundPercent([double[]]$Main, [double[]]$Other) {
    $count = [Math]::Min($Main.Length, $Other.Length)
    if ($count -lt 10) { return 0.0 }
    $sumM = 0.0; $sumO = 0.0
    for ($i = 0; $i -lt $count; $i++) { $sumM += $Main[$i]; $sumO += $Other[$i] }
    $meanM = $sumM / $count; $meanO = $sumO / $count
    $cov = 0.0; $varM = 0.0
    for ($i = 0; $i -lt $count; $i++) {
        $dm = $Main[$i] - $meanM
        $cov += $dm * ($Other[$i] - $meanO)
        $varM += $dm * $dm
    }
    $slope = 0.0
    if ($varM -gt 0) { $slope = $cov / $varM }
    $offset = $meanO - $slope * $meanM
    $louder = 0
    for ($i = 0; $i -lt $count; $i++) {
        if ($Other[$i] - ($offset + $slope * $Main[$i]) -gt 6) { $louder++ }
    }
    return 100.0 * $louder / $count
}

# Title info from the file name (without extension):
#   "Name, Inc. (2001) [tmdbid-12345] - 2160p.imax"
#     -> movie, Title "Name, Inc. (2001) - 2160p [imax]", Year 2001
#   "Show Name (2024) S01E04 Episode Title"
#     -> episode, Title "Episode Title", Show "Show Name", Season 1, Episode 4, Year 2024
# Bracketed parts like " [tmdbid-1234]" are removed; trailing ".tag" parts become " [tag]".
# A ".tag" counts only if it has no spaces, isn't all digits, and the dot isn't followed
# by a space (so "Name, Inc. (2001)" and "Dr. Name" are safe).
function Get-TitleInfo([string]$BaseName) {
    $text = $BaseName.Trim()
    $tags = [Collections.Generic.List[string]]::new()
    while ($text -match '^(.*\S)\.([^\s.\[\]()]+)$' -and $Matches[2] -notmatch '^\d+$') {
        $tags.Insert(0, $Matches[2])
        $text = $Matches[1]
    }
    $text = $text -replace '\s*\[[^\]]*\]', ''     # drop [tmdbid-...] and other bracketed bits
    $text = $text -replace '\s+-\s*$', ''            # no dangling " -" at the end
    $text = ($text -replace '\s{2,}', ' ').Trim()
    $tagSuffix = ($tags | ForEach-Object { " [$_]" }) -join ''

    $result = [pscustomobject]@{
        Kind = 'Movie'; Title = ''; Show = ''; Season = 0; Episode = 0; EpisodeId = ''; Year = ''
    }
    if ($text -match '^(?<show>.+?)\s+(?<id>S(?<s>\d{1,3})E(?<e>\d{1,4})(?:-?E\d{1,4})*)(?:\s+(?:-\s+)?(?<ep>.*))?$') {
        $show = ($Matches['show'].Trim() -replace '\s*-$', '').Trim()
        $epId = $Matches['id'].ToUpper()
        $seasonNum = [int]$Matches['s']
        $episodeNum = [int]$Matches['e']
        $epName = ([string]$Matches['ep']).Trim()
        if ($show -match '^(.*?)\s*\((\d{4})\)$') {
            $result.Year = $Matches[2]
            $show = $Matches[1].Trim()
        }
        if (-not $epName) { $epName = $epId }
        $result.Kind = 'Episode'
        $result.Title = $epName + $tagSuffix
        $result.Show = $show
        $result.Season = $seasonNum
        $result.Episode = $episodeNum
        $result.EpisodeId = $epId
    } else {
        if ($text -match '\((\d{4})\)') { $result.Year = $Matches[1] }
        $result.Title = $text + $tagSuffix
    }
    return $result
}

function Get-TitleSummary($TitleInfo) {
    $yearText = ''
    if ($TitleInfo.Year) { $yearText = ", $($TitleInfo.Year)" }
    if ($TitleInfo.Kind -eq 'Episode') {
        return "title '$($TitleInfo.Title)' (TV: $($TitleInfo.Show), season $($TitleInfo.Season), episode $($TitleInfo.Episode)$yearText)"
    }
    return "title '$($TitleInfo.Title)' (movie$yearText)"
}

# Matroska's own tag scheme (the MKV counterpart of the MP4 show/season/episode tags):
#   level 70 = the show, 60 = the season, 50 = the episode or movie.
function Get-TagsXml($TitleInfo) {
    function Simple([string]$TagName, [string]$Value) {
        return "<Simple><Name>$TagName</Name><String>$([Security.SecurityElement]::Escape($Value))</String></Simple>"
    }
    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add('<?xml version="1.0" encoding="UTF-8"?>')
    $parts.Add('<Tags>')
    if ($TitleInfo.Kind -eq 'Episode') {
        $showTags = Simple 'TITLE' $TitleInfo.Show
        if ($TitleInfo.Year) { $showTags += Simple 'DATE_RELEASED' $TitleInfo.Year }
        $parts.Add("<Tag><Targets><TargetTypeValue>70</TargetTypeValue></Targets>$showTags</Tag>")
        $parts.Add("<Tag><Targets><TargetTypeValue>60</TargetTypeValue></Targets>$(Simple 'PART_NUMBER' "$($TitleInfo.Season)")</Tag>")
        $parts.Add("<Tag><Targets><TargetTypeValue>50</TargetTypeValue></Targets>$(Simple 'TITLE' $TitleInfo.Title)$(Simple 'PART_NUMBER' "$($TitleInfo.Episode)")</Tag>")
    } else {
        $movieTags = Simple 'TITLE' $TitleInfo.Title
        if ($TitleInfo.Year) { $movieTags += Simple 'DATE_RELEASED' $TitleInfo.Year }
        $parts.Add("<Tag><Targets><TargetTypeValue>50</TargetTypeValue></Targets>$movieTags</Tag>")
    }
    $parts.Add('</Tags>')
    return $parts -join "`n"
}

# Backup of all of a source MKV's subtitle tracks (e.g. PGS), unchanged, in one Matroska
# subtitle file next to the encoded file. The ".originals" extension keeps Jellyfin from
# treating it as an extra subtitle. Same flow as the audio remux:
#   "<name>.remux.mks.originals.partial" while writing,
#   "<name>.remux.mks.originals" once verified (for review, without -Replace),
#   "<name>.mks.originals" final (with -Replace).
function Export-SubtitleBackup([string]$SourceFile, [string]$DestFile) {
    $dir = [IO.Path]::GetDirectoryName($DestFile)
    $base = [IO.Path]::GetFileNameWithoutExtension($DestFile)
    $finalSubs = Join-Path $dir ($base + '.mks.originals')
    $reviewSubs = Join-Path $dir ($base + '.remux.mks.originals')
    $partialSubs = $reviewSubs + '.partial'

    if ((Test-Path -LiteralPath $finalSubs) -and -not $Force) { return '' }
    $srcSubCount = @(Get-MkvTracks $SourceFile | Where-Object { $_.type -eq 'subtitles' }).Count
    if ($srcSubCount -eq 0) { return '' }

    # A verified review copy from an earlier run: leave it, or move it into place.
    if ((Test-Path -LiteralPath $reviewSubs) -and -not $Force) {
        if (-not $Replace) { return '' }
        $gotCount = @(Get-MkvTracks $reviewSubs | Where-Object { $_.type -eq 'subtitles' }).Count
        if ($gotCount -ne $srcSubCount) {
            throw "$([IO.Path]::GetFileName($reviewSubs)) has $gotCount subtitle track(s), the source has $srcSubCount. Use -Force to redo it."
        }
        if (-not $script:Cmdlet.ShouldProcess($finalSubs, 'Move the reviewed subtitle backup into place')) {
            return "reviewed backup would be moved to $([IO.Path]::GetFileName($finalSubs))"
        }
        Move-Item -LiteralPath $reviewSubs -Destination $finalSubs -Force
        return "reviewed backup moved to $([IO.Path]::GetFileName($finalSubs))"
    }

    $target = $reviewSubs
    if ($Replace) { $target = $finalSubs }
    if (-not $script:Cmdlet.ShouldProcess($target, "Back up $srcSubCount subtitle track(s)")) {
        return "would back up $srcSubCount subtitle track(s) to $([IO.Path]::GetFileName($target))"
    }
    & $script:mkvmerge --quiet --output $partialSubs --no-video --no-audio --no-chapters --no-attachments --no-global-tags $SourceFile
    if ($LASTEXITCODE -ge 2) {
        Remove-Item -LiteralPath $partialSubs -Force -ErrorAction SilentlyContinue
        throw "mkvmerge failed backing up subtitles (exit code $LASTEXITCODE)"
    }
    $gotCount = @(Get-MkvTracks $partialSubs | Where-Object { $_.type -eq 'subtitles' }).Count
    if ($gotCount -ne $srcSubCount) {
        throw "Subtitle backup has $gotCount track(s), the source has $srcSubCount. Left for inspection: $partialSubs"
    }
    Move-Item -LiteralPath $partialSubs -Destination $target -Force
    return "backed up $srcSubCount subtitle track(s) to $([IO.Path]::GetFileName($target))"
}

# ================================================================ one pair

function Invoke-AudioRebuild([string]$SourceFile, [string]$DestFile) {

    $dir = [IO.Path]::GetDirectoryName($DestFile)
    $base = [IO.Path]::GetFileNameWithoutExtension($DestFile)
    $destIsMp4 = ([IO.Path]::GetExtension($DestFile) -eq '.mp4')
    $finalFile = Join-Path $dir ($base + '.mkv')
    $outFile = Join-Path $dir ($base + '.remux.mkv')
    $partialFile = $outFile + '.partial'   # written first; renamed to .remux.mkv once verified
    $titleInfo = Get-TitleInfo $base
    $videoTitle = $titleInfo.Title
    $titleDesc = Get-TitleSummary $titleInfo

    if ($destIsMp4 -and (Test-Path -LiteralPath $finalFile)) {
        throw "Both $base.mp4 and $base.mkv exist; remove one of them first."
    }

    # ------------------------------------------------ inspect the encoded file
    $destFormat = Get-Format $DestFile
    $destAll = Get-Streams $DestFile
    $destVideo = @($destAll | Where-Object { $_.codec_type -eq 'video' })
    if ($destVideo.Count -eq 0) { throw "No video stream found in $DestFile" }
    $destHasDv = Test-DolbyVision $destVideo[0]
    $currentLayout = Get-AudioLayout $destAll

    # A .remux.mkv from an earlier run has already passed full verification (it only gets
    # that name afterwards). Without -Replace it's left for review. With -Replace it gets a
    # quick sanity check and is swapped in: no source analysis, no comparisons.
    # -Force skips this and redoes everything.
    if ((Test-Path -LiteralPath $outFile) -and -not $Force) {
        if (-not $Replace) {
            return New-Result 'Skipped' 'a .remux.mkv from an earlier run exists; review it, then run with -Replace to use it (or -Force to redo)'
        }
        $origLen = ConvertTo-Number (Get-Field $destFormat 'duration')
        $rLen = ConvertTo-Number (Get-Field (Get-Format $outFile) 'duration')
        $rStreams = Get-Streams $outFile
        $rVideo = @($rStreams | Where-Object { $_.codec_type -eq 'video' })
        $rLayout = Get-AudioLayout $rStreams
        $quick = [Collections.Generic.List[string]]::new()
        if ($rVideo.Count -eq 0) { $quick.Add('no video') }
        if ($rLayout.Count -eq 0) { $quick.Add('no audio') }
        if ($origLen -gt 0 -and [Math]::Abs($origLen - $rLen) -gt 2) {
            $quick.Add(("it is {0} but the original is {1}" -f (Format-Duration $rLen), (Format-Duration $origLen)))
        }
        if ($destHasDv -and -not ($rVideo.Count -gt 0 -and (Test-DolbyVision $rVideo[0]))) { $quick.Add('Dolby Vision missing') }
        if ($quick.Count -gt 0) {
            throw "The existing .remux.mkv failed its quick check ($($quick -join '; ')). Use -Force to redo it."
        }
        $rWhat = 'replaced with the reviewed .remux.mkv'
        if ($destIsMp4) { $rWhat += ' (MP4 migrated to MKV)' }
        Write-Host "Reviewed remux found: $outFile (audio: $($rLayout -join ', '))"
        if (-not $script:Cmdlet.ShouldProcess($DestFile, 'Replace with the reviewed .remux.mkv')) {
            return New-Result 'Planned' "$rWhat; audio: $($rLayout -join ', ')"
        }
        Move-Item -LiteralPath $outFile -Destination $finalFile -Force
        if ($destIsMp4) { Remove-Item -LiteralPath $DestFile -Force }
        Write-Host '  Original replaced.' -ForegroundColor Green
        return New-Result 'Done' "$rWhat; audio: $($rLayout -join ', ')"
    }

    # ------------------------------------------------ check the pair
    $srcFormat = Get-Format $SourceFile
    $vLen = ConvertTo-Number (Get-Field $destFormat 'duration')
    $sLen = ConvertTo-Number (Get-Field $srcFormat 'duration')
    if ($vLen -gt 0 -and $sLen -gt 0 -and [Math]::Abs($vLen - $sLen) -gt 2) {
        throw ("Length mismatch: encoded file is {0}, source MKV is {1}. Is this the right pair?" -f (Format-Duration $vLen), (Format-Duration $sLen))
    }

    $srcStreams = Get-Streams $SourceFile
    $srcVideo = @($srcStreams | Where-Object { $_.codec_type -eq 'video' })

    # ---- sync: where the video starts in the source vs in the encoded file
    # Source audio is in sync with the SOURCE video. If the encoder moved the video's start
    # (e.g. the source video starts at 0.5 s and the encode restarts it at 0), every audio
    # track has to move by the same amount: shift = encoded video start - source video start.
    # Some sources start mid-sequence (leading frames that can't be decoded); an encoder may
    # drop those, so the encode's first frame is a LATER source frame. That time is added:
    # source time of the encode's first frame = source video start + dropped x frame length.
    $srcVideoStart = 0.0
    if ($srcVideo.Count -gt 0) { $srcVideoStart = ConvertTo-Number (Get-Field $srcVideo[0] 'start_time') }
    $destVideoStart = ConvertTo-Number (Get-Field $destVideo[0] 'start_time')
    $droppedFrames = 0
    $droppedSecs = 0.0
    if ($srcVideo.Count -gt 0) {
        $srcFrames = Get-FrameCount $SourceFile $srcVideo[0]
        $destFrames = Get-FrameCount $DestFile $destVideo[0]
        $frameSecs = Get-FrameSeconds $srcVideo[0]
        if ($srcFrames -gt 0 -and $destFrames -gt 0) {
            $droppedFrames = [int]($srcFrames - $destFrames)
            if ($droppedFrames -gt 240) {
                throw "The encode has $droppedFrames fewer video frames than the source ($destFrames vs $srcFrames); can't tell where they went, so the audio can't be synced safely."
            } elseif ($droppedFrames -lt 0) {
                Write-Warning "The encode has $(-$droppedFrames) MORE video frames than the source ($destFrames vs $srcFrames); not adjusting for it. Check sync by ear."
                $droppedFrames = 0
            } elseif ($droppedFrames -gt 0) {
                $droppedSecs = $droppedFrames * $frameSecs
            }
        }
    }
    # Where the encode's first frame was in the source's timeline.
    $srcVideoRef = $srcVideoStart + $droppedSecs
    $syncMs = [int][Math]::Round(($destVideoStart - $srcVideoRef) * 1000)
    if ([Math]::Abs($syncMs) -lt 10) { $syncMs = 0 }
    if ($syncMs -ne 0) {
        $script:SubShiftNote = "shift its .srt subtitles by $syncMs ms (encode is missing $droppedFrames frame(s); video start $([Math]::Round($srcVideoStart, 3))s -> $([Math]::Round($destVideoStart, 3))s)"
    }

    if ($srcVideo.Count -gt 0 -and (Test-DolbyVision $srcVideo[0]) -and -not $destHasDv) {
        Write-Warning 'The source has Dolby Vision but the encoded video does not. The output will be HDR10/SDR only.'
    }

    # mkvmerge track IDs (its options refer to tracks by these).
    $destMkvVideo = @(Get-MkvTracks $DestFile | Where-Object { $_.type -eq 'video' })
    if ($destMkvVideo.Count -eq 0) { throw "mkvmerge sees no video track in $DestFile" }
    $srcMkvAudioIds = @(Get-MkvTracks $SourceFile | Where-Object { $_.type -eq 'audio' } | ForEach-Object { $_.id })

    # ------------------------------------------------ inspect source audio
    $srcAudio = @($srcStreams | Where-Object { $_.codec_type -eq 'audio' })
    if ($srcAudio.Count -eq 0) { throw "No audio tracks found in $SourceFile" }
    if ($srcMkvAudioIds.Count -ne $srcAudio.Count) {
        throw "ffprobe sees $($srcAudio.Count) audio tracks but mkvmerge sees $($srcMkvAudioIds.Count); refusing to guess the mapping."
    }

    $audio = @(for ($i = 0; $i -lt $srcAudio.Count; $i++) {
        $st = $srcAudio[$i]
        $codecName = [string]$st.codec_name
        $codecProfile = [string](Get-Field $st 'profile')
        $tags = Get-Field $st 'tags'
        $bitrate = ConvertTo-Number (Get-Field $st 'bit_rate')
        if ($bitrate -le 0) { $bitrate = ConvertTo-Number (Get-Field $tags 'BPS') }
        if ($bitrate -le 0) { $bitrate = ConvertTo-Number (Get-Field $tags 'BPS-eng') }
        $sourceId = [string](Get-Field $tags 'SOURCE_ID')
        if (-not $sourceId) { $sourceId = [string](Get-Field $tags 'SOURCE_ID-eng') }

        [pscustomobject]@{
            Pos      = $i
            MkvId    = $srcMkvAudioIds[$i]
            Codec    = $codecName
            Name     = Get-FriendlyName $codecName $codecProfile
            Channels = [int](ConvertTo-Number (Get-Field $st 'channels'))
            BitRate  = $bitrate
            Lossless = Test-Lossless $codecName $codecProfile
            Title    = [string](Get-Field $tags 'title')
            Seconds  = Get-StreamSeconds $st
            Start    = ConvertTo-Number (Get-Field $st 'start_time')
            SourceId = $sourceId
        }
    })

    Write-Host 'Audio tracks in source:'
    $audio | Format-Table -AutoSize Pos, Name,
        @{ n = 'Ch';   e = { Get-ChannelLabel $_.Channels } },
        @{ n = 'kbps'; e = { if ($_.BitRate -gt 0) { [math]::Round($_.BitRate / 1000) } else { '?' } } },
        Lossless, Title | Out-Host

    # ------------------------------------------------ masters and the main track
    # Masters = every lossless track (a DTS-HD MA track keeps its DTS core inside it).
    $masters = @($audio | Where-Object { $_.Lossless })

    # Best track = most channels, then highest bitrate, then first in the list.
    function Select-BestTrack($Tracks) {
        $best = $null
        foreach ($t in $Tracks) {
            if (-not $best -or $t.Channels -gt $best.Channels -or
                ($t.Channels -eq $best.Channels -and $t.BitRate -gt $best.BitRate)) { $best = $t }
        }
        return $best
    }

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

    # ------------------------------------------------ comparison with the main track
    $isTrueHdMain = ($pick.Lossless -and $pick.Codec -eq 'truehd' -and $pick.Channels -ge 6)
    $toCompare = @($audio | Where-Object {
        -not $_.Lossless -and $_.Pos -ne $pick.Pos -and (
            $_.Channels -le 2 -or
            ($_.Codec -eq 'ac3' -and $_.Channels -eq 6 -and $pick.Lossless -and -not $isTrueHdMain -and $pick.Channels -ge 6))
    })

    $runtime = $sLen
    if ($runtime -le 0) { $runtime = $vLen }
    $clipLen = [Math]::Min($CheckClipSeconds, [Math]::Floor($runtime * 0.1))
    if ($clipLen -lt 10) { $clipLen = [Math]::Max(1, [Math]::Floor($runtime / 2)) }
    $starts = @(for ($c = 0; $c -lt $CheckClipCount; $c++) {
        $runtime * (0.15 + 0.6 * $c / [Math]::Max(1, $CheckClipCount - 1))
    })

    $verdicts = @{}   # source position -> verdict
    if ($toCompare.Count -gt 0) {
        Write-Host ("Comparing {0} track(s) with the main track, {1} x {2:N0}s clips..." -f
            $toCompare.Count, $starts.Count, $clipLen)

        $mainCurves = [Collections.Generic.List[object]]::new()
        foreach ($st0 in $starts) { $mainCurves.Add((Get-LoudnessCurve $SourceFile $pick.Pos $st0 $clipLen)) }

        foreach ($cand in $toCompare) {
            $louder = [Collections.Generic.List[double]]::new()
            $quieter = [Collections.Generic.List[double]]::new()
            for ($c = 0; $c -lt $starts.Count; $c++) {
                $curve = Get-LoudnessCurve $SourceFile $cand.Pos $starts[$c] $clipLen
                $louder.Add((Get-ExtraSoundPercent $mainCurves[$c] $curve))
                $quieter.Add((Get-ExtraSoundPercent $curve $mainCurves[$c]))
            }
            $topLouder = ($louder | Measure-Object -Maximum).Maximum
            $topQuieter = ($quieter | Measure-Object -Maximum).Maximum
            # Commentary talks through the whole film: high in (nearly) every clip. A different
            # mix (e.g. an original theatrical stereo mix) only differs in some scenes.
            $clipsOver = @($louder | Where-Object { $_ -ge $CommentaryMinPercent }).Count
            $needClips = [Math]::Min($CommentaryMinClips, $starts.Count)
            $kind = 'different mix'
            if ($clipsOver -ge $needClips) { $kind = 'commentary' }
            elseif ($topLouder -ge $NarrationMinPercent -and $topQuieter -lt $NarrationMaxQuieter) { $kind = 'narration' }
            elseif ($topLouder -lt $SameMixMaxPercent -and $topQuieter -lt $SameMixMaxPercent) { $kind = 'same mix' }
            $verdicts[$cand.Pos] = [pscustomobject]@{
                Kind = $kind; Louder = $topLouder; Quieter = $topQuieter
                ClipsOver = "$clipsOver/$($starts.Count)"
                Clips = (($louder | ForEach-Object { '{0:N1}' -f $_ }) -join ' / ')
            }
            Write-Host ("  {0} -> {1} (louder {2:N1}%, quieter {3:N1}%; louder per clip {4}; {5} clips at {6}%+)" -f
                (Get-TrackDesc $cand), $kind, $topLouder, $topQuieter, $verdicts[$cand.Pos].Clips,
                $verdicts[$cand.Pos].ClipsOver, $CommentaryMinPercent)
        }
    }

    # Highest-bitrate track among $Tracks that the comparison found to be the same mix.
    function Select-SameMix($Tracks) {
        $best = $null
        foreach ($t in $Tracks) {
            if (-not $verdicts.ContainsKey($t.Pos) -or $verdicts[$t.Pos].Kind -ne 'same mix') { continue }
            if (-not $best -or $t.BitRate -gt $best.BitRate) { $best = $t }
        }
        return $best
    }

    # ------------------------------------------------ default (compatibility) track
    $copyable = $pick.Codec -in @('ac3', 'eac3', 'aac')
    $compat = $null

    if ($masters.Count -eq 0 -and $copyable) {
        $compat = New-OutputTrack 'source' $pick.Pos 'copy' 0 0 $srcLabel 'copied as-is (no lossless track)' "$($pick.Codec) $($pick.Channels)"
    } elseif ($isTrueHdMain) {
        $core = @($audio | Where-Object {
            $_.Codec -eq 'ac3' -and $_.Pos -ne $pick.Pos -and $pick.SourceId -and $_.SourceId -eq $pick.SourceId }) |
            Select-Object -First 1
        $how = 'same disc stream ID'
        if (-not $core -and ($pick.Pos + 1) -lt $audio.Count -and $audio[$pick.Pos + 1].Codec -eq 'ac3') {
            $core = $audio[$pick.Pos + 1]
            $how = 'the AC-3 right after the TrueHD'
        }
        if (-not $core) {
            throw "The TrueHD master (audio $($pick.Pos)) has no AC-3 core track. The source MKV is probably missing tracks."
        }
        if ($core.BitRate -gt 0 -and $core.BitRate -lt $CoreMinKbps * 1000) {
            throw ("The TrueHD's AC-3 core (audio {0}) is {1} kbps, below {2}. The source MKV is probably missing tracks." -f
                $core.Pos, [math]::Round($core.BitRate / 1000), $CoreMinKbps)
        }
        $compat = New-OutputTrack 'source' $core.Pos 'copy' 0 0 "$($core.Name) $(Get-ChannelLabel $core.Channels)" `
            "audio $($core.Pos): the TrueHD's AC-3 core ($how), copied" "ac3 $($core.Channels)"
    } elseif ($pick.Lossless -and $pick.Channels -ge 6) {
        $same = Select-SameMix @($audio | Where-Object { $_.Codec -eq 'ac3' -and $_.Channels -eq 6 })
        if ($same) {
            $compat = New-OutputTrack 'source' $same.Pos 'copy' 0 0 "$($same.Name) $(Get-ChannelLabel $same.Channels)" `
                "audio $($same.Pos): existing AC-3, same mix as the main track, copied" "ac3 6"
        }
    } elseif ($pick.Lossless -and $pick.Channels -le 2) {
        $same = Select-SameMix @($audio | Where-Object {
            -not $_.Lossless -and $_.Codec -ne 'dts' -and $_.Channels -eq $pick.Channels })
        if ($same) {
            $compat = New-OutputTrack 'source' $same.Pos 'copy' 0 0 "$($same.Name) $(Get-ChannelLabel $same.Channels)" `
                "audio $($same.Pos): existing $($same.Name), same mix as the main track, copied" "$($same.Codec) $($same.Channels)"
        }
    }

    if (-not $compat) {
        if ($pick.Channels -le 2) {
            $kbps = $AacBitrate
            if ($pick.Channels -eq 1) { $kbps = [Math]::Min($AacBitrate, 256) }
            $compat = New-OutputTrack 'encode' $pick.Pos 'aac' $kbps 0 "AAC $(Get-ChannelLabel $pick.Channels)" `
                "new, encoded from $srcLabel at $kbps kbps" "aac $($pick.Channels)"
        } else {
            $ac = 0
            if ($pick.Channels -gt 6) { $ac = 6 }
            $outCh = [Math]::Min($pick.Channels, 6)
            $compat = New-OutputTrack 'encode' $pick.Pos 'ac3' $Ac3Bitrate $ac "Dolby Digital $(Get-ChannelLabel $outCh)" `
                "new, encoded from $srcLabel at $Ac3Bitrate kbps" "ac3 $outCh"
        }
    }
    $compat.IsDefault = $true

    # Kept as masters: every lossless track, main one first. With no lossless track, a
    # main track that had to be converted (e.g. lossy DTS) is kept as-is instead.
    $keep = @($masters | Where-Object { $_.Pos -eq $pick.Pos }) + @($masters | Where-Object { $_.Pos -ne $pick.Pos })
    if ($masters.Count -eq 0 -and $compat.From -eq 'encode') { $keep = @($pick) }
    $keepPos = @($keep | ForEach-Object { $_.Pos })

    # ------------------------------------------------ commentary tracks to keep
    # Default: every detected stereo/mono commentary. Overrides (single mode): numbers, or None.
    $passTracks = [Collections.Generic.List[object]]::new()
    $passTitles = [Collections.Generic.List[string]]::new()
    if ($script:PassMode -eq 'List') {
        for ($k = 0; $k -lt $script:PassList.Count; $k++) {
            $pp = $script:PassList[$k]
            if ($pp -lt 0 -or $pp -ge $audio.Count) {
                throw "-PassthruCommentaries: there is no audio track $pp. Valid: 0-$($audio.Count - 1) (the 'Pos' column above)."
            }
            if ($pp -in $keepPos) { throw "-PassthruCommentaries: audio track $pp is already kept as a master." }
            if ($pp -eq $compat.SrcPos -or $pp -eq $pick.Pos) { throw "-PassthruCommentaries: audio track $pp is the main or default track." }
            $passTracks.Add($audio[$pp])
            if ($PassthruTitles.Count -gt 0) { $passTitles.Add($PassthruTitles[$k]) } else { $passTitles.Add('Commentary') }
        }
    } elseif ($script:PassMode -eq 'Auto') {
        foreach ($cand in $toCompare) {
            if ($cand.Channels -le 2 -and $verdicts[$cand.Pos].Kind -eq 'commentary' -and $cand.Pos -ne $compat.SrcPos) {
                $passTracks.Add($cand)
                $passTitles.Add('Commentary')
            }
        }
    }
    $passPos = @($passTracks | ForEach-Object { $_.Pos })

    # ------------------------------------------------ lossless copies of a kept commentary
    # Some discs carry the commentary twice: lossy and lossless. A lossless track (not the
    # main track) with the same channel count is compared DIRECTLY with each kept
    # commentary; if both directions are under the same-mix cutoff it's the same audio,
    # so the lossless copy is dropped and the lossy commentary is kept as before.
    $dupLines = [Collections.Generic.List[string]]::new()
    $dupDropped = @()
    foreach ($pt in $passTracks) {
        $twins = @($keep | Where-Object {
            $_.Lossless -and $_.Pos -ne $pick.Pos -and $_.Channels -eq $pt.Channels -and $_.Pos -notin $dupDropped })
        if ($twins.Count -eq 0) { continue }
        $ptCurves = @(foreach ($st0 in $starts) { ,(Get-LoudnessCurve $SourceFile $pt.Pos $st0 $clipLen) })
        foreach ($tw in $twins) {
            $maxL = 0.0; $maxQ = 0.0
            for ($c = 0; $c -lt $starts.Count; $c++) {
                $twCurve = Get-LoudnessCurve $SourceFile $tw.Pos $starts[$c] $clipLen
                $maxL = [Math]::Max($maxL, (Get-ExtraSoundPercent $ptCurves[$c] $twCurve))
                $maxQ = [Math]::Max($maxQ, (Get-ExtraSoundPercent $twCurve $ptCurves[$c]))
            }
            $isDup = ($maxL -lt $CommentaryCopyMaxPercent -and $maxQ -lt $CommentaryCopyMaxPercent)
            $fate = 'different audio, kept as a master'
            if ($isDup) { $fate = 'lossless copy of the commentary, dropped'; $dupDropped += $tw.Pos }
            $line = ("{0} vs commentary audio {1}: louder {2:N1}%, quieter {3:N1}% -> {4}" -f
                (Get-TrackDesc $tw), $pt.Pos, $maxL, $maxQ, $fate)
            Write-Host "  $line"
            $dupLines.Add($line)
        }
    }
    if ($dupDropped.Count -gt 0) {
        $keep = @($keep | Where-Object { $_.Pos -notin $dupDropped })
        $keepPos = @($keep | ForEach-Object { $_.Pos })
    }

    # ------------------------------------------------ plan the output audio
    $outputs = [Collections.Generic.List[object]]::new()
    $outputs.Add($compat)
    for ($k = 0; $k -lt $passTracks.Count; $k++) {
        $pt = $passTracks[$k]
        $track = New-OutputTrack 'source' $pt.Pos 'copy' 0 0 $passTitles[$k] `
            "audio $($pt.Pos): commentary, copied ($($pt.Name) $(Get-ChannelLabel $pt.Channels))" "$($pt.Codec) $($pt.Channels)"
        $track.IsCommentary = $true
        $outputs.Add($track)
    }
    foreach ($m in $keep) {
        if ($m.Codec -match '^(pcm_.*|flac|alac)$') {
            # Channel-based lossless (no Atmos/DTS:X objects to keep for a future format):
            # stored as high-bitrate Opus to save space.
            $ok = Get-OpusKbps $m.Channels
            $outputs.Add((New-OutputTrack 'encode' $m.Pos 'libopus' $ok 0 "Opus $(Get-ChannelLabel $m.Channels)" `
                "audio $($m.Pos): $($m.Name) encoded to Opus at $ok kbps" "opus $($m.Channels)"))
        } else {
            $note = "audio $($m.Pos): copied"
            if (-not $m.Lossless) { $note = "audio $($m.Pos): copied (original lossy track; the default track is a converted copy)" }
            $outputs.Add((New-OutputTrack 'source' $m.Pos 'copy' 0 0 "$($m.Name) $(Get-ChannelLabel $m.Channels)" $note "$($m.Codec) $($m.Channels)"))
        }
    }
    $plannedLayout = @($outputs | ForEach-Object { $_.Layout })
    $usedPos = @($outputs | ForEach-Object { $_.SrcPos })

    # e.g. "Dolby Digital 5.1 (from DTS-HD MA 5.1), Commentary, DTS-HD MA 5.1"
    $trackLabel = (@($outputs | ForEach-Object {
        if ($_.From -eq 'encode' -and $_.SrcPos -eq $pick.Pos) { "$($_.Title) (from $srcLabel)" } else { $_.Title }
    })) -join ', '

    # Comparison report: one line per compared track, with what happens to it.
    $keptWord = 'kept'
    if ($WhatIfPreference) { $keptWord = 'would be kept' }
    $reportLines = [Collections.Generic.List[string]]::new()
    foreach ($cand in $toCompare) {
        $v = $verdicts[$cand.Pos]
        $fate = 'dropped'
        if ($cand.Pos -eq $compat.SrcPos -and $compat.From -eq 'source') { $fate = "used as the default track" }
        elseif ($cand.Pos -in $passPos) { $fate = "$keptWord as commentary" }
        $reportLines.Add(("{0} -> {1} (louder {2:N1}%, quieter {3:N1}%, louder per clip {4}) -> {5}" -f
            (Get-TrackDesc $cand), $v.Kind, $v.Louder, $v.Quieter, $v.Clips, $fate))
    }
    if ($script:PassMode -eq 'List') {
        foreach ($pt in $passTracks) {
            if (-not $verdicts.ContainsKey($pt.Pos)) {
                $reportLines.Add("$(Get-TrackDesc $pt) -> chosen with -PassthruCommentaries -> $keptWord as commentary")
            }
        }
    }
    foreach ($dl in $dupLines) { $reportLines.Add($dl) }
    $script:StereoReport = $reportLines -join "`n      "

    # ------------------------------------------------ source length check (warning only)
    $srcVideoLen = 0.0
    if ($srcVideo.Count -gt 0) { $srcVideoLen = Get-StreamSeconds $srcVideo[0] }
    $lengthLines = [Collections.Generic.List[string]]::new()
    if ($srcVideoLen -gt 0) {
        foreach ($srcPos in @($usedPos | Select-Object -Unique)) {
            $srcTrack = $audio[$srcPos]
            if ($srcTrack.Seconds -le 0) { continue }
            $diff = $srcTrack.Seconds - $srcVideoLen
            if ([Math]::Abs($diff) -le 2) { continue }
            $how = 'ends {0:N1} s before the video'
            if ($diff -gt 0) { $how = 'runs {0:N1} s past the video' }
            $lengthLines.Add(("audio {0} ({1} {2}) is {3}, video is {4}: {5}" -f $srcPos, $srcTrack.Name,
                (Get-ChannelLabel $srcTrack.Channels), (Format-Duration $srcTrack.Seconds),
                (Format-Duration $srcVideoLen), ($how -f [Math]::Abs($diff))))
        }
    }
    if ($lengthLines.Count -gt 0) {
        foreach ($l in $lengthLines) { Write-Warning "Source length: $l" }
        $script:LengthReport = $lengthLines -join "`n      "
    }

    # ------------------------------------------------ already done?
    if (-not $Force -and -not $destIsMp4 -and (($currentLayout -join '|') -eq ($plannedLayout -join '|'))) {
        return New-Result 'Skipped' "already has the planned audio ($trackLabel)"
    }

    # ------------------------------------------------ build the commands
    $tempDir = [IO.Path]::GetTempPath()
    $encodeCmds = [Collections.Generic.List[object]]::new()
    foreach ($o in $outputs) {
        if ($o.From -ne 'encode') { continue }
        $o.TempFile = Join-Path $tempDir ('abr-' + [guid]::NewGuid().ToString('N') + '.mka')
        # -copyts keeps the source track's start time, so a track that starts late stays in sync.
        $enc = [Collections.Generic.List[string]]::new()
        $enc.AddRange([string[]]@('-hide_banner', '-v', 'warning', '-stats', '-nostdin', '-copyts',
            '-i', $SourceFile, '-map', "0:a:$($o.SrcPos)", '-map_metadata', '-1', '-map_chapters', '-1',
            '-c:a', $o.Codec))
        if ($o.Kbps -gt 0) { $enc.AddRange([string[]]@('-b:a', "$($o.Kbps)k")) }
        if ($o.Ac -gt 0) { $enc.AddRange([string[]]@('-ac', "$($o.Ac)")) }
        $enc.AddRange([string[]]@('-f', 'matroska', '-y', $o.TempFile))
        $encodeCmds.Add($enc.ToArray())
    }

    # mkvmerge inputs: file 0 = encoded video, file 1 = source MKV (copied audio + chapters),
    # files 2+ = the temp encodes. --track-order puts everything in the planned order.
    $vid = $destMkvVideo[0].id
    $mk = [Collections.Generic.List[string]]::new()
    $tagsFile = Join-Path $tempDir ('abr-' + [guid]::NewGuid().ToString('N') + '.xml')
    $mk.AddRange([string[]]@('--output', $partialFile, '--title', $videoTitle, '--global-tags', $tagsFile))
    $mk.AddRange([string[]]@('--video-tracks', "$vid", '--no-audio', '--no-subtitles', '--no-chapters',
        '--no-global-tags', '--no-attachments', '--track-name', "${vid}:$videoTitle", $DestFile))

    $srcIds = @($outputs | Where-Object { $_.From -eq 'source' } | ForEach-Object { $audio[$_.SrcPos].MkvId })
    $mk.AddRange([string[]]@('--no-video', '--no-subtitles', '--no-global-tags', '--no-attachments'))
    if ($srcIds.Count -gt 0) { $mk.AddRange([string[]]@('--audio-tracks', ($srcIds -join ','))) } else { $mk.Add('--no-audio') }
    $order = [Collections.Generic.List[string]]::new()
    $order.Add("0:$vid")
    $fileNo = 2
    $trackOpts = @{}   # output index -> "file:track" for --track-order
    for ($i = 0; $i -lt $outputs.Count; $i++) {
        $o = $outputs[$i]
        if ($o.From -ne 'source') { continue }
        $tid = $audio[$o.SrcPos].MkvId
        $mk.AddRange([string[]]@('--language', "${tid}:$AudioLanguage", '--track-name', "${tid}:$($o.Title)",
            '--default-track-flag', "${tid}:$(if ($o.IsDefault) { 'yes' } else { 'no' })"))
        if ($o.IsCommentary) { $mk.AddRange([string[]]@('--commentary-flag', "${tid}:yes")) }
        if ($syncMs -ne 0) { $mk.AddRange([string[]]@('--sync', "${tid}:$syncMs")) }
        $trackOpts[$i] = "1:$tid"
    }
    $mk.Add($SourceFile)
    for ($i = 0; $i -lt $outputs.Count; $i++) {
        $o = $outputs[$i]
        if ($o.From -ne 'encode') { continue }
        $mk.AddRange([string[]]@('--no-chapters', '--no-global-tags', '--language', "0:$AudioLanguage",
            '--track-name', "0:$($o.Title)", '--default-track-flag', "0:$(if ($o.IsDefault) { 'yes' } else { 'no' })"))
        if ($syncMs -ne 0) { $mk.AddRange([string[]]@('--sync', "0:$syncMs")) }
        $mk.Add($o.TempFile)
        $trackOpts[$i] = "${fileNo}:0"
        $fileNo++
    }
    for ($i = 0; $i -lt $outputs.Count; $i++) { $order.Add($trackOpts[$i]) }
    $mk.AddRange([string[]]@('--track-order', ($order -join ',')))

    # ------------------------------------------------ report
    Write-Host "Metadata: $titleDesc"
    if ($droppedFrames -gt 0) {
        Write-Host ("Sync: the encode is missing the source's first {0} video frame(s) ({1:N3}s), dropped by the encoder" -f
            $droppedFrames, $droppedSecs) -ForegroundColor Yellow
    }
    if ($syncMs -ne 0) {
        Write-Host ("Sync: encode's first frame is at {0:N3}s in the source's timeline and {1:N3}s in the encode; shifting all audio by {2} ms" -f
            $srcVideoRef, $destVideoStart, $syncMs) -ForegroundColor Yellow
    } else {
        Write-Host ("Sync: video starts at {0:N3}s in both; no shift needed" -f $destVideoStart)
    }
    if ($currentLayout.Count -gt 0) {
        Write-Host "Encoded file's audio now: $($currentLayout -join ', ')  (will be replaced)"
    } else {
        Write-Host "Encoded file's audio now: none"
    }
    Write-Host 'Planned audio:'
    for ($i = 0; $i -lt $outputs.Count; $i++) {
        $o = $outputs[$i]
        $flag = ''
        if ($o.IsDefault) { $flag = '  [default]' }
        if ($o.IsCommentary) { $flag = '  [commentary]' }
        Write-Host ("  a:{0}  {1,-40} {2}{3}" -f $i, $o.Title, $o.Note, $flag)
    }
    foreach ($d in @($audio | Where-Object { $_.Pos -notin $usedPos })) {
        Write-Host "  dropped: $(Get-TrackDesc $d)" -ForegroundColor DarkGray
    }
    if ($Replace) {
        if ($destIsMp4) { Write-Host "Replaces: $DestFile  (with $finalFile)" } else { Write-Host "Replaces: $DestFile" }
    } else {
        Write-Host "Output:   $outFile"
    }
    Write-Host ''

    foreach ($enc in $encodeCmds) { Write-Host (Format-Command $script:ffmpeg $enc) -ForegroundColor Cyan }
    Write-Host (Format-Command $script:mkvmerge $mk.ToArray()) -ForegroundColor Cyan
    Write-Host ''
    $action = 'Rebuild audio with ffmpeg and mkvmerge'
    $what = 'remux'
    if ($destIsMp4) { $what += ' (MP4 migrated to MKV)' }

    if (-not $script:Cmdlet.ShouldProcess($DestFile, $action)) {
        if ($syncMs -ne 0) { $what += " (audio shifted $syncMs ms; $droppedFrames dropped frame(s))" }
        return New-Result 'Planned' "${what}: $trackLabel; $titleDesc"
    }

    # ------------------------------------------------ run
    $mkWarnings = $false
    try {
        [IO.File]::WriteAllText($tagsFile, (Get-TagsXml $titleInfo), [Text.UTF8Encoding]::new($false))
        foreach ($enc in $encodeCmds) {
            & $script:ffmpeg @enc
            if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed with exit code $LASTEXITCODE" }
        }
        $mkArgs = $mk.ToArray()
        & $script:mkvmerge @mkArgs
        if ($LASTEXITCODE -ge 2) { throw "mkvmerge failed with exit code $LASTEXITCODE" }
        if ($LASTEXITCODE -eq 1) { $mkWarnings = $true }
    } finally {
        Remove-Item -LiteralPath $tagsFile -Force -ErrorAction SilentlyContinue
        foreach ($o in $outputs) {
            if ($o.TempFile) { Remove-Item -LiteralPath $o.TempFile -Force -ErrorAction SilentlyContinue }
        }
    }

    # ------------------------------------------------ verify
    $problems = [Collections.Generic.List[string]]::new()
    $notes = [Collections.Generic.List[string]]::new()
    if ($mkWarnings) { $notes.Add('mkvmerge reported warnings (see above)') }
    $outStreams = Get-Streams $partialFile
    $outVideo = @($outStreams | Where-Object { $_.codec_type -eq 'video' })
    $outAudio = @($outStreams | Where-Object { $_.codec_type -eq 'audio' })
    $outLayout = Get-AudioLayout $outStreams

    Write-Host "`nResult:"
    if ($outVideo.Count -gt 0) {
        $gotTitle = [string](Get-Field (Get-Field $outVideo[0] 'tags') 'title')
        Write-Host "  video track name: $gotTitle"
        if ($gotTitle -ne $videoTitle) { $notes.Add("video track name is '$gotTitle', expected '$videoTitle'") }
    }
    for ($i = 0; $i -lt $outAudio.Count; $i++) {
        $st = $outAudio[$i]
        $disp = Get-Field $st 'disposition'
        $gotName = [string](Get-Field (Get-Field $st 'tags') 'title')
        Write-Host ("  audio: {0,-7} {1,-4} default={2} commentary={3}  {4}" -f $st.codec_name,
            (Get-ChannelLabel ([int]$st.channels)), (Get-Field $disp 'default'), (Get-Field $disp 'comment'), $gotName)
        if ($i -lt $outputs.Count -and $gotName -ne $outputs[$i].Title) {
            $notes.Add("a:$i is named '$gotName', expected '$($outputs[$i].Title)'")
        }
    }
    if (($outLayout -join '|') -ne ($plannedLayout -join '|')) {
        $problems.Add("audio tracks are [$($outLayout -join ', ')], expected [$($plannedLayout -join ', ')]")
    }
    if ($outAudio.Count -gt 0 -and (ConvertTo-Number (Get-Field (Get-Field $outAudio[0] 'disposition') 'default')) -ne 1) {
        $problems.Add('a:0 is not flagged as the default track')
    }

    # Whole file compared with the original: catches a remux that was cut short.
    $oLen = ConvertTo-Number (Get-Field (Get-Format $partialFile) 'duration')
    if ($vLen -gt 0 -and [Math]::Abs($vLen - $oLen) -gt 2) {
        $problems.Add(("the remux is {0} but the original is {1}" -f (Format-Duration $oLen), (Format-Duration $vLen)))
    }
    # Sync: each audio track's start relative to the video must match the source's.
    $outVideoStart = 0.0
    if ($outVideo.Count -gt 0) { $outVideoStart = ConvertTo-Number (Get-Field $outVideo[0] 'start_time') }
    $syncBad = $false
    for ($i = 0; $i -lt [Math]::Min($outAudio.Count, $outputs.Count); $i++) {
        $srcTrack = $audio[$outputs[$i].SrcPos]
        $wantRel = $srcTrack.Start - $srcVideoRef
        $gotRel = (ConvertTo-Number (Get-Field $outAudio[$i] 'start_time')) - $outVideoStart
        $offMs = [int][Math]::Round(($gotRel - $wantRel) * 1000)
        # Audio shifted to before the file's 0 gets its start cut off, so it starts at ~0
        # whether or not it was shifted. Then the track's END is checked instead: the end
        # can't be cut, so it moves by exactly the shift.
        if (($wantRel + $outVideoStart) -lt 0 -and ($gotRel + $outVideoStart) -le 0.05) {
            $gotLenSync = Get-StreamSeconds $outAudio[$i]
            if ($gotLenSync -gt 0 -and $srcTrack.Seconds -gt 0) {
                $wantEnd = $wantRel + $srcTrack.Seconds
                $gotEnd = $gotRel + $gotLenSync
                $offMs = [int][Math]::Round(($gotEnd - $wantEnd) * 1000)
            } else {
                $offMs = 0
                $notes.Add("a:$i starts before the video, and its length is unknown, so its sync couldn't be verified")
            }
        }
        if ([Math]::Abs($offMs) -gt 50) {
            $problems.Add(("a:{0} ({1}) is out of sync by {2} ms (starts {3:N3}s after the video, source: {4:N3}s)" -f
                $i, $outputs[$i].Title, $offMs, $gotRel, $wantRel))
            $syncBad = $true
        }
    }
    if (-not $syncBad) { Write-Host '  sync: every audio track starts where it does in the source (within 50 ms)' -ForegroundColor Green }

    # Each audio track compared with its OWN source track (some discs have audio that
    # legitimately ends a few seconds before the picture).
    for ($i = 0; $i -lt [Math]::Min($outAudio.Count, $outputs.Count); $i++) {
        $gotLen = Get-StreamSeconds $outAudio[$i]
        $srcTrack = $audio[$outputs[$i].SrcPos]
        $cutSecs = [Math]::Max(0, -(($srcTrack.Start - $srcVideoRef) + $outVideoStart))
        if ($gotLen -gt 0 -and $srcTrack.Seconds -gt 0 -and [Math]::Abs($gotLen - ($srcTrack.Seconds - $cutSecs)) -gt 2) {
            $problems.Add(("a:{0} ({1}) is {2} but its source track (audio {3}) is {4}" -f
                $i, $outputs[$i].Title, (Format-Duration $gotLen), $outputs[$i].SrcPos, (Format-Duration $srcTrack.Seconds)))
        }
    }

    $outHasDv = ($outVideo.Count -gt 0) -and (Test-DolbyVision $outVideo[0])
    if ($outHasDv) {
        Write-Host '  Dolby Vision configuration record: present' -ForegroundColor Green
    } elseif ($destHasDv) {
        $problems.Add('the encoded video had Dolby Vision, but the output does not')
    } else {
        Write-Host '  Dolby Vision: none (not in the encoded video)'
    }

    foreach ($noteText in $notes) { Write-Warning $noteText }
    if ($problems.Count -gt 0) {
        throw "Verification failed ($($problems -join '; ')). Output left for inspection: $partialFile"
    }

    # ------------------------------------------------ replace the original
    if (-not $Replace) {
        Move-Item -LiteralPath $partialFile -Destination $outFile -Force
        Write-Host "  Verified; saved as $([IO.Path]::GetFileName($outFile)) for review." -ForegroundColor Green
    } else {
        Move-Item -LiteralPath $partialFile -Destination $finalFile -Force
        if ($destIsMp4) {
            Remove-Item -LiteralPath $DestFile -Force
            Write-Host "  Replaced: $([IO.Path]::GetFileName($finalFile)) written, old MP4 deleted." -ForegroundColor Green
        } else {
            Write-Host '  Original replaced.' -ForegroundColor Green
        }
    }

    if ($syncMs -ne 0) { $what += " (audio shifted $syncMs ms; $droppedFrames dropped frame(s))" }
    $msg = "${what}: $trackLabel; $titleDesc"
    if ($notes.Count -gt 0) { $msg += "; NOTE: $($notes -join '; ')" }
    return New-Result 'Done' $msg
}

# ================================================================ main

$startTime = Get-Date
$logPath = Join-Path ([Environment]::GetFolderPath('Desktop')) `
    ('Add-BluRayAudio {0:yyyy-MM-dd HHmmss}.log' -f $startTime)

$script:ffmpeg = Get-Tool 'ffmpeg'
$script:ffprobe = Get-Tool 'ffprobe'
$script:mkvmerge = Get-Tool 'mkvmerge'

if (-not (Test-Path -LiteralPath $Source)) { throw "Source not found: $Source" }
if (-not (Test-Path -LiteralPath $Dest)) { throw "Dest not found: $Dest" }
$Source = (Resolve-Path -LiteralPath $Source).ProviderPath
$Dest = (Resolve-Path -LiteralPath $Dest).ProviderPath
$batch = Test-Path -LiteralPath $Source -PathType Container
if ($batch -ne (Test-Path -LiteralPath $Dest -PathType Container)) {
    throw '-Source and -Dest must both be files, or both be folders.'
}
if ($Source.TrimEnd('\', '/') -eq $Dest.TrimEnd('\', '/')) {
    throw '-Source and -Dest must be different (both hold .mkv files with the same names).'
}

$pairs            = [Collections.Generic.List[object]]::new()
$done             = [Collections.Generic.List[string]]::new()
$planned          = [Collections.Generic.List[string]]::new()
$skipped          = [Collections.Generic.List[string]]::new()
$failed           = [Collections.Generic.List[string]]::new()
$skippedDirs      = [Collections.Generic.List[string]]::new()
$unmatched        = [Collections.Generic.List[string]]::new()
$noLosslessTitles = [Collections.Generic.List[string]]::new()
$stereoChecks     = [Collections.Generic.List[string]]::new()
$lengthChecks     = [Collections.Generic.List[string]]::new()
$subBackups       = [Collections.Generic.List[string]]::new()
$subShifts        = [Collections.Generic.List[string]]::new()


# -PassthruCommentaries: not given = Auto (keep detected commentary); "None"; or track
# numbers ("2,3" may also arrive as one string). The overrides are single mode only.
$script:PassMode = 'Auto'
$script:PassList = @()
if ($PassthruCommentaries.Count -eq 1 -and $PassthruCommentaries[0] -eq 'Auto') {
    $script:PassMode = 'Auto'
} elseif ($PassthruCommentaries.Count -eq 1 -and $PassthruCommentaries[0] -eq 'None') {
    $script:PassMode = 'None'
} elseif ($PassthruCommentaries.Count -gt 0) {
    $script:PassMode = 'List'
    foreach ($entry in $PassthruCommentaries) {
        foreach ($part in ($entry -split ',')) {
            if (-not $part.Trim()) { continue }
            $num = 0
            if (-not [int]::TryParse($part.Trim(), [ref]$num)) {
                throw "-PassthruCommentaries: '$part' isn't a track number. Use numbers like 2,3, or None."
            }
            if ($num -in $script:PassList) { continue }
            $script:PassList += $num
        }
    }
}
if ($PassthruTitles.Count -gt 0) {
    if ($script:PassList.Count -eq 0) {
        throw '-PassthruTitles only works with track numbers in -PassthruCommentaries.'
    }
    if ($PassthruTitles.Count -ne $script:PassList.Count) {
        throw "-PassthruTitles has $($PassthruTitles.Count) title(s) but -PassthruCommentaries has $($script:PassList.Count) track(s); they must match 1:1."
    }
}

if (-not $batch) {
    if ([IO.Path]::GetExtension($Dest) -notin @('.mkv', '.mp4')) { throw '-Dest must be an .mkv or .mp4 file.' }
    $pairs.Add([pscustomobject]@{ Source = $Source; Video = $Dest })
} else {
    if ($SourceTrack -ge 0) { throw '-SourceTrack only works with single files.' }
    if ($script:PassMode -ne 'Auto') {
        throw '-PassthruCommentaries only works with single files. Folders always keep detected commentary automatically.'
    }

    $srcRoot = $Source.TrimEnd('\', '/')
    $dstRoot = $Dest.TrimEnd('\', '/')

    # Each source MKV maps to one encoded file: same relative folder under Dest, same base
    # name, as .mkv (or else .mp4, an older encode to migrate).
    $mkvs = @(Get-ChildItem -LiteralPath $srcRoot -Recurse -File |
        Where-Object { $_.Extension -eq '.mkv' -and $_.Name -notlike '*.remux.mkv' })
    foreach ($group in ($mkvs | Group-Object DirectoryName | Sort-Object Name)) {
        $relDir = $group.Name.Substring($srcRoot.Length).TrimStart('\', '/')
        $mirrorDir = $dstRoot
        if ($relDir) { $mirrorDir = Join-Path $dstRoot $relDir }

        $matched = [Collections.Generic.List[object]]::new()
        $missing = [Collections.Generic.List[string]]::new()
        foreach ($mkv in ($group.Group | Sort-Object Name)) {
            $target = $null
            foreach ($ext in @('.mkv', '.mp4')) {
                $candidate = Join-Path $mirrorDir ($mkv.BaseName + $ext)
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $target = $candidate; break }
            }
            if ($target) {
                $matched.Add([pscustomobject]@{ Source = $mkv.FullName; Video = $target })
            } else {
                $missing.Add("$($mkv.FullName)`n      expected: $(Join-Path $mirrorDir ($mkv.BaseName + '.mkv'))")
            }
        }

        if ($matched.Count -eq 0) {
            $why = 'mirrored folder exists, but none of the file names match'
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
        $script:StereoReport = ''
        $script:LengthReport = ''
        $script:SubShiftNote = ''
        $r = Invoke-AudioRebuild $p.Source $p.Video
        if ($script:FlagNoLossless) { $noLosslessTitles.Add("$name  ($($r.Status): $($r.Message))") }
        if ($script:StereoReport) { $stereoChecks.Add("$name`n      $($script:StereoReport)") }
        if ($script:LengthReport) { $lengthChecks.Add("$name`n      $($script:LengthReport)") }
        if ($script:SubShiftNote) { $subShifts.Add("$name`n      $($script:SubShiftNote)") }
        switch ($r.Status) {
            'Done'    { $done.Add("$name  ($($r.Message))") }
            'Planned' { $planned.Add("$name  ($($r.Message))") }
            'Skipped' { $skipped.Add("$name  ($($r.Message))"); Write-Host "Skipped: $($r.Message)" -ForegroundColor DarkGray }
        }
    } catch {
        $failed.Add("$name`n      $($_.Exception.Message)")
        Write-Warning $_.Exception.Message
    }
    try {
        $subMsg = Export-SubtitleBackup $p.Source $p.Video
        if ($subMsg) { $subBackups.Add("$name  ($subMsg)"); Write-Host "Subtitles: $subMsg" }
    } catch {
        $failed.Add("$name (subtitle backup)`n      $($_.Exception.Message)")
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
Add-Section 'SUBTITLES TO FIX: audio was shifted to match the encode, so OCR''d subtitles from the source need the same shift' $subShifts
Add-Section 'Folders skipped: no mirrored encoded files' $skippedDirs
Add-Section 'MKVs without a mirrored encoded file (in otherwise matched folders)' $unmatched
Add-Section 'No lossless audio in the source (best lossy track used)' $noLosslessTitles
Add-Section 'Track comparison (lossy tracks vs the main track)' $stereoChecks
Add-Section 'Audio and video lengths differ in the source by more than 2 s (check playback)' $lengthChecks
Add-Section 'Subtitle backups' $subBackups
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
