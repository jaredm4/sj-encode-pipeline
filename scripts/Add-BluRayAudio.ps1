<#
.SYNOPSIS
    Combines a FastFlix/NVEncC video encode with Blu-ray audio: every lossless master track,
    each paired with an AC-3 compatibility track.

.DESCRIPTION
    1. Every lossless audio track (TrueHD, DTS-HD MA, PCM, FLAC) is kept as a master.
       TrueHD, DTS-HD MA and FLAC are copied; PCM is converted to FLAC (still lossless,
       and MP4-friendly). If there is no lossless track, the largest lossy track is kept.
    2. For each master, an AC-3 track is added according to -Ac3Mode. An existing AC-3
       track is reused if it comes after the master, has the matching layout (5.1 for
       5.1/6.1/7.1 masters, 2.0 for stereo, etc.), is at least -Ac3Bitrate, and hasn't
       already been claimed by another master. Otherwise a new AC-3 track is encoded
       from the master.
    3. Output order: the primary master's AC-3 track first (default), then the primary
       master, then the same pair for any other masters. All other source audio tracks
       are dropped.
    4. Prints the plan and the ffmpeg command, runs it, then checks the result
       (audio tracks and the Dolby Vision configuration record).

    Only the first video stream of -VideoFile is used; any audio in it is ignored.
    Chapters are taken from -SourceFile.

.PARAMETER VideoFile
    The FastFlix output (HEVC with Dolby Vision).
.PARAMETER SourceFile
    The source MKV to take audio and chapters from.
.PARAMETER OutputFile
    Defaults to "<VideoFile name>.muxed.mp4" next to VideoFile.
.PARAMETER Ac3Mode
    Always : add an AC-3 track for every master (default).
    NoCore : skip AC-3 for DTS masters, whose DTS core already works on Roku, Shield
             and most Android TV boxes. TrueHD, PCM and FLAC masters still get one.
    Never  : no AC-3 tracks; masters only.
.PARAMETER PrimaryTrack
    Source audio track (0-based, as in ffmpeg's 1:a:N) to make the primary master.
    Default: the master with the most channels, then the largest stream.
.PARAMETER Ac3Bitrate
    Bitrate in kbps for new AC-3 tracks, and the minimum for an existing one to be reused.
.PARAMETER AudioLanguage
    ISO 639-2 language tag written on every audio track. Default 'eng'.
.PARAMETER Force
    Overwrite OutputFile if it exists.

.EXAMPLE
    .\Add-BluRayAudio.ps1 -VideoFile '.\S01E01.mp4' -SourceFile 'S:\Sources\S01E01.mkv' -WhatIf
    Shows the analysis, the plan and the ffmpeg command without running it.
.EXAMPLE
    .\Add-BluRayAudio.ps1 -VideoFile '.\Movie.mp4' -SourceFile 'S:\Sources\Movie.mkv' -PrimaryTrack 0
    Makes the first source audio track (e.g. the original stereo mix) the default.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$VideoFile,
    [Parameter(Mandatory)][string]$SourceFile,
    [string]$OutputFile,
    [ValidateSet('Always', 'NoCore', 'Never')][string]$Ac3Mode = 'Always',
    [int]$PrimaryTrack = -1,
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

function Get-AudioKind([string]$Format, [string]$Features) {
    switch -Regex ($Format) {
        '^MLP'    { return 'TrueHD' }
        '^DTS'    { if ("$Format $Features" -match 'XLL') { return 'DTS-HD MA' } else { return 'DTS' } }
        '^PCM'    { return 'PCM' }
        '^FLAC'   { return 'FLAC' }
        '^AC-3'   { return 'AC-3' }
        '^E-AC-3' { return 'E-AC-3' }
    }
    return $Format
}

function Get-FfCodecPattern([string]$Kind) {
    switch ($Kind) {
        'TrueHD'    { return '^truehd$' }
        'DTS-HD MA' { return '^dts$' }
        'DTS'       { return '^dts$' }
        'PCM'       { return '^pcm_' }
        'FLAC'      { return '^flac$' }
        'AC-3'      { return '^ac3$' }
        'E-AC-3'    { return '^eac3$' }
    }
    return '.'
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

function New-OutputTrack($SrcPos, [string]$Codec, [int]$Ac, [string]$Title, [string]$Note) {
    return [pscustomobject]@{ SrcPos = $SrcPos; Codec = $Codec; Ac = $Ac; Title = $Title; Note = $Note }
}

# ---------------------------------------------------------------- setup

$script:ffmpeg = Get-Tool 'ffmpeg'
$script:ffprobe = Get-Tool 'ffprobe'
$mediainfo = Get-Tool 'mediainfo'

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

$miRaw = & $mediainfo --Output=JSON $SourceFile | Out-String
if ([string]::IsNullOrWhiteSpace($miRaw)) {
    throw 'MediaInfo returned nothing. Make sure the MediaInfo CLI (not the GUI) is on PATH.'
}
$miAudio = @((ConvertFrom-Json $miRaw).media.track | Where-Object { (Get-Field $_ '@type') -eq 'Audio' })
$fpAudio = @(Get-Streams $SourceFile | Where-Object { $_.codec_type -eq 'audio' })

if ($miAudio.Count -eq 0) { throw "No audio tracks found in $SourceFile" }
if ($miAudio.Count -ne $fpAudio.Count) {
    throw "MediaInfo sees $($miAudio.Count) audio tracks but ffprobe sees $($fpAudio.Count); refusing to guess the mapping."
}

$audio = @(for ($i = 0; $i -lt $miAudio.Count; $i++) {
    $t = $miAudio[$i]
    $kind = Get-AudioKind (Get-Field $t 'Format') (Get-Field $t 'Format_AdditionalFeatures')
    $bitrate = ConvertTo-Number (Get-Field $t 'BitRate')
    $size = ConvertTo-Number (Get-Field $t 'StreamSize')
    if ($size -le 0) { $size = $bitrate * (ConvertTo-Number (Get-Field $t 'Duration')) / 8 }
    $name = Get-Field $t 'Format_Commercial_IfAny'
    if (-not $name) { $name = $kind }

    [pscustomobject]@{
        Pos      = $i
        Kind     = $kind
        Name     = $name
        Channels = [int](ConvertTo-Number (Get-Field $t 'Channels'))
        BitRate  = $bitrate
        Size     = $size
        Title    = [string](Get-Field $t 'Title')
        Lossless = $kind -in @('TrueHD', 'DTS-HD MA', 'PCM', 'FLAC')
        HasCore  = $kind -in @('DTS-HD MA', 'DTS')
        FfCodec  = $fpAudio[$i].codec_name
    }
})

foreach ($a in $audio) {
    if ($a.FfCodec -notmatch (Get-FfCodecPattern $a.Kind)) {
        throw "Track order mismatch at audio $($a.Pos): MediaInfo says $($a.Kind), ffprobe says $($a.FfCodec)."
    }
}

Write-Host "`nAudio tracks in source:"
$audio | Format-Table -AutoSize Pos, Name,
    @{ n = 'Ch';   e = { Get-ChannelLabel $_.Channels } },
    @{ n = 'kbps'; e = { [math]::Round($_.BitRate / 1000) } },
    @{ n = 'MB';   e = { [math]::Round($_.Size / 1MB) } },
    Title | Out-Host

# ---------------------------------------------------------------- choose masters

function Select-Best($Tracks) {
    $best = $Tracks[0]
    foreach ($t in $Tracks) {
        if ($t.Channels -gt $best.Channels -or ($t.Channels -eq $best.Channels -and $t.Size -gt $best.Size)) {
            $best = $t
        }
    }
    return $best
}

$masters = @($audio | Where-Object Lossless)
if ($masters.Count -eq 0) {
    Write-Warning 'No lossless audio track found; keeping the best lossy track as the master.'
    $masters = @(Select-Best $audio)
}

if ($PrimaryTrack -ge 0) {
    $primary = @($masters | Where-Object { $_.Pos -eq $PrimaryTrack })
    if ($primary.Count -eq 0) {
        throw "Audio track $PrimaryTrack is not a master track. Masters: $(($masters | ForEach-Object Pos) -join ', ')"
    }
    $primary = $primary[0]
} else {
    $primary = Select-Best $masters
}
$orderedMasters = @($primary) + @($masters | Where-Object { $_.Pos -ne $primary.Pos })

# ---------------------------------------------------------------- plan output tracks

$claimed = @{}
$outputs = [Collections.Generic.List[object]]::new()

foreach ($m in $orderedMasters) {
    $targetCh = 6
    if ($m.Channels -gt 0) { $targetCh = [Math]::Min($m.Channels, 6) }

    $wantAc3 = $false
    switch ($Ac3Mode) {
        'Always' { $wantAc3 = $true }
        'NoCore' { $wantAc3 = -not $m.HasCore }
    }
    if ($m.Kind -in @('AC-3', 'E-AC-3')) { $wantAc3 = $false }

    if ($wantAc3) {
        $match = $audio | Where-Object {
            $_.Pos -gt $m.Pos -and $_.Kind -eq 'AC-3' -and -not $claimed.ContainsKey($_.Pos) -and
            $_.Channels -eq $targetCh -and $_.BitRate -ge $Ac3Bitrate * 1000
        } | Select-Object -First 1

        if ($match) {
            $claimed[$match.Pos] = $true
            $outputs.Add((New-OutputTrack $match.Pos 'copy' 0 `
                "$($match.Name) $(Get-ChannelLabel $match.Channels)" "copied from audio $($match.Pos)"))
        } else {
            $ac = 0
            if ($m.Channels -gt 6) { $ac = 6 }
            $outputs.Add((New-OutputTrack $m.Pos 'ac3' $ac `
                "Dolby Digital $(Get-ChannelLabel $targetCh)" "encoded from audio $($m.Pos) at $Ac3Bitrate kbps"))
        }
    }

    if ($m.Kind -eq 'PCM') {
        $outputs.Add((New-OutputTrack $m.Pos 'flac' 0 `
            "FLAC $(Get-ChannelLabel $m.Channels)" "audio $($m.Pos) PCM converted to FLAC (lossless)"))
    } else {
        $outputs.Add((New-OutputTrack $m.Pos 'copy' 0 `
            "$($m.Name) $(Get-ChannelLabel $m.Channels)" "copied from audio $($m.Pos)"))
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
    if ($o.Codec -eq 'ac3') { $ffArgs.AddRange([string[]]@("-b:a:$i", "$($Ac3Bitrate)k")) }
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

Write-Host "Planned output audio (Ac3Mode: $Ac3Mode):"
for ($i = 0; $i -lt $outputs.Count; $i++) {
    $o = $outputs[$i]
    $flag = ''
    if ($i -eq 0) { $flag = '  [default]' }
    Write-Host ("  a:{0}  {1,-45} {2}{3}" -f $i, $o.Title, $o.Note, $flag)
}
$usedPos = @($outputs | ForEach-Object SrcPos)
foreach ($d in @($audio | Where-Object { $_.Pos -notin $usedPos })) {
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
    $disp = Get-Field $s 'disposition'
    Write-Host ("  audio: {0,-7} {1,-4} default={2}  {3}" -f $s.codec_name,
        (Get-ChannelLabel ([int]$s.channels)), (Get-Field $disp 'default'),
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
