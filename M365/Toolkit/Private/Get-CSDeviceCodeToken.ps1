function Get-CSDeviceCodeToken {
    <#
    .SYNOPSIS
        Device-code sign-in, for headless shells or when the browser flow is not possible.
        Note: many tenants block the device-code flow with Conditional Access.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Authority,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$Scope
    )

    $device = Invoke-CSTokenRequest -Authority $Authority -Endpoint devicecode -Body @{ client_id = $ClientId; scope = $Scope }
    Write-Host $device.message -ForegroundColor Cyan

    $deadline = (Get-Date).AddSeconds([int]$device.expires_in)
    $interval = [int]$device.interval
    if ($interval -lt 1) { $interval = 5 }

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        $result = Invoke-CSTokenRequest -Authority $Authority -PassThroughPending -Body @{
            client_id   = $ClientId
            grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
            device_code = $device.device_code
        }
        if ($result.error -eq 'authorization_pending') { continue }
        if ($result.error -eq 'slow_down') { $interval += 5; continue }
        return $result
    }
    throw 'Device-code sign-in timed out.'
}
