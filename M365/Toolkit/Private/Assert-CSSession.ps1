function Assert-CSSession {
    [CmdletBinding()]
    param ()

    if (-not $script:CSSession) {
        throw 'Not signed in to the partner tenant. Run Connect-CSPartner first.'
    }
}
