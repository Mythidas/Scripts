#Requires -Modules Microsoft.Graph.Users

<#
    Update-EntraID-Users-JobTitle-Department-OfficeLocation.ps1

    CSV format example:
    User,Job Title,Department,Location
    john.doe@contoso.com,Software Engineer,Engineering,Chicago
    alice.johnson@contoso.com,Senior Accountant,Finance,Dallas

    - "User" = UserPrincipalName (UPN)
    - "Job Title" updates Graph property: jobTitle
    - "Department" updates Graph property: department
    - "Location" updates Graph property: officeLocation
    - Skips rows with empty UPN
    - Idempotent: only updates when values actually changed
    - Supports -WhatIf through SupportsShouldProcess
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath
)

# ════════════════════════════════════════════════════════════════
#  HELPER FUNCTIONS
# ════════════════════════════════════════════════════════════════

function Get-CsvValue {
    param (
        [Parameter(Mandatory = $true)]
        [psobject]$Row,

        [Parameter(Mandatory = $true)]
        [string]$ColumnName
    )

    $property = $Row.PSObject.Properties[$ColumnName]

    if ($null -eq $property -or $null -eq $property.Value) {
        return $null
    }

    return $property.Value.ToString().Trim()
}

function Add-UpdateIfChanged {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$UpdateBody,

        [Parameter(Mandatory = $true)]
        [string]$GraphPropertyName,

        [AllowNull()]
        [string]$CurrentValue,

        [AllowNull()]
        [string]$NewValue
    )

    if ([string]::IsNullOrWhiteSpace($NewValue)) {
        return
    }

    if ($NewValue -ne $CurrentValue) {
        $UpdateBody[$GraphPropertyName] = $NewValue
    }
}

# ════════════════════════════════════════════════════════════════
#  VALIDATE CSV PATH
# ════════════════════════════════════════════════════════════════

if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
    Write-Error "CSV file not found: $CsvPath"
    exit 1
}

# ════════════════════════════════════════════════════════════════
#  READ CSV
# ════════════════════════════════════════════════════════════════

try {
    $records = @(Import-Csv -LiteralPath $CsvPath -ErrorAction Stop)
}
catch {
    Write-Error "Failed to import CSV file: $($_.Exception.Message)"
    exit 1
}

if ($records.Count -eq 0) {
    Write-Warning "CSV contains no records."
    exit 0
}

$headers = $records[0].PSObject.Properties.Name

if ($headers -notcontains 'User') {
    Write-Error 'CSV is missing required column: User'
    exit 1
}

$optionalColumns = @('Job Title', 'Department', 'Location')
$presentOptionalColumns = $optionalColumns | Where-Object { $headers -contains $_ }

if ($presentOptionalColumns.Count -eq 0) {
    Write-Error 'CSV must contain at least one update column: Job Title, Department, or Location'
    exit 1
}

Write-Host "Loaded $($records.Count) records from CSV" -ForegroundColor Cyan
Write-Host "Update columns detected: $($presentOptionalColumns -join ', ')" -ForegroundColor Cyan

# ════════════════════════════════════════════════════════════════
#  CONNECT TO MICROSOFT GRAPH
# ════════════════════════════════════════════════════════════════

try {
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan

    Connect-MgGraph -Scopes "User.ReadWrite.All" -NoWelcome -ErrorAction Stop

    $context = Get-MgContext
    Write-Host "Connected as: $($context.Account)" -ForegroundColor Green
}
catch {
    Write-Error "Failed to connect to Microsoft Graph: $($_.Exception.Message)"
    exit 1
}

# ════════════════════════════════════════════════════════════════
#  PROCESS USERS
# ════════════════════════════════════════════════════════════════

$processed = 0
$updated   = 0
$skipped   = 0
$errors    = 0

foreach ($row in $records) {
    $processed++

    $upn = Get-CsvValue -Row $row -ColumnName 'User'

    if ([string]::IsNullOrWhiteSpace($upn)) {
        Write-Warning "[$processed] Skipping row with empty/missing UPN"
        $skipped++
        continue
    }

    Write-Host "[$processed] $upn ..." -NoNewline -ForegroundColor White

    try {
        $user = Get-MgUser `
            -UserId $upn `
            -Property 'Id,UserPrincipalName,JobTitle,Department,OfficeLocation' `
            -ErrorAction Stop

        if ($null -eq $user) {
            Write-Host " User not found" -ForegroundColor Yellow
            $skipped++
            continue
        }

        $updateBody = @{}

        $newJobTitle   = Get-CsvValue -Row $row -ColumnName 'Job Title'
        $newDepartment = Get-CsvValue -Row $row -ColumnName 'Department'
        $newLocation   = Get-CsvValue -Row $row -ColumnName 'Location'

        Add-UpdateIfChanged `
            -UpdateBody $updateBody `
            -GraphPropertyName 'jobTitle' `
            -CurrentValue $user.JobTitle `
            -NewValue $newJobTitle

        Add-UpdateIfChanged `
            -UpdateBody $updateBody `
            -GraphPropertyName 'department' `
            -CurrentValue $user.Department `
            -NewValue $newDepartment

        Add-UpdateIfChanged `
            -UpdateBody $updateBody `
            -GraphPropertyName 'officeLocation' `
            -CurrentValue $user.OfficeLocation `
            -NewValue $newLocation

        if ($updateBody.Count -eq 0) {
            Write-Host " No changes needed" -ForegroundColor DarkGray
            $skipped++
            continue
        }

        $changeSummary = ($updateBody.GetEnumerator() | ForEach-Object {
            "$($_.Key)='$($_.Value)'"
        }) -join '; '

        if ($PSCmdlet.ShouldProcess($upn, "Update user properties: $changeSummary")) {
            Update-MgUser `
                -UserId $user.Id `
                -BodyParameter $updateBody `
                -ErrorAction Stop

            Write-Host " Updated: $changeSummary" -ForegroundColor Green
        }
        else {
            Write-Host " WhatIf: $changeSummary" -ForegroundColor DarkYellow
        }

        $updated++
    }
    catch {
        Write-Host " ERROR" -ForegroundColor Red
        Write-Error "[$processed] $upn - $($_.Exception.Message)"
        $errors++
    }
}

# ════════════════════════════════════════════════════════════════
#  SUMMARY
# ════════════════════════════════════════════════════════════════

Write-Host "`nSummary:" -ForegroundColor Cyan
Write-Host "  Processed : $processed"
Write-Host "  Updated   : $updated" -ForegroundColor Green
Write-Host "  Skipped   : $skipped" -ForegroundColor DarkGray
Write-Host "  Errors    : $errors" -ForegroundColor Red

Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null

Write-Host "`nDone." -ForegroundColor Cyan
