# ===============================================
# Export Shared Mailboxes with Graph User Properties (Licenses, Sign-ins, Manager)
# WITH Progress Bar - Delegates optional via switch
# ===============================================

param(
    [switch]$IncludeDelegates   # Add -IncludeDelegates when you want FullAccess/SendAs/etc.
)

# ---------------------------
# 1 Connect to Microsoft Graph + Exchange Online
# ---------------------------
Connect-MgGraph -Scopes `
    "User.Read.All",
    "Directory.Read.All",
    "AuditLog.Read.All",
    "Organization.Read.All"

Connect-ExchangeOnline

# ---------------------------
# 2 Import the friendly SKU CSV (same as your user script)
# ---------------------------
$skuCsvPath = "./SkuFriendlyNames.csv"
$skuFriendly = Import-Csv $skuCsvPath

$skuLookup = @{}
foreach ($row in $skuFriendly) {
    $skuLookup[$row.GUID] = $row.Product_Display_Name
}

# ---------------------------
# 3 Get all Shared Mailboxes
# ---------------------------
Write-Host "Retrieving all shared mailboxes..." -ForegroundColor Cyan
$sharedMailboxes = Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited

$totalMailboxes = $sharedMailboxes.Count
Write-Host "Found $totalMailboxes shared mailboxes. Starting export..." -ForegroundColor Green

# ---------------------------
# 4 Build export objects with Progress Bar
# ---------------------------
$exportShared = @()
$counter = 0

foreach ($mbx in $sharedMailboxes) {
    $counter++
    
    # Progress Bar
    $percentComplete = [math]::Round(($counter / $totalMailboxes) * 100, 0)
    $status = "Processing: $($mbx.DisplayName)  ($counter of $totalMailboxes)"
    
    Write-Progress `
        -Activity "Exporting Shared Mailboxes" `
        -Status $status `
        -PercentComplete $percentComplete `
        -CurrentOperation "Getting Graph data"

    # Get Graph user data (licenses, sign-ins, manager, etc.)
    $graphUser = Get-MgUser -UserId $mbx.ExternalDirectoryObjectId `
        -Property DisplayName, UserPrincipalName, UserType, CompanyName, JobTitle, SignInActivity, AssignedLicenses `
        -ExpandProperty Manager `
        -ErrorAction SilentlyContinue

    # Friendly license mapping (same as your original user script)
    $licenses = @()
    if ($graphUser.AssignedLicenses) {
        foreach ($license in $graphUser.AssignedLicenses) {
            $skuId = $license.SkuId.ToString()
            if ($skuLookup.ContainsKey($skuId)) {
                $licenses += $skuLookup[$skuId]
            } else {
                $licenses += $skuId
            }
        }
    }

    # Manager info
    $managerName = ""
    $managerEmail = ""
    if ($graphUser.Manager -and $graphUser.Manager.AdditionalProperties) {
        $managerName = $graphUser.Manager.AdditionalProperties.displayName ?? ""
        $managerEmail = $graphUser.Manager.AdditionalProperties.userPrincipalName ?? ""
    }

    # Delegates (only if switch is used)
    $fullAccess = ""
    $sendAs = ""
    $sendOnBehalf = ""

    if ($IncludeDelegates) {
        Write-Progress -Activity "Exporting Shared Mailboxes" -Status $status -CurrentOperation "Getting delegates (this may be slow)"
        
        $fullAccess = (Get-MailboxPermission -Identity $mbx.Identity |
            Where-Object { $_.AccessRights -like "*FullAccess*" -and $_.User -notlike "NT AUTHORITY\SELF" } |
            Select-Object -ExpandProperty User) -join "; "

        $sendAs = (Get-RecipientPermission -Identity $mbx.Identity |
            Where-Object { $_.AccessRights -like "*SendAs*" -and $_.Trustee -notlike "NT AUTHORITY\SELF" } |
            Select-Object -ExpandProperty Trustee) -join "; "

        $sendOnBehalf = (Get-Mailbox -Identity $mbx.Identity).GrantSendOnBehalfTo -join "; "
    }

    # Mailbox statistics
    $stats = Get-MailboxStatistics -Identity $mbx.Identity -ErrorAction SilentlyContinue

    # Build object
    $exportShared += [PSCustomObject]@{
        DisplayName                  = $mbx.DisplayName
        UserPrincipalName            = $mbx.UserPrincipalName
        PrimarySmtpAddress           = $mbx.PrimarySmtpAddress
        UserType                     = $graphUser.UserType ?? "Member"
        CompanyName                  = $graphUser.CompanyName ?? ""
        JobTitle                     = $graphUser.JobTitle ?? ""
        Manager                      = $managerName
        ManagerEmail                 = $managerEmail
        LastInteractiveSignIn        = $graphUser.SignInActivity.LastSignInDateTime
        LastNonInteractiveSignIn     = $graphUser.SignInActivity.LastNonInteractiveSignInDateTime
        LastLogonTime                = $stats.LastLogonTime
        LicensesAssigned             = ($licenses -join ", ")
        IsLicensed                   = if ($licenses.Count -gt 0) { "Yes" } else { "No" }
        FullAccessDelegates          = $fullAccess
        SendAsDelegates              = $sendAs
        SendOnBehalfDelegates        = $sendOnBehalf
        HiddenFromAddressLists       = $mbx.HiddenFromAddressListsEnabled
        WhenCreated                  = $mbx.WhenCreated
        WhenChanged                  = $mbx.WhenChanged
    }
}

# Clear progress bar
Write-Progress -Activity "Exporting Shared Mailboxes" -Completed

# ---------------------------
# 5 Export to CSV
# ---------------------------
$exportShared | Export-Csv "Entra_Shared_Mailboxes_WithGraphProperties.csv" -NoTypeInformation -Encoding UTF8

Write-Host "`nExport complete!" -ForegroundColor Green
Write-Host "File: Entra_Shared_Mailboxes_WithGraphProperties.csv" -ForegroundColor Cyan
Write-Host "Total shared mailboxes processed: $totalMailboxes" -ForegroundColor Cyan

if ($IncludeDelegates) {
    Write-Host "Delegates were included (FullAccess, SendAs, SendOnBehalf)" -ForegroundColor Yellow
} else {
    Write-Host "Delegates were skipped for faster execution. Use -IncludeDelegates to enable them." -ForegroundColor Yellow
}
