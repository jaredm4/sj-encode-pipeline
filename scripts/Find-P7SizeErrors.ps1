<#
.SYNOPSIS
    Finds finished Dolby Vision 7 titles whose "% of source" was measured against the wrong
    file, and works out their real size against the original. Reads only; changes nothing.
    Built for Windows PowerShell 5.1.

.DESCRIPTION
    Until Nov 2026, a Dolby Vision 7 title's size was measured against the 8.1 copy it was scored
    against, not the original: a baked FEL ("<name> - baked.mkv", often 3-4x the original's size)
    made encodes look far smaller than they are, and so did the rung search and the -MaxPct cap,
    which use that figure. A converted MEL ("<name> - p8.1.mkv", the base layer only) made them
    look a little bigger.

    For every title in each folder's "encode logs.zip" (or loose in the folder), from its
    "<name>.final.json" and "<name>.encode.log":
      - Affected: the finished variant's VMAF run compared against "<name> - baked.mkv" or
        "<name> - p8.1.mkv" (its "Original:" line). Anything else (including titles kept as
        profile 7, and 1080p copies) isn't affected and is skipped.
      - The encode's video: measured in the finished file with mediainfo, else the size the
        log recorded.
      - The original's video stream, from the most exact of:
          source on disk     the original, if it's still where final.json says (mediainfo)
          source-size.json   measured by a fixed Encode-Batch
          layers split       a baked title's log: "base X GB, enhancement Y GB" (both layers =
                             the original's video stream, to 0.1 GB)
          file size          the log's "Copying source ... (N GB" line: the whole original file,
                             audio included, so the real % is HIGHER than shown (">=")
    Sorted into: bigger than the original's video; over -MaxPct (the cap the search should have
    used); within it; and unknown (nothing to measure against).

.PARAMETER Root
    The media folder to search (all sub-folders).
.PARAMETER MaxPct
    The size cap to check against (Encode-Batch's -MaxPct). Default: 70.
.PARAMETER ShowAll
    Also list the titles within the cap.
.PARAMETER CsvPath
    Also save every affected title as a CSV here. Default: none.
.PARAMETER MediaInfo
    The MediaInfo command-line tool. Default: mediainfo on PATH; without it, the logs' sizes are used.

.EXAMPLE
    .\Find-P7SizeErrors.ps1 -Root 'L:\Library\Movies'
.EXAMPLE
    .\Find-P7SizeErrors.ps1 -Root 'L:\Library' -ShowAll -CsvPath "$HOME\Desktop\p7-sizes.csv"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Root,
    [double]$MaxPct = 70,
    [switch]$ShowAll,
    [string]$CsvPath = '',
    [string]$MediaInfo = 'mediainfo'
)

# Defaults from the settings file (encode-settings.ini) for parameters not given, and paths
# as typed or tab-completed: Shared.ps1, next to this script.
if (-not [IO.File]::Exists((Join-Path $PSScriptRoot 'Shared.ps1'))) { throw "Shared.ps1 not found next to this script ($PSScriptRoot); keep the scripts together." }
. (Join-Path $PSScriptRoot 'Shared.ps1')
$script:SettingsUsed = @(Get-ScriptSettings $MyInvocation.MyCommand $PSBoundParameters)
foreach ($setting in $script:SettingsUsed) { Set-Variable -Name $setting.Name -Value $setting.Value -WhatIf:$false }
$Root = Resolve-InputPath $Root; $CsvPath = Resolve-InputPath $CsvPath; $MediaInfo = Resolve-InputPath $MediaInfo -Program

# 'Continue': under 'Stop', Windows PowerShell turns a native program's stderr into errors.
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
if (-not [IO.Directory]::Exists($Root)) { throw "-Root not found: $Root" }
$mi = if ([IO.File]::Exists($MediaInfo)) { $MediaInfo } else { $c = Get-Command $MediaInfo -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($c) { $c.Source } else { '' } }
if (-not $mi) { Write-Host "mediainfo not found: sizes come from the logs only (pass -MediaInfo for exact ones)." -ForegroundColor Yellow }

# PowerShell's (and the logs' own) "GB" is 2^30 bytes; compare_encode's is 10^9. Everything
# below is in 10^9, as compare_encode reported the encodes.
$GiB = [double][Math]::Pow(2, 30) / 1e9

# A file's (first) video stream in GB (10^9 bytes), from mediainfo; 0 if it can't tell.
function Get-VideoGB([string]$Path) {
    if (-not $mi -or -not [IO.File]::Exists($Path)) { return 0.0 }
    try {
        $o = @(& $mi '--Output=Video;%StreamSize%\n' $Path 2>$null) | Where-Object { "$_".Trim() } | Select-Object -First 1
        if ("$o" -match '^\s*(\d+)\s*$') { return [double]$Matches[1] / 1e9 }
    } catch { }
    0.0
}

# A folder's title files (final.json, encode.log, source-size.json), loose or in "encode logs.zip".
function Get-TitleTexts([string]$Dir) {
    $h = @{}
    $zip = Join-Path $Dir 'encode logs.zip'
    if ([IO.File]::Exists($zip)) {
        try {
            $in = [IO.Compression.ZipFile]::OpenRead($zip)
            try {
                foreach ($e in $in.Entries) {
                    if ($e.Name -notmatch '\.(final\.json|encode\.log|source-size\.json)$') { continue }
                    $sr = New-Object IO.StreamReader($e.Open(), [Text.Encoding]::UTF8)
                    try { $h[$e.Name] = $sr.ReadToEnd() } finally { $sr.Dispose() }
                }
            } finally { $in.Dispose() }
        } catch { Write-Host "  WARNING: can't read $zip`: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.(final\.json|encode\.log|source-size\.json)$' })) {
        try { $h[$f.Name] = [IO.File]::ReadAllText($f.FullName) } catch { }   # loose files are newer than a zip's
    }
    $h
}

$rows = New-Object System.Collections.Generic.List[object]
$dirs = @(@(Get-Item -LiteralPath $Root) + @(Get-ChildItem -LiteralPath $Root -Recurse -Directory -ErrorAction SilentlyContinue))
$checked = 0; $p7 = 0; $n = 0
foreach ($d in $dirs) {
    $n++
    Write-Progress -Activity 'Reading encode logs' -Status "$n of $($dirs.Count): $($d.Name)" -PercentComplete (100 * $n / [Math]::Max(1, $dirs.Count))
    $texts = $null
    $hasLogs = [IO.File]::Exists((Join-Path $d.FullName 'encode logs.zip')) -or @(Get-ChildItem -LiteralPath $d.FullName -File -Filter '*.final.json' -ErrorAction SilentlyContinue).Count
    if (-not $hasLogs) { continue }
    $texts = Get-TitleTexts $d.FullName
    foreach ($fj in @($texts.Keys | Where-Object { $_ -like '*.final.json' })) {
        $base = $fj -replace '\.final\.json$', ''
        $checked++
        try { $doc = $texts[$fj] | ConvertFrom-Json } catch { continue }
        if ([string]$doc.State -ne 'done' -or -not $doc.Variant -or [string]$doc.Variant -in 'source', 'p7 original', 'manual') { continue }
        $log = $texts["$base.encode.log"]
        if (-not $log) { continue }
        $variant = [string]$doc.Variant
        $tag = "[$variant] "
        # The finished variant's last VMAF run: what it compared against, and the sizes it recorded.
        $ref = ''; $refGB = 0.0; $encGBLog = 0.0
        foreach ($l in ($log -split "`r?`n")) {
            $i = $l.IndexOf($tag); if ($i -lt 0) { continue }
            $x = $l.Substring($i + $tag.Length)
            if ($x -match '^Original: (.+?) \(\d+s\)\s*$') { $ref = $Matches[1] }
            elseif ($x -match '^Sizes \(video stream only\): original ([\d.]+) GB, encode ([\d.]+) GB') { $refGB = [double]$Matches[1]; $encGBLog = [double]$Matches[2] }
        }
        if ($ref -notmatch ' - (baked|p8\.1)\.mkv$') { continue }   # not scored against an 8.1 copy
        $p7++
        $kind = if ($ref -match ' - baked\.mkv$') { 'baked FEL' } else { 'converted MEL' }

        # The original's video stream: the most exact source of it.
        $srcGB = 0.0; $basis = ''; $lower = $false
        $srcPath = [string]$doc.Source
        if ($srcPath) { $g = Get-VideoGB $srcPath; if ($g -gt 0) { $srcGB = $g; $basis = 'source on disk' } }
        if (-not $srcGB -and $texts["$base.source-size.json"]) {
            try { $c = $texts["$base.source-size.json"] | ConvertFrom-Json; if ([int64]$c.VideoBytes -gt 0) { $srcGB = [double]$c.VideoBytes / 1e9; $basis = 'source-size.json' } } catch { }
        }
        if (-not $srcGB) {
            $m = [regex]::Matches($log, 'Layers split in \S+: base ([\d.]+) GB, enhancement ([\d.]+) GB')
            if ($m.Count) { $last = $m[$m.Count - 1]; $srcGB = ([double]$last.Groups[1].Value + [double]$last.Groups[2].Value) * $GiB; $basis = 'layers split' }
        }
        $fileGB = 0.0
        $m = [regex]::Matches($log, 'Copying source to .+? \(([\d.]+) GB, ')
        if ($m.Count) { $fileGB = [double]$m[$m.Count - 1].Groups[1].Value * $GiB }
        if (-not $srcGB -and $fileGB) { $srcGB = $fileGB; $basis = 'file size'; $lower = $true }

        # The encode's video: the finished file, else the log.
        $final = Join-Path $d.FullName $(if ($doc.Final) { @([string]$doc.Final -split '[\\/]')[-1] } else { "$base.mkv" })
        $encGB = Get-VideoGB $final; $encBasis = 'finished file'
        if (-not $encGB) { $encGB = $encGBLog; $encBasis = 'log' }
        $finalFileGB = if ([IO.File]::Exists($final)) { (New-Object IO.FileInfo $final).Length / 1e9 } else { 0.0 }

        $recPct = $null
        $vr = @($doc.Variants | Where-Object { [string]$_.Name -eq $variant }) | Select-Object -First 1
        if ($vr -and $null -ne $vr.Pct) { $recPct = [double]$vr.Pct }
        $pct = if ($srcGB -gt 0 -and $encGB -gt 0) { [Math]::Round($encGB / $srcGB * 100, 1) } else { $null }
        $group = if ($null -eq $pct) { 'Unknown' } elseif ($pct -gt 100) { 'Bigger than the original' } elseif ($pct -gt $MaxPct) { "Over $MaxPct%" } else { 'Within the cap' }
        $rows.Add([pscustomobject]@{
            Group = $group; Title = $base; Kind = $kind; Variant = $variant
            RecordedPct = $recPct; RealPct = $(if ($null -eq $pct) { '?' } elseif ($lower) { ">= $pct" } else { "$pct" })
            EncodeVideoGB = [Math]::Round($encGB, 2); SourceVideoGB = $(if ($srcGB) { [Math]::Round($srcGB, 2) } else { $null }); Basis = $basis
            ScoredAgainstGB = $refGB; FinishedFileGB = [Math]::Round($finalFileGB, 2); SourceFileGB = $(if ($fileGB) { [Math]::Round($fileGB, 2) } else { $null })
            EncodeFrom = $encBasis; Folder = $d.FullName; SortPct = $(if ($null -eq $pct) { -1 } else { $pct })
        })
    }
}
Write-Progress -Activity 'Reading encode logs' -Completed

$order = @('Bigger than the original', "Over $MaxPct%", 'Within the cap', 'Unknown')
Write-Host ''
Write-Host ("Titles checked: {0}; scored against an 8.1 copy: {1} (bigger than the original: {2}; over {3}%: {4}; within: {5}; unknown: {6})." -f $checked, $p7,
    @($rows | Where-Object { $_.Group -eq $order[0] }).Count, $MaxPct, @($rows | Where-Object { $_.Group -eq $order[1] }).Count,
    @($rows | Where-Object { $_.Group -eq $order[2] }).Count, @($rows | Where-Object { $_.Group -eq $order[3] }).Count)
Write-Host 'Sizes are video streams in GB (10^9 bytes). RealPct ">=" means only the original''s whole file size was known, so the real figure is higher.' -ForegroundColor DarkGray
foreach ($g in $order) {
    $sel = @($rows | Where-Object { $_.Group -eq $g } | Sort-Object SortPct -Descending)
    if (-not $sel.Count -or ($g -eq 'Within the cap' -and -not $ShowAll)) { continue }
    Write-Host "$($g):" -ForegroundColor $(switch ($g) { 'Bigger than the original' { 'Red' } 'Within the cap' { 'Green' } default { 'Yellow' } })
    $sel | Format-Table Title, Kind, Variant, @{ n = 'Recorded %'; e = { $_.RecordedPct } }, @{ n = 'Real %'; e = { $_.RealPct } },
        @{ n = 'Encode GB'; e = { $_.EncodeVideoGB } }, @{ n = 'Original GB'; e = { $_.SourceVideoGB } }, Basis, @{ n = 'Scored vs GB'; e = { $_.ScoredAgainstGB } } -AutoSize |
        Out-String -Width 300 | Write-Host
}
if ($CsvPath -and $rows.Count) {
    $rows | Select-Object * -ExcludeProperty SortPct | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Saved: $CsvPath"
}
