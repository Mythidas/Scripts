function Invoke-CSTokenRequest {
    <#
    .SYNOPSIS
        POSTs a form body to an Entra v2.0 endpoint ('token' or 'devicecode') and returns the parsed response.
        Throws with the AADSTS message on failure; 'authorization_pending' / 'slow_down' are returned as the raw error body
        when -PassThroughPending is set (device-code polling).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Authority,
        [ValidateSet('token', 'devicecode')][string]$Endpoint = 'token',
        [Parameter(Mandatory)][hashtable]$Body,
        [switch]$PassThroughPending
    )

    $uri      = "https://login.microsoftonline.com/$Authority/oauth2/v2.0/$Endpoint"
    $response = Send-CSRequest -Uri $uri -Method POST -Body $Body -ContentType 'application/x-www-form-urlencoded'

    if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) { return $response.Body }

    $err = $response.Body
    if ($PassThroughPending -and $err.error -in 'authorization_pending', 'slow_down') { return $err }

    $description = ("$($err.error_description)" -split "`r?`n")[0]
    $hint = switch -Regex ($description) {
        'AADSTS65001' { ' (consent for this client has not been granted in the target tenant)'; break }
        'AADSTS500011|AADSTS700016' { ' (the client or resource does not exist in the target tenant)'; break }
        'AADSTS90072|AADSTS500014' { ' (no active GDAP relationship / user not authorized in the target tenant)'; break }
        default { '' }
    }
    throw "Token request failed [$Authority]: $description$hint"
}
