<#
.SYNOPSIS
  Sets up a new ScanB development laptop from the migration kit in OneDrive.

.DESCRIPTION
  Start it with Setup-NewMachine.cmd in the kit folder. Two phases, and every step
  checks before it acts, so a re-run only does what is still missing:

  Prepare  touches only this machine, and runs in a second window with
           administrator rights. Installs the toolchain with winget, installs SQL
           Server 2022 Developer from Microsoft's ISO with the old laptop's
           collation, unlocks the kit with your passphrase, restores its
           databases, and puts back Claude Code (memory, skills, settings, MCP
           servers), .NET user secrets, git, Codex and VS Code settings, and the
           user folders.

  Cutover  changes files inside the OneDrive-synced repos, so it is for when the
           old laptop is finished with them. Runs WITHOUT administrator rights,
           because OneDrive will not download files for an elevated program. Keeps
           the repos on this device, rewrites the old OneDrive path and machine
           name, renames Claude's memory folders to the new path, rebuilds the
           Python environments, restores NuGet and npm packages, creates the
           Azurite container and runs all four repo gates.

  Phase All runs Prepare, then asks before Cutover.

  The kit's archives are unpacked into %LOCALAPPDATA%\ScanB-Kit (not synced) and
  that folder is deleted once Prepare has nothing left to retry.

.PARAMETER Phase
  All (default), Prepare or Cutover.

.PARAMETER WorkspaceRoot
  The folder holding ScanB-Platform and the repos. Found in OneDrive by default.

.PARAMETER IncludeOptional
  Also install PowerToys, Visual Studio 2022 Community, Azure Functions Core
  Tools and DAX Studio.

.PARAMETER Yes
  Do not ask before the Cutover steps.

.PARAMETER DryRun
  Report what would happen. Installs, unpacks, restores and writes nothing.

.PARAMETER RestoreSuffix
  For testing the restore on a machine that already has the databases:
  restores each one as <name><suffix>.

.EXAMPLE
  Setup-NewMachine.cmd             (double-click: Prepare, then asks about Cutover)
  Setup-NewMachine.cmd cutover     (later, on cutover day)
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Prepare', 'Cutover')][string]$Phase = 'All',
    [string]$KitPath,
    [string]$WorkspaceRoot,
    [switch]$IncludeOptional,
    [switch]$SkipInstall,
    [switch]$SkipSql,
    [switch]$SkipProfile,
    [switch]$SkipUserFolders,
    [securestring]$Passphrase,
    [string]$SevenZip,
    [switch]$Yes,
    [switch]$DryRun,
    [string]$RestoreSuffix = '',
    [switch]$PauseAtEnd          # set on the elevated Prepare window so it stays open
)

# Not 'Stop': Windows PowerShell 5.1 turns any stderr line from git, winget, pip or npm
# into a terminating error under 'Stop'. Failures are caught explicitly instead.
$ErrorActionPreference = 'Continue'
try { Remove-TypeData -TypeName System.Array -ErrorAction Stop } catch { }

$ScriptFile = $MyInvocation.MyCommand.Path

$Repos = [ordered]@{
    'Platform'  = 'ScanB-Platform'
    'Web App'   = 'TurnB_ScanB_WebApplication_latest\TurnB_ScanB_WebApplication'
    'AI Bot'    = 'ScanB-AI-Bot'
    'Insight'   = 'Auto-Insight-Generation'
    'Messaging' = 'ScanB-Messaging'
}

$Core = @(
    @{ Id = '7zip.7zip';                              Name = '7-Zip (opens the kit)' },
    @{ Id = 'Git.Git';                                Name = 'Git' },
    @{ Id = 'Microsoft.VisualStudioCode';             Name = 'VS Code'; Extra = @('--scope', 'machine') },
    @{ Id = 'Microsoft.DotNet.SDK.9';                 Name = '.NET SDK 9' },
    @{ Id = 'Microsoft.DotNet.AspNetCore.8';          Name = 'ASP.NET Core 8 runtime' },
    @{ Id = 'Python.Python.3.12';                     Name = 'Python 3.12'; Override = '/quiet InstallAllUsers=1 PrependPath=1 Include_test=0 Include_launcher=1 InstallLauncherAllUsers=1' },
    @{ Id = 'astral-sh.uv';                           Name = 'uv' },
    @{ Id = 'OpenJS.NodeJS.LTS';                      Name = 'Node.js LTS' },
    @{ Id = 'Microsoft.AzureCLI';                     Name = 'Azure CLI' },
    @{ Id = 'GitHub.cli';                             Name = 'GitHub CLI' },
    @{ Id = 'Docker.DockerDesktop';                   Name = 'Docker Desktop' },
    @{ Id = 'Microsoft.msodbcsql.18';                 Name = 'ODBC Driver 18 for SQL Server' },
    @{ Id = 'Microsoft.SQLServerManagementStudio.21'; Name = 'SQL Server Management Studio 21' },
    @{ Id = 'Microsoft.PowerBI';                      Name = 'Power BI Desktop' },
    @{ Id = 'Google.Chrome';                          Name = 'Google Chrome' },
    @{ Id = 'Anthropic.Claude';                       Name = 'Claude desktop app' }
)
$Optional = @(
    @{ Id = 'Microsoft.PowerToys';                    Name = 'PowerToys' },
    @{ Id = 'Microsoft.VisualStudio.2022.Community';  Name = 'Visual Studio 2022 Community' },
    @{ Id = 'Microsoft.Azure.FunctionsCoreTools';     Name = 'Azure Functions Core Tools' },
    @{ Id = 'DaxStudio.DaxStudio';                    Name = 'DAX Studio' }
)

# SQL Server 2022 Developer as a full ISO. The web bootstrapper (SQL2022-SSEI-Dev.exe)
# is refused by Microsoft's servers now ("This version of the installer is no longer
# supported"), so it is not used. The ISO's setup.exe is checked for Microsoft's signature.
$SqlIsoUrl = 'https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLServer2022-x64-ENU-Dev.iso'

$Unpacked = Join-Path $env:LOCALAPPDATA 'ScanB-Kit'

# ------------------------------------------------------------------ helpers
$Results = New-Object System.Collections.ArrayList
$script:NeedsReboot = $false

function Step([string]$text) { Write-Host ''; Write-Host "== $text" -ForegroundColor Cyan }
function Say([string]$text, [string]$colour = 'Gray') { Write-Host "   $text" -ForegroundColor $colour }
function Note([string]$item, [string]$status, [string]$detail = '') {
    [void]$Results.Add([pscustomobject]@{ Item = $item; Status = $status; Detail = $detail })
    $colour = switch ($status) { 'ok' { 'Green' } 'skip' { 'DarkGray' } 'plan' { 'Yellow' } 'todo' { 'Yellow' } default { 'Red' } }
    Say ('{0,-40} {1,-5} {2}' -f $item, $status, $detail) $colour
}
function Fail([string]$item, $err) {
    Note $item 'FAIL' ('{0} (line {1})' -f $err.Exception.Message.Trim(), $err.InvocationInfo.ScriptLineNumber)
}
function Status([bool]$ok) { if ($DryRun) { 'plan' } elseif ($ok) { 'ok' } else { 'FAIL' } }
function Ask([string]$question, [bool]$default) {
    $hint = if ($default) { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host "   $question $hint"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $default }
    return @('y', 'yes') -contains $answer.Trim().ToLower()
}
function Tail($lines) { (($lines | ForEach-Object { "$_" } | Where-Object { $_.Trim() } | Select-Object -Last 2) -join ' ').Trim() }
function Write-Utf8([string]$path, [string]$text, [bool]$bom = $false) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $bom))
}
function Copy-Tree([string]$from, [string]$to, [string[]]$extra = @()) {
    if (-not (Test-Path -LiteralPath $from)) { return $false }
    # /XO: a file already on this machine that is newer than the kit's copy wins
    $rc = @($from, $to, '/E', '/XO', '/R:1', '/W:1', '/XJ', '/NFL', '/NDL', '/NP', '/NJH', '/NJS') + $extra
    & robocopy.exe @rc | Out-Null
    return ($LASTEXITCODE -lt 8)
}
function Copy-One([string]$from, [string]$to, [switch]$Backup) {
    if (-not (Test-Path -LiteralPath $from)) { return $false }
    try {
        $dir = Split-Path -Parent $to
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop }
        if ($Backup -and (Test-Path -LiteralPath $to)) {
            Copy-Item -LiteralPath $to -Destination "$to.bak-scanbkit-$(Get-Date -Format yyyyMMddHHmmss)" -Force -ErrorAction Stop
        }
        Copy-Item -LiteralPath $from -Destination $to -Force -ErrorAction Stop
        return $true
    } catch { Say "could not copy $from ($($_.Exception.Message))" 'Red'; return $false }
}
function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}
function Have([string]$command) { [bool](Get-Command $command -ErrorAction SilentlyContinue) }
function Get-Plain([securestring]$s) {
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

# Claude Code names a project's folder after its path, every non-alphanumeric character a dash.
function Get-ClaudeKey([string]$path) { $path.TrimEnd('\') -replace '[^A-Za-z0-9]', '-' }

function Open-Sql([string]$database = 'master') {
    $cn = New-Object System.Data.SqlClient.SqlConnection(
        "Server=localhost;Database=$database;Integrated Security=True;TrustServerCertificate=True;Connect Timeout=15")
    $cn.Open(); return $cn
}
function Invoke-SqlQuery([string]$query, [string]$database = 'master') {
    $cn = Open-Sql $database
    try {
        $cmd = $cn.CreateCommand(); $cmd.CommandText = $query; $cmd.CommandTimeout = 0
        $table = New-Object System.Data.DataTable; $table.Load($cmd.ExecuteReader()); return , $table
    } finally { $cn.Close() }
}
function Invoke-SqlCommand([string]$query, [string]$database = 'master') {
    $cn = Open-Sql $database
    try { $cmd = $cn.CreateCommand(); $cmd.CommandText = $query; $cmd.CommandTimeout = 0; [void]$cmd.ExecuteNonQuery() } finally { $cn.Close() }
}
function SqlName([string]$name) { '[' + $name.Replace(']', ']]') + ']' }
function SqlText([string]$text) { "N'" + $text.Replace("'", "''") + "'" }

function Read-TextFile([string]$file) {
    $bytes = [System.IO.File]::ReadAllBytes($file)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $skip = if ($bom) { 3 } else { 0 }
    return @{ Text = [System.Text.Encoding]::UTF8.GetString($bytes, $skip, $bytes.Length - $skip); Bom = $bom }
}

# Replace an old path with a new one in a text file, in its plain, forward-slash and
# JSON-escaped spellings. The lookahead stops a re-run matching inside the new path.
function Update-PathsInFile([string]$file, [object[]]$pairs) {
    if (-not (Test-Path -LiteralPath $file)) { return $false }
    $f = Read-TextFile $file
    $text = $f.Text
    foreach ($pair in $pairs) {
        $old = ([string]$pair[0]).TrimEnd('\'); $new = ([string]$pair[1]).TrimEnd('\')
        if (-not $old -or $old -ieq $new) { continue }
        $variants = @(
            , @($old.Replace('\', '\\'), $new.Replace('\', '\\'))
            , @($old, $new)
            , @($old.Replace('\', '/'), $new.Replace('\', '/'))
        )
        foreach ($v in $variants) {
            $pattern = '(?im)' + [regex]::Escape($v[0]) + '(?=[\\/"'';,<>|\r\n]|$)'
            $text = [regex]::Replace($text, $pattern, $v[1].Replace('$', '$$'))
        }
    }
    if ($text -ceq $f.Text) { return $false }
    if (-not $DryRun) { Write-Utf8 $file $text $f.Bom }
    return $true
}

# The kit folder: -KitPath, else the folder this script is in, else ScanB-Migration-Kit in
# any OneDrive this user is signed in to. ($PSScriptRoot alone came back empty on one
# elevated run, so it is not trusted on its own.)
function Resolve-KitPath {
    $candidates = @($KitPath, $PSScriptRoot)
    if ($ScriptFile) { $candidates += Split-Path -Parent $ScriptFile }
    if ($PSCommandPath) { $candidates += Split-Path -Parent $PSCommandPath }
    $roots = @($env:OneDriveCommercial, $env:OneDrive)
    $roots += Get-ChildItem 'HKCU:\Software\Microsoft\OneDrive\Accounts' -ErrorAction SilentlyContinue | ForEach-Object { (Get-ItemProperty $_.PSPath).UserFolder }
    foreach ($r in ($roots | Where-Object { $_ })) { $candidates += Join-Path $r 'ScanB-Migration-Kit' }
    $candidates += (Get-Location).Path
    foreach ($c in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        $full = [System.IO.Path]::GetFullPath($c)
        if (Test-Path -LiteralPath (Join-Path $full 'kit.json')) { return $full.TrimEnd('\') }
    }
    throw ('No kit.json found. Looked in: ' + (($candidates | Where-Object { $_ } | Select-Object -Unique) -join '; ') + '. Start Setup-NewMachine.cmd from the ScanB-Migration-Kit folder in OneDrive.')
}

function Find-SevenZip {
    foreach ($c in @($SevenZip, (Join-Path $env:ProgramFiles '7-Zip\7z.exe'), (Join-Path $env:LOCALAPPDATA 'ScanB-Kit-tools\7zip\Files\7-Zip\7z.exe'))) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

# Make OneDrive actually download the repos. Pinning only queues the downloads, and a
# placeholder that is still cloud-only can fail to read: empty files (__init__.py) gave
# "OSError: [Errno 22] Invalid argument" to Python. Reading a byte of each placeholder
# downloads it; an empty one that still fails is recreated, since its content is nothing.
function Invoke-Hydrate([string[]]$dirs) {
    $cloudOnly = 0x400000 -bor 0x40000 -bor 0x1000      # recall on data access / on open, offline
    $pending = @(foreach ($d in $dirs) {
        Get-ChildItem -LiteralPath $d -Recurse -Force -File -ErrorAction SilentlyContinue |
            Where-Object { [int]$_.Attributes -band $cloudOnly }
    })
    $stats = @{ Pending = $pending.Count; Read = 0; Recreated = 0; Failed = @() }
    if ($DryRun -or -not $pending.Count) { return $stats }
    Say "downloading $($pending.Count) file(s) OneDrive has not fetched yet ..."
    $i = 0
    foreach ($f in $pending) {
        $i++
        if ($i % 2000 -eq 0) { Say "  $i of $($pending.Count)" 'DarkGray' }
        try {
            $fs = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
            try { [void]$fs.ReadByte() } finally { $fs.Dispose() }
            $stats.Read++
        } catch {
            if ($f.Length -eq 0) {
                try {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                    [System.IO.File]::WriteAllBytes($f.FullName, [byte[]]@())
                    $stats.Recreated++
                } catch { $stats.Failed += $f.FullName }
            } else { $stats.Failed += $f.FullName }
        }
    }
    return $stats
}

function Initialize-Venv([string]$label, [string]$repo, [string[]]$requirements) {
    $venv = Join-Path $repo '.venv'
    $marker = Join-Path $venv ".built-on-$env:COMPUTERNAME"
    if (Test-Path -LiteralPath $marker) { Note "$label .venv" 'skip' 'already built on this machine'; return }
    if ($DryRun) { Note "$label .venv" 'plan' 'rebuild with Python 3.12'; return }
    Say "building $label .venv ..."
    & py -3.12 -m venv --clear $venv *> $null
    $py = Join-Path $venv 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $py)) { Note "$label .venv" 'FAIL' 'py -3.12 -m venv failed'; return }
    & $py -m pip install --upgrade pip --quiet --disable-pip-version-check *> $null
    $reqArgs = @(); foreach ($r in $requirements) { $reqArgs += @('-r', (Join-Path $repo $r)) }
    $out = & $py -m pip install @reqArgs --quiet --disable-pip-version-check 2>&1
    if ($LASTEXITCODE -ne 0) { Note "$label .venv" 'FAIL' (Tail $out); return }
    Write-Utf8 $marker (Get-Date).ToString('s')
    Note "$label .venv" 'ok'
}

# ------------------------------------------------------------------ preflight
Write-Host 'ScanB new-machine setup' -ForegroundColor Cyan
if ($DryRun) { Write-Host '(dry run: nothing is installed or written)' -ForegroundColor Yellow }

$logDir = Join-Path $env:LOCALAPPDATA 'ScanB-Setup'
$null = New-Item -ItemType Directory -Force -Path $logDir
$logFile = Join-Path $logDir "setup-$(Get-Date -Format yyyyMMdd-HHmmss)-$PID.log"
Start-Transcript -Path $logFile | Out-Null
$pass = $null

try {
    $runPrepare = $Phase -in @('All', 'Prepare')
    $runCutover = $Phase -in @('All', 'Cutover')

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $console = (Get-CimInstance Win32_ComputerSystem).UserName
    if ($console -and $identity.Name -ine $console) {
        throw "Running as $($identity.Name) but $console is signed in. Settings would land in the wrong profile: approve the admin prompt with your own account."
    }

    $KitPath = Resolve-KitPath
    if (-not $ScriptFile) { $ScriptFile = Join-Path $KitPath 'Setup-NewMachine.ps1' }
    $Kit = Get-Content -LiteralPath (Join-Path $KitPath 'kit.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    Say "kit from $($Kit.oldMachine), made $($Kit.createdAt), in $KitPath"
    $encrypted = [bool]$Kit.encrypted
    # an encrypted kit is unpacked into $Unpacked; an older plain kit is used where it is
    $DataPath = if ($encrypted) { $Unpacked } else { $KitPath }

    # Where the repos are on this machine: look in every OneDrive this user has signed in to.
    $NewWorkspace = $null
    if ($WorkspaceRoot) { $NewWorkspace = [System.IO.Path]::GetFullPath($WorkspaceRoot) }
    elseif ($null -ne $Kit.workspaceUnderOneDrive) {
        $roots = @($env:OneDriveCommercial, $env:OneDrive)
        $roots += Get-ChildItem 'HKCU:\Software\Microsoft\OneDrive\Accounts' -ErrorAction SilentlyContinue | ForEach-Object { (Get-ItemProperty $_.PSPath).UserFolder }
        foreach ($root in ($roots | Where-Object { $_ } | Select-Object -Unique)) {
            $candidate = if ($Kit.workspaceUnderOneDrive) { Join-Path $root $Kit.workspaceUnderOneDrive } else { $root.TrimEnd('\') }
            if (Test-Path -LiteralPath (Join-Path $candidate 'ScanB-Platform')) { $NewWorkspace = $candidate; break }
        }
    }
    if ($NewWorkspace) { Say "workspace: $NewWorkspace" } else { Say 'workspace: not found yet (let OneDrive finish syncing ScanB-Platform; Prepare does not need it)' 'Yellow' }

    # old path -> new path, most specific first
    $PathPairs = @()
    if ($NewWorkspace) {
        $PathPairs += , @($Kit.oldWorkspaceRoot, $NewWorkspace)
        if ($Kit.oldOneDriveRoot -and $Kit.oldOneDriveRoot -ne $Kit.oldWorkspaceRoot -and $Kit.workspaceUnderOneDrive) {
            $PathPairs += , @($Kit.oldOneDriveRoot, $NewWorkspace.Substring(0, $NewWorkspace.Length - $Kit.workspaceUnderOneDrive.Length).TrimEnd('\'))
        }
    }
    $PathPairs += , @($Kit.oldUserProfile, $env:USERPROFILE)

    # Prepare needs administrator rights; Cutover must not have them. From a normal
    # window, run Prepare in a second, elevated window and wait for it.
    if ($runPrepare -and -not $isAdmin -and -not $DryRun -and -not $PauseAtEnd) {
        Step 'Prepare'
        Say 'Opening a second window with administrator rights for the installs. Approve the prompt,'
        Say 'type the kit passphrase there, and come back here when it says to.'
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptFile`"", '-Phase', 'Prepare', '-KitPath', "`"$KitPath`"", '-PauseAtEnd')
        foreach ($sw in 'IncludeOptional', 'SkipInstall', 'SkipSql', 'SkipProfile', 'SkipUserFolders') { if ((Get-Variable -Name $sw -ValueOnly)) { $argList += "-$sw" } }
        if ($SevenZip) { $argList += @('-SevenZip', "`"$SevenZip`"") }
        if ($RestoreSuffix) { $argList += @('-RestoreSuffix', $RestoreSuffix) }
        try {
            $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList ($argList -join ' ') -Verb RunAs -Wait -PassThru -ErrorAction Stop
            if ($proc.ExitCode -eq 0) { Note 'Prepare (admin window)' 'ok' }
            else {
                # repeat the admin window's failures here, from its log
                $childLog = Get-ChildItem -LiteralPath $logDir -Filter "setup-*-$($proc.Id).log" -ErrorAction SilentlyContinue | Select-Object -First 1
                $lines = @()
                if ($childLog) {
                    $inSummary = $false
                    foreach ($l in (Get-Content -LiteralPath $childLog.FullName -ErrorAction SilentlyContinue)) {
                        if ($l -match '^== Summary') { $inSummary = $true; continue }
                        if ($inSummary -and $l -match '\s(FAIL|todo)\s') { $lines += $l.Trim() }
                    }
                }
                if ($lines.Count) { foreach ($l in $lines) { Note 'admin window' 'FAIL' $l } }
                else { Note 'Prepare (admin window)' 'FAIL' "see the admin window's summary (log in $logDir)" }
            }
        } catch {
            Note 'Prepare (admin window)' 'FAIL' "administrator rights were not granted ($($_.Exception.Message))"
        }
        $runPrepare = $false
    }

    # ============================================================== PREPARE
    if ($runPrepare) {
        $sqlMissing = -not (Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue)

        # ---------------------------------------------------- toolchain
        if (-not $SkipInstall) {
            Step 'Install the toolchain (winget)'
            if (-not (Have 'winget')) { throw 'winget is missing. Install "App Installer" from the Microsoft Store, then run this again.' }
            $packages = $Core + $(if ($IncludeOptional) { $Optional } else { @() })
            $okCodes = @(0, -1978335189, -1978335135)                 # done, nothing to update, already installed
            $rebootCodes = @(-1978334967, -1978334966, 3010, 1641)    # done, restart needed
            foreach ($p in $packages) {
                & winget list --id $p.Id --exact --accept-source-agreements --disable-interactivity *> $null
                if ($LASTEXITCODE -eq 0) { Note $p.Name 'skip' 'already installed'; continue }
                if ($DryRun) { Note $p.Name 'plan' "would install $($p.Id)"; continue }
                Say "installing $($p.Name) ..."
                $a = @('install', '--id', $p.Id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
                if ($p.Extra) { $a += $p.Extra }
                if ($p.Override) { $a += @('--override', $p.Override) }
                $out = & winget @a 2>&1
                $code = $LASTEXITCODE
                if ($okCodes -contains $code) {
                    Note $p.Name 'ok'
                    if ($p.Id -eq 'Docker.DockerDesktop') { $script:NeedsReboot = $true }   # WSL 2 comes in with it
                }
                elseif ($rebootCodes -contains $code) { Note $p.Name 'ok' 'restart needed'; $script:NeedsReboot = $true }
                else { Note $p.Name 'FAIL' ("winget exit $code. " + (Tail $out)) }
            }
            if (-not $DryRun) { Update-SessionPath }
        }

        # ---------------------------------------------------- SQL Server engine
        if (-not $SkipSql) {
            Step 'SQL Server'
            $collation = if ($Kit.sqlCollation) { $Kit.sqlCollation } else { 'Latin1_General_CI_AS' }
            if (-not $sqlMissing) { Note 'SQL Server (default instance)' 'skip' 'already installed' }
            elseif ($DryRun) { Note 'SQL Server 2022 Developer' 'plan' "would install from the ISO with collation $collation" }
            else {
                $media = Join-Path $env:SystemDrive 'ScanB-SQLMedia'
                $iso = Join-Path $media 'SQLServer2022-x64-ENU-Dev.iso'
                $mounted = $false
                try {
                    $null = New-Item -ItemType Directory -Force -Path $media -ErrorAction Stop
                    $expected = $null
                    try { $expected = [long](Invoke-WebRequest -Uri $SqlIsoUrl -Method Head -UseBasicParsing -ErrorAction Stop).Headers['Content-Length'] } catch { }
                    $have = if (Test-Path -LiteralPath $iso) { (Get-Item -LiteralPath $iso).Length } else { 0 }
                    if (-not $have -or ($expected -and $have -ne $expected)) {
                        Say 'downloading the SQL Server 2022 Developer ISO (about 1.1 GB) ...'
                        & curl.exe -L --fail --retry 3 --progress-bar -C - -o $iso $SqlIsoUrl
                        if ($LASTEXITCODE -ne 0) { throw "the ISO download failed (curl exit $LASTEXITCODE)" }
                        if ($expected -and (Get-Item -LiteralPath $iso).Length -ne $expected) { Remove-Item -LiteralPath $iso -Force; throw 'the ISO download was incomplete; run this again' }
                    }
                    $volume = Mount-DiskImage -ImagePath $iso -PassThru -ErrorAction Stop | Get-Volume
                    $mounted = $true
                    $setup = "$($volume.DriveLetter):\setup.exe"
                    $sig = Get-AuthenticodeSignature -FilePath $setup
                    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw "setup.exe on the ISO is not signed by Microsoft ($($sig.Status))" }
                    Say "installing the database engine, collation $collation (10-20 minutes) ..."
                    $setupArgs = '/Q /ACTION=Install /FEATURES=SQLENGINE /INSTANCENAME=MSSQLSERVER /SQLCOLLATION=' + $collation +
                                 ' /SQLSYSADMINACCOUNTS="' + $identity.Name + '" "BUILTIN\Administrators" /TCPENABLED=1' +
                                 ' /UPDATEENABLED=False /IACCEPTSQLSERVERLICENSETERMS /SUPPRESSPRIVACYSTATEMENTNOTICE /INDICATEPROGRESS'
                    $proc = Start-Process -FilePath $setup -ArgumentList $setupArgs -Wait -PassThru -ErrorAction Stop
                    if (@(0, 3010) -notcontains $proc.ExitCode) { throw "setup.exe exit $($proc.ExitCode); logs in C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log" }
                    if ($proc.ExitCode -eq 3010) { $script:NeedsReboot = $true }
                    $sqlMissing = $false
                    Note 'SQL Server 2022 Developer' 'ok' "collation $collation"
                } catch {
                    Fail 'SQL Server 2022 Developer' $_
                    Say "Install it by hand from the ISO in $media (Custom > Database Engine Services > collation $collation > add yourself as admin), then run this again." 'Yellow'
                } finally {
                    if ($mounted) { Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue | Out-Null }
                }
                if (-not $sqlMissing) { Remove-Item -LiteralPath $media -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }

        # ---------------------------------------------------- unlock the kit
        $needData = (-not $SkipSql -and @($Kit.databases).Count) -or -not $SkipProfile -or (-not $SkipUserFolders -and $Kit.userFoldersArchive)
        $unlocked = -not $encrypted
        if ($encrypted -and $needData) {
            Step 'Unlock the kit'
            try {
                $archives = @()
                if (-not $SkipProfile) { $archives += , @($Kit.profileArchive, (Join-Path $Unpacked 'profile')) }
                if (-not $SkipSql) { foreach ($db in @($Kit.databases)) { $archives += , @($db.archive, (Join-Path $Unpacked 'sql')) } }
                if (-not $SkipUserFolders -and $Kit.userFoldersArchive) { $archives += , @($Kit.userFoldersArchive, (Join-Path $Unpacked 'userfolders')) }
                # an archive unpacked by an earlier run leaves a marker; skip those
                $todoArchives = @($archives | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Unpacked ".unpacked-$($_[0])")) })
                $sz = Find-SevenZip
                if ($DryRun) { Note 'unlock kit' 'plan' "$($todoArchives.Count) archive(s) to unpack into %LOCALAPPDATA%\ScanB-Kit" }
                elseif (-not $todoArchives.Count) { Note 'unlock kit' 'skip' 'already unpacked'; $unlocked = $true }
                elseif (-not $sz) { Note 'unlock kit' 'FAIL' '7-Zip is not installed; run this again without -SkipInstall' }
                else {
                    $probe = Join-Path $KitPath $todoArchives[0][0]
                    if ($Passphrase) { $pass = Get-Plain $Passphrase }
                    for ($try = 1; $try -le 3; $try++) {
                        if (-not $pass) { $pass = Get-Plain (Read-Host '   kit passphrase' -AsSecureString) }
                        & $sz t $probe "-p$pass" -bso0 -bsp0 -bse0 *> $null
                        if ($LASTEXITCODE -eq 0) { break }
                        Say 'That passphrase does not open the kit.' 'Yellow'
                        $pass = $null
                        if ($Passphrase) { break }
                    }
                    if (-not $pass) { Note 'unlock kit' 'FAIL' 'wrong passphrase' }
                    else {
                        $null = New-Item -ItemType Directory -Force -Path $Unpacked
                        $bad = @()
                        foreach ($pair in $todoArchives) {
                            $arc = Join-Path $KitPath $pair[0]
                            if (-not (Test-Path -LiteralPath $arc)) { $bad += "$($pair[0]) missing"; continue }
                            Say "unpacking $($pair[0]) ..."
                            $out = & $sz x $arc "-o$($pair[1])" "-p$pass" -y -bso0 -bsp0 2>&1
                            if ($LASTEXITCODE -gt 1) { $bad += "$($pair[0]): " + (Tail $out) }
                            else { Write-Utf8 (Join-Path $Unpacked ".unpacked-$($pair[0])") (Get-Date).ToString('s') }
                        }
                        if ($bad.Count) { Note 'unlock kit' 'FAIL' ($bad -join '; ') } else { Note 'unlock kit' 'ok' "$($todoArchives.Count) archive(s) unpacked" }
                        $unlocked = $true
                    }
                }
                # the SQL Server service restores from here, so it needs to read the folder
                $svcAccount = (Get-CimInstance Win32_Service -Filter "Name='MSSQLSERVER'").StartName
                if ($svcAccount -and (Test-Path -LiteralPath (Join-Path $Unpacked 'sql'))) { & icacls.exe (Join-Path $Unpacked 'sql') /grant "${svcAccount}:(OI)(CI)RX" *> $null }
            } catch { Fail 'unlock kit' $_ }
        }

        # ---------------------------------------------------- restore the databases
        if (-not $SkipSql) {
            $haveSql = $false
            try { $null = Invoke-SqlQuery 'SELECT 1 AS one'; $haveSql = $true } catch { }
            if (-not @($Kit.databases).Count) { Note 'database restore' 'skip' 'the kit has no databases' }
            elseif (-not $haveSql) { Note 'database restore' $(if ($DryRun) { 'plan' } else { 'todo' }) 'SQL Server is not running yet; run this again once it is' }
            elseif (-not $unlocked -and -not $DryRun) { Note 'database restore' 'skip' 'the kit is still locked' }
            else {
                $paths = $null
                try {
                    $paths = (Invoke-SqlQuery "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(400)) AS d, CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(400)) AS l, CAST(SERVERPROPERTY('Collation') AS nvarchar(128)) AS c").Rows[0]
                } catch {
                    Note 'database restore' 'FAIL' ("SQL Server did not answer: $($_.Exception.Message) Close other programs and run this again.")
                }
                if ($paths -and $Kit.sqlCollation -and $paths.c -ne $Kit.sqlCollation) { Say "Note: this server's collation is $($paths.c); the old one was $($Kit.sqlCollation)." 'Yellow' }
                foreach ($db in @($(if ($paths) { $Kit.databases }))) {
                    $target = $db.name + $RestoreSuffix
                    try {
                        $exists = (Invoke-SqlQuery "SELECT DB_ID($(SqlText $target)) AS id").Rows[0].id
                        if ($exists -isnot [DBNull]) { Note "restore $target" 'skip' 'database already exists'; continue }
                        $bak = if ($db.archive) { Join-Path $DataPath ('sql\' + $db.bakName) } else { Join-Path $KitPath $db.file }
                        if ($DryRun) { Note "restore $target" 'plan' "from $(if ($db.archive) { $db.archive } else { $db.file })"; continue }
                        if (-not (Test-Path -LiteralPath $bak)) { throw "backup not found: $bak" }
                        $files = @((Invoke-SqlQuery "RESTORE FILELISTONLY FROM DISK = $(SqlText $bak)").Rows)
                        $need = [double](($files | Measure-Object Size -Sum).Sum)
                        $free = (New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot([string]$paths.d))).AvailableFreeSpace
                        if ($need -gt $free) { throw ('needs {0:N1} GB, the data drive has {1:N1} GB free' -f ($need / 1GB), ($free / 1GB)) }
                        $moves = foreach ($f in $files) {
                            $ext = [System.IO.Path]::GetExtension([string]$f.PhysicalName)
                            if (-not $ext) { $ext = if ($f.Type -eq 'L') { '.ldf' } else { '.ndf' } }
                            $dir = if ($f.Type -eq 'L') { [string]$paths.l } else { [string]$paths.d }
                            $leaf = ($target + '_' + $f.LogicalName) -replace '[\\/:*?"<>|]', '_'
                            "MOVE $(SqlText ([string]$f.LogicalName)) TO $(SqlText (Join-Path $dir ($leaf + $ext)))"
                        }
                        Say "restoring $target ..."
                        $sw = [System.Diagnostics.Stopwatch]::StartNew()
                        Invoke-SqlCommand ("RESTORE DATABASE $(SqlName $target) FROM DISK = $(SqlText $bak) WITH CHECKSUM, RECOVERY, " + ($moves -join ', '))
                        # the old owner was a Windows account of the old laptop
                        Invoke-SqlCommand "ALTER AUTHORIZATION ON DATABASE::$(SqlName $target) TO [sa]"
                        $tables = (Invoke-SqlQuery 'SELECT COUNT(*) AS n FROM sys.tables' $target).Rows[0].n
                        Note "restore $target" 'ok' ('{0} tables, {1:N0}s' -f $tables, $sw.Elapsed.TotalSeconds)
                    } catch {
                        Note "restore $target" 'FAIL' $_.Exception.Message
                    }
                }
            }
        }

        # ---------------------------------------------------- profile
        if (-not $SkipProfile -and ($unlocked -or $DryRun)) {
            Step 'Profile'
            try {
                $P = Join-Path $DataPath 'profile'

                # Claude Code. Newer files already here win; the kit's settings.json wins (backed up first).
                $claudeDir = Join-Path $env:USERPROFILE '.claude'
                if ($DryRun) { Note 'Claude Code (~\.claude)' 'plan' 'memory, skills, plugins, settings' }
                elseif (Test-Path -LiteralPath (Join-Path $P 'claude')) {
                    $ok = Copy-Tree (Join-Path $P 'claude') $claudeDir @('/XF', 'settings.json')
                    $kitSettings = Join-Path $P 'claude\settings.json'
                    if (Test-Path -LiteralPath $kitSettings) { $ok = (Copy-One $kitSettings (Join-Path $claudeDir 'settings.json') -Backup) -and $ok }
                    Note 'Claude Code (~\.claude)' (Status $ok) 'memory, skills, plugins, settings'
                }

                # MCP servers go into ~\.claude.json, merged by Python because that file is Claude's own state
                $mcpFile = Join-Path $P 'claude-mcpServers.json'
                if ($DryRun) { Note 'Claude MCP servers' 'plan' 'add to ~\.claude.json' }
                elseif (Test-Path -LiteralPath $mcpFile) {
                    if (-not (Have 'py')) { Note 'Claude MCP servers' 'FAIL' 'Python launcher (py) not found' }
                    else {
                        $merge = Join-Path $env:TEMP 'scanb-merge-mcp.py'
                        Write-Utf8 $merge @'
import json, os, sys
src, old_profile = sys.argv[1], sys.argv[2]
home = os.path.expanduser('~')
with open(src, encoding='utf-8-sig') as f:
    text = f.read()
for old, new in ((old_profile, home), (old_profile.replace('\\', '/'), home.replace('\\', '/'))):
    text = text.replace(json.dumps(old)[1:-1], json.dumps(new)[1:-1])
servers = json.loads(text)
path = os.path.join(home, '.claude.json')
data = {}
if os.path.exists(path):
    with open(path, encoding='utf-8-sig') as f:
        data = json.load(f)
mine = data.setdefault('mcpServers', {})
added = [k for k in servers if k not in mine]
for k in added:
    mine[k] = servers[k]
if added:
    tmp = path + '.scanbkit-tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)
print(', '.join(added) if added else 'already there')
'@
                        $claudeJson = Join-Path $env:USERPROFILE '.claude.json'
                        if (Test-Path -LiteralPath $claudeJson) { $null = Copy-One $claudeJson "$claudeJson.bak-scanbkit-$(Get-Date -Format yyyyMMddHHmmss)" }
                        $out = & py -3 $merge $mcpFile $Kit.oldUserProfile 2>&1
                        if ($LASTEXITCODE -eq 0) { Note 'Claude MCP servers' 'ok' (Tail $out) } else { Note 'Claude MCP servers' 'FAIL' (Tail $out) }
                        Remove-Item -LiteralPath $merge -Force -ErrorAction SilentlyContinue
                    }
                }

                if ($DryRun -or (Test-Path -LiteralPath (Join-Path $P 'UserSecrets'))) {
                    $ok = $DryRun -or (Copy-Tree (Join-Path $P 'UserSecrets') "$env:APPDATA\Microsoft\UserSecrets")
                    Note '.NET user secrets' (Status $ok)
                }

                $gitconfig = Join-Path $env:USERPROFILE '.gitconfig'
                if (Test-Path -LiteralPath $gitconfig) { Note '.gitconfig' 'skip' 'one exists already' }
                elseif ($DryRun -or (Test-Path -LiteralPath (Join-Path $P 'gitconfig'))) {
                    $ok = $DryRun -or (Copy-One (Join-Path $P 'gitconfig') $gitconfig); Note '.gitconfig' (Status $ok)
                }

                if ($DryRun -or (Test-Path -LiteralPath (Join-Path $P 'codex'))) {
                    $ok = $DryRun -or (Copy-Tree (Join-Path $P 'codex') (Join-Path $env:USERPROFILE '.codex'))
                    Note 'Codex settings' (Status $ok) 'sign in to Codex again'
                }

                # VS Code settings and extensions
                $codeUser = Join-Path $env:APPDATA 'Code\User'
                if ($DryRun -or (Test-Path -LiteralPath (Join-Path $P 'vscode'))) {
                    $ok = $true
                    if (-not $DryRun) {
                        foreach ($f in 'settings.json', 'keybindings.json') {
                            $src = Join-Path $P "vscode\$f"
                            if (Test-Path -LiteralPath $src) { $ok = (Copy-One $src (Join-Path $codeUser $f) -Backup) -and $ok }
                        }
                        $null = Copy-Tree (Join-Path $P 'vscode\snippets') (Join-Path $codeUser 'snippets')
                    }
                    Note 'VS Code settings' (Status $ok)
                }
                $extFile = Join-Path $P 'vscode-extensions.txt'
                if (Test-Path -LiteralPath $extFile) {
                    $code = @("$env:ProgramFiles\Microsoft VS Code\bin\code.cmd", "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
                    $wanted = @(Get-Content -LiteralPath $extFile | Where-Object { $_.Trim() })
                    if (-not $code) { Note 'VS Code extensions' 'FAIL' 'VS Code not found' }
                    else {
                        $have = @(& $code --list-extensions 2>$null)
                        $todo = @($wanted | Where-Object { $have -notcontains $_ })
                        if (-not $todo.Count) { Note 'VS Code extensions' 'skip' 'all installed' }
                        else {
                            $bad = @()
                            foreach ($e in $todo) { & $code --install-extension $e --force *> $null; if ($LASTEXITCODE -ne 0) { $bad += $e } }
                            if ($bad.Count) { Note 'VS Code extensions' 'FAIL' ('failed: ' + ($bad -join ', ')) } else { Note 'VS Code extensions' 'ok' "$($todo.Count) installed" }
                        }
                    }
                } elseif ($DryRun) { Note 'VS Code extensions' 'plan' }

                # HTTPS dev certificate for https://localhost:5000
                if (Have 'dotnet') {
                    & dotnet dev-certs https --check --trust *> $null
                    if ($LASTEXITCODE -eq 0) { Note 'HTTPS dev certificate' 'skip' 'already trusted' }
                    elseif ($DryRun) { Note 'HTTPS dev certificate' 'plan' }
                    else {
                        Say 'trusting the ASP.NET HTTPS dev certificate (click Yes on the Windows prompt) ...'
                        & dotnet dev-certs https --trust *> $null
                        Note 'HTTPS dev certificate' (Status ($LASTEXITCODE -eq 0))
                    }
                }
            } catch { Fail 'profile' $_ }
        }

        # ---------------------------------------------------- user folders
        $uf = Join-Path $DataPath 'userfolders'
        if (-not $SkipUserFolders -and $Kit.userFoldersArchive -and ($unlocked -or $DryRun)) {
            Step 'User folders'
            try {
                $downloads = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' -ErrorAction SilentlyContinue).'{374DE290-123F-4565-9164-39C4925E467B}'
                $targets = @{
                    Desktop = [Environment]::GetFolderPath('Desktop'); Documents = [Environment]::GetFolderPath('MyDocuments')
                    Downloads = $downloads; Pictures = [Environment]::GetFolderPath('MyPictures')
                    Videos = [Environment]::GetFolderPath('MyVideos'); Music = [Environment]::GetFolderPath('MyMusic')
                }
                if ($DryRun) { Note 'user folders' 'plan' 'Desktop, Documents, Downloads, Pictures, Videos, Music' }
                else {
                    foreach ($dir in @(Get-ChildItem -LiteralPath $uf -Directory -ErrorAction SilentlyContinue)) {
                        $to = $targets[$dir.Name]
                        if (-not $to) { Note $dir.Name 'skip' 'no matching folder'; continue }
                        $ok = Copy-Tree $dir.FullName $to @('/XF', 'desktop.ini')
                        Note $dir.Name (Status $ok) "to $to"
                    }
                }
            } catch { Fail 'user folders' $_ }
        }

        # ---------------------------------------------------- tidy up
        if ($encrypted -and -not $DryRun -and (Test-Path -LiteralPath $Unpacked)) {
            $dataFailed = @($Results | Where-Object { $_.Status -in @('FAIL', 'todo') -and $_.Item -match '^(unlock kit|restore |database restore|profile|Claude|\.NET user secrets|\.gitconfig|Codex|VS Code settings|user folders|Desktop|Documents|Downloads|Pictures|Videos|Music)' })
            if ($dataFailed.Count) {
                Note 'unpacked kit' 'todo' "kept at $Unpacked for the re-run (it holds secrets; a clean re-run deletes it)"
            } else {
                Remove-Item -LiteralPath $Unpacked -Recurse -Force -ErrorAction SilentlyContinue
                Note 'unpacked kit' $(if (Test-Path -LiteralPath $Unpacked) { 'FAIL' } else { 'ok' }) 'deleted from this machine'
            }
        }
    }

    # ============================================================== CUTOVER
    if ($runCutover) {
        Step 'Cutover: the repos'
        if (-not $NewWorkspace) {
            Note 'cutover' 'todo' 'ScanB-Platform is not in OneDrive here yet. Let OneDrive sync, then double-click Setup-NewMachine-Cutover.cmd'
            $runCutover = $false
        } elseif ($isAdmin -and -not $DryRun) {
            Note 'cutover' 'todo' 'needs a normal window: OneDrive will not download files for an administrator. Double-click Setup-NewMachine.cmd (not "Run as administrator").'
            $runCutover = $false
        } elseif ($Phase -eq 'All' -and -not $Yes -and -not $DryRun) {
            Say 'The next steps change files inside your OneDrive repos: Python environments, build output'
            Say 'and config paths. Those changes sync back to the old laptop, so only go ahead once the'
            Say 'old laptop is finished with the repos and OneDrive there shows "Up to date".'
            if (-not (Ask 'Is the old laptop done with the repos?' $false)) {
                Note 'cutover' 'todo' 'later, double-click Setup-NewMachine-Cutover.cmd'
                $runCutover = $false
            }
        }
    }
    if ($runCutover) {
        $repoPath = @{}
        foreach ($k in $Repos.Keys) { $repoPath[$k] = Join-Path $NewWorkspace $Repos[$k] }

        # the repos, kept on this device: git and builds read every file
        try {
            $missing = @($Repos.Keys | Where-Object { -not (Test-Path -LiteralPath $repoPath[$_]) })
            if ($missing.Count) { Note 'repos present' 'FAIL' ('not synced yet: ' + ($missing -join ', ')) } else { Note 'repos present' 'ok' $NewWorkspace }
            if (-not $DryRun) {
                foreach ($k in $Repos.Keys) {
                    if (-not (Test-Path -LiteralPath $repoPath[$k])) { continue }
                    & attrib.exe +P -U $repoPath[$k] *> $null
                    & attrib.exe +P -U /S /D (Join-Path $repoPath[$k] '*') *> $null
                }
            }
            Note 'OneDrive: keep repos on this device' (Status $true)
        } catch { Fail 'OneDrive: keep repos on this device' $_ }

        $h = $null
        try {
            $existing = @($Repos.Keys | ForEach-Object { $repoPath[$_] } | Where-Object { Test-Path -LiteralPath $_ })
            $h = Invoke-Hydrate $existing
            if ($DryRun) { Note 'OneDrive: download the repos' 'plan' "$($h.Pending) file(s) still cloud-only" }
            elseif ($h.Failed.Count) {
                $names = ($h.Failed | Select-Object -First 5 | ForEach-Object { $_.Substring($NewWorkspace.Length + 1) }) -join '; '
                Note 'OneDrive: download the repos' 'FAIL' ("$($h.Failed.Count) file(s) OneDrive could not download, e.g. $names. Wait for the green ticks, then run Setup-NewMachine-Cutover.cmd again.")
            }
            elseif ($h.Pending) { Note 'OneDrive: download the repos' 'ok' "$($h.Read) downloaded, $($h.Recreated) empty file(s) recreated" }
            else { Note 'OneDrive: download the repos' 'skip' 'everything already on this device' }
        } catch { Fail 'OneDrive: download the repos' $_ }

        # Python byte-code caches synced from the old laptop carry its paths; Python and pytest
        # rebuild them. Done once, and only after the download above (an empty __init__.py that
        # cannot be read is exactly what these caches were hiding).
        try {
            $marker = Join-Path $env:LOCALAPPDATA 'ScanB-Setup\pycache-cleared'
            if (Test-Path -LiteralPath $marker) { Note 'old Python caches' 'skip' 'cleared on an earlier run' }
            elseif (-not $h -or $h.Failed.Count) { Note 'old Python caches' 'skip' 'kept until every repo file has downloaded' }
            else {
                $caches = @(foreach ($k in 'AI Bot', 'Insight', 'Messaging') {
                    Get-ChildItem -LiteralPath $repoPath[$k] -Recurse -Force -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -in @('__pycache__', '.pytest_cache') -and $_.FullName -notmatch '\\(\.venv|venv|node_modules)\\' }
                })
                if (-not $DryRun) {
                    foreach ($c in $caches) { Remove-Item -LiteralPath $c.FullName -Recurse -Force -ErrorAction SilentlyContinue }
                    Write-Utf8 $marker (Get-Date).ToString('s')
                }
                Note 'old Python caches' (Status $true) "$($caches.Count) folder(s) removed; Python rebuilds them"
            }
        } catch { Fail 'old Python caches' $_ }

        # Claude memory folders follow the path
        try {
            $projects = Join-Path $env:USERPROFILE '.claude\projects'
            if (Test-Path -LiteralPath $projects) {
                $maps = @()
                foreach ($pair in $PathPairs) { if ($pair[0] -and $pair[0] -ine $pair[1]) { $maps += , @((Get-ClaudeKey $pair[0]), (Get-ClaudeKey $pair[1])) } }
                $moved = 0; $problems = @()
                foreach ($dir in @(Get-ChildItem -LiteralPath $projects -Directory)) {
                    foreach ($m in $maps) {
                        if ($dir.Name -ieq $m[0] -or $dir.Name.StartsWith($m[0] + '-', [StringComparison]::OrdinalIgnoreCase)) {
                            $newKey = $m[1]
                            if ($dir.Name.Substring(0, 1) -cne $newKey.Substring(0, 1)) { $newKey = $dir.Name.Substring(0, 1) + $newKey.Substring(1) }   # keep the drive letter's case
                            $newName = $newKey + $dir.Name.Substring($m[0].Length)
                            $dest = Join-Path $projects $newName
                            if (-not $DryRun) {
                                try {
                                    if (Test-Path -LiteralPath $dest) { if (-not (Copy-Tree $dir.FullName $dest)) { throw 'robocopy failed' } }
                                    else { Rename-Item -LiteralPath $dir.FullName -NewName $newName -ErrorAction Stop }
                                    $moved++
                                } catch { $problems += "$($dir.Name): $($_.Exception.Message)" }
                            } else { $moved++ }
                            break
                        }
                    }
                }
                $mdFixed = 0
                foreach ($md in @(Get-ChildItem -LiteralPath $projects -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { $_.Directory.Name -eq 'memory' })) {
                    try { if (Update-PathsInFile $md.FullName $PathPairs) { $mdFixed++ } } catch { $problems += "$($md.Name): $($_.Exception.Message.Trim())" }
                }
                $detail = "$moved moved to the new path, $mdFixed memory files updated"
                if ($problems.Count) { Note 'Claude memory folders' 'FAIL' ($detail + '; ' + ($problems -join '; ')) } else { Note 'Claude memory folders' (Status $true) $detail }
            }
        } catch { Fail 'Claude memory folders' $_ }

        # config files that hold absolute paths
        try {
            $configs = @(
                (Join-Path $repoPath['Platform'] '.claude\settings.json'),
                (Join-Path $repoPath['Platform'] '.claude\settings.local.json'),
                (Join-Path $NewWorkspace 'TurnB_ScanB_WebApplication_latest\.claude\settings.local.json')
            )
            foreach ($k in 'Web App', 'AI Bot', 'Insight', 'Messaging') { $configs += Join-Path $repoPath[$k] '.claude\settings.local.json' }
            $fixed = @(); $problems = @()
            foreach ($c in $configs) {
                try { if (Update-PathsInFile $c $PathPairs) { $fixed += $c.Substring($NewWorkspace.Length + 1) } }
                catch { $problems += ($c.Substring($NewWorkspace.Length + 1) + ': ' + $_.Exception.Message.Trim()) }
            }
            if ($problems.Count) { Note 'old paths in Claude settings' 'FAIL' ($problems -join '; ') }
            elseif ($fixed.Count) { Note 'old paths in Claude settings' (Status $true) ($fixed -join ', ') }
            else { Note 'old paths in Claude settings' 'skip' 'nothing to change' }
        } catch { Fail 'old paths in Claude settings' $_ }

        # the Web App's connection string named the old laptop
        try {
            $appsettings = Join-Path $repoPath['Web App'] 'appsettings.json'
            if (Test-Path -LiteralPath $appsettings) {
                $f = Read-TextFile $appsettings
                $pattern = '(?i)((?:Server|Data Source)\s*=\s*(?:tcp:)?)' + [regex]::Escape($Kit.oldMachine) + '(?=[;,\\"])'
                $new = [regex]::Replace($f.Text, $pattern, '${1}localhost')
                if ($new -ceq $f.Text) { Note 'Web App SQL server name' 'skip' 'no old machine name in appsettings.json' }
                else {
                    if (-not $DryRun) { Write-Utf8 $appsettings $new $f.Bom }
                    Note 'Web App SQL server name' (Status $true) "$($Kit.oldMachine) -> localhost"
                }
            } else { Note 'Web App appsettings.json' 'FAIL' 'not found (it is gitignored, so it only arrives through OneDrive)' }
        } catch { Fail 'Web App SQL server name' $_ }

        # Python
        try {
            if (-not (Have 'py')) { Note 'Python environments' 'FAIL' 'Python launcher (py) not found; is Python 3.12 installed?' }
            else {
                Initialize-Venv 'AI Bot' $repoPath['AI Bot'] @('requirements.txt', 'requirements-dev.txt')
                Initialize-Venv 'Messaging' $repoPath['Messaging'] @('requirements-dev.txt')
                # Auto-Insight runs on the main Python (its gate calls plain "python"); --user
                # because Cutover runs without administrator rights
                $req = Join-Path $repoPath['Insight'] 'powerbi-summary-agent\requirements.txt'
                if ($DryRun) { Note 'Auto-Insight packages' 'plan' 'pip install --user into Python 3.12' }
                else {
                    $out = & py -3.12 -m pip install --user -r $req --quiet --disable-pip-version-check 2>&1
                    Note 'Auto-Insight packages' (Status ($LASTEXITCODE -eq 0)) $(if ($LASTEXITCODE -eq 0) { 'into Python 3.12 (user site)' } else { Tail $out })
                }
                $pyv = if (Have 'python') { Tail (& python --version 2>&1) } else { 'missing' }
                if ($pyv -notmatch 'Python 3\.12') { Note '"python" on PATH' 'FAIL' "is '$pyv'; turn off the python App Execution Alias in Windows Settings" }
            }
        } catch { Fail 'Python environments' $_ }

        # .NET and the UI checks
        try {
            if ($DryRun) { Note 'Web App NuGet restore' 'plan'; Note 'Web App ui/ (npm + Playwright)' 'plan' }
            else {
                Push-Location $repoPath['Web App']
                $out = & dotnet restore TurnRetailWebApp.csproj --nologo -v:minimal 2>&1
                $code = $LASTEXITCODE; Pop-Location
                Note 'Web App NuGet restore' (Status ($code -eq 0)) $(if ($code -ne 0) { Tail $out })
                $ui = Join-Path $repoPath['Web App'] 'ui'
                if ((Test-Path -LiteralPath (Join-Path $ui 'package.json')) -and (Have 'npm')) {
                    Push-Location $ui
                    $out = & npm ci --no-audit --no-fund 2>&1; $code = $LASTEXITCODE
                    if ($code -eq 0) { $out = & npx --yes playwright install chromium 2>&1; $code = $LASTEXITCODE }
                    Pop-Location
                    Note 'Web App ui/ (npm + Playwright)' (Status ($code -eq 0)) $(if ($code -ne 0) { Tail $out })
                }
            }
        } catch { Fail 'Web App build setup' $_ }

        # Azurite, for Messaging's store contract tests
        try {
            if (-not (Have 'docker')) { Note 'Azurite container' 'todo' 'Docker is not installed' }
            else {
                & docker info *> $null
                if ($LASTEXITCODE -ne 0) { Note 'Azurite container' 'todo' 'restart Windows, open Docker Desktop once (accept its terms), then double-click Setup-NewMachine-Cutover.cmd' }
                else {
                    $cid = & docker ps -a --filter 'name=^scanb-azurite$' --format '{{.ID}}' 2>$null
                    if ($cid) { Note 'Azurite container' 'skip' 'scanb-azurite exists' }
                    elseif ($DryRun) { Note 'Azurite container' 'plan' }
                    else {
                        & docker run -d --name scanb-azurite -p 127.0.0.1:10000-10002:10000-10002 mcr.microsoft.com/azure-storage/azurite azurite --blobHost 0.0.0.0 --tableHost 0.0.0.0 --queueHost 0.0.0.0 --loose --skipApiVersionCheck *> $null
                        Note 'Azurite container' (Status ($LASTEXITCODE -eq 0)) 'scanb-azurite'
                    }
                }
            }
        } catch { Fail 'Azurite container' $_ }

        # the four repo gates
        try {
            $check = Join-Path $repoPath['Platform'] 'scripts\check.ps1'
            if ($DryRun) { Note 'repo gates (check.ps1)' 'plan' }
            elseif (Test-Path -LiteralPath $check) {
                Step 'Repo gates'
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $check
                Note 'repo gates (check.ps1)' (Status ($LASTEXITCODE -eq 0)) $(if ($LASTEXITCODE -eq 0) { 'all four green' } else { 'see the output above' })
            }
        } catch { Fail 'repo gates (check.ps1)' $_ }
    }
} catch {
    Fail 'setup stopped' $_
} finally {
    $pass = $null
    # ------------------------------------------------------------------ summary
    Step 'Summary'
    $failed = @($Results | Where-Object { $_.Status -eq 'FAIL' })
    $todo = @($Results | Where-Object { $_.Status -eq 'todo' })
    foreach ($r in @($failed) + @($todo)) { Say ('{0,-40} {1,-5} {2}' -f $r.Item, $r.Status, $r.Detail) $(if ($r.Status -eq 'FAIL') { 'Red' } else { 'Yellow' }) }
    if (-not $failed.Count -and -not $todo.Count) { Say 'Everything done.' 'Green' }
    Write-Host ''
    if ($script:NeedsReboot) { Say 'Restart Windows, then run Setup-NewMachine.cmd again to finish what needed the restart.' 'Yellow' }
    if (-not $PauseAtEnd) {
        Say 'Sign in by hand (logins are never copied):' 'Cyan'
        Say '  az login                          Azure CLI'
        Say '  Claude Code / Claude desktop      first launch asks you to sign in'
        Say '  GitHub                            the first git fetch or push opens a browser'
        Say '  Power BI Desktop, Docker Desktop  first launch'
        Say '  Sophos Connect VPN                profile from IT'
        Say 'Not migrated on purpose: Oracle XE, the OnPremTestDB Power BI gateway, Docker images.'
        Say 'Once this laptop works, delete the ScanB-Migration-Kit folder from OneDrive.' 'Yellow'
    }
    Say "log: $logFile"
    Stop-Transcript | Out-Null
    # copy this machine's setup logs into the kit (OneDrive), so they can be read from the
    # old laptop; they hold no secrets (the passphrase is never echoed)
    if ($KitPath -and -not $DryRun -and (Test-Path -LiteralPath (Join-Path $KitPath 'kit.json'))) {
        $dest = Join-Path $KitPath "logs\$env:COMPUTERNAME"
        try {
            $null = New-Item -ItemType Directory -Force -Path $dest -ErrorAction Stop
            Get-ChildItem -LiteralPath $logDir -Filter 'setup-*.log' -ErrorAction SilentlyContinue | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $dest -Force -ErrorAction SilentlyContinue }
        } catch { }
    }
}
if ($PauseAtEnd) {
    Write-Host ''
    Read-Host '   Prepare is done. Press Enter to close this window and go back to the first one' | Out-Null
}
if (@($Results | Where-Object { $_.Status -eq 'FAIL' }).Count) { exit 1 }
exit 0
