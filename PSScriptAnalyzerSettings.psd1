# Invoke-ScriptAnalyzer -Path .\scripts -Settings .\PSScriptAnalyzerSettings.psd1
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Console tools: Write-Host is the point (colour, no pipeline output).
        'PSAvoidUsingWriteHost',
        # Names like Get-SourceInfo / Read-ZipText are clearer as they are.
        'PSUseSingularNouns',
        # Best-effort cleanup (deleting temp files, reading optional files) ignores errors on purpose.
        'PSAvoidUsingEmptyCatchBlock',
        # Internal helpers named Set-/New-/Remove-; the scripts' own -WhatIf handling covers what matters.
        'PSUseShouldProcessForStateChangingFunctions',
        # Write-Log is this project's own log function (not a built-in on Windows PowerShell 5.1);
        # Add-BluRayAudio wraps Write-Host / Write-Warning / Out-Host to also write its log.
        'PSAvoidOverwritingBuiltInCmdlets',
        # Encode-Batch's worker jobs are built by joining scriptblocks as text, so variables set in
        # one part and used in another look unused to the analyzer.
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSReviewUnusedParameter',
        # Add-BluRayAudio calls ShouldProcess through the script's $PSCmdlet ($script:Cmdlet).
        'PSShouldProcess'
    )
}
