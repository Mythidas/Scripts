#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement, ExchangeOnlineManagement

<#
.SYNOPSIS
    Finds licensed (default: Microsoft 365 F1) users who are visible in the Global Address List (GAL)
    but have no mailbox, optionally hides them from the GAL, and can roll the change back.

.DESCRIPTION
    Three modes, all sharing the same CSV layout so any output file can be fed back in via -CsvPath:

    Report  (default, READ-ONLY)
        Scans every user holding the SKU, looks up the Exchange recipient for each one and exports a
        report. Nothing is changed. Rows flagged Candidate = True are users that would be hidden.

    Hide
        Hides the Candidate users from the GAL (HiddenFromAddressListsEnabled = $true).
        Without -CsvPath it runs a fresh scan first (and saves that scan as a report).
        With -CsvPath it hides the Candidate rows of a report you already reviewed.
        Every user is re-checked live right before the change, so a stale report cannot hide
        someone who has since been given a mailbox. Writes a Hide log with the result per user.

    Restore (rollback)
        Takes a Report or Hide log via -CsvPath and un-hides every Candidate row. Users that were
        already hidden before the Hide run are never Candidates, so they stay hidden.

    A Candidate is a user that:
      - is a mail-enabled recipient WITHOUT a mailbox (MailUser / GuestMailUser), so it shows in the GAL
      - is not already hidden
      - is not directory-synced (synced objects must be hidden on-premises; Exchange Online rejects it)

    Users with a mailbox (including shared, room and hybrid RemoteUserMailbox) are never touched.
    Users that are not an Exchange recipient at all are not in the GAL already and are reported only.

.PARAMETER Mode
    Report (default, read-only), Hide, or Restore.

.PARAMETER SkuPartNumber
    SKU to look for. Default M365_F1_COMM (Microsoft 365 F1). Do not confuse with SPE_F1, which is M365 F3.
    If the SKU is not found in the tenant the available SkuPartNumbers are listed.

.PARAMETER CsvPath
    Report / Hide log from a previous run. Required for Restore, optional for Hide.

.PARAMETER OutputPath
    Folder for the exported CSVs (created if missing). Default: Data next to this script.
    Files are timestamped so a run never overwrites an earlier report or rollback source.

.PARAMETER Force
    Skip the one-time "are you sure" prompt before Hide / Restore changes anything (for unattended runs).

.EXAMPLE
    .\FetchF1Users.ps1
    Read-only report of F1 users with no mailbox.

.EXAMPLE
    .\FetchF1Users.ps1 -Mode Hide -CsvPath .\Data\F1_GAL_Report_20261028-093000.csv -WhatIf
    Preview what hiding the reviewed report would do. Nothing is changed.

.EXAMPLE
    .\FetchF1Users.ps1 -Mode Hide -CsvPath .\Data\F1_GAL_Report_20261028-093000.csv
    Hide the users from the reviewed report.

.EXAMPLE
    .\FetchF1Users.ps1 -Mode Restore -CsvPath .\Data\F1_GAL_Hide_20261028-094500.csv
    Roll back: make the hidden users visible in the GAL again.

.NOTES
    Report: Graph User.Read.All + Organization.Read.All, and any Exchange Online read role.
    Hide / Restore: additionally an Exchange role that can run Set-MailUser (e.g. Exchange Administrator).
    Hide / Restore support -WhatIf and -Confirm.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [ValidateSet('Report', 'Hide', 'Restore')]
    [string]$Mode = 'Report',

    [ValidateNotNullOrEmpty()]
    [string]$SkuPartNumber = 'M365_F1_COMM',

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$CsvPath,

    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (Join-Path $PSScriptRoot 'Data'),

    [switch]$Force
)

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$columns   = 'UserPrincipalName', 'DisplayName', 'ObjectId', 'AccountEnabled', 'DirSynced',
             'RecipientTypeDetails', 'HiddenBefore', 'Candidate', 'Action', 'Notes'

# ════════════════════════════════════════════════════════════════
#  HELPER FUNCTIONS
# ════════════════════════════════════════════════════════════════

function Get-RecipientState {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Identity
    )

    try {
        $recipient = Get-Recipient -Identity $Identity -ErrorAction Stop | Select-Object -First 1

        return [pscustomobject]@{
            Status = 'Found'
            Type   = [string]$recipient.RecipientTypeDetails
            Hidden = [bool]$recipient.HiddenFromAddressListsEnabled
            Error  = $null
        }
    }
    catch {
        $notFound = $_.FullyQualifiedErrorId -match 'ManagementObjectNotFoundException' -or
                    $_.Exception.Message -match "couldn't be found|was not found"

        # Anything other than a clean "not found" is a lookup error and is never acted on
        return [pscustomobject]@{
            Status = ($notFound ? 'NotFound' : 'Error')
            Type   = ($notFound ? 'None' : 'LookupError')
            Hidden = $false
            Error  = $_.Exception.Message
        }
    }
}

function Test-HideCandidate {
    param (
        [Parameter(Mandatory = $true)]
        [psobject]$State,

        [bool]$DirSynced
    )

    $note = switch ($true) {
        ($State.Status -eq 'Error')                            { "Exchange lookup failed: $($State.Error)"; break }
        ($State.Status -eq 'NotFound')                         { 'Not an Exchange recipient (not in GAL)'; break }
        ($State.Type -match 'Mailbox$')                        { 'Has a mailbox'; break }
        ($State.Type -notin 'MailUser', 'GuestMailUser')       { "Unsupported recipient type: $($State.Type)"; break }
        ($State.Hidden)                                        { 'Already hidden from GAL'; break }
        ($DirSynced)                                           { 'Directory-synced - hide on-premises (msExchHideFromAddressLists)'; break }
        default                                                { $null }
    }

    return [pscustomobject]@{
        Candidate = ($null -eq $note)
        Note      = ($note ?? 'No mailbox, visible in GAL')
    }
}

function Set-GalHidden {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Identity,

        [Parameter(Mandatory = $true)]
        [string]$Type,

        [Parameter(Mandatory = $true)]
        [bool]$Hidden
    )

    # Dispatch on the live recipient type; Restore may meet a user who got a mailbox since the Hide run
    if ($Type -match 'Mailbox$') {
        Set-Mailbox -Identity $Identity -HiddenFromAddressListsEnabled $Hidden -ErrorAction Stop
    }
    elseif ($Type -in 'MailUser', 'GuestMailUser') {
        Set-MailUser -Identity $Identity -HiddenFromAddressListsEnabled $Hidden -ErrorAction Stop
    }
    else {
        throw "Cannot change GAL visibility for recipient type '$Type'"
    }
}

function Get-GalScan {
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Users
    )

    $total   = $Users.Count
    $current = 0

    $rows = foreach ($user in $Users) {
        $current++

        Write-Progress `
            -Activity 'Scanning users against the GAL' `
            -Status "$current of $total" `
            -PercentComplete ([math]::Round(($current / $total) * 100)) `
            -CurrentOperation $user.UserPrincipalName

        $state  = Get-RecipientState -Identity $user.UserPrincipalName
        $synced = [bool]$user.OnPremisesSyncEnabled
        $check  = Test-HideCandidate -State $state -DirSynced $synced

        [pscustomobject][ordered]@{
            UserPrincipalName    = $user.UserPrincipalName
            DisplayName          = $user.DisplayName
            ObjectId             = $user.Id
            AccountEnabled       = $user.AccountEnabled
            DirSynced            = $synced
            RecipientTypeDetails = $state.Type
            HiddenBefore         = $state.Hidden
            Candidate            = $check.Candidate
            Action               = 'Report'
            Notes                = $check.Note
        }
    }

    Write-Progress -Activity 'Scanning users against the GAL' -Completed

    return @($rows | Sort-Object @{ Expression = { $_.Candidate }; Descending = $true }, UserPrincipalName)
}

function Import-GalCsv {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $records = @(Import-Csv -LiteralPath $Path -ErrorAction Stop)

    if ($records.Count -eq 0) {
        return @()
    }

    $headers = $records[0].PSObject.Properties.Name
    foreach ($required in 'UserPrincipalName', 'Candidate') {
        if ($headers -notcontains $required) {
            throw "CSV is missing required column: $required (use a Report or Hide log produced by this script)"
        }
    }

    # Normalise to the full column set so older/trimmed files still work
    return @($records | ForEach-Object {
        $row = [ordered]@{}
        foreach ($column in $columns) {
            $row[$column] = $_.PSObject.Properties[$column]?.Value
        }
        [pscustomobject]$row
    })
}

function Export-GalCsv {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Rows,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    # -WhatIf:$false so previews still leave a log behind
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
        New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false | Out-Null
    }

    $file = Join-Path $OutputPath "F1_GAL_${Label}_$timestamp.csv"
    $Rows | Select-Object $columns | Export-Csv -LiteralPath $file -NoTypeInformation -Encoding UTF8 -WhatIf:$false

    return $file
}

function Test-IsCandidate {
    param ([psobject]$Row)
    return ([string]$Row.Candidate -eq 'True')
}

function Write-ScanSummary {
    param ([object[]]$Rows)

    Write-Host "`nScan summary:" -ForegroundColor Cyan
    $Rows | Group-Object RecipientTypeDetails | Sort-Object Count -Descending | ForEach-Object {
        Write-Host ("  {0,-22}: {1}" -f $_.Name, $_.Count)
    }

    $candidates = @($Rows | Where-Object { Test-IsCandidate $_ })
    Write-Host ("  {0,-22}: {1}" -f 'Would hide (Candidate)', $candidates.Count) -ForegroundColor Yellow
}

# ════════════════════════════════════════════════════════════════
#  VALIDATE INPUTS
# ════════════════════════════════════════════════════════════════

if ($Mode -eq 'Restore' -and -not $CsvPath) {
    Write-Error '-CsvPath is required for Restore (use the Report or Hide log from the run you want to roll back).'
    exit 1
}

if ($Mode -eq 'Report' -and $CsvPath) {
    Write-Warning '-CsvPath is ignored in Report mode.'
}

$fromCsv = [bool]$CsvPath -and $Mode -ne 'Report'
$rows    = @()

if ($fromCsv) {
    try {
        $rows = Import-GalCsv -Path $CsvPath
    }
    catch {
        Write-Error "Failed to read CSV: $($_.Exception.Message)"
        exit 1
    }

    Write-Host "Loaded $($rows.Count) rows from $CsvPath" -ForegroundColor Cyan
}

Write-Host "Mode: $Mode" -ForegroundColor Cyan
if ($Mode -eq 'Report') {
    Write-Host 'Read-only run - no changes will be made.' -ForegroundColor Green
}
elseif ($WhatIfPreference) {
    Write-Host 'WhatIf - no changes will be made.' -ForegroundColor DarkYellow
}

# ════════════════════════════════════════════════════════════════
#  CONNECT
# ════════════════════════════════════════════════════════════════

$needsGraph = -not $fromCsv

try {
    if ($needsGraph) {
        Write-Host 'Connecting to Microsoft Graph...' -ForegroundColor Cyan
        Connect-MgGraph -Scopes 'User.Read.All', 'Organization.Read.All' -NoWelcome -ErrorAction Stop
        Write-Host "Connected as: $((Get-MgContext).Account)" -ForegroundColor Green
    }

    Write-Host 'Connecting to Exchange Online...' -ForegroundColor Cyan
    Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
}
catch {
    Write-Error "Failed to connect: $($_.Exception.Message)"
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    exit 1
}

try {

    # ════════════════════════════════════════════════════════════════
    #  FETCH + SCAN USERS (Report, and Hide without -CsvPath)
    # ════════════════════════════════════════════════════════════════

    if ($needsGraph) {
        $sku = Get-MgSubscribedSku -All | Where-Object SkuPartNumber -eq $SkuPartNumber

        if (-not $sku) {
            Write-Error "SKU '$SkuPartNumber' not found in this tenant. Available SKUs:"
            Get-MgSubscribedSku -All | Select-Object SkuPartNumber, SkuId | Format-Table -AutoSize | Out-String | Write-Host
            exit 1
        }

        Write-Host "Fetching users licensed with $SkuPartNumber..." -ForegroundColor Cyan

        $users = @(Get-MgUser -All -ConsistencyLevel eventual -CountVariable userCount `
            -Filter "assignedLicenses/any(x:x/skuId eq $($sku.SkuId))" `
            -Property 'Id,UserPrincipalName,DisplayName,AccountEnabled,OnPremisesSyncEnabled')

        Write-Host "Found $($users.Count) users" -ForegroundColor Green

        if ($users.Count -eq 0) {
            Write-Warning 'No users hold this license. Nothing to do.'
            return
        }

        $rows = Get-GalScan -Users $users

        $reportFile = Export-GalCsv -Rows $rows -Label 'Report'
        Write-ScanSummary -Rows $rows
        Write-Host "`nReport: $reportFile" -ForegroundColor Green
    }

    if ($Mode -eq 'Report') {
        $script = $MyInvocation.MyCommand.Name
        Write-Host "`nReview the Candidate rows, then preview with:" -ForegroundColor Cyan
        Write-Host "  .\$script -Mode Hide -CsvPath `"$reportFile`" -WhatIf"
        return
    }

    # ════════════════════════════════════════════════════════════════
    #  APPLY (Hide / Restore)
    # ════════════════════════════════════════════════════════════════

    $hiding  = $Mode -eq 'Hide'
    $targets = @($rows | Where-Object { Test-IsCandidate $_ })

    if ($targets.Count -eq 0) {
        Write-Warning 'No Candidate rows to process. Nothing to do.'
        return
    }

    $verb = $hiding ? 'hide from' : 'make visible in'
    Write-Host "`n$($targets.Count) user(s) to $verb the GAL" -ForegroundColor Yellow

    if (-not $WhatIfPreference -and -not $Force) {
        if (-not $PSCmdlet.ShouldContinue("This will $verb the GAL: $($targets.Count) user(s). Continue?", "Confirm $Mode")) {
            Write-Host 'Cancelled.' -ForegroundColor Yellow
            return
        }
    }

    $processed = 0
    $changed   = 0
    $skipped   = 0
    $errors    = 0
    $total     = $targets.Count
    $log       = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $targets) {
        $processed++
        $upn = $row.UserPrincipalName.Trim()

        Write-Progress `
            -Activity "$Mode users $($hiding ? 'in' : 'to') the GAL" `
            -Status "$processed of $total" `
            -PercentComplete ([math]::Round(($processed / $total) * 100)) `
            -CurrentOperation $upn

        Write-Host "[$processed] $upn ..." -NoNewline -ForegroundColor White

        $entry = $row.PSObject.Copy()

        # Always re-check live: reports go stale
        $state = Get-RecipientState -Identity $upn

        if ($state.Status -ne 'Found') {
            $entry.Action = $state.Status -eq 'Error' ? 'Error' : 'Skipped'
            $entry.Notes  = $state.Status -eq 'Error' ? "Exchange lookup failed: $($state.Error)" : 'No longer an Exchange recipient'
            Write-Host " $($entry.Notes)" -ForegroundColor ($state.Status -eq 'Error' ? 'Red' : 'Yellow')
            if ($state.Status -eq 'Error') { $errors++ } else { $skipped++ }
            $log.Add($entry)
            continue
        }

        if ($hiding) {
            $check = Test-HideCandidate -State $state -DirSynced ([string]$row.DirSynced -eq 'True')
            if (-not $check.Candidate) {
                $entry.Action = 'Skipped'
                $entry.Notes  = "State changed since report: $($check.Note)"
                Write-Host " Skipped - $($check.Note)" -ForegroundColor Yellow
                $skipped++
                $log.Add($entry)
                continue
            }
        }
        elseif (-not $state.Hidden) {
            $entry.Action = 'Skipped'
            $entry.Notes  = 'Already visible in GAL'
            Write-Host ' Already visible' -ForegroundColor DarkGray
            $skipped++
            $log.Add($entry)
            continue
        }

        $newHidden = $hiding
        $past      = $hiding ? 'Hidden' : 'Restored'

        try {
            if ($PSCmdlet.ShouldProcess($upn, ($hiding ? 'Hide from GAL' : 'Make visible in GAL'))) {
                Set-GalHidden -Identity $upn -Type $state.Type -Hidden $newHidden
                $entry.Action = $past
                Write-Host " $past" -ForegroundColor Green
            }
            else {
                $entry.Action = "Would$($hiding ? 'Hide' : 'Restore')"
                Write-Host " WhatIf: would be $($past.ToLower())" -ForegroundColor DarkYellow
            }
            $changed++
        }
        catch {
            $entry.Action = 'Error'
            $entry.Notes  = $_.Exception.Message
            Write-Host ' ERROR' -ForegroundColor Red
            Write-Error "[$processed] $upn - $($_.Exception.Message)"
            $errors++
        }

        $log.Add($entry)
    }

    Write-Progress -Activity "$Mode users $($hiding ? 'in' : 'to') the GAL" -Completed

    $logFile = Export-GalCsv -Rows $log -Label $Mode

    # ════════════════════════════════════════════════════════════════
    #  SUMMARY
    # ════════════════════════════════════════════════════════════════

    Write-Host "`nSummary:" -ForegroundColor Cyan
    Write-Host ("  {0,-12}: {1}" -f 'Processed', $processed)
    Write-Host ("  {0,-12}: {1}" -f ($WhatIfPreference ? 'Would change' : 'Changed'), $changed) -ForegroundColor Green
    Write-Host ("  {0,-12}: {1}" -f 'Skipped', $skipped) -ForegroundColor DarkGray
    Write-Host ("  {0,-12}: {1}" -f 'Errors', $errors)   -ForegroundColor Red
    Write-Host "`nLog: $logFile" -ForegroundColor Green

    if ($hiding -and -not $WhatIfPreference) {
        $script = $MyInvocation.MyCommand.Name
        Write-Host "Rollback with:" -ForegroundColor Cyan
        Write-Host "  .\$script -Mode Restore -CsvPath `"$logFile`""
    }
}
finally {
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}

Write-Host "`nDone." -ForegroundColor Cyan
