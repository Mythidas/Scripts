function Register-CSPartnerApp {
    <#
    .SYNOPSIS
        One-time setup: creates (or updates) the toolkit's own multi-tenant app registration in your partner tenant.

    .DESCRIPTION
        Signs in to the partner tenant with the Microsoft Graph CLI client (asks for Application.ReadWrite.All and
        DelegatedPermissionGrant.ReadWrite.All - you need Global Admin or Privileged Role Admin / Cloud App Admin there), then:
          1. creates a multi-tenant public-client app (redirect http://localhost) - or updates it if one with -DisplayName exists
          2. sets its delegated permissions: the Graph read permissions the health checks use + Partner Center user_impersonation
          3. creates its service principal and grants admin consent in the partner tenant
          4. writes the ClientId to Config/settings.json, which Connect-CSPartner picks up from then on

        Safe to re-run (e.g. after adding a permission to $CustomerGraphScopes in CSToolkit.psm1). No secret or certificate is
        created: the app is a public client used for delegated (signed-in user) access only.

        Afterwards: Disconnect-CSPartner; Connect-CSPartner; Get-CSTenant | Grant-CSTenantConsent

    .EXAMPLE
        Register-CSPartnerApp -WhatIf
        Register-CSPartnerApp
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [string]$DisplayName = 'CS Toolkit',

        [switch]$DeviceCode
    )

    $setupScopes = @('https://graph.microsoft.com/Application.ReadWrite.All', 'https://graph.microsoft.com/DelegatedPermissionGrant.ReadWrite.All')
    Write-Host 'Signing in to the partner tenant to register the app (admin consent for the Graph CLI client may be requested)...' -ForegroundColor Cyan
    $conn = Connect-CSPartner -ClientId $script:BootstrapClientId -Scope $setupScopes -DeviceCode:$DeviceCode
    $ctx  = [pscustomobject]@{ AccessToken = (Get-CSTenantToken -TenantId $conn.PartnerTenantId -Scope ($setupScopes -join ' ')).AccessToken }

    # Directory writes can take a few seconds to replicate; retry the call that depends on a just-created object.
    $retry = {
        param([scriptblock]$Call)
        for ($i = 1; ; $i++) {
            try { return & $Call }
            catch {
                if ($i -ge 6 -or $_.FullyQualifiedErrorId -notin 'CSGraph.NotFound', 'CSGraph.Error') { throw }
                Start-Sleep -Seconds (3 * $i)
            }
        }
    }

    $getOrCreateSp = {
        param([string]$AppId)
        try { Invoke-CSGraph "/servicePrincipals(appId='$AppId')?`$select=id,appId,displayName,oauth2PermissionScopes" -Context $ctx }
        catch {
            if ($_.FullyQualifiedErrorId -ne 'CSGraph.NotFound') { throw }
            if (-not $PSCmdlet.ShouldProcess($AppId, 'Create service principal')) { return $null }
            & $retry { Invoke-CSGraph '/servicePrincipals' -Method POST -Body @{ appId = $AppId } -Context $ctx }
        }
    }

    # --- resolve permission IDs ---
    $graphSp = & $getOrCreateSp $script:GraphAppId
    $pcSp    = & $getOrCreateSp $script:PartnerCenterAppId
    if (-not $pcSp) { throw 'Partner Center service principal is missing in the partner tenant (re-run without -WhatIf to create it).' }

    $graphNames = @($script:CustomerGraphScopes) + $script:PartnerGraphScopes | Select-Object -Unique
    $graphAccess = foreach ($name in $graphNames) {
        $perm = $graphSp.oauth2PermissionScopes | Where-Object value -eq $name
        if (-not $perm) { throw "Microsoft Graph has no delegated permission named '$name'." }
        @{ id = $perm.id; type = 'Scope' }
    }
    $pcPerm = $pcSp.oauth2PermissionScopes | Where-Object value -eq 'user_impersonation'
    if (-not $pcPerm) { throw 'Partner Center API has no user_impersonation permission in this tenant.' }

    $appBody = @{
        displayName            = $DisplayName
        signInAudience         = 'AzureADMultipleOrgs'
        isFallbackPublicClient = $true
        publicClient           = @{ redirectUris = @('http://localhost') }
        requiredResourceAccess = @(
            @{ resourceAppId = $script:GraphAppId;         resourceAccess = @($graphAccess) }
            @{ resourceAppId = $script:PartnerCenterAppId; resourceAccess = @(@{ id = $pcPerm.id; type = 'Scope' }) }
        )
    }

    # --- app registration ---
    $escaped  = $DisplayName.Replace("'", "''")
    $existing = @(Invoke-CSGraph "/applications?`$filter=displayName eq '$escaped'&`$select=id,appId,displayName" -Context $ctx)
    if ($existing.Count -gt 1) { throw "More than one app registration is named '$DisplayName'. Remove the duplicate or pass -DisplayName." }

    if ($existing.Count -eq 1) {
        $app = $existing[0]
        if ($PSCmdlet.ShouldProcess("$DisplayName ($($app.appId))", 'Update app registration permissions')) {
            Invoke-CSGraph "/applications/$($app.id)" -Method PATCH -Body $appBody -Context $ctx | Out-Null
            Write-Host "Updated app registration '$DisplayName' ($($app.appId))" -ForegroundColor Green
        }
    }
    elseif ($PSCmdlet.ShouldProcess($DisplayName, 'Create multi-tenant app registration')) {
        $app = Invoke-CSGraph '/applications' -Method POST -Body $appBody -Context $ctx
        Write-Host "Created app registration '$DisplayName' ($($app.appId))" -ForegroundColor Green
    }
    else {
        Write-Host "Would create app '$DisplayName' with Graph: $($graphNames -join ', '); Partner Center: user_impersonation"
        return
    }

    # --- service principal + admin consent in the partner tenant ---
    $appSp = if ($WhatIfPreference) { $null } else { & $retry { & $getOrCreateSp $app.appId } }
    $grants = @(
        @{ Resource = $graphSp; Scope = ($graphNames -join ' ') }
        @{ Resource = $pcSp;    Scope = 'user_impersonation' }
    )
    foreach ($grant in $grants) {
        if (-not $appSp) { Write-Host "Would grant admin consent: $($grant.Resource.displayName) [$($grant.Scope)]"; continue }
        $current = @(Invoke-CSGraph "/oauth2PermissionGrants?`$filter=clientId eq '$($appSp.id)' and resourceId eq '$($grant.Resource.id)'" -Context $ctx) |
            Where-Object consentType -eq 'AllPrincipals' | Select-Object -First 1
        if (-not $PSCmdlet.ShouldProcess($grant.Resource.displayName, "Grant admin consent: $($grant.Scope)")) { continue }
        if ($current) {
            Invoke-CSGraph "/oauth2PermissionGrants/$($current.id)" -Method PATCH -Body @{ scope = $grant.Scope } -Context $ctx | Out-Null
        }
        else {
            & $retry {
                Invoke-CSGraph '/oauth2PermissionGrants' -Method POST -Context $ctx -Body @{
                    clientId = $appSp.id; consentType = 'AllPrincipals'; resourceId = $grant.Resource.id; scope = $grant.Scope
                }
            } | Out-Null
        }
        Write-Host "Admin consent granted in partner tenant: $($grant.Resource.displayName)" -ForegroundColor Green
    }

    if ($PSCmdlet.ShouldProcess($script:SettingsPath, 'Save ClientId')) {
        [ordered]@{ ClientId = $app.appId; DisplayName = $DisplayName; PartnerTenantId = $conn.PartnerTenantId } |
            ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding utf8
        Write-Host "Saved $($script:SettingsPath)" -ForegroundColor Green
    }

    # The current session belongs to the Graph CLI client; drop it so the next Connect-CSPartner uses the new app.
    Disconnect-CSPartner
    Write-Host "`nNext:  Connect-CSPartner;  Get-CSTenant | Grant-CSTenantConsent" -ForegroundColor Cyan

    [pscustomobject]@{ DisplayName = $DisplayName; ClientId = $app.appId; PartnerTenantId = $conn.PartnerTenantId }
}
