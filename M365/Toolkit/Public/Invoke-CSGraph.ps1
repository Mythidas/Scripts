function Invoke-CSGraph {
    <#
    .SYNOPSIS
        Calls Microsoft Graph for one tenant using an explicit bearer token. Follows paging, retries throttling, and
        raises errors that carry the HTTP status so callers can tell "no access" from "broken".

    .DESCRIPTION
        Uses plain REST (not the Graph SDK), so there is no process-wide connection and several tenants can be queried side by side.
        The tenant comes from -Context, or from the current context (Set-CSContext) when omitted.

        Collection responses are returned as individual items with every page followed (-NoPaging to get one page).
        Single objects are returned as-is.

        Errors are ErrorRecords whose FullyQualifiedErrorId is one of
        CSGraph.Unauthorized (401), CSGraph.Forbidden (403), CSGraph.NotFound (404), CSGraph.Throttled (429, retries exhausted),
        CSGraph.Error (anything else). Test with $_.FullyQualifiedErrorId -eq '...'. TargetObject holds @{ Status; Code; Message; Uri }.

    .EXAMPLE
        Invoke-CSGraph '/users?$select=displayName,userPrincipalName&$top=999'

    .EXAMPLE
        Invoke-CSGraph '/policies/conditionalAccessPolicies' -Context $ctx
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$Uri,

        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
        [string]$Method = 'GET',

        $Body,

        [switch]$Beta,

        # Adds ConsistencyLevel: eventual (needed for $count / $search / some $filter on directory objects).
        [switch]$ConsistencyEventual,

        [switch]$NoPaging,

        $Context = $script:CSContext,

        [int]$MaxRetries = 5
    )

    if (-not $Context -or -not $Context.AccessToken) {
        throw 'No tenant context. Pass -Context or call Set-CSContext (Invoke-CSForEachTenant does this for you).'
    }

    $base = if ($Beta) { 'https://graph.microsoft.com/beta' } else { 'https://graph.microsoft.com/v1.0' }
    $next = if ($Uri -match '^https?://') { $Uri } else { "$base/$($Uri.TrimStart('/'))" }

    $headers = @{ Authorization = "Bearer $($Context.AccessToken)" }
    if ($ConsistencyEventual) { $headers.ConsistencyLevel = 'eventual' }

    $payload     = $null
    $contentType = $null
    if ($null -ne $Body) {
        $payload     = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
        $contentType = 'application/json'
    }

    while ($next) {
        $attempt = 0
        while ($true) {
            $attempt++
            $response = Send-CSRequest -Uri $next -Method $Method -Headers $headers -Body $payload -ContentType $contentType

            if ($response.StatusCode -in 429, 502, 503, 504 -and $attempt -le $MaxRetries) {
                $retryAfter = 0
                if ($response.Headers -and $response.Headers['Retry-After']) {
                    [void][int]::TryParse(@($response.Headers['Retry-After'])[0], [ref]$retryAfter)
                }
                $delay = if ($retryAfter -gt 0) { $retryAfter } else { [math]::Min(30, [math]::Pow(2, $attempt)) }
                Write-Verbose "Graph $($response.StatusCode) - retrying in ${delay}s (attempt $attempt/$MaxRetries)"
                Start-Sleep -Seconds $delay
                continue
            }
            break
        }

        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
            $status  = $response.StatusCode
            $errBody = $response.Body.error
            $code    = if ($errBody.code) { "$($errBody.code)" } else { "$status" }
            $message = if ($errBody.message) { "$($errBody.message)" } else { "HTTP $status" }

            $errorId = switch ($status) {
                401     { 'CSGraph.Unauthorized' }
                403     { 'CSGraph.Forbidden' }
                404     { 'CSGraph.NotFound' }
                429     { 'CSGraph.Throttled' }
                default { 'CSGraph.Error' }
            }
            $details   = @{ Status = $status; Code = $code; Message = $message; Uri = $next }
            $exception = [System.Exception]::new("Graph $Method $next failed: $status $code - $message")
            throw [System.Management.Automation.ErrorRecord]::new($exception, $errorId, [System.Management.Automation.ErrorCategory]::NotSpecified, $details)
        }

        $data = $response.Body
        if ($null -ne $data -and $data.PSObject.Properties['value'] -and $data.PSObject.Properties['@odata.context'] -and $data.value -is [System.Collections.IEnumerable] -and $data.value -isnot [string]) {
            $data.value
            $next = if ($NoPaging) { $null } else { $data.'@odata.nextLink' }
        }
        else {
            $data
            $next = $null
        }
    }
}
