@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'          # interactive admin tooling: coloured console status is intentional (and captured to logs by the runner)
        'PSReviewUnusedParameter'        # false positives for parameters used inside nested script blocks
        'PSUseDeclaredVarsMoreThanAssignments'   # false positives for Pester BeforeAll variables
    )
}
