#Requires -Modules Microsoft.Graph.Groups, Microsoft.Graph.Users

<#
    AddUsersToGroup.ps1

    CSV format (member users):
    userPrincipalName,type
    john.doe@contoso.com,member

    CSV format (guest users — use their real email, not the generated Entra UPN):
    userPrincipalName,type
    tojones@macleanpower.com,guest

    - "userPrincipalName" column is required
    - "type" column is optional; omitting it (or leaving blank) defaults to "member"
    - Guest lookup resolves by the mail attribute, not the generated #EXT# UPN
    - Skips rows with empty/missing userPrincipalName
    - Skips users already in the group (idempotent)
    - Use -WhatIf to preview without making changes
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$GroupObjectId,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [switch]$WhatIf
)

# ════════════════════════════════════════════════════════════════
#  CONNECT TO MICROSOFT GRAPH
# ════════════════════════════════════════════════════════════════

Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan

Connect-MgGraph -Scopes "User.Read.All", "GroupMember.ReadWrite.All" -NoWelcome -ErrorAction Stop

Write-Host "Connected as: $((Get-MgContext).Account)" -ForegroundColor Green

# ════════════════════════════════════════════════════════════════
#  VALIDATE GROUP
# ════════════════════════════════════════════════════════════════

Write-Host "Resolving group..." -ForegroundColor Cyan

try {
    $group = Get-MgGroup -GroupId $GroupObjectId -Property Id, DisplayName -ErrorAction Stop
}
catch {
    Write-Error "Group not found for object ID '$GroupObjectId': $_"
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    exit 1
}

Write-Host "Target group: $($group.DisplayName)" -ForegroundColor Green

# ════════════════════════════════════════════════════════════════
#  READ CSV
# ════════════════════════════════════════════════════════════════

$records = Import-Csv $CsvPath

if (-not ($records | Get-Member -Name "userPrincipalName" -ErrorAction SilentlyContinue)) {
    Write-Error "CSV must contain a 'userPrincipalName' column."
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    exit 1
}

Write-Host "Loaded $($records.Count) records from CSV" -ForegroundColor Cyan

# ════════════════════════════════════════════════════════════════
#  FETCH EXISTING MEMBERS
# ════════════════════════════════════════════════════════════════

Write-Host "Fetching existing group members..." -ForegroundColor Cyan

$existingMemberIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

Get-MgGroupMember -GroupId $GroupObjectId -All | ForEach-Object {
    $existingMemberIds.Add($_.Id) | Out-Null
}

Write-Host "  $($existingMemberIds.Count) current member(s)" -ForegroundColor DarkGray

# ════════════════════════════════════════════════════════════════
#  PROCESS USERS
# ════════════════════════════════════════════════════════════════

$processed = 0
$added     = 0
$skipped   = 0
$errors    = 0
$total     = $records.Count

foreach ($row in $records) {
    $processed++
    $upn = $row.userPrincipalName?.Trim()

    $percentComplete = [math]::Round(($processed / $total) * 100)
    Write-Progress `
        -Activity "Adding users to '$($group.DisplayName)'" `
        -Status "$processed of $total" `
        -PercentComplete $percentComplete `
        -CurrentOperation $upn

    if ([string]::IsNullOrWhiteSpace($upn)) {
        Write-Warning "[$processed] Skipping row with empty/missing userPrincipalName"
        $skipped++
        continue
    }

    $type = $row.PSObject.Properties['type'] ? $row.type?.Trim().ToLower() : 'member'
    if ([string]::IsNullOrWhiteSpace($type)) { $type = 'member' }

    Write-Host "[$processed] $upn ($type) ..." -NoNewline -ForegroundColor White

    try {
        if ($type -eq 'guest') {
            $matches = Get-MgUser `
                -Filter "mail eq '$upn'" `
                -Property Id, UserPrincipalName, Mail `
                -ConsistencyLevel eventual `
                -CountVariable matchCount `
                -ErrorAction Stop

            if ($matchCount -eq 0) {
                throw "No guest found with mail '$upn'"
            }
            if ($matchCount -gt 1) {
                throw "Multiple users matched mail '$upn' — cannot determine which to add"
            }

            $user = $matches
        }
        else {
            $user = Get-MgUser -UserId $upn -Property Id, UserPrincipalName -ErrorAction Stop
        }

        if ($existingMemberIds.Contains($user.Id)) {
            Write-Host " Already a member" -ForegroundColor DarkGray
            $skipped++
            continue
        }

        if ($WhatIf) {
            Write-Host " WOULD ADD (WhatIf - no change made)" -ForegroundColor DarkYellow
            $added++
        }
        else {
            New-MgGroupMember -GroupId $GroupObjectId -DirectoryObjectId $user.Id -ErrorAction Stop
            Write-Host " Added" -ForegroundColor Green
            $existingMemberIds.Add($user.Id) | Out-Null
            $added++
        }
    }
    catch {
        Write-Host " ERROR" -ForegroundColor Red
        Write-Error "  $_"
        $errors++
    }
}

Write-Progress -Activity "Adding users" -Completed

# ════════════════════════════════════════════════════════════════
#  SUMMARY
# ════════════════════════════════════════════════════════════════

Write-Host "`nSummary:" -ForegroundColor Cyan
Write-Host "  Group     : $($group.DisplayName)"
Write-Host "  Processed : $processed"
Write-Host "  Added     : $added"     -ForegroundColor Green
Write-Host "  Skipped   : $skipped"   -ForegroundColor DarkGray
Write-Host "  Errors    : $errors"    -ForegroundColor Red

Disconnect-MgGraph -ErrorAction SilentlyContinue

Write-Host "`nDone." -ForegroundColor Cyan
