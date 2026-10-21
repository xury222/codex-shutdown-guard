# Release validation: 1.1.0

Validated on Windows with Windows PowerShell 5.1 and Node.js 24.15.0 on 2026-10-21.

| Suite | Passed |
| --- | ---: |
| Native state machine | 90 |
| Guardian review filtering | 89 |
| Native repair and panel behavior | 66 |
| Session and subagent identity | 65 |
| Task status metadata | 17 |
| Task manager layout | 117 |
| Tray toggle | 20 |
| Codex launch boundary | 72 |
| Codex startup option | 83 |
| Isolated startup process smoke | 16 |
| Portable installation | 81 |
| Installation process lifecycle | 47 |
| PowerShell bridge | 143 |
| Node MCP | 8 |
| Public install/uninstall wrappers | 18 |
| Total | 932 |

The wrapper smoke test ran against the extracted Windows ZIP using an independent program directory, state directory and registration file with `-NoStart -NoShortcuts`. It exercised clean installation, configuration-preserving upgrade, read-only bridge inspection, no-op disarming of an absent instance, and uninstallation. Unknown files and durable preferences survived uninstallation. The installer suites also checked rejection of updates to armed instances and rejection of a state-directory switch while the old instance was running, using simulated instances.

The four documented local marketplace commands succeeded with a separate Codex home: add marketplace, list marketplaces, add plugin, and list plugins. The installed test copy reported version 1.1.0. This did not change the user's Codex plugin installation or account release.

All 24 packaged PowerShell scripts and modules parsed on Windows PowerShell 5.1. The skill passed `quick_validate.py` and its UTF-8 BOM check. Source manifests, file inventories, ZIP CRCs and archived file hashes are checked by the release build script.

Two settings tests initially hit the sandbox's redirected temporary-directory restrictions. They passed after only their test temporary directory was moved into the workspace. The production source was unchanged for those reruns.

The startup process smoke test launched only an isolated dummy native program and a disabled fixture watcher. Layout screenshots used mock tasks. No real shutdown, reboot, live guard upgrade, user Startup change, Codex desktop restart, or acceptance test on another computer was performed. The package does not include Node.js, a signed executable installer, credentials, session data, runtime logs or user configuration.
