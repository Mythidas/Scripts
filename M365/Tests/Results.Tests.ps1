BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../Toolkit/CSToolkit.psd1') -Force
    $script:tenant = [pscustomobject]@{ TenantId = 't1'; DisplayName = 'Acme'; Customer = 'AcmeCo' }
}

Describe 'New-CSResult' {
    It 'takes tenant fields from the current context' {
        Set-CSContext -Tenant $tenant -Token $null
        $r = New-CSResult -CheckId 'CA-001' -Category CA -Title 'x' -Status Pass
        $r.TenantId | Should -Be 't1'
        $r.Customer | Should -Be 'AcmeCo'
    }
    It 'rejects unknown statuses' {
        { New-CSResult -CheckId a -Category b -Title c -Status Maybe -Tenant $tenant } | Should -Throw
    }
}

Describe 'Export-CSResult / Get-CSResultSummary' {
    BeforeAll {
        $results = @(
            New-CSResult -Tenant $tenant -CheckId 'A-1' -Category X -Title 't' -Status Fail -Affected 'u1', 'u2' -Actual @{ state = 'off' }
            New-CSResult -Tenant $tenant -CheckId 'A-2' -Category X -Title 't' -Status Pass
            New-CSResult -Tenant $tenant -CheckId 'A-3' -Category X -Title 't' -Status Error
        )
    }
    It 'writes flat CSV and full JSON' {
        $files = $results | Export-CSResult -Name T -Path $TestDrive
        $files.Count | Should -Be 2
        $csv = Import-Csv ($files | Where-Object { $_ -like '*.csv' })
        $csv.Count | Should -Be 3
        ($csv | Where-Object CheckId -eq 'A-1').Affected | Should -Be 'u1; u2'
        ($csv | Where-Object CheckId -eq 'A-1').Actual | Should -Be '{"state":"off"}'
        $json = Get-Content ($files | Where-Object { $_ -like '*.json' }) -Raw | ConvertFrom-Json
        $json[0].Affected | Should -Be @('u1', 'u2')
    }
    It 'summarises per tenant' {
        $s = $results | Get-CSResultSummary
        $s.Total | Should -Be 3
        $s.Fail | Should -Be 1
        $s.Error | Should -Be 1
        $s.Pass | Should -Be 1
    }
}
