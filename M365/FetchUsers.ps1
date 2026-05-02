# ===============================================
# Export Entra Enabled Members with Sign-ins, Friendly Licenses, and Manager Email
# ===============================================
param(
    [Parameter(Mandatory=$false)]
    [string]$TenantId = "",

    [Parameter(Mandatory=$false)]
    [string[]]$Domains = @()
)

# Disconnect existing session
if (Get-MgContext) {
    Disconnect-MgGraph | Out-Null
}

# Connect
$connectParams = @{
    Scopes = "User.Read.All","Directory.Read.All","AuditLog.Read.All","Organization.Read.All"
}
if ($TenantId) { $connectParams.TenantId = $TenantId }
Connect-MgGraph @connectParams

# Import friendly SKU names
$skuCsvPath = "./SkuFriendlyNames.csv"
$skuFriendly = Import-Csv $skuCsvPath
$skuLookup = @{}
foreach ($row in $skuFriendly) {
    $skuLookup[$row.GUID] = $row.Product_Display_Name
}

# Build filter
$filter = "accountEnabled eq true and userType eq 'Member'"

if ($Domains.Count -gt 0) {
    $domainFilters = foreach ($d in $Domains) {
        $clean = $d.TrimStart('@')
        "endsWith(userPrincipalName, '@$clean')"
    }
    $filter += " and (" + ($domainFilters -join " or ") + ")"
}

Write-Host "Using filter: $filter" -ForegroundColor Cyan

# Get users - Using advanced query parameters
$users = Get-MgUser -All `
    -Filter $filter `
    -Property DisplayName, UserPrincipalName, UserType, CompanyName, JobTitle, SignInActivity, AssignedLicenses, Manager `
    -ConsistencyLevel eventual `
    -CountVariable userCount

# Fetch manager details separately (this avoids the expand limitation)
Write-Host "Retrieving manager information..." -ForegroundColor Cyan

$export = foreach ($user in $users) {
    $managerName = ""
    $managerEmail = ""

    if ($user.Manager) {
        try {
            $manager = Get-MgUser -UserId $user.Manager.Id -Property DisplayName, UserPrincipalName -ErrorAction Stop
            $managerName = $manager.DisplayName
            $managerEmail = $manager.UserPrincipalName
        }
        catch {
            # Manager might be external or deleted
            $managerName = "Error retrieving manager"
        }
    }

    $licenses = foreach ($license in $user.AssignedLicenses) {
        $skuId = $license.SkuId.ToString()
        $skuLookup[$skuId] ?? $skuId
    }

    $lastInteractive = if ($user.SignInActivity.LastSignInDateTime) {
        $user.SignInActivity.LastSignInDateTime.ToString("yyyy-MM-dd")
    } else { "" }

    $lastNonInteractive = if ($user.SignInActivity.LastNonInteractiveSignInDateTime) {
        $user.SignInActivity.LastNonInteractiveSignInDateTime.ToString("yyyy-MM-dd")
    } else { "" }

    [PSCustomObject]@{
        DisplayName               = $user.DisplayName
        UserPrincipalName         = $user.UserPrincipalName
        UserType                  = $user.UserType
        CompanyName               = $user.CompanyName
        JobTitle                  = $user.JobTitle
        Manager                   = $managerName
        ManagerEmail              = $managerEmail
        LastInteractiveSignIn     = $lastInteractive
        LastNonInteractiveSignIn  = $lastNonInteractive
        LicensesAssigned          = ($licenses -join ", ")
    }
}

# Export
$filename = "Entra_Enabled_Member_Users_FriendlyLicenses_WithManager.csv"
if ($Domains.Count -gt 0) {
    $domainList = ($Domains | ForEach-Object { $_.TrimStart('@') }) -join "_"
    $filename = "Entra_Enabled_Member_Users_$($domainList)_WithManager.csv"
}

$export | Export-Csv $filename -NoTypeInformation -Encoding UTF8
Write-Host "Export complete: $filename ($($export.Count) users)" -ForegroundColor Green
