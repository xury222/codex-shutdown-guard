# Release validation: 1.1.3

Validated on Windows with Windows PowerShell 5.1 and Node.js on 2026-10-27. All existing native, bridge, MCP and setup suites listed for 1.1.2 below were rerun for this patch; the missing-session suite adds 120 checks. The table includes completed checks only.

| Suite | Passed |
| --- | ---: |
| Native state machine | 90 |
| Guardian review filtering | 118 |
| Native repair and panel behavior | 66 |
| Session and subagent identity | 67 |
| Task status metadata | 31 |
| Task manager layout | 126 |
| Tray toggle | 20 |
| Codex launch boundary | 72 |
| Codex startup option | 83 |
| Isolated startup process smoke | 16 |
| Portable installation | 81 |
| Installation process lifecycle | 47 |
| Subagent shutdown policy | 210 |
| Missing-session cleanup and task-record labels | 120 |
| PowerShell bridge | 143 |
| Node MCP | 8 |
| Setup worker and native-operation result handling | 24 |
| Optional plugin dependencies, installation and recovery | 102 |
| Extracted-archive native wrappers | 18 |
| Total | 1442 |

The missing-session tests cover cleanup of confirmed-missing candidates without observed active or unknown turns, retention of missing files with unfinished turns, permission and I/O failure handling, and task ownership labels on pending or read-error rows. User logs and compressed copies remain outside the cleanup operation. Cleanup covers stale caches left by compression or archival; existing unread records retain their previous shutdown policy.

The locally installed guard was refreshed while unarmed through the native installer. The configuration and both startup-preference files retained identical byte hashes. The compressed history copies checked during the update also retained identical SHA-256 hashes, and the installed core module and main script matched the source hashes. A fresh schema-8 runtime snapshot after history replay confirmed running=true, armed=false, readingHistory=false, historyBytesRemaining=0 and unknownCount=0. The stale pending-read entries were absent from task and diagnostic lists; observed main tasks remained blocking while child tasks did not.

The extracted Windows archive completed 18 native public-wrapper checks for isolated clean installation, configuration-preserving upgrade, read-only inspection and uninstallation with -NoStart -NoShortcuts. All 31 packaged PowerShell scripts and modules parsed on Windows PowerShell 5.1.

No real PC shutdown or reboot, Codex desktop restart, or acceptance test on another computer was performed.

## Previous release: 1.1.2

Validated on Windows with Windows PowerShell 5.1 and Node.js on 2026-10-22. All existing native suites listed below were rerun for this patch; the subagent-policy suite is new. The table includes completed checks only.

| Suite | Passed |
| --- | ---: |
| Native state machine | 90 |
| Guardian review filtering | 118 |
| Native repair and panel behavior | 66 |
| Session and subagent identity | 67 |
| Task status metadata | 31 |
| Task manager layout | 126 |
| Tray toggle | 20 |
| Codex launch boundary | 72 |
| Codex startup option | 83 |
| Isolated startup process smoke | 16 |
| Portable installation | 81 |
| Installation process lifecycle | 47 |
| Subagent shutdown policy | 210 |
| PowerShell bridge | 143 |
| Node MCP | 8 |
| Setup worker and native-operation result handling | 24 |
| Optional plugin dependencies, installation and recovery | 102 |
| Extracted-archive native wrappers | 18 |
| Total | 1322 |

The policy tests keep identified subagents and internal reviews visible while excluding them from shutdown blocking. They cover active and stale turns, incomplete or malformed history, read errors, and the transition after a main task completes. Main-task and unidentified-source problems, plus global discovery errors, retain fail-closed behavior. Subagent-only activity does not satisfy the first-main-task observation requirement, restart a countdown or cancel an existing countdown. Task-manager and status checks verify that labels, counts and serialized blocking flags agree.

The bridge suite initially failed because its Windows PowerShell 5.1 child inherited a PowerShell 7 module path, making `Get-FileHash` unavailable. All 143 bridge checks passed after restricting the test process's `PSModulePath` to the system Windows PowerShell 5.1 modules. This was a test-environment correction; no production-code change was made for that failure.

The locally installed guard was refreshed while unarmed through the native installer with `-NoShortcuts`. The configuration and both startup-preference files retained identical byte hashes, and the installed core module and main script matched the source hashes. A fresh schema-8 runtime snapshot confirmed that main tasks still block and observed child tasks report blocksShutdown=false with non-blocking labels, including child-file diagnostics. Initial bounded history replay was still in progress during that snapshot; unidentified records remained conservative blockers.

The Windows ZIP was extracted into an independent workspace. Its setup suites passed again, and its native public wrappers completed 18 clean-install, configuration-preserving upgrade, read-only inspection and uninstall checks with -NoStart -NoShortcuts. All 30 packaged PowerShell files parsed on Windows PowerShell 5.1. The build verifies archive CRCs and every archived file hash. The skill frontmatter and UTF-8-without-BOM checks passed.

No real PC shutdown or reboot, Codex desktop restart, or acceptance test on another computer was performed.

## Previous release: 1.1.1

Validated on Windows with Windows PowerShell 5.1, Node.js 24.15.0 and the locally installed Codex CLI on 2026-10-21.

| Focused check | Passed |
| --- | ---: |
| Setup worker and native-operation result handling | 24 |
| Optional plugin dependencies, installation and recovery | 102 |
| GUI event flows | 28 |
| CMD launchers and exit codes | 4 |
| Real isolated desktop/startup shortcut creation and removal | 7 |
| MCP protocol and version regression | 8 |
| Extracted-archive native wrappers | 18 |
| Total | 191 |

The setup worker and GUI checks used complete inert package fixtures. They covered success, an armed-native refusal, partial chat-plugin failure, special-character paths, exit-code propagation, and blocking window closure until the worker result was processed. Native installation and actual shutdown entry points in these fixtures were never executed. Both install and uninstall window previews were inspected for clipped text.

Optional plugin tests covered Node 18+ and Git detection, bundled desktop CLI discovery, refreshed child-only PATH, npm CMD shims, a disabled existing plugin, unrelated or ambiguous marketplace ownership, fixed-tag upgrades, rollback failure, invalid CLI results, and timeouts. A timed-out operation reports an uncertain outcome and performs no competing rollback.

Separate real CLI tests used an independent Codex home, local Git repositories and a per-process Git URL rewrite, with no real user configuration or MCP execution. They verified upgrading 1.1.0 to 1.1.1, an idempotent second installation, and restoration of the old tag/version after a missing-tag failure. An unrelated marketplace and plugin were preserved.

The shortcut check used the real native installer with `-NoStart` and explicit independent program, registration, state, Startup and Desktop directories. It created and removed only fixture shortcuts; neither shortcut armed automatic shutdown. The user's actual Desktop and Startup folders were untouched.

The built Windows ZIP was extracted and its bundled setup suites rerun. The public native wrappers also completed an isolated clean install, byte-preserving upgrade, read-only bridge inspection and uninstall. All 29 packaged PowerShell scripts/modules parsed on Windows PowerShell 5.1. The archives are reread for CRC and per-file hash verification before upload.

The native monitor and shutdown logic are unchanged from 1.1.0. The previous 932-check record below is historical and was not rerun in full for this installer update. No real PC shutdown, reboot, live guard update or acceptance test on another computer was performed.

## Previous release: 1.1.0

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
