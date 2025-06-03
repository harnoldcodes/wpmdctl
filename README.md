# wpmdctl

A PowerShell utility for managing a Windows Scheduled Task that launches and controls a [wpm](https://github.com/LGUG2Z/wpm) daemon/service.

## Features

- Loads all configuration from a single JSON file (`wpmdctl.json`)
- Supports environment variable expansion in config values
- Robust error handling and clear CLI usage
- Requires PowerShell 7.2+

## Quick Start

1. **Copy wpmdctl.ps1 into your $env:Path somewhere!**

1. **Copy the configuration file:**

   Place your `wpmdctl.json` file in the configuration directory. By default, the script will look for the config file at:

   ```
   $env:WPMDCTL_CONFIG_HOME\wpmdctl.json
   ```

   If the environment variable `WPMDCTL_CONFIG_HOME` is not set, it will default to:

   ```
   $env:USERPROFILE\.config\wpmdctl\wpmdctl.json
   ```

2. **Edit your configuration:**

   See `wpmdctl.example.json` for a template. Example:

   ```json
   {
     "wpm_instances": [
       {
         "TaskName": "wpmd",
         "TaskPath": "\\",
         "Command": "C:\\Windows\\System32\\conhost.exe",
         "Arguments": "--headless $env:USERPROFILE\\.cargo\\bin\\wpmd.exe $env:USERPROFILE\\.config\\wpm\\",
         "WorkingDir": "$env:USERPROFILE\\.config\\wpm\\",
         "StartAsAdmin": false
       }
     ]
   }
   ```

   **Note:** Only one instance is currently supported. If more than one is defined, the script will abort.

3. **Run the script:**

```
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
``` 

## Requirements

- PowerShell 7.2 or later
- `wpmctl` must be installed and available in your `PATH`

## License

MIT License. See [LICENSE](LICENSE) for details.

---

**Note:** This project is under active development. Multi-instance support is not yet available.
