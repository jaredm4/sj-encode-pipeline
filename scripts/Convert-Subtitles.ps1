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

    Which track is which. Only the Forced flag is trusted (the Default flag is ignored: discs
    set it on whichever track they like); otherwise the tracks' sizes and text decide. "Alike"
    = mostly the same lines and about the same size (e.g. main and SDH/CC once the
    hearing-impaired text is removed). Commentary is always longer than the main track.
      Forced flag set: that track is forced. Of the others:
        1 -> main.  2 alike -> the earlier is main, the other a duplicate (dropped).
        2 different -> the shorter is main, the longer commentary.  More -> review.
      No Forced flag:
        1 track  -> main.
        2 tracks -> the shorter under 25% of the longer: forced + main. Alike: main +
                    duplicate. Otherwise: the shorter is main, the longer commentary.
        3 tracks -> two alike and the third under 50% of them: forced, main (the earlier of
                    the two), duplicate. All different: forced, main, commentary by size
                    (the shortest must be under half the middle one). Otherwise review.
        4 tracks -> exactly two alike (main + duplicate), the other two: the shorter forced,
                    the longer commentary. Otherwise review.
        More     -> review.
      Review: only the tracks that could be named are written, every track's .srt goes to
      "_subtitles review\<name>\" in -Dest, labelled with its track number and role, and
      Encode-Batch lists the title at the top of its report.

    Needs: mkvmerge and mkvextract (MKVToolNix; on PATH or in "C:\Program Files\MKVToolNix"),
    seconv.exe (Subtitle Edit 5's command line), and PaddleOCR on PATH for seconv.

.PARAMETER Source
    Required. The source MKV (or a "<name>.mks" backup made earlier), or a folder: then every
    title in it is done, each written next to itself under its own name: its <name>.mks backup
    if there is one (loose, or inside the folder's subtitles.zip), else its .mkv
    (when it has subtitle tracks). Each title's shift comes from Encode-Batch's
    <name>.final.json next to it (or in the folder's "encode logs.zip"), unless -OffsetMs is given. A summary is shown at the end.
.PARAMETER Recurse
    With a folder as -Source: sub-folders too.
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
    .\Convert-Subtitles.ps1 -Source 'E:\Encodes\Shows' -Recurse
    Redo every title's subtitles under a show (from the .mks backups, zipped or not).
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
    [ValidateRange(1, 1440)][int]$TimeoutMin = 30,
    [string]$WorkDir = '',
    [string]$LogPath = '',
    [switch]$Recurse,
    [switch]$Plumbing
)

$ErrorActionPreference = 'Stop'
$script:RulesGiven = $PSBoundParameters.ContainsKey('ReplaceRules')
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# ---- Tunables
$SameTextShare  = 0.5    # tracks sharing at least this share of their 3-word phrases have the same text
$SameSizeRatio  = 0.8    # ...and the smaller has at least this share of the larger's letters
$TwoTrackForcedPct   = 25   # two tracks: the shorter is forced if it's under this % of the longer
$ThreeTrackForcedPct = 50   # three tracks: the odd one out is forced if it's under this % of the alike two
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
# Review (bool) and ReviewReasons. Only the Forced flag is trusted; otherwise sizes and text:
#   Forced flag set: that's the forced track. Of the rest: one -> main; two alike -> the earlier
#     is main, the other a duplicate (CC/SDH); two different -> the shorter is main, the longer
#     commentary; more -> review (only the forced one is named).
#   No Forced flag:
#     1 track: main.
#     2: the shorter under TwoTrackForcedPct (25%) of the longer -> forced + main; otherwise the
#        shorter is main and the longer commentary (commentary is always longer than the film).
#     3: two alike and the third under ThreeTrackForcedPct (50%) of them -> forced, main (the
#        earlier of the two), duplicate; all three different -> forced, main, commentary by size
#        (shortest first), as long as the shortest is under half the middle one; else review.
#     4: two alike and the other two different from them and each other -> main + duplicate,
#        and the shorter / longer of the other two are forced / commentary; else review.
#     More: review.
# "Alike" = Test-SameText (most of their 3-word phrases shared, sizes within SameSizeRatio).
# Unnamed tracks (role unknown) aren't written; review puts every track in the review folder.
function Set-SubtitleRoles($Tracks) {
    $reasons = [Collections.Generic.List[string]]::new()
    $use = @($Tracks | Where-Object { $_.Cues -gt 0 } | Sort-Object Order)
    foreach ($t in @($Tracks | Where-Object { $_.Cues -le 0 })) { $t.Role = 'unknown'; $t.Reason = 'no text came out of it' }
    $pct = { param($a, $b) if ($b.Letters -gt 0) { 100.0 * $a.Letters / $b.Letters } else { 100.0 } }
    $set = { param($t, [string]$role, [string]$why) $t.Role = $role; $t.Reason = $why }
    $review = { param([string]$why) $reasons.Add($why); foreach ($t in $use) { if (-not $t.Role) { & $set $t 'unknown' 'not named: needs review' } } }
    $describe = { (($use | ForEach-Object { "track $($_.Id) $($_.Letters) letters" }) -join ', ') }
    # One alike pair among $List and the rest (none of them alike with anything), or $null.
    $onePair = {
        param($List)
        $pairs = @()
        for ($i = 0; $i -lt $List.Count; $i++) { for ($j = $i + 1; $j -lt $List.Count; $j++) { if (Test-SameText $List[$i] $List[$j]) { $pairs += , @($List[$i], $List[$j]) } } }
        if ($pairs.Count -ne 1) { return $null }
        $p = $pairs[0]
        [pscustomobject]@{ First = $p[0]; Second = $p[1]; Rest = @($List | Where-Object { $_ -ne $p[0] -and $_ -ne $p[1] }) }
    }
    $done = { [pscustomobject]@{ Review = ($reasons.Count -gt 0); ReviewReasons = @($reasons) } }
    if ($use.Count -eq 0) { return (& $done) }

    # ---- Forced flag: trusted
    $flagged = @($use | Where-Object { $_.Forced })
    if ($flagged.Count) {
        $forced = $flagged[0]
        & $set $forced 'forced' 'flagged Forced'
        $rest = @($use | Where-Object { $_ -ne $forced })
        switch ($rest.Count) {
            0 { }
            1 { & $set $rest[0] 'main' 'the only other track' }
            2 {
                $a = $rest[0]; $b = $rest[1]
                if (Test-SameText $a $b) {
                    & $set $a 'main' 'the earlier of two alike tracks'
                    & $set $b 'duplicate' "same text as track $($a.Id)"
                } else {
                    $sh = $(if ($a.Letters -le $b.Letters) { $a } else { $b }); $lo = $(if ($sh -eq $a) { $b } else { $a })
                    & $set $sh 'main' ('the shorter of the other two ({0:0}% of track {1})' -f (& $pct $sh $lo), $lo.Id)
                    & $set $lo 'commentary' 'the longer of the other two, different text'
                }
            }
            default { & $review "a Forced track plus $($rest.Count) others ($(& $describe)); only the forced one is named" }
        }
        return (& $done)
    }

    # ---- no Forced flag: sizes and text
    $bySize = @($use | Sort-Object Letters, Order)
    switch ($use.Count) {
        1 { & $set $use[0] 'main' 'the only track' }
        2 {
            $sh = $bySize[0]; $lo = $bySize[1]
            $p = & $pct $sh $lo
            if ($p -lt $TwoTrackForcedPct) {
                & $set $sh 'forced' ('{0:0}% of the other track (under {1}%)' -f $p, $TwoTrackForcedPct)
                & $set $lo 'main' 'the longer of two'
            } elseif (Test-SameText $sh $lo) {
                $first = @($use)[0]; $second = @($use)[1]
                & $set $first 'main' 'the earlier of two alike tracks'
                & $set $second 'duplicate' "same text as track $($first.Id)"
            } else {
                & $set $sh 'main' ('the shorter of two ({0:0}% of the other)' -f $p)
                & $set $lo 'commentary' 'the longer of two, different text'
            }
        }
        3 {
            $pr = & $onePair $use
            if ($pr) {
                $third = $pr.Rest[0]
                $big = $(if ($pr.First.Letters -ge $pr.Second.Letters) { $pr.First } else { $pr.Second })
                $p = & $pct $third $big
                if ($p -lt $ThreeTrackForcedPct) {
                    & $set $third 'forced' ('{0:0}% of the two alike tracks (under {1}%)' -f $p, $ThreeTrackForcedPct)
                    & $set $pr.First 'main' 'the earlier of two alike tracks'
                    & $set $pr.Second 'duplicate' "same text as track $($pr.First.Id)"
                } else {
                    & $review ("two alike tracks (tracks $($pr.First.Id), $($pr.Second.Id)) and a third that isn't much shorter (track $($third.Id), {0:0}%)" -f $p)
                }
            } elseif (-not (Test-SameText $use[0] $use[1]) -and -not (Test-SameText $use[0] $use[2]) -and -not (Test-SameText $use[1] $use[2])) {
                $f = $bySize[0]; $m = $bySize[1]; $c = $bySize[2]
                if ((& $pct $f $m) -lt 50) {
                    & $set $f 'forced' ('the shortest of three different tracks ({0:0}% of the main)' -f (& $pct $f $m))
                    & $set $m 'main' 'the middle of three different tracks'
                    & $set $c 'commentary' 'the longest of three different tracks'
                } else {
                    & $review ("three different tracks, but the two shortest are close in size ($(& $describe))")
                }
            } else {
                & $review "three tracks that are all alike, or alike in a chain ($(& $describe))"
            }
        }
        4 {
            $pr = & $onePair $use
            if ($pr -and $pr.Rest.Count -eq 2) {
                $o = @($pr.Rest | Sort-Object Letters, Order)
                & $set $pr.First 'main' 'the earlier of two alike tracks'
                & $set $pr.Second 'duplicate' "same text as track $($pr.First.Id)"
                & $set $o[0] 'forced' 'the shorter of the two other tracks'
                & $set $o[1] 'commentary' 'the longer of the two other tracks'
            } else {
                & $review "four tracks without exactly one alike pair ($(& $describe))"
            }
        }
        default { & $review "$($use.Count) tracks ($(& $describe))" }
    }
    & $done
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
        # (earlier .srt files are left alone: e.g. a finished .mkv has no subtitle tracks, but its
        # .srt files from the backup are still good)
        if ($old.Count) { Write-Log "Left $($old.Count) existing subtitle file(s) for $base as they are" }
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

# One file: everything above, then the summary / plumbing line.
function Invoke-One {
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
        $script:Work = ''
        Sync-Log
    }
}

# The audio shift a finished title's subtitles need, from Encode-Batch's <name>.final.json next
# to it, or inside the folder's "encode logs.zip" (a "- 2160p" title's is <name>.final.json).
# $null if there's none.
function Get-SavedOffset([string]$Dir, [string]$Base) {
    foreach ($b in @($Base, ($Base -replace ' - 2160p$', ''))) {
        $f = Join-Path $Dir "$b.final.json"
        $txt = $null
        if ([IO.File]::Exists($f)) { $txt = [IO.File]::ReadAllText($f) }
        else {
            $z = Join-Path $Dir 'encode logs.zip'
            if ([IO.File]::Exists($z)) {
                try {
                    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
                    $za = [IO.Compression.ZipFile]::OpenRead($z)
                    try {
                        $e = $za.GetEntry("$b.final.json")
                        if ($e) { $sr = New-Object IO.StreamReader($e.Open(), [Text.Encoding]::UTF8); try { $txt = $sr.ReadToEnd() } finally { $sr.Dispose() } }
                    } finally { $za.Dispose() }
                } catch { }
            }
        }
        if ($null -eq $txt) { continue }
        try {
            $d = $txt | ConvertFrom-Json
            if ($d.PSObject.Properties['Audio'] -and $d.Audio) {
                if ($d.Audio.PSObject.Properties['SubtitleShiftMs']) { return [int]$d.Audio.SubtitleShiftMs }
                if ($d.Audio.PSObject.Properties['SyncMs']) { return [int]$d.Audio.SyncMs }
            }
            return 0
        } catch { }
    }
    return $null
}

if (-not [IO.Directory]::Exists($Source)) {
    # ---------------------------------------------- a single .mkv / .mks
    Invoke-One
    Write-Result
    if ($script:Result.Status -eq 'Failed') { exit 1 }
    exit 0
}

# ---------------------------------------------- a folder (and sub-folders with -Recurse)
# Each title once: its <name>.mks backup if there is one (loose, or inside the folder's
# subtitles.zip), else the .mkv itself when it has subtitle tracks (a source folder). Written
# next to it under the same name; the offset comes from its <name>.final.json when there is
# one (Encode-Batch's Dest folders), unless -OffsetMs is given.
if ($Plumbing) { throw '-Plumbing only works with a single file.' }
if ($Basename) { throw '-Basename only works with a single file (a folder''s titles keep their own names).' }
if ($Dest) { throw '-Dest only works with a single file (a folder''s subtitles are written next to each title).' }
$offsetGiven = $PSBoundParameters.ContainsKey('OffsetMs')
$root = [IO.Path]::GetFullPath($Source)
$dirs = @($root)
if ($Recurse) { $dirs += @([IO.Directory]::GetDirectories($root, '*', [IO.SearchOption]::AllDirectories) | Where-Object { $_ -notmatch '[\\/]_subtitles review([\\/]|$)|[\\/]_encode-batch_tmp([\\/]|$)' }) }
$jobs = [Collections.Generic.List[object]]::new()
foreach ($d in ($dirs | Sort-Object)) {
    $names = @{}
    foreach ($f in [IO.Directory]::GetFiles($d, '*.mks')) { $b = [IO.Path]::GetFileNameWithoutExtension($f); $names[$b] = $true; $jobs.Add([pscustomobject]@{ Dir = $d; Base = $b; Path = $f; Zip = '' }) }
    foreach ($z in [IO.Directory]::GetFiles($d, '*subtitles.zip')) {   # "subtitles.zip" (older: "<folder> - subtitles.zip")
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $za = [IO.Compression.ZipFile]::OpenRead($z)
            try {
                foreach ($e in $za.Entries) {
                    if ($e.FullName -notlike '*.mks' -or $e.FullName -match '[\\/]') { continue }
                    $b = [IO.Path]::GetFileNameWithoutExtension($e.FullName)
                    if ($names.ContainsKey($b)) { continue }
                    $names[$b] = $true
                    $jobs.Add([pscustomobject]@{ Dir = $d; Base = $b; Path = ''; Zip = $z; Entry = $e.FullName })
                }
            } finally { $za.Dispose() }
        } catch { Write-Warn "Couldn't read ${z}: $($_.Exception.Message)" }
    }
    foreach ($f in [IO.Directory]::GetFiles($d, '*.mkv')) {
        $b = [IO.Path]::GetFileNameWithoutExtension($f)
        if ($names.ContainsKey($b) -or $f -match '\.(remux|partial)\.mkv$') { continue }
        $jobs.Add([pscustomobject]@{ Dir = $d; Base = $b; Path = $f; Zip = ''; Mkv = $true })
    }
}
Write-Log "$($jobs.Count) title(s) under $root$(if (-not $Recurse) { ' (sub-folders not included; add -Recurse)' })"
$summary = [Collections.Generic.List[string]]::new()
$counts = @{ Done = 0; Review = 0; None = 0; Failed = 0 }
$tmpRoot = $(if ($WorkDir) { $WorkDir } else { [IO.Path]::GetTempPath() })
$n = 0
foreach ($j in $jobs) {
    $n++
    $extracted = ''
    $script:Warnings = [Collections.Generic.List[string]]::new()
    $script:SrcTracks = @()
    $script:Result = [ordered]@{
        Status = 'Failed'; Message = ''; OffsetMs = 0; BackupMks = ''
        Outputs = @(); Tracks = @(); Review = $false; ReviewReason = ''; ReviewDir = ''
        Warnings = @(); LogPath = $LogPath
    }
    $off = $OffsetMs
    if (-not $offsetGiven) { $saved = Get-SavedOffset $j.Dir $j.Base; if ($null -ne $saved) { $off = $saved } }
    Write-Log ("`n==== [{0}/{1}] {2}{3}" -f $n, $jobs.Count, (Join-Path $j.Dir $j.Base), $(if ($j.Zip) { ' (.mks from ' + [IO.Path]::GetFileName($j.Zip) + ')' })) 'Cyan'
    try {
        $src = $j.Path
        if ($j.Zip) {
            $extracted = Join-Path $tmpRoot ("Convert-Subtitles " + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.mks')
            $za = [IO.Compression.ZipFile]::OpenRead($j.Zip)
            try { [IO.Compression.ZipFileExtensions]::ExtractToFile($za.GetEntry($j.Entry), $extracted) } finally { $za.Dispose() }
            $src = $extracted
        }
        $script:Source = $src; $script:Dest = $j.Dir; $script:Basename = $j.Base; $script:OffsetMs = $off
        $script:Result.OffsetMs = $off
        Invoke-One
    } catch {
        $script:Result.Status = 'Failed'; $script:Result.Message = $_.Exception.Message
        Write-Log "FAILED: $($_.Exception.Message)" 'Red'
    } finally {
        if ($extracted -and [IO.File]::Exists($extracted)) { Remove-Item -LiteralPath $extracted -Force -ErrorAction SilentlyContinue }
    }
    $st = [string]$script:Result.Status
    if ($counts.ContainsKey($st)) { $counts[$st]++ }
    $line = "{0,-7} {1}: {2}" -f $st, (Join-Path $j.Dir $j.Base), $script:Result.Message
    if ($script:Result.Review -and $script:Result.ReviewReason) { $line += "`n          REVIEW: $($script:Result.ReviewReason)" }
    $summary.Add($line)
}
Write-Log ''
Write-Log ("Summary: {0} done, {1} to review, {2} without English subtitles, {3} failed" -f $counts.Done, $counts.Review, $counts.None, $counts.Failed) 'Cyan'
foreach ($l in $summary) { Write-Log "  $l" $(if ($l -like 'Failed*') { 'Red' } elseif ($l -like 'Review*') { 'Yellow' } else { '' }) }
Sync-Log
if ($counts.Failed) { exit 1 }
exit 0
