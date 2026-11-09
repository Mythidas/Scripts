function Invoke-CSForEachTenant {
    <#
    .SYNOPSIS
        Runs a script block once per tenant, each in its own isolated process, with a delegated token for that tenant.

    .DESCRIPTION
        For every tenant piped in (see Get-CSTenant) the runner mints a GDAP token in this session, starts a background job
        (separate process - no shared module/connection state between tenants), imports CSToolkit there, sets the tenant context, and
        invokes your script block as  & $ScriptBlock $Tenant @ArgumentList.
        Inside the block, Invoke-CSGraph works without a -Context, and New-CSResult fills in the tenant fields.

        A failure in one tenant never stops the others. Each tenant produces one run object:
          Tenant, TenantId, Customer, Status (Succeeded | SucceededWithErrors | Failed | TimedOut), Duration, Output, Errors, Warnings, LogFile
        Run objects are emitted as tenants finish. With -OutputOnly only the script block output is emitted and failures become errors.

        The script block runs in a fresh process: it cannot see your variables ($using: and closures do not work). Pass data with
        -ArgumentList. Write-Host/Verbose output is captured into the per-tenant log file (Data/Logs/<run>/<tenant>.log),
        not shown live. -WhatIf is passed through, so change commands inside the block honour it.

    .PARAMETER ThrottleLimit
        Tenants processed at once. Default 5.

    .PARAMETER NoAuth
        Skip token minting (offline testing, or script blocks that do not call Graph).

    .EXAMPLE
        Get-CSTenant -Group Dental | Invoke-CSForEachTenant { param($t) Invoke-CSGraph '/organization' | Select-Object displayName } -OutputOnly

    .EXAMPLE
        $runs = Get-CSTenant | Invoke-CSForEachTenant { param($t, $days) Get-StaleUsers -Days $days } -ArgumentList 90
        $runs | Where-Object Status -ne Succeeded
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSShouldProcess', '', Justification = '-WhatIf is forwarded to the per-tenant processes, not gated here.')]
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]]$Tenant,

        [Parameter(Mandatory, Position = 0)]
        [scriptblock]$ScriptBlock,

        [object[]]$ArgumentList = @(),

        [ValidateRange(1, 20)]
        [int]$ThrottleLimit = 5,

        [double]$TimeoutMinutes = 30,

        [string]$TokenScope = 'https://graph.microsoft.com/.default',

        [string]$LogPath = (Join-Path $script:DataPath ('Logs/' + (Get-Date -Format 'yyyyMMdd-HHmmss'))),

        [switch]$NoAuth,

        [switch]$OutputOnly
    )

    begin {
        $tenants = [System.Collections.Generic.List[object]]::new()
        $wrapper = {
            param($ManifestPath, $Tenant, $Token, $ScriptText, $ArgList, $RunWhatIf, $RunVerbose)
            if ($RunWhatIf)  { $WhatIfPreference  = $true }
            if ($RunVerbose) { $VerbosePreference = 'Continue' }
            Import-Module $ManifestPath -Force
            Set-CSContext -Tenant $Tenant -Token $Token
            & ([scriptblock]::Create($ScriptText)) $Tenant @ArgList
        }
        $manifest = Join-Path $MyInvocation.MyCommand.Module.ModuleBase 'CSToolkit.psd1'
    }
    process { foreach ($t in $Tenant) { $tenants.Add($t) } }
    end {
        if ($tenants.Count -eq 0) { Write-Warning 'Invoke-CSForEachTenant: no tenants to process.'; return }
        if (-not $NoAuth) { Assert-CSSession }

        New-Item -ItemType Directory -Path $LogPath -Force -WhatIf:$false | Out-Null
        $queue    = [System.Collections.Generic.Queue[object]]::new($tenants)
        $running  = @{}          # job id -> @{ Job; Tenant; Started }
        $total    = $tenants.Count
        $finished = 0
        $tally    = @{ Succeeded = 0; SucceededWithErrors = 0; Failed = 0; TimedOut = 0 }
        $runWhatIf   = [bool]$WhatIfPreference
        $runVerbose  = $VerbosePreference -ne 'SilentlyContinue'
        $workingDir  = (Get-Location).Path

        $newRun = {
            param($t, $status, $started, $output, $errors, $warnings, $logFile)
            [pscustomobject]@{
                PSTypeName = 'CS.TenantRun'
                Tenant     = if ($t.DisplayName) { $t.DisplayName } else { $t.DefaultDomain }
                TenantId   = $t.TenantId
                Customer   = $t.Customer
                Status     = $status
                Duration   = (Get-Date) - $started
                Output     = @($output)
                Errors     = @($errors)
                Warnings   = @($warnings)
                LogFile    = $logFile
            }
        }

        $complete = {
            param($run)
            $tally[$run.Status]++
            if ($OutputOnly) {
                $run.Output
                if ($run.Status -in 'Failed', 'TimedOut') {
                    Write-Error "[$($run.Tenant)] $($run.Status): $($run.Errors | Select-Object -First 1)" -ErrorAction Continue
                }
            }
            else { $run }
        }

        try {
            while ($queue.Count -gt 0 -or $running.Count -gt 0) {

                # Start jobs while slots are free
                while ($queue.Count -gt 0 -and $running.Count -lt $ThrottleLimit) {
                    $t       = $queue.Dequeue()
                    $started = Get-Date
                    $label   = if ($t.DisplayName) { $t.DisplayName } else { $t.DefaultDomain }
                    $logFile = Join-Path $LogPath (($label -replace '[^\w\.\-]+', '_') + '.log')

                    $token = $null
                    if (-not $NoAuth) {
                        try   { $token = Get-CSTenantToken -TenantId $t.TenantId -Scope $TokenScope }
                        catch {
                            "Token error: $($_.Exception.Message)" | Set-Content -LiteralPath $logFile -WhatIf:$false
                            $finished++
                            & $complete (& $newRun $t 'Failed' $started @() @("Token error: $($_.Exception.Message)") @() $logFile)
                            continue
                        }
                    }

                    $job = Start-Job -WorkingDirectory $workingDir -ScriptBlock $wrapper `
                        -ArgumentList $manifest, $t, $token, $ScriptBlock.ToString(), $ArgumentList, $runWhatIf, $runVerbose
                    $running[$job.Id] = @{ Job = $job; Tenant = $t; Started = $started; LogFile = $logFile }
                }

                $names = ($running.Values | ForEach-Object { if ($_.Tenant.DisplayName) { $_.Tenant.DisplayName } else { $_.Tenant.DefaultDomain } }) -join ', '
                Write-Progress -Activity 'Processing tenants' -Status "$finished of $total done - running: $names" -PercentComplete (($finished / $total) * 100)

                if ($running.Count -gt 0) {
                    [void](Wait-Job -Job @($running.Values.Job) -Any -Timeout 1)
                }

                foreach ($id in @($running.Keys)) {
                    $entry   = $running[$id]
                    $job     = $entry.Job
                    $timeout = ((Get-Date) - $entry.Started).TotalMinutes -gt $TimeoutMinutes

                    if ($job.State -in 'Running', 'NotStarted' -and -not $timeout) { continue }

                    $timedOut = $job.State -in 'Running', 'NotStarted'
                    if ($timedOut) { Stop-Job $job -WhatIf:$false }

                    # Read the child job's stream collections directly: Receive-Job would replay Write-Host / warnings to the console.
                    $child    = $job.ChildJobs[0]
                    $errors   = @($child.Error | ForEach-Object { $_.Exception.Message })
                    $warnings = @($child.Warning | ForEach-Object { $_.Message })
                    $info     = @($child.Information | ForEach-Object { "$($_.MessageData)" })
                    $verbose  = @($child.Verbose | ForEach-Object { $_.Message })
                    $output   = @($child.Output | ForEach-Object {
                            foreach ($noise in 'PSComputerName', 'RunspaceId', 'PSShowComputerName') { $_.PSObject.Properties.Remove($noise) }
                            $_
                        })

                    $status = if ($timedOut) { 'TimedOut' }
                    elseif ($job.State -eq 'Failed') { 'Failed' }
                    elseif ($errors.Count -gt 0) { 'SucceededWithErrors' }
                    else { 'Succeeded' }

                    if ($job.State -eq 'Failed' -and $child.JobStateInfo.Reason) {
                        $errors += $child.JobStateInfo.Reason.Message
                    }
                    if ($timedOut) { $errors += "Timed out after $TimeoutMinutes minutes." }

                    $logLines = @("Status: $status", "Started: $($entry.Started.ToString('s'))", "Duration: $(((Get-Date) - $entry.Started).ToString('hh\:mm\:ss'))", '')
                    $logLines += $info | ForEach-Object { "[info]    $_" }
                    $logLines += $verbose | ForEach-Object { "[verbose] $_" }
                    $logLines += $warnings | ForEach-Object { "[warning] $_" }
                    $logLines += $errors | ForEach-Object { "[error]   $_" }
                    $logLines | Set-Content -LiteralPath $entry.LogFile -WhatIf:$false

                    Remove-Job $job -Force -WhatIf:$false
                    $running.Remove($id)
                    $finished++
                    & $complete (& $newRun $entry.Tenant $status $entry.Started $output $errors $warnings $entry.LogFile)
                }
            }
        }
        finally {
            foreach ($entry in $running.Values) { Stop-Job $entry.Job -WhatIf:$false -ErrorAction SilentlyContinue; Remove-Job $entry.Job -Force -WhatIf:$false -ErrorAction SilentlyContinue }
            Write-Progress -Activity 'Processing tenants' -Completed
        }

        Write-Host ("Tenants: {0} ok, {1} with errors, {2} failed, {3} timed out. Logs: {4}" -f
            $tally.Succeeded, $tally.SucceededWithErrors, $tally.Failed, $tally.TimedOut, $LogPath) -ForegroundColor Cyan
    }
}
