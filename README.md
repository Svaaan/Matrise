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

All of that wording lives in one file, `lib\Explain.ps1`, separate from any
logic — so it can be reworded, or translated, without touching the tool.

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
checks the output landed. Nineteen checks, PASS/FAIL each — including one that
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
