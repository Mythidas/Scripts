BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../Toolkit/CSToolkit.psd1') -Force
    $script:tenants = 1..3 | ForEach-Object { [pscustomobject]@{ TenantId = "id$_"; DisplayName = "T$_"; DefaultDomain = "t$_.onmicrosoft.com"; Customer = 'C' } }
}

Describe 'Invoke-CSForEachTenant' {
    It 'isolates failures, passes arguments and sets the tenant context per process' {
        $runs = $tenants | Invoke-CSForEachTenant -NoAuth -LogPath $TestDrive -ThrottleLimit 3 6>$null {
            param($t, $suffix)
            if ($t.DisplayName -eq 'T2') { throw 'boom' }
            (Get-CSContext).Tenant.TenantId + $suffix
        } -ArgumentList '-x'

        $runs.Count | Should -Be 3
        ($runs | Where-Object Tenant -eq 'T1').Output | Should -Be 'id1-x'
        ($runs | Where-Object Tenant -eq 'T3').Status | Should -Be 'Succeeded'
        $failed = $runs | Where-Object Tenant -eq 'T2'
        $failed.Status | Should -Be 'Failed'
        $failed.Errors | Should -Contain 'boom'
        Test-Path $failed.LogFile | Should -BeTrue
    }
    It 'marks non-terminating errors as SucceededWithErrors and keeps output' {
        $run = $tenants[0] | Invoke-CSForEachTenant -NoAuth -LogPath $TestDrive 6>$null { Write-Error 'soft'; 'still here' }
        $run.Status | Should -Be 'SucceededWithErrors'
        $run.Output | Should -Be 'still here'
    }
    It '-OutputOnly emits just the output' {
        $out = $tenants[0] | Invoke-CSForEachTenant -NoAuth -LogPath $TestDrive -OutputOnly 6>$null { 'a'; 'b' }
        $out | Should -Be @('a', 'b')
    }
    It 'stops a tenant that exceeds the timeout' -Tag Slow {
        $run = $tenants[0] | Invoke-CSForEachTenant -NoAuth -LogPath $TestDrive -TimeoutMinutes 0.01 6>$null { Start-Sleep 30 }
        $run.Status | Should -Be 'TimedOut'
    }
    It 'forwards -WhatIf to the tenant process' {
        $run = $tenants[0] | Invoke-CSForEachTenant -NoAuth -LogPath $TestDrive -WhatIf 6>$null { $WhatIfPreference }
        $run.Output | Should -BeTrue
    }
    It 'requires a partner session unless -NoAuth' {
        Disconnect-CSPartner
        { $tenants[0] | Invoke-CSForEachTenant -LogPath $TestDrive { 1 } } | Should -Throw '*Connect-CSPartner*'
    }
}

Describe 'Expand-CSTenantRun' {
    It 'passes results through and turns failed tenants into Error rows' {
        $runs = $tenants | Invoke-CSForEachTenant -NoAuth -LogPath $TestDrive 6>$null {
            param($t)
            if ($t.DisplayName -eq 'T2') { throw 'no gdap' }
            New-CSResult -CheckId 'X-1' -Category Test -Title 't' -Status Pass
        }
        $rows = @($runs | Expand-CSTenantRun)
        $rows.Count | Should -Be 3
        ($rows | Where-Object CheckId -eq 'X-1').Count | Should -Be 2
        $err = $rows | Where-Object CheckId -eq 'RUN-001'
        $err.Tenant | Should -Be 'T2'
        $err.Customer | Should -Be 'C'
        $err.Detail | Should -Be 'no gdap'
        $err.Status | Should -Be 'Error'
    }
}
