function Set-CSContext {
    <#
    .SYNOPSIS
        Sets the current tenant (registry row) and its access token. Invoke-CSGraph and New-CSResult read this when no explicit
        tenant is given. Invoke-CSForEachTenant calls it inside each tenant's process.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'In-memory session state only.')]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        $Tenant,

        $Token
    )

    $script:CSContext = [pscustomobject]@{
        Tenant      = $Tenant
        AccessToken = $Token.AccessToken
        ExpiresOn   = $Token.ExpiresOn
    }
}
