#Requires -Version 7.2
param(
    [Parameter(Position = 0, Mandatory = $false)]
    [string]$Action,
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$args,
    [Parameter(Position = 2, Mandatory = $false)]
    [string]$ConfigHome,
    [Parameter(Position = 3, Mandatory = $false)]
    [string]$TaskName
)

# Load configuration from JSON (PowerShell 7+ only, no legacy support)
function Import-ConfigJson {
    param(
        [string]$ConfigPath = "$env:USERPROFILE/.config/wpmdctl/wpmdctl.json"
    )
    if (-not (Test-Path $ConfigPath)) {
        Write-Host "Error: Config file '$ConfigPath' not found."
        exit 1
    }
    try {
        $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    } catch {
        Write-Host "Error: Could not parse JSON config. $_"
        exit 1
    }
    if (-not $config.wpm_instances -or $config.wpm_instances.Count -eq 0) {
        Write-Host "Error: No wpm_instances found in config file."
        exit 1
    }
    if ($config.wpm_instances.Count -gt 1) {
        Write-Host "More than 1 wpmd instance is not yet supported.  Aborting..."
        exit 1
    }
    return $config.wpm_instances
}

# User-supplied replacements can be set before running the script, e.g.:
# $ConfigReplacements = @{ 'REPLACE_THIS' = 'WithThis'; 'ANOTHER' = 'Value' }
if (-not $ConfigReplacements) { $ConfigReplacements = @{} }

function Expand-ConfigValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )
    # Expand $env:VAR and $VAR (PowerShell style)
    $result = $Value
    $result = $result -replace '\\', '\'  # Normalize backslashes
    # Expand any $env:VAR or $VAR in the string
    $result = [regex]::Replace($result, '\$env:([A-Za-z_][A-Za-z0-9_]*)', { param($m) (Get-Item -Path "env:$($m.Groups[1].Value)" -ErrorAction SilentlyContinue).Value })
    $result = [regex]::Replace($result, '\$([A-Za-z_][A-Za-z0-9_]*)', { param($m) (Get-Item -Path "env:$($m.Groups[1].Value)" -ErrorAction SilentlyContinue).Value })
    # Remove any trailing/leading whitespace
    $result = $result.Trim()
    return $result
}

# Determine config home directory from CLI, env, or default
if (-not $ConfigHome -or $ConfigHome -eq "") {
    $ConfigHome = $env:WPMDCTL_CONFIG_HOME
}
if (-not $ConfigHome -or $ConfigHome -eq "") {
    $ConfigHome = "$env:USERPROFILE/.config/wpmdctl/"
}
$ConfigHome = Expand-ConfigValue $ConfigHome
$ConfigPath = Join-Path $ConfigHome "wpmdctl.json"

# Load all instances
$WpmdInstances = Import-ConfigJson -ConfigPath $ConfigPath

# Determine TaskName from CLI, env, or config
if (-not $TaskName -or $TaskName -eq "") {
    $TaskName = $env:WPMDCTL_TASK_NAME
}

if ($WpmdInstances.Count -eq 1) {
    # Only one instance, use it
    $Wpmd = $WpmdInstances[0]
    $TaskName = $Wpmd.TaskName
} else {
    # Multiple instances, TaskName is required
    if (-not $TaskName -or $TaskName -eq "") {
        Write-Host "Error: Multiple wpm_instances defined. You must specify -TaskName or set the WpmTaskName environment variable."
        exit 1
    }
    $Wpmd = $WpmdInstances | Where-Object { $_.TaskName -eq $TaskName }
    if (-not $Wpmd) {
        Write-Host "Error: No wpm_instance found with TaskName '$TaskName'."
        exit 1
    }
}

$TaskPath   = Expand-ConfigValue $Wpmd.TaskPath
$Command    = Expand-ConfigValue $Wpmd.Command
$Arguments  = Expand-ConfigValue $Wpmd.Arguments
$WorkingDir = Expand-ConfigValue $Wpmd.WorkingDir

# Dynamically set $Author and $UserSID
$Author = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$UserSID = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value

function Invoke-WithStatus {
    param(
        [string]$ActionDescription,
        [scriptblock]$Action,
        [string]$SuccessMessage = '',
        [string]$ErrorMessage = ''
    )
    Write-Host "==> $ActionDescription"
    try {
        & $Action
        if ($SuccessMessage) { Write-Host "    $SuccessMessage" }
    } catch {
        if ($ErrorMessage) {
            Write-Host "    $ErrorMessage $_"
        } else {
            Write-Host "    Error: $_"
        }
    }
}

# Ensure 'wpmctl' is executable within the current context and path
try {
    & wpmctl --version > $null 2>&1
} catch {
    Write-Host "Error: 'wpmctl' is not executable or not found in the current PATH. Please ensure it is installed and accessible."
    exit 1
}

# Function to display usage information
function Show-Usage {
    # Get the script name without path
    $scriptName = Split-Path -Leaf $MyInvocation.ScriptName
    Write-Host @"
Usage: $scriptName [-ConfigHome <PathToConfig>] [-TaskName <TaskName>] <Action> [SubCommand]

Config Parameters:
    -ConfigHome         - Path to directory containing wpmdctl.json (Alterntively set environment variable WPMDCTL_CONFIG_HOME)
    -TaskName           - Name of Task to Manage (Alternatively set environment varible WPMDCTL_TASK_NAME)
                        - TaskName MUST be specified if more than one wpmd instance is defined in wpmdctl.json
Available Actions:
    create              - Creates the scheduled task 'wpmd'
    destroy             - Removes the scheduled task 'wpmd'
    state               - Shows the registration and current status of the task 'wpmd' (including the raw output of 'wpmctl state' if the task is running)

    start               - Starts the scheduled task 'wpmd' (same as 'start task')
    start task          - Starts the scheduled task 'wpmd'
    start watch         - Starts the scheduled task 'wpmd' and waits for it to become ready by streaming 'wpmctl log'

    start services-all  - Starts all non-Oneshot wpm services that are not running
    start services-auto - Starts wpm services configured for auto-start
    start all           - Starts the scheduled task 'wpmd' and then all non-Oneshot wpm services

    stop                - Stops the scheduled task 'wpmd' (same as 'stop task')
    stop task           - Stops the scheduled task 'wpmd'

    stop services       - Stops all running wpm services
    stop all            - Stops all running wpm services and then the scheduled task 'wpmd'

Environment Variables:

"@
}

# Function to display task state information
function Show-TaskState {
    param(
        [string]$TaskName, 
        [string]$TaskPath,
        [object]$ExistingTask = $null
    )

    try {
        # Use existing task object if provided, otherwise get it
        $task = if ($null -ne $ExistingTask) { $ExistingTask } else { Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue }

        if ($null -eq $task) {
            Write-Host "Scheduled task '$TaskName' is NOT registered."
        } else {
            Write-Host "Scheduled task '$TaskName' is registered."

            # Get the task info to show current status
            $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue

            if ($null -ne $taskInfo) {
                Write-Host "Current Status: $($taskInfo.LastTaskResult)"
                Write-Host "Last Run Time: $($taskInfo.LastRunTime)"
                Write-Host "Next Run Time: $($taskInfo.NextRunTime)"
                Write-Host "Number of Missed Runs: $($taskInfo.NumberOfMissedRuns)"

                # Get the current state
                Write-Host "Task State: $($task.State)"
                Write-Host ''

                # If the task is running, print the raw output of 'wpmctl state'
                if ($task.State -eq 'Running') {
                    try {
                        $wpmctlOutput = & wpmctl state 2>&1

                        if ($LASTEXITCODE -eq 0 -and $null -ne $wpmctlOutput) {
                            Write-Host "Raw output of 'wpmctl state':"
                            $wpmctlOutput | ForEach-Object { Write-Host "  $_" }
                        } else {
                            Write-Host "Error: Could not fetch 'wpmctl state' output or no output available."
                        }
                    } catch {
                        Write-Host "Error while fetching 'wpmctl state' output: $_"
                    }
                }
            } else {
                Write-Host 'Could not retrieve task status information.'
            }
        }
    } catch {
        Write-Host "Error checking scheduled task status: $_"
    }
}

# Function to check if task exists and handle common error patterns
function Test-TaskExists {
    param([string]$TaskName, [string]$TaskPath)
    
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
        return $task
    } catch {
        return $null
    }
}

# Function to handle task operations with consistent error handling
function Invoke-TaskOperation {
    param(
        [string]$Operation,
        [scriptblock]$Action,
        [string]$SuccessMessage,
        [string]$ErrorMessage
    )
    
    try {
        & $Action
        if ($SuccessMessage) {
            Write-Host $SuccessMessage
        }
        $global:LASTEXITCODE = 0
    } catch {
        Write-Host "$ErrorMessage $_"
        $global:LASTEXITCODE = 1
    }
}

# Function to create scheduled task
function Invoke-CreateTask {
    param([string]$TaskName, [string]$TaskPath, [string]$Command, [string]$Arguments, [string]$WorkingDir, [string]$Author, [string]$UserSID)
    $existingTask = Test-TaskExists -TaskName $TaskName -TaskPath $TaskPath
    if ($null -ne $existingTask) {
        Write-Host "Scheduled task '$TaskName' already exists."
        Write-Host ''
        Write-Host 'Current task information:'
        Show-TaskState -TaskName $TaskName -TaskPath $TaskPath -ExistingTask $existingTask
        $global:LASTEXITCODE = 0
        return
    }
    Invoke-WithStatus "Creating scheduled task '$TaskName'..." {
        # Create settings with minimal parameters for compatibility
        $settings = New-ScheduledTaskSettingsSet `
            -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -RestartCount 999 `
            -RestartInterval ([TimeSpan]::FromMinutes(1)) `
            -StartWhenAvailable:$true
        try {
            if ($null -ne $settings) {
                if ([bool]($settings.PSObject.Properties | Where-Object { $_.Name -eq 'DisallowStartIfOnBatteries' })) {
                    $settings.DisallowStartIfOnBatteries = $false
                }
                if ([bool]($settings.PSObject.Properties | Where-Object { $_.Name -eq 'StopIfGoingOnBatteries' })) {
                    $settings.StopIfGoingOnBatteries = $false
                }
            }
        } catch {}
        try {
            if ($null -ne $settings -and [bool]($settings.PSObject.Properties | Where-Object { $_.Name -eq 'MultipleInstancesPolicy' })) {
                $settings.MultipleInstancesPolicy = 'IgnoreNew'
            }
        } catch {}
        try {
            if ($null -ne $settings.IdleSettings) {
                $settings.IdleSettings.StopOnIdleEnd = $false
                $settings.IdleSettings.RestartOnIdle = $false
            }
        } catch {}
        $triggerParams = @{ AtLogOn = $true }
        $triggerCmdInfo = Get-Command New-ScheduledTaskTrigger -ErrorAction SilentlyContinue
        if ($triggerCmdInfo -and $triggerCmdInfo.Parameters.ContainsKey('User')) {
            $triggerParams['User'] = $Author
        }
        $trigger = New-ScheduledTaskTrigger @triggerParams
        $principalParams = @{ UserId = $UserSID; LogonType = 'Interactive' }
        $principal = New-ScheduledTaskPrincipal @principalParams
        $taskAction = New-ScheduledTaskAction `
            -Execute $Command `
            -Argument $Arguments `
            -WorkingDirectory $WorkingDir
        $task = New-ScheduledTask `
            -Action $taskAction `
            -Trigger $trigger `
            -Settings $settings `
            -Principal $principal
        Register-ScheduledTask `
            -TaskName $TaskName `
            -TaskPath $TaskPath `
            -InputObject $task `
            -Force
    } "Scheduled task '$TaskName' created successfully." 'Error creating scheduled task:'
}

# Function to destroy scheduled task
function Invoke-DestroyTask {
    param([string]$TaskName, [string]$TaskPath)
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        Write-Host "Scheduled task '$TaskName' is not registered. Nothing to destroy."
        $global:LASTEXITCODE = 0
        return
    }
    if ($task.State -ne 'Disabled' -and $task.State -ne 'Ready') {
        Invoke-StopTask -TaskName $TaskName -TaskPath $TaskPath
    }
    Invoke-WithStatus "Destroying scheduled task '$TaskName'..." {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
    } "Scheduled task '$TaskName' destroyed." 'Error destroying scheduled task:'
}

# Function to start scheduled task
function Invoke-StartTask {
    param([string]$TaskName, [string]$TaskPath)
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        Write-Host "Scheduled task '$TaskName' is not registered. Registering task..."
        Invoke-CreateTask -TaskName $TaskName -TaskPath $TaskPath -Command $Command -Arguments $Arguments -WorkingDir $WorkingDir -Author $Author -UserSID $UserSID
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Unable to create task '$TaskName'. Cannot start it."
            $global:LASTEXITCODE = 1
            return
        }
        $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
        if ($null -eq $task) {
            Write-Host 'Error: Task was created but could not be retrieved. Cannot start it.'
            $global:LASTEXITCODE = 1
            return
        }
    }
    if ($task.State -eq 'Running') {
        Write-Host "Scheduled task '$TaskName' is already running (State: $($task.State))."
        $global:LASTEXITCODE = 0
    } else {
        Invoke-WithStatus "Starting scheduled task '$TaskName'..." {
            Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
        } "Scheduled task '$TaskName' started." 'Error starting scheduled task:'
    }
}

# Function to stop scheduled task
function Invoke-StopTask {
    param([string]$TaskName, [string]$TaskPath)
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        Write-Host "Scheduled task '$TaskName' is not registered. Nothing to stop."
        $global:LASTEXITCODE = 0
        return
    }
    if ($task.State -eq 'Disabled' -or $task.State -eq 'Ready') {
        Write-Host "Scheduled task '$TaskName' is already stopped (State: $($task.State))."
        $global:LASTEXITCODE = 0
        return
    }
    $services = Get-WpmServices
    if ($null -ne $services) {
        $runningServices = $services | Where-Object { $_.State -eq 'Running' }
        if ($runningServices.Count -gt 0) {
            Write-Host "Warning: There are still $($runningServices.Count) running wpm services. Stopping the scheduled task will not stop these services."
            Write-Host "Please run 'stop services' first if you want to stop the running wpm services,"
            Write-Host "or run 'stop all' to stop both the services and the scheduled task."
            Write-Host ''
        }
    }
    Invoke-WithStatus "Stopping scheduled task '$TaskName'..." {
        Stop-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
    } "Scheduled task '$TaskName' stopped." 'Error stopping scheduled task:'
}

# Function to stop all running wpmctl services
function Stop-AllWpmServices {
    param([string]$TaskName = 'wpmd', [string]$TaskPath = '\')
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
        if ($null -eq $task) {
            Write-Host 'wpmd task is not registered.'
            Write-Host 'Attempting to stop services in case they were started outside of task scheduler...'
            Write-Host 'This may hang if wpmd is not running.  Press Ctrl-C to abort.'
        } elseif ($task.State -eq 'Disabled' -or $task.State -eq 'Ready') {
            Write-Host 'wpmd task is not running.'
            Write-Host 'Attempting to stop services in case they were started outside of task scheduler...'
            Write-Host 'This may hang if wpmd is not running.  Press Ctrl-C to abort.'
        } else {
            Write-Host "wpmd task is running (State: $($task.State)). Stopping all wpmctl services..."
        }
    } catch {
        Write-Host 'Could not check wpmd task state.'
        Write-Host 'Attempting to stop services in case they were started outside of task scheduler...'
        Write-Host 'This may hang if wpmd is not running.  Press Ctrl-C to abort.'
    }
    $services = Get-WpmServices
    if ($null -eq $services) {
        Write-Host 'No services found to process.'
        return
    }
    $runningServices = $services | Where-Object { $_.State -eq 'Running' }
    if ($runningServices.Count -eq 0) {
        Write-Host 'No running wpmctl services found.'
    } else {
        Write-Host "Found $($runningServices.Count) running wpmctl services. Stopping them..."
        foreach ($service in $runningServices) {
            Invoke-WithStatus "Stopping service: $($service.Name)" {
                & wpmctl stop $service.Name
                if ($LASTEXITCODE -ne 0) { throw "Failed to stop $($service.Name)" }
            } "  Successfully stopped $($service.Name)" "  Failed to stop $($service.Name)"
        }
    }
}

# Function to start all non-oneshot wpmctl services that are not running
function Start-AllWpmServices {
    param([string]$TaskName = 'wpmd', [string]$TaskPath = '\')
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
        if ($null -eq $task) {
            Write-Host 'wpmd task is not registered. Attempting to start services in case they were configured outside of task scheduler.'
        } elseif ($task.State -eq 'Disabled' -or $task.State -eq 'Ready') {
            Write-Host 'wpmd task is not running. Attempting to start services in case they were configured outside of task scheduler.'
        } else {
            Write-Host "wpmd task is running (State: $($task.State)). Starting non-oneshot wpmctl services..."
        }
    } catch {
        Write-Host 'Could not check wpmd task state. Attempting to start services...'
    }
    $services = Get-WpmServices
    if ($null -eq $services) {
        Write-Host 'No services found to process.'
        return
    }
    $servicesToStart = $services | Where-Object { $_.Kind -ne 'Oneshot' -and $_.State -ne 'Running' }
    if ($servicesToStart.Count -eq 0) {
        Write-Host 'No non-oneshot services found that need to be started.'
    } else {
        Write-Host "Found $($servicesToStart.Count) non-oneshot services that are not running. Starting them..."
        foreach ($service in $servicesToStart) {
            Invoke-WithStatus "Starting service: $($service.Name)" {
                & wpmctl start $service.Name
                if ($LASTEXITCODE -ne 0) { throw "Failed to start $($service.Name)" }
            } "  Successfully started $($service.Name)" "  Failed to start $($service.Name)"
        }
    }
}

# Function to start WPM services configured for auto-start
function Start-AutoStartServices {
    Write-Host 'Discovering auto-start services...'
    $autoStartServices = Get-AutoStartServices
    if ($autoStartServices.Count -eq 0) {
        Write-Host 'No auto-start services found.'
        return
    }
    Write-Host "Found $($autoStartServices.Count) auto-start service(s): $($autoStartServices -join ', ')"
    foreach ($serviceName in $autoStartServices) {
        Invoke-WithStatus "Starting auto-start service: $serviceName" {
            & wpmctl start $serviceName 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Failed to start $serviceName" }
        } "  Successfully started $serviceName" "  Failed to start $serviceName"
    }
}

# Function to parse wpmctl state output into services
function Get-WpmServices {
    try {
        # Run wpmctl state command and capture output
        $wpmctlOutput = & wpmctl state 2>&1

        if ($LASTEXITCODE -ne 0 -or $null -eq $wpmctlOutput) {
            Write-Host "Error: Could not execute 'wpmctl state' command."
            Write-Host 'Raw output:'
            if ($null -ne $wpmctlOutput) {
                $wpmctlOutput | ForEach-Object { Write-Host "  $_" }
            } else {
                Write-Host '  (no output)'
            }
            return $null
        }

        # Convert output to string array if it isn't already
        $lines = @($wpmctlOutput)

        # Check if output looks like expected table format
        if ($lines.Count -lt 3 -or $lines[0] -notmatch '\+.*\+' -or $lines[1] -notmatch '\|\s*name\s*\|') {
            Write-Host "Error: Unexpected output format from 'wpmctl state' command."
            return $null
        }

        # Parse the table - skip header lines (first 2 lines) and footer
        $services = @()
        for ($i = 2; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]

            # Skip separator lines (starting with +)
            if ($line -match '^\+.*\+$') {
                continue
            }

            try {
                # Parse data lines (format: | name | kind | state | pid | timestamp |)
                if ($line -match '^\|\s*([^\|]+?)\s*\|\s*([^\|]+?)\s*\|\s*([^\|]+?)\s*\|\s*([^\|]*?)\s*\|\s*([^\|]*?)\s*\|$') {
                    $service = [PSCustomObject]@{
                        Name      = $matches[1].Trim()
                        Kind      = $matches[2].Trim()
                        State     = $matches[3].Trim()
                        PID       = if ($matches[4].Trim() -ne '') { [int]$matches[4].Trim() } else { $null }
                        Timestamp = $matches[5].Trim()
                    }
                    $services += $service
                }
            } catch {}
        }

        return $services
    } catch {
        Write-Host "Error parsing wpmctl state output: $_"
        return $null
    }
}

# Function to discover services configured for auto-start
function Get-AutoStartServices {
    try {
        # Step 1: Get the unit file path from wpmctl units
        Write-Verbose 'Getting WPM unit file path...'
        $wpmctlUnitsOutput = & wpmctl units 2>&1
        
        if ($LASTEXITCODE -ne 0 -or $null -eq $wpmctlUnitsOutput) {
            Write-Error "Could not execute 'wpmctl units' command."
            Write-Verbose 'Raw output:'
            if ($null -ne $wpmctlUnitsOutput) {
                $wpmctlUnitsOutput | ForEach-Object { Write-Verbose "  $_" }
            } else {
                Write-Verbose '  (no output)'
            }
            return @()
        }
        
        # Parse the output to find the unit path
        $unitPath = $null
        foreach ($line in $wpmctlUnitsOutput) {
            # Look for a line that looks like a path (contains backslashes or forward slashes)
            if ($line -match '^[A-Za-z]:[\\\/].*' -or $line -match '^[\/~].*') {
                $unitPath = $line.Trim()
                break
            }
        }
        
        if (-not $unitPath -or -not (Test-Path $unitPath)) {
            Write-Error "Could not find valid unit file path from 'wpmctl units' output."
            Write-Verbose 'Raw output:'
            $wpmctlUnitsOutput | ForEach-Object { Write-Verbose "  $_" }
            return @()
        }
        
        Write-Verbose "Found unit file path: $unitPath"
        
        # Step 2: Parse unit files to find auto-start services
        Write-Verbose 'Scanning unit files for auto-start services...'
        $autoStartServices = @()
        
        # Get all TOML and JSON files in the unit directory
        $unitFiles = Get-ChildItem -Path $unitPath -Filter '*.toml' -ErrorAction SilentlyContinue
        $unitFiles += Get-ChildItem -Path $unitPath -Filter '*.json' -ErrorAction SilentlyContinue
        
        if ($unitFiles.Count -eq 0) {
            Write-Error "No unit files found in: $unitPath"
            return @()
        }
        
        foreach ($file in $unitFiles) {
            try {
                $content = Get-Content -Path $file.FullName -Raw -ErrorAction SilentlyContinue
                if (-not $content) { continue }
                
                $isAutoStart = $false
                $serviceName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                
                # Parse based on file extension
                if ($file.Extension -eq '.toml') {
                    # Simple TOML parsing for Service.Autostart
                    if ($content -match '(?m)^\s*\[Service\]' -and $content -match '(?m)^\s*Autostart\s*=\s*true\s*$') {
                        $isAutoStart = $true
                    }
                } elseif ($file.Extension -eq '.json') {
                    # JSON parsing
                    try {
                        $jsonData = $content | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($jsonData.Service.Autostart -eq $true) {
                            $isAutoStart = $true
                        }
                    } catch {
                        Write-Verbose "Could not parse JSON file: $($file.Name)"
                    }
                }
                
                if ($isAutoStart) {
                    $autoStartServices += $serviceName
                    Write-Verbose "Found auto-start service: $serviceName"
                }
            } catch {
                Write-Verbose "Error processing file $($file.Name): $_"
            }
        }
        
        # Return the list of auto-start services
        return $autoStartServices
    } catch {
        Write-Error "Error in Get-AutoStartServices: $_"
        return @()
    }
}

# Add the new function to watch wpmd startup
function Watch-WpmdStartup {
    try {
        Write-Host "Streaming logs from 'wpmctl log'..."
        # Set up tracking variables
        $foundSuccess = $false
        $timeout = 30  # 30 second timeout
        $startTime = Get-Date
        $processedLines = @{}  # Dictionary to track which lines we've already seen/processed
        $lineCounter = 0  # Counter to maintain order even if lines are identical
        # Start background job to run wpmctl log
        $job = Start-Job -ScriptBlock {
            & wpmctl log 2>&1
        }
        Write-Host 'Monitoring log output...'
        while (-not $foundSuccess -and ((Get-Date) - $startTime).TotalSeconds -lt $timeout) {
            # Check if job has output, but don't keep it in the job queue
            $output = Receive-Job -Job $job
            if ($output) {
                foreach ($line in $output) {
                    # Convert the line to string
                    $lineStr = $line.ToString()
                    # Create a unique key for each line to prevent duplicates
                    $lineKey = "$lineCounter`:$lineStr"
                    $lineCounter++
                    # Only process each unique line once
                    if (-not $processedLines.ContainsKey($lineKey)) {
                        $processedLines[$lineKey] = $true
                        Write-Host $lineStr
                        if ($lineStr -match 'listening on wpmd.sock') {
                            $foundSuccess = $true
                            Write-Host 'wpmd started successfully.'
                            break
                        }
                    }
                }
            }
            # Check if job completed
            if ($job.State -eq 'Completed') {
                break
            }
            Start-Sleep -Milliseconds 200
        }
        if (-not $foundSuccess) {
            if (((Get-Date) - $startTime).TotalSeconds -ge $timeout) {
                Write-Host "Timeout waiting for wpmd to start. Check the logs manually with 'wpmctl log'."
            } else {
                Write-Host 'wpmctl log process completed without detecting startup success.'
            }
        }
    } catch {
        Write-Host "Error while streaming logs: $_"
    } finally {
        # Clean up job
        if ($null -ne $job) {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }
}

#
############################################################################################
# Main script execution starts here
############################################################################################
#

# Help menu if no action is provided
if (-not $Action) {
    Show-Usage
    exit
}

# Check for common misspelling
if ($Action -eq 'status') {
    Write-Host "Did you mean 'state'?"
    exit
}

# Validate action parameter
$validActions = @('create', 'destroy', 'start', 'stop', 'state')
if ($Action -and $Action -notin $validActions) {
    Write-Host "Invalid action '$Action'"
    Show-Usage
    exit
}

switch ($Action) {
    'create' {
        Invoke-CreateTask -TaskName $TaskName -TaskPath $TaskPath -Command $Command -Arguments $Arguments -WorkingDir $WorkingDir -Author $Author -UserSID $UserSID
    }
    'destroy' {
        Write-Host 'Stopping all wpm services...'
        Stop-AllWpmServices -TaskName $TaskName -TaskPath $TaskPath
        Write-Host 'Waiting 5 seconds before stopping the task...'
        Start-Sleep -Seconds 5
        Write-Host 'Stopping all wpmd task...'
        Invoke-StopTask -TaskName $TaskName -TaskPath $TaskPath
        Write-Host 'Destroying wpmd task...'
        Invoke-DestroyTask -TaskName $TaskName -TaskPath $TaskPath

    }    
    'start' {
        # Check if there's a subcommand for "start"
        if ($args.Count -gt 0) {
            switch ($args[0]) {
                'task' {
                    Write-Host "Starting the '$TaskName' task only..."
                    Invoke-StartTask -TaskName $TaskName -TaskPath $TaskPath
                }'watch' {
                    Invoke-StartTask -TaskName $TaskName -TaskPath $TaskPath
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "Running 'wpmctl log' to wait for wpmd to become ready. Press Ctrl-C to abort watching logs."
                        Watch-WpmdStartup
                    } else {
                        Write-Host 'Not watching logs because task start failed.'
                    }
                }
                'services-all' {
                    Write-Host 'Starting all non-oneshot wpmctl services...'
                    Start-AllWpmServices -TaskName $TaskName -TaskPath $TaskPath
                }
                'services-auto' {
                    Write-Host 'Starting auto-start wpmctl services...'
                    Start-AutoStartServices
                }                'all' {
                    Write-Host "Starting the '$TaskName' task and all non-oneshot services..."
                    Invoke-StartTask -TaskName $TaskName -TaskPath $TaskPath
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host 'Waiting 5 seconds before starting services...'
                        Start-Sleep -Seconds 5
                        Start-AllWpmServices -TaskName $TaskName -TaskPath $TaskPath
                    } else {
                        Write-Host 'Not starting services because task start failed.'
                    }
                }
                default {
                    Write-Host "Invalid start subcommand: $($args[0])"
                    Write-Host 'Valid options are: task, watch, services-all, services-auto, all'
                    Show-Usage
                }
            }
        } else {
            # Default behavior: start the task only
            Write-Host "Starting the '$TaskName' task..."
            Invoke-StartTask -TaskName $TaskName -TaskPath $TaskPath
        }
    }
    'stop' {
        # Check if there's a subcommand for "stop"
        if ($args.Count -gt 0) {
            switch ($args[0]) {
                'task' {
                    Write-Host "Stopping the '$TaskName' task only..."
                    Invoke-StopTask -TaskName $TaskName -TaskPath $TaskPath
                }
                'services' {
                    Write-Host 'Stopping all running wpmctl services...'
                    Stop-AllWpmServices -TaskName $TaskName -TaskPath $TaskPath
                }                
                'all' {
                    Write-Host 'Stopping all wpmctl services and the task...'
                    Stop-AllWpmServices -TaskName $TaskName -TaskPath $TaskPath
                    Write-Host 'Waiting 5 seconds before stopping the task...'
                    Start-Sleep -Seconds 5
                    Invoke-StopTask -TaskName $TaskName -TaskPath $TaskPath
                }
                default {
                    Write-Host "Invalid stop subcommand: $($args[0])"
                    Write-Host 'Valid options are: task, services, all'
                    Show-Usage
                }
            }
        } else {
            Write-Host "Stopping the '$TaskName' task only..."
            Invoke-StopTask -TaskName $TaskName -TaskPath $TaskPath
        }
    }    'state' {
        Show-TaskState -TaskName $TaskName -TaskPath $TaskPath
    }
}
