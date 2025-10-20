# Run from admin host PowerShell (Run as Administrator).
# Target IP prefilled for you: 192.168.56.11
$targetIP = "192.168.56.11"

function FailExit($msg) {
    Write-Host "[ERROR] $msg" -ForegroundColor Red
    exit 1
}

Write-Host "Target IP: $targetIP" -ForegroundColor Cyan
Write-Host "You will be prompted for admin credentials for the target ($targetIP)." -ForegroundColor Yellow
$cred = Get-Credential -Message "Enter credentials for $targetIP (must be admin)"

# 1) Network check
Write-Host "`n== Network check ==" -ForegroundColor Cyan
if (-not (Test-Connection -ComputerName $targetIP -Count 2 -Quiet)) {
    FailExit "Ping/Test-Connection to $targetIP failed. Check network or IP."
} else { Write-Host "Ping OK." -ForegroundColor Green }

# 2) Add target to TrustedHosts on this client (adds only the single IP)
try {
    $current = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction SilentlyContinue).Value
} catch { $current = $null }
if ($current) {
    if ($current -notlike "*$targetIP*") { $new = "$current,$targetIP" } else { $new = $current }
} else { $new = $targetIP }
Set-Item WSMan:\localhost\Client\TrustedHosts -Value $new -Force
Write-Host "TrustedHosts updated to: $new" -ForegroundColor Green

# 3) Quick Test-WSMan
Write-Host "`n== WinRM endpoint test ==" -ForegroundColor Cyan
try {
    Test-WSMan -ComputerName $targetIP -ErrorAction Stop
    Write-Host "WinRM endpoint responded." -ForegroundColor Green
} catch {
    Write-Host "Test-WSMan failed. WinRM may not be enabled or firewall blocking. You may need console access to the target to run 'Enable-PSRemoting -Force'." -ForegroundColor Yellow
    # continue to attempt a session; will fail later if WinRM truly down
}

# 4) Create PSSession
Write-Host "`n== Creating PSSession to $targetIP ==" -ForegroundColor Cyan
try {
    $session = New-PSSession -ComputerName $targetIP -Credential $cred -ErrorAction Stop
    Write-Host "PSSession created." -ForegroundColor Green
} catch {
    FailExit "Failed to create PSSession. Error: $($_.Exception.Message)`nIf New-PSSession fails, ensure WinRM is enabled on target (Enable-PSRemoting -Force on the target console) and firewall allows 5985."
}

# 5) Ensure Invoke-AtomicRedTeam module exists on target, install if missing (current user)
Write-Host "`n== Ensure Invoke-AtomicRedTeam on target ==" -ForegroundColor Cyan
$modStatus = Invoke-Command -Session $session -ScriptBlock {
    try {
        Import-Module Invoke-AtomicRedTeam -ErrorAction Stop
        return "MODULE_OK"
    } catch {
        return "MODULE_MISSING"
    }
} -ErrorAction Stop

if ($modStatus -eq "MODULE_OK") {
    Write-Host "Invoke-AtomicRedTeam already available on target." -ForegroundColor Green
} elseif ($modStatus -eq "MODULE_MISSING") {
    Write-Host "Module missing — attempting install on target (CurrentUser scope)..." -ForegroundColor Yellow
    try {
        Invoke-Command -Session $session -ScriptBlock {
            Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            Install-Module -Name Invoke-AtomicRedTeam -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            "INSTALLED_OK"
        } -ErrorAction Stop | ForEach-Object {
            if ($_ -eq "INSTALLED_OK") { Write-Host "Module installed on target." -ForegroundColor Green }
        }
    } catch {
        Write-Host "Could not install module on target. Target may not have internet access to PSGallery. You can still copy atomics or run tests if module is preloaded." -ForegroundColor Yellow
    }
} else {
    Write-Host "Unexpected response checking module: $modStatus" -ForegroundColor Yellow
}

# 6) Retrieve a short list of tests on the target
Write-Host "`n== Fetching a short list of Atomic Tests on target ==" -ForegroundColor Cyan
$tests = Invoke-Command -Session $session -ScriptBlock {
    Import-Module Invoke-AtomicRedTeam -ErrorAction SilentlyContinue
    Get-AtomicTest | Select-Object -Property AtomicID,Title,Description | Select-Object -First 12
} -ErrorAction SilentlyContinue

if (-not $tests) {
    Write-Host "Could not retrieve Atomic test list from target. Either module missing or not functional. You can still run a script manually if you copy it to the target." -ForegroundColor Yellow
    $tests = @()
}

$idx = 0
foreach ($t in $tests) {
    $idx++
    Write-Host "[$idx] $($t.AtomicID) - $($t.Title)"
}

if ($tests.Count -eq 0) {
    Write-Host "`nNo tests listed. You can still run specific atomics if you know the AtomicID, but be careful to choose low-impact ones." -ForegroundColor Yellow
    $selectedID = Read-Host "If you still want to attempt a test, enter an AtomicID now (or press Enter to skip)"
    if (-not $selectedID) { Remove-PSSession $session; Write-Host "Exiting." ; exit 0 }
} else {
    $choice = Read-Host "Enter the number of the test to run from the list above (or 'q' to quit)"
    if ($choice -eq 'q') { Remove-PSSession $session; exit 0 }
    [int]$choice
    if ($choice -lt 1 -or $choice -gt $tests.Count) { Remove-PSSession $session; FailExit "Invalid selection." }
    $selectedID = $tests[$choice - 1].AtomicID
    Write-Host "You selected $selectedID" -ForegroundColor Cyan
}

# 7) Confirm non-destructive run
Write-Host "`n== IMPORTANT: Previewing atomic details before execution ==" -ForegroundColor Yellow
$preview = Invoke-Command -Session $session -ScriptBlock { param($aid) Import-Module Invoke-AtomicRedTeam -ErrorAction SilentlyContinue; Get-AtomicTest -AtomicID $aid | Select-Object -Property AtomicID,Title,Description,SupportedPlatforms } -ArgumentList $selectedID
$preview | Format-List
$confirm = Read-Host "If the atomic is safe to run, type 'RUN' to execute it; otherwise type anything else to abort"
if ($confirm -ne "RUN") { Remove-PSSession $session; Write-Host "Aborted by user." ; exit 0 }

# 8) Run the chosen atomic with -ShowDetails to minimize destructive behavior
Write-Host "`n== Running selected atomic ($selectedID) on target with -ShowDetails ==" -ForegroundColor Cyan
try {
    $atomicOutput = Invoke-Command -Session $session -ScriptBlock { param($aid) Import-Module Invoke-AtomicRedTeam -ErrorAction SilentlyContinue; Invoke-AtomicTest -AtomicID $aid -ShowDetails -ErrorAction Stop } -ArgumentList $selectedID -ErrorAction Stop
    Write-Host "Atomic run completed. Output saved to variable." -ForegroundColor Green
} catch {
    Write-Host "Atomic execution failed: $($_.Exception.Message)" -ForegroundColor Red
}

# 9) Export Sysmon/System/Application logs from the target for reporting
Write-Host "`n== Exporting logs from target for evidence ==" -ForegroundColor Cyan
$exportDir = "C:\Temp\AtomicEvidence"
$exportedFiles = Invoke-Command -Session $session -ScriptBlock {
    param($ed)
    New-Item -Path $ed -ItemType Directory -Force | Out-Null
    $out = @()
    try { wevtutil epl System "$ed\System.evtx"; $out += "$ed\System.evtx" } catch {}
    try { wevtutil epl Microsoft-Windows-Sysmon/Operational "$ed\Sysmon.evtx"; $out += "$ed\Sysmon.evtx" } catch {}
    try { wevtutil epl Application "$ed\Application.evtx"; $out += "$ed\Application.evtx" } catch {}
    return $out
} -ArgumentList $exportDir -ErrorAction SilentlyContinue

if (-not $exportedFiles) { Write-Host "No logs exported on target (Sysmon may not be installed). Check target Event Viewer manually." -ForegroundColor Yellow }

# 10) Copy exported files to local machine
$localSave = Join-Path -Path $env:TEMP -ChildPath ("AtomicEvidence_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
New-Item -Path $localSave -ItemType Directory -Force | Out-Null
if ($exportedFiles) {
    foreach ($f in $exportedFiles) {
        $fileName = Split-Path -Path $f -Leaf
        $dest = Join-Path -Path $localSave -ChildPath $fileName
        try { Copy-Item -FromSession $session -Path $f -Destination $dest -Force -ErrorAction Stop; Write-Host "Copied $fileName to $dest" -ForegroundColor Green } catch { Write-Host "Failed to copy $f : $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    Write-Host "`nLocal evidence saved to: $localSave" -ForegroundColor Green
} else {
    Write-Host "`nNo exported evtx files to copy." -ForegroundColor Yellow
}

# 11) Cleanup
Remove-PSSession $session
Write-Host "`nDone. Attach the console screenshot(s), the evtx files (if any), and a short interpretation of observables in your lab write-up." -ForegroundColor Cyan
