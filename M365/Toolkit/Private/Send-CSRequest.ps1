function Send-CSRequest {
    <#
    .SYNOPSIS
        Thin wrapper over Invoke-RestMethod that never throws on HTTP errors and returns status, headers and body.
        Exists so the retry / paging logic above it can be unit-tested by mocking this one function.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        [hashtable]$Headers = @{},
        $Body,
        [string]$ContentType
    )

    $params = @{
        Uri                     = $Uri
        Method                  = $Method
        Headers                 = $Headers
        SkipHttpErrorCheck      = $true
        StatusCodeVariable      = 'statusCode'
        ResponseHeadersVariable = 'responseHeaders'
        ErrorAction             = 'Stop'
    }
    if ($null -ne $Body)  { $params.Body = $Body }
    if ($ContentType)     { $params.ContentType = $ContentType }

    $result = Invoke-RestMethod @params

    [pscustomobject]@{
        StatusCode = [int]$statusCode
        Headers    = $responseHeaders
        Body       = $result
    }
}
