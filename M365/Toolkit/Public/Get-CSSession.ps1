function Get-CSSession {
    <#
    .SYNOPSIS
        Returns the partner sign-in (Account, PartnerTenantId), or $null when not connected.
    #>
    [CmdletBinding()]
    param ()

    if ($script:CSSession) {
        [pscustomobject]@{ Account = $script:CSSession.Account; PartnerTenantId = $script:CSSession.PartnerTenantId }
    }
}
