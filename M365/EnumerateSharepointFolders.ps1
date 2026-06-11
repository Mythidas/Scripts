# ===============================================
# Export SharePoint Folder Tree View
# All Document Libraries / Drives in a SharePoint Site
# ===============================================

param(
    [Parameter(Mandatory = $true)]
    [string]$SiteUrl,

    [string]$OutputCsv = "SharePoint_Folder_Tree.csv"
)

# ---------------------------
# 1 Connect to Microsoft Graph
# ---------------------------
Connect-MgGraph -Scopes `
    "Sites.Read.All",
    "Files.Read.All"

# ---------------------------
# 2 Resolve SharePoint Site
# ---------------------------
Write-Host "Resolving SharePoint site..." -ForegroundColor Cyan

$uri = [uri]$SiteUrl
$hostname = $uri.Host
$sitePath = $uri.AbsolutePath.TrimEnd("/")

$site = Get-MgSite -SiteId "${hostname}:$sitePath"

Write-Host "Site found: $($site.DisplayName)" -ForegroundColor Green

# ---------------------------
# 3 Get all document libraries / drives
# ---------------------------
Write-Host "Retrieving document libraries..." -ForegroundColor Cyan

$drives = Get-MgSiteDrive -SiteId $site.Id -All

$totalDrives = $drives.Count
Write-Host "Found $totalDrives document libraries. Starting folder export..." -ForegroundColor Green

# ---------------------------
# 4 Recursive folder function
# ---------------------------
$exportFolders = @()
$global:folderCounter = 0

function Get-SharePointFolderTree {
    param(
        [string]$DriveId,
        [string]$DriveName,
        [string]$ParentItemId,
        [string]$ParentPath,
        [int]$Depth
    )

    $encodedDriveId = [uri]::EscapeDataString($DriveId)
    $encodedItemId  = [uri]::EscapeDataString($ParentItemId)

    $uri = "https://graph.microsoft.com/v1.0/drives/$encodedDriveId/items/$encodedItemId/children?`$select=id,name,folder,file,webUrl,createdDateTime,lastModifiedDateTime,createdBy,lastModifiedBy"

    do {
        try {
            $response = Invoke-MgGraphRequest `
                -Method GET `
                -Uri $uri `
                -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not read children for path: $ParentPath. Error: $($_.Exception.Message)"
            return
        }

        foreach ($item in $response.value) {

            # Skip anything that is not a folder
            if (-not $item.folder) {
                continue
            }

            $global:folderCounter++

            $folderPath = "$ParentPath/$($item.name)"
            $treeView = ("|   " * $Depth) + "|-- " + $item.name

            Write-Progress `
                -Activity "Exporting SharePoint Folder Tree" `
                -Status "Processing folder: $folderPath" `
                -CurrentOperation "Folders found: $global:folderCounter"

            $script:exportFolders += [PSCustomObject]@{
                SiteName             = $site.DisplayName
                SiteUrl              = $SiteUrl
                DocumentLibrary      = $DriveName
                FolderName           = $item.name
                FolderPath           = $folderPath
                TreeView             = $treeView
                Depth                = $Depth
                FolderId             = $item.id
                ParentFolderId       = $ParentItemId
                WebUrl               = $item.webUrl
                ChildFolderCount     = $item.folder.childCount
                CreatedDateTime      = $item.createdDateTime
                LastModifiedDateTime = $item.lastModifiedDateTime
                CreatedBy            = $item.createdBy.user.displayName
                LastModifiedBy       = $item.lastModifiedBy.user.displayName
            }

            Get-SharePointFolderTree `
                -DriveId $DriveId `
                -DriveName $DriveName `
                -ParentItemId $item.id `
                -ParentPath $folderPath `
                -Depth ($Depth + 1)
        }

        $uri = $response.'@odata.nextLink'

    } while ($uri)
}

# ---------------------------
# 5 Process each document library
# ---------------------------
$driveCounter = 0

foreach ($drive in $drives) {
    $driveCounter++

    Write-Progress `
        -Activity "Processing Document Libraries" `
        -Status "Processing: $($drive.Name) ($driveCounter of $totalDrives)" `
        -PercentComplete ([math]::Round(($driveCounter / $totalDrives) * 100, 0))

    Write-Host "Processing library: $($drive.Name)" -ForegroundColor Cyan

try {
    $root = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/drives/$($drive.Id)/root?`$select=id,name,folder,webUrl,createdDateTime,lastModifiedDateTime,createdBy,lastModifiedBy" `
        -ErrorAction Stop
}
catch {
    Write-Warning "Could not read root for library: $($drive.Name). Error: $($_.Exception.Message)"
    continue
}

    # Add library root row
    $exportFolders += [PSCustomObject]@{
        SiteName             = $site.DisplayName
        SiteUrl              = $SiteUrl
        DocumentLibrary      = $drive.Name
        FolderName           = $drive.Name
        FolderPath           = $drive.Name
        TreeView             = $drive.Name
        Depth                = 0
        FolderId             = $root.Id
        ParentFolderId       = ""
        WebUrl               = $root.WebUrl
        ChildFolderCount     = $root.folder.childCount
        CreatedDateTime      = $root.CreatedDateTime
        LastModifiedDateTime = $root.LastModifiedDateTime
        CreatedBy            = $root.CreatedBy.User.DisplayName
        LastModifiedBy       = $root.LastModifiedBy.User.DisplayName
    }

    Get-SharePointFolderTree `
        -DriveId $drive.Id `
        -DriveName $drive.Name `
        -ParentItemId $root.Id `
        -ParentPath $drive.Name `
        -Depth 1
}

# Clear progress bars
Write-Progress -Activity "Processing Document Libraries" -Completed
Write-Progress -Activity "Exporting SharePoint Folder Tree" -Completed

# ---------------------------
# 6 Export to CSV
# ---------------------------
$exportFolders |
    Sort-Object DocumentLibrary, FolderPath |
    Export-Csv $OutputCsv -NoTypeInformation -Encoding UTF8

Write-Host "`nExport complete!" -ForegroundColor Green
Write-Host "File: $OutputCsv" -ForegroundColor Cyan
Write-Host "Total folders processed: $($exportFolders.Count)" -ForegroundColor Cyan
