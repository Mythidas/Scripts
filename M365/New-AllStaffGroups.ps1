#Requires -Version 7.0
#Requires -Modules ExchangeOnlineManagement

<#
    New-AllStaffGroups.ps1

    Sets up an all-staff list that only approved external senders can mail:

      allstaff@<domain>       Dynamic DL - every user mailbox in the tenant
                              Allowed senders: every contact in the CSV

      allstaff-test@<domain>  Static DL  - one test member (-TestMemberEmail)
                              Allowed senders: CSV rows flagged testSender

    CSV format:
    displayName,email,testSender
    HR,hr@innovate32services.com,true
    Carrington Morgan,cmorgan@innovate32services.com,false

    - "displayName" and "email" columns are required
    - "testSender" is optional; true/yes/y/1/x also allows that contact to send
      to allstaff-test@ (blank or missing = allstaff@ only)
    - CSV contacts are allowed senders only - they are never added as members
    - Contacts are created as mail contacts, hidden from the GAL by default
      (new and existing); use -ShowContactsInGAL to leave them visible
    - If an address already exists as any recipient, it is reused rather than
      creating a duplicate contact
    - -TestMemberEmail is resolved to an existing recipient; if it doesn't exist
      and is external, a hidden mail contact is created for it
    - Both groups are set to accept mail from external senders
    - Groups are created only if missing; existing groups are reused
    - Skips rows with empty/invalid email and duplicate emails
    - Skips senders/members already present (idempotent - safe to re-run)
    - Use -WhatIf to preview without making changes

    NOTE: Once a group has allowed senders set, ONLY those senders can mail it.
    Internal users and admins will be rejected unless added as senders too.

    Example:
    .\New-AllStaffGroups.ps1 -Domain contoso.com -CsvPath .\allstaff.csv `
        -TestMemberEmail it-test@contoso.com -WhatIf
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$Domain,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string]$TestMemberEmail,

    [string]$AllStaffName  = "All Staff",
    [string]$AllStaffAlias = "allstaff",

    [string]$TestName  = "All Staff - Test",
    [string]$TestAlias = "allstaff-test",

    [switch]$ShowContactsInGAL,

    [switch]$WhatIf
)

# ════════════════════════════════════════════════════════════════
#  CONFIG / STATE
# ════════════════════════════════════════════════════════════════

$UserMailboxFilter = "RecipientTypeDetails -eq 'UserMailbox'"
$truthy            = @('true', 'yes', 'y', '1', 'x')

$groupsCreated    = 0
$groupsUpdated    = 0
$contactsCreated  = 0
$contactsExisting = 0
$contactErrors    = 0
$sendersAdded     = 0
$sendersSkipped   = 0
$senderErrors     = 0
$testMemberStatus = "Not processed"

# ════════════════════════════════════════════════════════════════
#  HELPERS
# ════════════════════════════════════════════════════════════════

function Stop-Script([string]$Message) {
    Write-Error $Message
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    exit 1
}

function Get-RecipientOrNull([string]$Identity) {
    try   { Get-Recipient -Identity $Identity -ErrorAction Stop }
    catch { $null }
}

# Newly created objects can take a few seconds to become addressable.
# Retries only on "not found" style errors; anything else is rethrown.
function Invoke-WithRetry([scriptblock]$Action, [int]$Attempts = 4, [int]$DelaySeconds = 5) {
    for ($i = 1; ; $i++) {
        try {
            return & $Action
        }
        catch {
            $transient = "$_" -match "couldn't be found|couldn't find|wasn't found|not found"
            if (-not $transient -or $i -ge $Attempts) { throw }
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Set-GroupProperty($Target, [hashtable]$Params) {
    $id = "$($Target.Group.Guid)"
    if ($Target.Kind -eq 'Dynamic') {
        Set-DynamicDistributionGroup -Identity $id @Params -ErrorAction Stop
    }
    else {
        Set-DistributionGroup -Identity $id @Params -BypassSecurityGroupManagerCheck -ErrorAction Stop
    }
}

function Get-AllowedSenderSet($Group) {
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($Group) {
        foreach ($s in $Group.AcceptMessagesOnlyFromSendersOrMembers) {
            $r = Get-RecipientOrNull "$s"
            if ($r) { [void]$set.Add("$($r.Guid)") }
        }
    }
    return , $set
}

function Resolve-Group {
    param (
        [ValidateSet('Dynamic', 'Static')][string]$Kind,
        [string]$Name,
        [string]$Alias
    )

    $smtp     = "$Alias@$Domain"
    $expected = $Kind -eq 'Dynamic' ? @('DynamicDistributionGroup') : @('MailUniversalDistributionGroup', 'MailUniversalSecurityGroup')
    $label    = $Kind -eq 'Dynamic' ? 'dynamic DL' : 'DL'

    Write-Host "  $smtp ($label) ..." -NoNewline -ForegroundColor White

    $existing = Get-RecipientOrNull $smtp

    if ($existing) {
        if ("$($existing.RecipientTypeDetails)" -notin $expected) {
            Write-Host " CONFLICT" -ForegroundColor Red
            Stop-Script "$smtp is already in use by $($existing.RecipientTypeDetails) '$($existing.DisplayName)' (expected $($expected -join ' or '))."
        }

        $group = $Kind -eq 'Dynamic' `
            ? (Get-DynamicDistributionGroup -Identity "$($existing.Guid)" -ErrorAction Stop) `
            : (Get-DistributionGroup        -Identity "$($existing.Guid)" -ErrorAction Stop)

        Write-Host " Exists ('$($group.DisplayName)')" -ForegroundColor DarkGray
        return [pscustomobject]@{ Kind = $Kind; Smtp = $smtp; Group = $group }
    }

    if ($WhatIf) {
        Write-Host " WOULD CREATE '$Name' (WhatIf - no change made)" -ForegroundColor DarkYellow
        $script:groupsCreated++
        return [pscustomobject]@{ Kind = $Kind; Smtp = $smtp; Group = $null }
    }

    try {
        if ($Kind -eq 'Dynamic') {
            $group = New-DynamicDistributionGroup `
                -Name $Name `
                -DisplayName $Name `
                -Alias $Alias `
                -PrimarySmtpAddress $smtp `
                -RecipientFilter $UserMailboxFilter `
                -ErrorAction Stop
        }
        else {
            $group = New-DistributionGroup `
                -Name $Name `
                -DisplayName $Name `
                -Alias $Alias `
                -PrimarySmtpAddress $smtp `
                -Type Distribution `
                -ErrorAction Stop
        }
    }
    catch {
        Write-Host " ERROR" -ForegroundColor Red
        Stop-Script "Failed to create '$smtp': $_"
    }

    Write-Host " Created" -ForegroundColor Green
    $script:groupsCreated++
    return [pscustomobject]@{ Kind = $Kind; Smtp = $smtp; Group = $group }
}

# Caller writes the "<email> ..." prefix; this writes the result and returns
# the recipient (or $null in WhatIf / on failure).
function Resolve-ExternalContact([string]$DisplayName, [string]$Email) {
    $existing = Get-RecipientOrNull $Email

    if ($existing) {
        if ($existing.RecipientTypeDetails -eq 'MailContact') {
            if (-not $ShowContactsInGAL -and -not $existing.HiddenFromAddressListsEnabled) {
                if ($WhatIf) {
                    Write-Host " Contact exists - WOULD HIDE from GAL (WhatIf)" -ForegroundColor DarkYellow
                }
                else {
                    Set-MailContact -Identity "$($existing.Guid)" -HiddenFromAddressListsEnabled $true -ErrorAction Stop
                    Write-Host " Contact exists - hidden from GAL" -ForegroundColor Green
                }
            }
            else {
                Write-Host " Contact exists" -ForegroundColor DarkGray
            }
        }
        else {
            Write-Host " Exists as $($existing.RecipientTypeDetails) - reusing" -ForegroundColor Yellow
        }
        $script:contactsExisting++
        return $existing
    }

    if ($WhatIf) {
        Write-Host " WOULD CREATE contact (WhatIf - no change made)" -ForegroundColor DarkYellow
        $script:contactsCreated++
        return $null
    }

    # Name must be unique tenant-wide (max 64 chars); DisplayName does not.
    $objName   = $DisplayName
    $nameQuery = $objName -replace "'", "''"
    $nameClash = Get-Recipient -Filter "Name -eq '$nameQuery'" -ResultSize 1 -ErrorAction SilentlyContinue
    if ($nameClash) {
        $objName = "$DisplayName ($Email)"
    }
    if ($objName.Length -gt 64) {
        $objName = $objName.Substring(0, 64)
    }

    $contact = New-MailContact `
        -Name $objName `
        -DisplayName $DisplayName `
        -ExternalEmailAddress $Email `
        -ErrorAction Stop

    if (-not $ShowContactsInGAL) {
        Invoke-WithRetry {
            Set-MailContact -Identity "$($contact.Guid)" -HiddenFromAddressListsEnabled $true -ErrorAction Stop
        }
        Write-Host " Created (hidden from GAL)" -ForegroundColor Green
    }
    else {
        Write-Host " Created" -ForegroundColor Green
    }

    $script:contactsCreated++
    return $contact
}

# ════════════════════════════════════════════════════════════════
#  CONNECT TO EXCHANGE ONLINE
# ════════════════════════════════════════════════════════════════

Write-Host "Connecting to Exchange Online..." -ForegroundColor Cyan

try {
    Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
}
catch {
    Write-Error "Failed to connect to Exchange Online: $_"
    exit 1
}

$conn = Get-ConnectionInformation | Select-Object -First 1
Write-Host "Connected as: $($conn.UserPrincipalName)" -ForegroundColor Green

if ($WhatIf) {
    Write-Host "WhatIf mode - no changes will be made" -ForegroundColor DarkYellow
}

# ════════════════════════════════════════════════════════════════
#  VALIDATE DOMAIN
# ════════════════════════════════════════════════════════════════

$Domain          = $Domain.Trim().TrimStart('@').ToLower()
$TestMemberEmail = $TestMemberEmail.Trim().ToLower()

Write-Host "Validating domain..." -ForegroundColor Cyan

$acceptedDomains = @(Get-AcceptedDomain | ForEach-Object { "$($_.DomainName)".ToLower() })

if ($Domain -notin $acceptedDomains) {
    Stop-Script "'$Domain' is not an accepted domain in this tenant."
}

Write-Host "Domain: $Domain" -ForegroundColor Green

# ════════════════════════════════════════════════════════════════
#  READ CSV
# ════════════════════════════════════════════════════════════════

$records = @(Import-Csv $CsvPath)

if ($records.Count -eq 0) {
    Stop-Script "CSV '$CsvPath' contains no rows."
}

$columns = $records[0].PSObject.Properties.Name
foreach ($col in 'displayName', 'email') {
    if ($col -notin $columns) {
        Stop-Script "CSV must contain a '$col' column."
    }
}

$entries     = [System.Collections.Generic.List[pscustomobject]]::new()
$seenEmails  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$rowsSkipped = 0
$rowNum      = 0

foreach ($row in $records) {
    $rowNum++
    $email = ([string]$row.email).Trim().ToLower()
    $name  = ([string]$row.displayName).Trim()

    if ([string]::IsNullOrWhiteSpace($email)) {
        Write-Warning "[Row $rowNum] Skipping row with empty/missing email"
        $rowsSkipped++
        continue
    }
    if ($email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
        Write-Warning "[Row $rowNum] Skipping invalid email '$email'"
        $rowsSkipped++
        continue
    }
    if (-not $seenEmails.Add($email)) {
        Write-Warning "[Row $rowNum] Skipping duplicate email '$email'"
        $rowsSkipped++
        continue
    }
    if ($email.Split('@')[-1] -in $acceptedDomains) {
        Write-Warning "[Row $rowNum] '$email' is on an accepted domain - will be used as an existing internal recipient"
    }
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = $email.Split('@')[0]
        Write-Warning "[Row $rowNum] No displayName - using '$name'"
    }

    $entries.Add([pscustomobject]@{
        DisplayName = $name
        Email       = $email
        TestSender  = ([string]$row.testSender).Trim().ToLower() -in $truthy
        Recipient   = $null
    })
}

$testSenderCount = @($entries | Where-Object TestSender).Count
Write-Host "Loaded $($entries.Count) valid record(s) from CSV ($testSenderCount flagged as test sender)" -ForegroundColor Cyan

if ($entries.Count -eq 0) {
    Stop-Script "No valid rows to process."
}

if ($testSenderCount -eq 0) {
    Write-Warning "No rows flagged testSender - nobody will be able to send to $TestAlias@$Domain"
}

# ════════════════════════════════════════════════════════════════
#  RESOLVE / CREATE GROUPS
# ════════════════════════════════════════════════════════════════

Write-Host "`nResolving groups..." -ForegroundColor Cyan

$allStaff = Resolve-Group -Kind Dynamic -Name $AllStaffName -Alias $AllStaffAlias
$testDl   = Resolve-Group -Kind Static  -Name $TestName     -Alias $TestAlias

# Preview who allstaff@ will actually deliver to
$previewFilter = $allStaff.Group ? $allStaff.Group.RecipientFilter : $UserMailboxFilter
try {
    $previewCount = @(Get-Recipient -RecipientPreviewFilter $previewFilter -ResultSize Unlimited -ErrorAction Stop).Count
    Write-Host "  $($allStaff.Smtp) resolves to $previewCount user mailbox(es)" -ForegroundColor DarkGray
}
catch {
    Write-Warning "Could not preview $($allStaff.Smtp) membership: $_"
}

# ════════════════════════════════════════════════════════════════
#  ALLOW EXTERNAL SENDERS
# ════════════════════════════════════════════════════════════════

Write-Host "`nConfiguring external senders..." -ForegroundColor Cyan

foreach ($t in @($allStaff, $testDl)) {
    Write-Host "  $($t.Smtp) ..." -NoNewline -ForegroundColor White

    if (-not $t.Group) {
        Write-Host " WOULD ALLOW external senders (WhatIf)" -ForegroundColor DarkYellow
        continue
    }
    if (-not $t.Group.RequireSenderAuthenticationEnabled) {
        Write-Host " External senders already allowed" -ForegroundColor DarkGray
        continue
    }
    if ($WhatIf) {
        Write-Host " WOULD ALLOW external senders (WhatIf)" -ForegroundColor DarkYellow
        $groupsUpdated++
        continue
    }

    try {
        Invoke-WithRetry { Set-GroupProperty $t @{ RequireSenderAuthenticationEnabled = $false } }
        Write-Host " External senders allowed" -ForegroundColor Green
        $groupsUpdated++
    }
    catch {
        Write-Host " ERROR" -ForegroundColor Red
        Stop-Script "Failed to allow external senders on '$($t.Smtp)': $_"
    }
}

# ════════════════════════════════════════════════════════════════
#  CREATE CONTACTS
# ════════════════════════════════════════════════════════════════

Write-Host "`nProcessing contacts..." -ForegroundColor Cyan

$processed = 0
$total     = $entries.Count

foreach ($e in $entries) {
    $processed++

    Write-Progress `
        -Activity "Creating mail contacts" `
        -Status "$processed of $total" `
        -PercentComplete ([math]::Round(($processed / $total) * 100)) `
        -CurrentOperation $e.Email

    Write-Host "[$processed] $($e.Email) ($($e.DisplayName)) ..." -NoNewline -ForegroundColor White

    try {
        $e.Recipient = Resolve-ExternalContact -DisplayName $e.DisplayName -Email $e.Email
    }
    catch {
        Write-Host " ERROR" -ForegroundColor Red
        Write-Error "  $_"
        $contactErrors++
    }
}

Write-Progress -Activity "Creating mail contacts" -Completed

# ════════════════════════════════════════════════════════════════
#  TEST DL MEMBER
# ════════════════════════════════════════════════════════════════

Write-Host "`nSetting test member on $($testDl.Smtp)..." -ForegroundColor Cyan
Write-Host "  $TestMemberEmail ..." -NoNewline -ForegroundColor White

try {
    $testRecipient = Get-RecipientOrNull $TestMemberEmail

    if (-not $testRecipient) {
        if ($TestMemberEmail.Split('@')[-1] -in $acceptedDomains) {
            Write-Host " NOT FOUND" -ForegroundColor Red
            Stop-Script "'$TestMemberEmail' is on an accepted domain but no recipient exists. Create the mailbox first."
        }
        $testRecipient = Resolve-ExternalContact -DisplayName $TestMemberEmail -Email $TestMemberEmail
        Write-Host "  $TestMemberEmail ..." -NoNewline -ForegroundColor White
    }

    if (-not $testRecipient -or -not $testDl.Group) {
        Write-Host " WOULD ADD as member (WhatIf - no change made)" -ForegroundColor DarkYellow
        $testMemberStatus = "Would add (WhatIf)"
    }
    else {
        $testId  = "$($testRecipient.Guid)"
        $members = @(Get-DistributionGroupMember -Identity "$($testDl.Group.Guid)" -ResultSize Unlimited -ErrorAction Stop)

        if ($members.Guid | Where-Object { "$_" -eq $testId }) {
            Write-Host " Already a member" -ForegroundColor DarkGray
            $testMemberStatus = "Already a member"
        }
        elseif ($WhatIf) {
            Write-Host " WOULD ADD as member (WhatIf - no change made)" -ForegroundColor DarkYellow
            $testMemberStatus = "Would add (WhatIf)"
        }
        else {
            Invoke-WithRetry {
                Add-DistributionGroupMember `
                    -Identity "$($testDl.Group.Guid)" `
                    -Member $testId `
                    -BypassSecurityGroupManagerCheck `
                    -ErrorAction Stop
            }
            Write-Host " Added as member" -ForegroundColor Green
            $testMemberStatus = "Added"
        }

        if ($members.Count -gt 0 -and -not ($members.Guid | Where-Object { "$_" -eq $testId })) {
            Write-Warning "$($testDl.Smtp) already had $($members.Count) other member(s) - they were left in place"
        }
    }
}
catch {
    Write-Host " ERROR" -ForegroundColor Red
    Write-Error "  $_"
    $testMemberStatus = "ERROR"
}

# ════════════════════════════════════════════════════════════════
#  ASSIGN ALLOWED SENDERS
# ════════════════════════════════════════════════════════════════

$targets = @(
    [pscustomobject]@{
        Target  = $allStaff
        Allowed = Get-AllowedSenderSet $allStaff.Group
        Entries = @($entries)
    }
    [pscustomobject]@{
        Target  = $testDl
        Allowed = Get-AllowedSenderSet $testDl.Group
        Entries = @($entries | Where-Object TestSender)
    }
)

foreach ($t in $targets) {
    Write-Host "`n$($t.Target.Smtp) - $($t.Entries.Count) allowed sender(s) to process" -ForegroundColor Cyan

    foreach ($e in $t.Entries) {
        Write-Host "  $($e.Email) ..." -NoNewline -ForegroundColor White

        if (-not $e.Recipient) {
            if ($WhatIf) {
                Write-Host " WOULD ALLOW as sender (WhatIf - no change made)" -ForegroundColor DarkYellow
                $sendersAdded++
            }
            else {
                Write-Host " Skipped (contact failed - see errors above)" -ForegroundColor Red
                $senderErrors++
            }
            continue
        }

        $id = "$($e.Recipient.Guid)"

        if ($t.Allowed.Contains($id)) {
            Write-Host " Already an allowed sender" -ForegroundColor DarkGray
            $sendersSkipped++
            continue
        }

        if ($WhatIf -or -not $t.Target.Group) {
            Write-Host " WOULD ALLOW as sender (WhatIf - no change made)" -ForegroundColor DarkYellow
            $sendersAdded++
            continue
        }

        try {
            Invoke-WithRetry {
                Set-GroupProperty $t.Target @{ AcceptMessagesOnlyFromSendersOrMembers = @{ Add = $id } }
            }
            Write-Host " Allowed as sender" -ForegroundColor Green
            [void]$t.Allowed.Add($id)
            $sendersAdded++
        }
        catch {
            Write-Host " ERROR" -ForegroundColor Red
            Write-Error "  $_"
            $senderErrors++
        }
    }
}

# ════════════════════════════════════════════════════════════════
#  SUMMARY
# ════════════════════════════════════════════════════════════════

Write-Host "`nSummary:" -ForegroundColor Cyan
if ($WhatIf) {
    Write-Host "  (WhatIf - counts show what WOULD happen)" -ForegroundColor DarkYellow
}
Write-Host "  Domain            : $Domain"
Write-Host "  Rows skipped      : $rowsSkipped"      -ForegroundColor DarkGray
Write-Host "  Groups created    : $groupsCreated"    -ForegroundColor Green
Write-Host "  Groups updated    : $groupsUpdated"    -ForegroundColor Green
Write-Host "  Contacts created  : $contactsCreated"  -ForegroundColor Green
Write-Host "  Contacts existing : $contactsExisting" -ForegroundColor DarkGray
Write-Host "  Contact errors    : $contactErrors"    -ForegroundColor Red
Write-Host "  Test member       : $testMemberStatus"
Write-Host "  Senders added     : $sendersAdded"     -ForegroundColor Green
Write-Host "  Senders skipped   : $sendersSkipped"   -ForegroundColor DarkGray
Write-Host "  Sender errors     : $senderErrors"     -ForegroundColor Red

Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue

Write-Host "`nDone." -ForegroundColor Cyan
