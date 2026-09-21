#Requires -RunAsAdministrator
<#
.SYNOPSIS
    TOAST custom image preparation, Windows side.

    Runs on your configured computer, from the TOAST USB drive.
    - Asks how computers built from this image should come up: user accounts,
      network settings and time zone
    - Checks that an image can be taken from this computer at all
    - Writes your answers to config\unattend.xml on the USB drive
    - Removes the preinstalled Windows apps that stop Sysprep running
    - Runs Sysprep, which prepares Windows and shuts the computer down

    You then boot the same USB drive and copy the disk with Clonezilla, as
    described in the Customer Image Capture Guide. Nothing this script does
    needs a network connection.

.NOTES
    Started by Run-Toast-Prep.cmd, which asks Windows for administrator
    rights on your behalf. There is no need to right-click and Run as
    administrator.

    Anything unexpected, stop and contact your supplier. The log is in the logs
    folder on this drive.
#>

# ============================================================
# CONFIGURATION
# ============================================================
# No share. Everything lives on the stick.
#
# From 1.4 this script ships in <kit>\scripts\ so that the only runnable file
# the customer sees in the kit folder is Run-Toast-Prep.cmd. config, logs and
# KIT-VERSION.txt stay in the KIT folder (and home\partimag one level above
# that), so KitRoot must be the kit folder, not this script's folder. Walk up
# when we are in scripts\; still work when the script sits in the kit root,
# which is how every build up to 1.3 shipped.
$ScriptDir     = $PSScriptRoot
if ((Split-Path $ScriptDir -Leaf) -ieq 'scripts') {
    $KitRoot = Split-Path $ScriptDir -Parent
} else {
    $KitRoot = $ScriptDir
}
if ([string]::IsNullOrWhiteSpace($KitRoot)) { $KitRoot = $ScriptDir }
$ConfigFolder  = Join-Path $KitRoot "config"
$KitLogFolder  = Join-Path $KitRoot "logs"

# Clonezilla's image store sits beside the kit folder, at <drive>\home\partimag.
# When the kit is unpacked into a subfolder (D:\TOAST) that is the PARENT of
# $KitRoot; when it is unpacked straight onto the root of the stick (D:\) there
# is no parent -- Split-Path returns nothing, Join-Path on nothing returns
# nothing, and the Test-Path further down then failed with "Cannot bind argument
# to parameter 'Path' because it is null". Both layouts have to land on the same
# place, <drive>\home\partimag, which is where the Clonezilla side looks.
$KitParent     = Split-Path $KitRoot -Parent
if ([string]::IsNullOrWhiteSpace($KitParent)) { $KitParent = $KitRoot }
$PartimagPath  = Join-Path $KitParent "home\partimag"
$KitVersion    = "1.0"
$KitVersionFile = Join-Path $KitRoot "KIT-VERSION.txt"

# Set true the moment this script first changes something on the computer, so
# that every message about what state the computer has been left in can tell the
# truth. The questions and the pre-flight checks change nothing; STEP 1 onwards
# does, and cancelling after that point is not the same as never having started.
$script:MachineChanged = $false

$LogFile       = "C:\Windows\Temp\CustomerSysprep.log"
$LocalUnattend = "C:\Windows\System32\Sysprep\unattend.xml"

# This script never asks for a Windows product key, and must not. Licensing for
# the computers built from this image is arranged by your supplier.
$productKey    = ""
$productKeyXml = ""

# ============================================================
# LOGGING
# ============================================================
function Write-Log {
    # -Quiet writes to the log file without printing. Use it for detail that is
    # already on screen in a tidier form, so the customer does not see it twice.
    param([string]$Message, [string]$Level = "INFO", [switch]$Quiet)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    if (-not $Quiet) {
        # Windows error text is routinely a dozen lines of detail and a support
        # hyperlink. All of it goes to the log; only the first line goes on
        # screen. One failed app package used to scroll a whole screen past.
        $shown = $Message
        if ($shown -match '[\r\n]') {
            $first = @($shown -split '[\r\n]+' | Where-Object { $_.Trim() -ne '' })[0]
            if ($null -eq $first) { $first = "" }
            $shown = "$($first.Trim())  (full detail is in the log)"
        }
        if ($shown.Length -gt 200) { $shown = $shown.Substring(0, 197) + "..." }

        # The screen gets a short marker instead of the timestamp and level.
        # The customer is reading a checklist, not a log, and a wall of
        # "[2026-08-31 12:45:21] [INFO]" prefixes was the single biggest reason
        # the screen read as machine output rather than as something for them.
        # The log line above keeps the full timestamp and level, so a screenshot
        # can still be matched to the log by its text.
        #
        # Every marker is padded to the same width, so the text of every line
        # starts in the same column and the whole run reads as one list.
        $marker = switch ($Level) {
            "OK"    { "[ok]" }
            "WARN"  { "[!]" }
            "ERROR" { "[X]" }
            default { "" }
        }
        $onScreen = "  {0,-4} {1}" -f $marker, $shown
        switch ($Level) {
            "OK"    { Write-Host $onScreen -ForegroundColor Green }
            "WARN"  { Write-Host $onScreen -ForegroundColor Yellow }
            "ERROR" { Write-Host $onScreen -ForegroundColor Red }
            default { Write-Host $onScreen -ForegroundColor White }
        }
    }
    Add-Content -Path $LogFile -Value $entry
}

function Write-Section {
    # -Part/-Of number the five sets of questions the customer answers, so that
    # the run stops feeling open-ended: "PART 3 OF 5" says how much is left. The
    # work steps after the questions are deliberately NOT numbered this way --
    # numbering them too would make five parts look like twelve.
    param([string]$Title, [int]$Part = 0, [int]$Of = 0)
    $line = "=" * 60
    $head = if ($Part -gt 0) { "  PART $Part OF $Of   $Title" } else { "  $Title" }
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Write-Host $head -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
    Add-Content -Path $LogFile -Value ""
    Add-Content -Path $LogFile -Value $line
    Add-Content -Path $LogFile -Value $head
    Add-Content -Path $LogFile -Value $line
}

# ============================================================
# MAKE THE WINDOW AS BIG AS THE SCREEN
# ============================================================
# The customer has to READ this window, and a default 80x25 console throws most
# of what it says off the top before they get to it. Three separate things are
# needed, and each is wrapped in its own try because any of them can be refused
# depending on which console host Windows gave us -- a small window is a poor
# experience, never a reason to stop.
#
#   1. Maximize the host window itself (ShowWindow, SW_MAXIMIZE). This is the
#      only one of the three that Windows Terminal honours.
#   2. Grow the screen buffer to the physical maximum width and give it 9999
#      lines of scrollback, so anything that does scroll past can be scrolled
#      back to instead of being lost.
#   3. Grow the visible window to that same physical maximum. The buffer has to
#      be set FIRST and has to stay at least as large as the window, or the
#      assignment throws.
try {
    $sw = @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
    $tw = Add-Type -MemberDefinition $sw -Name "TOASTWindow" -Namespace "TOAST" -PassThru -ErrorAction Stop
    $hwnd = $tw::GetConsoleWindow()
    if ($hwnd -ne [IntPtr]::Zero) { $null = $tw::ShowWindow($hwnd, 3) }   # 3 = SW_MAXIMIZE
} catch { }

try {
    $raw = $Host.UI.RawUI
    $max = $raw.MaxPhysicalWindowSize

    $buf = $raw.BufferSize
    if ($max.Width -gt $buf.Width) { $buf.Width = $max.Width }
    $buf.Height = 9999
    $raw.BufferSize = $buf

    $vis = $raw.WindowSize
    $vis.Width  = [Math]::Min($max.Width,  $raw.BufferSize.Width)
    $vis.Height = [Math]::Min($max.Height, $raw.BufferSize.Height)
    $raw.WindowSize = $vis
} catch { }

Clear-Host
Write-Section "TOAST IMAGE CAPTURE KIT - STEP 1 OF 2"
Write-Log "Computer  : $env:COMPUTERNAME"
Write-Log "Date/Time : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "Log File  : $LogFile"

# ============================================================
# HELPERS - LOG OFF-MACHINE, AND STOPPING CLEANLY
# ============================================================
# Every exit point copies the log to the stick. A unit that fails pre-flight is
# powered down and shipped nowhere; the log on the stick is the only artifact
# support will ever see.
function Copy-LogToStick {
    try {
        if (-not (Test-Path $KitLogFolder)) { New-Item -ItemType Directory -Path $KitLogFolder -Force | Out-Null }
        Copy-Item -LiteralPath $LogFile -Destination (Join-Path $KitLogFolder "windows-step1.log") -Force -ErrorAction Stop
    } catch { Write-Host "  (Could not copy the log to the USB drive: $_)" -ForegroundColor DarkGray }
}

function Stop-Kit {
    param([string]$Reason, [string]$WhatToDo = "Please contact your supplier and quote the message above.")
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Red
    Write-Host "  CANNOT CONTINUE" -ForegroundColor Red
    Write-Host ("=" * 60) -ForegroundColor Red
    Write-Log $Reason "ERROR"
    Write-Host ""
    Write-Host "  $WhatToDo" -ForegroundColor Yellow
    Write-Host ""
    if ($script:MachineChanged) {
        Write-Host "  This computer was NOT prepared for imaging, so Windows starts" -ForegroundColor White
        Write-Host "  normally the next time it is switched on." -ForegroundColor White
        Write-Host ""
        Write-Host "  Getting this far did remove some of the preinstalled Windows apps" -ForegroundColor White
        Write-Host "  and change a few Windows settings. Your own files, programs," -ForegroundColor White
        Write-Host "  accounts and settings were not touched." -ForegroundColor White
    } else {
        Write-Host "  Nothing has been changed on this computer." -ForegroundColor White
    }
    Write-Host "  A copy of the log is on the USB drive: $KitLogFolder" -ForegroundColor Gray
    Write-Host ""
    Copy-LogToStick
    Write-Host "  Press any key to close." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

function Confirm-Or-Stop {
    param([string]$Question, [string]$Reason)
    $ans = Read-Answer -Question $Question `
                       -Notes "Type YES to continue. Anything else, including Enter, stops here."
    if ($ans.Trim().ToUpper() -ne "YES") {
        Stop-Kit -Reason $Reason -WhatToDo "Stopped at your request."
    }
    Write-Log "Customer confirmed: $Question"
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return ("{0:N1} TB" -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ("{0:N1} GB" -f ($Bytes / 1GB)) }
    return ("{0:N0} MB" -f ($Bytes / 1MB))
}

function Get-SysprepBlockingAppx {
    # Every app that would make sysprep /generalize fail with 0x80073cf2:
    # installed for a user, but not provisioned for all users.
    #
    # Three exclusions, and each one is load-bearing:
    #
    #   SignatureKind System  inbox components. On a stock image EVERY one of
    #                         them is installed and unprovisioned, and sysprep
    #                         is perfectly happy. Confirmed on the lab VM.
    #   IsFramework           runtimes. Provisioned by whatever depends on them.
    #   NonRemovable          part of Windows and refuses removal with
    #                         0x80070032 "the request is not supported".
    #
    # NonRemovable is the one that was missing, and it is not a tidy-up. Windows
    # Security (Microsoft.SecHealthUI) is Store-signed, not System-signed, so the
    # SignatureKind test does not catch it. Trying to remove such a package FAILS
    # AND STILL STRIPS ITS PROVISIONING, so the failed attempt is itself what
    # turns a healthy inbox app into a blocker -- and neither removal nor
    # re-provisioning can then clear it (Add-AppxProvisionedPackage from the
    # installed manifest returns 0x8051100f, and the DISM CLI form reports
    # success while doing nothing). Measured on the lab VM 2026-09-18.
    #
    # NonRemovable is only populated when running elevated. If it ever comes back
    # empty the test reads as false and this behaves exactly as it did before,
    # which is the right way round to fail.
    $prov  = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
    $names = @($prov.DisplayName) + @($prov.PackageName | ForEach-Object { ($_ -split '_')[0] })
    @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object {
        $_.SignatureKind -ne 'System' -and
        -not $_.IsFramework -and
        -not $_.NonRemovable -and
        $names -notcontains $_.Name
    })
}

# ============================================================
# ASKING A QUESTION
# ============================================================
# Every question the customer answers goes through here, so that they all look
# the same and all stand out from the progress lines scrolling past above them.
#
# The question itself is drawn in reverse video, black on yellow. Nothing else
# this script prints uses a background colour at all, so a question cannot be
# mistaken for progress output however fast the screen is moving -- which was
# the complaint that put this function here. Do not start colouring progress
# lines with a background: the highlight only works while it is unique.
#
# -Notes are the one-line clarifications that used to be printed by hand above
# each Read-Host, and -Default says in plain words what pressing Enter does.
# Both go in the log with the answer, so the log records what was actually on
# screen when the question was answered.
function Read-Answer {
    param(
        [Parameter(Mandatory = $true)][string]$Question,
        [string[]]$Notes = @(),
        [string]$Default = "",
        [int]$Indent = 2,
        [switch]$Secret          # a password: prompt normally, record nothing
    )
    $pad = " " * $Indent
    Write-Host ""
    Write-Host "$pad ? $Question " -ForegroundColor Black -BackgroundColor Yellow
    foreach ($n in $Notes) {
        if (-not [string]::IsNullOrWhiteSpace($n)) { Write-Host "$pad   $n" -ForegroundColor Gray }
    }
    if ($Default) { Write-Host "$pad   Press Enter for: $Default" -ForegroundColor DarkGray }

    $answer = Read-Host "$pad > Your answer"
    if ($null -eq $answer) { $answer = "" }

    if ($Secret) {
        Write-Log "Asked: $Question -> answer not recorded (password)" -Quiet
    } else {
        $recorded = if ([string]::IsNullOrWhiteSpace($answer)) { "(Enter)" } else { $answer }
        Write-Log "Asked: $Question -> $recorded" -Quiet
    }
    return [string]$answer
}

# ============================================================
# LOCATE THE KIT ON THE USB DRIVE
# ============================================================
Write-Section "CHECKING THE TOAST USB DRIVE"

if ([string]::IsNullOrWhiteSpace($KitRoot)) {
    Stop-Kit -Reason "Could not work out where this script is running from." `
             -WhatToDo "Run Run-Toast-Prep.cmd from the USB drive itself, not from a copy on the computer."
}
Write-Log "Kit folder : $KitRoot"

if (Test-Path $KitVersionFile) {
    $KitVersion = (Get-Content -LiteralPath $KitVersionFile -Raw).Trim()
}
Write-Log "Kit version: $KitVersion"

$kitDrive = (Split-Path -Qualifier $KitRoot)
$kitVolume = $null
try { $kitVolume = Get-Volume -DriveLetter $kitDrive.TrimEnd(':') -ErrorAction Stop } catch {}
if (-not $kitVolume) {
    Stop-Kit -Reason "Could not read the USB drive ($kitDrive)." `
             -WhatToDo "Unplug the USB drive, plug it back in, and run Run-Toast-Prep.cmd again."
}
Write-Log "USB drive  : $kitDrive  ($($kitVolume.FileSystem), $(Format-Size $kitVolume.Size) total, $(Format-Size $kitVolume.SizeRemaining) free)"

# The stick has to be writable -- the wizard writes the config the capture reads,
# and the capture writes tens of gigabytes back to it.
$writeProbe = Join-Path $KitRoot ".toast-write-test"
try {
    Set-Content -LiteralPath $writeProbe -Value "ok" -ErrorAction Stop
    Remove-Item -LiteralPath $writeProbe -Force -ErrorAction SilentlyContinue
} catch {
    Stop-Kit -Reason "The USB drive is read-only ($kitDrive)." `
             -WhatToDo "Check for a write-protect switch on the drive, then run Run-Toast-Prep.cmd again."
}

foreach ($d in @($ConfigFolder, $KitLogFolder, $PartimagPath)) {
    if ([string]::IsNullOrWhiteSpace($d)) { continue }
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
Write-Log "USB drive is writable and the kit folders are present." "OK"

# A stick that already holds a finished capture must not be reused. Re-running
# step 1 would sysprep this unit again and the capture step would then refuse to
# overwrite the good image -- leaving a generalized machine and no way forward.
if (Test-Path (Join-Path $ConfigFolder "capture.done")) {
    $doneWhen = (Get-Content -LiteralPath (Join-Path $ConfigFolder "capture.done") -First 1)
    Stop-Kit -Reason "This USB drive already holds a completed capture (finished $doneWhen)." `
             -WhatToDo "This kit's work is done. Follow the upload instructions instead. If you need to capture another unit, contact your supplier for another kit."
}

# ============================================================
# PRE-FLIGHT CHECKS
# ============================================================
# The wizard refuses rather than failing halfway. Sysprep is a one-way door: it
# generalizes the machine and shuts it down, and a customer left with a
# half-generalized unit and no image has to rebuild their configuration by hand.
Write-Section "PRE-FLIGHT CHECKS"

# --- Windows edition and build ------------------------------------------------
$os = Get-CimInstance -ClassName Win32_OperatingSystem
$osBuild = [int]$os.BuildNumber
Write-Log "Windows    : $($os.Caption) build $($os.BuildNumber) ($($os.OSArchitecture))"

if ($os.ProductType -ne 1) {
    Write-Log "This is a Windows Server installation." "WARN"
    Confirm-Or-Stop -Question "This looks like Windows Server, which we have not tested with this kit. Continue anyway?" `
                    -Reason "Stopped on an untested Windows Server installation."
}
# 17763 is Windows 10 1809, which is what IoT Enterprise LTSC 2019 is built on.
# Supported from 2026-08-28. Older than that is refused: the appx and servicing
# behaviour this script depends on differs too much to claim it works.
if ($osBuild -lt 17763) {
    Stop-Kit -Reason "Windows build $osBuild is older than we support with this kit (need 17763 / Windows 10 1809 or newer)." `
             -WhatToDo "Contact your supplier -- we can capture this unit a different way."
}
if ($osBuild -lt 18362) {
    # LTSC 2019 territory. Nothing here fails, but two steps have less to do and
    # say so rather than looking like they went wrong.
    Write-Log "Build $osBuild predates Windows 10 1903, so reserved storage does not exist on this computer." "OK"
}
if ($os.Caption -match 'Home') {
    Stop-Kit -Reason "Windows Home editions cannot be prepared this way." `
             -WhatToDo "Contact your supplier."
}
Write-Log "Windows edition and build are supported." "OK"

# In-place upgrade. Sysprep is unsupported on an upgraded Windows, but the signal
# is a heuristic (the Setup keys survive some legitimate servicing operations
# too), so this warns and asks rather than hard-stopping -- a false positive that
# refused outright would strand a customer whose unit is actually fine.
$upgradeKeys = @(Get-ChildItem "HKLM:\SYSTEM\Setup" -ErrorAction SilentlyContinue |
                 Where-Object { $_.PSChildName -like "Source OS*" })
if ($upgradeKeys.Count -gt 0 -or (Test-Path "C:\Windows.old")) {
    Write-Log "Signs of an in-place Windows upgrade found ($($upgradeKeys.Count) Source OS key(s), Windows.old $(if (Test-Path 'C:\Windows.old') { 'present' } else { 'absent' }))." "WARN"
    Write-Host ""
    Write-Host "  This computer looks like it was upgraded to a newer Windows version" -ForegroundColor Yellow
    Write-Host "  in place, rather than installed fresh. Microsoft does not support" -ForegroundColor Yellow
    Write-Host "  imaging those, and the next step may fail." -ForegroundColor Yellow
    Confirm-Or-Stop -Question "Continue anyway?" -Reason "Stopped on a possible in-place-upgraded Windows."
}

# --- One internal disk --------------------------------------------------------
$sysPartition = Get-Partition -DriveLetter C -ErrorAction Stop
$sysDisk      = $sysPartition | Get-Disk
# Internal disks only. Excluding by bus type rather than by RemovableMedia is
# deliberate: eMMC-based units report BusType MMC/SD for the disk Windows is
# actually on, so filtering those out would drop the system disk itself.
$fixedDisks   = @(Get-Disk | Where-Object { $_.BusType -ne 'USB' })
Write-Log "Windows disk: #$($sysDisk.Number) $($sysDisk.FriendlyName) $(Format-Size $sysDisk.Size), style $($sysDisk.PartitionStyle)"

if ($fixedDisks.Count -gt 1) {
    foreach ($d in $fixedDisks) {
        Write-Log "  disk #$($d.Number) $($d.FriendlyName) $(Format-Size $d.Size) bus $($d.BusType)"
    }
    Stop-Kit -Reason "This computer has $($fixedDisks.Count) internal disks. The kit captures one disk only." `
             -WhatToDo "Contact your supplier -- multi-disk units need a decision we should not make for you."
}
Write-Log "Single internal disk confirmed." "OK"

# --- BitLocker ----------------------------------------------------------------
# NOTE: the proposal said "suspended or off". Suspended is NOT sufficient and
# saying so would produce unusable kits: suspending writes a clear key into the
# volume metadata but leaves every sector encrypted, so partclone cannot read the
# filesystem and falls back to a raw sector copy -- a 40 GB install becomes a
# whole-disk image, blows the free-space check, and blows the upload. The volume
# has to be fully decrypted.
$blVolumes = @()
try {
    $blVolumes = @(Get-BitLockerVolume -ErrorAction Stop |
                   Where-Object { $_.VolumeStatus -ne 'FullyDecrypted' })
} catch {
    Write-Log "BitLocker cmdlets unavailable on this edition -- checking manage-bde instead." "WARN"
    $bde = (& manage-bde -status 2>&1) -join "`n"
    $encPcts = @([regex]::Matches($bde, 'Percentage Encrypted:\s*([\d.]+)') |
                 ForEach-Object { [double]$_.Groups[1].Value } | Where-Object { $_ -gt 0 })
    if ($encPcts.Count -gt 0) {
        Stop-Kit -Reason "At least one drive on this computer is encrypted with BitLocker." `
                 -WhatToDo "Turn BitLocker off (Control Panel > BitLocker Drive Encryption > Turn off), wait for decryption to finish, then run Run-Toast-Prep.cmd again."
    }
}
if ($blVolumes.Count -gt 0) {
    foreach ($v in $blVolumes) {
        Write-Log "BitLocker on $($v.MountPoint): status $($v.VolumeStatus), protection $($v.ProtectionStatus), $($v.EncryptionPercentage)% encrypted" "WARN"
    }
    Write-Host ""
    Write-Host "  BitLocker drive encryption is on. An encrypted drive cannot be" -ForegroundColor Yellow
    Write-Host "  imaged -- the copy would be unreadable on any other computer." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  BitLocker has to be turned OFF and the drive fully decrypted." -ForegroundColor White
    Write-Host "  That can take an hour or more, and this script cannot wait for it." -ForegroundColor Gray
    Write-Host ""
    $doDecrypt = Read-Answer -Question "Start decrypting now? (Y / N)" `
                             -Notes "Either answer stops this script: decrypting takes far longer than it can wait for, so you run Run-Toast-Prep.cmd again once it has finished.", `
                                    "Y starts decrypting now. N leaves it for you to turn BitLocker off yourself." `
                             -Default "N -- do not start it"
    if ($doDecrypt -match '^[Yy]') {
        foreach ($v in $blVolumes) {
            try {
                Disable-BitLocker -MountPoint $v.MountPoint -ErrorAction Stop | Out-Null
                Write-Log "Decryption started on $($v.MountPoint)." "OK"
            } catch {
                Write-Log "Could not start decryption on $($v.MountPoint): $_" "ERROR"
            }
        }
        Stop-Kit -Reason "Decryption has been started. It has to finish before an image can be taken." `
                 -WhatToDo "Leave the computer on and plugged in. Check progress in Control Panel > BitLocker Drive Encryption. When every drive says 'BitLocker off', run Run-Toast-Prep.cmd again."
    }
    Stop-Kit -Reason "BitLocker is still on, so the image cannot be taken." `
             -WhatToDo "Turn BitLocker off (Control Panel > BitLocker Drive Encryption > Turn off), wait for decryption to finish, then run Run-Toast-Prep.cmd again."
}
Write-Log "No BitLocker-encrypted volumes." "OK"

# --- Domain membership --------------------------------------------------------
$cs = Get-CimInstance -ClassName Win32_ComputerSystem
if ($cs.PartOfDomain) {
    Write-Log "Computer is joined to domain $($cs.Domain)." "WARN"
    Write-Host ""
    Write-Host "  This computer is joined to the domain '$($cs.Domain)'." -ForegroundColor Yellow
    Write-Host "  Preparing the image removes the domain membership, from this" -ForegroundColor Yellow
    Write-Host "  computer and from every computer built from the image. They will" -ForegroundColor Yellow
    Write-Host "  each need re-joining after delivery." -ForegroundColor Yellow
    Confirm-Or-Stop -Question "Is that what you want?" -Reason "Stopped: domain-joined computer, not confirmed."
} else {
    Write-Log "Not domain-joined (workgroup $($cs.Workgroup))." "OK"
}

# --- Pending reboot / pending servicing ---------------------------------------
$pendingReasons = @()
if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
    $pendingReasons += "a Windows component installation is waiting for a restart"
}
if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
    $pendingReasons += "Windows Update is waiting for a restart"
}
# PendingFileRenameOperations is deliberately NOT a stop condition: it is present
# on a large share of healthy machines and sysprep does not fail on it.
$pfro = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
if ($pfro) { Write-Log "PendingFileRenameOperations present ($($pfro.Count) entries) -- not a blocker, recorded only." }

if ($pendingReasons.Count -gt 0) {
    Stop-Kit -Reason ("Restart pending: " + ($pendingReasons -join "; ") + ".") `
             -WhatToDo "Restart the computer, let Windows finish installing updates, then run Run-Toast-Prep.cmd again."
}
Write-Log "No pending restart." "OK"

# --- Will the image fit on the stick? -----------------------------------------
# Used space across every volume on the Windows disk. The capture is compressed,
# so this is a deliberately pessimistic figure -- if the uncompressed used space
# fits, the image certainly does.
$usedBytes = 0
$measured  = @()
foreach ($p in (Get-Partition -DiskNumber $sysDisk.Number -ErrorAction SilentlyContinue)) {
    $vol = $null
    try { $vol = $p | Get-Volume -ErrorAction Stop } catch {}
    if ($vol -and $vol.Size -gt 0 -and $vol.SizeRemaining -ge 0 -and $vol.FileSystem) {
        $u = [int64]($vol.Size - $vol.SizeRemaining)
        $usedBytes += $u
        $measured  += "part$($p.PartitionNumber) $($vol.FileSystem) $(Format-Size $u) used"
    } else {
        # No readable filesystem (MSR, or a recovery partition with no letter):
        # count the whole partition, which is what partclone will copy sector-wise.
        $usedBytes += [int64]$p.Size
        $measured  += "part$($p.PartitionNumber) raw $(Format-Size $p.Size) counted whole"
    }
}
Write-Log "Disk usage : $($measured -join ' | ')"
Write-Log "Total to capture (uncompressed): $(Format-Size $usedBytes)"

$usbFree = [int64]$kitVolume.SizeRemaining
if ($usbFree -lt $usedBytes) {
    Stop-Kit -Reason "The USB drive does not have enough free space. Free on the drive: $(Format-Size $usbFree). Data on this computer: $(Format-Size $usedBytes)." `
             -WhatToDo "Contact your supplier with those two numbers -- we will send a larger kit."
}
Write-Log "USB free space $(Format-Size $usbFree) is enough for $(Format-Size $usedBytes) of data." "OK"

# --- Apps that will block sysprep (informational here; enforced before sysprep)-
# STEP 2B below removes these. This pass exists so an unfixable one is reported
# now, before the customer has answered twenty questions.
$blockingApps = @(Get-SysprepBlockingAppx)
if ($blockingApps.Count -gt 0) {
    Write-Log "$($blockingApps.Count) app(s) are installed for a user but not for all users -- these block sysprep and will be removed later in this run." "WARN"
    foreach ($a in $blockingApps) { Write-Log "  will remove: $($a.PackageFullName)" }
} else {
    Write-Log "No sysprep-blocking apps found." "OK"
}

Write-Host ""
Write-Log "All pre-flight checks passed." "OK"

# The checks above print a couple of dozen lines in a few seconds. Stopping here
# means the first question is not read off the bottom of a screen that is still
# moving. It is also the one chance to say how much is coming and what a
# question looks like, which is what stops the run feeling open-ended.
Write-Host ""
Write-Host "  The checks are done. From here on the script asks you questions," -ForegroundColor White
Write-Host "  in five short parts:" -ForegroundColor White
Write-Host ""
Write-Host "    PART 1   Who this image is for" -ForegroundColor White
Write-Host "             your company name, so we can label the image" -ForegroundColor Gray
Write-Host "    PART 2   Network settings" -ForegroundColor White
Write-Host "             a fixed IP address, or leave addresses automatic" -ForegroundColor Gray
Write-Host "    PART 3   User accounts" -ForegroundColor White
Write-Host "             extra accounts, and signing in automatically" -ForegroundColor Gray
Write-Host "    PART 4   First start" -ForegroundColor White
Write-Host "             what the user sees the first time one is switched on" -ForegroundColor Gray
Write-Host "    PART 5   Other options" -ForegroundColor White
Write-Host "             Wi-Fi, Windows Update, time zone" -ForegroundColor Gray
Write-Host ""
Write-Host "  Eight questions in all, if you take the answer each one suggests." -ForegroundColor Gray
Write-Host "  Only the first, your company name, has to be typed in. Choosing to" -ForegroundColor Gray
Write-Host "  add an account or set a fixed IP address adds a few more." -ForegroundColor Gray
Write-Host ""
Write-Host "  Every question looks like this, and nothing else on screen does:" -ForegroundColor White
Write-Host ""
Write-Host "   ? An example question " -ForegroundColor Black -BackgroundColor Yellow
Write-Host "     A grey line under it explains the question, if it needs it." -ForegroundColor Gray
Write-Host "     Press Enter for: the answer you get by pressing Enter" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Nothing on this computer is changed while you answer them, and" -ForegroundColor Gray
Write-Host "  there is a last chance to stop after the last one." -ForegroundColor Gray
Write-Host ""
Write-Host "  Press Enter to start." -ForegroundColor Green
$null = Read-Host
# ============================================================
# CUSTOMER AND IMAGE NAME
# ============================================================
# Nothing is pre-seeded. Every stick that leaves TOAST is identical -- no
# customer name, no link, no address baked in at build time -- and only becomes
# specific to a customer once they answer these questions and it captures their
# image.
Write-Section "WHO THIS IMAGE IS FOR" -Part 1 -Of 5

$customerName = ""
while ([string]::IsNullOrWhiteSpace($customerName)) {
    $customerName = (Read-Answer -Question "Company name" `
                                 -Notes "This only labels the image file, so we can tell whose it is when it arrives.").Trim()
    if ([string]::IsNullOrWhiteSpace($customerName)) {
        Write-Host "  A name is needed here. Please type your company name." -ForegroundColor Yellow
    }
}
$customerName = $customerName -replace '[\\/:*?"<>|]', '_'
Write-Log "Customer name: $customerName"

# Image revision, so a later image can be told from this one by more than its
# date, and two captures on the same day do not produce the same name.
$imageVersion = ""
while ([string]::IsNullOrWhiteSpace($imageVersion)) {
    $imageVersion = (Read-Answer -Question "Image version" `
                                 -Notes "Press Enter for v1.", "If TOAST has asked for an updated image, use the next number: v2, v3 and so on." `
                                 -Default "v1").Trim()
    if ([string]::IsNullOrWhiteSpace($imageVersion)) { $imageVersion = "v1" }
}
# Typing just "2" is the obvious thing to do, so accept it and make it v2.
if ($imageVersion -match '^[0-9]+$') { $imageVersion = "v$imageVersion" }
Write-Log "Image version: $imageVersion"

# Model comes from the computer's own firmware rather than from a question. It
# has to match exactly, and typing it by hand is the easiest way to get it wrong.
$modelName = ""
try { $modelName = (Get-CimInstance -ClassName Win32_ComputerSystemProduct).Name.Trim() } catch {}
if ([string]::IsNullOrWhiteSpace($modelName)) {
    try { $modelName = (Get-CimInstance -ClassName Win32_ComputerSystem).Model.Trim() } catch {}
}
if ([string]::IsNullOrWhiteSpace($modelName)) { $modelName = "unknown-model" }
Write-Log "Model (from firmware): $modelName"

$serialNumber = ""
try { $serialNumber = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber.Trim() } catch {}
if ($serialNumber) { Write-Log "Unit serial (from firmware): $serialNumber" }

# Clonezilla uses the image name as a directory name on a FAT32 filesystem, so
# keep it to characters that are safe there and in a shell.
function ConvertTo-SafeName {
    param([string]$Text)
    $t = ($Text -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLower()
    if ($t.Length -gt 40) { $t = $t.Substring(0, 40).Trim('-') }
    return $t
}
# company - unit - version - capture date
$imageName = "{0}-{1}-{2}-{3}" -f (ConvertTo-SafeName $customerName), (ConvertTo-SafeName $modelName), (ConvertTo-SafeName $imageVersion), (Get-Date -Format 'yyyyMMdd')
Write-Log "Image name : $imageName" "OK"

Write-Host ""
Write-Host "  Company : $customerName" -ForegroundColor White
Write-Host "  Model   : $modelName" -ForegroundColor White
Write-Host "  Version : $imageVersion" -ForegroundColor White
Write-Host "  Image   : $imageName" -ForegroundColor White
# ============================================================
# REUSE THE ANSWERS FROM AN EARLIER RUN ON THIS KIT
# ============================================================
# Only ever one saved file, on the stick itself. This exists for the re-run case:
# a first attempt that stopped at a pre-flight check, or a sysprep that had to be
# repeated. It saves the customer answering twenty questions a second time.
$reuseUnattend   = $false
$reuseSourcePath = ""
$savedUnattend   = Join-Path $ConfigFolder "unattend.xml"
if (Test-Path $savedUnattend) {
    $savedInfo = Get-Item -LiteralPath $savedUnattend
    Write-Host ""
    Write-Host "  This kit already has answers saved from an earlier run on" -ForegroundColor White
    Write-Host ("  {0:yyyy-MM-dd} at {0:HH:mm}." -f $savedInfo.LastWriteTime) -ForegroundColor White
    $reuseInput = Read-Answer -Question "Reuse the saved answers? (Y / N)" `
                              -Notes "Y uses those answers and skips every question below.", `
                                     "N asks all of them again from the start." `
                              -Default "Y -- reuse them"
    if (-not ($reuseInput -match '^[Nn]')) {
        $reuseSourcePath = $savedUnattend
        $unattendXml     = [System.IO.File]::ReadAllText($reuseSourcePath)
        $reuseUnattend   = $true
        Write-Log "Reusing saved unattend.xml from: $reuseSourcePath" "OK"
    } else {
        Write-Log "Customer chose to answer the questions again."
    }
}

# Defaults for the summary section -- the prompt sections below are skipped
# entirely when a saved unattend is reused.
$nicConfigs = @(); $users = @(); $existingAutoUser = $null
$autoLogonEveryBoot = $false; $autoLogonViaRegistry = $false
$disableWifi = $false; $disableWU = $false; $timeZone = ""
$oobeMode = 1

if (-not $reuseUnattend) {

# ============================================================
# PROMPT - NETWORK CONFIGURATION
# ============================================================
Write-Section "NETWORK SETTINGS" -Part 2 -Of 5
Write-Host ""
Write-Host "  If the computers built from this image need a fixed IP address," -ForegroundColor White
Write-Host "  set it here. Skipping is safe and is what most people want." -ForegroundColor White

function ConvertTo-PrefixLength {
    param([string]$Mask)
    try {
        $bytes = ([System.Net.IPAddress]$Mask).GetAddressBytes()
        $bits  = $bytes | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }
        return ($bits -join '' -replace '0').Length
    } catch { return 24 }
}

$nicConfigs = @()
$configureNics = Read-Answer -Question "Set a fixed IP address on any network adapter? (Y / N)" `
                             -Notes "N leaves every adapter getting its address automatically (DHCP)." `
                             -Default "N -- keep automatic addresses"
if ($configureNics -match '^[Yy]') {
    $addAnother = $true
    $nicIndex   = 0
    while ($addAnother) {
        $nicIndex++
        Write-Host ""
        Write-Host "  --- Adapter $nicIndex ---" -ForegroundColor Cyan

        $adapterName = (Read-Answer -Indent 4 -Question "Adapter name, exactly as Windows shows it" `
                                    -Notes "The name in Settings > Network > Advanced network settings." `
                                    -Default "Ethernet").Trim()
        if ([string]::IsNullOrWhiteSpace($adapterName)) { $adapterName = "Ethernet" }

        $ipAddress = ""
        while (-not ($ipAddress -match '^\d{1,3}(\.\d{1,3}){3}$')) {
            $ipAddress = (Read-Answer -Indent 4 -Question "IP address for this adapter" `
                                      -Notes "Four numbers separated by dots, for example 192.168.1.50.").Trim()
            if (-not ($ipAddress -match '^\d{1,3}(\.\d{1,3}){3}$')) {
                Write-Host "    Invalid format -- enter a dotted-decimal IP address." -ForegroundColor Yellow
            }
        }

        $maskInput = (Read-Answer -Indent 4 -Question "Subnet mask" `
                                  -Default "255.255.255.0").Trim()
        if ([string]::IsNullOrWhiteSpace($maskInput)) { $maskInput = "255.255.255.0" }
        $prefix = ConvertTo-PrefixLength $maskInput
        $cidr   = "$ipAddress/$prefix"

        $gateway = (Read-Answer -Indent 4 -Question "Default gateway, that is your router's address" `
                                -Default "no gateway").Trim()

        $dnsRaw  = (Read-Answer -Indent 4 -Question "DNS servers, separated by commas" `
                                -Notes "For example: 192.168.1.1, 8.8.8.8" `
                                -Default "automatic").Trim()
        $dnsServers = @()
        if (-not [string]::IsNullOrWhiteSpace($dnsRaw)) {
            $dnsServers = @($dnsRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        }

        $nicConfigs += [PSCustomObject]@{
            AdapterName = $adapterName
            CIDR        = $cidr
            Gateway     = $gateway
            DnsServers  = $dnsServers
        }
        Write-Log "NIC defined: $adapterName | IP: $cidr | GW: $(if ($gateway) { $gateway } else { 'none' }) | DNS: $(if ($dnsServers.Count) { $dnsServers -join ', ' } else { 'automatic' })"

        $moreInput = Read-Answer -Indent 4 -Question "Set up another adapter? (Y / N)" `
                                 -Default "N -- that is all of them"
        $addAnother = $moreInput -match '^[Yy]'
    }
}

# ============================================================
# PROMPT - USER ACCOUNTS
# ============================================================
Write-Section "USER ACCOUNTS" -Part 3 -Of 5
Write-Host ""
Write-Host "  These accounts are already on this computer. Every one of them is" -ForegroundColor White
Write-Host "  kept exactly as it is, with its password, profile and settings, on" -ForegroundColor White
Write-Host "  the computers built from this image." -ForegroundColor White
Write-Host ""

# Read the accounts off this computer and show them, so that the answers below
# are given against what is actually here rather than from memory. Read only:
# nothing in this block changes an account.
#
# Passwords are deliberately absent, and cannot be added. Windows keeps only a
# one-way hash of a password, so there is nothing for any script to read back.
# What the account prompts do instead is check a password that is typed in, so a
# wrong one is caught here instead of on a computer built from this image.
$adminMembers = @()
$adminKnown   = $false
try {
    $adminMembers = @(Get-LocalGroupMember -Group "Administrators" -ErrorAction Stop |
                      ForEach-Object { ($_.Name -split '\\')[-1] })
    $adminKnown = $true
} catch {
    Write-Log "Could not read the Administrators group: $($_.Exception.Message)" "WARN"
}

$localAccounts = @()
try { $localAccounts = @(Get-LocalUser -ErrorAction Stop) }
catch { Write-Log "Could not read the local account list: $($_.Exception.Message)" "WARN" }

$fmt = "    {0,-20} {1,-8} {2,-14} {3,-11} {4}"
if ($localAccounts.Count -eq 0) {
    Write-Host "    (Windows would not give us the account list on this computer)" -ForegroundColor Yellow
} else {
    Write-Host ($fmt -f "ACCOUNT", "STATE", "ROLE", "PW SET", "NOTE") -ForegroundColor Gray
    foreach ($la in ($localAccounts | Sort-Object @{Expression={-not $_.Enabled}}, Name)) {
        $state = if ($la.Enabled) { "enabled" } else { "OFF" }
        $role  = if (-not $adminKnown)                  { "unknown" }
                 elseif ($adminMembers -contains $la.Name) { "Administrator" }
                 else                                    { "Standard" }
        # PasswordLastSet, not PasswordRequired: the latter is Windows' flag for
        # whether a password is INSISTED upon, and reads as "this account has no
        # password" when it means nothing of the kind.
        $pwSet = if ($la.PasswordLastSet) { $la.PasswordLastSet.ToString('yyyy-MM-dd') } else { "never" }
        $note  = ""
        switch -Regex ($la.SID.Value) {
            '-500$' { $note = "built-in Administrator, see below" }
            '-501$' { $note = "built-in Guest" }
            '-503$' { $note = "built-in Default Account" }
            '-504$' { $note = "built-in for Application Guard" }
        }
        Write-Host ($fmt -f $la.Name, $state, $role, $pwSet, $note) `
                   -ForegroundColor $(if ($la.Enabled) { "White" } else { "DarkGray" })
        Write-Log ("Existing account: {0} | {1} | {2} | password last set {3} | password-required flag {4}{5}" -f `
                   $la.Name, $state, $role, $pwSet,
                   $(if ($la.PasswordRequired) { "yes" } else { "no" }),
                   $(if ($note) { " | $note" } else { "" })) -Quiet
    }
    Write-Host ""
    Write-Host "  PW SET is when that account's password was last changed, so a date" -ForegroundColor Gray
    Write-Host "  there means the account has one and 'never' means it has none. The" -ForegroundColor Gray
    Write-Host "  passwords themselves cannot be shown: Windows keeps only a one-way" -ForegroundColor Gray
    Write-Host "  hash of them, so nothing can read them back." -ForegroundColor Gray
    if ($localAccounts | Where-Object { $_.SID.Value -match '-500$' -and $_.Enabled }) {
        Write-Host ""
        Write-Host "  Note on the built-in Administrator account: Windows switches that" -ForegroundColor Yellow
        Write-Host "  one off again at the end of the first start, so it will not be" -ForegroundColor Yellow
        Write-Host "  available on the computers built from this image. If it is the" -ForegroundColor Yellow
        Write-Host "  only administrator here, add a named administrator account before" -ForegroundColor Yellow
        Write-Host "  going on, or those computers will have no administrator." -ForegroundColor Yellow
    }
}
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Yellow
Write-Host "   THE ANSWER TO THE NEXT QUESTION IS ALMOST ALWAYS 0" -ForegroundColor Yellow
Write-Host "  ============================================================" -ForegroundColor Yellow

$userCount = -1
while ($userCount -lt 0) {
    $raw = (Read-Answer -Question "How many NEW accounts to add?" `
                        -Notes "0 keeps exactly the accounts listed above, and adds nothing.", `
                               "Answer this only for an EXTRA account that is NOT in that list.", `
                               "Typing a name that is already in the list breaks the first start of", `
                               "every computer built from this image." `
                        -Default "0 -- no new accounts").Trim()
    if ($raw -eq "") {
        $userCount = 0
    } elseif ($raw -match '^\d+$') {
        $userCount = [int]$raw
    } else {
        Write-Host "  Please enter a number, or press Enter for none." -ForegroundColor Yellow
    }
}

$users = @()
$autoLogonEveryBoot = $false
for ($i = 1; $i -le $userCount; $i++) {
    Write-Host ""
    Write-Host "  --- User $i of $userCount ---" -ForegroundColor Cyan

    # A name that is already on this computer is refused here rather than
    # written into the answer file. That is the exact failure the section above
    # warns about: Windows is asked to create an account it already has, and the
    # first start stops with "Windows could not complete the installation" -- on
    # a finished computer, long after this script has run. Checking it while the
    # person who knows the answer is still sitting here costs nothing.
    #
    # Windows account names are case-insensitive, and so is -contains, so
    # "Operator" is correctly caught against an existing "operator".
    $username = ""
    while ([string]::IsNullOrWhiteSpace($username)) {
        $username = (Read-Answer -Indent 4 -Question "Username for this new account" `
                                 -Notes "It must not be a name already listed above.").Trim()
        if ([string]::IsNullOrWhiteSpace($username)) { continue }

        $clash = $null
        if (@($localAccounts).Count -gt 0 -and (@($localAccounts).Name -contains $username)) {
            $clash = "is already an account on this computer"
        } elseif (@($users).Count -gt 0 -and (@($users).Username -contains $username)) {
            $clash = "was already entered a moment ago, for another new account"
        }

        if ($clash) {
            Write-Host ""
            Write-Host "    '$username' $clash." -ForegroundColor Red
            Write-Host ""
            Write-Host "    Accounts that are already here are kept as they are, so this" -ForegroundColor Yellow
            Write-Host "    script must not create them a second time." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "    Enter a different name for the NEW account, or press Ctrl+C and" -ForegroundColor Yellow
            Write-Host "    run this again answering 0, if you did not mean to add one." -ForegroundColor Yellow
            Write-Host ""
            Write-Log "Refused account name '$username': $clash" "WARN"
            $username = ""
        }
    }

    $displayName = (Read-Answer -Indent 4 -Question "Display name, as it appears on the sign in screen" `
                                -Default "the username, $username").Trim()
    if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $username }

    # Typed twice and compared. A new account's password cannot be checked
    # against anything, so a typo here would quietly become the real password on
    # every computer built from this image, and nobody would find out until one
    # of them refused to sign in.
    $password = ""
    while ($true) {
        $password = (Read-Answer -Indent 4 -Secret -Question "Password for this account" `
                                 -Notes "What you type is shown on screen." `
                                 -Default "no password at all").Trim()
        if ($password -eq "") {
            Write-Host "    No password set. Anyone will be able to sign in to this account." -ForegroundColor Yellow
            break
        }
        $passwordAgain = (Read-Answer -Indent 4 -Secret `
                                      -Question "Type the same password again, so a typo is caught here").Trim()
        if ($password -eq $passwordAgain) {
            Write-Host "    The two match." -ForegroundColor Green
            break
        }
        Write-Host "    Those two are not the same. Please enter it again." -ForegroundColor Yellow
    }

    $isAdmin = $false
    $adminInput = Read-Answer -Indent 4 -Question "Should this account be an administrator? (Y / N)" `
                              -Default "N -- an ordinary account"
    if ($adminInput -match '^[Yy]') { $isAdmin = $true }

    $isAutoLogon = $false
    if ($i -eq 1 -and $userCount -ge 1) {
        $autoInput = Read-Answer -Indent 4 -Question "Sign in as this account automatically, with nobody typing a password? (Y / N)" `
                                 -Default "N -- ask for the password"
        if ($autoInput -match '^[Yy]') {
            $isAutoLogon = $true
            $everyInput = Read-Answer -Indent 4 -Question "Sign in automatically every time the computer starts? (Y / N)" `
                                      -Notes "N does it only the first time, then asks for the password after that." `
                                      -Default "Y -- every time"
            $autoLogonEveryBoot = -not ($everyInput -match '^[Nn]')
        }
    }

    $hasPassword = $password -ne ""
    $users += [PSCustomObject]@{
        Username    = $username
        DisplayName = $displayName
        Password    = $password
        IsAdmin     = $isAdmin
        IsAutoLogon = $isAutoLogon
    }

    Write-Log "User defined: $username | Admin: $isAdmin | Password: $(if ($hasPassword) { 'set' } else { 'none' }) | AutoLogon: $isAutoLogon$(if ($isAutoLogon) { " (every boot: $autoLogonEveryBoot)" })"
}

# Auto-logon to an EXISTING account, for images whose accounts are already set
# up on this computer. Only offered when none of the accounts created above has
# already claimed it. The account is checked against this computer as it is
# typed in, because a name or password that is wrong here produces an image
# whose computers stop at the sign in screen, which is not discoverable until
# one is deployed.
if (-not ($users | Where-Object { $_.IsAutoLogon })) {
    Write-Host ""
    Write-Host "  One of the accounts already on this computer can sign in on its" -ForegroundColor White
    Write-Host "  own, with nobody typing a password." -ForegroundColor White
    Write-Host ""
    $exAuto = Read-Answer -Question "Sign in automatically as an account already on this computer? (Y / N)" `
                          -Default "N -- no automatic sign in"
    if ($exAuto -match '^[Yy]') {

        $exName = ""
        while ($exName -eq "") {
            $exName = (Read-Answer -Indent 4 -Question "Which account? Type the username" `
                                   -Notes "One of the names in the list above.").Trim()
            if ($exName -eq "") { continue }

            $exUser = $null
            try { $exUser = Get-LocalUser -Name $exName -ErrorAction Stop } catch { }

            if (-not $exUser) {
                Write-Host "    There is no account called '$exName' on this computer." -ForegroundColor Yellow
                Write-Host "    Pick one of the names from the list above." -ForegroundColor Gray
                $exName = ""
            } elseif (-not $exUser.Enabled) {
                Write-Host "    '$exName' is switched off, so it cannot sign in." -ForegroundColor Yellow
                $exName = ""
            } elseif ($exUser.SID.Value -match '-500$') {
                # Windows switches the built-in Administrator back off at the end
                # of the first start, so automatic sign in as it cannot work on a
                # computer built from this image.
                Write-Host "    '$exName' is Windows' own built-in Administrator account, and" -ForegroundColor Yellow
                Write-Host "    Windows switches that one off again at the end of the first" -ForegroundColor Yellow
                Write-Host "    start. It cannot sign in by itself on the computers built" -ForegroundColor Yellow
                Write-Host "    from this image. Please pick a different account." -ForegroundColor Yellow
                $exName = ""
            }
        }

        # Check the password against Windows now. A blank one is not checked:
        # Windows refuses blank-password logons of this kind by default even when
        # the password really is blank, so the check would report a false alarm.
        $exPass = ""
        while ($true) {
            $exPass = (Read-Answer -Indent 4 -Secret -Question "That account's password" `
                                   -Notes "What you type is shown on screen, and is checked against Windows before going on." `
                                   -Default "it has no password").Trim()
            if ($exPass -eq "") {
                # The account list above shows when each password was last set, so
                # a blank answer for an account that demonstrably has one is almost
                # always a slip. Left wrong it is not discoverable until a finished
                # computer sits at the sign in screen instead of signing itself in.
                if ($exUser -and $exUser.PasswordLastSet) {
                    Write-Host ""
                    Write-Host "    '$exName' does have a password -- it was last set on" -ForegroundColor Yellow
                    Write-Host "    $($exUser.PasswordLastSet.ToString('yyyy-MM-dd'))." -ForegroundColor Yellow
                    Write-Host "    Left blank, the computers built from this image stop at the" -ForegroundColor Yellow
                    Write-Host "    sign in screen instead of signing in on their own." -ForegroundColor Yellow
                    $blankOk = Read-Answer -Indent 4 -Question "Leave it blank anyway? (Y / N)" `
                                           -Default "N -- let me type the password"
                    if (-not ($blankOk -match '^[Yy]')) { continue }
                    Write-Log "Auto-logon password for '$exName' left blank although the account has one." "WARN"
                }
                break
            }
            $pwOk = $null
            try {
                Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction Stop
                $pwCtx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext 'Machine'
                $pwOk  = $pwCtx.ValidateCredentials($exName, $exPass)
                $pwCtx.Dispose()
            } catch {
                # Could not check. Carry on rather than block on our own limitation.
                Write-Log "Could not check the password for '$exName': $($_.Exception.Message)" "WARN"
            }
            if ($pwOk -eq $false) {
                Write-Host "    Windows did not accept that password for '$exName'." -ForegroundColor Yellow
                Write-Host "    Left wrong, the computers built from this image stop at the" -ForegroundColor Yellow
                Write-Host "    sign in screen instead of signing in on their own." -ForegroundColor Yellow
                $again = Read-Answer -Indent 4 -Question "Type it again? (Y / N)" `
                                     -Notes "N keeps the password as you typed it, wrong or not." `
                                     -Default "Y -- let me try again"
                if ($again -match '^[Nn]') {
                    Write-Log "Auto-logon password for '$exName' was not accepted and was kept anyway." "WARN"
                    break
                }
                continue
            }
            if ($pwOk -eq $true) { Write-Host "    Password checked, Windows accepted it." -ForegroundColor Green }
            break
        }

        $everyInput = Read-Answer -Indent 4 -Question "Sign in automatically every time the computer starts? (Y / N)" `
                                  -Notes "N does it only the first time, then asks for the password after that." `
                                  -Default "Y -- every time"
        $autoLogonEveryBoot = -not ($everyInput -match '^[Nn]')
        $existingAutoUser = [PSCustomObject]@{ Username = $exName; Password = $exPass }
        Write-Log "Auto-logon to existing account: $exName (every boot: $autoLogonEveryBoot, password $(if ($exPass) { 'given' } else { 'blank' }))"
    } else {
        Write-Log "No auto-logon to an existing account."
    }
}

# ============================================================
# PROMPT - FIRST START EXPERIENCE
# ============================================================
Write-Section "FIRST START" -Part 4 -Of 5
Write-Host ""
Write-Host "  What should happen the first time one of these computers is" -ForegroundColor White
Write-Host "  switched on by the person who will be using it?" -ForegroundColor White
Write-Host ""
Write-Host "    1  Nothing to answer. It goes straight to the desktop, using the" -ForegroundColor White
Write-Host "       accounts and settings you have entered here. (recommended)" -ForegroundColor Gray
Write-Host ""
Write-Host "    2  The same as 1, except it asks for the time zone once, at the" -ForegroundColor White
Write-Host "       first sign in. The question can be skipped, and skipping it" -ForegroundColor Gray
Write-Host "       keeps whichever time zone you set in the next section." -ForegroundColor Gray
Write-Host ""
Write-Host "    3  It asks for country, keyboard and network first, then goes to" -ForegroundColor White
Write-Host "       the desktop using your accounts. The country answer is what" -ForegroundColor Gray
Write-Host "       sets the time zone." -ForegroundColor Gray
Write-Host ""
Write-Host "  None of the three asks for an account. The accounts you have" -ForegroundColor Gray
Write-Host "  already set up are the ones the computers come up with." -ForegroundColor Gray
Write-Host ""

# There is deliberately no fourth option offering the whole Windows first time
# setup. That is the one path that asks the person switching the computer on to
# create an account of their own, and images built with this kit already carry
# the accounts the customer wants, either named in this script or already
# present on the computer being captured. An extra account appearing on every
# deployed computer is not an acceptable outcome, so the account pages stay off
# in every option above. Do not add such an option back.
$oobeMode = 0
while ($oobeMode -lt 1 -or $oobeMode -gt 3) {
    $rawMode = (Read-Answer -Question "Choose 1, 2 or 3" `
                            -Default "1 -- straight to the desktop, nothing to answer").Trim()
    if ($rawMode -eq "")               { $oobeMode = 1 }
    elseif ($rawMode -match '^[1-3]$') { $oobeMode = [int]$rawMode }
    else { Write-Host "  Please enter 1, 2 or 3." -ForegroundColor Yellow }
}

Write-Log "First start experience: option $oobeMode"

# ============================================================
# PROMPT - SYSTEM OPTIONS
# ============================================================
Write-Section "OTHER OPTIONS" -Part 5 -Of 5
Write-Host ""
Write-Host "  All three are optional. Press Enter to leave any of them alone." -ForegroundColor White
Write-Host ""

$disableWifi = (Read-Answer -Question "Turn Wi-Fi off completely on these computers? (Y / N)" `
                            -Default "N -- leave Wi-Fi as it is") -match '^[Yy]'
$disableWU   = (Read-Answer -Question "Turn Windows Update off on these computers? (Y / N)" `
                            -Default "N -- leave Windows Update as it is") -match '^[Yy]'
if ($oobeMode -eq 3) {
    Write-Host ""
    Write-Host "  The time zone below is only a starting point on option 3: the" -ForegroundColor Gray
    Write-Host "  country answered during the first time setup replaces it." -ForegroundColor Gray
    Write-Host ""
}
# Whatever is typed here goes straight into <TimeZone> in the answer file, and
# Windows wants the exact name from its own list ("Eastern Standard Time", not
# "EST" or "Eastern"). A name it does not recognise is not reported anywhere the
# customer would ever see it: the computers built from the image just come up on
# the wrong time zone. So it is checked here, against this computer's own list,
# while there is still somebody sitting in front of it to correct it.
$tzIds = @()
try { $tzIds = @([System.TimeZoneInfo]::GetSystemTimeZones() | ForEach-Object { $_.Id }) } catch { }
if ($tzIds.Count -eq 0) {
    try { $tzIds = @((& tzutil /l) | Where-Object { $_ -match '^[A-Za-z]' }) } catch { }
}
$tzCurrent = ""
try { $tzCurrent = [System.TimeZoneInfo]::Local.Id } catch { }

$timeZone = ""
while ($true) {
    $tzTyped = (Read-Answer -Question "Time zone" `
                            -Notes "The Windows name for it, for example: Eastern Standard Time", `
                                   "Type a question mark to list the names this computer knows." `
                            -Default $(if ($tzCurrent) { "$tzCurrent, the one this computer is on now" } else { "the time zone this computer is on now" })).Trim()

    if ($tzTyped -eq "") { break }

    if ($tzTyped -eq "?") {
        Write-Host ""
        foreach ($z in ($tzIds | Sort-Object)) { Write-Host "    $z" -ForegroundColor Gray }
        continue
    }

    if ($tzIds.Count -eq 0) {
        # Could not read the list at all. Take the answer rather than block on
        # our own limitation, and say plainly that it was not checked.
        $timeZone = $tzTyped
        Write-Log "Time zone '$tzTyped' could not be checked -- this computer would not give up its time zone list." "WARN"
        break
    }

    $exact = @($tzIds | Where-Object { $_ -ieq $tzTyped })
    if ($exact.Count -ge 1) {
        $timeZone = $exact[0]   # canonical spelling from Windows' own list
        break
    }

    Write-Host ""
    Write-Host "  Windows has no time zone called '$tzTyped'." -ForegroundColor Yellow
    $near = @($tzIds | Where-Object { $_ -like "*$tzTyped*" } | Sort-Object | Select-Object -First 10)
    if ($near.Count -gt 0) {
        Write-Host "  Did you mean one of these? Type it exactly as shown." -ForegroundColor Yellow
        foreach ($n in $near) { Write-Host "    $n" -ForegroundColor Gray }
    } else {
        Write-Host "  Type a question mark to see the whole list, or press Enter to" -ForegroundColor Yellow
        Write-Host "  leave the time zone as this computer has it now." -ForegroundColor Yellow
    }
}

Write-Log "Disable Wi-Fi: $disableWifi | Disable Windows Update: $disableWU | TimeZone: $(if ($timeZone) { $timeZone } else { 'unchanged' })"

# ============================================================
# WINDOWS PRODUCT KEY
# ============================================================
# Not asked for, deliberately. Windows licensing for the computers built from
# this image is arranged by your supplier, and a key entered here would be applied to
# every one of them. Your answer file is written without one, which is correct.
Write-Log "No product key prompt: Windows licensing is arranged by your supplier."
# ============================================================
# GENERATE UNATTEND.XML
# ============================================================
Write-Section "GENERATING UNATTEND.XML"

# Build TCPIP / DNS-Client XML blocks for specialize pass
$tcpipXml = ""
$dnsXml   = ""
$firstLogonCommandsXml = ""
if ($nicConfigs.Count -gt 0) {
    $ifacesTcpip  = ""
    $ifacesDns    = ""
    $flcCommands  = ""
    $flcOrder     = 1

    foreach ($nic in $nicConfigs) {
        $safeAdapter = [System.Security.SecurityElement]::Escape($nic.AdapterName)
        # Split CIDR back into IP and prefix for netsh
        $ipOnly = $nic.CIDR -replace '/\d+$', ''
        $mask   = $maskInput  # reuse last entered mask; each nic has its own but we store prefix only -- recalc
        # Recalculate dotted mask from prefix
        $prefix    = [int]($nic.CIDR -replace '^.+/', '')
        $maskInt   = if ($prefix -gt 0) { [uint32]([math]::Pow(2,32) - [math]::Pow(2, 32 - $prefix)) } else { 0 }
        $maskBytes = [System.BitConverter]::GetBytes($maskInt)
        [System.Array]::Reverse($maskBytes)
        $dotMask   = $maskBytes -join '.'

        $routesXml = ""
        if (-not [string]::IsNullOrWhiteSpace($nic.Gateway)) {
            $safeGw = [System.Security.SecurityElement]::Escape($nic.Gateway)
            $routesXml = @"

                        <Routes>
                            <Route wcm:action="add">
                                <Identifier>0</Identifier>
                                <Prefix>0.0.0.0/0</Prefix>
                                <NextHopAddress>$safeGw</NextHopAddress>
                            </Route>
                        </Routes>
"@
        }

        # TCPIP interface -- Ipv4Settings required to reliably disable DHCP
        $ifacesTcpip += @"

                <Interface wcm:action="add">
                    <Ipv4Settings>
                        <DhcpEnabled>false</DhcpEnabled>
                        <RouterDiscoveryEnabled>false</RouterDiscoveryEnabled>
                    </Ipv4Settings>
                    <Identifier>$safeAdapter</Identifier>
                    <UnicastIpAddresses>
                        <IpAddress wcm:action="add" wcm:keyValue="1">$($nic.CIDR)</IpAddress>
                    </UnicastIpAddresses>$routesXml
                </Interface>
"@

        # DNS-Client block (only if DNS servers specified)
        if ($nic.DnsServers.Count -gt 0) {
            $dnsAddrs = ""
            $kv = 1
            foreach ($dns in $nic.DnsServers) {
                $safeDns = [System.Security.SecurityElement]::Escape($dns)
                $dnsAddrs += "                        <IpAddress wcm:action=`"add`" wcm:keyValue=`"$kv`">$safeDns</IpAddress>`n"
                $kv++
            }
            $ifacesDns += @"

                <Interface wcm:action="add">
                    <Identifier>$safeAdapter</Identifier>
                    <DNSServerSearchOrder>
$dnsAddrs                    </DNSServerSearchOrder>
                </Interface>
"@
        }

        # FirstLogonCommands -- netsh enforces the static IP at first boot as a backstop
        $gwArg = if ($nic.Gateway) { $nic.Gateway } else { "none" }
        $flcCommands += @"
                <SynchronousCommand wcm:action="add">
                    <CommandLine>netsh interface ip set address &quot;$($nic.AdapterName)&quot; static $ipOnly $dotMask $gwArg</CommandLine>
                    <Description>Set static IP on $($nic.AdapterName)</Description>
                    <Order>$flcOrder</Order>
                </SynchronousCommand>
"@
        $flcOrder++

        if ($nic.DnsServers.Count -gt 0) {
            $primaryDns = $nic.DnsServers[0]
            $flcCommands += @"
                <SynchronousCommand wcm:action="add">
                    <CommandLine>netsh interface ip set dns &quot;$($nic.AdapterName)&quot; static $primaryDns</CommandLine>
                    <Description>Set primary DNS on $($nic.AdapterName)</Description>
                    <Order>$flcOrder</Order>
                </SynchronousCommand>
"@
            $flcOrder++
            for ($di = 1; $di -lt $nic.DnsServers.Count; $di++) {
                $flcCommands += @"
                <SynchronousCommand wcm:action="add">
                    <CommandLine>netsh interface ip add dns &quot;$($nic.AdapterName)&quot; $($nic.DnsServers[$di]) index=$($di + 1)</CommandLine>
                    <Description>Add DNS $($di+1) on $($nic.AdapterName)</Description>
                    <Order>$flcOrder</Order>
                </SynchronousCommand>
"@
                $flcOrder++
            }
        } else {
            $flcCommands += @"
                <SynchronousCommand wcm:action="add">
                    <CommandLine>netsh interface ip set dns &quot;$($nic.AdapterName)&quot; static none</CommandLine>
                    <Description>Clear DNS on $($nic.AdapterName)</Description>
                    <Order>$flcOrder</Order>
                </SynchronousCommand>
"@
            $flcOrder++
        }

        $flcCommands += @"
                <SynchronousCommand wcm:action="add">
                    <CommandLine>powershell -Command &quot;Set-NetIPInterface -InterfaceAlias '$($nic.AdapterName)' -Dhcp Disabled&quot;</CommandLine>
                    <Description>Disable DHCP on $($nic.AdapterName)</Description>
                    <Order>$flcOrder</Order>
                </SynchronousCommand>
"@
        $flcOrder++
    }

    $tcpipXml = @"

        <!-- Static IP configuration -->
        <component name="Microsoft-Windows-TCPIP"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral"
                   versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <Interfaces>$ifacesTcpip
            </Interfaces>
        </component>
"@

    if ($ifacesDns) {
        $dnsXml = @"

        <!-- DNS configuration -->
        <component name="Microsoft-Windows-DNS-Client"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral"
                   versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <Interfaces>$ifacesDns
            </Interfaces>
        </component>
"@
    }

    $firstLogonCommandsXml = @"

            <FirstLogonCommands>
$flcCommands            </FirstLogonCommands>
"@
}

# ============================================================
# Build specialize-pass RunSynchronous commands. These run as SYSTEM before
# any logon, so they work even when the auto-logon user is a standard account
# (the FirstLogonCommands netsh backstop runs as that user and would fail).
$runSyncCommands = ""
$rsOrder = 1

foreach ($nic in $nicConfigs) {
    $rsIp     = $nic.CIDR -replace '/\d+$', ''
    $rsPrefix = [int]($nic.CIDR -replace '^.+/', '')
    $rsMaskInt   = if ($rsPrefix -gt 0) { [uint32]([math]::Pow(2,32) - [math]::Pow(2, 32 - $rsPrefix)) } else { 0 }
    $rsMaskBytes = [System.BitConverter]::GetBytes($rsMaskInt)
    [System.Array]::Reverse($rsMaskBytes)
    $rsMask = $rsMaskBytes -join '.'
    $rsGw   = if ($nic.Gateway) { " $($nic.Gateway)" } else { "" }

    $runSyncCommands += @"

                <RunSynchronousCommand wcm:action="add">
                    <Order>$rsOrder</Order>
                    <Description>Set static IP on $($nic.AdapterName)</Description>
                    <Path>netsh interface ipv4 set address name="$($nic.AdapterName)" static $rsIp $rsMask$rsGw</Path>
                </RunSynchronousCommand>
"@
    $rsOrder++

    if ($nic.DnsServers.Count -gt 0) {
        $runSyncCommands += @"

                <RunSynchronousCommand wcm:action="add">
                    <Order>$rsOrder</Order>
                    <Description>Set DNS on $($nic.AdapterName)</Description>
                    <Path>netsh interface ipv4 set dns name="$($nic.AdapterName)" static $($nic.DnsServers[0]) primary</Path>
                </RunSynchronousCommand>
"@
        $rsOrder++
    }
}

if ($disableWifi) {
    $runSyncCommands += @"

                <RunSynchronousCommand wcm:action="add">
                    <Order>$rsOrder</Order>
                    <Description>Disable all Wi-Fi adapters</Description>
                    <Path>powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-NetAdapter -Physical | Where-Object { `$_.PhysicalMediaType -match '802.11' -or `$_.Name -like '*Wi-Fi*' -or `$_.InterfaceDescription -match 'Wireless|WLAN' } | Disable-NetAdapter -Confirm:`$false"</Path>
                </RunSynchronousCommand>
"@
    $rsOrder++
    $runSyncCommands += @"

                <RunSynchronousCommand wcm:action="add">
                    <Order>$rsOrder</Order>
                    <Description>Disable WLAN AutoConfig service</Description>
                    <Path>cmd /c sc config wlansvc start= disabled &amp; sc stop wlansvc</Path>
                </RunSynchronousCommand>
"@
    $rsOrder++
}

if ($disableWU) {
    $runSyncCommands += @"

                <RunSynchronousCommand wcm:action="add">
                    <Order>$rsOrder</Order>
                    <Description>Disable automatic Windows Update (policy)</Description>
                    <Path>cmd /c reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
"@
    $rsOrder++
    $runSyncCommands += @"

                <RunSynchronousCommand wcm:action="add">
                    <Order>$rsOrder</Order>
                    <Description>Disable Windows Update service</Description>
                    <Path>cmd /c sc config wuauserv start= disabled &amp; sc stop wuauserv</Path>
                </RunSynchronousCommand>
"@
    $rsOrder++
}


if ($oobeMode -eq 2) {
    # Ask for the time zone once, at the first sign in. Registered here rather
    # than acted on here: this command runs on each computer built from the
    # image, not on this one. RunOnce deletes its own entry before running it,
    # so the question is asked once and never comes back. Setting the time zone
    # does not need an administrator in Windows, so it works whichever account
    # signs in first.
    $runSyncCommands += @"

                <RunSynchronousCommand wcm:action="add">
                    <Order>$rsOrder</Order>
                    <Description>Ask for the time zone at the first sign in</Description>
                    <Path>cmd /c reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v TOASTTimeZone /t REG_SZ /d "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\toast-timezone.ps1" /f</Path>
                </RunSynchronousCommand>
"@
    $rsOrder++
}

# Resolve the auto-logon user here (needed for the registry fallback below).
# Winlogon silently IGNORES an unattend <AutoLogon> block whose password is
# blank (confirmed on a customer unit 2026-07-14) -- for blank-password
# accounts, autologon must be set via registry instead, and DefaultPassword
# must EXIST as an empty REG_SZ or AutoAdminLogon is ignored too.
$autoLogonUser = $users | Where-Object { $_.IsAutoLogon } | Select-Object -First 1
if (-not $autoLogonUser) { $autoLogonUser = $existingAutoUser }
$autoLogonViaRegistry = ($null -ne $autoLogonUser) -and ($autoLogonUser.Password -eq "")

if ($autoLogonViaRegistry) {
    $safeRegUser = [System.Security.SecurityElement]::Escape(($autoLogonUser.Username -replace '"', ''))
    $runSyncCommands += @"

                <RunSynchronousCommand wcm:action="add">
                    <Order>$rsOrder</Order>
                    <Description>Enable auto-logon via registry (blank password)</Description>
                    <Path>cmd /c reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 1 /f &amp; reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultUserName /t REG_SZ /d "$safeRegUser" /f &amp; reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /t REG_SZ /f</Path>
                </RunSynchronousCommand>
"@
    $rsOrder++

    if (-not $autoLogonEveryBoot) {
        # First boot only: Winlogon decrements AutoLogonCount on each auto-logon
        # and disables AutoAdminLogon when it reaches 0.
        $runSyncCommands += @"

                <RunSynchronousCommand wcm:action="add">
                    <Order>$rsOrder</Order>
                    <Description>Limit auto-logon to first boot</Description>
                    <Path>cmd /c reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoLogonCount /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
"@
        $rsOrder++
    }
    Write-Log "Auto-logon for '$($autoLogonUser.Username)' will be set via registry (blank password -- unattend AutoLogon is ignored by Winlogon for blank passwords)."
}

if ($productKey) {
    # Register the helper as a SYSTEM task rather than running activation here:
    # this command executes during specialize on the DEPLOYED unit, and the work
    # has to outlive that pass (wait for network, retry across boots). SYSTEM
    # rather than FirstLogonCommands/RunOnce because slmgr /cpky needs elevation
    # and the auto-logon account may be a standard user.
    $runSyncCommands += @"

                <RunSynchronousCommand wcm:action="add">
                    <Order>$rsOrder</Order>
                    <Description>Register TOAST activation + product key cleanup task</Description>
                    <Path>cmd /c schtasks /Create /TN "TOAST-Activate" /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Windows\Setup\Scripts\toast-activate.ps1" /SC ONSTART /DELAY 0001:00 /RU SYSTEM /RL HIGHEST /F &amp; exit /b 0</Path>
                </RunSynchronousCommand>
"@
    $rsOrder++
}

$deploymentXml = ""
if ($runSyncCommands) {
    $deploymentXml = @"

        <!-- Machine config commands (SYSTEM context, before first logon) -->
        <component name="Microsoft-Windows-Deployment"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral"
                   versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <RunSynchronous>$runSyncCommands
            </RunSynchronous>
        </component>
"@
}

$timeZoneXml = ""
if ($timeZone) {
    $timeZoneXml = "`n            <TimeZone>$([System.Security.SecurityElement]::Escape($timeZone))</TimeZone>"
}

# Build LocalAccounts XML block
$localAccountsXml = ""
foreach ($user in $users) {
    $group = if ($user.IsAdmin) { "Administrators" } else { "Users" }
    # Encode password per Windows unattend spec: Base64(UTF-16LE(password + "Password"))
    $encodedPass = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($user.Password + "Password")
    )
    $safeName    = [System.Security.SecurityElement]::Escape($user.Username)
    $safeDisplay = [System.Security.SecurityElement]::Escape($user.DisplayName)

    $localAccountsXml += @"

                    <LocalAccount wcm:action="add">
                        <Password>
                            <Value>$encodedPass</Value>
                            <PlainText>false</PlainText>
                        </Password>
                        <DisplayName>$safeDisplay</DisplayName>
                        <Group>$group</Group>
                        <Name>$safeName</Name>
                    </LocalAccount>
"@
}

# Wrap in UserAccounts section if any users defined.
#
# The account creation page is switched off whether or not accounts are named
# above. Entering 0 accounts means the accounts the customer wants are already
# on the computer being captured, so there is still nothing for the people
# switching these computers on to create, and being asked to create one would
# leave a stray extra account on every computer built from the image.
# SkipUserOOBE also skips that page, but it is a deprecated setting that newer
# versions of Windows may ignore, so the page is switched off directly too.
$userAccountsSection = ""
$hideLocalAccountScreen = "true"
if ($localAccountsXml) {
    $userAccountsSection = @"

            <UserAccounts>
                <LocalAccounts>$localAccountsXml
                </LocalAccounts>
            </UserAccounts>
"@
}

# Build AutoLogon block -- only for accounts WITH a password. Blank-password
# autologon is handled by the specialize-pass registry commands above.
$autoLogonSection = ""
if ($autoLogonUser -and -not $autoLogonViaRegistry) {
    $encodedAutoPass = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($autoLogonUser.Password + "AutoLogonPassword")
    )
    $safeAutoName = [System.Security.SecurityElement]::Escape($autoLogonUser.Username)
    $autoLogonCount = if ($autoLogonEveryBoot) { 9999 } else { 1 }
    $autoLogonSection = @"

            <AutoLogon>
                <Password>
                    <Value>$encodedAutoPass</Value>
                    <PlainText>false</PlainText>
                </Password>
                <Enabled>true</Enabled>
                <LogonCount>$autoLogonCount</LogonCount>
                <Username>$safeAutoName</Username>
            </AutoLogon>
"@
}


# ------------------------------------------------------------------
# Build the OOBE block from the first start choice above.
#   1 / 2  every first start question suppressed
#   3      country, keyboard, network and licence shown, then the accounts
#          defined above sign in. The user side stays suppressed both by
#          SkipUserOOBE and by the individual Hide switches, because
#          SkipUserOOBE is deprecated and may be ignored on newer builds.
# Every option keeps HideLocalAccountScreen and HideOnlineAccountScreens on, so
# no option can ask for an account. See the note by $hideLocalAccountScreen.
# The element order below is the order the Windows answer file schema expects.
# Do not reorder it.
# ------------------------------------------------------------------
switch ($oobeMode) {
    3 {
        $oobeSettingsXml = @"
                <HideEULAPage>false</HideEULAPage>
                <HideLocalAccountScreen>$hideLocalAccountScreen</HideLocalAccountScreen>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>false</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>3</ProtectYourPC>
                <SkipMachineOOBE>false</SkipMachineOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
"@
    }
    default {
        $oobeSettingsXml = @"
                <HideEULAPage>true</HideEULAPage>
                <HideLocalAccountScreen>$hideLocalAccountScreen</HideLocalAccountScreen>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>3</ProtectYourPC>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
"@
    }
}

# Language, keyboard and region. Naming these forces them, which also takes
# away the pages that ask for them, so options 3 and 4 leave the whole
# component out and let Windows ask. The image is built en-US either way, so
# that stays the default it offers.
$internationalXml = ""
if ($oobeMode -le 2) {
    $internationalXml = @"

        <component name="Microsoft-Windows-International-Core"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral"
                   versionScope="nonSxS">
            <InputLocale>en-US</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UserLocale>en-US</UserLocale>
        </component>
"@
}

$unattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">

    <!-- SPECIALIZE: copy configured admin profile into Default User -->
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral"
                   versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <CopyProfile>true</CopyProfile>
            <ComputerName>*</ComputerName>$timeZoneXml$productKeyXml
        </component>$tcpipXml$dnsXml$deploymentXml
    </settings>

    <!-- OOBE: first start questions per the choice above, local accounts -->
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral"
                   versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">

            <OOBE>
$oobeSettingsXml            </OOBE>
$userAccountsSection$autoLogonSection$firstLogonCommandsXml
        </component>$internationalXml
    </settings>

</unattend>
"@

} # end if (-not $reuseUnattend) -- prompts + unattend generation
# Save the answers to the USB stick, beside the config the capture step reads.
$unattendSharePath = Join-Path $ConfigFolder "unattend.xml"
[System.IO.File]::WriteAllText($unattendSharePath, $unattendXml, [System.Text.UTF8Encoding]::new($false))
Write-Log "Answers saved to the USB drive: $unattendSharePath" "OK"

# Copy locally for sysprep
[System.IO.File]::WriteAllText($LocalUnattend, $unattendXml, [System.Text.UTF8Encoding]::new($false))
Write-Log "Unattend copied to: $LocalUnattend" "OK"
# ============================================================
# CONFIRM THE ANSWER FILE IS KEYLESS
# ============================================================
# This script has no product key prompt, so a key can only appear in the answer
# file if that file was edited by hand. A key here would be applied to every
# computer built from the image, so it needs a person to look at it rather than
# be guessed at. Stop instead of continuing.
$embeddedKeyTail = ""
$keyMatch = [regex]::Match($unattendXml, '<ProductKey>\s*([A-Z0-9]{5}(?:-[A-Z0-9]{5}){4})\s*</ProductKey>')
if ($keyMatch.Success) {
    Stop-Kit -Reason "The saved answer file on this USB drive contains a Windows product key. The customer kit must not carry one." `
             -WhatToDo "Contact your supplier before going any further -- quote 'capture kit: product key in unattend'."
}
Write-Log "Answer file is keyless, as it must be on the customer kit." "OK"
# ============================================================
# FIRST START TIME ZONE QUESTION
# ============================================================
# Gated on the finished answer file, so it covers both a fresh run that just
# asked for this and a repeat run whose saved answers on the USB drive already
# ask for it. The file goes under C:\Windows\Setup\Scripts so that it is
# captured with the image and is present on every computer built from it.
if ($unattendXml -match 'toast-timezone\.ps1') {
    $tzScriptDir  = Join-Path $env:SystemRoot "Setup\Scripts"
    $tzScriptPath = Join-Path $tzScriptDir "toast-timezone.ps1"
    New-Item -ItemType Directory -Path $tzScriptDir -Force | Out-Null

    $tzHelper = @'
# TOAST: ask for the time zone at the first sign in.
#
# The answer file registers this under RunOnce, so Windows runs it once, at the
# first sign in on each computer built from the image, and then removes its own
# entry. Doing nothing, or pressing K, keeps the time zone the image carries.
#
# Setting the time zone is allowed for ordinary accounts in Windows, so this
# does not need to run as an administrator.

$ErrorActionPreference = "Continue"
$logPath = Join-Path $env:SystemRoot "Setup\Scripts\toast-timezone.log"
function W($m) {
    try {
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" |
            Out-File -FilePath $logPath -Append -Encoding utf8
    } catch { }
}

try {
    try { $Host.UI.RawUI.WindowTitle = "Time zone" } catch { }

    $zones = New-Object System.Collections.Specialized.OrderedDictionary
    $zones.Add("1", @("Eastern",                                "Eastern Standard Time"))
    $zones.Add("2", @("Central",                                "Central Standard Time"))
    $zones.Add("3", @("Mountain",                               "Mountain Standard Time"))
    $zones.Add("4", @("Arizona (Mountain, no daylight saving)", "US Mountain Standard Time"))
    $zones.Add("5", @("Pacific",                                "Pacific Standard Time"))
    $zones.Add("6", @("Alaska",                                 "Alaskan Standard Time"))
    $zones.Add("7", @("Hawaii",                                 "Hawaiian Standard Time"))

    $current = ""
    try { $current = ((& tzutil /g) -join "").Trim() } catch { }
    if ($current -eq "") { $current = "(could not be read)" }
    W "Started. Current time zone: $current"

    Write-Host ""
    Write-Host "  ==========================================================="
    Write-Host "   TIME ZONE"
    Write-Host "  ==========================================================="
    Write-Host ""
    Write-Host "   This computer is set to: $current"
    Write-Host ""
    foreach ($k in $zones.Keys) {
        Write-Host ("     {0}   {1}" -f $k, $zones[$k][0])
    }
    Write-Host ""
    Write-Host "     L   show the full list of time zones"
    Write-Host "     K   keep the setting above and carry on"
    Write-Host ""
    Write-Host "   This is only asked once. The time zone can be changed at any"
    Write-Host "   time in Settings, under Time and language."
    Write-Host ""

    $valid    = @("1","2","3","4","5","6","7","L","K")
    $deadline = (Get-Date).AddSeconds(90)
    $choice   = ""
    try { while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) } } catch { }

    while ((Get-Date) -lt $deadline) {
        $left = [int][math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
        Write-Host ("`r   Your answer, or wait {0,3} seconds to keep it as it is:  " -f $left) -NoNewline
        $key = ""
        try {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true).KeyChar.ToString().ToUpper()
            }
        } catch {
            # No console to read from. Leave the time zone alone.
            W "No console input available. Time zone left at: $current"
            break
        }
        if ($key -eq "") { Start-Sleep -Milliseconds 250; continue }
        if ($valid -contains $key) { $choice = $key; break }
    }
    Write-Host ""

    $target = ""
    if ($choice -eq "L") {
        Write-Host ""
        Write-Host "   Note the name you want, spelled exactly as it appears, then"
        Write-Host "   type it in at the end of the list."
        Write-Host ""
        try { & tzutil /l | Out-Host -Paging } catch { & tzutil /l }
        Write-Host ""
        $typed = (Read-Host "   Time zone name (Enter to keep it as it is)").Trim()
        if ($typed -ne "") { $target = $typed }
    } elseif ($zones.Contains($choice)) {
        $target = $zones[$choice][1]
    }

    if ($target -eq "") {
        W "No change requested (answer: '$choice'). Time zone left at: $current"
        Write-Host "   Left as it is: $current"
    } else {
        & tzutil /s "$target" 2>&1 | Out-Null
        $now = ""
        try { $now = ((& tzutil /g) -join "").Trim() } catch { }
        if ($now -like "$target*") {
            W "Time zone set to: $now"
            Write-Host "   Time zone set to: $now"
        } else {
            W "Could not set '$target'. Time zone is still: $now"
            Write-Host "   That name was not recognised, so the time zone is still $now."
            Write-Host "   It can be changed in Settings, under Time and language."
        }
    }

    Write-Host ""
    Write-Host "   Carrying on in 5 seconds."
    Start-Sleep -Seconds 5
} catch {
    # Never let this hold up the first sign in.
    W "Stopped on an error: $($_.Exception.Message)"
}
'@

    [System.IO.File]::WriteAllText($tzScriptPath, $tzHelper, [System.Text.UTF8Encoding]::new($false))
    Write-Log "First start time zone question installed: $tzScriptPath" "OK"
}

# ============================================================
# STEP 1 - BYPASS NRO (required for local accounts on Win11)
# ============================================================
Write-Section "STEP 1 - BYPASS NRO"
# Everything above this line only read the computer and asked questions. From
# here on it is being changed, and the messages about what state it has been
# left in have to say so.
$script:MachineChanged = $true
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f | Out-Null
Write-Log "BypassNRO set (required for local account OOBE on Windows 11)." "OK"

# ============================================================
# STEP 2 - REMOVE BLOAT / SYSPREP-BLOCKING PACKAGES
# ============================================================
Write-Section "STEP 2 - REMOVE BLOAT PACKAGES"
Write-Log "Removing the preinstalled apps that stop Windows preparing an image..."
# Each package name goes to the log only. Printing thirty of them scrolls the
# screen for no benefit -- the count below is what a person actually needs.
$appxRemoved = 0

$blocklist = @(
    "*Ink.Handwriting*",
    "*WidgetsPlatformRuntime*",
    "*LanguageExperiencePack*",
    "*Teams*",
    "*XboxGamingOverlay*",
    "*XboxApp*",
    "*GamingApp*",
    "*GamingServices*",
    "*YourPhone*",
    "*PhoneLink*",
    "*Todos*",
    "*BingSearch*",
    "*BingNews*",
    "*BingWeather*",
    "*Clipchamp*",
    "*Copilot*",
    "*DevHome*",
    "*ContentDeliveryManager*",
    "*WindowsFeedbackHub*",
    "*MixedReality*",
    "*3DViewer*",
    "*GetHelp*",
    "*Getstarted*",
    "*ZuneMusic*",
    "*ZuneVideo*",
    "*Solitaire*",
    "*ScreenSketch*",
    "*MicrosoftOfficeHub*",
    "*PowerAutomateDesktop*",
    "*Whiteboard*"
)

foreach ($app in $blocklist) {
    # Skip NonRemovable packages. The removal cannot succeed (0x80070032) and the
    # failed attempt still strips the package's provisioning, which is how an app
    # that was fine becomes a sysprep blocker nothing can then clear.
    $packages = Get-AppxPackage -AllUsers | Where-Object { $_.Name -like $app -and -not $_.NonRemovable }
    foreach ($pkg in $packages) {
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction SilentlyContinue 2>&1 | Out-Null
            Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction SilentlyContinue 2>&1 | Out-Null
            Write-Log "Removed: $($pkg.PackageFullName)" -Quiet
            $appxRemoved++
        } catch {
            Write-Log "Could not remove $($pkg.PackageFullName): $_" "WARN"
        }
    }

    $provPkgs = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like $app }
    foreach ($pkg in $provPkgs) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction SilentlyContinue 2>&1 | Out-Null
            Write-Log "Removed provisioned: $($pkg.PackageName)" -Quiet
            $appxRemoved++
        } catch {
            Write-Log "Could not remove provisioned $($pkg.PackageName): $_" "WARN"
        }
    }
}

Write-Log "App cleanup complete -- $appxRemoved package(s) removed (each one is named in the log)." "OK"

# ============================================================
# STEP 2B - REMOVE UNPROVISIONED APPX PACKAGES
# ============================================================
# Sysprep /generalize fails (0x80073cf2) on any app that is installed for a
# user but not provisioned for all users (e.g. Microsoft.StartExperiencesApp
# on Win11 25H2, seen 2026-07-14). This removes every such package -- it is
# exactly the condition AppxSysprep.dll validates before generalize.
Write-Section "STEP 2B - REMOVE UNPROVISIONED APPX PACKAGES"
Write-Log "Scanning for per-user apps not provisioned for all users..."

$unprovisioned = @(Get-SysprepBlockingAppx)
# Why each removal failed, keyed by package name. Surfaced next to the name in
# the final check, so the reason is on the screen the customer is looking at
# and in the log, instead of only in an exception nobody reads.
$script:AppxRemovalErrors = @{}

if ($unprovisioned.Count -eq 0) {
    Write-Log "No unprovisioned per-user apps found." "OK"
} else {
    foreach ($pkg in $unprovisioned) {
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop | Out-Null
            Write-Log "Removed unprovisioned: $($pkg.PackageFullName)" -Quiet
        } catch {
            Write-Log "Direct removal failed for $($pkg.PackageFullName): $_" "WARN"
            # Package may be flagged NonRemovable -- clear the flag and retry
            dism /Online /Set-NonRemovableAppPolicy /PackageFamily:"$($pkg.PackageFamilyName)" /NonRemovable:0 2>&1 | Out-Null
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop | Out-Null
                Write-Log "Removed after clearing NonRemovable flag: $($pkg.PackageFullName)" -Quiet
            } catch {
                Write-Log "Could not remove $($pkg.PackageFullName): $_" "WARN"
                $msg  = ($_.Exception.Message -replace '\s+', ' ')
                $code = if ($msg -match '(0x[0-9A-Fa-f]{8})') { $Matches[1] } else { "" }
                $why  = switch -Regex ($msg) {
                    '0x80070032|0x80073CFA|part of Windows' { "part of Windows, cannot be uninstalled" ; break }
                    '0x80073D02|in use'                     { "in use by a running program"           ; break }
                    '0x80073CF1|not found'                  { "already gone for this user"            ; break }
                    default                                 { if ($code) { "removal refused ($code)" } else { "removal refused" } }
                }
                $script:AppxRemovalErrors[$pkg.Name] = $why
            }
        }
    }

    # Verify -- anything listed here WILL fail sysprep generalize validation.
    # Re-queries provisioning instead of reusing the list from before the loop:
    # a failed removal changes a package's provisioning state as a side effect.
    $stillPresent = @(Get-SysprepBlockingAppx)
    if ($stillPresent.Count -gt 0) {
        foreach ($pkg in $stillPresent) {
            Write-Log "STILL PRESENT (will block sysprep): $($pkg.PackageFullName)" "ERROR"
        }
    } else {
        Write-Log "All unprovisioned per-user apps removed." "OK"
    }
}

# ============================================================
# STEP 3 - VERIFY INK.HANDWRITING REMOVED
# ============================================================
Write-Section "STEP 3 - VERIFY INK.HANDWRITING"
Write-Log "Checking for remaining Ink.Handwriting packages..."

$remaining = Get-AppxPackage -AllUsers | Where-Object { $_.Name -like "*Ink.Handwriting*" }
if ($remaining) {
    Write-Log "Ink.Handwriting still present - attempting DISM removal..." "WARN"
    foreach ($pkg in $remaining) {
        dism /Online /Remove-ProvisionedAppxPackage /PackageName:"$($pkg.PackageFullName)" 2>&1 | Out-Null
        Write-Log "DISM removal attempted: $($pkg.PackageFullName)" -Quiet
    }
} else {
    Write-Log "Ink.Handwriting confirmed removed." "OK"
}

# ============================================================
# STEP 4 - CLEAR SYSPREP CACHE
# ============================================================
Write-Section "STEP 4 - CLEAR SYSPREP CACHE"
Write-Log "Clearing Sysprep Panther cache..."
try {
    Remove-Item "C:\Windows\System32\Sysprep\Panther" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Sysprep cache cleared." "OK"
} catch {
    Write-Log "Could not clear Sysprep cache: $_" "WARN"
}

# ============================================================
# STEP 5 - DISABLE RESERVED STORAGE
# ============================================================
Write-Section "STEP 5 - DISABLE RESERVED STORAGE"
Write-Log "Stopping Windows Update while the disk is prepared..."
foreach ($svc in @('wuauserv','UsoSvc','dosvc','bits','TrustedInstaller')) {
    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
    Write-Log "Stopped: $svc" -Quiet
}
Start-Sleep -Seconds 5

Write-Log "Clearing Windows Update download cache..."
Remove-Item -Path "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "C:\Windows\SoftwareDistribution\DataStore\*" -Recurse -Force -ErrorAction SilentlyContinue
Write-Log "Download cache cleared." "OK"

# Reserved storage arrived in Windows 10 1903 (build 18362). On anything older,
# IoT Enterprise LTSC 2019 included, these DISM options do not exist and return
# error 87, which reads like a real failure in the log. Skip them instead.
$reservedOff = $false
if ($osBuild -lt 18362) {
    Write-Log "Reserved storage is not a feature of build $osBuild; nothing to disable." "OK"
    $reservedOff = $true
} else {
    Write-Log "Disabling Windows Reserved Storage..."
    $dismOut = & DISM.exe /Online /Set-ReservedStorageState /State:Disabled 2>&1
    Write-Log "DISM set result: $($dismOut -join ' | ')" -Quiet

    $dismCheckOut = & DISM.exe /Online /Get-ReservedStorageState 2>&1
    Write-Log "DISM get result: $($dismCheckOut -join ' | ')" -Quiet

    # DISM's own wording, one line, rather than its whole banner.
    if (($dismCheckOut -join ' ') -match 'Reserved storage is disabled') {
        Write-Log "Reserved storage is disabled." "OK"
        $reservedOff = $true
    } else {
        Write-Log "DISM did not confirm reserved storage is disabled -- see the log." "WARN"
    }
}

Write-Log "ReserveManager registry state:" -Quiet
$rmPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager"
try {
    (Get-Item -Path $rmPath -ErrorAction SilentlyContinue).GetValueNames() | ForEach-Object {
        Write-Log "  $_ = $((Get-ItemProperty -Path $rmPath -Name $_).$_)" -Quiet
    }
} catch { Write-Log "  Could not read ReserveManager key." "WARN" }

Write-Log "Zeroing all ReserveManager values..." -Quiet
try {
    (Get-Item -Path $rmPath -ErrorAction SilentlyContinue).GetValueNames() | ForEach-Object {
        Set-ItemProperty -Path $rmPath -Name $_ -Value 0 -Force -ErrorAction SilentlyContinue
    }
} catch {}
Write-Log "ReserveManager values zeroed." "OK"

# Belt and braces only. Disabling reserved storage with DISM is what actually
# satisfies sysprep; this node is the fallback for when that did not work.
# Cleanup.xml is owned by TrustedInstaller, so even an elevated admin gets
# "Access to the path is denied" on save. Taking ownership of a Windows file
# that then ships inside the captured image is not worth it for a check that
# has already passed, so only try when there is something left to fix.
if ($reservedOff) {
    Write-Log "Reserved storage is off, so the Cleanup.xml fallback is not needed." -Quiet
} else {
Write-Log "Reserved storage is still on -- trying the sysprep Cleanup.xml fallback..."
$cleanupPath = "C:\Windows\System32\Sysprep\ActionFiles\Cleanup.xml"
try {
    [xml]$xml = Get-Content $cleanupPath -Raw
    $nodes = @($xml.SelectNodes("//*[@name='Sysprep_Clean_Validate_Opk' or @methodName='Sysprep_Clean_Validate_Opk']"))
    if ($nodes.Count -gt 0) {
        foreach ($node in $nodes) { $node.ParentNode.RemoveChild($node) | Out-Null }
        $xml.Save($cleanupPath)
        Write-Log "Removed $($nodes.Count) reserved storage validation node(s) from Cleanup.xml." "OK"
    } else {
        Write-Log "Sysprep_Clean_Validate_Opk not found in Cleanup.xml -- already patched or structure differs." "WARN"
    }
} catch {
    Write-Log "Could not modify Cleanup.xml (it is owned by TrustedInstaller): $_" "WARN"
}
}


# ============================================================
# FINAL GATE - ANYTHING LEFT THAT WOULD FAIL SYSPREP
# ============================================================
# STEP 5B - TOUCH KEYBOARD DEFAULTS (TRT RUGGED TABLETS ONLY)
# ============================================================
# Not prompted: it applies itself on TRT rugged tablets running IoT Enterprise and
# is skipped everywhere else. The whole TRT line is a tablet with no physical
# keyboard, so the touch keyboard has to work out of the box.
#
# Gated on the EDITION as well as the model, deliberately. The same settings would
# be wanted on a Pro TRT, but Pro units are not ours to configure: the Settings UI
# works there, so leave it to whoever owns the unit. On IoT the Settings page is
# unreachable when Windows is unactivated, which is why this exists.
#
# The per-user half is written into the DEFAULT profile, not the current one.
# Sysprep discards the profile it was run under, so anything set in HKCU is lost;
# every new profile is copied from C:\Users\Default, so that is where a setting
# has to be to reach the units built from this image.
Write-Section "STEP 5B - TOUCH KEYBOARD DEFAULTS"

$tkModel = ""
try { $tkModel = (Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop).Name.Trim() } catch {}
if (-not $tkModel) {
    try { $tkModel = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Model.Trim() } catch {}
}
Write-Log "Model reported as: $(if ($tkModel) { $tkModel } else { 'not reported' })"

# EditionID is the reliable read: IoTEnterprise, IoTEnterpriseS (LTSC), against
# Professional. The Caption is a fallback for a build that does not set it.
$tkEdition = ""
try {
    $tkEdition = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" `
                  -Name EditionID -ErrorAction Stop).EditionID
} catch {}
if (-not $tkEdition) {
    try { $tkEdition = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch {}
}
Write-Log "Edition reported as: $(if ($tkEdition) { $tkEdition } else { 'not reported' })"

if ($tkModel -notmatch '^TRT-') {
    Write-Log "Not a TRT rugged tablet; touch keyboard defaults skipped." "OK"
} elseif ($tkEdition -notmatch 'IoT') {
    Write-Log "TRT tablet but the edition is not IoT Enterprise; touch keyboard defaults skipped." "OK"
} else {
    Write-Log "TRT rugged tablet on IoT Enterprise; applying touch keyboard defaults."

    # Machine-wide. ConvertibleSlateMode is the posture the shell reads: 0 means
    # slate, and while it reads 1 the touch keyboard will not appear on its own
    # whatever else is set.
    $tkMachine = @(
        @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl"; Name = "ConvertibleSlateMode"; Value = 0 }
        @{ Path = "HKLM:\SOFTWARE\Microsoft\TabletTip\1.7";                 Name = "EnableDesktopModeAutoInvoke"; Value = 1 }
    )
    foreach ($tkItem in $tkMachine) {
        try {
            if (-not (Test-Path $tkItem.Path)) { New-Item -Path $tkItem.Path -Force -ErrorAction Stop | Out-Null }
            Set-ItemProperty -Path $tkItem.Path -Name $tkItem.Name -Value $tkItem.Value -Type DWord -ErrorAction Stop
            Write-Log "Set $($tkItem.Name) = $($tkItem.Value)" "OK"
        } catch {
            Write-Log "Could not set $($tkItem.Name): $_" "WARN"
        }
    }

    # Default profile. reg.exe rather than the registry provider: the provider
    # leaves handles open on a loaded hive, the unload then fails, NTUSER.DAT
    # stays locked and sysprep dies on it.
    $tkHive = "C:\Users\Default\NTUSER.DAT"
    $tkMount = "HKU\TOASTTouchKb"
    if (-not (Test-Path -LiteralPath $tkHive)) {
        Write-Log "Default profile hive not found at $tkHive; per-user defaults skipped." "WARN"
    } else {
        $tkLoaded = $false
        try {
            & reg.exe load $tkMount $tkHive 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "reg load returned $LASTEXITCODE" }
            $tkLoaded = $true
            foreach ($tkPair in @(@{ N = "TipbandDesiredVisibility"; V = 1 },
                                  @{ N = "EnableDesktopModeAutoInvoke"; V = 1 },
                                  @{ N = "TouchKeyboardTapInvoke"; V = 2 })) {
                & reg.exe add "$tkMount\SOFTWARE\Microsoft\TabletTip\1.7" /v $tkPair.N `
                          /t REG_DWORD /d $tkPair.V /f 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { Write-Log "Default profile: $($tkPair.N) = $($tkPair.V)" "OK" }
                else { Write-Log "Default profile: could not set $($tkPair.N)" "WARN" }
            }
        } catch {
            Write-Log "Could not load the default profile hive: $_" "WARN"
        } finally {
            if ($tkLoaded) {
                [System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers()
                & reg.exe unload $tkMount 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "Default profile hive unloaded." "OK"
                } else {
                    Write-Log "DEFAULT PROFILE HIVE STILL LOADED. Run 'reg unload $tkMount' before sysprep or sysprep will fail." "ERROR"
                }
            }
        }
    }

    # Windows recalculates ConvertibleSlateMode on dock and undock events and no
    # permission prevents it, so the value above does not hold on its own.
    try {
        $tkAction = New-ScheduledTaskAction -Execute "reg.exe" -Argument (
            'add "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" ' +
            '/v ConvertibleSlateMode /t REG_DWORD /d 0 /f')
        $tkTrigger = New-ScheduledTaskTrigger -AtStartup
        $tkPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
        Register-ScheduledTask -TaskName "TOAST-TouchKeyboard-Posture" -Action $tkAction `
                               -Trigger $tkTrigger -Principal $tkPrincipal -Force -ErrorAction Stop | Out-Null
        Write-Log "Registered boot task TOAST-TouchKeyboard-Posture." "OK"
    } catch {
        Write-Log "Could not register the posture boot task: $_" "WARN"
    }

    Write-Log "Touch keyboard defaults applied." "OK"
}

# ============================================================
# STEP 2B above removes the per-user apps that break generalize. If any survived,
# sysprep fails with 0x80073cf2 and leaves the machine in a state the customer
# cannot recover from. Stop here instead -- nothing irreversible has happened yet.
Write-Section "FINAL CHECK BEFORE PREPARING THE IMAGE"

# This used to be a hard stop. It warns and carries on now, on purpose, and it
# asks the customer nothing: the check is a PREDICTION of what Windows will
# refuse, and it is not always right in either direction. A unit that has been
# online collects Store-updated and Edge-delivered apps we have never seen, and
# stopping a customer dead over a prediction is how a build gets abandoned for
# something that would have worked.
#
# Carrying on is safe because Windows validates apps at the START of preparing
# the image, before it changes anything, so a refusal leaves the computer working
# normally -- measured, GeneralizationState stayed 7 on the lab VM 2026-09-18.
#
# THIS LIST IS NOT THE LAST WORD. A NonRemovable package is excluded from it
# (attempting removal is what breaks such a package) and sysprep still refuses
# over one, so this can be empty and sysprep fail anyway. That is why the failure
# path at the end of this script reads the blamed package out of setupact.log
# rather than reusing this list.
$stillBlocking = @(Get-SysprepBlockingAppx)
$script:AppxGateOverridden = $false
if ($stillBlocking.Count -gt 0) {
    foreach ($pkg in $stillBlocking) { Write-Log "Installed for one user only: $($pkg.PackageFullName)" "WARN" }
    Write-Host ""
    Write-Host "  These app(s) are installed for one user only:" -ForegroundColor Yellow
    Write-Host ""
    foreach ($pkg in $stillBlocking) {
        $why = $script:AppxRemovalErrors[$pkg.Name]
        if ($why) {
            Write-Host ("      " + $pkg.Name + "  --  " + $why) -ForegroundColor White
            Write-Log  ("Blocking: " + $pkg.PackageFullName + " (" + $why + ")") "WARN"
        } else {
            Write-Host ("      " + $pkg.Name) -ForegroundColor White
            Write-Log  ("Blocking: " + $pkg.PackageFullName) "WARN"
        }
    }
    Write-Host ""
    Write-Host "  Windows may refuse to prepare the image while they are installed."  -ForegroundColor Yellow
    Write-Host "  Preparing the image will be attempted anyway."                      -ForegroundColor White
    Write-Host ""
    Write-Host "  If it is refused, these can usually be uninstalled from"             -ForegroundColor White
    Write-Host "  Settings > Apps > Installed apps, and this can then be run again."   -ForegroundColor White
    Write-Host ""
    Start-Sleep -Seconds 8
    $script:AppxGateOverridden = $true
    Write-Log "Continuing past the app check with $($stillBlocking.Count) app(s) outstanding." "WARN"
} else {
    Write-Log "Nothing left that would block image preparation." "OK"
}

# ============================================================
# WRITE capture.conf - THE HANDOFF TO THE CAPTURE STEP
# ============================================================
# This is the only thing that tells Clonezilla which disk to image. It is
# written last on purpose: if anything above stopped the run, there is no
# capture.conf on the stick and booting the USB refuses cleanly rather than
# capturing a machine that was never generalized.
Write-Section "WRITING THE CAPTURE INSTRUCTIONS TO THE USB DRIVE"

# The identifier stored ON the disk itself: GPT disk GUID, or the MBR disk
# signature for a legacy install. Windows and Linux read the same bytes for
# these with no controller in the path, which is why this is the primary key and
# the vendor serial is only a fallback -- see the comment in ocs-prerun.sh.
$diskId     = ""
$diskIdKind = ""
if ($sysDisk.PartitionStyle -eq 'GPT' -and $sysDisk.Guid) {
    $diskId     = $sysDisk.Guid.Trim('{','}').ToLower()
    $diskIdKind = "gpt-guid"
} elseif ($sysDisk.PartitionStyle -eq 'MBR' -and $sysDisk.Signature) {
    # blkid reports the MBR signature as the little-endian 32-bit value in hex,
    # which is the same number Get-Disk reports in Signature.
    $diskId     = ('{0:x8}' -f [uint32]$sysDisk.Signature)
    $diskIdKind = "mbr-signature"
}
$diskSerial = ""
if ($sysDisk.SerialNumber) { $diskSerial = $sysDisk.SerialNumber.Trim() }
$diskModel  = ""
if ($sysDisk.FriendlyName) { $diskModel = $sysDisk.FriendlyName.Trim() }

if (-not $diskId -and -not $diskSerial) {
    Stop-Kit -Reason "Could not read an identifier for the disk Windows is installed on (partition style $($sysDisk.PartitionStyle))." `
             -WhatToDo "Contact your supplier -- without it the capture step cannot tell which disk to copy, and it will not guess."
}
Write-Log "Disk identifier: $diskIdKind = $(if ($diskId) { $diskId } else { 'none' }) | serial = $(if ($diskSerial) { $diskSerial } else { 'none' })"

# Written with UNIX line endings and every value single-quoted. Both matter: the
# capture script reads this file as shell input, so a CR would end up inside the
# image directory name, and an unquoted value with a space in it (disk models
# routinely have one) would be read as a command to run.
function ConvertTo-ShellValue {
    param([string]$Text)
    return "'" + (($Text -replace "'", "") -replace "[`r`n]", " ") + "'"
}
$captureConfPath = Join-Path $ConfigFolder "capture.conf"
$captureLines = @(
    "# Written by Prepare-Sysprep-USB.ps1 -- read by ocs-prerun.sh."
    "IMAGE_NAME=$(ConvertTo-ShellValue $imageName)"
    "DISK_ID=$(ConvertTo-ShellValue $diskId)"
    "DISK_ID_KIND=$(ConvertTo-ShellValue $diskIdKind)"
    "DISK_SERIAL=$(ConvertTo-ShellValue $diskSerial)"
    "DISK_MODEL=$(ConvertTo-ShellValue $diskModel)"
    "USED_BYTES=$(ConvertTo-ShellValue $usedBytes)"
    "CUSTOMER=$(ConvertTo-ShellValue $customerName)"
    "IMAGE_VERSION=$(ConvertTo-ShellValue $imageVersion)"
    "MODEL=$(ConvertTo-ShellValue $modelName)"
    "UNIT_SERIAL=$(ConvertTo-ShellValue $serialNumber)"
    "CREATED=$(ConvertTo-ShellValue (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'))"
    "KIT_VERSION=$(ConvertTo-ShellValue $KitVersion)"
)
[System.IO.File]::WriteAllText($captureConfPath, (($captureLines -join "`n") + "`n"),
                               [System.Text.UTF8Encoding]::new($false))
Write-Log "Capture instructions written: $captureConfPath" "OK"



# ============================================================
# LAST CHANCE TO STOP
# ============================================================
Write-Section "READY TO PREPARE THE IMAGE"

Write-Host ""
Write-Host "  Company  : $customerName" -ForegroundColor White
Write-Host "  Model    : $modelName" -ForegroundColor White
Write-Host "  Image     : $imageName" -ForegroundColor White
Write-Host "  Saved to : $unattendSharePath" -ForegroundColor White
Write-Host "  Disk     : $diskModel ($(Format-Size $sysDisk.Size), $(Format-Size $usedBytes) in use)" -ForegroundColor White
if ($reuseUnattend) {
    Write-Host "  Settings : reused from the earlier run on this kit" -ForegroundColor White
    Write-Host "             (all settings come from that file -- the questions were skipped)" -ForegroundColor Gray
} else {
Write-Host "  Accounts : $($users.Count) to be created on first start" -ForegroundColor White
if ($nicConfigs.Count -gt 0) {
    foreach ($nic in $nicConfigs) {
        $gwStr  = if ($nic.Gateway)                 { " | gateway $($nic.Gateway)" }             else { "" }
        $dnsStr = if ($nic.DnsServers.Count -gt 0)  { " | DNS $($nic.DnsServers -join ', ')" }   else { " | DNS automatic" }
        Write-Host "  Network  : $($nic.AdapterName) -- $($nic.CIDR)$gwStr$dnsStr" -ForegroundColor White
    }
} else {
    Write-Host "  Network  : automatic (DHCP)" -ForegroundColor Gray
}
$autoUser = $users | Where-Object { $_.IsAutoLogon } | Select-Object -First 1
if (-not $autoUser) { $autoUser = $existingAutoUser }
if ($autoUser) {
    Write-Host "  Sign-in  : automatic as $($autoUser.Username) ($(if ($autoLogonEveryBoot) { 'every start' } else { 'first start only' }))" -ForegroundColor White
}
$oobeLabel = switch ($oobeMode) {
    2       { "straight to the desktop, asks for the time zone once" }
    3       { "asks for country, keyboard and network first" }
    default { "straight to the desktop, nothing to answer" }
}
Write-Host "  1st start: $oobeLabel" -ForegroundColor White
Write-Host "  Wi-Fi    : $(if ($disableWifi) { 'turned off' } else { 'left as it is' })" -ForegroundColor White
Write-Host "  Updates  : $(if ($disableWU) { 'turned off' } else { 'left as it is' })" -ForegroundColor White
if ($timeZone) {
    $tzNote = ""
    if     ($oobeMode -eq 2) { $tzNote = " (can be changed at the first sign in)" }
    elseif ($oobeMode -eq 3) { $tzNote = " (replaced by the country answered at first start)" }
    Write-Host "  Time zone: $timeZone$tzNote" -ForegroundColor White
} elseif ($oobeMode -eq 2) {
    Write-Host "  Time zone: asked for at the first sign in" -ForegroundColor White
}
} # end summary branch (reused vs prompted)

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host "  READ THIS BEFORE CONTINUING" -ForegroundColor Yellow
Write-Host ("=" * 60) -ForegroundColor Yellow
Write-Host ""
Write-Host "  This computer is about to be prepared for imaging and will then" -ForegroundColor White
Write-Host "  SHUT ITSELF DOWN. That is normal and means it worked." -ForegroundColor White
Write-Host ""
Write-Host "  When it is off:" -ForegroundColor White
Write-Host ""
Write-Host "    DO NOT just switch it back on." -ForegroundColor Red
Write-Host "    Switch it on and BOOT FROM THE USB DRIVE." -ForegroundColor Green
Write-Host ""
Write-Host "  Letting Windows start first undoes the preparation, and everything" -ForegroundColor White
Write-Host "  from here has to be done over. The printed sheet that came with the" -ForegroundColor White
Write-Host "  kit shows how to boot from the USB drive." -ForegroundColor White
Write-Host ""
Write-Host "  Your programs, files, accounts and settings stay on this computer" -ForegroundColor Gray
Write-Host "  either way. What preparing the image resets is Windows' own first" -ForegroundColor Gray
Write-Host "  start, which then runs again using the answers you have just given." -ForegroundColor Gray
Write-Host ""

$go = Read-Answer -Question "Type GO to prepare the image now" `
                  -Notes "Anything else, including Enter, cancels and leaves Windows able to start normally."
if ($go.Trim().ToUpper() -ne "GO") {
    Write-Log "Customer cancelled at the final prompt. Sysprep was not run; the preparation steps that had already run were left in place." "WARN"
    # The instructions are on the stick but the machine was never generalized.
    # Remove them, or booting the USB would capture a live, non-generalized unit.
    Remove-Item -LiteralPath $captureConfPath -Force -ErrorAction SilentlyContinue
    Write-Log "Capture instructions removed." "OK"
    Copy-LogToStick
    Write-Host ""
    Write-Host "  Cancelled. The image was NOT prepared, and Windows starts normally" -ForegroundColor Yellow
    Write-Host "  the next time this computer is switched on." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Getting this far removed some of the preinstalled Windows apps and" -ForegroundColor White
    Write-Host "  changed a few Windows settings. Your own files, programs, accounts" -ForegroundColor White
    Write-Host "  and settings were not touched." -ForegroundColor White
    Write-Host ""
    Write-Host "  Run Run-Toast-Prep.cmd again whenever you are ready." -ForegroundColor Yellow
    Write-Host ""
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 0
}

Write-Host ""
Write-Log "Log saved to: $LogFile"
Copy-LogToStick
Write-Section "PREPARING THE IMAGE - THE COMPUTER WILL SHUT DOWN WHEN THIS FINISHES"
Write-Host ""
Write-Host "  Remember: switch it back on and BOOT FROM THE USB DRIVE." -ForegroundColor Green
Write-Host ""
Start-Sleep -Seconds 5

& "C:\Windows\System32\Sysprep\sysprep.exe" /generalize /oobe /shutdown /unattend:$LocalUnattend
$syspremExit = $LASTEXITCODE

# ============================================================
# SYSPREP FAILED IF WE ARE STILL HERE
# ============================================================
# sysprep was asked to /shutdown, so a successful run never returns to this
# line -- the computer is already off. Reaching it at all means it refused,
# whatever the exit code says.
#
# The important part is removing capture.conf. It was written before sysprep,
# and it is the only thing that tells the USB drive to capture. Left behind
# after a failure, the customer follows the instructions, boots the USB and
# captures a machine that was never generalized -- an image carrying their own
# accounts, machine name and SIDs, which is useless to us and theirs to keep.
Write-Log "sysprep returned instead of shutting down; exit code $syspremExit." "ERROR"

try {
    if ($captureConfPath -and (Test-Path $captureConfPath)) {
        Remove-Item $captureConfPath -Force -ErrorAction Stop
        Write-Log "Removed capture.conf so the USB drive cannot capture a machine that was not prepared." "OK"
    }
} catch {
    Write-Log "COULD NOT remove capture.conf: $_" "ERROR"
}

# Windows own reason, copied next to our log so support gets both.
$panther = "C:\Windows\System32\Sysprep\Panther\setupact.log"
try {
    if (Test-Path $panther) {
        Copy-Item $panther (Join-Path $KitLogFolder "sysprep-setupact.log") -Force -ErrorAction Stop
        Write-Log "Copied Windows own sysprep log to the USB drive." "OK"
        $why = Select-String -Path $panther -Pattern 'was installed for a user', '0x80073cf2' -ErrorAction SilentlyContinue |
               Select-Object -Last 5
        foreach ($line in $why) { Write-Log ("Windows said: " + $line.Line.Trim()) "ERROR" }
    }
} catch {
    Write-Log "Could not copy the sysprep log: $_" "WARN"
}

# Name the package WINDOWS blamed, not the one we predicted. Those are not always
# the same: a package that is part of Windows and refuses removal is deliberately
# left out of our own check (trying to remove it is what breaks it), yet sysprep
# still refuses over it -- confirmed on the lab VM 2026-09-18, where
# Microsoft.SecHealthUI produced 0x80073cf2 on its own. Reading it back out of
# setupact.log is the only account that is always right.
$blamed = @()
try {
    if (Test-Path $panther) {
        $blamed = @(Select-String -Path $panther -Pattern 'Package (\S+) was installed for a user' -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -Unique)
    }
} catch { }
if ($blamed.Count -eq 0 -and $stillBlocking.Count -gt 0) {
    $blamed = @($stillBlocking.PackageFullName)
}
if ($blamed.Count -gt 0) {
    Write-Host ""
    Write-Host "  Windows named these app(s) as the reason:" -ForegroundColor Yellow
    Write-Host ""
    foreach ($b in $blamed) {
        $short = ($b -split '_')[0]
        Write-Host ("      " + $short) -ForegroundColor White
        Write-Log  ("Windows blamed: " + $b) "ERROR"
    }
    Write-Host ""
    Write-Host "  If one of them can be uninstalled from Settings > Apps >"     -ForegroundColor White
    Write-Host "  Installed apps, doing that and running this again is usually" -ForegroundColor White
    Write-Host "  all that is needed. Some are part of Windows and cannot be"   -ForegroundColor White
    Write-Host "  uninstalled; send us the logs folder from the USB drive and"  -ForegroundColor White
    Write-Host "  we will take it from there."                                  -ForegroundColor White
}
Stop-Kit -Reason "Windows refused to prepare the image, so this computer was NOT prepared and no image can be captured." `
         -WhatToDo "Switch it on again and it will start normally. Nothing on it has been damaged."
