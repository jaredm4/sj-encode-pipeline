<#
.SYNOPSIS
    Combines a FastFlix/NVEncC video encode with the main Blu-ray audio track, plus an
    AC-3 compatibility track for surround or an AAC encode for stereo.

.DESCRIPTION
    1. Picks the source audio track: the one flagged Default (first one if several),
       else the first lossless track, else the first track. -SourceTrack overrides this.
    2. Stereo or mono source: encoded to AAC (-AacBitrate). Nothing else is kept.
       (An AAC source is copied instead of re-encoded.)
    3. Surround source:
         - Already AC-3: copied as the only audio track.
         - Anything else: a new AC-3 5.1 track (-Ac3Bitrate) is encoded from it and
           becomes the default, and the source itself is kept as the second track
           (copied; PCM is converted to FLAC, which is still lossless).
    4. All other source audio tracks are dropped.
    5. Prints the plan and the ffmpeg command, runs it, then checks the result
       (audio tracks and the Dolby Vision configuration record).

    Only the first video stream of -VideoFile is used; any audio in it is ignored.
    Chapters are taken from -SourceFile.

.PARAMETER VideoFile
    The FastFlix output (HEVC with Dolby Vision).
.PARAMETER SourceFile
    The source MKV to take audio and chapters from.
.PARAMETER OutputFile
    Defaults to "<VideoFile name>.muxed.mp4" next to VideoFile.
.PARAMETER SourceTrack
    Use this source audio track (0-based, as in ffmpeg's 1:a:N) instead of auto-detection.
.PARAMETER AacBitrate
    AAC bitrate in kbps for stereo sources (mono sources are capped at 256).
.PARAMETER Ac3Bitrate
    AC-3 bitrate in kbps for surround sources.
.PARAMETER AudioLanguage
    ISO 639-2 language tag written on every audio track. Default 'eng'.
.PARAMETER Force
    Overwrite OutputFile if it exists.

.EXAMPLE
    .\Add-BluRayAudio.ps1 -VideoFile '.\S01E01.mp4' -SourceFile 'S:\Sources\S01E01.mkv' -WhatIf
    Shows the analysis, the plan and the ffmpeg command without running it.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$VideoFile,
    [Parameter(Mandatory)][string]$SourceFile,
    [string]$OutputFile,
    [int]$SourceTrack = -1,
    [ValidateRange(96, 576)][int]$AacBitrate = 512,
    [ValidateSet(384, 448, 512, 576, 640)][int]$Ac3Bitrate = 640,
    [ValidatePattern('^[a-z]{3}$')][string]$AudioLanguage = 'eng',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# ---------------------------------------------------------------- helpers

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

function Test-DolbyVision($VideoStream) {
    $sideData = @(Get-Field $VideoStream 'side_data_list')
    return [bool](@($sideData | Where-Object { (Get-Field $_ 'side_data_type') -like 'DOVI*' }).Count)
}

function New-OutputTrack([int]$SrcPos, [string]$Codec, [int]$Kbps, [int]$Ac, [string]$Title, [string]$Note) {
    return [pscustomobject]@{ SrcPos = $SrcPos; Codec = $Codec; Kbps = $Kbps; Ac = $Ac; Title = $Title; Note = $Note }
}

# ---------------------------------------------------------------- setup

$script:ffmpeg = Get-Tool 'ffmpeg'
$script:ffprobe = Get-Tool 'ffprobe'

$VideoFile = (Resolve-Path -LiteralPath $VideoFile).ProviderPath
$SourceFile = (Resolve-Path -LiteralPath $SourceFile).ProviderPath
if (-not $OutputFile) {
    $OutputFile = Join-Path ([IO.Path]::GetDirectoryName($VideoFile)) `
        ([IO.Path]::GetFileNameWithoutExtension($VideoFile) + '.muxed.mp4')
}
$OutputFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFile)

if ($OutputFile -in @($VideoFile, $SourceFile)) { throw 'OutputFile must be different from the input files.' }
if ((Test-Path -LiteralPath $OutputFile) -and -not $Force) {
    throw "Output already exists: $OutputFile (use -Force to overwrite)"
}

# ---------------------------------------------------------------- inspect video

$videoStreams = @(Get-Streams $VideoFile | Where-Object { $_.codec_type -eq 'video' })
if ($videoStreams.Count -eq 0) { throw "No video stream found in $VideoFile" }
if (-not (Test-DolbyVision $videoStreams[0])) {
    Write-Warning 'The input video has no Dolby Vision configuration record. The output will be HDR10/SDR only.'
}

# ---------------------------------------------------------------- inspect audio

$srcAudio = @(Get-Streams $SourceFile | Where-Object { $_.codec_type -eq 'audio' })
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

Write-Host "`nAudio tracks in source:"
$audio | Format-Table -AutoSize Pos, Name,
    @{ n = 'Ch';   e = { Get-ChannelLabel $_.Channels } },
    @{ n = 'kbps'; e = { if ($_.BitRate -gt 0) { [math]::Round($_.BitRate / 1000) } else { '?' } } },
    Default, Lossless, Title | Out-Host

# ---------------------------------------------------------------- choose source track

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

# ---------------------------------------------------------------- plan output tracks

$outputs = [Collections.Generic.List[object]]::new()
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
        $outputs.Add((New-OutputTrack $pick.Pos 'flac' 0 0 "FLAC $(Get-ChannelLabel $pick.Channels)" 'PCM converted to FLAC (lossless)'))
    } else {
        $outputs.Add((New-OutputTrack $pick.Pos 'copy' 0 0 $srcLabel 'copied'))
    }
}

# ---------------------------------------------------------------- build ffmpeg command

$ffArgs = [Collections.Generic.List[string]]::new()
$ffArgs.AddRange([string[]]@('-hide_banner', '-i', $VideoFile, '-i', $SourceFile, '-map', '0:v:0'))
foreach ($o in $outputs) { $ffArgs.AddRange([string[]]@('-map', "1:a:$($o.SrcPos)")) }
$ffArgs.AddRange([string[]]@('-map_chapters', '1', '-c:v', 'copy', '-tag:v', 'hvc1'))

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
$ffArgs.Add($OutputFile)

# ---------------------------------------------------------------- report and run

Write-Host "Source track: audio $($pick.Pos) - $srcLabel ($why)"
Write-Host 'Planned output audio:'
for ($i = 0; $i -lt $outputs.Count; $i++) {
    $o = $outputs[$i]
    $flag = ''
    if ($i -eq 0) { $flag = '  [default]' }
    Write-Host ("  a:{0}  {1,-40} {2}{3}" -f $i, $o.Title, $o.Note, $flag)
}
foreach ($d in @($audio | Where-Object { $_.Pos -ne $pick.Pos })) {
    Write-Host "  dropped: audio $($d.Pos) - $($d.Name) $(Get-ChannelLabel $d.Channels)" -ForegroundColor DarkGray
}
Write-Host "Output: $OutputFile`n"

$argArray = $ffArgs.ToArray()
Write-Host ((Format-Arg $script:ffmpeg) + ' ' + (($argArray | ForEach-Object { Format-Arg $_ }) -join ' ')) -ForegroundColor Cyan
Write-Host ''

if (-not $PSCmdlet.ShouldProcess($OutputFile, 'Run ffmpeg')) { return }

& $script:ffmpeg @argArray
if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed with exit code $LASTEXITCODE" }

# ---------------------------------------------------------------- verify output

$outStreams = Get-Streams $OutputFile
$outVideo = @($outStreams | Where-Object { $_.codec_type -eq 'video' })
$outAudio = @($outStreams | Where-Object { $_.codec_type -eq 'audio' })

Write-Host "`nResult:"
foreach ($s in $outAudio) {
    Write-Host ("  audio: {0,-7} {1,-4} default={2}  {3}" -f $s.codec_name,
        (Get-ChannelLabel ([int]$s.channels)), (Get-Field (Get-Field $s 'disposition') 'default'),
        (Get-Field (Get-Field $s 'tags') 'title'))
}
if ($outAudio.Count -ne $outputs.Count) {
    Write-Warning "Expected $($outputs.Count) audio tracks, found $($outAudio.Count)."
}

if ($outVideo.Count -gt 0 -and (Test-DolbyVision $outVideo[0])) {
    Write-Host '  Dolby Vision configuration record: present' -ForegroundColor Green
} else {
    Write-Warning 'Dolby Vision configuration record NOT found in the output video.'
}
