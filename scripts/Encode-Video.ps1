<#
.SYNOPSIS
    Encodes one video with NVEncC (HEVC, 10-bit, two-pass), the way Encode-Batch encodes each
    variant: optional crop, the source's HDR / HDR10+ metadata, and Dolby Vision 8.1 (RPU copied).
    Built for Windows PowerShell 5.1.

.DESCRIPTION
    Writes "<Output without .mkv>.partial.mkv" first and renames it to -Output when NVEncC
    succeeds, so a half-written encode is never mistaken for a finished one. If -Output already
    exists it's reused (nothing is encoded).

    NVEncC options, in order:
      --<Decoder> --device 0 -i <Source> [--crop L,T,R,B]
      --video-metadata clear --metadata clear --chapter-copy -c hevc
      <EncoderArgs> (e.g. --cqp 24 --aq --aq-strength 8)
      --bref-mode middle --preset P7 --tier main --level 5.1 --chromaloc auto --colorrange auto
      HDR source: its color options, --master-display and --max-cll (when it has them),
                  --dhdr10-info copy (HDR10+); otherwise --colormatrix/--transfer/--colorprim auto
      -DolbyVision: --dolby-vision-rpu copy --dolby-vision-profile copy (+ crop=true when cropped)
      --output-depth 10 --multipass 2pass-full --mv-precision Auto --avsync cfr -o <partial>

    Encode-Batch runs this in its encode workers (with -Plumbing and its title log). It can also
    be run on its own for one file.

.PARAMETER Source
    The video to encode (an MKV).
.PARAMETER Output
    The encode to write (.mkv). Reused if it already exists.
.PARAMETER EncoderArgs
    The quality settings for NVEncC, e.g. '--cqp','24','--aq','--aq-strength','8', or as one
    string: '--cqp 24 --aq --aq-strength 8'.
.PARAMETER Crop
    Pixels to crop as "Left,Top,Right,Bottom" (CropDetect's numbers). Default: none.
.PARAMETER Decoder
    How NVEncC decodes the source: avsw (CPU, default) or avhw (GPU).
.PARAMETER DolbyVision
    Copy the source's Dolby Vision 8.1 metadata (RPU). Only for a profile 8.1 source. When it's
    left out and -SourceInfo isn't given, it's set from the source's own probe (8.1 -> on).
.PARAMETER SourceInfo
    The source's probe (Get-SourceInfo in Encode-Batch.Common.ps1): HDR, color options, mastering
    display, max CLL, HDR10+. Encode-Batch passes its own (for a converted Dolby Vision 7 title,
    the original's). Probed from -Source when not given.
.PARAMETER NVEncC
    Path to NVEncC64.exe. Default: %APPDATA%\NVEnc\NVEncC64.exe.
.PARAMETER VmafFile
    A VMAF result for -Output from an earlier encode: deleted when the encode is redone (it no
    longer applies). Default: none.
.PARAMETER TempDir
    Where NVEncC's output is buffered while it runs. Default: your temp folder.
.PARAMETER LogPath
    Log to add to (Encode-Batch: the title's .encode.log). Default: none (screen only).
.PARAMETER LogPrefix
    Put in front of every log line (Encode-Batch: "[<variant>] ").
.PARAMETER StatusFile
    JSON file for progress (Encode-Batch's console reads it). Default: none.
.PARAMETER Status
    Fields to keep in every status update (Encode-Batch: the variant and its number).
.PARAMETER Plumbing
    For Encode-Batch: nothing on screen; one line of JSON on stdout when done:
      Status     Encoded, Reused or Failed
      Error      why it failed
      EncodeSec  how long NVEncC took (Encoded only)
      Output     the encode

.EXAMPLE
    .\Encode-Video.ps1 -Source 'S:\Sources\Movie.mkv' -Output 'D:\enc\Movie.mkv' -EncoderArgs '--cqp','24','--aq','--aq-strength','8' -Crop '0,140,0,140'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Output,
    [Parameter(Mandatory)][string[]]$EncoderArgs,
    [string]$Crop = '',
    [ValidateSet('avhw', 'avsw')][string]$Decoder = 'avsw',
    [switch]$DolbyVision,
    $SourceInfo = $null,
    [string]$NVEncC = '',
    [string]$VmafFile = '',
    [string]$TempDir = [IO.Path]::GetTempPath(),
    [string]$LogPath = '',
    [string]$LogPrefix = '',
    [string]$StatusFile = '',
    [hashtable]$Status = @{},
    [switch]$Plumbing
)

# 'Continue', not 'Stop': in Windows PowerShell, 2>&1 on a native program raises terminating
# errors under 'Stop'. Failures are checked explicitly.
$ErrorActionPreference = 'Continue'
# The shared helpers: already loaded when Encode-Batch runs this inside its worker, else from
# Encode-Batch.Common.ps1 next to this script.
if (-not (Get-Command Invoke-Logged -CommandType Function -ErrorAction SilentlyContinue)) {
    $commonPath = Join-Path $PSScriptRoot 'Encode-Batch.Common.ps1'
    if (-not [IO.File]::Exists($commonPath)) { throw "Encode-Batch.Common.ps1 not found next to this script ($commonPath)." }
    . $commonPath
}
$script:Utf8 = New-Object System.Text.UTF8Encoding $false
$script:LogPath = $(if ($LogPath) { $LogPath } else { $null })
$script:StatusFile = $(if ($StatusFile) { $StatusFile } else { $null })
$script:LogPrefix = $LogPrefix
$script:EchoLog = -not $Plumbing
if (-not $NVEncC) { $NVEncC = [IO.Path]::Combine([string]$env:APPDATA, 'NVEnc', 'NVEncC64.exe') }

$status = $Status
if (-not $status.ContainsKey('Step')) { $status.Step = 'starting' }
function Step([string]$name) {
    $status.Step = $name; $status.Remove('Pct'); $status.Remove('Detail')
    Set-Status $status
}

$res = [ordered]@{ Status = 'Failed'; Error = ''; EncodeSec = $null; Output = $Output }
$dvGiven = $PSBoundParameters.ContainsKey('DolbyVision')
# One string ("--cqp 24 --aq") works too.
if ($EncoderArgs.Count -eq 1 -and $EncoderArgs[0] -match '\s') { $EncoderArgs = @($EncoderArgs[0] -split '\s+' | Where-Object { $_ }) }

function Invoke-Encode {
  try {
    $info = $SourceInfo
    $dv = [bool]$DolbyVision
    if (-not $info) {
        $info = Get-SourceInfo $Source
        if (-not $dvGiven) { $dv = ($info.Dv -eq 'P8.1') }
    }
    $c = @(0, 0, 0, 0)
    if ($Crop) {
        $c = @($Crop -split '[,:]' | ForEach-Object { [int]$_ })
        if ($c.Count -ne 4) { throw "-Crop must be Left,Top,Right,Bottom (got '$Crop')." }
    }
    $hasCrop = ($c[0] + $c[1] + $c[2] + $c[3]) -gt 0
    $vdir = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Output))
    [void][IO.Directory]::CreateDirectory($vdir)
    $partial = Join-Path $vdir ([IO.Path]::GetFileNameWithoutExtension($Output) + '.partial.mkv')
    if ([IO.File]::Exists($Output)) {
        Write-Log "Encode already exists, reusing: $Output"
        $res.Status = 'Reused'
        return
    }
    $free = Get-FreeGB $vdir
    if ($free -lt 10) { $res.Error = "only $free GB free"; Write-Log "Skipping encode: $($res.Error)"; return }
    if ([IO.File]::Exists($partial)) { Remove-Item -LiteralPath $partial -Force }
    Step 'encoding'
    $a = @("--$Decoder", '--device', '0', '-i', $Source)
    if ($hasCrop) { $a += @('--crop', ('{0},{1},{2},{3}' -f $c[0], $c[1], $c[2], $c[3])) }
    $a += @('--video-metadata', 'clear', '--metadata', 'clear', '--chapter-copy', '-c', 'hevc')
    $a += @($EncoderArgs)
    $a += @('--bref-mode', 'middle', '--preset', 'P7', '--tier', 'main', '--level', '5.1', '--chromaloc', 'auto', '--colorrange', 'auto')
    # Only pass the HDR / HDR10+ / Dolby Vision options a source actually has (FastFlix
    # always adds the "copy" ones). Their avhw implementation re-orders frames by
    # timestamp to match the metadata, so there's no reason to involve it otherwise.
    $colorArgs = @($info.ColorArgs | Where-Object { $_ })
    if ($info.Hdr -and $colorArgs.Count) { $a += $colorArgs }
    else { $a += @('--colormatrix', 'auto', '--transfer', 'auto', '--colorprim', 'auto') }
    if ($info.Hdr) {
        if ($info.MasterDisplay) { $a += @('--master-display', $info.MasterDisplay) } else { Write-Log 'WARNING: HDR source without mastering display metadata; none written.' }
        if ($info.MaxCll) { $a += @('--max-cll', $info.MaxCll) }
    }
    if ($info.Hdr10Plus) { $a += @('--dhdr10-info', 'copy') }
    if ($dv) {
        $a += @('--dolby-vision-rpu', 'copy', '--dolby-vision-profile', 'copy')
        if ($hasCrop) { $a += @('--dolby-vision-rpu-prm', 'crop=true') }
    }
    $a += @('--output-depth', '10', '--multipass', '2pass-full', '--mv-precision', 'Auto', '--avsync', 'cfr', '-o', $partial)
    $a = @($a | Where-Object { $null -ne $_ -and "$_" -ne '' })
    $e0 = Get-Date
    $r = Invoke-Logged -Exe $NVEncC -ArgList $a -TempDir $TempDir -StatusBase $status
    $res.EncodeSec = [int]((Get-Date) - $e0).TotalSeconds
    if ($r.ExitCode -ne 0 -or -not [IO.File]::Exists($partial) -or (Get-Item -LiteralPath $partial).Length -eq 0) {
        $res.Error = "NVEncC exit $($r.ExitCode)"
        Write-Log "Encode FAILED: $($res.Error)"
        return
    }
    Move-Item -LiteralPath $partial -Destination $Output -Force -ErrorAction Stop
    # A score left over from an earlier encode of this variant no longer applies.
    if ($VmafFile -and [IO.File]::Exists($VmafFile)) { Remove-Item -LiteralPath $VmafFile -Force -ErrorAction Stop; Write-Log "Removed the old VMAF result (it was for a previous encode)." }
    Write-Log ("Encoded in {0}: {1}" -f [TimeSpan]::FromSeconds($res.EncodeSec), $Output)
    $res.Status = 'Encoded'
  } catch {
    $res.Error = $_.Exception.Message
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-LogRaw ($_.ScriptStackTrace)
  }
}

[void](Invoke-Encode)
if ($Plumbing) {
    [pscustomobject]$res | ConvertTo-Json -Compress
} else {
    if ($res.Status -eq 'Failed') { Write-Host "Failed: $($res.Error)" -ForegroundColor Red; exit 1 }
    Write-Host "$($res.Status): $Output" -ForegroundColor Green
}
