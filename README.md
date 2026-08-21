# Matrise

A Windows security and system helper. It runs the diagnostic and repair commands
you would otherwise have to remember, keeps every result on one searchable board,
and flags the things worth a second look.

Built on Windows PowerShell 5.1 + WinForms. No install, no dependencies, no
network calls unless you explicitly ask for the Claude hand-off.

---

## Running it

```bash
Matrise.bat
```

That prompts for Administrator, which you want: many checks return blank or
partial data without it, and nothing in the **Fix** sections works at all.

To skip the UAC prompt, use `Matrise-no-admin.bat`. Commands marked `*` in the
tree are the ones that need elevation.

There is also a headless mode:

```bash
powershell -ExecutionPolicy Bypass -File Matrise.ps1 -Analyze reports\matrise-20260821.txt
```

Runs the rule engine over a saved file, prints the findings, and exits `2` if
anything Critical or High was found — so you can use it in a scheduled task.
`-List` prints the whole command catalog. `-SelfTest` drives the window through
a scripted pass and reports PASS/FAIL for each part.

---

## How it works

### 1. Pick a command

The tree on the left holds **62 commands** in three groups:

| Group | Diagnose / Hunt | Fix |
|---|---|---|
| **Network** | IP config, connections with owning process, listening ports, ARP, routes, DNS cache, HOSTS, proxy, firewall rules, Wi-Fi, shares, latency, traceroute | flush DNS, renew DHCP, Winsock reset, TCP/IP reset, clear proxy hijack, restore HOSTS, firewall on, restart adapters |
| **Computer** | system summary, processes with full paths, unsigned binaries, autoruns, scheduled tasks, services, Defender status, accounts, logons, crashes, disk health, disk usage, installed programs, drivers, integrity, encryption | restore point, temp cleanup, recycle bin, Windows Update cache, SFC, DISM, chkdsk, Defender scan, re-enable Defender, TRIM/defrag |
| **Security** | **FULL SWEEP**, processes in Temp/AppData, living-off-the-land abuse, browser extensions and hijacked shortcuts, new executables, file fingerprinting | kill + quarantine a process, baseline hardening |

Colour tells you the risk before you click:

- **white** — read-only, safe any time
- **amber** — changes your system, asks for confirmation first
- **red** — slow, or needs a reboot
- **`*`** — returns partial data unless elevated

### Hover over anything

Every command, every button, every checkbox and every panel explains itself in
plain English when you rest the pointer on it. No jargon, no assumed knowledge:

```
Repair system files (SFC)

WHAT IT DOES
Checks the files that make up Windows and replaces any damaged
ones with clean copies from a spare-parts store kept on your
disk.

WHEN TO USE IT
When Windows itself is misbehaving. Takes somewhere between five
and twenty minutes.

CAREFUL - this changes your PC, takes a long time, and may need
a restart. Matrise will ask you to confirm first.
NEEDS ADMINISTRATOR to give you the full answer. Without it you
will get a partial result or a permission error.
```

Group and section headings explain what the whole category is for. Findings
explain what was seen and why it matters. The safety line at the bottom is
generated from the command itself, so it can never tell you something is safe
when it is not.

The panel appears anchored directly beneath the thing it explains, stays put
while you read it, and closes the moment the pointer leaves. It never takes
focus and it is click-through, so it cannot get in the way of what is underneath.

It is not a Windows tooltip. The built-in control ignores custom drawing in
several situations, so it kept reverting to the system light theme, and it
insists on its own show / fade / reposition behaviour, which is why it used to
drift around instead of sitting on its subject. `lib\Hover.ps1` is a small
purpose-built window instead.

The wording lives in one file, `lib\Explain.ps1`, separate from any logic — so
it can be reworded, or translated, without touching the tool.

### Resizing

The window opens at about 92% of your desktop. The three dividers — tree /
board, board / findings, findings / why — are draggable, and where you put them
is remembered along with the window size, so the shape you set up once is the
shape you get next time. It is kept in `matrise-layout.json` next to the app;
delete that file to go back to the defaults.

Two things size themselves automatically:

- **The command box** grows to fit whatever it has to show. A 634-character
  command like the proxy check is fully readable rather than hidden behind a
  scrollbar, up to a third of the window height.
- **The findings columns** share the panel width, so widening that panel widens
  the finding and evidence text instead of leaving dead space.

### 2. See exactly what will run

The box under the command name shows the literal command line Matrise hands to
the OS, before it runs. Nothing executes behind your back. Anything that changes
your system shows that same command again in a confirmation dialog.

**Run** executes it in the background and streams output onto the board.
**Open in CMD** runs it in a real console window that stays open, so you can
watch it live and copy from the terminal. Those console scripts are written to
`reports\_console\` so you can inspect precisely what was executed.

Select a *section* header instead of a command and press Run to queue every
read-only command in it back to back.

### 3. The board

All output appends to one board and stays there. Run ten commands and you have a
single searchable record of the whole session.

- **Ctrl+F** jumps to the find box. Every match is highlighted; Enter / F3 walks
  through them, Shift for backwards.
- **Filter to matching lines only** strips a huge dump down to just the lines
  containing your term, keeping the real line numbers in front. This is how you
  make a 4000-line `netstat -abno` readable.
- **Copy board** puts everything (or your selection) on the clipboard.
- **Paste in** appends whatever is on your clipboard — so output you captured
  somewhere else, from another machine or a `| clip` in a terminal, gets the same
  search and analysis treatment.
- **Load file** does the same from a saved log.

### 4. Analyze

Presses the local rule engine against everything on the board. Runs offline, in
about a second, and needs no network. It looks for:

- encoded / hidden PowerShell, `IEX` downloads, certutil and mshta abuse
- executables running from Temp, AppData, Downloads; double extensions
- persistence: Run keys, Winlogon tampering, WMI event consumers, odd service paths
- Defender disabled or with exclusion paths added, firewall profiles off
- RDP/VNC/backdoor ports listening, wildcard bindings, HOSTS and proxy hijacks
- ARP tables where one MAC answers for several IPs
- unsigned or hash-mismatched binaries, unhealthy disks, repeated failed logons

Findings land in the list at the bottom, ranked by severity. Each one comes with
a plain-language explanation of **why it matters and what to do**, because a
finding you cannot act on is just noise. Double-click a row to jump to that line
on the board.

Auto-analyze is on by default, so the engine runs after every command.

### 5. Ask Claude

Sends the whole board for a second opinion, with the local findings attached as
hints rather than conclusions.

- If the **Claude Code CLI** is installed, Matrise pipes the prompt to it and
  streams the answer straight back onto the board.
- If not, it builds the prompt, splits it into paste-sized parts, and puts part 1
  on your clipboard. Each part is labelled so Claude waits for the rest before
  answering. **Copy next part** cycles through them. The full prompt is also
  saved to `reports\agent-prompt-*.md`.

Column padding is squeezed out first, which roughly halves the payload without
losing meaning.

---

## Running it in a managed estate

Matrise was written to work inside AD-managed environments where application
control blocks `.exe`, software arrives through Software Center, and Security
sets limits on what IT Support may run.

### Supporting another machine

Type a hostname in the **Machine** box and everything runs there instead of
here, over PowerShell Remoting (WinRM). No agent, no `.exe`, no listener of our
own, nothing needing an application-control exception.

**Test connection** walks the chain one link at a time — DNS, the WinRM port,
then authentication — and stops at the first thing that is broken with the fix
attached. "Connection failed" costs an afternoon; "nothing is listening on TCP
5985, WinRM is normally enabled by GPO so this machine is the exception" does
not.

Use the hostname, not the IP. A bare IP cannot use Kerberos, so WinRM falls
back to NTLM and needs an explicit credential, HTTPS, or a TrustedHosts entry.
Matrise says so before you hit it rather than after. **Run as...** uses the
Windows credential prompt; the password goes into a `PSCredential` and is never
written to a file, a command line, or a process listing.

### Policy

Security publishes a `policy.json` (see `policy.example.json`). Point
`MATRISE_POLICY` at it on a read-only share, or drop it next to the app. Rules
match on command id, a regex over the command line, group/section, or impact,
and resolve most-specific-first. Each is `allow`, `requireApproval`, or `block`,
and carries a reason the operator actually reads.

Blocked and approval-only commands are marked in the tree. Every attempt —
allowed or refused — is written to the audit log *before* it runs, so an attempt
that hangs is still on the record.

> **A client-side block list is not a security boundary.** Matrise is
> PowerShell: anyone who can run it can read it, edit the policy, or skip
> Matrise and type the command into a console. This layer stops an honest
> operator from doing the wrong thing by accident and produces an audit trail.
> It must never be presented to a Security team as though it does more.
>
> The enforcement boundary is the endpoint. See JEA below.

### Requests and approvals

When policy holds a command back, the operator raises a request with a
justification and a time window. Security approves it for that window, or
declines, and the two of them talk it through on the request itself.

Two directories on a share, with different ACLs:

```
\\share\matrise\requests\   Support: create + comment    Security: full
\\share\matrise\grants\     Support: READ ONLY           Security: full
```

**The ACL on the grants folder is the control.** An operator cannot write a
grant for themselves because the file system refuses, not because this script
declines. Real boundary, enforced by Windows, auditable through file system
auditing, needing no server and no open port. Grants are scoped to one command,
one operator, one machine, and one time window — all four are checked, and all
four are covered by tests.

Approve and Deny are shown to everyone; whether they work is decided by that
ACL, and when it says no the error explains that it is the share permissions
talking, not the app.

**On peer-to-peer chat** — it was asked for, and I would advise against it. A
direct socket between two workstations means a listener on an endpoint, a
firewall exception, another authentication scheme to get wrong, and a
conversation nobody can audit, for something Teams already does. What was
actually missing is chat *attached to the request*, so the reasoning lives next
to the decision permanently. That is the comment thread: one JSON file,
inheriting the share's ACLs and auditing.

### JEA — where the rules become real

```bash
powershell -File Matrise.ps1 -ExportJea .\out
```

Generates a constrained PowerShell Remoting endpoint from the *same* catalog and
policy, so the list the operator sees and the list the machine enforces are
built from one source and cannot drift:

- `SessionType = RestrictedRemoteServer`, `LanguageMode = NoLanguage` — there is
  no command line to type an unapproved command into, only the generated
  functions.
- `RunAsVirtualAccount` — commands run as a per-session temporary local admin,
  so **the operator's own account needs no admin rights on any endpoint.** That
  removes the standing privilege most endpoint-support models leak.
- Blocked commands are not merely hidden; they are absent from the endpoint.
- Prompted commands validate their input at the parameter, so nothing reaching
  a shell can carry `&`, `|`, `>` or `%`.
- The endpoint transcribes every session itself.

Two roles are produced: `MatriseSupport` (allow) and `MatriseSupportElevated`
(allow + requireApproval). Map the elevated role to a group with **time-boxed
membership** — AD PAM shadow groups, or Entra PIM. That, not the client, is what
makes an approval expire.

`README.txt` and `MatriseSupport.psrc` in the output are written as plain,
readable PowerShell data specifically so a human on the Security side can review
them before anything is deployed.

### Deployment

No compiled binary — `.ps1` and `.bat` only. For an estate enforcing
`AllSigned`, sign the scripts with your internal code-signing certificate before
packaging; unsigned files simply refuse to load and the failure reports itself
badly. `Install-MatriseJea.ps1` is written to be deployed as a Software Center /
Intune PowerShell script, running as SYSTEM with no interactive logon.

### Command line

```bash
powershell -File Matrise.ps1 -Requests
```

`-Target <host>` opens aimed at a machine · `-ExportJea <dir>` generates the
endpoint · `-Requests` lists the queue · `-Approve <id> -Minutes 60` and
`-Deny <id>` decide one, both writing to the audit log.

---

## Safety

- Read-only commands run without ceremony. Anything that changes the system shows
  you the exact command and requires confirmation.
- `Computer > Fix > Create a restore point FIRST` exists for a reason. Run it
  before the other fixes.
- **Restore HOSTS** backs the old file up to `hosts.matrise-backup` next to it.
- **Kill + quarantine** moves the binary into `Quarantine\` and logs the original
  path in `quarantine-log.txt`, so a mistake is reversible by hand.
- Stop kills the whole process tree, not just the process Matrise started.

Matrise never deletes anything without telling you which paths and how much it
freed.

---

## Verifying it works

```bash
powershell -ExecutionPolicy Bypass -File Matrise.ps1 -SelfTest
```

Builds the real window, loads a synthetic "infected machine" fixture, runs the
analyzer, exercises find/filter/jump, then runs a real command end to end and
checks the output landed. Thirty-two checks, PASS/FAIL each — including one that
fails if any command is missing its hover explanation.

`tests\sample-compromised.txt` is that fixture — fake output from a deliberately
compromised machine. Load it with **Load file** and press **Analyze** to see what
a bad result looks like without needing anything actually wrong with your PC. It
should produce 31 findings, 7 of them Critical.

---

## Adding your own command

Everything lives in one table. Open `lib\Catalog.ps1` and add an entry:

```powershell
& $add (New-MatriseEntry -Id 'net.mything' -Group 'Network' -Section 'Diagnose' `
    -Name 'What it is called in the tree' `
    -Desc 'One or two sentences on what this tells you and when to reach for it.' `
    -Shell 'cmd' -Command 'whatever /you /want')
```

- `Shell` — `cmd` streams live; `ps` runs the body as a PowerShell script
- `Impact` — `read` (default), `fix` (confirmation required), `heavy` (slow / reboot)
- `Admin` — `$true` marks it `*` and warns when not elevated
- `Prompt` — set it and the GUI asks for a value, substituted for `%INPUT%` in
  the command. Input is escaped for the target shell before it goes anywhere.

Then add its hover explanation in `lib\Explain.ps1`:

```powershell
& $e 'net.mything' `
    'What it does, explained the way you would explain it to someone who has never heard of any of this.' `
    'Why you would reach for it, and what a bad answer looks like.'
```

The safety line underneath is generated from the catalog entry, so you never
write it by hand and it can never contradict what the command actually does.
`Matrise.ps1 -SelfTest` fails if any command is missing its explanation.

Detection rules live the same way in `lib\Analyzer.ps1` via `New-MatriseRule`.
Give every rule a `Why`.

---

## Layout

```
Matrise.bat              launcher, elevates first
Matrise-no-admin.bat     launcher without UAC
Matrise.ps1              entry point; -Analyze / -List / -SelfTest
lib\Explain.ps1          every word Matrise says, in plain English
lib\Hover.ps1            the themed hover-explanation panel
lib\Target.ps1           remote targeting over WinRM, with a real preflight
lib\Policy.ps1           policy rules, grants and the audit log
lib\Requests.ps1         request store, approvals, comment thread
lib\GuiRequests.ps1      the request and approval windows
lib\Jea.ps1              generates the constrained endpoint from catalog+policy
policy.example.json      an example Security policy
audit\                   local audit log (jsonl, one line per attempt)
audit\ui-errors.log      full stack traces for anything that goes wrong in the window
lib\Catalog.ps1          the 62 commands
lib\Runner.ps1           background execution, live output, real-console mode
lib\Analyzer.ps1         offline detection rules
lib\Agent.ps1            Claude CLI + clipboard hand-off
lib\Gui.ps1              the window
tests\                   synthetic fixture for the analyzer
reports\                 saved reports, agent prompts, generated console scripts
matrise-layout.json      remembered window size and divider positions
Quarantine\              created on first use
```

---

## Known limits

- Matrise only sees what you actually run. No findings is not a clean bill of
  health; `Security > Hunt > FULL SWEEP` is the broadest single check.
- The rule engine is a regex matcher. It produces false positives — Chrome and
  Discord legitimately run from AppData, and a router with several interfaces can
  look like ARP spoofing. That is why every finding tells you how to confirm it.
- It is not an antivirus. It finds and explains; removing a real infection still
  means an offline scan from rescue media.
