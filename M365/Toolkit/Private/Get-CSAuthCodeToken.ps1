function Get-CSAuthCodeToken {
    <#
    .SYNOPSIS
        Interactive sign-in: authorization code + PKCE with a loopback redirect (http://localhost:<port>).
        Honours Conditional Access on the partner tenant the same way Connect-MgGraph does.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Authority,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$Scope,
        [int]$TimeoutSeconds = 180
    )

    function ConvertTo-Base64Url([byte[]]$Bytes) {
        [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    }

    $verifier  = ConvertTo-Base64Url ([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(48))
    $challenge = ConvertTo-Base64Url ([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::ASCII.GetBytes($verifier)))
    $state     = ConvertTo-Base64Url ([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(16))

    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
    $redirect = "http://localhost:$port"

    $query = @{
        client_id             = $ClientId
        response_type         = 'code'
        redirect_uri          = $redirect
        response_mode         = 'query'
        scope                 = $Scope
        state                 = $state
        code_challenge        = $challenge
        code_challenge_method = 'S256'
        prompt                = 'select_account'
    }
    $queryString = ($query.GetEnumerator() | ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString($_.Value))" }) -join '&'
    $authUrl     = "https://login.microsoftonline.com/$Authority/oauth2/v2.0/authorize?$queryString"

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("$redirect/")
    $listener.Start()

    try {
        Write-Host 'Opening your browser to sign in. If it does not open, browse to:' -ForegroundColor Cyan
        Write-Host $authUrl -ForegroundColor DarkGray
        try {
            if     ($IsWindows) { Start-Process $authUrl }
            elseif ($IsMacOS)   { & open $authUrl }
            else                { & xdg-open $authUrl 2>$null }
        }
        catch { Write-Verbose "Could not launch a browser automatically: $_" }

        $pending = $listener.GetContextAsync()
        if (-not $pending.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            throw "Sign-in timed out after $TimeoutSeconds seconds."
        }
        $httpContext = $pending.Result
        $params      = [System.Web.HttpUtility]::ParseQueryString($httpContext.Request.Url.Query)

        $page  = if ($params['code']) { 'Signed in. You can close this tab and return to PowerShell.' } else { 'Sign-in failed. See PowerShell for details.' }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("<html><body style='font-family:sans-serif'><h3>$page</h3></body></html>")
        $httpContext.Response.ContentType     = 'text/html'
        $httpContext.Response.ContentLength64 = $bytes.Length
        $httpContext.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $httpContext.Response.Close()
    }
    finally {
        $listener.Stop(); $listener.Close()
    }

    if ($params['error']) { throw "Sign-in failed: $($params['error']) - $($params['error_description'])" }
    if ($params['state'] -ne $state) { throw 'Sign-in failed: state mismatch (possible forged redirect).' }

    Invoke-CSTokenRequest -Authority $Authority -Body @{
        client_id     = $ClientId
        grant_type    = 'authorization_code'
        code          = $params['code']
        redirect_uri  = $redirect
        code_verifier = $verifier
        scope         = $Scope
    }
}
