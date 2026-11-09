function Disconnect-CSPartner {
    <#
    .SYNOPSIS
        Forgets the partner sign-in and every cached tenant token.
    #>
    [CmdletBinding()]
    param ()

    $script:CSSession = $null
    $script:CSContext = $null
}
