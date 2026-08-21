# Matrise - Plain English
#
# Everything Matrise says in normal words. One place, so it can be improved or
# translated without touching any logic.
#
# Each command gets two lines:
#   Plain - what the thing actually does, explained without jargon
#   When  - why you would reach for it
#
# The safety footer (safe / changes your PC / needs Administrator) is generated
# from the catalog entry itself, so it can never drift out of sync.

function Format-MatriseWrap {
    param([string]$Text, [int]$Width = 64)
    $out = New-Object System.Collections.ArrayList
    foreach ($para in ($Text -split "`r?`n")) {
        $line = ''
        foreach ($w in ($para -split '\s+' | Where-Object { $_ -ne '' })) {
            if ($line.Length -eq 0)                          { $line = $w }
            elseif (($line.Length + 1 + $w.Length) -le $Width) { $line += ' ' + $w }
            else { [void]$out.Add($line); $line = $w }
        }
        [void]$out.Add($line)
    }
    $out -join "`r`n"
}

$script:MatriseExplain = $null

function Get-MatriseExplainTable {
    if ($script:MatriseExplain) { return $script:MatriseExplain }

    $t = @{}
    $e = { param($id, $plain, $when) $t[$id] = @{ Plain = $plain; When = $when } }

    # ================================================================
    # GROUPS AND SECTIONS
    # ================================================================
    & $e 'group.Network' `
        'Everything about how this PC talks to other computers, your router, and the wider internet.' `
        'Open this when the internet is broken, slow, or behaving strangely.'

    & $e 'group.Computer' `
        'Everything about the machine itself: what is running, what starts up on its own, and how healthy the hardware is.' `
        'Open this when the PC is slow, crashing, full, or acting up.'

    & $e 'group.Security' `
        'The hunting tools. These go looking for things that are hiding.' `
        'Open this when you think something is wrong but you do not know what.'

    & $e 'section.Diagnose' `
        'These only look. Not one of them changes anything on your PC, so you can run any of them at any time without worrying.' `
        'Click the section heading and press Run to do all of the safe ones back to back.'

    & $e 'section.Hunt' `
        'Deeper searches aimed at finding something deliberately hiding. Still read-only, still safe.' `
        'FULL SWEEP at the top does all of it in one go. Start there.'

    & $e 'section.Fix' `
        'These change your PC. Every single one shows you the exact command first and asks you to confirm before anything happens.' `
        'Run "Create a restore point FIRST" before anything else here.'

    # ================================================================
    # NETWORK - DIAGNOSE
    # ================================================================
    & $e 'net.ipconfig' `
        'Every device on a network gets an address, like a house number, plus the phone book it uses to turn website names into numbers. This prints all of that for every network card you have.' `
        'Start here when "the internet is not working". If there is no address at all, the problem is your cable or Wi-Fi, not the website.'

    & $e 'net.connections' `
        'Right now your PC is holding open conversations with other computers. This lists every one of them and, crucially, names the program doing the talking.' `
        'When you want to know what is phoning home. A program you do not recognise talking to the internet is the thing to look at.'

    & $e 'net.netstat' `
        'The same list as the one above, but printed by the old built-in Windows tool. Slower, and this is exactly what you would see if you typed it into a black command window yourself.' `
        'When you want the raw, unedited output to paste somewhere or compare against a guide you are following.'

    & $e 'net.listeners' `
        'A listening port is like an unlocked door with someone sitting behind it waiting for visitors. This lists every door your PC is currently holding open.' `
        'When you want to know what other machines could connect to. Doors opened to 0.0.0.0 are open to your whole network, not just to you.'

    & $e 'net.arp' `
        'On your local network every device has a name tag (its address) and a permanent serial number burned into the hardware. This shows which serial number is claiming which name tag.' `
        'If two different name tags share one serial number, something may be pretending to be your router so it can read everything you send.'

    & $e 'net.route' `
        'A map telling your PC which way to send data. Normally anything that is not local goes to your router and out to the internet.' `
        'When traffic is going somewhere strange, or when some things work and others do not.'

    & $e 'net.dnscache' `
        'Your PC remembers the website names it recently looked up, like the recently-dialled list on a phone. This prints that list.' `
        'To see which sites this machine has been contacting, including ones no human ever typed in.'

    & $e 'net.hosts' `
        'A small text file that can overrule the internet phone book. Whatever is written in here wins, even if the real internet says something different.' `
        'Malware and pirated software write here to block antivirus updates or send you to fake sites. Anything beyond "localhost" deserves a look.'

    & $e 'net.proxy' `
        'A proxy is a middleman that all your web traffic passes through. Whoever runs it can read and change everything you see.' `
        'If a proxy is set here and your workplace did not set it, someone has put themselves between you and the internet.'

    & $e 'net.firewall' `
        'The firewall is the doorman for your PC, deciding who is even allowed to knock. Windows keeps three separate settings: one for home, one for work, one for public places.' `
        'Any of the three saying OFF means that doorman has gone home.'

    & $e 'net.fwrules' `
        'Rules that say "let this specific thing in from outside". Each one is a hole deliberately punched in the doorman policy.' `
        'Malware adds a rule to keep its own door propped open. Look for names you do not recognise.'

    & $e 'net.wifi' `
        'Every Wi-Fi network this PC has ever joined and saved, plus how good the connection you are on right now actually is.' `
        'For Wi-Fi that is slow or keeps dropping, and to spot saved networks you would rather forget.'

    & $e 'net.shares' `
        'Folders on this PC that other computers on your network are allowed to open, plus who is connected to them at this moment.' `
        'When you want to know what you are sharing without having meant to.'

    & $e 'net.speed' `
        'Three quick tests in a row: can you reach your router, can you reach the wider internet, and can you turn website names into numbers.' `
        'The fastest way to find out which of those three links in the chain is the broken one.'

    & $e 'net.trace' `
        'Follows a message hop by hop as it leaves your house and travels across the internet, listing every relay it passes through.' `
        'When the connection works but is slow, this shows you roughly where it slows down.'

    & $e 'net.pinghost' `
        'You type in a website or an address, and this checks whether it answers, then traces the route your data takes to get there.' `
        'When one particular site or server will not load but everything else is fine.'

    & $e 'net.dnslookup' `
        'Asks two different phone books for the same website number: yours, and a well-known public one. They should give the same answer.' `
        'If they disagree, your phone book is lying to you and quietly sending you somewhere else.'

    & $e 'net.portcheck' `
        'Knocks on one specific door on one specific machine and reports whether anybody answered.' `
        'When a game, server, or app cannot connect and you want to know whether the door is even open.'

    # ================================================================
    # NETWORK - FIX
    # ================================================================
    & $e 'netfix.flushdns' `
        'Throws away the remembered list of website addresses so your PC has to ask for fresh ones next time.' `
        'The first thing to try when one website will not load but others do. Harmless, instant, and fixes it surprisingly often.'

    & $e 'netfix.renew' `
        'Hands your network address back to the router and asks for a new one, like returning a cloakroom ticket and taking a fresh one.' `
        'When you have a bad address, or no address at all. You will be offline for a few seconds.'

    & $e 'netfix.winsock' `
        'All your internet traffic passes through a stack of layers inside Windows. Some adware wedges itself into that stack. This tears the stack down and rebuilds it clean.' `
        'When ads appear everywhere, or nothing connects properly. You must restart the PC afterwards for it to take effect.'

    & $e 'netfix.ipreset' `
        'The heavier version of the one above: rebuilds the entire networking machinery from scratch.' `
        'Last resort when nothing else brings the internet back. Needs a restart.'

    & $e 'netfix.proxy' `
        'Removes the middleman. Switches the proxy off and deletes any automatic-configuration address pointing at one.' `
        'Run this straight after the proxy check finds something you did not put there yourself.'

    & $e 'netfix.hosts' `
        'Copies the current override file to a backup sitting right next to it, then puts back the plain empty one Windows ships with.' `
        'When the HOSTS check shows entries you did not add. Your old file is kept, so nothing is lost if you were wrong.'

    & $e 'netfix.firewallon' `
        'Puts the doorman back on duty for all three settings, then shows you the result so you can see it worked.' `
        'Whenever the firewall check comes back saying OFF.'

    & $e 'netfix.adapters' `
        'Switches your network cards off and straight back on again, the software version of unplugging the cable and plugging it back in.' `
        'When Wi-Fi or Ethernet is being stubborn. You will drop offline for a moment while it happens.'

    # ================================================================
    # COMPUTER - DIAGNOSE
    # ================================================================
    & $e 'pc.sysinfo' `
        'The birth certificate of your PC: which Windows, how old, how much memory, what motherboard, and how long since the last restart.' `
        'Worth grabbing first whenever you are about to ask anybody for help, because it is the first thing they will ask for.'

    & $e 'pc.processes' `
        'Everything running right now, and more importantly the exact file on disk that each one was launched from.' `
        'When something is chewing up your PC and you want to know what it is. Where the file lives matters far more than what it is called.'

    & $e 'pc.unsigned' `
        'Real software comes with a signature, like a wax seal, proving who made it and that nobody has altered it since. This lists running programs with no seal, or a broken one.' `
        'A broken seal is the serious one: the file was changed after it was made. No seal at all is normal for small free tools, so judge it by where the file lives.'

    & $e 'pc.autoruns' `
        'Everything that starts itself when you switch the PC on or log in, gathered from all the different places Windows lets things hide.' `
        'For a slow startup, and because anything nasty wants to be on this list so that it comes back after you restart.'

    & $e 'pc.tasks' `
        'Windows can run things on a timer, like an alarm clock. This lists the alarms that did not come with Windows, and exactly what each one launches.' `
        'Another favourite hiding place. Read the command each task runs, not just the friendly name someone gave it.'

    & $e 'pc.services' `
        'Background helpers that run whether or not anybody is logged in, along with the exact file each one runs.' `
        'Anything running from your own folders instead of the Windows folders is worth asking questions about.'

    & $e 'pc.defender' `
        'Is your built-in antivirus actually switched on, is it up to date, and has anything told it to ignore certain folders?' `
        'An "ignore this folder" entry you did not add is a big deal, because that is precisely where something would hide.'

    & $e 'pc.accounts' `
        'Who can log into this PC, which of them has full control, and whether remote desktop is switched on.' `
        'A name you do not recognise sitting in the Administrators group means somebody else has a key to your house.'

    & $e 'pc.logons' `
        'A record of who signed in successfully and who tried and failed.' `
        'A few failures is you mistyping your password. A hundred in a row is somebody trying to guess it.'

    & $e 'pc.errors' `
        'Windows writes down every serious problem it runs into. This pulls out the last week of them and counts which ones keep repeating.' `
        'For random freezing, restarting, or crashing. The repeat offenders at the top are the ones worth chasing.'

    & $e 'pc.disk' `
        'Asks each drive how it is feeling and how much room is left. Drives can usually tell when they are wearing out and will say so.' `
        'Run this early. A dying drive causes almost every other strange symptom on this whole list.'

    & $e 'pc.bigfiles' `
        'Measures every pile of junk that Matrise is able to clear away, and finds your 25 largest files.' `
        'Run it before cleaning, so you can see what you are actually going to get back.'

    & $e 'pc.installed' `
        'Everything installed on the machine, newest first.' `
        'If the trouble started on a particular day, look at what arrived on that day.'

    & $e 'pc.drivers' `
        'Drivers are the translators between Windows and your hardware. This finds unsigned ones and any device that is complaining.' `
        'For hardware that has stopped working, or a device showing a warning triangle in Device Manager.'

    & $e 'pc.integrity' `
        'Compares the files that make up Windows itself against a list of what they are supposed to be. It only checks, it does not touch anything.' `
        'When Windows misbehaves in ways that make no sense. Completely safe, but slow.'

    & $e 'pc.bitlocker' `
        'Is your drive scrambled so a thief who takes it cannot read it, and are the security chips on your motherboard switched on?' `
        'To find out whether your data would actually be protected if the laptop went missing.'

    & $e 'pc.procinfo' `
        'You type a program name or number, and this tells you the whole story about it: where it lives, what started it, whether it is signed, and who it is talking to.' `
        'When you have spotted something suspicious in another check and want everything known about it in one place.'

    & $e 'pc.findfile' `
        'Searches your folders for a file name or a pattern like *.exe, and does it far faster than the search box in Explorer.' `
        'When you know a file name and need to find out where on earth it landed.'

    # ================================================================
    # COMPUTER - FIX
    # ================================================================
    & $e 'pcfix.restorepoint' `
        'Takes a snapshot of your Windows settings so you can roll everything back if a repair goes wrong. This is your undo button.' `
        'Run this FIRST, before anything else in any of the Fix sections. It costs a minute and can save your afternoon.'

    & $e 'pcfix.temp' `
        'Programs constantly leave scratch files behind and almost never clean up after themselves. This empties those scratch bins.' `
        'When you are running short on space. Files currently in use are skipped safely, and it tells you exactly how much it freed and from where.'

    & $e 'pcfix.recyclebin' `
        'Permanently deletes everything currently sitting in the Recycle Bin, on every drive.' `
        'When you are certain you do not want any of it back. There is no undo after this one.'

    & $e 'pcfix.wucache' `
        'Windows downloads updates into a holding area first. If one arrives damaged, updates get stuck there forever. This throws the holding area away so everything downloads fresh.' `
        'When Windows Update fails, or hangs at the same percentage every single time.'

    & $e 'pcfix.sfc' `
        'Checks the files that make up Windows and replaces any damaged ones with clean copies from a spare-parts store kept on your disk.' `
        'When Windows itself is misbehaving. Takes somewhere between five and twenty minutes.'

    & $e 'pcfix.dism' `
        'Repairs the spare-parts store that the previous fix takes its clean copies from, fetching fresh parts from Microsoft.' `
        'Run this if the previous fix reports that it could not repair everything, then run that one again afterwards.'

    & $e 'pcfix.chkdsk' `
        'Books a full inspection of the disk surface for the next time you restart. It cannot run now because Windows is busy using the drive.' `
        'When the disk health check comes back looking bad. The inspection itself can take hours, so start it when you do not need the PC.'

    & $e 'pcfix.defenderscan' `
        'Downloads the newest list of known threats, then searches all the usual hiding places for them.' `
        'Any time you suspect something. Takes a few minutes, and the results all appear at once when it finishes.'

    & $e 'pcfix.defenderon' `
        'Switches your antivirus protection back on.' `
        'When the Defender check shows it is off. It may refuse, which is good news: it means Tamper Protection is guarding the setting and doing its job.'

    & $e 'pcfix.optimize' `
        'Tidies up how files are arranged on each drive. Windows automatically picks the right method for modern solid-state drives versus older spinning ones.' `
        'Occasional housekeeping. Safe, but it can take a long time on a big drive.'

    # ================================================================
    # SECURITY - HUNT
    # ================================================================
    & $e 'sec.sweep' `
        'The big one. Runs every security check in a single pass and pours all of it onto the board, so the Analyze button has the whole picture to work from.' `
        'Start here if you think something is wrong but have no idea where to look. Then press Analyze.'

    & $e 'sec.suspath' `
        'Properly installed software lives in the Program Files folder. This finds programs running from the scratch, downloads and personal folders instead.' `
        'Because those are the folders things land in when they arrive without ever asking your permission.'

    & $e 'sec.lolbins' `
        'Windows ships with tools that can download and run other things. Attackers use those instead of bringing their own, so everything looks trustworthy. This hunts for that pattern.' `
        'One of the most reliable ways to catch something that is being clever about hiding.'

    & $e 'sec.browser' `
        'Lists every add-on installed in your browsers, and checks whether any browser shortcut has had a web address secretly stuck onto the end of it.' `
        'When your browser opens the wrong search engine, or shows ads where it never used to.'

    & $e 'sec.newfiles' `
        'Finds programs and scripts that appeared in your folders within the last seven days.' `
        'When you know roughly when things went wrong. For each one, ask yourself where it came from.'

    & $e 'sec.hashfile' `
        'Takes a fingerprint of one file. Every file has a unique fingerprint, and you can look that fingerprint up online to find out whether the world already knows it is dangerous. It also shows which website the file was downloaded from.' `
        'When you have found a file you do not trust and want to identify it without opening it.'

    # ================================================================
    # SECURITY - FIX
    # ================================================================
    & $e 'sec.quarantine' `
        'Stops a running program and moves its file into a locked box inside the Matrise folder, writing down where it came from.' `
        'When you have confirmed something is bad. It is reversible: the file is moved, not destroyed, so you can put it back if you got it wrong.'

    & $e 'sec.harden' `
        'Closes the doors that are most commonly left open: firewall on, remote desktop off, remote registry off, ancient file sharing off, antivirus on.' `
        'A sensible tidy-up for a home PC. Do not run it on a work machine without asking IT first, because you may switch off something they rely on.'

    # ================================================================
    # THE APP ITSELF
    # ================================================================
    & $e 'ui.run' `
        'Runs the command you picked on the left. Whatever it prints appears on the big board in the middle and stays there, so you can search it later.' `
        'Tip: click a section heading instead of a single command, and this runs every safe command in that section one after another.'

    & $e 'ui.opencmd' `
        'The same command, but in a real black command window that opens on top and stays open when it finishes.' `
        'Use it when you want to watch something happen live, or copy text straight out of the terminal itself.'

    & $e 'ui.stop' `
        'Stops whatever is running right now, including anything else it started along the way.' `
        'Safe to press at any time. A half-finished command just leaves half its output on the board.'

    & $e 'ui.copy' `
        'Copies everything on the board to your clipboard, ready to paste into a message, an email, or a chat with whoever is helping you.' `
        'If you have highlighted some text first, it copies only that instead of the whole thing.'

    & $e 'ui.paste' `
        'Takes whatever is on your clipboard right now and drops it onto the board.' `
        'Use it for output you captured somewhere else, even on a different computer, so you can search and analyze it here.'

    & $e 'ui.load' `
        'Opens a saved log or report file and puts its contents onto the board.' `
        'Try it on tests\sample-compromised.txt to see what a badly infected machine looks like, without needing anything to be wrong with yours.'

    & $e 'ui.save' `
        'Writes the findings and everything on the board out to a text file you can keep, print, or send to somebody.' `
        'Do this before pressing Clear if you want to keep a record.'

    & $e 'ui.clear' `
        'Empties the board completely.' `
        'It will ask first. Save a report beforehand if you want to keep what is there.'

    & $e 'ui.analyze' `
        'Reads everything on the board and points out anything that looks suspicious. It works entirely offline and takes about a second.' `
        'Each thing it finds is explained in normal words in the panel at the bottom right. Double-click a finding to jump straight to that line.'

    & $e 'ui.agent' `
        'Sends the whole board to Claude for a second opinion, along with what the built-in checks already spotted.' `
        'If the Claude command line tool is installed the answer comes straight back onto the board. If not, Matrise puts the text on your clipboard so you can paste it into Claude yourself.'

    & $e 'ui.chunk' `
        'The text was too long to paste in one go, so it was split into parts. This copies the next part.' `
        'Paste each part into the same chat. Each one is labelled so Claude knows to wait for the rest before answering.'

    & $e 'ui.autocopy' `
        'When ticked, the board is copied to your clipboard automatically every time a command finishes.' `
        'Handy when you are collecting output to paste somewhere else and do not want to keep pressing Copy.'

    & $e 'ui.autoscan' `
        'When ticked, the suspicious-things check runs by itself after every single command.' `
        'Leave this on. It costs about a second and means you never forget to look.'

    & $e 'ui.find' `
        'Type here to search everything on the board. Every match lights up in yellow at once.' `
        'Enter jumps to the next match, Shift+Enter to the previous. Ctrl+F from anywhere in the window brings you back here.'

    & $e 'ui.filter' `
        'Hides every line that does not contain what you typed, keeping the original line numbers down the left so you never lose your place.' `
        'This is how you turn a four thousand line wall of text into the six lines you actually care about. Untick it to get everything back.'

    & $e 'ui.wrap' `
        'Makes very long lines fold onto the next line instead of running off the right-hand edge.' `
        'Leave it off for command output, where columns need to stay lined up to be readable.'

    & $e 'ui.cmdbox' `
        'The exact command Matrise is going to hand to Windows, shown before anything runs. Nothing ever happens behind your back.' `
        'You can select the text and press Ctrl+C to copy it, if you want to run it yourself or look it up.'

    & $e 'ui.tree' `
        'Every check and repair Matrise can do, sorted into groups. The colour tells you the risk before you click anything.' `
        'White only looks and changes nothing. Amber changes your PC and asks first. Red is slow or needs a restart. A star means it needs Administrator to give you the full answer.'

    & $e 'ui.board' `
        'Everything you run lands here and stays here, one command after another, building a single record of the whole session.' `
        'Press Ctrl+F to search it. You can also select any part of it and copy it out.'

    & $e 'ui.findings' `
        'Anything the check thought was worth a second look, most serious first.' `
        'Click a row to read why it matters in the panel to the right. Double-click it to jump to that exact line up on the board.'

    & $e 'ui.why' `
        'A plain-English explanation of whichever finding you clicked: what was seen, why it matters, and how to tell a real problem from a false alarm.' `
        'Read this before acting on anything. Some findings are perfectly normal on some machines.'

    & $e 'ui.admin' `
        'Administrator is the difference between being handed the keys and being told to wait outside. Plenty of these checks simply cannot see the whole machine without it.' `
        'If this says "not elevated", close Matrise and start it again with Matrise.bat, which asks Windows for permission first.'

    & $e 'ui.target' `
        'Which machine the commands run on. Leave it empty for this PC, or type the hostname of the machine you are supporting.' `
        'Use the hostname, not the IP, wherever you can. A hostname can authenticate properly through the domain; a bare IP cannot, and needs extra setup.'

    & $e 'ui.thispc' `
        'Points everything back at the computer you are sitting in front of.' `
        'Use it when you have finished with someone else machine, so you do not accidentally run a repair on the wrong one.'

    & $e 'ui.testconn' `
        'Walks the chain a remote connection depends on, one link at a time: does the name resolve, is the remote-management port open, and do your credentials get accepted.' `
        'Run it before anything else when connecting to a machine. It tells you which link is broken instead of just saying "failed".'

    & $e 'ui.runas' `
        'Connect to the machine as a different account. Windows asks for the password itself; Matrise never sees or stores it.' `
        'Only needed if your everyday account does not have support rights on endpoints, or when connecting by IP address.'

    & $e 'ui.requests' `
        'The queue of requests to unlock commands that policy holds back, and the conversation attached to each one.' `
        'Raise a request from the message you get when something is blocked. Security answers here, and the reasoning stays attached to the decision.'

    & $e 'ui.policy' `
        'The rule set your Security team publishes, saying which commands IT Support may run freely, which need approval first, and which are off limits.' `
        'Commands are marked in the list on the left. If nothing is marked, no policy file was found and everything is available.'

    & $e 'ui.homesetup' `
        'Everything needed to let this PC help another one in the same house. Home PCs are not in a work network, so the two have to be introduced to each other once.' `
        'Start here before trying to connect to a family member computer. It gives them a script to run and you a button to trust their machine.'

    & $e 'ui.sendmsg' `
        'Puts a message box on the other person screen, so you can tell them what you are doing or ask them to try something.' `
        'It works whether or not they have Matrise open. Your name and this computer name are always shown on it - there is no anonymous option.'

    & $e 'ui.findbar' `
        'The search bar for the board.' `
        'Ctrl+F brings you here from anywhere in the window.'

    $script:MatriseExplain = $t
    $t
}

# The tooltip text for one catalog entry: plain words, when to use it, and a
# safety line built from the entry itself so it can never say the wrong thing.
function Format-MatriseExplain {
    param($Entry, [int]$Width = 64)

    $tab = Get-MatriseExplainTable
    $x   = $tab[$Entry.Id]

    $parts = New-Object System.Collections.ArrayList

    if ($x) {
        [void]$parts.Add('WHAT IT DOES')
        [void]$parts.Add((Format-MatriseWrap -Text $x.Plain -Width $Width))
        [void]$parts.Add('')
        [void]$parts.Add('WHEN TO USE IT')
        [void]$parts.Add((Format-MatriseWrap -Text $x.When -Width $Width))
    } else {
        [void]$parts.Add((Format-MatriseWrap -Text $Entry.Desc -Width $Width))
    }

    [void]$parts.Add('')
    switch ($Entry.Impact) {
        'fix' {
            [void]$parts.Add((Format-MatriseWrap -Width $Width -Text `
                'CAREFUL - this changes your PC. Matrise will show you the exact command and ask you to confirm before anything happens.'))
        }
        'heavy' {
            [void]$parts.Add((Format-MatriseWrap -Width $Width -Text `
                'CAREFUL - this changes your PC, takes a long time, and may need a restart. Matrise will ask you to confirm first.'))
        }
        default {
            [void]$parts.Add('SAFE - this only looks. It changes nothing.')
        }
    }

    if ($Entry.Admin) {
        [void]$parts.Add((Format-MatriseWrap -Width $Width -Text `
            'NEEDS ADMINISTRATOR to give you the full answer. Without it you will get a partial result or a permission error.'))
    }
    if ($Entry.Prompt) {
        [void]$parts.Add((Format-MatriseWrap -Width $Width -Text `
            ('ASKS YOU FIRST - it will ask for: ' + $Entry.Prompt)))
    }

    $parts -join "`r`n"
}

# Tooltip text for a group or section heading in the tree, and for the buttons
# and panels of the app itself.
function Get-MatriseTip {
    param([string]$Key, [int]$Width = 64)

    $x = (Get-MatriseExplainTable)[$Key]
    if (-not $x) { return '' }

    @(
        (Format-MatriseWrap -Text $x.Plain -Width $Width),
        '',
        (Format-MatriseWrap -Text $x.When -Width $Width)
    ) -join "`r`n"
}
