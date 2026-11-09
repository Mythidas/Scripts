function Connect-CSPartner {
    <#
    .SYNOPSIS
        Signs in once to your partner (MSP) tenant. The session is then used to mint a delegated (GDAP) token for any customer tenant.

    .DESCRIPTION
        Uses the public "Microsoft Graph Command Line Tools" client by default (the same one Connect-MgGraph uses), browser sign-in with
        PKCE. The refresh token is kept in memory only - nothing is written to disk. Customer tokens are minted from it by
        Get-CSTenantToken, so a run across many tenants needs a single interactive sign-in (MFA included).

        The session lives in the loaded module, so run your scripts from the same pwsh window to avoid signing in again.

    .PARAMETER PartnerTenantId
        Your partner tenant ID or domain. Default 'organizations' lets Entra work it out from the account you pick.

    .PARAMETER Scope
        Delegated Graph scopes requested at sign-in. The default is what Sync-CSTenantRegistry needs.
        Customer-tenant tokens request their own scopes (see Get-CSTenantToken).

    .PARAMETER DeviceCode
        Use the device-code flow instead of the browser. Often blocked by Conditional Access.

    .EXAMPLE
        Connect-CSPartner
    #>
    [CmdletBinding()]
    param (
        [string]$PartnerTenantId = 'organizations',

        [string]$ClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e',

        [string[]]$Scope = @('https://graph.microsoft.com/DelegatedAdminRelationship.Read.All', 'https://graph.microsoft.com/CrossTenantInformation.ReadBasic.All'),

        [switch]$DeviceCode
    )

    $scopeString = (@($Scope) + 'openid', 'profile', 'offline_access') -join ' '

    $token = if ($DeviceCode) {
        Get-CSDeviceCodeToken -Authority $PartnerTenantId -ClientId $ClientId -Scope $scopeString
    }
    else {
        Get-CSAuthCodeToken -Authority $PartnerTenantId -ClientId $ClientId -Scope $scopeString
    }

    $access  = ConvertFrom-CSJwt $token.access_token
    $account = if ($token.id_token) { (ConvertFrom-CSJwt $token.id_token).preferred_username } else { $access.upn }

    $script:CSSession = @{
        ClientId        = $ClientId
        PartnerTenantId = $access.tid
        Account         = $account
        RefreshToken    = $token.refresh_token
        TokenCache      = @{}
    }

    $grantedScope = ($Scope -join ' ')
    $script:CSSession.TokenCache["$($access.tid)|$grantedScope"] = [pscustomobject]@{
        TenantId    = $access.tid
        AccessToken = $token.access_token
        ExpiresOn   = (Get-Date).AddSeconds([int]$token.expires_in)
        Scope       = $grantedScope
    }

    Write-Host "Connected to partner tenant $($access.tid) as $account" -ForegroundColor Green
    [pscustomobject]@{ Account = $account; PartnerTenantId = $access.tid }
}
