<#
.SYNOPSIS
  Weekly encrypted backup of what GitHub does not hold.

.DESCRIPTION
  The repos live in C:\dev\ScanB, outside OneDrive. GitHub holds what is pushed;
  this covers the rest:

    scanb-workspace-<time>.7z   every file in C:\dev\ScanB except .git, .venv,
                                node_modules, the Web App's bin/obj, caches, and
                                files over 25 MB (generated data the ingest scripts
                                rebuild). So: uncommitted work, the files git ignores
                                (.env, appsettings*.json, the .csproj, token caches),
                                and the _latest wrapper.
    scanb-profile-<time>.7z     Claude Code memory, skills and settings, .NET user
                                secrets, .gitconfig and the global git ignore.

  Both are 7-Zip AES-256 with file names hidden, written to OneDrive\ScanB-Backups.
  The newest four of each are kept.

  The passphrase is stored in %LOCALAPPDATA%\ScanB-Backup, encrypted to this Windows
  account (DPAPI), so the weekly task runs unattended. Only this account on this
  laptop can read that copy. To open a backup anywhere else, you need the
  passphrase itself, so keep it in your password manager.

  To restore: open the .7z with 7-Zip, type the passphrase, and extract.

.EXAMPLE
  .\Backup-LocalOnly.ps1 -Setup
  Once: asks for the passphrase, schedules the weekly run (Mondays 13:00, or at the
  next logon if the laptop was off) and makes the first backup.

.EXAMPLE
  .\Backup-LocalOnly.ps1
  Makes a backup now. This is what the weekly task runs.
#>
[CmdletBinding()]
param(
    [switch]$Setup,
    [string]$Workspace = 'C:\dev\ScanB',
    [string]$Destination,
    [securestring]$Passphrase,
    [int]$Keep = 4,
    [int]$MaxFileMB = 25
)

$ErrorActionPreference = 'Continue'
$stateDir = Join-Path $env:LOCALAPPDATA 'ScanB-Backup'
$passFile = Join-Path $stateDir 'passphrase.dat'
$logFile  = Join-Path $stateDir 'backup.log'
$taskName = 'ScanB weekly backup'
$null = New-Item -ItemType Directory -Force -Path $stateDir

function Log([string]$text, [string]$colour = 'Gray') {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $text
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    Write-Host "   $text" -ForegroundColor $colour
}
function Get-Plain([securestring]$s) {
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

if (-not $Destination) {
    $od = if ($env:OneDriveCommercial) { $env:OneDriveCommercial } else { $env:OneDrive }
    if (-not $od) { Log 'OneDrive is not signed in, and no -Destination was given.' 'Red'; exit 1 }
    $Destination = Join-Path $od 'ScanB-Backups'
}
$sz = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
if (-not (Test-Path -LiteralPath $sz)) { Log "7-Zip not found at $sz" 'Red'; exit 1 }

# ------------------------------------------------------------------ one-time setup
if ($Setup) {
    Write-Host 'ScanB weekly backup: setup' -ForegroundColor Cyan
    if (-not $Passphrase) {
        Write-Host '   Choose a passphrase (at least 12 characters, no double quotes).'
        Write-Host '   Put it in your password manager: you need it to open a backup on any other machine.'
        for ($i = 0; $i -lt 3 -and -not $Passphrase; $i++) {
            $a = Read-Host '   passphrase' -AsSecureString
            $b = Read-Host '   again     ' -AsSecureString
            if ((Get-Plain $a) -cne (Get-Plain $b)) { Write-Host '   They did not match.' -ForegroundColor Yellow } else { $Passphrase = $a }
        }
        if (-not $Passphrase) { Log 'setup: no passphrase' 'Red'; exit 1 }
    }
    $plain = Get-Plain $Passphrase
    if ($plain.Length -lt 12 -or $plain.Contains('"')) { Log 'setup: the passphrase needs 12+ characters and no double quotes' 'Red'; exit 1 }
    ConvertFrom-SecureString -SecureString $Passphrase | Set-Content -LiteralPath $passFile -Encoding ASCII
    Log 'setup: passphrase stored (encrypted to this Windows account)' 'Green'

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $PSCommandPath)
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At '13:00'
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Log "setup: scheduled task '$taskName' registered (Mondays 13:00; runs at next logon if missed)" 'Green'
    Log 'setup: making the first backup now ...'
}

# ------------------------------------------------------------------ passphrase
if (-not $Passphrase) {
    if (-not (Test-Path -LiteralPath $passFile)) { Log 'No stored passphrase. Run: Backup-LocalOnly.ps1 -Setup' 'Red'; exit 1 }
    try { $Passphrase = Get-Content -LiteralPath $passFile -ErrorAction Stop | ConvertTo-SecureString -ErrorAction Stop }
    catch { Log "Cannot read the stored passphrase ($($_.Exception.Message)). Run -Setup again." 'Red'; exit 1 }
}
$pass = Get-Plain $Passphrase

# ------------------------------------------------------------------ backup
$null = New-Item -ItemType Directory -Force -Path $Destination
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$listFile = Join-Path $stateDir 'filelist.txt'
$failed = $false

function New-Archive([string]$name, [string]$baseDir, [string[]]$relPaths) {
    $archive = Join-Path $Destination "$name-$stamp.7z"
    [IO.File]::WriteAllLines($listFile, $relPaths, (New-Object Text.UTF8Encoding $false))
    Push-Location $baseDir
    $out = & $sz a -t7z -mx=5 -mhe=on "-p$pass" -scsUTF-8 -bso0 -bsp0 $archive "@$listFile" 2>&1
    $code = $LASTEXITCODE
    Pop-Location
    Remove-Item -LiteralPath $listFile -Force -ErrorAction SilentlyContinue
    if ($code -ge 2 -or -not (Test-Path -LiteralPath $archive)) {
        Log ("$name FAILED (7-Zip exit $code): " + (($out | ForEach-Object { "$_" } | Where-Object { $_.Trim() } | Select-Object -Last 2) -join ' ')) 'Red'
        return $false
    }
    & $sz t $archive "-p$pass" -bso0 -bsp0 *> $null
    if ($LASTEXITCODE -ne 0) { Log "$name FAILED: the archive did not test clean" 'Red'; return $false }
    Log ('{0}: {1} files, {2:N1} MB{3}' -f (Split-Path $archive -Leaf), $relPaths.Count, ((Get-Item -LiteralPath $archive).Length / 1MB), $(if ($code -eq 1) { ' (some files were in use and skipped)' } else { '' })) 'Green'
    # keep the newest $Keep of this kind
    Get-ChildItem -LiteralPath $Destination -Filter "$name-*.7z" | Sort-Object Name -Descending | Select-Object -Skip $Keep | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force
        Log "removed old $($_.Name)"
    }
    return $true
}

# workspace: everything except what GitHub or a rebuild provides
$skipDirs = '\\(\.git|\.venv|venv|node_modules|__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache)(\\|$)'
$webBuild = '^TurnB_ScanB_WebApplication_latest\\TurnB_ScanB_WebApplication\\(bin|obj)\\'
$limit = $MaxFileMB * 1MB
$files = Get-ChildItem -LiteralPath $Workspace -Recurse -Force -File -ErrorAction SilentlyContinue
$rel = @(); $big = @()
foreach ($f in $files) {
    $r = $f.FullName.Substring($Workspace.TrimEnd('\').Length + 1)
    if (('\' + $r) -match $skipDirs -or $r -match $webBuild) { continue }
    if ($f.Length -gt $limit) { $big += ('{0} ({1:N0} MB)' -f $r, ($f.Length / 1MB)); continue }
    $rel += $r
}
if ($big.Count) { Log ("not backed up, over $MaxFileMB MB (generated data): " + ($big -join '; ')) }
if (-not (New-Archive 'scanb-workspace' $Workspace $rel)) { $failed = $true }

# profile: Claude memory and settings, .NET user secrets, git config
$profileRel = @()
$home_ = $env:USERPROFILE
foreach ($d in (Get-ChildItem -LiteralPath (Join-Path $home_ '.claude\projects') -Directory -ErrorAction SilentlyContinue)) {
    if (Test-Path -LiteralPath (Join-Path $d.FullName 'memory')) {
        $profileRel += @(Get-ChildItem -LiteralPath (Join-Path $d.FullName 'memory') -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($home_.Length + 1) })
    }
}
foreach ($p in '.claude\settings.json', '.claude\CLAUDE.md', '.claude\keybindings.json', '.gitconfig', '.config\git\ignore') {
    if (Test-Path -LiteralPath (Join-Path $home_ $p)) { $profileRel += $p }
}
foreach ($d in '.claude\skills', '.claude\agents', '.claude\commands') {
    $full = Join-Path $home_ $d
    if (Test-Path -LiteralPath $full) { $profileRel += @(Get-ChildItem -LiteralPath $full -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($home_.Length + 1) }) }
}
$secrets = Join-Path $env:APPDATA 'Microsoft\UserSecrets'
if (Test-Path -LiteralPath $secrets) {
    $profileRel += @(Get-ChildItem -LiteralPath $secrets -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($home_.Length + 1) })
}
if (-not (New-Archive 'scanb-profile' $home_ $profileRel)) { $failed = $true }

$pass = $null
if ($failed) { exit 1 }
exit 0
