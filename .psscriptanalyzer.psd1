# PSScriptAnalyzer baseline for this repo.
#
# This is a command-line tool: Write-Host is how it talks to a human, and empty
# catch blocks are deliberate best-effort fallbacks (a missing optional file must
# not abort a collection run). Those two shapes dominate the raw output (~410 of
# 458 findings) and would bury the ones that point at real defects.
#
# Kept on purpose:
#   PSAvoidAssignmentToAutomaticVariable      - $args / $sender / $input shadowing
#   PSReviewUnusedParameter                   - dead switches that look live
#   PSUseDeclaredVarsMoreThanAssignments      - variables computed and never used
#
# Run:  Invoke-ScriptAnalyzer -Path . -Recurse -Settings .psscriptanalyzer.psd1
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
        'PSAvoidUsingEmptyCatchBlock'
        'PSUseSingularNouns'
        'PSUseApprovedVerbs'
        'PSAvoidOverwritingBuiltInCmdlets'
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
