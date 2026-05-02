# =============================================
# Export Shared Calendar to CSV with Progress Bar
# Using Microsoft Graph PowerShell SDK
# =============================================

param(
    [string]$MailboxName = "office.calendar@renstar.net",
    [datetime]$StartTime = (Get-Date).AddYears(-1),
    [datetime]$EndTime   = (Get-Date).AddDays(1),
    [string]$FileName    = "SharedCalendar_Audit.csv"
)

# Connect to Microsoft Graph
Connect-MgGraph -Scopes "Calendars.Read.Shared", "Calendars.Read", "User.Read.All" -NoWelcome

Write-Host "Connected to Microsoft Graph" -ForegroundColor Green
Write-Host "Fetching calendar events for: $MailboxName" -ForegroundColor Cyan
Write-Host "Date range: $($StartTime.ToShortDateString()) → $($EndTime.ToShortDateString())`n"

# Step 1: Retrieve all events (fast fetch)
$events = Get-MgUserCalendarView -UserId $MailboxName `
                                 -StartDateTime $StartTime `
                                 -EndDateTime $EndTime `
                                 -All `
                                 -Property Subject, Start, End, Location, Organizer, Attendees, 
                                           IsAllDay, IsCancelled, Sensitivity, ShowAs, 
                                           BodyPreview, CreatedDateTime, LastModifiedDateTime, 
                                           Recurrence, SeriesMasterId

if (-not $events -or $events.Count -eq 0) {
    Write-Host "No events found in the specified date range." -ForegroundColor Yellow
    exit
}

Write-Host "Retrieved $($events.Count) events. Processing into report..." -ForegroundColor Cyan

# Step 2: Process events with progress bar
$report = @()
$i = 0
$total = $events.Count

foreach ($event in $events) {
    $i++
    $percent = [math]::Round(($i / $total) * 100)

    Write-Progress -Activity "Processing Calendar Events" `
                   -Status "Processing event $i of $total" `
                   -PercentComplete $percent `
                   -CurrentOperation $event.Subject

    $report += [PSCustomObject]@{
        Subject              = $event.Subject
        Start                = $event.Start.DateTime
        StartTimeZone        = $event.Start.TimeZone
        End                  = $event.End.DateTime
        EndTimeZone          = $event.End.TimeZone
        IsAllDay             = $event.IsAllDay
        Location             = $event.Location.DisplayName
        Organizer            = if ($event.Organizer) { $event.Organizer.EmailAddress.Name } else { "" }
        OrganizerEmail       = if ($event.Organizer) { $event.Organizer.EmailAddress.Address } else { "" }
        Attendees            = ($event.Attendees | ForEach-Object { "$($_.EmailAddress.Name) ($($_.EmailAddress.Address))" }) -join "; "
        IsCancelled          = $event.IsCancelled
        Sensitivity          = $event.Sensitivity
        ShowAs               = $event.ShowAs
        BodyPreview          = $event.BodyPreview
        Created              = $event.CreatedDateTime
        LastModified         = $event.LastModifiedDateTime
        HasRecurrence        = if ($event.Recurrence) { $true } else { $false }
        SeriesMasterId       = $event.SeriesMasterId
        Id                   = $event.Id
    }
}

# Clear the progress bar
Write-Progress -Activity "Processing Calendar Events" -Completed

# Export to CSV
$FullPath = Join-Path (Get-Location) $FileName
$report | Export-Csv -Path $FullPath -NoTypeInformation -Encoding UTF8

Write-Host "`nExport completed successfully!" -ForegroundColor Green
Write-Host "File saved to: $FullPath" -ForegroundColor Green
Write-Host "Total events exported: $($report.Count)" -ForegroundColor Cyan

# Optional: Open the file automatically
Invoke-Item $FullPath
