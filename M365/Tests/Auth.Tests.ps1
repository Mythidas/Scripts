BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../Toolkit/CSToolkit.psd1') -Force

    function script:New-FakeJwt($claims) {
        $b64 = { param($t) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($t)).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
        "$(& $b64 '{"alg":"none"}').$(& $b64 ($claims | ConvertTo-Json -Compress)).sig"
    }
}

Describe 'ConvertFrom-CSJwt' {
    It 'decodes base64url payloads of any padding length' -ForEach @('a', 'ab', 'abc', 'abcd') {
        $jwt = New-FakeJwt @{ tid = 'T'; scp = "x$_" }
        (& (Get-Module CSToolkit) { param($j) ConvertFrom-CSJwt $j } $jwt).scp | Should -Be "x$_"
    }
}

Describe 'Get-CSTenantToken' {
    BeforeEach {
        & (Get-Module CSToolkit) {
            $script:CSSession = @{ ClientId = 'cid'; PartnerTenantId = 'partner'; Account = 'me'; RefreshToken = 'rt-master'; TokenCache = @{} }
        }
        $script:minted = 0
        Mock -ModuleName CSToolkit Invoke-CSTokenRequest {
            $script:minted++
            $tid = $Authority
            [pscustomobject]@{ access_token = (New-FakeJwt @{ tid = $tid }); refresh_token = "rt-from-$tid"; expires_in = 3600 }
        }
    }

    It 'redeems the master refresh token for the customer tenant' {
        $t = Get-CSTenantToken -TenantId 'cust1'
        $t.TenantId | Should -Be 'cust1'
        Should -Invoke -ModuleName CSToolkit Invoke-CSTokenRequest -ParameterFilter {
            $Authority -eq 'cust1' -and $Body.grant_type -eq 'refresh_token' -and $Body.refresh_token -eq 'rt-master' -and $Body.client_id -eq 'cid' }
    }
    It 'caches tokens per tenant and scope' {
        Get-CSTenantToken -TenantId 'cust1' | Out-Null
        Get-CSTenantToken -TenantId 'cust1' | Out-Null
        Get-CSTenantToken -TenantId 'cust2' | Out-Null
        Get-CSTenantToken -TenantId 'cust1' -Scope 'https://graph.microsoft.com/User.Read' | Out-Null
        $script:minted | Should -Be 3
    }
    It '-Force bypasses the cache' {
        Get-CSTenantToken -TenantId 'cust1' | Out-Null
        Get-CSTenantToken -TenantId 'cust1' -Force | Out-Null
        $script:minted | Should -Be 2
    }
    It 'only lets the partner tenant replace the master refresh token' {
        Get-CSTenantToken -TenantId 'cust1' | Out-Null
        & (Get-Module CSToolkit) { $script:CSSession.RefreshToken } | Should -Be 'rt-master'
        Get-CSTenantToken -TenantId 'partner' | Out-Null
        & (Get-Module CSToolkit) { $script:CSSession.RefreshToken } | Should -Be 'rt-from-partner'
    }
    It 'requires a partner session' {
        Disconnect-CSPartner
        { Get-CSTenantToken -TenantId 'cust1' } | Should -Throw '*Connect-CSPartner*'
    }
}

Describe 'Invoke-CSTokenRequest' {
    It 'adds a consent hint for AADSTS65001' {
        Mock -ModuleName CSToolkit Send-CSRequest {
            [pscustomobject]@{ StatusCode = 400; Headers = @{}; Body = [pscustomobject]@{ error = 'invalid_grant'; error_description = "AADSTS65001: The user or administrator has not consented.`r`nTrace ID: x" } }
        }
        { & (Get-Module CSToolkit) { Invoke-CSTokenRequest -Authority 'cust1' -Body @{ a = 1 } } } | Should -Throw '*consent for this client has not been granted*'
    }
}
