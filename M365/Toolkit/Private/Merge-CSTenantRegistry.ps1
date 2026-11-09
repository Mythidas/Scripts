function Merge-CSTenantRegistry {
    <#
    .SYNOPSIS
        Merges GDAP-sourced tenants into existing registry rows without touching the hand-maintained columns.

    .DESCRIPTION
        Synced columns (overwritten): DisplayName, DefaultDomain (only when the source has a value), GdapStatus.
        Manual columns (never overwritten): Customer, Group, Profile, Features, Enabled, Notes.
        Tenants no longer in the source are kept and flagged GdapStatus = Missing.
        New tenants get Customer = DisplayName, Enabled = true, everything else blank.
    #>
    [CmdletBinding()]
    param (
        [object[]]$Existing = @(),
        [object[]]$Source = @()
    )

    $columns = 'TenantId', 'DefaultDomain', 'DisplayName', 'Customer', 'Group', 'Profile', 'Features', 'Enabled', 'GdapStatus', 'Notes'

    $rows    = [ordered]@{}
    $added   = [System.Collections.Generic.List[string]]::new()
    $updated = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()

    foreach ($row in $Existing) {
        $copy = [ordered]@{}
        foreach ($c in $columns) { $copy[$c] = "$($row.$c)" }
        $rows[$copy.TenantId.ToLowerInvariant()] = $copy
    }

    $seen = @{}
    foreach ($src in $Source) {
        $key = "$($src.TenantId)".ToLowerInvariant()
        $seen[$key] = $true
        $status = if ($src.GdapActive) { 'Active' } else { 'Inactive' }

        if ($rows.Contains($key)) {
            $row    = $rows[$key]
            $before = ($columns | ForEach-Object { $row[$_] }) -join '|'
            if ($src.DisplayName)   { $row.DisplayName   = "$($src.DisplayName)" }
            if ($src.DefaultDomain) { $row.DefaultDomain = "$($src.DefaultDomain)" }
            $row.GdapStatus = $status
            if ((($columns | ForEach-Object { $row[$_] }) -join '|') -ne $before) { $updated.Add($row.TenantId) }
        }
        else {
            $rows[$key] = [ordered]@{
                TenantId      = "$($src.TenantId)"
                DefaultDomain = "$($src.DefaultDomain)"
                DisplayName   = "$($src.DisplayName)"
                Customer      = "$($src.DisplayName)"
                Group         = ''
                Profile       = ''
                Features      = ''
                Enabled       = 'true'
                GdapStatus    = $status
                Notes         = ''
            }
            $added.Add("$($src.TenantId)")
        }
    }

    foreach ($key in @($rows.Keys)) {
        if (-not $seen.ContainsKey($key) -and $rows[$key].GdapStatus -ne 'Missing') {
            $rows[$key].GdapStatus = 'Missing'
            $missing.Add($rows[$key].TenantId)
        }
    }

    [pscustomobject]@{
        Rows    = @($rows.Values | ForEach-Object { [pscustomobject]$_ })
        Added   = $added.ToArray()
        Updated = $updated.ToArray()
        Missing = $missing.ToArray()
    }
}
