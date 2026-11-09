#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement, ExchangeOnlineManagement

<#
    Hide-LicensedUsersFromGAL.ps1

    Finds every user assigned one or more license SKUs (via Microsoft Graph)
    and hides their Exchange Online recipient from the GAL.

    List the tenant's SKUs first to get the exact part number:
    .\Hide-LicensedUsersFromGAL.ps1 -ListSkus

    Preview (lists exactly which accounts would be hidden, no changes):
    .\Hide-LicensedUsersFromGAL.ps1 -SkuPartNumber M365_F1_COMM -WhatIf

    Hide them:
    .\Hide-LicensedUsersFromGAL.ps1 -SkuPartNumber M365_F1_COMM

    - -SkuPartNumber accepts multiple values and wildcards (e.g. "*F1*")
    - Microsoft 365 F1 is usually M365_F1_COMM; note SPE_F1 is Microsoft 365 F3.
      Always confirm with -ListSkus.
    - Each licensed user is classified as:
        Hide          mail-enabled and visible in the GAL -> will be hidden
        AlreadyHidden already hidden, nothing to do
        NoMailbox     not mail-enabled in Exchange, so not in the GAL at all
        DirSynced     synced from on-prem AD; must be hidden there
                      (msExchHideFromAddressLists), Exchange Online can't set it
        OtherLicense  also holds a non-target license; skipped only when
                      -SkipUsersWithOtherLicenses is used
        Unsupported   recipient type this script doesn't modify
    - Use -ReportPath to export the full classification to CSV
    - Up to -BulkThreshold users (default 1000) are looked up individually
      with a progress bar; above that, all recipients are pulled in one pass
    - Use -WhatIf to preview without making changes
#>

[CmdletBinding(DefaultParameterSetName = 'Hide')]
param (
    [Parameter(Mandatory = $true, ParameterSetName = 'Hide')]
    [string[]]$SkuPartNumber,

    [Parameter(ParameterSetName = 'Hide')]
    [switch]$SkipUsersWithOtherLicenses,

    [Parameter(ParameterSetName = 'Hide')]
    [string]$ReportPath,

    [Parameter(ParameterSetName = 'Hide')]
    [int]$BulkThreshold = 1000,

    [Parameter(ParameterSetName = 'Hide')]
    [switch]$WhatIf,

    [Parameter(Mandatory = $true, ParameterSetName = 'List')]
    [switch]$ListSkus
)

# ════════════════════════════════════════════════════════════════
#  HELPERS
# ════════════════════════════════════════════════════════════════

$exoConnected = $false

function Disconnect-All {
    if ($script:exoConnected) {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    }
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}

function Stop-Script([string]$Message) {
    Write-Error $Message
    Disconnect-All
    exit 1
}

function Write-Table($Rows, [string[]]$Columns) {
    $Rows | Format-Table $Columns -AutoSize | Out-String -Width 250 | Write-Host
}

# ════════════════════════════════════════════════════════════════
#  CONNECT TO MICROSOFT GRAPH
# ════════════════════════════════════════════════════════════════

Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan

try {
    Connect-MgGraph -Scopes "Organization.Read.All", "User.Read.All" -NoWelcome -ErrorAction Stop
}
catch {
    Write-Error "Failed to connect to Microsoft Graph: $_"
    exit 1
}

Write-Host "Connected as: $((Get-MgContext).Account)" -ForegroundColor Green

# ════════════════════════════════════════════════════════════════
#  RESOLVE SKUS
# ════════════════════════════════════════════════════════════════

Write-Host "Fetching tenant licenses..." -ForegroundColor Cyan

try {
    $allSkus = @(Get-MgSubscribedSku -All -ErrorAction Stop)
}
catch {
    Stop-Script "Failed to read subscribed SKUs: $_"
}

$skuNameById = @{}
foreach ($s in $allSkus) { $skuNameById["$($s.SkuId)"] = $s.SkuPartNumber }

if ($ListSkus) {
    Write-Host "`nSubscribed SKUs:" -ForegroundColor Cyan
    $rows = $allSkus | Sort-Object SkuPartNumber | ForEach-Object {
        [pscustomobject]@{
            SkuPartNumber = $_.SkuPartNumber
            Assigned      = $_.ConsumedUnits
            Purchased     = $_.PrepaidUnits.Enabled
            SkuId         = $_.SkuId
        }
    }
    Write-Table $rows 'SkuPartNumber', 'Assigned', 'Purchased', 'SkuId'
    Disconnect-All
    exit 0
}

$targetSkus = @($allSkus | Where-Object {
    $part = $_.SkuPartNumber
    $SkuPartNumber | Where-Object { $part -like $_ }
})

if ($targetSkus.Count -eq 0) {
    Stop-Script "No subscribed SKU matches '$($SkuPartNumber -join "', '")'. Run with -ListSkus to see what's available."
}

$targetSkuIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($s in $targetSkus) {
    [void]$targetSkuIds.Add("$($s.SkuId)")
    Write-Host "  Target SKU: $($s.SkuPartNumber) ($($s.ConsumedUnits) assigned)" -ForegroundColor Green
}

# ════════════════════════════════════════════════════════════════
#  FIND LICENSED USERS
# ════════════════════════════════════════════════════════════════

Write-Host "Finding licensed users..." -ForegroundColor Cyan

$users = [ordered]@{}

foreach ($sku in $targetSkus) {
    try {
        $found = Get-MgUser `
            -Filter "assignedLicenses/any(x:x/skuId eq $($sku.SkuId))" `
            -Property Id, DisplayName, UserPrincipalName, AccountEnabled, AssignedLicenses, OnPremisesSyncEnabled `
            -ConsistencyLevel eventual `
            -CountVariable skuUserCount `
            -All `
            -ErrorAction Stop
    }
    catch {
        Stop-Script "Failed to query users for $($sku.SkuPartNumber): $_"
    }

    Write-Host "  $($sku.SkuPartNumber): $skuUserCount user(s)" -ForegroundColor DarkGray

    foreach ($u in $found) {
        if (-not $users.Contains($u.Id)) {
            $otherSkus = @($u.AssignedLicenses |
                Where-Object { -not $targetSkuIds.Contains("$($_.SkuId)") } |
                ForEach-Object { $skuNameById["$($_.SkuId)"] ?? "$($_.SkuId)" })

            $users[$u.Id] = [pscustomobject]@{
                DisplayName       = $u.DisplayName
                UserPrincipalName = $u.UserPrincipalName
                AccountEnabled    = $u.AccountEnabled
                DirSynced         = [bool]$u.OnPremisesSyncEnabled
                OtherLicenses     = $otherSkus -join '; '
                RecipientType     = ''
                Status            = ''
                Result            = ''
                ObjectId          = $u.Id
                Recipient         = $null
            }
        }
    }
}

Write-Host "  $($users.Count) unique licensed user(s)" -ForegroundColor Green

if ($users.Count -eq 0) {
    Write-Host "`nNothing to do." -ForegroundColor Cyan
    Disconnect-All
    exit 0
}

# ════════════════════════════════════════════════════════════════
#  CONNECT TO EXCHANGE ONLINE
# ════════════════════════════════════════════════════════════════

Write-Host "Connecting to Exchange Online..." -ForegroundColor Cyan

try {
    Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
    $exoConnected = $true
}
catch {
    Stop-Script "Failed to connect to Exchange Online: $_"
}

Write-Host "Connected to Exchange Online" -ForegroundColor Green

# ════════════════════════════════════════════════════════════════
#  MATCH TO EXCHANGE RECIPIENTS
# ════════════════════════════════════════════════════════════════

$recipientMap  = @{}
$lookupErrors  = 0
$recipientProps = 'ExternalDirectoryObjectId', 'RecipientTypeDetails', 'HiddenFromAddressListsEnabled'

if ($users.Count -le $BulkThreshold) {
    # Few users: look each one up directly (fast, with a real progress bar)
    Write-Host "Looking up $($users.Count) user(s) in Exchange Online..." -ForegroundColor Cyan

    $processed = 0
    $total     = $users.Count

    foreach ($u in $users.Values) {
        $processed++

        Write-Progress `
            -Activity "Looking up Exchange recipients" `
            -Status "$processed of $total" `
            -PercentComplete ([math]::Round(($processed / $total) * 100)) `
            -CurrentOperation $u.UserPrincipalName

        try {
            $r = Get-EXORecipient `
                -ExternalDirectoryObjectId $u.ObjectId `
                -Properties $recipientProps `
                -ErrorAction Stop

            if ($r) { $recipientMap[$u.ObjectId] = $r }
        }
        catch {
            if ("$_" -match "couldn't be found|couldn't find|not found|doesn't exist") {
                continue   # not mail-enabled -> classified as NoMailbox below
            }
            Write-Warning "Lookup failed for $($u.UserPrincipalName): $_"
            $u.Status = 'Error'
            $u.Result = "Lookup error: $_"
            $lookupErrors++
        }
    }

    Write-Progress -Activity "Looking up Exchange recipients" -Completed
}
else {
    # Many users: one bulk pull is cheaper than thousands of single lookups
    Write-Host "Fetching all Exchange recipients ($($users.Count) users exceeds -BulkThreshold $BulkThreshold)..." -ForegroundColor Cyan

    $loaded = 0

    try {
        Get-EXORecipient `
            -ResultSize Unlimited `
            -Properties $recipientProps `
            -ErrorAction Stop |
            ForEach-Object {
                $loaded++
                if ($loaded % 500 -eq 0) {
                    Write-Progress -Activity "Fetching Exchange recipients" -Status "$loaded recipient(s) loaded"
                }
                if ($_.ExternalDirectoryObjectId) { $recipientMap[$_.ExternalDirectoryObjectId] = $_ }
            }
    }
    catch {
        Stop-Script "Failed to fetch Exchange recipients: $_"
    }

    Write-Progress -Activity "Fetching Exchange recipients" -Completed
    Write-Host "  $loaded recipient(s) loaded" -ForegroundColor DarkGray
}

$mailboxTypes  = @('UserMailbox', 'SharedMailbox', 'RoomMailbox', 'EquipmentMailbox')
$mailUserTypes = @('MailUser', 'GuestMailUser')

foreach ($u in $users.Values) {
    if ($u.Status -eq 'Error') { continue }

    $r = $recipientMap[$u.ObjectId]
    $u.Recipient = $r

    if (-not $r) {
        $u.Status = 'NoMailbox'
        continue
    }

    $u.RecipientType = "$($r.RecipientTypeDetails)"

    if ($r.HiddenFromAddressListsEnabled) {
        $u.Status = 'AlreadyHidden'
    }
    elseif ($SkipUsersWithOtherLicenses -and $u.OtherLicenses) {
        $u.Status = 'OtherLicense'
    }
    elseif ($u.DirSynced) {
        $u.Status = 'DirSynced'
    }
    elseif ($u.RecipientType -notin ($mailboxTypes + $mailUserTypes)) {
        $u.Status = 'Unsupported'
    }
    else {
        $u.Status = 'Hide'
    }
}

$byStatus = @{}
foreach ($status in 'Hide', 'AlreadyHidden', 'NoMailbox', 'DirSynced', 'OtherLicense', 'Unsupported') {
    $byStatus[$status] = @($users.Values | Where-Object Status -eq $status | Sort-Object DisplayName)
}

$tableCols = 'DisplayName', 'UserPrincipalName', 'RecipientType', 'AccountEnabled', 'OtherLicenses'

# ════════════════════════════════════════════════════════════════
#  REPORT FINDINGS
# ════════════════════════════════════════════════════════════════

$toHide = $byStatus['Hide']

if ($toHide.Count -gt 0) {
    $verb = $WhatIf ? 'WILL BE HIDDEN' : 'To hide'
    Write-Host "`n$verb ($($toHide.Count)) - currently visible in the GAL:" -ForegroundColor Yellow
    Write-Table $toHide $tableCols
}
else {
    Write-Host "`nNo licensed users are currently visible in the GAL via Exchange Online." -ForegroundColor Green
}

if ($byStatus['DirSynced'].Count -gt 0) {
    Write-Host "Synced from on-prem - VISIBLE, must be hidden in AD ($($byStatus['DirSynced'].Count)):" -ForegroundColor Red
    Write-Table $byStatus['DirSynced'] $tableCols
}

if ($byStatus['OtherLicense'].Count -gt 0) {
    Write-Host "Skipped - also hold another license ($($byStatus['OtherLicense'].Count)):" -ForegroundColor DarkYellow
    Write-Table $byStatus['OtherLicense'] $tableCols
}

if ($byStatus['Unsupported'].Count -gt 0) {
    Write-Host "Skipped - unsupported recipient type ($($byStatus['Unsupported'].Count)):" -ForegroundColor DarkYellow
    Write-Table $byStatus['Unsupported'] $tableCols
}

Write-Host "Already hidden : $($byStatus['AlreadyHidden'].Count)" -ForegroundColor DarkGray
Write-Host "No mailbox     : $($byStatus['NoMailbox'].Count) (not mail-enabled, so not in the GAL)" -ForegroundColor DarkGray

# ════════════════════════════════════════════════════════════════
#  HIDE USERS
# ════════════════════════════════════════════════════════════════

$hidden = 0
$errors = 0

if ($WhatIf) {
    foreach ($u in $toHide) { $u.Result = 'WhatIf - would hide' }
    Write-Host "`nWhatIf mode - no changes made" -ForegroundColor DarkYellow
}
elseif ($toHide.Count -gt 0) {
    Write-Host "`nHiding users..." -ForegroundColor Cyan

    $processed = 0
    $total     = $toHide.Count

    foreach ($u in $toHide) {
        $processed++

        Write-Progress `
            -Activity "Hiding licensed users from the GAL" `
            -Status "$processed of $total" `
            -PercentComplete ([math]::Round(($processed / $total) * 100)) `
            -CurrentOperation $u.UserPrincipalName

        Write-Host "[$processed] $($u.UserPrincipalName) ($($u.RecipientType)) ..." -NoNewline -ForegroundColor White

        try {
            # Get-EXORecipient only returns requested properties (no Guid),
            # so target by UPN - accepted by both Set-Mailbox and Set-MailUser.
            $id = $u.UserPrincipalName
            if ([string]::IsNullOrWhiteSpace($id)) {
                throw "No UserPrincipalName to target"
            }

            if ($u.RecipientType -in $mailboxTypes) {
                Set-Mailbox -Identity $id -HiddenFromAddressListsEnabled $true -ErrorAction Stop
            }
            else {
                Set-MailUser -Identity $id -HiddenFromAddressListsEnabled $true -ErrorAction Stop
            }

            Write-Host " Hidden" -ForegroundColor Green
            $u.Result = 'Hidden'
            $hidden++
        }
        catch {
            Write-Host " ERROR" -ForegroundColor Red
            Write-Error "  $_"
            $u.Result = "Error: $_"
            $u.Status = 'Error'
            $errors++
        }
    }

    Write-Progress -Activity "Hiding licensed users from the GAL" -Completed
}

# ════════════════════════════════════════════════════════════════
#  EXPORT REPORT
# ════════════════════════════════════════════════════════════════

if ($ReportPath) {
    try {
        $users.Values |
            Sort-Object Status, DisplayName |
            Select-Object DisplayName, UserPrincipalName, AccountEnabled, DirSynced, RecipientType, Status, Result, OtherLicenses, ObjectId |
            Export-Csv -Path $ReportPath -NoTypeInformation -Encoding utf8 -ErrorAction Stop
        Write-Host "`nReport written to $ReportPath" -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to write report to '$ReportPath': $_"
    }
}

# ════════════════════════════════════════════════════════════════
#  SUMMARY
# ════════════════════════════════════════════════════════════════

Write-Host "`nSummary:" -ForegroundColor Cyan
if ($WhatIf) {
    Write-Host "  (WhatIf - counts show what WOULD happen)" -ForegroundColor DarkYellow
}
Write-Host "  SKUs            : $($targetSkus.SkuPartNumber -join ', ')"
Write-Host "  Licensed users  : $($users.Count)"
Write-Host "  $(($WhatIf ? 'Would hide' : 'Hidden').PadRight(15)) : $($WhatIf ? $toHide.Count : $hidden)" -ForegroundColor Green
Write-Host "  Already hidden  : $($byStatus['AlreadyHidden'].Count)"   -ForegroundColor DarkGray
Write-Host "  No mailbox      : $($byStatus['NoMailbox'].Count)"       -ForegroundColor DarkGray
Write-Host "  DirSynced (AD)  : $($byStatus['DirSynced'].Count)"       -ForegroundColor ($byStatus['DirSynced'].Count ? 'Red' : 'DarkGray')
Write-Host "  Other license   : $($byStatus['OtherLicense'].Count)"    -ForegroundColor DarkGray
Write-Host "  Unsupported     : $($byStatus['Unsupported'].Count)"     -ForegroundColor DarkGray
Write-Host "  Errors          : $($errors + $lookupErrors)"            -ForegroundColor Red

Disconnect-All

Write-Host "`nDone." -ForegroundColor Cyan
