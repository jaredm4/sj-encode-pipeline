<#
.SYNOPSIS
    Re-detects black bars on source MKVs using many more samples than FastFlix.
    With -Dest: reports encoded files whose resolution doesn't match the expected crop
    and writes a Markdown report (default: Desktop\CropReport_<date>.md).
    Without -Dest: prints the suggested crop for each source.

.DESCRIPTION
    Strict crop: ffmpeg cropdetect at every sample point; the union of all samples is the
    largest area that ever contains picture. A side with less than -MinBarPixels (10) of solid
    black isn't cropped: thin stray lines are left, only real bars are removed.

    Soft edges: in the same decode, every frame is reduced to a per-column and per-row
    luma profile. A pixel line at the edge of the strict crop counts as "soft edge" if it is
    darker than the picture slightly further in (EdgeRatio) in nearly every bright frame
    (EdgeConsistency). Real picture edges vary scene to scene; scanner/gate artifacts are
    darker every time. Trimming is capped at SoftBorderMaxPercent per side.

    An encode is accepted if its resolution lies between the soft and strict results.

.EXAMPLE
    CropDetect -Source "S:\Sources\Movies" -Dest "L:\Library\Movies"

.EXAMPLE
    CropDetect -Source ".\Movie (1975) [tmdbid-12345] - 2160p.mkv" -StepPercent 2

.EXAMPLE
    CropDetect -Source ".\movie.mkv" -Plumbing
    Machine-readable mode for scripts: writes one compressed JSON line per source to the
    output stream with the Suggested crop at the top level, and all three crops (Strict:
    black bars only; Suggested: plus soft edges beside black bars; Full: plus all soft edges)
    under Crops, e.g.
    {"File":"D:\\movie.mkv","SourceWidth":3840,"SourceHeight":2160,"Width":3840,"Height":1632,
     "Left":0,"Top":264,"Right":0,"Bottom":264,"Mode":"Suggested",
     "Crops":{"Strict":{"Width":3840,"Height":1632,...},"Suggested":{...},"Full":{...}},
     "Samples":"20/20","EdgeDark":"L9% R9% T0% B1%"}
    Status text still goes to the host/information stream (callers can redirect it with 6>),
    progress bars are suppressed, and nothing is written for a file that can't be analysed.
    Cannot be combined with -Dest.
#>
[CmdletBinding()]
param(
    # A folder of movie folders, a single movie folder, or a single .mkv file. Relative paths are fine.
    [Parameter(Mandatory)][string]$Source,

    # Omit to just analyse sources and print suggested crops (no comparison, no report).
    [string]$Dest,

    # Sample spacing as % of runtime. 5 = 20 samples, centred at 2.5%, 7.5% ... 97.5%.
    [ValidateRange(0.5, 50)][double]$StepPercent = 5,

    # Frames analysed at each sample point (~2 s at 24 fps).
    [ValidateRange(1, 1000)][int]$FramesPerSample = 48,

    # Strict black threshold for cropdetect, as a fraction (0.094 ~= 24/255). Bit-depth independent.
    [double]$Limit = 0.094,

    # Max pixels the soft-edge check may trim per side, as % of that dimension.
    # 0.5 => up to 9 px/side at 1080p, 19 px at 4K. 0 disables soft-edge handling.
    [ValidateRange(0, 10)][double]$SoftBorderMaxPercent = 0.5,

    # An edge line is "darker" in a frame if its brightness is below this fraction of the reference strip.
    [ValidateRange(0.5, 1.0)][double]$EdgeRatio = 0.95,

    # Fraction of bright frames in which an edge line must be darker to be treated as soft edge.
    [ValidateRange(0.5, 1.0)][double]$EdgeConsistency = 0.65,

    # Frames whose reference strip is dimmer than this (8-bit luma, 0-255) are ignored for the soft check.
    [ValidateRange(0, 255)][int]$BrightMin = 48,

    # Strict crop: a side needs at least this many pixels of solid black to be cropped; thinner
    # (stray lines left on the disc, not a letterbox) is left alone. Soft/Suggested crops still
    # trim them. 0 or 1 = crop any solid black.
    [ValidateRange(0, 200)][int]$MinBarPixels = 10,

    # Samples that must show picture at an edge before it counts for the strict crop (1 = pure union).
    [ValidateRange(1, 10)][int]$MinSupport = 1,

    # Allowed difference in pixels (per dimension) beyond the accepted range.
    [ValidateRange(0, 64)][int]$Tolerance = 0,

    # Use NVDEC for decoding (faster on 4K HEVC).
    [switch]$HwDecode,

    # Report location. Defaults to Desktop\CropReport_yyyy-MM-dd_HHmmss.md
    [string]$ReportPath,

    # Machine-readable output for other scripts (see examples). Analysis only.
    [switch]$Plumbing
)

if ($Plumbing) {
    if ($Dest) { throw '-Plumbing cannot be combined with -Dest.' }
    $ProgressPreference = 'SilentlyContinue'
}

$inv = [System.Globalization.CultureInfo]::InvariantCulture
$started = Get-Date
$RefWidth = 8          # lines in the reference strip
$MinBrightFrames = 20  # below this, no soft trimming is attempted

foreach ($tool in 'ffmpeg', 'ffprobe') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool not found on PATH." }
}

if (-not $ReportPath) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop) { $desktop = Join-Path $HOME 'Desktop' }
    $ReportPath = Join-Path $desktop ('CropReport_{0:yyyy-MM-dd_HHmmss}.md' -f $started)
}

# ---------------------------------------------------------------- path handling
# Uses .NET file APIs so [ ] and other wildcard characters in names are treated literally.

function ConvertTo-FullPath {
    # Tab completion escapes [ ] as `[ `] (meant for wildcard-aware commands), so try the path
    # exactly as given first, then with that backtick escaping removed.
    param([string]$Path, [string]$What)
    $candidates = @($Path)
    $unescaped = $Path -replace '`(.)', '$1'
    if ($unescaped -ne $Path) { $candidates += $unescaped }

    $first = $null; $lastError = $null
    foreach ($c in $candidates) {
        try {
            $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($c)
        } catch {
            $lastError = $_.Exception.Message
            continue
        }
        if (-not $full) { continue }
        if (-not $first) { $first = $full }
        if ([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)) { return $full }
    }
    if ($first) { return $first }   # doesn't exist; the caller reports it clearly
    throw "$What path is invalid: '$Path'. $lastError"
}

$srcPath = ConvertTo-FullPath $Source 'Source'

if ([IO.Directory]::Exists($srcPath)) {
    $srcRoot = $srcPath.TrimEnd('\', '/')
    $rootDir = New-Object IO.DirectoryInfo $srcRoot
    $found = New-Object System.Collections.Generic.List[IO.FileInfo]
    # Root folder itself, plus one level of sub-folders (one folder per movie).
    $dirs = @($rootDir)
    try { $dirs += @($rootDir.GetDirectories()) } catch { Write-Warning "Could not list folders in '$srcRoot': $($_.Exception.Message)" }
    foreach ($d in $dirs) {
        try {
            foreach ($f in $d.GetFiles('*.mkv')) {
                if ($f.Extension -eq '.mkv') { $found.Add($f) }   # .NET '*.mkv' can also match '.mkvx' etc.
            }
        } catch {
            Write-Warning "Skipping '$($d.FullName)': $($_.Exception.Message)"
        }
    }
    $sources = @($found | Sort-Object FullName)
}
elseif ([IO.File]::Exists($srcPath)) {
    $srcRoot = [IO.Path]::GetDirectoryName($srcPath).TrimEnd('\', '/')
    $sources = @(New-Object IO.FileInfo $srcPath)
}
else {
    throw "Source not found: '$srcPath' (from '$Source', current location '$((Get-Location).ProviderPath)')."
}

if ($sources.Count -eq 0) { throw "No .mkv files found in '$srcRoot' or its immediate sub-folders." }

$dstRoot = $null
if ($Dest) {
    $dstRoot = (ConvertTo-FullPath $Dest 'Dest').TrimEnd('\', '/')
    if (-not [IO.Directory]::Exists($dstRoot)) { throw "Dest folder not found: '$dstRoot' (from '$Dest')." }
}

$mode = if ($dstRoot) { "comparing against $dstRoot" } else { 'analysis only (no -Dest given)' }
Write-Host "Found $($sources.Count) source file(s) in $srcRoot - $mode" -ForegroundColor Cyan

# ---------------------------------------------------------------- helpers

function Get-VideoInfo {
    param([string]$Path)
    $json = & ffprobe -v error -select_streams v:0 `
        -show_entries 'stream=width,height:format=duration' -of json $Path 2>$null
    if (-not $json) { return $null }
    $j = ($json -join "`n") | ConvertFrom-Json
    if (-not $j.streams) { return $null }
    $dur = 0.0
    [void][double]::TryParse([string]$j.format.duration, [System.Globalization.NumberStyles]::Float, $inv, [ref]$dur)
    [pscustomobject]@{
        Width    = [int]$j.streams[0].width
        Height   = [int]$j.streams[0].height
        Duration = $dur
    }
}

function New-Box {
    param([int]$L, [int]$T, [int]$R, [int]$B, $Info)
    [pscustomobject]@{
        Left = $L; Top = $T; Right = $R; Bottom = $B
        Width  = $Info.Width - $L - $R
        Height = $Info.Height - $T - $B
    }
}

function ConvertTo-Even {
    # Rounds an odd number to even: down by default, up with -Up.
    param([int]$Value, [switch]$Up)
    if ($Value % 2 -eq 0) { return $Value }
    if ($Up) { $Value + 1 } else { $Value - 1 }
}

function Get-Bounds {
    param($Boxes, [int]$K, $Info)
    $k = [Math]::Min([Math]::Max(1, $K), $Boxes.Count)
    $x1 = @($Boxes | ForEach-Object { $_.X1 } | Sort-Object)[$k - 1]
    $y1 = @($Boxes | ForEach-Object { $_.Y1 } | Sort-Object)[$k - 1]
    $x2 = @($Boxes | ForEach-Object { $_.X2 } | Sort-Object -Descending)[$k - 1]
    $y2 = @($Boxes | ForEach-Object { $_.Y2 } | Sort-Object -Descending)[$k - 1]
    $x1 = [Math]::Max(0, $x1); $y1 = [Math]::Max(0, $y1)
    $x2 = [Math]::Min($Info.Width, $x2); $y2 = [Math]::Min($Info.Height, $y2)
    New-Box -L $x1 -T $y1 -R ($Info.Width - $x2) -B ($Info.Height - $y2) -Info $Info
}

function Measure-SoftEdge {
    # Profiles: list of byte[] buffers, each holding consecutive frames of $Len bytes (one byte per line).
    # Edge: index of the outermost picture line (per strict crop). Dir: +1 inward from left/top, -1 from right/bottom.
    # Returns how many lines from the edge are consistently darker, plus the darkness rate of the outermost line.
    param($Profiles, [int]$Len, [int]$Edge, [int]$Dir, [int]$Cap, [int]$Span)

    $none = [pscustomobject]@{ Count = 0; OuterPct = $null; Frames = 0 }
    if ($Cap -le 0 -or $Span -lt 2 * ($Cap + $RefWidth)) { return $none }

    $refStart = $Edge + $Dir * $Cap
    $dark = New-Object int[] $Cap
    $bright = 0

    foreach ($buf in $Profiles) {
        for ($off = 0; $off + $Len -le $buf.Length; $off += $Len) {
            $sum = 0
            for ($k = 0; $k -lt $RefWidth; $k++) { $sum += $buf[$off + $refStart + $Dir * $k] }
            $ref = $sum / $RefWidth
            if ($ref -lt $BrightMin) { continue }
            $bright++
            $thr = $ref * $EdgeRatio
            for ($i = 0; $i -lt $Cap; $i++) {
                if ($buf[$off + $Edge + $Dir * $i] -lt $thr) { $dark[$i]++ }
            }
        }
    }
    if ($bright -lt $MinBrightFrames) { return [pscustomobject]@{ Count = 0; OuterPct = $null; Frames = $bright } }

    $n = 0
    while ($n -lt $Cap -and $dark[$n] -ge $EdgeConsistency * $bright) { $n++ }
    [pscustomobject]@{ Count = $n; OuterPct = [int](100 * $dark[0] / $bright); Frames = $bright }
}

function Get-ContentBoxes {
    param([string]$Path, $Info)

    $strictBoxes = New-Object System.Collections.Generic.List[object]
    $colProfiles = New-Object System.Collections.Generic.List[byte[]]
    $rowProfiles = New-Object System.Collections.Generic.List[byte[]]

    $points = @()
    for ($p = $StepPercent / 2; $p -lt 100; $p += $StepPercent) { $points += $p }

    $fc = ('[0:v:0]split=2[a][b];' +
           '[a]cropdetect=limit={0}:round=2:reset=0[s];' +
           '[b]format=gray,split=2[c][r];' +
           '[c]scale=w=iw:h=1:flags=area[cp];' +   # one value per column
           '[r]scale=w=1:h=ih:flags=area[rp]') -f $Limit.ToString($inv)

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('cropchk_' + [guid]::NewGuid().ToString('N'))
    $colFile = "$tmp`_cols.raw"; $rowFile = "$tmp`_rows.raw"

    Write-Host "  Scanning $($points.Count) samples " -NoNewline -ForegroundColor DarkGray

    $i = 0
    foreach ($p in $points) {
        $i++
        Write-Progress -Id 2 -ParentId 1 -Activity 'Sampling' -Status ("{0:0.#}% of runtime" -f $p) `
            -PercentComplete ([int](100 * $i / $points.Count))

        $ss = ($Info.Duration * $p / 100).ToString('0.###', $inv)
        $nf = "$FramesPerSample"
        $ffArgs = @('-hide_banner', '-nostats', '-loglevel', 'info', '-y')
        if ($HwDecode) { $ffArgs += @('-hwaccel', 'cuda') }
        $ffArgs += @('-ss', $ss, '-i', $Path, '-filter_complex', $fc,
                     '-map', '[s]',  '-frames:v', $nf, '-f', 'null', '-',
                     '-map', '[cp]', '-frames:v', $nf, '-f', 'rawvideo', $colFile,
                     '-map', '[rp]', '-frames:v', $nf, '-f', 'rawvideo', $rowFile)

        $lines = & ffmpeg @ffArgs 2>&1 | ForEach-Object { "$_" }

        $last = $null
        foreach ($l in $lines) {
            if ($l -match 'crop=(-?\d+):(-?\d+):(-?\d+):(-?\d+)') {
                $w = [int]$Matches[1]; $h = [int]$Matches[2]
                if ($w -le 0 -or $h -le 0) { continue }
                $x = [int]$Matches[3]; $y = [int]$Matches[4]
                $last = [pscustomobject]@{ X1 = $x; Y1 = $y; X2 = $x + $w; Y2 = $y + $h }
            }
        }
        if ($last) {
            $strictBoxes.Add($last)
            Write-Host '.' -NoNewline -ForegroundColor DarkGray
        } else {
            Write-Host 'x' -NoNewline -ForegroundColor DarkYellow   # black sample or ffmpeg problem
        }

        foreach ($pair in @(@($colFile, $colProfiles), @($rowFile, $rowProfiles))) {
            if ([IO.File]::Exists($pair[0])) {
                $pair[1].Add([IO.File]::ReadAllBytes($pair[0]))
                Remove-Item -LiteralPath $pair[0] -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Write-Progress -Id 2 -Activity 'Sampling' -Completed
    Write-Host ''

    if ($strictBoxes.Count -eq 0) {
        # Show the tail of ffmpeg's output so a real ffmpeg error isn't hidden.
        Write-Host '  ffmpeg produced no crop data. Last ffmpeg output:' -ForegroundColor Yellow
        $lines | Select-Object -Last 8 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
        return $null
    }
    $strict = Get-Bounds -Boxes $strictBoxes -K $MinSupport -Info $Info

    $capX = [int][Math]::Floor($Info.Width  * $SoftBorderMaxPercent / 100)
    $capY = [int][Math]::Floor($Info.Height * $SoftBorderMaxPercent / 100)
    $W = $Info.Width; $H = $Info.Height

    $eL = Measure-SoftEdge $colProfiles $W $strict.Left                 1 $capX $strict.Width
    $eR = Measure-SoftEdge $colProfiles $W ($W - $strict.Right - 1)     -1 $capX $strict.Width
    $eT = Measure-SoftEdge $rowProfiles $H $strict.Top                  1 $capY $strict.Height
    $eB = Measure-SoftEdge $rowProfiles $H ($H - $strict.Bottom - 1)    -1 $capY $strict.Height

    # 4:2:0 chroma covers 2x2 pixel blocks, so every crop amount (L/T/R/B) must be even. That keeps
    # chroma aligned and, for even source sizes, also makes the width/height even.
    #   Soft (suggested): each side rounded UP   - removes the soft edge fully, may lose 1 line of picture.
    #   Strict:           each side rounded DOWN - keeps all picture, may leave 1 line of black;
    #                     a side with fewer than MinBarPixels of black isn't cropped at all.
    $soft = New-Box -Info $Info `
        -L (ConvertTo-Even ($strict.Left + $eL.Count) -Up) -R (ConvertTo-Even ($strict.Right + $eR.Count) -Up) `
        -T (ConvertTo-Even ($strict.Top + $eT.Count) -Up)  -B (ConvertTo-Even ($strict.Bottom + $eB.Count) -Up)
    # Suggested: trim soft edges only on sides that already have a black bar. Where the picture
    # runs to the frame edge (e.g. full 1920/3840 width), leave the soft edge and keep full size.
    $barred = New-Box -Info $Info `
        -L $(if ($strict.Left   -gt 0) { $soft.Left   } else { 0 }) `
        -R $(if ($strict.Right  -gt 0) { $soft.Right  } else { 0 }) `
        -T $(if ($strict.Top    -gt 0) { $soft.Top    } else { 0 }) `
        -B $(if ($strict.Bottom -gt 0) { $soft.Bottom } else { 0 })

    # Strict also ignores thin bars: a side with fewer than MinBarPixels of solid black is left
    # alone (1-2 stray lines on a disc aren't a letterbox). Soft/Suggested still trim them.
    $bar = { param([int]$v) if ($v -lt $MinBarPixels) { 0 } else { ConvertTo-Even $v } }
    $strict = New-Box -Info $Info `
        -L (& $bar $strict.Left) -R (& $bar $strict.Right) `
        -T (& $bar $strict.Top)  -B (& $bar $strict.Bottom)

    $fmt = { param($e) if ($null -eq $e.OuterPct) { '-' } else { "$($e.OuterPct)%" } }
    [pscustomobject]@{
        Strict   = $strict
        Soft     = $soft
        Barred   = $barred
        Samples  = "$($strictBoxes.Count)/$($points.Count)"
        EdgeDark = 'L{0} R{1} T{2} B{3}' -f (& $fmt $eL), (& $fmt $eR), (& $fmt $eT), (& $fmt $eB)
    }
}

function Format-Bars($b) { "L$($b.Left) R$($b.Right) T$($b.Top) B$($b.Bottom)" }

# ---------------------------------------------------------------- main loop
$results = New-Object System.Collections.Generic.List[object]
$n = 0

foreach ($src in $sources) {
    $n++
    Write-Progress -Id 1 -Activity 'Checking crops' -Status $src.Name -PercentComplete ([int](100 * $n / $sources.Count))

    $rel     = $src.FullName.Substring($srcRoot.Length).TrimStart('\', '/')
    $relBase = [IO.Path]::Combine([IO.Path]::GetDirectoryName($rel), [IO.Path]::GetFileNameWithoutExtension($rel))

    Write-Host "`n[$n/$($sources.Count)] $rel" -ForegroundColor Cyan

    # ---------- analysis-only mode
    if (-not $dstRoot) {
        $sInfo = Get-VideoInfo $src.FullName
        if (-not $sInfo -or $sInfo.Duration -le 0) { Write-Host '  [ERROR] ffprobe failed' -ForegroundColor Red; continue }
        Write-Host "  Source    : $($sInfo.Width)x$($sInfo.Height), $([TimeSpan]::FromSeconds([int]$sInfo.Duration))" -ForegroundColor DarkGray
        $boxes = Get-ContentBoxes -Path $src.FullName -Info $sInfo
        if (-not $boxes) { Write-Host '  [UNKNOWN] could not detect (all samples black?)' -ForegroundColor Yellow; continue }
        $so = $boxes.Soft; $st = $boxes.Strict; $sg = $boxes.Barred
        if ($Plumbing) {
            # Top level: the Suggested crop (as before). Crops: all three, so a caller can pick one
            # without another scan.
            $pick = { param($b) [ordered]@{ Width = $b.Width; Height = $b.Height; Left = $b.Left; Top = $b.Top; Right = $b.Right; Bottom = $b.Bottom } }
            [pscustomobject]@{
                File = $src.FullName; SourceWidth = $sInfo.Width; SourceHeight = $sInfo.Height
                Width = $sg.Width; Height = $sg.Height
                Left = $sg.Left; Top = $sg.Top; Right = $sg.Right; Bottom = $sg.Bottom
                Mode = 'Suggested'
                Crops = [ordered]@{ Strict = (& $pick $st); Suggested = (& $pick $sg); Full = (& $pick $so) }
                Samples = $boxes.Samples; EdgeDark = $boxes.EdgeDark
            } | ConvertTo-Json -Compress -Depth 4
            continue
        }
        $line = { param($label, $b, $note, $color)
            Write-Host ("  {0,-10}: {1}x{2}   crop T{3} B{4} L{5} R{6}   (ffmpeg crop={1}:{2}:{5}:{3})   {7}" -f `
                $label, $b.Width, $b.Height, $b.Top, $b.Bottom, $b.Left, $b.Right, $note) -ForegroundColor $color }
        $same = { param($a, $b) $a.Left -eq $b.Left -and $a.Right -eq $b.Right -and $a.Top -eq $b.Top -and $a.Bottom -eq $b.Bottom }

        & $line 'Suggested' $sg 'soft edges trimmed only beside black bars' 'Green'
        if (-not (& $same $so $sg)) { & $line 'Full crop' $so 'all soft edges trimmed' 'DarkGray' }
        if (-not (& $same $st $sg) -and -not (& $same $st $so)) { & $line 'Strict' $st 'no soft edges trimmed' 'DarkGray' }
        Write-Host "  Edge-dark : $($boxes.EdgeDark)   Samples: $($boxes.Samples)" -ForegroundColor DarkGray
        continue
    }

    # ---------- compare mode
    $dest = $null
    foreach ($ext in '.mp4', '.mkv') {
        $candidate = [IO.Path]::Combine($dstRoot, $relBase + $ext)
        if ([IO.File]::Exists($candidate)) { $dest = $candidate; break }
    }

    $row = [ordered]@{
        File = $rel; Status = $null; SourceRes = ''; EncodedRes = ''
        Strict = ''; Soft = ''; StrictBars = ''; SoftBars = ''; Suggested = ''; EdgeDark = ''; Samples = ''
    }

    if (-not $dest) {
        $row.Status = 'No encoded file found'
        $results.Add([pscustomobject]$row); Write-Host '  [MISSING] no matching .mp4/.mkv in Dest' -ForegroundColor DarkGray
        continue
    }
    $row.File = $dest.Substring($dstRoot.Length).TrimStart('\', '/')

    $sInfo = Get-VideoInfo $src.FullName
    $dInfo = Get-VideoInfo $dest
    if (-not $sInfo -or -not $dInfo -or $sInfo.Duration -le 0) {
        $row.Status = 'ffprobe failed'
        $results.Add([pscustomobject]$row); Write-Host '  [ERROR] ffprobe failed' -ForegroundColor Red
        continue
    }
    $row.SourceRes  = "$($sInfo.Width)x$($sInfo.Height)"
    $row.EncodedRes = "$($dInfo.Width)x$($dInfo.Height)"

    $boxes = Get-ContentBoxes -Path $src.FullName -Info $sInfo
    if (-not $boxes) {
        $row.Status = 'Could not detect (all samples black)'
        $results.Add([pscustomobject]$row); Write-Host '  [UNKNOWN] could not detect' -ForegroundColor Yellow
        continue
    }
    $st = $boxes.Strict; $so = $boxes.Soft
    $row.Strict     = "$($st.Width)x$($st.Height)"
    $row.Soft       = "$($so.Width)x$($so.Height)"
    $row.StrictBars = Format-Bars $st
    $row.SoftBars   = Format-Bars $so
    $row.EdgeDark   = $boxes.EdgeDark
    $row.Samples    = $boxes.Samples
    $sg = $boxes.Barred
    $row.Suggested  = "$($sg.Width)x$($sg.Height) (T$($sg.Top) B$($sg.Bottom) L$($sg.Left) R$($sg.Right))"

    $W = $dInfo.Width; $H = $dInfo.Height; $t = $Tolerance
    $exact    = [Math]::Abs($W - $st.Width) -le $t -and [Math]::Abs($H - $st.Height) -le $t
    $tooSmall = $W -lt $so.Width - $t -or $H -lt $so.Height - $t
    $tooBig   = $W -gt $st.Width + $t -or $H -gt $st.Height + $t

    $row.Status =
        if ($exact)                               { 'OK' }
        elseif (-not $tooSmall -and -not $tooBig) { 'OK (soft edge trimmed)' }
        elseif ($tooSmall -and -not $tooBig)      { 'Over-cropped (picture lost)' }
        elseif ($tooBig -and -not $tooSmall)      { 'Under-cropped (black bars remain)' }
        else                                      { 'Mismatch (one axis over, one under / scaled?)' }

    $color = if ($row.Status -like 'OK*') { 'Green' } else { 'Red' }
    Write-Host ("  [{0}]  encoded {1}, expected {2}..{3}  edge-dark {4}" -f `
        $row.Status, $row.EncodedRes, $row.Soft, $row.Strict, $row.EdgeDark) -ForegroundColor $color
    if ($row.Status -notlike 'OK*') { Write-Host "  Suggested : $($row.Suggested)" -ForegroundColor Yellow }
    $results.Add([pscustomobject]$row)
}
Write-Progress -Id 1 -Activity 'Checking crops' -Completed

# ---------------------------------------------------------------- markdown report
if (-not $dstRoot) { return }

function ConvertTo-MdRow { param([object[]]$Cells) '| ' + (($Cells | ForEach-Object { "$_" -replace '\|', '\|' }) -join ' | ') + ' |' }

$cols = 'File', 'Status', 'Source', 'Encoded', 'Suggested crop', 'Expected (soft)', 'Expected (strict)',
        'Bars (soft)', 'Bars (strict)', 'Outer line darker', 'Samples'
$header = @((ConvertTo-MdRow $cols), (ConvertTo-MdRow ($cols | ForEach-Object { '---' })))
function Get-Rows($set) {
    foreach ($r in $set) {
        ConvertTo-MdRow @($r.File, $r.Status, $r.SourceRes, $r.EncodedRes, $r.Suggested, $r.Soft, $r.Strict,
                          $r.SoftBars, $r.StrictBars, $r.EdgeDark, $r.Samples)
    }
}

$bad  = @($results | Where-Object { $_.Status -notlike 'OK*' })
$good = @($results | Where-Object { $_.Status -like 'OK*' })
$elapsed = (Get-Date) - $started

$md = New-Object System.Collections.Generic.List[string]
$md.Add("# Crop check report - $($started.ToString('yyyy-MM-dd HH:mm'))")
$md.Add('')
$md.Add("- **Source:** ``$srcRoot``")
$md.Add("- **Encoded:** ``$dstRoot``")
$md.Add("- **Settings:** step $StepPercent%, $FramesPerSample frames/sample, limit $Limit, soft max $SoftBorderMaxPercent%/side, edge ratio $EdgeRatio, edge consistency $EdgeConsistency, bright min $BrightMin, min support $MinSupport, tolerance ${Tolerance}px$(if ($HwDecode) { ', NVDEC' })")
$md.Add("- **Result:** $($bad.Count) of $($results.Count) files need attention (elapsed $($elapsed.ToString('hh\:mm\:ss')))")
$md.Add("- **Outer line darker:** % of bright frames in which the outermost picture line was darker than the picture just inside it. Trimmed when >= $([int]($EdgeConsistency * 100))%.")
$md.Add('')
$md.Add("## Needs attention ($($bad.Count))")
$md.Add('')
if ($bad.Count) { $header | ForEach-Object { $md.Add($_) }; Get-Rows $bad | ForEach-Object { $md.Add($_) } }
else { $md.Add('_None_') }
$md.Add('')
$md.Add("## OK ($($good.Count))")
$md.Add('')
if ($good.Count) { $header | ForEach-Object { $md.Add($_) }; Get-Rows $good | ForEach-Object { $md.Add($_) } }
else { $md.Add('_None_') }

$reportDir = Split-Path -Parent $ReportPath
if ($reportDir -and -not (Test-Path -LiteralPath $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
[IO.File]::WriteAllLines($ReportPath, $md, (New-Object System.Text.UTF8Encoding $false))

Write-Host "`n$($bad.Count) of $($results.Count) files need attention."
Write-Host "Report written to $ReportPath"
