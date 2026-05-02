#Requires -Modules Microsoft.Graph.Users

<#
    Update-EntraID-Users-JobTitle-Department.ps1

    CSV format example:
    User,Job Title,Department
    john.doe@contoso.com,Software Engineer,Engineering
    alice.johnson@contoso.com,Senior Accountant,Finance

    - "User" = UserPrincipalName (UPN)
    - Only updates JobTitle and Department when different
    - Skips rows with empty UPN
    - Idempotent (only updates when values actually changed)
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,

    [switch]$WhatIf
)

# ════════════════════════════════════════════════════════════════
#  CONNECT TO MICROSOFT GRAPH
# ════════════════════════════════════════════════════════════════

Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan

Connect-MgGraph -Scopes "User.ReadWrite.All" -NoWelcome -ErrorAction Stop

Write-Host "Connected as: $((Get-MgContext).Account)" -ForegroundColor Green

# ════════════════════════════════════════════════════════════════
#  READ CSV
# ════════════════════════════════════════════════════════════════

if (-not (Test-Path $CsvPath -PathType Leaf)) {
    Write-Error "CSV file not found: $CsvPath"
    exit 1
}

$records = Import-Csv $CsvPath
Write-Host "Loaded $($records.Count) records from CSV" -ForegroundColor Cyan

# ════════════════════════════════════════════════════════════════
#  PROCESS USERS
# ════════════════════════════════════════════════════════════════

$processed = 0
$updated   = 0
$skipped   = 0
$errors    = 0

foreach ($row in $records) {
    $processed++
    $upn = $row.User?.Trim()

    if ([string]::IsNullOrWhiteSpace($upn)) {
        Write-Warning "[$processed] Skipping row with empty/missing UPN"
        $skipped++
        continue
    }

    Write-Host "[$processed] $upn ..." -NoNewline -ForegroundColor White

    try {
        # Get current user properties
        $user = Get-MgUser -UserId $upn -Property Id,UserPrincipalName,JobTitle,Department `
            -ErrorAction Stop

        if (-not $user) {
            Write-Warning "User not found in Entra ID"
            $skipped++
            continue
        }

        $updateBody = @{}

        # Job Title
        $newJobTitle = $row.'Job Title'?.Trim()
        if ($newJobTitle -and $newJobTitle -ne $user.JobTitle) {
            $updateBody["jobTitle"] = $newJobTitle
        }

        # Department
        $newDepartment = $row.Department?.Trim()
        if ($newDepartment -and $newDepartment -ne $user.Department) {
            $updateBody["department"] = $newDepartment
        }

        if ($updateBody.Count -gt 0) {
            Write-Host " UPDATING" -NoNewline -ForegroundColor Yellow

            if ($WhatIf) {
                Write-Host " (WhatIf - no change made)" -ForegroundColor DarkYellow
            }
            else {
                Update-MgUser -UserId $user.Id -BodyParameter $updateBody | Out-Null
                Write-Host " → Done" -ForegroundColor Green
            }

            $updated++
        }
        else {
            Write-Host " No changes needed" -ForegroundColor DarkGray
            $skipped++
        }
    }
    catch {
        Write-Host " ERROR" -ForegroundColor Red
        Write-Error "  $_"
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
Write-Host "  Errors    : $errors"   -ForegroundColor Red

Disconnect-MgGraph -ErrorAction SilentlyContinue

Write-Host "`nDone." -ForegroundColor Cyan
