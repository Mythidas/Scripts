function Grant-CSTenantConsent {
    <#
    .SYNOPSIS
        Consents the toolkit app into customer tenants through the Partner Center API, so GDAP tokens can be minted there.

    .DESCRIPTION
        For each tenant piped in, calls Partner Center  POST /v1/customers/{tenantId}/applicationconsents  with the toolkit's ClientId
        and the delegated Graph permissions in $CustomerGraphScopes (CSToolkit.psm1). This creates the app's service principal and
        an admin consent grant in the customer tenant - no sign-in to each tenant needed.

        Requirements:
          - Connect-CSPartner signed in with the toolkit app (run Register-CSPartnerApp first)
          - your GDAP relationship with the customer includes Cloud Application Administrator, and your account is in that group

        Tenants where the app is already consented report Pass ("already consented") and are left alone. -Force replaces the
        existing consent (delete + create) - use it after adding permissions. Consent can take a few minutes to take effect.

        Emits one CS.Result row per tenant (CheckId CONSENT-001): Pass = consented, Error = could not consent (see Detail).

    .EXAMPLE
        Get-CSTenant | Grant-CSTenantConsent | Export-CSResult -Name Consent

    .EXAMPLE
        Get-CSTenant -Customer 'Acme*' | Grant-CSTenantConsent -Force -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]]$Tenant,

        [switch]$Force
    )

    begin {
        Assert-CSSession
        $session = $script:CSSession
        if ($session.ClientId -eq $script:BootstrapClientId) {
            throw 'Signed in with the Microsoft Graph CLI client. Run Register-CSPartnerApp, then Connect-CSPartner, before granting consent.'
        }
        $settings = if (Test-Path -LiteralPath $script:SettingsPath) { Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json }
        $appName  = if ($settings.DisplayName) { $settings.DisplayName } else { 'CS Toolkit' }

        $pcToken = (Get-CSTenantToken -TenantId $session.PartnerTenantId -Scope 'https://api.partnercenter.microsoft.com/user_impersonation').AccessToken
        $base    = 'https://api.partnercenter.microsoft.com/v1/customers'
        $body    = @{
            applicationId     = $session.ClientId
            displayName       = $appName
            applicationGrants = @(@{ enterpriseApplicationId = $script:GraphAppId; scope = ($script:CustomerGraphScopes -join ',') })
        } | ConvertTo-Json -Depth 5 -Compress

        $send = {
            param([string]$Method, [string]$Uri, $Payload)
            $headers = @{
                Authorization     = "Bearer $pcToken"
                Accept            = 'application/json'
                'MS-RequestId'    = [guid]::NewGuid().ToString()
                'MS-CorrelationId' = [guid]::NewGuid().ToString()
            }
            Send-CSRequest -Uri $Uri -Method $Method -Headers $headers -Body $Payload -ContentType $(if ($Payload) { 'application/json' })
        }
        $describe = {
            param($Response)
            $b = $Response.Body
            $msg = if ($b.description) { $b.description } elseif ($b.message) { $b.message } elseif ($b) { ($b | ConvertTo-Json -Compress -Depth 5) } else { '' }
            "HTTP $($Response.StatusCode): $msg"
        }

        $all = [System.Collections.Generic.List[object]]::new()
    }

    process { foreach ($t in $Tenant) { $all.Add($t) } }

    end {
        $i = 0
        foreach ($t in $all) {
            $i++
            $label = if ($t.DisplayName) { $t.DisplayName } else { $t.TenantId }
            Write-Progress -Activity 'Granting app consent' -Status $label -PercentComplete (($i - 1) / $all.Count * 100)

            $result = @{ Tenant = $t; CheckId = 'CONSENT-001'; Category = 'Access'; Title = "$appName consented"; Severity = 'Info' }
            $action = if ($Force) { 'Replace app consent' } else { 'Grant app consent' }
            if (-not $PSCmdlet.ShouldProcess($label, $action)) { continue }

            try {
                if ($Force) {
                    $del = & $send DELETE "$base/$($t.TenantId)/applicationconsents/$($session.ClientId)"
                    if ($del.StatusCode -notin 200, 204, 404) { throw (& $describe $del) }
                }

                $resp = & $send POST "$base/$($t.TenantId)/applicationconsents" $body
                if ($resp.StatusCode -in 200, 201) {
                    New-CSResult @result -Status Pass -Actual 'Consent granted'
                }
                elseif ($resp.StatusCode -eq 409) {
                    New-CSResult @result -Status Pass -Actual 'Already consented' -Detail 'Use -Force to replace it (e.g. after adding permissions).'
                }
                else { throw (& $describe $resp) }
            }
            catch {
                $msg = "$($_.Exception.Message)"
                $fix = if ($msg -match 'HTTP 40[13]') {
                    'Check that the GDAP relationship includes Cloud Application Administrator and your account is in that access assignment.'
                }
                New-CSResult @result -Status Error -Expected 'Consented' -Actual 'Failed' -Detail $msg -Remediation $fix
            }
        }
        Write-Progress -Activity 'Granting app consent' -Completed
    }
}
