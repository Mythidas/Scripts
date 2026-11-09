function ConvertFrom-CSJwt {
    <#
    .SYNOPSIS
        Decodes the payload of a JWT (no signature validation - for diagnostics and reading tid/scp/wids claims only).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Token
    )

    process {
        $parts = $Token.Split('.')
        if ($parts.Count -lt 2) { throw 'Not a JWT.' }

        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        $payload = $payload.PadRight($payload.Length + (4 - $payload.Length % 4) % 4, '=')
        [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    }
}
