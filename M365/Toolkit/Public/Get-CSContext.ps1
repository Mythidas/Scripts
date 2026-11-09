function Get-CSContext {
    <#
    .SYNOPSIS
        Returns the current tenant context (Tenant, AccessToken, ExpiresOn), or $null.
    #>
    [CmdletBinding()]
    param ()

    $script:CSContext
}
