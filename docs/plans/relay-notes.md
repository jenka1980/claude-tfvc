Git Bash /option: left alone
Embedded double quotes through powershell -File: survive on both interpreters (R3q PASS, Task 4)

Registration from console session: worked

## Verification 2026-10-11 (Task 12a)

Host: PowerShell 5.1.19041.6456, interpreters: powershell, pwsh, git bash: yes, csc: yes, ansi: windows-1255
Relay harness run 1: 121 checks, 0 failed, 0 skipped
Relay harness run 2: 121 checks, 0 failed, 0 skipped
Relay harness run 3: 121 checks, 0 failed, 0 skipped
Hook harness: 63 checks, 0 failed, 0 skipped
FAIL/SKIP/INFO rows: none
Stray processes: none (no powershell.exe processes listed); no *.req.json / *.run.json left in %TEMP%\claude\tfvc-tests\relay\relay

Register-TfRelay.ps1 -Status (exit 0):

    Session:    local (no SSH variables)
    Transport:  direct  (TFVC_TRANSPORT=auto from default)
    Task:       registered; task state Ready, last result 0x00000000; last run 10/11/2026 15:18:18
    Worker:     installed 0.3.0 (matches the plugin)
    Queue:      C:\Users\gabi\AppData\Local\claude-tfvc\relay\queue  (0 waiting, 0 running, 0 answered)
    Alive:      no worker running now (started on demand)
    Probe:      tf workspaces /noprompt via relay: exit 0 in 2.4 s

SSH password logon claim: not tested here (believed true: Windows OpenSSH password logons are network-cleartext logons with delegable credentials)
