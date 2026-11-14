# Shared.ps1
# Dot-sourced by every PowerShell script here; keep it next to them. Two things they all do
# the same way:
#   - Get-ScriptSettings: defaults from the settings file (encode-settings.ini) for the
#     parameters a run didn't give.
#   - Resolve-InputPath: a path as typed or tab-completed (tab completion escapes [ ] with
#     backticks) -> the full path.
# Built for Windows PowerShell 5.1 (also runs on PowerShell 7).

# The settings file: $env:ENCODE_SETTINGS if set, else encode-settings.ini next to the scripts.
function Get-SettingsFilePath {
    if ($env:ENCODE_SETTINGS) { return $env:ENCODE_SETTINGS }
    Join-Path $PSScriptRoot 'encode-settings.ini'
}

# An INI file: "[Section]" lines, "Key = value" lines, "#" or ";" comment lines. Keys before
# the first section are in section ''. A value may be wrapped in quotes; there are no inline
# comments (a # can be part of a path).
function Read-SettingsFile([string]$Path) {
    $section = ''
    $n = 0
    foreach ($raw in [IO.File]::ReadAllLines($Path)) {
        $n++
        $l = $raw.Trim()
        if (-not $l -or $l.StartsWith('#') -or $l.StartsWith(';')) { continue }
        if ($l -match '^\[\s*([^\]]+?)\s*\]$') { $section = $Matches[1]; continue }
        if ($l -notmatch '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            Write-Warning "${Path} line ${n}: not 'Key = value'; ignored"
            continue
        }
        $k = $Matches[1]; $v = $Matches[2].Trim()
        if ($v.Length -ge 2 -and (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'")))) {
            $v = $v.Substring(1, $v.Length - 2)
        }
        [pscustomobject]@{ Section = $section; Key = $k; Value = $v; Line = $n }
    }
}

# ~, $HOME and %VARIABLES% in a value.
function Expand-SettingValue([string]$Value) {
    if ($Value -match '^(~|\$HOME|\$env:USERPROFILE)(?=$|[\\/])') { $Value = $HOME + $Value.Substring($Matches[1].Length) }
    [Environment]::ExpandEnvironmentVariables($Value)
}

# The settings that apply to this script, for the parameters the run didn't give:
#   [All] (or no section)   every script that has a parameter of that name
#   [<script name>]         only that script (e.g. [Encode-Batch]); wins over [All]
#   [compare_encode]        read by compare_encode.sh in WSL, not here
# Each one found is also added to the bound parameters, so the script treats it as given.
# Each script, right after its param() block:
#   . (Join-Path $PSScriptRoot 'Shared.ps1')
#   $script:SettingsUsed = @(Get-ScriptSettings $MyInvocation.MyCommand $PSBoundParameters)
#   foreach ($setting in $script:SettingsUsed) { Set-Variable -Name $setting.Name -Value $setting.Value }
function Get-ScriptSettings {
    param(
        [Parameter(Mandatory)]$Command,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary]$Bound
    )
    $file = Get-SettingsFilePath
    if (-not [IO.File]::Exists($file)) {
        if ($env:ENCODE_SETTINGS) { throw "ENCODE_SETTINGS points to a file that doesn't exist: $file" }
        return
    }
    $file = [IO.Path]::GetFullPath($file)
    # Scripts this one starts (and WSL, through Invoke-Wsl) read the same file.
    $env:ENCODE_SETTINGS = $file
    $name = [IO.Path]::GetFileNameWithoutExtension([string]$Command.Name)
    $skip = @([Management.Automation.PSCmdlet]::CommonParameters) + @([Management.Automation.PSCmdlet]::OptionalCommonParameters)
    $params = @{}
    foreach ($p in $Command.Parameters.Values) {
        if ($skip -contains $p.Name) { continue }
        foreach ($n in @($p.Name) + @($p.Aliases)) { $params[$n.ToLowerInvariant()] = $p }   # a parameter's aliases work too
    }

    # What a single run is about (and the plumbing between the scripts) never comes from the file.
    $perRun = @('Source', 'Dest', 'WorkDir', 'Output', 'Root', 'Basename', 'Crop', 'Plumbing', 'Status', 'StatusFile', 'LogPrefix')

    $picked = @{}   # lower-case name -> @{ Param; Entry; Specific }
    foreach ($e in @(Read-SettingsFile $file)) {
        $specific = [bool]$e.Section -and $e.Section -ne 'All'
        if ($specific -and $e.Section -ne $name) { continue }
        $p = $params[$e.Key.ToLowerInvariant()]
        if (-not $p -or $Bound.ContainsKey($p.Name)) { continue }
        if ($perRun -contains $p.Name) { Write-Warning "${file} line $($e.Line): $($p.Name) is given per run, not in the settings file; ignored"; continue }
        $et = if ($p.ParameterType.IsArray) { $p.ParameterType.GetElementType() } else { $p.ParameterType }
        if ([Collections.IDictionary].IsAssignableFrom($et)) { Write-Warning "${file} line $($e.Line): $($p.Name) takes hashtables (@{...}), which the settings file can't hold; pass it on the command line. Ignored"; continue }
        $prev = $picked[$p.Name.ToLowerInvariant()]
        if ($prev -and $prev.Specific -and -not $specific) { continue }   # [Script] beats [All]
        $picked[$p.Name.ToLowerInvariant()] = @{ Param = $p; Entry = $e; Specific = $specific }
    }
    foreach ($k in $picked.Keys) {
        $p = $picked[$k].Param; $e = $picked[$k].Entry
        $where = "$file line $($e.Line) ($($p.Name))"
        $raw = Expand-SettingValue $e.Value
        $t = $p.ParameterType
        try {
            if ($t -eq [Management.Automation.SwitchParameter] -or $t -eq [bool]) {
                $b = switch -Regex ($raw) { '^(1|true|yes|on)$' { $true } '^(0|false|no|off)$' { $false } default { throw "'$raw' isn't true or false" } }
                $v = if ($t -eq [bool]) { $b } else { [Management.Automation.SwitchParameter]$b }
            } elseif ($t.IsArray) {
                $v = [Management.Automation.LanguagePrimitives]::ConvertTo(@($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }), $t)
            } else {
                $v = [Management.Automation.LanguagePrimitives]::ConvertTo($raw, $t)
            }
        } catch { throw "Settings file ${where}: $($_.Exception.Message)" }
        # The parameter's ValidateSet / ValidateRange etc. (checked here, so the error names the line)
        foreach ($a in $p.Attributes) {
            if ($a -isnot [Management.Automation.ValidateArgumentsAttribute]) { continue }
            $one = New-Object 'System.Collections.ObjectModel.Collection[System.Attribute]'
            $one.Add($a)
            try { $null = New-Object Management.Automation.PSVariable ('check', $v, 'None', $one) } catch {
                $rule = if ($a -is [Management.Automation.ValidateSetAttribute]) { "one of: $($a.ValidValues -join ', ')" }
                        elseif ($a -is [Management.Automation.ValidateRangeAttribute]) { "from $($a.MinRange) to $($a.MaxRange)" }
                        else { $a.GetType().Name -replace 'Attribute$' }
                throw "Settings file ${where}: '$raw' isn't allowed ($rule)"
            }
        }
        $Bound[$p.Name] = $v
        [pscustomobject]@{ Name = $p.Name; Value = $v; Where = $where }
    }
}

# A path as the user gave it -> a full path. Tab completion escapes [ ] (and * ?) with one
# backtick, or two when the path was completed inside double quotes and then pasted into
# single quotes; the path as given is used if it exists, else the unescaped one. A path that
# doesn't exist yet (an output) is unescaped: a real file name never has a backtick right
# before a bracket. -Program: a bare command name ("mkvmerge") is left for PATH lookup.
function Resolve-InputPath {
    param([string]$Path, [switch]$Program)
    if (-not $Path) { return $Path }
    $unescaped = $Path -replace '`+(?=[\[\]*?])', ''
    if ($Program -and $unescaped -notmatch '[\\/]') { return $unescaped }
    $sp = $ExecutionContext.SessionState.Path
    foreach ($c in @($Path, $unescaped) | Select-Object -Unique) {
        $full = $sp.GetUnresolvedProviderPathFromPSPath($c)
        if ([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)) { return $full }
    }
    $sp.GetUnresolvedProviderPathFromPSPath($unescaped)
}
