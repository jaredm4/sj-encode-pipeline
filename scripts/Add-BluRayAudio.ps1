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
                 - MP4s already processed by this script are skipped (-Force redoes them).
                 Everything skipped or failed is listed in the summary at the end, and in
                 -LogFile if given. One failed pair doesn't stop the batch.

    For each pair:
    1. Checks that the MP4 and MKV are the same length (within 2 s), to catch mismatched
       pairs before doing any work.
    2. Picks the source audio track: the one flagged Default (first one if several),
       else the first lossless track, else the first track. -SourceTrack overrides this
       (single mode only).
    3. Stereo or mono source: encoded to AAC (-AacBitrate). Nothing else is kept.
       (An AAC source is copied instead of re-encoded.)
    4. Surround source:
         - Already AC-3: copied as the only audio track.
         - Anything else: a new AC-3 5.1 track (-Ac3Bitrate) is encoded from it and
           becomes the MP4's audio. The source itself (the master) is written to an
           external .mka with the same base name as the MP4, which Jellyfin (10.8+) picks
           up as an extra audio track. PCM is converted to FLAC (still lossless). With
           -EmbedMaster the master goes into the MP4 as a second track instead.
    5. All other source audio tracks are dropped. Chapters come from the MKV; the video
       is copied from the MP4 untouched.
    6. Verifies the result: track counts, the .mka, Dolby Vision (if the MP4 had it) and
       that audio and video lengths match. With -Replace, the original MP4 is only
       replaced after these checks pass.

    Output without -Replace: "<name>.muxed.mp4" (and "<name>.muxed.mka") next to the MP4.
    Output with -Replace:    the MP4 is replaced in place and the master saved as
                             "<name>.mka" next to it. If you rename an MP4 later, rename
                             its .mka to match, or Jellyfin won't find it.

.PARAMETER Source
    The source MKV, or a folder to search recursively for MKVs. (Alias: -SourceFile)
.PARAMETER Dest
    The encoded MP4, or a folder to search recursively for MP4s. (Alias: -VideoFile)
.PARAMETER OutputFile
    Single mode only, without -Replace: a custom output path (must end in .mp4).
.PARAMETER SourceTrack
    Single mode only: use this source audio track (0-based, as in ffmpeg's 1:a:N).
.PARAMETER AacBitrate
    AAC bitrate in kbps for stereo sources (mono sources are capped at 256).
.PARAMETER Ac3Bitrate
    AC-3 bitrate in kbps for surround sources.
.PARAMETER AudioLanguage
    ISO 639-2 language tag written on every audio track. Default 'eng'.
.PARAMETER EmbedMaster
    Put the lossless master inside the MP4 as a second audio track instead of an
    external .mka. (TrueHD in MP4 isn't readable by some players, e.g. VLC.)
.PARAMETER Replace
    Replace each original MP4 with the result once it passes verification.
.PARAMETER LogFile
    Also write the end-of-run summary to this file (written even with -WhatIf).
.PARAMETER Force
    Overwrite leftover outputs from earlier runs, and reprocess MP4s already marked as
    processed by this script.

.EXAMPLE
    .\Add-BluRayAudio.ps1 -Source 'S:\Sources\Shows' -Dest 'L:\Library\Shows' -WhatIf -LogFile .\plan.log
    Shows the matching and every plan without writing anything.
.EXAMPLE
    .\Add-BluRayAudio.ps1 -Source 'S:\Sources\Shows' -Dest 'L:\Library\Shows' -Replace -LogFile .\audio.log
    Processes the whole tree, replacing MP4s in place.
.EXAMPLE
    .\Add-BluRayAudio.ps1 -Source '.\S01E01.mkv' -Dest '.\S01E01.mp4'
    Single pair, writing S01E01.muxed.mp4 (and .mka) next to the MP4.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][Alias('SourceFile')][string]$Source,
    [Parameter(Mandatory)][Alias('VideoFile')][string]$Dest,
    [string]$OutputFile,
    [int]$SourceTrack = -1,
    [ValidateRange(96, 576)][int]$AacBitrate = 512,
    [ValidateSet(384, 448, 512, 576, 640)][int]$Ac3Bitrate = 640,
    [ValidatePattern('^[a-z]{3}$')][string]$AudioLanguage = 'eng',
    [switch]$EmbedMaster,
    [switch]$Replace,
    [string]$LogFile,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$script:Cmdlet = $PSCmdlet
$MarkerComment = 'Audio rebuilt by Add-BluRayAudio'

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

function Get-FriendlyName([string]$Codec, [string]$Profile) {
    if ($Codec -in @('dts', 'truehd') -and $Profile -and $Profile -ne 'unknown' -and $Profile -notmatch '^-?\d+$') {
        return $Profile   # e.g. "DTS-HD MA", "DTS-HD MA + DTS:X", "Dolby TrueHD + Dolby Atmos"
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

function Test-Lossless([string]$Codec, [string]$Profile) {
    if ($Codec -match '^(truehd|mlp|flac|alac|pcm_.*)$') { return $true }
    if ($Codec -eq 'dts' -and $Profile -like 'DTS-HD MA*') { return $true }
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

# ================================================================ one pair

function Invoke-AudioRebuild([string]$SourceFile, [string]$VideoFile, [string]$OutFile) {

    # ------------------------------------------------ already done?
    $videoFormat = Get-Format $VideoFile
    if (-not $Force -and (Get-Field (Get-Field $videoFormat 'tags') 'comment') -eq $MarkerComment) {
        return New-Result 'Skipped' 'already processed (use -Force to redo)'
    }

    # ------------------------------------------------ output paths
    $dir = [IO.Path]::GetDirectoryName($VideoFile)
    $base = [IO.Path]::GetFileNameWithoutExtension($VideoFile)
    $finalMka = $null
    if ($Replace -or -not $OutFile) { $OutFile = Join-Path $dir ($base + '.muxed.mp4') }
    if ($Replace) { $finalMka = Join-Path $dir ($base + '.mka') }
    $OutFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
    if ([IO.Path]::GetExtension($OutFile) -ne '.mp4') { throw 'The output file must end in .mp4' }
    $extFile = [IO.Path]::ChangeExtension($OutFile, '.mka')

    if ($OutFile -in @($VideoFile, $SourceFile)) { throw 'The output file must be different from the input files.' }
    if (-not $Force) {
        foreach ($f in @($OutFile, $extFile)) {
            if (Test-Path -LiteralPath $f) {
                return New-Result 'Skipped' "output already exists: $([IO.Path]::GetFileName($f)) (use -Force to overwrite)"
            }
        }
    }

    # ------------------------------------------------ inspect video
    $videoStreams = @(Get-Streams $VideoFile | Where-Object { $_.codec_type -eq 'video' })
    if ($videoStreams.Count -eq 0) { throw "No video stream found in $VideoFile" }
    $videoCodec = [string]$videoStreams[0].codec_name
    $videoHasDv = Test-DolbyVision $videoStreams[0]

    $srcFormat = Get-Format $SourceFile
    $vLen = ConvertTo-Number (Get-Field $videoFormat 'duration')
    $sLen = ConvertTo-Number (Get-Field $srcFormat 'duration')
    if ($vLen -gt 0 -and $sLen -gt 0 -and [Math]::Abs($vLen - $sLen) -gt 2) {
        throw ("Length mismatch: MP4 is {0:N0}s, MKV is {1:N0}s. Is this the right pair?" -f $vLen, $sLen)
    }

    $srcStreams = Get-Streams $SourceFile
    $srcVideo = @($srcStreams | Where-Object { $_.codec_type -eq 'video' })
    $sourceHasDv = ($srcVideo.Count -gt 0) -and (Test-DolbyVision $srcVideo[0])
    if ($sourceHasDv -and -not $videoHasDv) {
        Write-Warning 'The source has Dolby Vision but the encoded video does not. The output will be HDR10 only.'
    }

    # ------------------------------------------------ inspect audio
    $srcAudio = @($srcStreams | Where-Object { $_.codec_type -eq 'audio' })
    if ($srcAudio.Count -eq 0) { throw "No audio tracks found in $SourceFile" }

    $audio = @(for ($i = 0; $i -lt $srcAudio.Count; $i++) {
        $s = $srcAudio[$i]
        $codec = [string]$s.codec_name
        $profile = [string](Get-Field $s 'profile')
        $tags = Get-Field $s 'tags'
        $bitrate = ConvertTo-Number (Get-Field $s 'bit_rate')
        if ($bitrate -le 0) { $bitrate = ConvertTo-Number (Get-Field $tags 'BPS') }
        if ($bitrate -le 0) { $bitrate = ConvertTo-Number (Get-Field $tags 'BPS-eng') }

        [pscustomobject]@{
            Pos      = $i
            Codec    = $codec
            Name     = Get-FriendlyName $codec $profile
            Channels = [int](ConvertTo-Number (Get-Field $s 'channels'))
            BitRate  = $bitrate
            Default  = ((ConvertTo-Number (Get-Field (Get-Field $s 'disposition') 'default')) -eq 1)
            Lossless = Test-Lossless $codec $profile
            Title    = [string](Get-Field $tags 'title')
        }
    })

    Write-Host 'Audio tracks in source:'
    $audio | Format-Table -AutoSize Pos, Name,
        @{ n = 'Ch';   e = { Get-ChannelLabel $_.Channels } },
        @{ n = 'kbps'; e = { if ($_.BitRate -gt 0) { [math]::Round($_.BitRate / 1000) } else { '?' } } },
        Default, Lossless, Title | Out-Host

    # ------------------------------------------------ choose source track
    $defaults = @($audio | Where-Object Default)
    if ($SourceTrack -ge 0) {
        if ($SourceTrack -ge $audio.Count) { throw "There is no audio track $SourceTrack (0-$($audio.Count - 1))." }
        $pick = $audio[$SourceTrack]
        $why = 'chosen with -SourceTrack'
    } elseif ($defaults.Count -gt 0) {
        $pick = $defaults[0]
        $why = 'flagged Default'
        if ($defaults.Count -gt 1) {
            Write-Warning "Several audio tracks are flagged Default ($(($defaults | ForEach-Object Pos) -join ', ')); using the first."
        }
    } else {
        $pick = @($audio | Where-Object Lossless) | Select-Object -First 1
        $why = 'first lossless track (none flagged Default)'
        if (-not $pick) {
            $pick = $audio[0]
            $why = 'first track (none flagged Default, none lossless)'
        }
    }

    # ------------------------------------------------ plan output tracks
    $outputs = [Collections.Generic.List[object]]::new()
    $external = $null
    $srcLabel = "$($pick.Name) $(Get-ChannelLabel $pick.Channels)"

    if ($pick.Channels -le 2) {
        if ($pick.Codec -eq 'aac') {
            $outputs.Add((New-OutputTrack $pick.Pos 'copy' 0 0 "AAC $(Get-ChannelLabel $pick.Channels)" 'copied (already AAC)'))
        } else {
            $kbps = $AacBitrate
            if ($pick.Channels -eq 1) { $kbps = [Math]::Min($AacBitrate, 256) }
            $outputs.Add((New-OutputTrack $pick.Pos 'aac' $kbps 0 "AAC $(Get-ChannelLabel $pick.Channels)" "encoded from $srcLabel at $kbps kbps"))
        }
    } elseif ($pick.Codec -eq 'ac3') {
        $outputs.Add((New-OutputTrack $pick.Pos 'copy' 0 0 $srcLabel 'copied (already AC-3)'))
    } else {
        $ac = 0
        if ($pick.Channels -gt 6) { $ac = 6 }
        $outputs.Add((New-OutputTrack $pick.Pos 'ac3' $Ac3Bitrate $ac "Dolby Digital $(Get-ChannelLabel ([Math]::Min($pick.Channels, 6)))" "encoded from $srcLabel at $Ac3Bitrate kbps"))
        if ($pick.Codec -like 'pcm_*') {
            $master = New-OutputTrack $pick.Pos 'flac' 0 0 "FLAC $(Get-ChannelLabel $pick.Channels)" 'PCM converted to FLAC (lossless)'
        } else {
            $master = New-OutputTrack $pick.Pos 'copy' 0 0 $srcLabel 'copied'
        }
        if ($EmbedMaster) { $outputs.Add($master) } else { $external = $master }
    }

    $mkaAfter = $extFile
    if ($Replace) { $mkaAfter = $finalMka }
    if (-not $external -and (Test-Path -LiteralPath $mkaAfter)) {
        Write-Warning "$([IO.Path]::GetFileName($mkaAfter)) exists but this title has no external master; Jellyfin would still show it as an audio track."
    }

    # ------------------------------------------------ build ffmpeg command
    $ffArgs = [Collections.Generic.List[string]]::new()
    $ffArgs.AddRange([string[]]@('-hide_banner', '-i', $VideoFile, '-i', $SourceFile, '-map', '0:v:0'))
    foreach ($o in $outputs) { $ffArgs.AddRange([string[]]@('-map', "1:a:$($o.SrcPos)")) }
    $ffArgs.AddRange([string[]]@('-map_chapters', '1', '-c:v', 'copy'))
    if ($videoCodec -eq 'hevc') { $ffArgs.AddRange([string[]]@('-tag:v', 'hvc1')) }

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

    $ffArgs.AddRange([string[]]@('-metadata', "comment=$MarkerComment",
        '-strict', 'experimental', '-movflags', '+faststart'))
    if ($Force) { $ffArgs.Add('-y') } else { $ffArgs.Add('-n') }
    $ffArgs.Add($OutFile)

    if ($external) {
        # Second output in the same pass: the master alone in a Matroska audio file.
        $ffArgs.AddRange([string[]]@(
            '-map', "1:a:$($external.SrcPos)", '-map_metadata', '-1', '-map_chapters', '-1',
            '-c:a', $external.Codec, '-disposition:a:0', '0',
            '-metadata:s:a:0', "language=$AudioLanguage", '-metadata:s:a:0', "title=$($external.Title)",
            $extFile))
    }

    # ------------------------------------------------ report and run
    Write-Host "Source track: audio $($pick.Pos) - $srcLabel ($why)"
    Write-Host 'Planned output audio:'
    for ($i = 0; $i -lt $outputs.Count; $i++) {
        $o = $outputs[$i]
        $flag = ''
        if ($i -eq 0) { $flag = '  [default]' }
        Write-Host ("  a:{0}  {1,-40} {2}{3}" -f $i, $o.Title, $o.Note, $flag)
    }
    if ($external) { Write-Host ("  .mka {0,-40} {1}" -f $external.Title, $external.Note) }
    foreach ($d in @($audio | Where-Object { $_.Pos -ne $pick.Pos })) {
        Write-Host "  dropped: audio $($d.Pos) - $($d.Name) $(Get-ChannelLabel $d.Channels)" -ForegroundColor DarkGray
    }
    if ($Replace) {
        Write-Host "Replaces: $VideoFile"
        if ($external) { Write-Host "Master:   $finalMka" }
    } else {
        Write-Host "Output:   $OutFile"
        if ($external) { Write-Host "          $extFile" }
    }
    Write-Host ''

    $argArray = $ffArgs.ToArray()
    Write-Host ((Format-Arg $script:ffmpeg) + ' ' + (($argArray | ForEach-Object { Format-Arg $_ }) -join ' ')) -ForegroundColor Cyan
    Write-Host ''

    if (-not $script:Cmdlet.ShouldProcess($VideoFile, 'Rebuild audio with ffmpeg')) {
        return New-Result 'Planned' $srcLabel
    }

    & $script:ffmpeg @argArray
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed with exit code $LASTEXITCODE" }

    # ------------------------------------------------ verify
    $problems = [Collections.Generic.List[string]]::new()
    $outStreams = Get-Streams $OutFile
    $outVideo = @($outStreams | Where-Object { $_.codec_type -eq 'video' })
    $outAudio = @($outStreams | Where-Object { $_.codec_type -eq 'audio' })

    Write-Host "`nResult:"
    foreach ($s in $outAudio) {
        Write-Host ("  audio: {0,-7} {1,-4} default={2}  {3}" -f $s.codec_name,
            (Get-ChannelLabel ([int]$s.channels)), (Get-Field (Get-Field $s 'disposition') 'default'),
            (Get-Field (Get-Field $s 'tags') 'title'))
    }
    if ($outAudio.Count -ne $outputs.Count) {
        $problems.Add("expected $($outputs.Count) audio track(s) in the MP4, found $($outAudio.Count)")
    }

    if ($outVideo.Count -gt 0 -and $outAudio.Count -gt 0) {
        $vDur = ConvertTo-Number (Get-Field $outVideo[0] 'duration')
        $aDur = ConvertTo-Number (Get-Field $outAudio[0] 'duration')
        if ($vDur -gt 0 -and $aDur -gt 0 -and [Math]::Abs($vDur - $aDur) -gt 2) {
            $problems.Add(("audio is {0:N0}s but video is {1:N0}s" -f $aDur, $vDur))
        }
    }

    if ($external) {
        if (Test-Path -LiteralPath $extFile) {
            $extAudio = @(Get-Streams $extFile | Where-Object { $_.codec_type -eq 'audio' })
            foreach ($s in $extAudio) {
                Write-Host ("  .mka:  {0,-7} {1,-4} {2}" -f $s.codec_name,
                    (Get-ChannelLabel ([int]$s.channels)), (Get-Field (Get-Field $s 'tags') 'title'))
            }
            if ($extAudio.Count -ne 1) { $problems.Add("expected 1 audio track in the .mka, found $($extAudio.Count)") }
        } else {
            $problems.Add('the external .mka was not created')
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

    if ($problems.Count -gt 0) {
        throw "Verification failed ($($problems -join '; ')). Output left for inspection: $OutFile"
    }

    # ------------------------------------------------ replace original
    if ($Replace) {
        Move-Item -LiteralPath $OutFile -Destination $VideoFile -Force
        if ($external) { Move-Item -LiteralPath $extFile -Destination $finalMka -Force }
        Write-Host '  Original MP4 replaced.' -ForegroundColor Green
    }

    return New-Result 'Done' $srcLabel
}

# ================================================================ main

$script:ffmpeg = Get-Tool 'ffmpeg'
$script:ffprobe = Get-Tool 'ffprobe'

if (-not (Test-Path -LiteralPath $Source)) { throw "Source not found: $Source" }
if (-not (Test-Path -LiteralPath $Dest)) { throw "Dest not found: $Dest" }
$Source = (Resolve-Path -LiteralPath $Source).ProviderPath
$Dest = (Resolve-Path -LiteralPath $Dest).ProviderPath
$batch = Test-Path -LiteralPath $Source -PathType Container
if ($batch -ne (Test-Path -LiteralPath $Dest -PathType Container)) {
    throw '-Source and -Dest must both be files, or both be folders.'
}
if ($Replace -and $OutputFile) { throw '-OutputFile cannot be combined with -Replace.' }

$pairs       = [Collections.Generic.List[object]]::new()
$done        = [Collections.Generic.List[string]]::new()
$planned     = [Collections.Generic.List[string]]::new()
$skipped     = [Collections.Generic.List[string]]::new()
$failed      = [Collections.Generic.List[string]]::new()
$skippedDirs = [Collections.Generic.List[string]]::new()
$unmatched   = [Collections.Generic.List[string]]::new()

if (-not $batch) {
    $pairs.Add([pscustomobject]@{ Source = $Source; Video = $Dest })
} else {
    if ($OutputFile) { throw '-OutputFile only works with single files.' }
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
    Write-Host ("`n==== [{0}/{1}] {2}" -f ($n + 1), $pairs.Count, $p.Video) -ForegroundColor Yellow
    Write-Host "     from $($p.Source)"
    try {
        $out = ''
        if (-not $batch) { $out = $OutputFile }
        $r = Invoke-AudioRebuild $p.Source $p.Video $out
        switch ($r.Status) {
            'Done'    { $done.Add("$($p.Video)  ($($r.Message))") }
            'Planned' { $planned.Add("$($p.Video)  ($($r.Message))") }
            'Skipped' { $skipped.Add("$($p.Video)  ($($r.Message))"); Write-Host "Skipped: $($r.Message)" -ForegroundColor DarkGray }
        }
    } catch {
        $failed.Add("$($p.Video)`n      $($_.Exception.Message)")
        Write-Warning $_.Exception.Message
    }
}

# ================================================================ summary

$lines = [Collections.Generic.List[string]]::new()
$lines.Add("Add-BluRayAudio summary  $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
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
Add-Section 'Skipped' $skipped
Add-Section 'Planned (dry run)' $planned
Add-Section 'Done' $done

Write-Host ''
Write-Host ('=' * 70)
foreach ($l in $lines) { Write-Host $l }

if ($LogFile) {
    Set-Content -LiteralPath $LogFile -Value $lines -Encoding UTF8 -WhatIf:$false
    Write-Host "`nSummary written to $LogFile"
}

if ($failed.Count -gt 0) { exit 1 }
