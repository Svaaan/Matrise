# Matrise - Guest / Host rendezvous
#
# Replaces "run this script, copy this code, paste it back" with:
#
#   On the PC that needs help :  press HOST
#   On the PC that helps      :  press GUEST, pick them from the list
#   On the PC that needs help :  an approval box appears - press Approve
#
# Nothing is typed and nothing is pasted.
#
# ---------------------------------------------------------------------------
# THE PROBLEM THIS SOLVES
#
# Before the two machines trust each other there is no channel between them:
# WinRM will not talk without credentials, and the credentials are the thing we
# are trying to deliver. So we need one narrow channel that works with no trust
# at all, and that is a UDP datagram on the local network.
#
# UDP on a LAN is unauthenticated and anyone on the network can read it, so the
# protocol is built assuming exactly that:
#
#   * The beacon carries no secret. Only "a PC called X is offering to be
#     helped". Broadcasting that is no worse than a machine name in Explorer.
#
#   * The password is never sent in the clear. The guest generates a throwaway
#     RSA key, sends the public half, and the host encrypts the password to it.
#     Someone sniffing the network captures ciphertext they cannot open.
#
#   * A human on the host approves, and sees who is asking. Approval is not a
#     formality - without it nothing is ever sent.
#
#   * Both screens show the same six-digit number, derived from the guest's key
#     and a nonce. If someone else on the network raced in with their own
#     request, the numbers would not match. Read it aloud before approving.
#
# The keypair is thrown away after one exchange, so a captured session cannot
# be replayed or decrypted later.
# ---------------------------------------------------------------------------

$script:MxRvGuestPort = 51999   # guest listens here: beacons and replies
$script:MxRvHostPort  = 51998   # host listens here: connection requests

# ------------------------------------------------------------- crypto ------
function New-MatriseRvKeyPair {
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
    $rsa.PersistKeyInCsp = $false
    $p = $rsa.ExportParameters($false)
    [pscustomobject]@{
        Rsa       = $rsa
        Modulus   = [Convert]::ToBase64String($p.Modulus)
        Exponent  = [Convert]::ToBase64String($p.Exponent)
    }
}

function Protect-MatriseRvSecret {
    param([string]$Modulus, [string]$Exponent, [string]$Plain)
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
    try {
        $rsa.PersistKeyInCsp = $false
        $p = New-Object System.Security.Cryptography.RSAParameters
        $p.Modulus  = [Convert]::FromBase64String($Modulus)
        $p.Exponent = [Convert]::FromBase64String($Exponent)
        $rsa.ImportParameters($p)
        # OAEP rather than PKCS#1 v1.5: no reason to ship the padding oracle.
        [Convert]::ToBase64String($rsa.Encrypt([System.Text.Encoding]::UTF8.GetBytes($Plain), $true))
    }
    finally { $rsa.Dispose() }
}

function Unprotect-MatriseRvSecret {
    param($KeyPair, [string]$Cipher)
    [System.Text.Encoding]::UTF8.GetString($KeyPair.Rsa.Decrypt([Convert]::FromBase64String($Cipher), $true))
}

# The number both people read off their screens. Derived from the guest's key
# and its nonce, so it is different every time and cannot be predicted.
function Get-MatriseRvCode {
    param([string]$Modulus, [string]$Nonce)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$Modulus|$Nonce"))
        $n = ([uint32]$h[0] -shl 24) -bor ([uint32]$h[1] -shl 16) -bor ([uint32]$h[2] -shl 8) -bor [uint32]$h[3]
        '{0:D6}' -f ($n % 1000000)
    }
    finally { $sha.Dispose() }
}

# ------------------------------------------------------------- transport ---
function Send-MatriseRvDatagram {
    param([string]$Address, [int]$Port, $Payload, [switch]$Broadcast)
    $json  = ($Payload | ConvertTo-Json -Compress)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    if ($bytes.Length -gt 8000) { throw "rendezvous message too large ($($bytes.Length) bytes)" }

    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        if ($Broadcast) { $udp.EnableBroadcast = $true }
        [void]$udp.Send($bytes, $bytes.Length, $Address, $Port)
    }
    finally { $udp.Close() }
}

function Get-MatriseBroadcastAddresses {
    $out = New-Object System.Collections.ArrayList
    [void]$out.Add('255.255.255.255')
    try {
        foreach ($a in (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' })) {
            $ip = [System.Net.IPAddress]::Parse($a.IPAddress).GetAddressBytes()
            $bits = [int]$a.PrefixLength
            if ($bits -lt 8 -or $bits -gt 31) { continue }

            # Built a byte at a time. Shifting a 32-bit mask in PowerShell
            # promotes it to Int64, so the top bits survive the shift and every
            # extracted byte comes out wrong.
            $mask = New-Object byte[] 4
            $rem = $bits
            for ($i = 0; $i -lt 4; $i++) {
                if ($rem -ge 8)     { $mask[$i] = 255; $rem -= 8 }
                elseif ($rem -gt 0) { $mask[$i] = [byte]((255 -shl (8 - $rem)) -band 255); $rem = 0 }
                else                { $mask[$i] = 0 }
            }
            for ($i = 0; $i -lt 4; $i++) {
                $ip[$i] = [byte](($ip[$i] -band $mask[$i]) -bor (255 -band (-bnot $mask[$i])))
            }
            $b = ([System.Net.IPAddress]::new($ip)).IPAddressToString
            if (-not $out.Contains($b)) { [void]$out.Add($b) }
        }
    } catch { }
    , $out
}

# The listener runs in its own runspace and drops parsed messages into a queue
# the UI drains on a timer, exactly like the command runner.
$script:MxRvListenerWorker = {
    param($port, $queue, $state)
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket,
                                    [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
        $udp.Client.ReceiveTimeout = 800
        $udp.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $port)))
        $state['Listening'] = $true

        $any = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        while (-not $state['Stop']) {
            try {
                $ref = $any
                $bytes = $udp.Receive([ref]$ref)
                $text  = [System.Text.Encoding]::UTF8.GetString($bytes)
                $msg   = $text | ConvertFrom-Json
                $queue.Enqueue([pscustomobject]@{ From = $ref.Address.ToString(); Message = $msg })
            }
            catch [System.Net.Sockets.SocketException] { }   # receive timeout: loop and re-check Stop
            catch { }                                        # malformed datagram: ignore, never trust the wire
        }
        $udp.Close()
    }
    catch {
        $state['Error'] = $_.Exception.Message
    }
    finally {
        $state['Listening'] = $false
        $state['Stopped']   = $true
    }
}

function Start-MatriseRvListener {
    param([int]$Port)

    $q = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
    $state = [hashtable]::Synchronized(@{ Stop = $false; Stopped = $false; Listening = $false; Error = '' })

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:MxRvListenerWorker)
    [void]$ps.AddArgument($Port)
    [void]$ps.AddArgument($q)
    [void]$ps.AddArgument($state)

    [pscustomobject]@{
        Port = $Port; Queue = $q; State = $state
        Ps = $ps; Rs = $rs; Handle = $ps.BeginInvoke()
    }
}

function Stop-MatriseRvListener {
    param($Listener)
    if (-not $Listener) { return }
    $Listener.State['Stop'] = $true
    $spin = 0
    while (-not $Listener.State['Stopped'] -and $spin -lt 40) { Start-Sleep -Milliseconds 50; $spin++ }
    try { $Listener.Ps.Stop() }   catch { }
    try { $Listener.Ps.Dispose() } catch { }
    try { $Listener.Rs.Close(); $Listener.Rs.Dispose() } catch { }
}

# ------------------------------------------------------------- messages ----
function New-MatriseRvHello {
    param([string]$SessionId)
    [pscustomobject]@{
        t = 'hello'; v = 1
        h = $env:COMPUTERNAME
        u = $env:USERNAME
        s = $SessionId
    }
}

function New-MatriseRvRequest {
    param($KeyPair, [string]$Nonce)
    [pscustomobject]@{
        t = 'req'; v = 1
        h = $env:COMPUTERNAME
        u = $env:USERNAME
        m = $KeyPair.Modulus
        e = $KeyPair.Exponent
        n = $Nonce
        p = $script:MxRvGuestPort
    }
}

function New-MatriseRvGrant {
    param([string]$Account, [string]$Password, [string]$Modulus, [string]$Exponent)
    [pscustomobject]@{
        t = 'grant'; v = 1
        h = $env:COMPUTERNAME
        i = @((Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' }).IPAddress)
        u = $Account
        c = (Protect-MatriseRvSecret -Modulus $Modulus -Exponent $Exponent -Plain $Password)
    }
}

function New-MatriseRvDeny {
    [pscustomobject]@{ t = 'deny'; v = 1; h = $env:COMPUTERNAME }
}

function New-MatriseRvNonce {
    $b = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    [Convert]::ToBase64String($b)
}

# ------------------------------------------------------- host-side setup ---
# Everything the host must do to itself before it can hand out a grant. Same
# work the pairing script did, minus the copy-and-paste.
function Initialize-MatriseHostSide {
    param([string]$Account = 'MatriseHelp')

    $steps = New-Object System.Collections.ArrayList
    $add = { param($ok, $text) [void]$steps.Add([pscustomobject]@{ Ok = $ok; Text = $text }) }

    if (-not (Test-MatriseElevated)) {
        & $add $false 'Matrise must be running as Administrator to host. Close it and start it with Matrise.bat.'
        return [pscustomobject]@{ Ok = $false; Steps = $steps; Password = ''; Account = $Account }
    }

    $password = New-MatriseCodePassword
    $sec = ConvertTo-SecureString $password -AsPlainText -Force
    try {
        if (Get-LocalUser -Name $Account -ErrorAction SilentlyContinue) {
            Set-LocalUser -Name $Account -Password $sec
            & $add $true "Reused the $Account account with a fresh password."
        } else {
            New-LocalUser -Name $Account -Password $sec -FullName 'Matrise remote help' `
                -Description $script:MatriseHelperDesc `
                -PasswordNeverExpires -AccountNeverExpires | Out-Null
            & $add $true "Created the $Account account."
        }
    }
    catch {
        & $add $false ("Could not create the helper account: " + $_.Exception.Message)
        return [pscustomobject]@{ Ok = $false; Steps = $steps; Password = ''; Account = $Account }
    }

    $rights = Grant-MatriseHelperRights -Account $Account
    foreach ($s in $rights.Steps) { & $add $s.Ok $s.Text }
    if (-not $rights.Ok) {
        return [pscustomobject]@{ Ok = $false; Steps = $steps; Password = ''; Account = $Account }
    }

    try {
        $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        New-ItemProperty -Path $k -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null
        & $add $true 'Allowed that account to administer this PC over the network.'
    }
    catch { & $add $false ("Could not set the remote-administration policy: " + $_.Exception.Message) }

    [pscustomobject]@{ Ok = $true; Steps = $steps; Password = $password; Account = $Account }
}

# Enabling WinRM is the slow part, so it is separate and callable in the
# background while the host waits for someone to connect.
function Enable-MatriseHostRemoting {
    $r = [pscustomobject]@{ Ok = $false; Detail = '' }
    try {
        Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop | Out-Null
    } catch {
        $r.Detail = $_.Exception.Message
    }
    $ports = @(Get-NetTCPConnection -LocalPort 5985, 5986 -State Listen -ErrorAction SilentlyContinue |
               Select-Object -ExpandProperty LocalPort -Unique)
    if ($ports) {
        $r.Ok = $true
        $r.Detail = "listening on $($ports -join '/')"
    } elseif (-not $r.Detail) {
        $r.Detail = 'WinRM is not accepting connections yet.'
    }
    $r
}

function Add-MatriseRvFirewallRule {
    if (-not (Test-MatriseElevated)) { return 'not elevated - firewall rule not added' }
    try {
        $name = 'Matrise rendezvous'
        if (-not (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow `
                -Protocol UDP -LocalPort $script:MxRvGuestPort, $script:MxRvHostPort `
                -Profile Private, Domain -ErrorAction Stop | Out-Null
            return "Added a firewall rule for UDP $($script:MxRvGuestPort)/$($script:MxRvHostPort) on private networks."
        }
        return 'Firewall rule already present.'
    }
    catch { return ("Could not add the firewall rule: " + $_.Exception.Message) }
}

function Remove-MatriseRvFirewallRule {
    try { Remove-NetFirewallRule -DisplayName 'Matrise rendezvous' -ErrorAction SilentlyContinue } catch { }
}
