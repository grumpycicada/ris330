# Remote-Atomic-QuickRun.ps1
# Run from your admin host PowerShell (Run as Administrator).
# Prompts: target IP, credentials, then lists a few atomic tests to choose from.

function FailExit($msg) {
    Write-Host "[ERROR] $msg" -ForegroundColor Red
    exit 1
}

# Prompt user
$targetIP = Read-Host "Enter target Windows IP (e.g. 10.0.0.15)"
if (-not $targetIP) { FailExit "No IP provided." }

Write-Host "You will be prompted for credentials for the target ($targetIP)." -ForegroundColor Yellow
$cred = Get-Credential -Message "Enter credentials for $targetIP (should be admin)"

# 1) Basic network check
Write-Host "`n== Network check ==" -ForegroundColor Cyan
if (-not (Test-Connection -ComputerName $targetIP -Count 2 -Quiet)) {
    FailExit "Ping/Test-Connection to $targetIP failed. Check network or IP."
} else {
    Write-Host "Ping OK." -ForegroundColor Green
}

# 2) Add target to TrustedHosts on this client (safer: add single IP)
try {
    $current = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction SilentlyContinue).Value
} catch {
    $current = $null
}
if ($current -and $current -notlike "*$targetIP*") {
    $new = "$current,$targetIP"
} elseif (-not $current) {
    $new = $targetIP
} else {
    $new = $current
}
Set-Item WSMan:\localhost\Client\TrustedHosts -Value $new -Force
Write-Host "TrustedHosts updated to: $new" -ForegroundColor Green

# 3) Quick Test-WSMan
Write-Host "`n== WinRM endpoint test ==" -ForegroundColor Cyan
try {
    Test-WSMan -ComputerName $targetIP -ErrorAction Stop
    Write-Host "WinRM endpoint responded." -ForegroundColor Green
} catch {
    Write-Host "Test-WSMan failed. Attempting remote enable fallback (requires console access to target if this fails)." -ForegroundColor Yellow
    # fallback: try a one-time connection to run winrm quickconfig remotely via psexec-like steps is not safe; must instruct to run locally if needed.
}

# 4) Create PSSession
Write-Host "`n== Creating PSSession to $targetIP ==" -ForegroundColor Cyan
try {
    $session = New-PSSession -ComputerName $targetIP -Credential $cred -ErrorAction Stop
    Write-Host "PSSession created." -ForegroundColor Green
} catch {
    FailExit "Failed to create PSSession. Error: $($_.Exception.Message)`nIf New-PSSession fails, ensure WinRM is enabled on target (Enable-PSRemoting -Force on target console) and firewall allows 5985."
}

# 5) Ensure Invoke-AtomicRedTeam module exists on target, install if missing
Write-Host "`n== Ensure Invoke-AtomicRedTeam on target ==" -ForegroundColor Cyan
Invoke-Command -Session $session -ScriptBlock {
    try {
        Import-Module Invoke-AtomicRedTeam -ErrorAction Stop
        "MODULE_OK"
    } catch {
        "MODULE_MISSING"
    }
} -ErrorAction Stop | ForEach-Object {
    if ($_ -eq "MODULE_OK") {
        Write-Host "Invoke-AtomicRedTeam already available on target." -ForegroundColor Green
    } elseif ($_ -eq "MODULE_MISSING") {
        Write-Host "Module missing — installing for current user on target (this may take a moment)..." -ForegroundColor Yellow
        Invoke-Command -Session $session -ScriptBlock {
            Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            Install-Module -Name Invoke-AtomicRedTeam -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            "INSTALLED_OK"
        } -ErrorAction Stop | ForEach-Object {
            if ($_ -eq "INSTALLED_OK") { Write-Host "Module installed on target." -ForegroundColor Green }
        }
    } else {
        Write-Host "Unexpected response: $_" -ForegroundColor Yellow
    }
}

# 6) List some atomic tests for selection
Write-Host "`n== Fetching a short list of Atomic Tests on target ==" -ForegroundColor Cyan
$tests = Invoke-Command -Session $session -ScriptBlock {
    Import-Module Invoke-AtomicRedTeam -ErrorAction SilentlyContinue
    Get-AtomicTest | Select-Object -Property AtomicID,Title,Description | Select-Object -First 12
}
if (-not $tests) { FailExit "Could not retrieve list of tests. Module may not be functional on target." }

$idx = 0
$tests | ForEach-Object {
    $idx++
    Write-Host "[$idx] $($_.AtomicID) - $($_.Title)"
}
$choice = Read-Host "Enter the number of the test to run from the list above (or 'q' to quit)"
if ($choice -eq 'q') { Remove-PSSession $session; exit 0 }
[int]$choice

if ($choice -lt 1 -or $choice -gt $tests.Count) { FailExit "Invalid selection." }
$selectedID = $tests[$choice - 1].AtomicID
Write-Host "You selected $selectedID" -ForegroundColor Cyan

# 7) Run the selected atomic in the remote session (ShowDetails only)
Write-Host "`n== Running selected atomic ($selectedID) on target =="
Invoke-Command -Session $session -ScriptBlock {
    param($aid)
    Import-Module Invoke-AtomicRedTeam -ErrorAction SilentlyContinue
    # Run with -ShowDetails to avoid destructive parameters; some atomics may request confirmation for dangerous steps.
    Invoke-AtomicTest -AtomicID $aid -ShowDetails -ErrorAction Stop
} -ArgumentList $selectedID -ErrorAction Stop | Tee-Object -Variable atomicOutput

Write-Host "`n== Atomic output captured; exporting logs from target for reporting ==" -ForegroundColor Cyan

# 8) Export Sysmon and System logs from the target (if available)
$exportDir = "C:\Temp\AtomicEvidence"
Invoke-Command -Session $session -ScriptBlock {
    param($ed)
    New-Item -Path $ed -ItemType Directory -Force | Out-Null
    wevtutil epl System "$ed\System.evtx" 2>$null
    wevtutil epl Microsoft-Windows-Sysmon/Operational "$ed\Sysmon.evtx" 2>$null
    # fallback: export Application if Sysmon missing
    wevtutil epl Application "$ed\Application.evtx" 2>$null
    return (Get-ChildItem -Path $ed -Filter *.evtx | Select-Object -ExpandProperty FullName)
} -ArgumentList $exportDir -ErrorAction SilentlyContinue -OutVariable exportedFiles

Write-Host "Exported files on target (if any):"
$exportedFiles | ForEach-Object { Write-Host $_ -ForegroundColor Green }

# 9) Copy logs to local machine for inclusion in report
$localSave = Join-Path -Path $env:TEMP -ChildPath ("AtomicEvidence_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
New-Item -Path $localSave -ItemType Directory -Force | Out-Null

foreach ($f in $exportedFiles) {
    $fileName = Split-Path -Path $f -Leaf
    $dest = Join-Path -Path $localSave -ChildPath $fileName
    Copy-Item -FromSession $session -Path $f -Destination $dest -Force -ErrorAction SilentlyContinue
}

Write-Host "`nLocal evidence saved to: $localSave" -ForegroundColor Green

# 10) Clean up
Remove-PSSession $session
Write-Host "`nDone. Remember to attach the console screenshot(s), the evtx files, and a short interpretation of observables in your lab write-up." -ForegroundColor Cyan
