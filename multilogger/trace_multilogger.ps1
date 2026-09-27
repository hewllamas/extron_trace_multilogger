<#
    trace_multilogger.ps1

    Connects directly to the trace server (telnet, TCP 6000) on several Extron
    processors at once and logs their output to per-processor files. Bypasses
    CSDU entirely, so it works around CSDU's one-trace-session-at-a-time limit
    - each processor's trace server is an independent TCP listener and doesn't
    care whether CSDU also has a session open on it.

    On connect, each worker enables trace for every room configured against that
    processor ("<room>:True"), so you don't have to do that by hand in CSDU/telnet
    first. Edit the $Processors table below to match your own processors and
    rooms - update it whenever a room is added, renamed or moved.

    On start (double-click or run with no args), a tick-box dialog lets you choose
    which processors to log this session - all ticked by default.

    Runs one background job per processor so they log truly concurrently. Logs
    land in <LogRoot>\<processor name>\ (default: the repo's logs\ folder), named
    Trace_MultiLogger_<timestamp>.log.

    Usage:
        # Start logging every processor in the table simultaneously
        .\trace_multilogger.ps1                      # or double-click run-trace_multilogger.bat
        .\trace_multilogger.ps1 -LogRoot D:\trace    # write logs somewhere else

        # Check on it later in the same PowerShell session
        Get-Job
        Receive-Job -Name processor-02 -Keep         # peek at recent lines without stopping it

        # When done
        Get-Job | Stop-Job
        Get-Job | Remove-Job
#>
param(
    [int]$Port = 6000,

    # Root folder for logs; each processor gets its own subfolder. Defaults to <repo>\logs.
    [string]$LogRoot,

    # -Worker mode: internal, used by the job to run a single processor's
    # connect/log loop. Don't call with -Worker directly.
    [switch]$Worker,
    [string]$Name,
    [string]$IPAddress,
    [string]$RoomList,
    [string]$LogDir
)

function Get-InnermostException ($ErrorRecord) {
    # PowerShell wraps a failed .NET method call in MethodInvocationException, which itself
    # wraps the real exception - and for a StreamReader.ReadLine() timeout specifically, that's
    # IOException wrapping SocketException, three levels deep. Checking only one level in (as an
    # earlier version of this script did) means a timeout is never recognised as one - walk all
    # the way to the bottom instead so socket-error checks actually match regardless of depth.
    $ex = $ErrorRecord.Exception
    while ($ex.InnerException) { $ex = $ex.InnerException }
    return $ex
}

function Select-Processors {
    # Tick-box dialog for choosing which processors to log this session. All ticked by
    # default - clicking "Start Logging" without touching anything logs everything.
    # Returns $null on Cancel/close (caller exits cleanly).
    param($Processors)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Extron trace multilogger - select processors to log'
    $form.Size = New-Object System.Drawing.Size(340, 260)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Topmost = $true

    $checklist = New-Object System.Windows.Forms.CheckedListBox
    $checklist.Location = New-Object System.Drawing.Point(10, 10)
    $checklist.Size = New-Object System.Drawing.Size(305, 150)
    $checklist.CheckOnClick = $true
    foreach ($p in $Processors) {
        [void]$checklist.Items.Add("$($p.Name)  ($($p.Rooms.Count) rooms)", $true)
    }
    $form.Controls.Add($checklist)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = 'Start Logging'
    $okButton.Location = New-Object System.Drawing.Point(115, 175)
    $okButton.Size = New-Object System.Drawing.Size(105, 30)
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($okButton)
    $form.AcceptButton = $okButton

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Location = New-Object System.Drawing.Point(230, 175)
    $cancelButton.Size = New-Object System.Drawing.Size(85, 30)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelButton)
    $form.CancelButton = $cancelButton

    $result = $form.ShowDialog()
    $form.Dispose()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

    $selectedIndexes = 0..($checklist.Items.Count - 1) | Where-Object { $checklist.GetItemChecked($_) }
    return $selectedIndexes | ForEach-Object { $Processors[$_] }
}

if (-not $LogRoot) { $LogRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'logs' }

# Demo data - replace with your own processors. Name is used for the job and the log subfolder,
# IP is the processor's address (these are RFC 5737 documentation addresses and won't answer),
# Rooms are the room names your program's TraceServer knows about - the same names you would
# type as "<room>:True" in a telnet session.
$Processors = @(
    @{ Name = 'processor-01'; IP = '192.0.2.11'; Rooms = @('Boardroom','Training','Huddle1','Huddle2') }
    @{ Name = 'processor-02'; IP = '192.0.2.12'; Rooms = @('Auditorium','Foyer') }
    @{ Name = 'processor-03'; IP = '192.0.2.13'; Rooms = @('Lab1','Lab2','Lab3') }
) | ForEach-Object { $_.LogDir = Join-Path $LogRoot $_.Name; $_ }

function Start-TraceWorker {
    param($Name, $IP, $Port, $LogDir, $Rooms)

    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    # ':' isn't valid in a Windows filename, so HH-mm uses a dash instead of a colon.
    $logFile = Join-Path $LogDir ("Trace_MultiLogger_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm'))

    # Writes to the log file AND the job's own output stream, so Receive-Job
    # actually shows something - Add-Content alone never surfaces to Receive-Job.
    function Write-Trace ($Value) {
        Add-Content -Path $logFile -Value $Value
        Write-Output $Value
    }

    while ($true) {
        $client = $null; $stream = $null; $reader = $null; $writer = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $client.Connect($IP, $Port)
            # Bounds ReadLine() below to 30s instead of blocking forever, so an idle connection
            # gives us a periodic chance to check for and retry any room that never confirmed.
            $client.ReceiveTimeout = 30000
            $stream = $client.GetStream()
            $writer = New-Object System.IO.StreamWriter($stream)
            $writer.AutoFlush = $true
            $reader = New-Object System.IO.StreamReader($stream)

            Write-Trace "[$(Get-Date -Format 'u')] Connected to $Name ($IP`:$Port)"

            # Every processor tested takes ~5-6s after TCP connect to
            # finish its handshake and actually start acting on commands - looks like a fixed
            # delay in the trace server itself (a reverse-DNS lookup timeout would explain it),
            # not something specific to one processor. Previously tried reading for the welcome
            # banner with a deadline, but StreamReader.ReadLine() blocks with no timeout once
            # DataAvailable goes true even for a partial line, so the deadline could never
            # actually cut it off - just blind-wait past the handshake instead. The main read
            # loop below picks up the (delayed) banner and command confirmations together once
            # they arrive.
            Start-Sleep -Seconds 7

            # Track which rooms have actually confirmed, so we can retry any that didn't -
            # observed on one processor after a program restart: 8 commands fired 100ms apart landed
            # in one coalesced TCP receive while the processor was boot-busy (still creating
            # rooms/connecting devices), and its trace_server_recv_data() splits the WHOLE
            # received blob on ':' with no per-line handling - garbled the lot into a handful of
            # "Invalid Command" responses instead of 8 confirmations, and NONE of the rooms
            # actually got enabled. No retry existed before this, so it stayed silently broken
            # until the job was manually restarted.
            $confirmed = @{}
            foreach ($room in $Rooms) { $confirmed[$room] = $false }

            function Send-RoomEnable ($RoomsToSend) {
                foreach ($room in $RoomsToSend) {
                    $writer.WriteLine("$room`:True")
                    Start-Sleep -Milliseconds 100
                }
            }

            Send-RoomEnable -RoomsToSend $Rooms
            Write-Trace "[$(Get-Date -Format 'u')] Trace enable sent for: $($Rooms -join ', ')"

            while ($client.Connected) {
                try {
                    $line = $reader.ReadLine()
                } catch {
                    $innermost = Get-InnermostException $_
                    $isTimeout = $innermost -is [System.Net.Sockets.SocketException] -and
                        $innermost.SocketErrorCode -eq [System.Net.Sockets.SocketError]::TimedOut
                    if (-not $isTimeout) { throw }

                    $unconfirmed = $Rooms | Where-Object { -not $confirmed[$_] }
                    if ($unconfirmed) {
                        Write-Trace "[$(Get-Date -Format 'u')] Still unconfirmed after 30s, re-sending: $($unconfirmed -join ', ')"
                        Send-RoomEnable -RoomsToSend $unconfirmed
                    }
                    continue
                }
                if ($null -eq $line) { break }
                Write-Trace "[$(Get-Date -Format 'HH:mm:ss.fff')] $line"

                foreach ($room in $Rooms) {
                    if (-not $confirmed[$room] -and $line -match "$([regex]::Escape($room)) Debug Set True") {
                        $confirmed[$room] = $true
                    }
                }
            }
            Write-Trace "[$(Get-Date -Format 'u')] Connection closed by remote"
        } catch {
            $innermost = Get-InnermostException $_
            if ($innermost -is [System.Net.Sockets.SocketException]) {
                Write-Trace "[$(Get-Date -Format 'u')] UNREACHABLE: $Name ($IP`:$Port) - $($innermost.Message). Check the processor is built/running and that you can reach $IP from this network. Retrying in 10s."
            } else {
                Write-Trace "[$(Get-Date -Format 'u')] ERROR: $($_.Exception.Message) - retrying in 10s"
            }
        } finally {
            if ($reader) { $reader.Dispose() }
            if ($writer) { $writer.Dispose() }
            if ($client) { $client.Dispose() }
        }
        Start-Sleep -Seconds 10
    }
}

if ($Worker) {
    Start-TraceWorker -Name $Name -IP $IPAddress -Port $Port -LogDir $LogDir -Rooms ($RoomList -split ',')
    return
}

$Processors = Select-Processors -Processors $Processors
if (-not $Processors -or $Processors.Count -eq 0) {
    Write-Host "No processors selected - exiting."
    return
}

$jobs = foreach ($p in $Processors) {
    Start-Job -Name $p.Name -ScriptBlock {
        param($ScriptPath, $Name, $IP, $Port, $LogDir, $RoomList)
        & $ScriptPath -Worker -Name $Name -IPAddress $IP -Port $Port -LogDir $LogDir -RoomList $RoomList
    } -ArgumentList $PSCommandPath, $p.Name, $p.IP, $Port, $p.LogDir, ($p.Rooms -join ',')
}

Write-Host "Started $($jobs.Count) trace logger jobs, logging into $LogRoot\<processor>\"
Write-Host "Trace is already enabled on every configured room - nothing to type here, this prompt is plain Windows PowerShell."
Write-Host "  Get-Job                              - check status"
Write-Host "  Receive-Job -Name <proc> -Keep        - peek at recent output without stopping"
Write-Host "  Get-Job | Stop-Job; Get-Job | Remove-Job   - stop everything"
