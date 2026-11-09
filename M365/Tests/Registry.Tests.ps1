BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../Toolkit/CSToolkit.psd1') -Force
}

Describe 'Merge-CSTenantRegistry' {
    BeforeAll {
        $existing = @(
            [pscustomobject]@{ TenantId = 'AAA'; DefaultDomain = 'a.onmicrosoft.com'; DisplayName = 'Old A'; Customer = 'Acme'; Group = 'Dental'; Profile = 'Standard'; Features = 'Intune'; Enabled = 'true'; GdapStatus = 'Active'; Notes = 'keep me' }
            [pscustomobject]@{ TenantId = 'GONE'; DefaultDomain = 'g.onmicrosoft.com'; DisplayName = 'Gone'; Customer = 'Gone'; Group = ''; Profile = ''; Features = ''; Enabled = 'true'; GdapStatus = 'Active'; Notes = '' }
        )
        $source = @(
            [pscustomobject]@{ TenantId = 'aaa'; DisplayName = 'New A'; DefaultDomain = ''; GdapActive = $true }
            [pscustomobject]@{ TenantId = 'BBB'; DisplayName = 'B Corp'; DefaultDomain = 'b.onmicrosoft.com'; GdapActive = $true }
        )
        $merge = & (Get-Module CSToolkit) { param($e, $s) Merge-CSTenantRegistry -Existing $e -Source $s } $existing $source
    }

    It 'never overwrites manual columns' {
        $a = $merge.Rows | Where-Object TenantId -eq 'AAA'
        $a.Customer | Should -Be 'Acme'
        $a.Group | Should -Be 'Dental'
        $a.Profile | Should -Be 'Standard'
        $a.Features | Should -Be 'Intune'
        $a.Notes | Should -Be 'keep me'
    }
    It 'refreshes synced columns but keeps a known domain when the source has none' {
        $a = $merge.Rows | Where-Object TenantId -eq 'AAA'
        $a.DisplayName | Should -Be 'New A'
        $a.DefaultDomain | Should -Be 'a.onmicrosoft.com'
    }
    It 'matches tenant ids case-insensitively without duplicating' {
        @($merge.Rows | Where-Object { $_.TenantId -ieq 'aaa' }).Count | Should -Be 1
    }
    It 'adds new tenants with Customer defaulted to the name' {
        $merge.Added | Should -Be @('BBB')
        ($merge.Rows | Where-Object TenantId -eq 'BBB').Customer | Should -Be 'B Corp'
    }
    It 'flags tenants that left GDAP as Missing instead of deleting them' {
        $merge.Missing | Should -Be @('GONE')
        ($merge.Rows | Where-Object TenantId -eq 'GONE').GdapStatus | Should -Be 'Missing'
    }
}

Describe 'Get-CSTenant' {
    BeforeAll {
        $csv = Join-Path $TestDrive 'tenants.csv'
        @'
TenantId,DefaultDomain,DisplayName,Customer,Group,Profile,Features,Enabled,GdapStatus,Notes
1,a.onmicrosoft.com,Acme North,Acme,Dental;NorthGA,Standard,Intune;EntraP2,true,Active,
2,b.onmicrosoft.com,Acme South,Acme,Dental,Baseline,,true,Active,
3,c.onmicrosoft.com,Contoso,Contoso,Retail,Standard,Intune,false,Active,
4,d.onmicrosoft.com,Fabrikam,Fabrikam,,Standard,,true,Missing,
'@ | Set-Content $csv
    }

    It 'skips disabled and no-longer-GDAP tenants by default' {
        (Get-CSTenant -Path $csv).TenantId | Should -Be @('1', '2')
    }
    It '-All includes them' {
        @(Get-CSTenant -Path $csv -All).Count | Should -Be 4
    }
    It 'filters by customer with wildcards' {
        @(Get-CSTenant -Path $csv -Customer 'Acm*').Count | Should -Be 2
    }
    It 'filters by any group tag' {
        (Get-CSTenant -Path $csv -Group NorthGA).TenantId | Should -Be '1'
    }
    It 'requires every listed feature' {
        (Get-CSTenant -Path $csv -Feature Intune, EntraP2).TenantId | Should -Be '1'
        @(Get-CSTenant -Path $csv -Feature Intune -All).Count | Should -Be 2
    }
    It 'matches Name against display name or domain' {
        (Get-CSTenant -Path $csv -Name 'b.onmicrosoft.com').TenantId | Should -Be '2'
    }
    It 'exposes tags as arrays' {
        (Get-CSTenant -Path $csv -TenantId 1).Group | Should -Be @('Dental', 'NorthGA')
    }
    It 'tells the user to sync when the registry is missing' {
        { Get-CSTenant -Path (Join-Path $TestDrive 'nope.csv') } | Should -Throw '*Sync-CSTenantRegistry*'
    }
}

Describe 'Module manifest' {
    It 'exports exactly the functions in Public/' {
        $manifest = Import-PowerShellDataFile (Join-Path $PSScriptRoot '../Toolkit/CSToolkit.psd1')
        $public   = (Get-ChildItem (Join-Path $PSScriptRoot '../Toolkit/Public') -Filter *.ps1).BaseName
        $manifest.FunctionsToExport | Sort-Object | Should -Be ($public | Sort-Object)
        (Get-Command -Module CSToolkit).Name | Sort-Object | Should -Be ($public | Sort-Object)
    }
}
