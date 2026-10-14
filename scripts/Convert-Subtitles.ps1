<#
.SYNOPSIS
    Makes Jellyfin-named .srt subtitles for an encoded title from its source MKV's English
    subtitle tracks: OCR with Subtitle Edit's command line (seconv, PaddleOCR), works out which
    track is the main one, the forced one and any commentary, and shifts them to match the
    encode. Built for Windows PowerShell 5.1.

.DESCRIPTION
    Steps:
      1. Backup: every subtitle track of -Source (all languages, unchanged) goes into one
         Matroska subtitle file, "<name>.mks" in -Dest (skipped with -NoBackup, or when
         -Source is already an .mks). An existing backup with the same number of subtitle
         tracks is reused.
      2. Each English subtitle track is extracted (mkvextract) and converted to .srt by seconv:
           seconv <track> subrip --json --overwrite --ocr-engine:paddle --ocr-language:en
             --encoding:utf-8 --remove-text-for-hi
             --fix-common-errors-rules:all,-FixDialogsOnOneLine,-FixShortLinesAll,-FixShortLinesPixelWidth
             --multiple-replace:<-ReplaceRules>
         Picture tracks (Blu-ray PGS; DVD VobSub should work but is untested) are OCR'd; text
         tracks (SRT, ASS) are just converted.
      3. Each track gets a role (see "Which track is which" below).
      4. Written to -Dest, named "<name>" = -Basename (the finished video's name, without .mkv):
           <name>.en.srt                  the main subtitles
           <name>.en.forced.default.srt   forced subtitles (only forced ones are marked default)
           <name>.en.Commentary.srt       a commentary track ("<name>.en.Commentary 2.srt", ... for more)
         Every cue is moved by -OffsetMs (Encode-Batch passes Add-BluRayAudio's SyncMs, the
         shift it gave the audio to match the encode). With no offset the files are exactly
         what seconv wrote. Older "<name>.en*.srt" files from an earlier run are replaced.

    Which track is which (the Default and Forced flags are trusted when they're set; most
    sources have neither, so the text decides):
      - One track: the main one (the forced one, if it has the Forced flag).
      - Forced flag: forced. Default flag without Forced: main.
      - Much shorter than the longest track (under -SmallPct of its letters): a forced
        candidate. With several, the one whose lines appear in the main track wins.
      - Tracks with mostly the same lines (e.g. main and SDH, which match once the
        hearing-impaired text is removed) are duplicates: the Default one, else the one not
        named SDH/CC, else the earliest is kept.
      - Different text: the main one is the one with the Default flag; else the one not named
        "commentary"; else the one containing the forced track's lines; else the earliest, if
        the later one is longer (commentary usually has more text than the film). The others
        are commentary.
      - Anything left unsure is flagged for review: the best guess is still written, and every
        track's .srt goes to "_subtitles review\<name>\" in -Dest, labelled with its
        track number and guessed role, for you to pick from. Encode-Batch lists these at the
        top of its report.

    Needs: mkvmerge and mkvextract (MKVToolNix; on PATH or in "C:\Program Files\MKVToolNix"),
    seconv.exe (Subtitle Edit 5's command line), and PaddleOCR on PATH for seconv.

.PARAMETER Source
    Required. The source MKV (or a "<name>.mks" backup made earlier).
.PARAMETER Dest
    The folder the subtitles (and the .mks backup) go in, usually the finished video's.
    Default: -Source's folder.
.PARAMETER Basename
    The name the files get: the finished video's file name without ".mkv", e.g.
    "Movie (2020) - 2160p" -> "Movie (2020) - 2160p.en.srt".
    Default: -Source's file name without its extension.
.PARAMETER OffsetMs
    Shift every cue by this many milliseconds (negative = earlier). Cues that would end at or
    before 0 are dropped. Default: 0.
.PARAMETER NoBackup
    Don't write the "<name>.mks" backup.
.PARAMETER SeConv
    seconv.exe. Default: "$HOME\Documents\SeConv-Windows-x64\seconv.exe".
.PARAMETER ReplaceRules
    Subtitle Edit multiple replace rules for seconv --multiple-replace.
    Default: "$HOME\Documents\SE_Replace_Rules.template" (skipped, with a warning, if missing).
    Kept out of seconv's folder so upgrading seconv doesn't wipe it.
.PARAMETER SmallPct
    A track with fewer letters than this % of the longest track is a forced candidate. Default: 20.
.PARAMETER TimeoutMin
    A tool (seconv, mkvmerge, mkvextract) still running after this many minutes is stopped:
    that track fails (the title is flagged for review), or the run fails. Default: 30.
.PARAMETER WorkDir
    Where the extracted tracks and seconv's output go while working (deleted afterwards).
    Default: your temp folder.
.PARAMETER LogPath
    Log file (added to if it exists). Default: none (shown on screen only).
.PARAMETER Plumbing
    For other scripts (Encode-Batch uses it): nothing is shown, and stdout gets one line of JSON:
      Status        Done, Review (written, but check them), None (no English subtitles) or Failed
      Message       what happened, or why it failed
      OffsetMs      the shift applied
      BackupMks     the backup file ('' if none)
      Outputs       Role (main, forced, commentary), File, Cues, Track (track number)
      Tracks        every subtitle track: Order, Id (the track number, MediaInfo's "ID"), Language, Codec, Name, Default, Forced,
                    Cues, Letters, Role (main, forced, commentary, duplicate, unknown, skipped),
                    Reason
      Review        true when a person should check; ReviewReason says why; ReviewDir has
                    every track's .srt
      Warnings      warnings
      LogPath       the log
    Exit code: 0, or 1 if it failed.

.EXAMPLE
    .\Convert-Subtitles.ps1 -Source 'D:\work\Movie (2020) - source.mkv' -Dest 'L:\Library\Movies\Movie (2020)' -Basename 'Movie (2020)' -OffsetMs -42
.EXAMPLE
    .\Convert-Subtitles.ps1 -Source 'L:\Library\Movies\Movie (2020)\Movie (2020).mks'
    Redo the subtitles from the backup (same folder and name as the .mks).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Source,
    [string]$Dest = '',
    [string]$Basename = '',
    [int]$OffsetMs = 0,
    [switch]$NoBackup,
    [string]$SeConv = (Join-Path $HOME 'Documents\SeConv-Windows-x64\seconv.exe'),
    [string]$ReplaceRules = (Join-Path $HOME 'Documents\SE_Replace_Rules.template'),
    [ValidateRange(1, 90)][int]$SmallPct = 20,
    [ValidateRange(1, 1440)][int]$TimeoutMin = 30,
    [string]$WorkDir = '',
    [string]$LogPath = '',
    [switch]$Plumbing
)

$ErrorActionPreference = 'Stop'
$script:RulesGiven = $PSBoundParameters.ContainsKey('ReplaceRules')
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# ---- Tunables
$SameTextShare  = 0.5    # tracks sharing at least this share of their 3-word phrases have the same text
$SameSizeRatio  = 0.5    # ...and the smaller has at least this share of the larger's letters
$ForcedInMain   = 0.3    # a forced track whose phrases are at least this share in a track: that's the main one
$LongerLater    = 1.1    # two different full tracks, no other clue: the earlier is main if the later is this much longer
$LangCodes      = @('eng', 'en')   # mkvmerge language / language_ietf values counted as English
$FileLang       = 'en'             # language tag in the file names

# ================================================================ log

$script:LogLines = [Collections.Generic.List[string]]::new()
$script:Warnings = [Collections.Generic.List[string]]::new()
$script:LogLines.Add(('Convert-Subtitles {0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date)))

# The log file is written as it goes (not just at the end), so a run that's stopped or hangs
# still shows how far it got.
$script:LogFlushed = 0
$script:LogStarted = $false
function Sync-Log {
    if (-not $LogPath -or $script:LogFlushed -ge $script:LogLines.Count) { return }
    try {
        $new = [Collections.Generic.List[string]]::new()
        if (-not $script:LogStarted) {
            $d = [IO.Path]::GetDirectoryName($LogPath)
            if ($d -and -not [IO.Directory]::Exists($d)) { [void][IO.Directory]::CreateDirectory($d) }
            if ([IO.File]::Exists($LogPath)) { $new.Add(''); $new.Add('') }
            $script:LogStarted = $true
        }
        for ($i = $script:LogFlushed; $i -lt $script:LogLines.Count; $i++) { $new.Add($script:LogLines[$i]) }
        [IO.File]::AppendAllLines($LogPath, [string[]]$new, [Text.UTF8Encoding]::new($false))
        $script:LogFlushed = $script:LogLines.Count
    } catch {
        if (-not $Plumbing) { Microsoft.PowerShell.Utility\Write-Warning "Could not write the log to ${LogPath}: $($_.Exception.Message)" }
    }
}
function Write-Log([string]$Text, [string]$Color = '') {
    $stamp = '{0:HH:mm:ss}  ' -f (Get-Date)
    foreach ($l in ($Text -split "`r?`n")) { $script:LogLines.Add($stamp + $l) }
    if (-not $Plumbing) {
        if ($Color) { Microsoft.PowerShell.Utility\Write-Host $Text -ForegroundColor $Color }
        else { Microsoft.PowerShell.Utility\Write-Host $Text }
    }
    Sync-Log
}
function Write-Warn([string]$Text) {
    $script:Warnings.Add($Text)
    $script:LogLines.Add(('{0:HH:mm:ss}  WARNING: {1}' -f (Get-Date), $Text))
    if (-not $Plumbing) { Microsoft.PowerShell.Utility\Write-Warning $Text }
    Sync-Log
}

# One command line from separate arguments (Windows quoting rules).
function Join-Args([string[]]$ArgList) {
    ($ArgList | ForEach-Object {
        $a = [string]$_
        if ($a -eq '') { '""' }
        elseif ($a -notmatch '[\s"]') { $a }
        else { '"' + (($a -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
    }) -join ' '
}

# Runs a tool and returns its stdout lines; everything it prints goes to the log, and its exit
# code to $LASTEXITCODE. Its input is empty and closed: under Encode-Batch this script runs in a
# background job, and a tool that inherits the job's input (seconv does) waits on it forever.
# A tool still running after -TimeoutMin minutes is stopped (with anything it started) and
# counts as failed.
function Invoke-Tool([string]$Exe, [string[]]$ArgList, [switch]$QuietStdout) {
    $cmdLine = Join-Args $ArgList
    $script:LogLines.Add(('{0:HH:mm:ss}  > {1} {2}' -f (Get-Date), [IO.Path]::GetFileName($Exe), $cmdLine))
    Sync-Log
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $cmdLine
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    if ($script:Work -and [IO.Directory]::Exists($script:Work)) { $psi.WorkingDirectory = $script:Work }
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    # Both streams read in the background (no PowerShell callbacks), so neither can fill up and block.
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $timedOut = -not $p.WaitForExit([int]([Math]::Min([double]$TimeoutMin * 60000, [double][int]::MaxValue)))
    if ($timedOut) {
        try {
            if ($env:OS -eq 'Windows_NT') { & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null } else { $p.Kill() }
        } catch { }
        [void]$p.WaitForExit(10000)
    }
    $p.WaitForExit()   # (also waits for the output to be read to the end)
    $code = $(if ($timedOut) { -1 } else { $p.ExitCode })
    $out = [Collections.Generic.List[string]]::new()
    foreach ($pair in @(@($outTask, $false), @($errTask, $true))) {
        $text = ''
        try { if ($pair[0].Wait(10000)) { $text = $pair[0].Result } } catch { }
        foreach ($l in ($text -split "`r?`n|`r")) {
            if (-not $pair[1]) { $out.Add($l) }
            if ($QuietStdout -and -not $pair[1]) { continue }
            if ($l.Trim() -and $l -notmatch '^\s*(Progress: \d+%|\d+%$)') { $script:LogLines.Add("    $l") }
        }
    }
    if ($timedOut) { $script:LogLines.Add(('{0:HH:mm:ss}  {1} was still running after {2} min: stopped' -f (Get-Date), [IO.Path]::GetFileName($Exe), $TimeoutMin)) }
    $p.Dispose()
    Sync-Log
    $global:LASTEXITCODE = $code
    if ($timedOut) { throw "$([IO.Path]::GetFileName($Exe)) was still running after $TimeoutMin min, so it was stopped" }
    return , $out.ToArray()
}

# ================================================================ helpers

function Get-Tool([string]$Name) {
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    foreach ($d in @("$env:ProgramFiles\MKVToolNix", "${env:ProgramFiles(x86)}\MKVToolNix")) {
        $f = Join-Path $d "$Name.exe"
        if ($d -and [IO.File]::Exists($f)) { return $f }
    }
    throw "'$Name' was not found on PATH or in C:\Program Files\MKVToolNix. Install MKVToolNix or add its folder to PATH."
}

function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-SubTracks([string]$File) {
    $lines = Invoke-Tool $script:mkvmerge @('-J', $File) -QuietStdout
    if ($LASTEXITCODE -ne 0) { throw "mkvmerge couldn't read $File (exit code $LASTEXITCODE)" }
    $info = ($lines -join "`n") | ConvertFrom-Json
    $order = 0
    foreach ($t in @($info.tracks)) {
        if ($t.type -ne 'subtitles') { continue }
        $order++
        $p = $t.properties
        $num = Get-Prop $p 'number'   # the track number MediaInfo shows as "ID"; mkvmerge's own IDs start at 0
        if ($null -eq $num) { $num = [int]$t.id + 1 }
        $lang = [string](Get-Prop $p 'language')
        $ietf = [string](Get-Prop $p 'language_ietf')
        [pscustomobject]@{
            Order = $order; Id = [int]$num; ExtractId = [int]$t.id; Codec = [string](Get-Prop $p 'codec_id'); CodecName = [string]$t.codec
            Language = $(if ($lang) { $lang } else { $ietf }); Ietf = $ietf
            Name = [string](Get-Prop $p 'track_name')
            Default = [bool](Get-Prop $p 'default_track'); Forced = [bool](Get-Prop $p 'forced_track')
            Srt = ''; Cues = 0; Letters = 0; Shingles = $null; Role = ''; Reason = ''; Group = -1
        }
    }
}

# Extension mkvextract should write a subtitle codec as (and seconv read), or '' if unsupported.
function Get-SubExtension([string]$Codec) {
    switch -Regex ($Codec) {
        '^S_HDMV/PGS'   { return '.sup' }
        '^S_VOBSUB'     { return '.sub' }
        '^S_TEXT/UTF8'  { return '.srt' }
        '^S_TEXT/ASS'   { return '.ass' }
        '^S_TEXT/SSA'   { return '.ssa' }
        '^S_TEXT/WEBVTT' { return '.vtt' }
    }
    return ''
}

# ---- .srt reading and writing

function ConvertFrom-SrtTime([string]$T) {
    $m = [regex]::Match($T, '^(\d+):(\d\d):(\d\d)[,.](\d{1,3})$')
    if (-not $m.Success) { return $null }
    $ms = $m.Groups[4].Value.PadRight(3, '0')
    return ([int64]$m.Groups[1].Value * 3600000) + ([int64]$m.Groups[2].Value * 60000) + ([int64]$m.Groups[3].Value * 1000) + [int64]$ms
}
function ConvertTo-SrtTime([int64]$Ms) {
    if ($Ms -lt 0) { $Ms = 0 }
    $h = [Math]::Floor($Ms / 3600000); $Ms -= $h * 3600000
    $m = [Math]::Floor($Ms / 60000); $Ms -= $m * 60000
    $s = [Math]::Floor($Ms / 1000); $Ms -= $s * 1000
    return '{0:00}:{1:00}:{2:00},{3:000}' -f $h, $m, $s, $Ms
}

# Cues of an .srt: Start, End (ms) and Text (lines joined with `n).
function Read-Srt([string]$Path) {
    $text = [IO.File]::ReadAllText($Path) -replace "`r`n?", "`n"
    $cues = [Collections.Generic.List[object]]::new()
    foreach ($block in ($text -split "`n\s*`n")) {
        $lines = @($block -split "`n" | Where-Object { $_ -ne '' })
        $i = 0
        while ($i -lt $lines.Count -and $lines[$i] -notmatch '-->') { $i++ }
        if ($i -ge $lines.Count) { continue }
        $m = [regex]::Match($lines[$i], '^\s*(\S+)\s*-->\s*(\S+)')
        if (-not $m.Success) { continue }
        $s = ConvertFrom-SrtTime $m.Groups[1].Value
        $e = ConvertFrom-SrtTime $m.Groups[2].Value
        if ($null -eq $s -or $null -eq $e) { continue }
        $body = @()
        if ($i + 1 -lt $lines.Count) { $body = $lines[($i + 1)..($lines.Count - 1)] }
        $cues.Add([pscustomobject]@{ Start = [int64]$s; End = [int64]$e; Text = ($body -join "`n") })
    }
    return , $cues.ToArray()
}

# Writes cues shifted by $Shift ms (cues ending at or before 0 dropped, starts clamped at 0).
# Returns the number of cues written.
function Write-ShiftedSrt([string]$From, [string]$To, [int]$Shift) {
    if ($Shift -eq 0) {
        Copy-Item -LiteralPath $From -Destination $To -Force
        return (Read-Srt $To).Count
    }
    $bytes = [IO.File]::ReadAllBytes($From)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $sb = [Text.StringBuilder]::new()
    $n = 0
    foreach ($c in (Read-Srt $From)) {
        $s = $c.Start + $Shift; $e = $c.End + $Shift
        if ($e -le 0) { continue }
        if ($s -lt 0) { $s = 0 }
        $n++
        [void]$sb.Append("$n`r`n$(ConvertTo-SrtTime $s) --> $(ConvertTo-SrtTime $e)`r`n$($c.Text -replace "`n", "`r`n")`r`n`r`n")
    }
    [IO.File]::WriteAllText($To, $sb.ToString(), [Text.UTF8Encoding]::new($bom))
    return $n
}

# ---- comparing tracks

# The set of 3-word phrases (lower case, letters and digits only) in the cues' text.
function Get-Shingles($Cues) {
    $set = [Collections.Generic.HashSet[string]]::new()
    $words = [Collections.Generic.List[string]]::new()
    foreach ($c in $Cues) {
        foreach ($w in ([regex]::Replace($c.Text.ToLowerInvariant(), '<[^>]*>|\{[^}]*\}', ' ') -split '[^\p{L}\p{N}'']+')) {
            $w = $w.Trim("'")
            if ($w) { $words.Add($w) }
        }
    }
    if ($words.Count -lt 3) { foreach ($w in $words) { [void]$set.Add($w) }; return , $set }
    for ($i = 0; $i -le $words.Count - 3; $i++) { [void]$set.Add($words[$i] + ' ' + $words[$i + 1] + ' ' + $words[$i + 2]) }
    return , $set
}
function Get-Letters($Cues) {
    $n = 0
    foreach ($c in $Cues) { $n += [regex]::Matches($c.Text, '\p{L}').Count }
    return $n
}
# Share of A's phrases that are also in B (0..1).
function Get-Containment($A, $B) {
    if ($null -eq $A -or $null -eq $B -or $A.Count -eq 0) { return 0.0 }
    $hit = 0
    foreach ($s in $A) { if ($B.Contains($s)) { $hit++ } }
    return [double]$hit / $A.Count
}
# Same text: most of the smaller one's phrases are in the larger, and they're of a similar size.
function Test-SameText($A, $B) {
    $small = $A; $big = $B
    if ($A.Letters -gt $B.Letters) { $small = $B; $big = $A }
    if ($big.Letters -le 0) { return $false }
    if (([double]$small.Letters / $big.Letters) -lt $SameSizeRatio) { return $false }
    return (Get-Containment $small.Shingles $big.Shingles) -ge $SameTextShare
}

# ================================================================ which track is which

# $Tracks: the OCR'd tracks (Order, Id, Name, Default, Forced, Cues, Letters, Shingles).
# Sets each one's Role (main, forced, commentary, duplicate, unknown) and Reason; returns
# Review (bool) and ReviewReasons.
function Set-SubtitleRoles($Tracks) {
    $reasons = [Collections.Generic.List[string]]::new()
    $use = @($Tracks | Where-Object { $_.Cues -gt 0 } | Sort-Object Order)
    foreach ($t in @($Tracks | Where-Object { $_.Cues -le 0 })) { $t.Role = 'unknown'; $t.Reason = 'no text came out of it' }
    if ($use.Count -eq 0) { return [pscustomobject]@{ Review = $false; ReviewReasons = @() } }
    if ($use.Count -eq 1) {
        $t = $use[0]
        if ($t.Forced) { $t.Role = 'forced'; $t.Reason = 'the only track, flagged Forced' }
        else { $t.Role = 'main'; $t.Reason = 'the only track' }
        return [pscustomobject]@{ Review = $false; ReviewReasons = @() }
    }

    $max = ($use | Measure-Object Letters -Maximum).Maximum
    $isComment = { param($t) $t.Name -match 'comment' }
    $isSdh = { param($t) $t.Name -match '\b(SDH|CC|HI|hearing)\b' }

    # Forced candidates: flagged Forced; otherwise the much shorter tracks.
    $forcedFlagged = @($use | Where-Object { $_.Forced })
    $small = @($use | Where-Object { -not $_.Forced -and -not ($_.Default) -and -not (& $isComment $_) -and $_.Letters -lt ($max * $SmallPct / 100.0) })
    $full = @($use | Where-Object { -not $_.Forced -and $small -notcontains $_ })

    # Full tracks with the same text are one group (e.g. main and SDH).
    $groups = [Collections.Generic.List[object]]::new()
    foreach ($t in $full) {
        $g = $null
        foreach ($cand in $groups) { if (Test-SameText $t $cand[0]) { $g = $cand; break } }
        if ($g) { $g.Add($t) } else { $l = [Collections.Generic.List[object]]::new(); $l.Add($t); $groups.Add($l) }
    }
    # Each group's kept track: the Default one, else one not named SDH/CC, else the earliest.
    $reps = @(foreach ($g in $groups) {
        $rep = @($g | Where-Object { $_.Default } | Sort-Object Order | Select-Object -First 1)
        if (-not $rep) { $rep = @($g | Where-Object { -not (& $isSdh $_) } | Sort-Object Order | Select-Object -First 1) }
        if (-not $rep) { $rep = @($g | Sort-Object Order | Select-Object -First 1) }
        $rep = $rep[0]
        foreach ($o in $g) { if ($o -ne $rep) { $o.Role = 'duplicate'; $o.Reason = "same text as track $($rep.Id)" } }
        $rep
    })

    # ---- main
    $main = $null
    $nonComment = @($reps | Where-Object { -not (& $isComment $_) })
    $defaults = @($nonComment | Where-Object { $_.Default })
    if ($defaults.Count -ge 1) {
        $main = $defaults[0]; $main.Reason = 'flagged Default'
        if ($defaults.Count -gt 1) { $reasons.Add("tracks $(($defaults | ForEach-Object { $_.Id }) -join ' and ') are both flagged Default but have different text") }
    } elseif ($nonComment.Count -eq 1) {
        $main = $nonComment[0]
        $main.Reason = $(if ($reps.Count -gt 1) { 'the only full-length track not named commentary' } else { 'the only full-length track' })
    } elseif ($nonComment.Count -gt 1) {
        # The forced track's lines are usually in the main subtitles too (not in commentary).
        $fr = @($forcedFlagged + $small)
        $best = $null; $bestShare = 0.0; $second = 0.0
        foreach ($r in $nonComment) {
            $share = 0.0
            foreach ($f in $fr) { $share = [Math]::Max([double]$share, [double](Get-Containment $f.Shingles $r.Shingles)) }
            if ($share -gt $bestShare) { $second = $bestShare; $bestShare = $share; $best = $r }
            elseif ($share -gt $second) { $second = $share }
        }
        if ($best -and $bestShare -ge $ForcedInMain -and $second -le $bestShare / 2) {
            $main = $best; $main.Reason = ('has the forced lines ({0:0}% of them)' -f ($bestShare * 100))
        } else {
            $main = $nonComment[0]
            $later = @($nonComment | Select-Object -Skip 1)
            $longer = @($later | Where-Object { $_.Letters -ge $main.Letters * $LongerLater })
            if ($nonComment.Count -eq 2 -and $longer.Count -eq 1) {
                $main.Reason = "the earliest; track $($later[0].Id) is longer, so likely commentary"
            } else {
                $main.Reason = 'the earliest (best guess)'
                $reasons.Add(("{0} full-length tracks with different text and nothing to tell the main one by (sizes: {1})" -f
                    $nonComment.Count, (($nonComment | ForEach-Object { "track $($_.Id) $($_.Letters) letters" }) -join ', ')))
            }
        }
    } else {
        $reasons.Add('every full-length track is named commentary; no main subtitles')
    }
    if ($main) { $main.Role = 'main' }
    $comm = @($reps | Where-Object { $_ -ne $main })
    foreach ($c in $comm) {
        $c.Role = 'commentary'
        if (& $isComment $c) { $c.Reason = 'named commentary' }
        elseif (-not $c.Reason) { $c.Reason = 'different text from the main track' }
    }
    if ($comm.Count -gt 2) { $reasons.Add("$($comm.Count) commentary tracks") }

    # ---- forced
    if ($forcedFlagged.Count) {
        $forced = $forcedFlagged[0]
        $forced.Role = 'forced'; $forced.Reason = $(if ($forced.Default) { 'flagged Default and Forced' } else { 'flagged Forced' })
        foreach ($o in @($forcedFlagged | Select-Object -Skip 1)) {
            if (Test-SameText $o $forced) { $o.Role = 'duplicate'; $o.Reason = "same text as track $($forced.Id)" }
            else { $o.Role = 'unknown'; $o.Reason = 'flagged Forced, different text from the first forced track'; $reasons.Add("tracks $($forced.Id) and $($o.Id) are both flagged Forced but have different text") }
        }
        if ($max -gt 0 -and $forced.Letters -gt $max * 0.5) { Write-Warn "Track $($forced.Id) is flagged Forced but is $([Math]::Round(100.0 * $forced.Letters / $max))% the size of the longest track" }
    } elseif ($small.Count) {
        # The candidate whose lines are most in the main track (ties: the earliest).
        $forced = $small[0]
        if ($main -and $small.Count -gt 1) {
            $bestShare = -1.0
            foreach ($s in $small) {
                $share = Get-Containment $s.Shingles $main.Shingles
                if ($share -gt $bestShare) { $bestShare = $share; $forced = $s }
            }
        }
        $forced.Role = 'forced'
        $forced.Reason = ('{0:0}% the size of the longest track' -f (100.0 * $forced.Letters / $max))
        foreach ($o in $small) {
            if ($o -eq $forced) { continue }
            # Same lines as the forced track (allowing for very different sizes of tiny tracks).
            if ((Get-Containment $o.Shingles $forced.Shingles) -ge $SameTextShare -or (Get-Containment $forced.Shingles $o.Shingles) -ge $SameTextShare) {
                $o.Role = 'duplicate'; $o.Reason = "same text as track $($forced.Id)"
            } else {
                $o.Role = 'unknown'; $o.Reason = ('short ({0:0}% of the longest), different text from the forced track' -f (100.0 * $o.Letters / $max))
                $reasons.Add("tracks $($forced.Id) and $($o.Id) are both short with different text; which is forced?")
            }
        }
    }
    foreach ($t in $use) { if (-not $t.Role) { $t.Role = 'unknown'; $t.Reason = 'not placed'; $reasons.Add("track $($t.Id) couldn't be placed") } }
    return [pscustomobject]@{ Review = ($reasons.Count -gt 0); ReviewReasons = @($reasons) }
}

# The file name suffix for a role (".en.srt" etc.); $N = the commentary's number (1 = first).
function Get-SrtSuffix([string]$Role, [int]$N = 1) {
    switch ($Role) {
        'main'       { return ".$FileLang.srt" }
        'forced'     { return ".$FileLang.forced.default.srt" }
        'commentary' { if ($N -le 1) { return ".$FileLang.Commentary.srt" } else { return ".$FileLang.Commentary $N.srt" } }
    }
    return ''
}

# Earlier outputs for this name (".en.srt", ".en.forced.default.srt", ".en.Commentary*.srt").
function Get-OldOutputs([string]$Dir, [string]$Base) {
    if (-not [IO.Directory]::Exists($Dir)) { return @() }
    @([IO.Directory]::GetFiles($Dir, "*.srt") | Where-Object {
        $n = [IO.Path]::GetFileName($_)
        $n.StartsWith("$Base.", [StringComparison]::OrdinalIgnoreCase) -and
            $n.Substring($Base.Length) -match "^\.$FileLang(\.forced\.default|\.Commentary( \d+)?)?\.srt$"
    })
}

# ================================================================ main

if ($MyInvocation.InvocationName -eq '.') { return }   # dot-sourced (tests): functions only

$script:Result = [ordered]@{
    Status = 'Failed'; Message = ''; OffsetMs = $OffsetMs; BackupMks = ''
    Outputs = @(); Tracks = @(); Review = $false; ReviewReason = ''; ReviewDir = ''
    Warnings = @(); LogPath = $LogPath
}
function Write-Result {
    $script:Result.Warnings = @($script:Warnings)
    if ($Plumbing) { [Console]::Out.WriteLine(([pscustomobject]$script:Result | ConvertTo-Json -Depth 5 -Compress)) }
}

$script:Work = ''
$script:SrcTracks = @()
function Invoke-Main {
    $Source = [IO.Path]::GetFullPath($Source)
    if (-not [IO.File]::Exists($Source)) { throw "Source not found: $Source" }
    $destDir = $(if ($Dest) { [IO.Path]::GetFullPath($Dest) } else { [IO.Path]::GetDirectoryName($Source) })
    $base = $(if ($Basename) { $Basename } else { [IO.Path]::GetFileNameWithoutExtension($Source) })
    if ($base -match '[\\/]' -or $base.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw "-Basename isn't a valid file name: $base" }
    if ([IO.File]::Exists($destDir)) { throw "-Dest is a file; give the folder: $destDir" }
    if (-not [IO.Directory]::Exists($destDir)) { throw "Dest folder not found: $destDir" }
    $reviewDir = Join-Path (Join-Path $destDir '_subtitles review') $base
    Write-Log "Subtitles for $base in $destDir (offset $OffsetMs ms)"

    $outputs = [Collections.Generic.List[object]]::new()
    $old = @(Get-OldOutputs $destDir $base)

    # ---------------------------------------------- OCR
    $script:mkvmerge = Get-Tool 'mkvmerge'
    $script:mkvextract = Get-Tool 'mkvextract'

    $srcTracks = @(Get-SubTracks $Source)
    $script:SrcTracks = $srcTracks
    Write-Log "Source: $Source, $($srcTracks.Count) subtitle track(s)"
    foreach ($t in $srcTracks) {
        Write-Log ("  track {0} (#{1}): {2} {3}{4}{5}{6}" -f $t.Id, $t.Order, $t.Language, $t.Codec,
            $(if ($t.Name) { " '$($t.Name)'" }), $(if ($t.Default) { ' [Default]' }), $(if ($t.Forced) { ' [Forced]' }))
    }
    if ($srcTracks.Count -eq 0) {
        foreach ($f in $old) { Remove-Item -LiteralPath $f -Force; Write-Log "Removed old $([IO.Path]::GetFileName($f))" }
        $script:Result.Status = 'None'; $script:Result.Message = 'no subtitle tracks in the source'
        Write-Log $script:Result.Message
        return
    }

    # ---- backup: every subtitle track, unchanged, in <name>.mks
    $readFrom = $Source
    if ([IO.Path]::GetExtension($Source) -eq '.mks') {
        $script:Result.BackupMks = $Source
    } elseif (-not $NoBackup) {
        $mks = Join-Path $destDir "$base.mks"
        $have = $false
        if ([IO.File]::Exists($mks)) {
            try { $have = @(Get-SubTracks $mks).Count -eq $srcTracks.Count } catch { $have = $false }
            if ($have) { Write-Log "Backup $base.mks already there ($($srcTracks.Count) track(s))" }
        }
        if (-not $have) {
            $partial = "$mks.partial"
            [void](Invoke-Tool $script:mkvmerge @('--quiet', '--output', $partial, '--no-video', '--no-audio', '--no-chapters', '--no-attachments', '--no-global-tags', $Source))
            if ($LASTEXITCODE -ge 2) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue; throw "mkvmerge failed backing up the subtitles (exit code $LASTEXITCODE)" }
            $got = @(Get-SubTracks $partial).Count
            if ($got -ne $srcTracks.Count) { throw "The subtitle backup has $got track(s), the source has $($srcTracks.Count). Left for inspection: $partial" }
            Move-Item -LiteralPath $partial -Destination $mks -Force
            Write-Log "Backed up $got subtitle track(s) to $base.mks"
        }
        $script:Result.BackupMks = $mks
        $readFrom = $mks
        # Same tracks in the same order, numbered afresh in the backup (reports keep the source's IDs).
        $inBackup = @(Get-SubTracks $mks)
        if ($inBackup.Count -ne $srcTracks.Count) { throw "$base.mks has $($inBackup.Count) subtitle track(s), the source has $($srcTracks.Count)" }
        for ($i = 0; $i -lt $srcTracks.Count; $i++) { $srcTracks[$i].ExtractId = $inBackup[$i].ExtractId }
    }

    # ---- English tracks: extract and convert
    $eng = [Collections.Generic.List[object]]::new()
    foreach ($t in $srcTracks) {
        $ext = Get-SubExtension $t.Codec
        if ($LangCodes -notcontains $t.Language -and $LangCodes -notcontains $t.Ietf -and -not ($t.Ietf -like 'en-*')) {
            $t.Role = 'skipped'; $t.Reason = "language $($t.Language)"; continue
        }
        if (-not $ext) { $t.Role = 'skipped'; $t.Reason = "can't convert $($t.Codec)"; Write-Warn "Track $($t.Id): can't convert $($t.Codec); skipped"; continue }
        $eng.Add($t)
    }
    Write-Log "$($eng.Count) English track(s) to convert"

    if ($eng.Count -gt 0) {
        $SeConv = [Environment]::ExpandEnvironmentVariables($SeConv)
        if (-not [IO.File]::Exists($SeConv)) { throw "seconv not found: $SeConv (pass -SeConv)" }
        if ($ReplaceRules -and -not [IO.File]::Exists($ReplaceRules)) {
            if ($script:RulesGiven) { throw "-ReplaceRules not found: $ReplaceRules" }
            Write-Warn "No multiple replace rules ($ReplaceRules not found); converting without them"; $ReplaceRules = ''
        }

        $tmpRoot = $(if ($WorkDir) { $WorkDir } else { [IO.Path]::GetTempPath() })
        $work = Join-Path $tmpRoot ("Convert-Subtitles " + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Work = $work
        [void][IO.Directory]::CreateDirectory($work)

        $exArgs = @($readFrom, 'tracks')
        foreach ($t in $eng) { $exArgs += "$($t.ExtractId):$(Join-Path $work ("track$($t.Id)" + (Get-SubExtension $t.Codec)))" }
        [void](Invoke-Tool $script:mkvextract $exArgs)
        if ($LASTEXITCODE -ge 2) { throw "mkvextract failed (exit code $LASTEXITCODE)" }

        foreach ($t in $eng) { try {
            $in = Join-Path $work ("track$($t.Id)" + (Get-SubExtension $t.Codec))
            if (-not [IO.File]::Exists($in)) { throw "mkvextract didn't write track $($t.Id)" }
            $outDir = Join-Path $work "out$($t.Id)"
            [void][IO.Directory]::CreateDirectory($outDir)
            $a = @($in, 'subrip', '--json', "--output-folder:$outDir", '--overwrite', '--ocr-engine:paddle', '--ocr-language:en',
                   '--encoding:utf-8', '--remove-text-for-hi', '--fix-common-errors-rules:all,-FixDialogsOnOneLine,-FixShortLinesAll,-FixShortLinesPixelWidth')
            if ($ReplaceRules) { $a += "--multiple-replace:$ReplaceRules" }
            Write-Log "Converting track $($t.Id) ($($t.Codec))..."
            $started = Get-Date
            $lines = Invoke-Tool $SeConv $a -QuietStdout
            $code = $LASTEXITCODE
            # seconv --json: one JSON object on stdout (anything before it is skipped).
            $json = $null
            for ($i = 0; $i -lt $lines.Count -and -not $json; $i++) {
                if ($lines[$i].TrimStart().StartsWith('{')) {
                    try { $json = ($lines[$i..($lines.Count - 1)] -join "`n") | ConvertFrom-Json } catch { $json = $null }
                }
            }
            $srt = ''
            $errs = [Collections.Generic.List[string]]::new()
            if ($json) {
                foreach ($f in @($json.files)) {
                    if (-not $f.success) { continue }
                    $o = [string]$f.output
                    if ($o -and -not [IO.Path]::IsPathRooted($o)) { $o = Join-Path $outDir ([IO.Path]::GetFileName($o)) }
                    if ($o -and [IO.File]::Exists($o)) { $srt = $o; break }
                }
                foreach ($e in @($json.errors) + @($json.files | ForEach-Object { $_.error })) { if ($e -and $errs -notcontains "$e") { $errs.Add("$e") } }
            }
            if (-not $srt) { $srt = @([IO.Directory]::GetFiles($outDir, '*.srt')) | Select-Object -First 1 }
            if (-not $srt) {
                foreach ($l in $lines) { if ($l.Trim()) { $script:LogLines.Add("    $l") } }
                $why = $(if ($errs.Count) { $errs -join '; ' } else { 'no .srt made' })
                throw "seconv couldn't convert it: $why (exit code $code)"
            }
            foreach ($e in $errs) { Write-Warn "seconv, track $($t.Id): $e" }
            $t.Srt = $srt
            $cues = Read-Srt $srt
            $t.Cues = $cues.Count
            $t.Letters = Get-Letters $cues
            $t.Shingles = Get-Shingles $cues
            Write-Log ("  track {0}: {1} cue(s), {2} letters, {3:0}s" -f $t.Id, $t.Cues, $t.Letters, ((Get-Date) - $started).TotalSeconds)
        } catch {
            # One bad track doesn't stop the rest; the title is flagged for review instead.
            $t.Role = 'failed'; $t.Reason = $_.Exception.Message; $t.Srt = ''
            Write-Warn "Track $($t.Id): $($_.Exception.Message)"
        } }
    }
    $failedTracks = @($eng | Where-Object { $_.Role -eq 'failed' })
    $converted = @($eng | Where-Object { $_.Role -ne 'failed' })
    if ($failedTracks.Count -and -not $converted.Count) {
        throw "No subtitle track could be converted: $(($failedTracks | ForEach-Object { "track $($_.Id): $($_.Reason)" }) -join '; ')"
    }

    # ---- roles
    $decision = Set-SubtitleRoles @($converted)
    foreach ($t in $failedTracks) { $decision.Review = $true; $decision.ReviewReasons = @($decision.ReviewReasons) + "track $($t.Id) couldn't be converted ($($t.Reason))" }
    Write-Log 'Roles:'
    foreach ($t in $srcTracks) {
        Write-Log ("  track {0} (#{1}){2}: {3} - {4}" -f $t.Id, $t.Order, $(if ($t.Name) { " '$($t.Name)'" }), $t.Role, $t.Reason)
    }

    # ---- write
    foreach ($f in $old) { Remove-Item -LiteralPath $f -Force }
    if ($old.Count) { Write-Log "Removed $($old.Count) old subtitle file(s) for $base" }
    $nComm = 0
    foreach ($role in 'main', 'forced', 'commentary') {
        foreach ($t in @($eng | Where-Object { $_.Role -eq $role } | Sort-Object Order)) {
            if ($role -eq 'commentary') { $nComm++ }
            $to = Join-Path $destDir ($base + (Get-SrtSuffix $role $nComm))
            $n = Write-ShiftedSrt $t.Srt $to $OffsetMs
            $outputs.Add([pscustomobject]@{ Role = $role; File = [IO.Path]::GetFileName($to); Cues = $n; Track = $t.Id })
            Write-Log "Wrote $([IO.Path]::GetFileName($to)) (track $($t.Id), $n cue(s))"
        }
    }

    # ---- review: every track's .srt, for picking by hand
    if ([IO.Directory]::Exists($reviewDir)) { Remove-Item -LiteralPath $reviewDir -Recurse -Force }
    if ($decision.Review) {
        [void][IO.Directory]::CreateDirectory($reviewDir)
        foreach ($t in @($eng | Where-Object { $_.Srt })) {
            $label = "track $($t.Id) (#$($t.Order)) - $($t.Role)$(if ($t.Default) { ' [Default]' })$(if ($t.Forced) { ' [Forced]' })"
            [void](Write-ShiftedSrt $t.Srt (Join-Path $reviewDir "$label.srt") $OffsetMs)
        }
        $script:Result.Review = $true
        $script:Result.ReviewReason = ($decision.ReviewReasons -join '; ')
        $script:Result.ReviewDir = $reviewDir
        Write-Log "REVIEW: $($script:Result.ReviewReason)" 'Yellow'
        Write-Log "  Best guess written; every track is in $reviewDir" 'Yellow'
    } else {
        $parent = [IO.Path]::GetDirectoryName($reviewDir)
        if ([IO.Directory]::Exists($parent) -and -not @([IO.Directory]::GetFileSystemEntries($parent)).Count) { Remove-Item -LiteralPath $parent -Force }
    }

    $script:Result.Outputs = @($outputs)
    if ($outputs.Count -eq 0) {
        $script:Result.Status = 'None'
        $script:Result.Message = $(if ($eng.Count) { 'no text in the English subtitle tracks' } else { 'no English subtitle tracks' })
    } else {
        $script:Result.Status = $(if ($decision.Review) { 'Review' } else { 'Done' })
        $script:Result.Message = (($outputs | ForEach-Object { "$($_.Role) (track $($_.Track))" }) -join ', ')
    }
    Write-Log "$($script:Result.Status): $($script:Result.Message)"
}

try {
    Invoke-Main
} catch {
    $script:Result.Status = 'Failed'
    $script:Result.Message = $_.Exception.Message
    Write-Log "FAILED: $($_.Exception.Message)" 'Red'
    $script:LogLines.Add($_.ScriptStackTrace)
} finally {
    if ($script:SrcTracks.Count) {
        $script:Result.Tracks = @($script:SrcTracks | ForEach-Object {
            [ordered]@{ Order = $_.Order; Id = $_.Id; Language = $_.Language; Codec = $_.Codec; Name = $_.Name; Default = $_.Default
                        Forced = $_.Forced; Cues = $_.Cues; Letters = $_.Letters; Role = $_.Role; Reason = $_.Reason }
        })
    }
    if ($script:Work -and [IO.Directory]::Exists($script:Work)) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
    Sync-Log
    Write-Result
}
if ($script:Result.Status -eq 'Failed') { exit 1 }
exit 0
