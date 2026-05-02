#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Users.Actions, Microsoft.Graph.Users
<#
.SYNOPSIS
    Removes ALL assigned Microsoft 365 licenses from users listed in a CSV file.
    Optionally disables the user accounts as well.

.PARAMETER CsvPath
    Path to CSV file that contains at least a column named UserPrincipalName

.PARAMETER DisableUsers
    Switch to also disable the user accounts (set AccountEnabled = $false)

.EXAMPLE
    .\Remove-AllLicensesFromCsv.ps1 -CsvPath "C:\temp\users_to_remove_licenses.csv"

.EXAMPLE
    .\Remove-AllLicensesFromCsv.ps1 -CsvPath "C:\temp\users_to_remove_licenses.csv" -DisableUsers

.WARNING
    This script REMOVES ALL licenses from the listed users.
    When -DisableUsers is used, it also disables the accounts.
    There is NO selective license removal — everything gets removed.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [switch]$DisableUsers
)

# ──────────────────────────────────────────────────────────────────────
# CONNECT
# ──────────────────────────────────────────────────────────────────────
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan

# Recommended scopes
$requiredScopes = @(
    "User.ReadWrite.All",
    "Directory.ReadWrite.All",
    "Organization.Read.All"
)

Connect-MgGraph -Scopes $requiredScopes -NoWelcome

$currentScopes = (Get-MgContext).Scopes
if (-not ($requiredScopes | Where-Object { $_ -notin $currentScopes })) {
    Write-Warning "Not all required scopes are present. Current scopes: $($currentScopes -join ', ')"
}

# ──────────────────────────────────────────────────────────────────────
# READ USERS
# ──────────────────────────────────────────────────────────────────────
Write-Host "Reading users from CSV..." -ForegroundColor Cyan
try {
    $users = Import-Csv -Path $CsvPath -ErrorAction Stop
}
catch {
    Write-Error "Failed to read CSV file: $_"
    exit
}

$upnColumn = 'UserPrincipalName'
if ($upnColumn -notin $users[0].PSObject.Properties.Name) {
    Write-Error "CSV must contain a column named 'UserPrincipalName'"
    exit
}

$validUsers = @()
$invalidUsers = @()

foreach ($row in $users) {
    $upn = $row.$upnColumn -replace '\s','' # remove accidental spaces
    if ($upn -match '^[\w\.\-]+@[\w\.\-]+\.[a-zA-Z]{2,}$') {
        $validUsers += $upn
    }
    else {
        $invalidUsers += $upn
        Write-Warning "Invalid UPN skipped: $upn"
    }
}

Write-Host "Found $($validUsers.Count) valid users in the CSV" -ForegroundColor Green
if ($invalidUsers.Count -gt 0) {
    Write-Host "Skipped $($invalidUsers.Count) invalid looking UPNs" -ForegroundColor Yellow
}

if ($validUsers.Count -eq 0) {
    Write-Error "No valid UserPrincipalNames found in the CSV."
    exit
}

# ──────────────────────────────────────────────────────────────────────
# MAIN LOOP
# ──────────────────────────────────────────────────────────────────────
Write-Host "`nStarting license removal..." -ForegroundColor Cyan
if ($DisableUsers) {
    Write-Host "→ Also disabling user accounts (AccountEnabled = `$false)" -ForegroundColor Yellow
}

$i = 0
foreach ($upn in $validUsers) {
    $i++
    Write-Host "($i/$($validUsers.Count)) $upn" -NoNewline -ForegroundColor DarkCyan

    try {
        $user = Get-MgUser -UserId $upn -ErrorAction Stop -Property Id, AssignedLicenses, UserPrincipalName, AccountEnabled

        $licenseAction = ""
        if ($user.AssignedLicenses.Count -gt 0) {
            $licensesToRemove = $user.AssignedLicenses | ForEach-Object { $_.SkuId }

            if ($PSCmdlet.ShouldProcess($upn, "Remove $($user.AssignedLicenses.Count) licenses")) {
                $null = Set-MgUserLicense -UserId $user.Id `
                    -AddLicenses @() `
                    -RemoveLicenses $licensesToRemove `
                    -ErrorAction Stop
                $licenseAction = " → removed $($licensesToRemove.Count) licenses"
            }
            else {
                $licenseAction = " → would remove $($licensesToRemove.Count) licenses"
            }
        }
        else {
            $licenseAction = " → already has no licenses"
        }

        # Disable user if switch is present
        if ($DisableUsers) {
            if ($PSCmdlet.ShouldProcess($upn, "Disable user account")) {
                Update-MgUser -UserId $user.Id -AccountEnabled:$false -ErrorAction Stop
                $disableAction = " + disabled"
            }
            else {
                $disableAction = " + would disable"
            }
        }

        Write-Host "$licenseAction$($disableAction)" -ForegroundColor Green
    }
    catch {
        Write-Host " → ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }

    # Small delay to be kind to the Graph API
    Start-Sleep -Milliseconds 400
}

Write-Host "`nFinished." -ForegroundColor Cyan
Disconnect-MgGraph -ErrorAction SilentlyContinue
