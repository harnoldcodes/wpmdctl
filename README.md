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

   ```powershell
   wpmdctl [-ConfigHome <PathToConfigDir>] [-TaskName <TaskName>] <help|create|destroy|start|stop|state> [SubCommand]
   ```

   - `-ConfigHome` (optional): Path to directory containing `wpmdctl.json`. Alternatively, set the `WPMDCTL_CONFIG_HOME` environment variable.
   - `-TaskName` (optional): Name of the task to manage. Alternatively, set the `WPMDCTL_TASK_NAME` environment variable. (Required if more than one instance is ever supported.)

   Example:
   ```powershell
   wpmdctl help
   wpmdctl create
   wpmdctl start
   wpmdctl stop
   wpmdctl destroy
   wpmdctl state
   ```

## Actions

- `help`    : Print usage help
- `create`  : Creates the scheduled task
- `destroy` : Stops wpm servies, stops wpmd task, and removes the scheduled task
- `state`   : Shows registration and current status (including `wpmctl state` output if running)
- `start`   : Starts the scheduled task, creates task if it doesn't exist (see script for subcommands)
- `stop`    : Stops the scheduled task (see script for subcommands)

## Requirements

- PowerShell 7.2 or later
- `wpmctl` must be installed and available in your `PATH`

## License

MIT License. See [LICENSE](LICENSE) for details.

---

**Note:** This project is under active development. Multi-instance support is not yet available.
