BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../Toolkit/CSToolkit.psd1') -Force
    $script:ctx = [pscustomobject]@{ AccessToken = 'tok' }
    function script:Resp($status, $body, $headers = @{}) { [pscustomobject]@{ StatusCode = $status; Headers = $headers; Body = $body } }
}

Describe 'Invoke-CSGraph' {
    It 'follows nextLink and emits individual items' {
        $script:calls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName CSToolkit Send-CSRequest {
            $script:calls.Add($Uri)
            if ($Uri -like '*page2*') { Resp 200 ([pscustomobject]@{ '@odata.context' = 'c'; value = @(3) }) }
            else { Resp 200 ([pscustomobject]@{ '@odata.context' = 'c'; value = @(1, 2); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/users?page2' }) }
        }
        Invoke-CSGraph '/users' -Context $ctx | Should -Be @(1, 2, 3)
        $script:calls[0] | Should -Be 'https://graph.microsoft.com/v1.0/users'
    }
    It 'returns a single object untouched' {
        Mock -ModuleName CSToolkit Send-CSRequest { Resp 200 ([pscustomobject]@{ id = 'x'; displayName = 'Org' }) }
        (Invoke-CSGraph 'organization/x' -Context $ctx).displayName | Should -Be 'Org'
    }
    It 'sends the bearer token, beta base and consistency header' {
        Mock -ModuleName CSToolkit Send-CSRequest { Resp 200 ([pscustomobject]@{ ok = $true }) } -ParameterFilter {
            $Uri -eq 'https://graph.microsoft.com/beta/users' -and $Headers.Authorization -eq 'Bearer tok' -and $Headers.ConsistencyLevel -eq 'eventual' }
        { Invoke-CSGraph '/users' -Beta -ConsistencyEventual -Context $ctx } | Should -Not -Throw
    }
    It 'retries 429 honouring Retry-After, then succeeds' {
        $script:n = 0
        Mock -ModuleName CSToolkit Start-Sleep {}
        Mock -ModuleName CSToolkit Send-CSRequest {
            $script:n++
            if ($script:n -lt 3) { Resp 429 $null @{ 'Retry-After' = '7' } } else { Resp 200 ([pscustomobject]@{ ok = $true }) }
        }
        (Invoke-CSGraph '/x' -Context $ctx).ok | Should -BeTrue
        $script:n | Should -Be 3
        Should -Invoke -ModuleName CSToolkit Start-Sleep -Times 2 -ParameterFilter { $Seconds -eq 7 }
    }
    It 'raises typed errors carrying status and code' -ForEach @(
        @{ Status = 401; Id = 'CSGraph.Unauthorized' }
        @{ Status = 403; Id = 'CSGraph.Forbidden' }
        @{ Status = 404; Id = 'CSGraph.NotFound' }
        @{ Status = 400; Id = 'CSGraph.Error' }
    ) {
        Mock -ModuleName CSToolkit Send-CSRequest { Resp $Status ([pscustomobject]@{ error = [pscustomobject]@{ code = 'Nope'; message = 'denied' } }) }
        try { Invoke-CSGraph '/x' -Context $ctx; throw 'should not reach' }
        catch {
            $_.FullyQualifiedErrorId | Should -Be $Id
            $_.TargetObject.Status | Should -Be $Status
            $_.TargetObject.Code | Should -Be 'Nope'
        }
    }
    It 'gives up with CSGraph.Throttled when retries are exhausted' {
        Mock -ModuleName CSToolkit Start-Sleep {}
        Mock -ModuleName CSToolkit Send-CSRequest { Resp 429 $null }
        try { Invoke-CSGraph '/x' -Context $ctx -MaxRetries 2; throw 'should not reach' }
        catch { $_.FullyQualifiedErrorId | Should -Be 'CSGraph.Throttled' }
        Should -Invoke -ModuleName CSToolkit Send-CSRequest -Times 3
    }
    It 'requires a context' {
        Disconnect-CSPartner
        { Invoke-CSGraph '/x' } | Should -Throw '*No tenant context*'
    }
}
