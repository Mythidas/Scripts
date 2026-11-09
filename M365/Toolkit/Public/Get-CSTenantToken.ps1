function Get-CSTenantToken {
    <#
    .SYNOPSIS
        Mints a delegated access token for a customer tenant from the partner session (GDAP).

    .DESCRIPTION
        Redeems the partner refresh token against the customer tenant's token endpoint. What the token can do is the intersection of
        the signed-in user's GDAP roles in that tenant and the scopes the client has been consented for there.
        Tokens are cached in memory and reused until five minutes before they expire.

    .PARAMETER Scope
        Default 'https://graph.microsoft.com/.default' = every scope already consented for the client in that tenant.

    .EXAMPLE
        Get-CSTenantToken -TenantId contoso.onmicrosoft.com | Select-Object -ExpandProperty AccessToken | ConvertFrom-CSJwt
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string]$TenantId,

        [string]$Scope = 'https://graph.microsoft.com/.default',

        [switch]$Force
    )

    process {
        Assert-CSSession

        $session = $script:CSSession
        $key     = "$TenantId|$Scope"

        $cached = $session.TokenCache[$key]
        if (-not $Force -and $cached -and $cached.ExpiresOn -gt (Get-Date).AddMinutes(5)) { return $cached }

        $response = Invoke-CSTokenRequest -Authority $TenantId -Body @{
            client_id     = $session.ClientId
            grant_type    = 'refresh_token'
            refresh_token = $session.RefreshToken
            scope         = $Scope
        }

        $claims = ConvertFrom-CSJwt $response.access_token

        # Only the partner tenant's own refresh token may replace the master; customer-tenant ones are tenant-scoped.
        if ($response.refresh_token -and $claims.tid -eq $session.PartnerTenantId) {
            $session.RefreshToken = $response.refresh_token
        }

        $token = [pscustomobject]@{
            TenantId    = $claims.tid
            AccessToken = $response.access_token
            ExpiresOn   = (Get-Date).AddSeconds([int]$response.expires_in)
            Scope       = $Scope
        }
        $session.TokenCache[$key] = $token
        $token
    }
}
