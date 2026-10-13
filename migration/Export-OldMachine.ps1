<#
.SYNOPSIS
  Packs what a new laptop needs, and OneDrive does not already carry, into an
  encrypted kit in OneDrive.

.DESCRIPTION
  Run this on the OLD laptop. It writes the kit to OneDrive\ScanB-Migration-Kit
  (or -KitPath):

    profile.7z         Claude Code memory, skills, settings and MCP servers, .NET user
                       secrets, .gitconfig, Codex and VS Code settings, extension list
    sql-<db>.7z        a compressed, verified COPY_ONLY backup of each chosen database
    userfolders.7z     Desktop, Documents, Downloads, Pictures, Videos, Music
    kit.json           what this machine looked like: paths, SQL collation, databases,
                       repos. No secrets, so not encrypted.
    Setup-NewMachine.cmd/.ps1, README.md   the setup for the new laptop
    logs\              a transcript of this run

  Every .7z is AES-256 encrypted with a passphrase you choose, file names included,
  so nothing readable lands in OneDrive. You type the passphrase again on the new
  laptop; never store it in OneDrive.

  Nothing is installed here: if 7-Zip is missing, a private copy is unpacked into
  %LOCALAPPDATA%\ScanB-Kit-tools. Working files go to %LOCALAPPDATA%\ScanB-Kit-staging
  (outside OneDrive) and are deleted at the end. The one change to this laptop: the
  SQL Server service may write into that staging folder, because BACKUP runs as it.

  The repos themselves are not in the kit: they arrive through OneDrive, and every
  branch is on GitHub.

.EXAMPLE
  .\Export-OldMachine.ps1
  Asks which databases, whether to take the user folders, and for a passphrase.

.EXAMPLE
  .\Export-OldMachine.ps1 -AllDatabases -SkipUserFolders

.EXAMPLE
  .\Export-OldMachine.ps1 -DryRun
  Shows what would be packed and the space it needs. Writes nothing.
#>
[CmdletBinding()]
param(
    [string]$KitPath,
    [string[]]$Databases,
    [switch]$AllDatabases,
    [switch]$SkipDatabases,
    [switch]$SkipUserFolders,
    [securestring]$Passphrase,
    [string]$SevenZip,
    [switch]$DryRun
)

# Not 'Stop': Windows PowerShell 5.1 turns any stderr line from git, winget or 7-Zip
# into a terminating error under 'Stop'. Failures are caught explicitly instead.
$ErrorActionPreference = 'Continue'
# Windows PowerShell 5.1 serialises some arrays as {"value":[...],"Count":n} unless this goes.
try { Remove-TypeData -TypeName System.Array -ErrorAction Stop } catch { }

$Platform  = Split-Path -Parent $PSScriptRoot          # ...\ScanB-Platform
$Workspace = Split-Path -Parent $Platform              # the folder holding ScanB-Platform and the repos
$Repos = @(
    'ScanB-Platform',
    'TurnB_ScanB_WebApplication_latest\TurnB_ScanB_WebApplication',
    'ScanB-AI-Bot',
    'Auto-Insight-Generation',
    'ScanB-Messaging'
)
$DefaultDatabase = 'TurnretailVMConfigDB'              # what the local Web App runs on
$Staging = Join-Path $env:LOCALAPPDATA 'ScanB-Kit-staging'
$ToolsDir = Join-Path $env:LOCALAPPDATA 'ScanB-Kit-tools'

# ------------------------------------------------------------------ helpers
function Step([string]$text) { Write-Host ''; Write-Host "== $text" -ForegroundColor Cyan }
function Say([string]$text, [string]$colour = 'Gray') { Write-Host "   $text" -ForegroundColor $colour }

function Ask([string]$question, [bool]$default) {
    $hint = if ($default) { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host "   $question $hint"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $default }
    return @('y', 'yes') -contains $answer.Trim().ToLower()
}

function Get-FolderBytes([string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return [long]0 }
    $sum = (Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum).Sum
    if ($sum) { return [long]$sum } else { return [long]0 }
}

function GB([double]$bytes) { '{0:N1} GB' -f ($bytes / 1GB) }

function Write-Utf8([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $false))
}

function Copy-Tree([string]$from, [string]$to, [string[]]$extra = @()) {
    if (-not (Test-Path -LiteralPath $from)) { return $false }
    $rc = @($from, $to, '/E', '/R:1', '/W:1', '/XJ', '/NFL', '/NDL', '/NP', '/NJH', '/NJS') + $extra
    & robocopy.exe @rc | Out-Null
    return ($LASTEXITCODE -lt 8)      # robocopy: 0-7 are success codes
}

function Copy-One([string]$from, [string]$to) {
    if (-not (Test-Path -LiteralPath $from)) { return $false }
    try {
        $dir = Split-Path -Parent $to
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop }
        Copy-Item -LiteralPath $from -Destination $to -Force -ErrorAction Stop
        return $true
    } catch { Say "could not copy $from ($($_.Exception.Message))" 'Red'; return $false }
}

function Open-Sql([string]$database = 'master') {
    $cn = New-Object System.Data.SqlClient.SqlConnection(
        "Server=localhost;Database=$database;Integrated Security=True;TrustServerCertificate=True;Connect Timeout=15")
    $cn.Open()
    return $cn
}

function Invoke-SqlQuery([string]$query, [string]$database = 'master') {
    $cn = Open-Sql $database
    try {
        $cmd = $cn.CreateCommand(); $cmd.CommandText = $query; $cmd.CommandTimeout = 0
        $table = New-Object System.Data.DataTable
        $table.Load($cmd.ExecuteReader())
        return , $table
    } finally { $cn.Close() }
}

function Invoke-SqlCommand([string]$query, [string]$database = 'master') {
    $cn = Open-Sql $database
    try {
        $cmd = $cn.CreateCommand(); $cmd.CommandText = $query; $cmd.CommandTimeout = 0
        [void]$cmd.ExecuteNonQuery()
    } finally { $cn.Close() }
}

function SqlName([string]$name) { '[' + $name.Replace(']', ']]') + ']' }
function SqlText([string]$text) { "N'" + $text.Replace("'", "''") + "'" }

function Get-Plain([securestring]$s) {
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

# 7-Zip: the installed one, else a private copy unpacked from the signed winget MSI (no install, no admin)
function Get-SevenZip {
    foreach ($c in @($SevenZip, (Join-Path $env:ProgramFiles '7-Zip\7z.exe'), (Join-Path $ToolsDir '7zip\Files\7-Zip\7z.exe'))) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    Say 'fetching a private copy of 7-Zip (nothing is installed) ...'
    $dl = Join-Path $ToolsDir 'download'
    $null = New-Item -ItemType Directory -Force -Path $dl
    & winget download --id 7zip.7zip --exact --download-directory $dl --accept-package-agreements --accept-source-agreements --disable-interactivity *> $null
    $msi = Get-ChildItem -LiteralPath $dl -Filter '*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $msi) { throw 'Could not download 7-Zip with winget.' }
    $p = Start-Process msiexec.exe -ArgumentList @('/a', "`"$($msi.FullName)`"", '/qn', "TARGETDIR=`"$ToolsDir\7zip`"") -Wait -PassThru
    $exe = Join-Path $ToolsDir '7zip\Files\7-Zip\7z.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "Could not unpack 7-Zip (msiexec exit $($p.ExitCode))." }
    return $exe
}

# One encrypted archive; 7-Zip exit 1 means warnings (a file it could not read), 2+ is a failure.
function New-KitArchive([string]$archive, [string[]]$sources, [string[]]$extra = @()) {
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    $a = @('a', '-t7z', '-mhe=on', "-p$script:Pass", '-bso0', '-bsp0', $archive) + $sources + $extra
    $out = & $script:Sz @a 2>&1
    $code = $LASTEXITCODE
    if ($code -ge 2) { return @{ Ok = $false; Detail = "7-Zip exit $code. " + (($out | ForEach-Object { "$_" } | Where-Object { $_.Trim() } | Select-Object -Last 2) -join ' ') } }
    & $script:Sz t $archive "-p$script:Pass" -bso0 -bsp0 *> $null
    if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Detail = 'the archive did not test clean' } }
    $len = (Get-Item -LiteralPath $archive).Length
    $detail = (GB $len) + ', encrypted and tested'
    if ($code -eq 1) { $detail += ' (some unreadable files skipped)' }
    return @{ Ok = $true; Detail = $detail; Bytes = $len }
}

# ------------------------------------------------------------------ where the kit goes
Write-Host 'ScanB migration kit: export from this laptop' -ForegroundColor Cyan
if ($DryRun) { Write-Host '(dry run: nothing is written)' -ForegroundColor Yellow }

$OneDriveRoot = if ($env:OneDriveCommercial) { $env:OneDriveCommercial } else { $env:OneDrive }
if (-not $KitPath) {
    if (-not $OneDriveRoot) { throw 'OneDrive is not signed in here; pass -KitPath.' }
    $KitPath = Join-Path $OneDriveRoot 'ScanB-Migration-Kit'
}
$KitPath = [System.IO.Path]::GetFullPath($KitPath)
foreach ($rel in $Repos) {
    $r = (Join-Path $Workspace $rel).TrimEnd('\')
    if ($KitPath -ieq $r -or $KitPath.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Put the kit outside the repos (it is inside $rel, where git would see it)."
    }
}

# ------------------------------------------------------------------ survey
Step 'Survey'
$underOneDrive = $null
if ($OneDriveRoot) {
    $od = $OneDriveRoot.TrimEnd('\')
    if ($Workspace -ieq $od) { $underOneDrive = '' }
    elseif ($Workspace.StartsWith($od + '\', [StringComparison]::OrdinalIgnoreCase)) { $underOneDrive = $Workspace.Substring($od.Length + 1) }
}
Say "workspace: $Workspace"
Say "kit:       $KitPath"

# SQL Server
$sqlCollation = $null; $allDbs = @()
try {
    $sqlCollation = (Invoke-SqlQuery "SELECT CAST(SERVERPROPERTY('Collation') AS nvarchar(128)) AS c").Rows[0].c
    # allocated data-file size from the catalog: a safe upper bound, and it does not open
    # each database (which fails when SQL Server is short of memory)
    $t = Invoke-SqlQuery @"
SET NOCOUNT ON;
SELECT d.name, d.collation_name AS coll, SUM(CAST(mf.size AS bigint)) * 8 / 1024.0 AS used_mb
FROM sys.databases d JOIN sys.master_files mf ON mf.database_id = d.database_id AND mf.type = 0
WHERE d.database_id > 4 AND d.state_desc = 'ONLINE' AND d.name <> 'SSISDB'
GROUP BY d.name, d.collation_name ORDER BY d.name;
"@
    $allDbs = @($t.Rows | ForEach-Object { [pscustomobject]@{ Name = $_.name; Collation = $_.coll; UsedMB = [double]$_.used_mb } })
    Say "SQL Server: collation $sqlCollation, $($allDbs.Count) user databases (SSISDB left out: it needs its own key)"
    foreach ($d in $allDbs) { Say ('  {0,-26} {1,10:N0} MB of data files' -f $d.Name, $d.UsedMB) }
} catch {
    Say "SQL Server not reachable on localhost ($($_.Exception.Message)); databases skipped." 'Yellow'
    $SkipDatabases = $true
}

# which databases
$chosen = @()
if (-not $SkipDatabases) {
    if ($AllDatabases) { $chosen = @($allDbs | ForEach-Object { $_.Name }) }
    elseif ($PSBoundParameters.ContainsKey('Databases')) { $chosen = @($Databases) }
    elseif ($DryRun) { $chosen = @($DefaultDatabase) }
    else {
        $allEst = ($allDbs | Measure-Object UsedMB -Sum).Sum * 0.35 * 1MB
        Say "Default is only $DefaultDatabase, which the local Web App needs."
        if (Ask "Take ALL of them instead (roughly $(GB $allEst) more to upload)?" $false) {
            $chosen = @($allDbs | ForEach-Object { $_.Name })
        } else { $chosen = @($DefaultDatabase) }
    }
    $missing = @($chosen | Where-Object { $n = $_; -not ($allDbs | Where-Object { $_.Name -ieq $n }) })
    if ($missing.Count) { throw "Not on this SQL Server: $($missing -join ', ')" }
}
$chosenDbs = @($allDbs | Where-Object { $chosen -contains $_.Name })
# compressed backups run ~25-35% of used space
$dbEstimate = [long](($chosenDbs | Measure-Object UsedMB -Sum).Sum * 0.35 * 1MB)
$dbLargest = [long](($chosenDbs | Measure-Object UsedMB -Maximum).Maximum * 0.35 * 1MB)

# user folders (not under OneDrive on this laptop: Known Folder Move is off)
$downloads = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' -ErrorAction SilentlyContinue).'{374DE290-123F-4565-9164-39C4925E467B}'
$userFolders = @(
    @{ Name = 'Desktop';   Path = [Environment]::GetFolderPath('Desktop') },
    @{ Name = 'Documents'; Path = [Environment]::GetFolderPath('MyDocuments') },
    @{ Name = 'Downloads'; Path = $downloads },
    @{ Name = 'Pictures';  Path = [Environment]::GetFolderPath('MyPictures') },
    @{ Name = 'Videos';    Path = [Environment]::GetFolderPath('MyVideos') },
    @{ Name = 'Music';     Path = [Environment]::GetFolderPath('MyMusic') }
) | Where-Object { $_.Path -and (Test-Path -LiteralPath $_.Path) -and ((Split-Path -Leaf $_.Path) -eq $_.Name) }
$userBytes = [long]0
if (-not $SkipUserFolders) {
    foreach ($f in $userFolders) { $f.Bytes = Get-FolderBytes $f.Path; $userBytes += $f.Bytes }
    if (-not $PSBoundParameters.ContainsKey('SkipUserFolders') -and -not $DryRun) {
        $list = ($userFolders | ForEach-Object { '{0} {1}' -f $_.Name, (GB $_.Bytes) }) -join ', '
        Say "User folders: $list"
        if (-not (Ask "Take them too ($(GB $userBytes) to upload)?" $true)) { $SkipUserFolders = $true; $userBytes = 0 }
    }
}

$claudeDir = Join-Path $env:USERPROFILE '.claude'
$profileBytes = (Get-FolderBytes (Join-Path $claudeDir 'projects')) + (Get-FolderBytes "$env:APPDATA\Microsoft\UserSecrets") + 50MB
# archives (kept) + the largest temporary backup + the profile staging copy
$upload = $dbEstimate + $userBytes + $profileBytes
$need = $upload + $dbLargest + $profileBytes
$drive = New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot($KitPath))
$free = if ($drive.IsReady) { $drive.AvailableFreeSpace } else { 0 }

Step 'Plan'
Say ("databases:    {0}  (about {1})" -f $(if ($chosen.Count) { $chosen -join ', ' } else { 'none' }), (GB $dbEstimate))
Say ("profile:      Claude Code, .NET user secrets, git, Codex, VS Code  (about {0})" -f (GB $profileBytes))
Say ("user folders: {0}" -f $(if ($SkipUserFolders) { 'skipped' } else { GB $userBytes }))
Say ("upload:       at most {0} to OneDrive; needs {1} free on {2} while packing, {3} free now" -f (GB $upload), (GB $need), $drive.Name, (GB $free))
if ($free -lt $need * 1.1) {
    $msg = "Not enough free space on $($drive.Name). Take fewer databases or skip the user folders."
    if ($DryRun) { Say $msg 'Yellow' } else { throw $msg }
}
if ($DryRun) { Write-Host ''; Write-Host 'Dry run finished; nothing was written.' -ForegroundColor Yellow; return }

# ------------------------------------------------------------------ passphrase and 7-Zip
Step 'Passphrase'
if (-not $Passphrase) {
    Say 'Choose a passphrase for the kit: at least 12 characters, no double quotes.'
    Say 'You will type it on the new laptop. Do not save it in OneDrive.'
    for ($i = 0; $i -lt 3 -and -not $Passphrase; $i++) {
        $a = Read-Host '   passphrase' -AsSecureString
        $b = Read-Host '   again     ' -AsSecureString
        if ((Get-Plain $a) -cne (Get-Plain $b)) { Say 'They did not match.' 'Yellow' } else { $Passphrase = $a }
    }
    if (-not $Passphrase) { throw 'No passphrase.' }
}
$script:Pass = Get-Plain $Passphrase
if ($script:Pass.Length -lt 12) { throw 'The passphrase needs at least 12 characters.' }
if ($script:Pass.Contains('"')) { throw 'The passphrase cannot contain a double quote.' }
$script:Sz = Get-SevenZip
Say "7-Zip: $script:Sz" 'DarkGray'

# ------------------------------------------------------------------ build the kit
foreach ($d in $KitPath, "$KitPath\logs") { $null = New-Item -ItemType Directory -Force -Path $d -ErrorAction Stop }
if (Test-Path -LiteralPath $Staging) { Remove-Item -LiteralPath $Staging -Recurse -Force }
$null = New-Item -ItemType Directory -Force -Path "$Staging\sql", "$Staging\profile" -ErrorAction Stop
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Start-Transcript -Path "$KitPath\logs\export-$stamp.log" | Out-Null
$results = New-Object System.Collections.ArrayList
function Note([string]$item, [string]$status, [string]$detail = '') {
    [void]$results.Add([pscustomobject]@{ Item = $item; Status = $status; Detail = $detail })
    $colour = switch ($status) { 'ok' { 'Green' } 'skip' { 'DarkGray' } default { 'Red' } }
    Say ('{0,-34} {1,-5} {2}' -f $item, $status, $detail) $colour
}

try {
    # databases: back up to staging, pack, delete the plain backup
    $dbManifest = @()
    if ($chosen.Count) {
        Step 'Databases'
        $sqlDir = Join-Path $Staging 'sql'
        $svc = (Get-CimInstance Win32_Service -Filter "Name='MSSQLSERVER'").StartName
        if ($svc) { & icacls.exe $sqlDir /grant "${svc}:(OI)(CI)M" *> $null }
        foreach ($d in $chosenDbs) {
            $safe = $d.Name -replace '[\\/:*?"<>|]', '_'
            $bak = Join-Path $sqlDir "$safe.bak"
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                Say "backing up $($d.Name) ..."
                Invoke-SqlCommand "BACKUP DATABASE $(SqlName $d.Name) TO DISK = $(SqlText $bak) WITH COPY_ONLY, COMPRESSION, CHECKSUM, INIT, FORMAT, NAME = N'ScanB migration kit'"
                Invoke-SqlCommand "RESTORE VERIFYONLY FROM DISK = $(SqlText $bak) WITH CHECKSUM"
                $bakMB = [math]::Round((Get-Item -LiteralPath $bak).Length / 1MB, 1)
                $r = New-KitArchive (Join-Path $KitPath "sql-$safe.7z") @($bak) @('-mx=0', '-sdel')   # backups are already compressed
                if (-not $r.Ok) { throw $r.Detail }
                $dbManifest += [ordered]@{ name = $d.Name; archive = "sql-$safe.7z"; bakName = "$safe.bak"; collation = $d.Collation; usedMB = $d.UsedMB; backupMB = $bakMB }
                Note "database $($d.Name)" 'ok' ('{0} ({1:N0}s)' -f $r.Detail, $sw.Elapsed.TotalSeconds)
            } catch {
                Note "database $($d.Name)" 'FAIL' $_.Exception.Message
            } finally {
                if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force }
            }
        }
    }

    # profile: gather into staging, then one archive
    Step 'Profile'
    $P = Join-Path $Staging 'profile'
    # Claude Code: memory, skills, plugins, settings. Not the login or the caches.
    $copied = @()
    foreach ($d in 'projects', 'skills', 'plugins', 'plans', 'agents', 'commands', 'output-styles') {
        if (Copy-Tree (Join-Path $claudeDir $d) (Join-Path $P "claude\$d")) { $copied += $d }
    }
    foreach ($f in 'settings.json', 'CLAUDE.md', 'keybindings.json') {
        if (Copy-One (Join-Path $claudeDir $f) (Join-Path $P "claude\$f")) { $copied += $f }
    }
    if ($copied.Count) { Say ('Claude Code: ' + ($copied -join ', ')) }

    # user-scope MCP servers live in ~\.claude.json; the rest of that file is per-machine state
    $claudeJson = Join-Path $env:USERPROFILE '.claude.json'
    $mcp = $null
    if (Test-Path -LiteralPath $claudeJson) {
        try { $mcp = (Get-Content -LiteralPath $claudeJson -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json).mcpServers } catch { Say "could not read ~\.claude.json ($($_.Exception.Message))" 'Red' }
    }
    if ($mcp) {
        Write-Utf8 (Join-Path $P 'claude-mcpServers.json') ($mcp | ConvertTo-Json -Depth 20)
        Say ('MCP servers: ' + (($mcp.PSObject.Properties | ForEach-Object { $_.Name }) -join ', '))
    }
    if (Copy-Tree "$env:APPDATA\Microsoft\UserSecrets" (Join-Path $P 'UserSecrets')) { Say '.NET user secrets' }
    if (Copy-One (Join-Path $env:USERPROFILE '.gitconfig') (Join-Path $P 'gitconfig')) { Say '.gitconfig' }

    $codex = Join-Path $env:USERPROFILE '.codex'
    $codexCopied = @()
    foreach ($f in 'config.toml', 'AGENTS.md') { if (Copy-One (Join-Path $codex $f) (Join-Path $P "codex\$f")) { $codexCopied += $f } }
    foreach ($d in 'prompts', 'skills', 'rules') { if (Copy-Tree (Join-Path $codex $d) (Join-Path $P "codex\$d")) { $codexCopied += $d } }
    if ($codexCopied.Count) { Say ('Codex (not the login): ' + ($codexCopied -join ', ')) }

    $codeUser = Join-Path $env:APPDATA 'Code\User'
    $vs = @()
    foreach ($f in 'settings.json', 'keybindings.json') { if (Copy-One (Join-Path $codeUser $f) (Join-Path $P "vscode\$f")) { $vs += $f } }
    if (Copy-Tree (Join-Path $codeUser 'snippets') (Join-Path $P 'vscode\snippets')) { $vs += 'snippets' }
    $code = Get-Command code -ErrorAction SilentlyContinue
    if ($code) {
        $ext = @(& $code.Source --list-extensions 2>$null)
        if ($ext.Count) { Write-Utf8 (Join-Path $P 'vscode-extensions.txt') (($ext -join "`r`n") + "`r`n"); $vs += "$($ext.Count) extensions" }
    }
    if ($vs.Count) { Say ('VS Code: ' + ($vs -join ', ')) }
    & winget export -o (Join-Path $P 'winget-export.json') --include-versions --accept-source-agreements --disable-interactivity *> $null

    $r = New-KitArchive (Join-Path $KitPath 'profile.7z') @("$P\*") @('-mx=5')
    if ($r.Ok) { Note 'profile' 'ok' $r.Detail } else { Note 'profile' 'FAIL' $r.Detail }

    # user folders: straight from where they are, no staging copy
    $userArchive = $null
    if (-not $SkipUserFolders -and $userFolders) {
        Step 'User folders'
        Say "packing $(GB $userBytes); this is the slow part ..."
        $sources = @($userFolders | ForEach-Object { $_.Path })
        # the hidden "My Music"-style links inside Documents only produce access-denied warnings
        $skip = @('-xr!desktop.ini', '-x!Documents\My Music', '-x!Documents\My Pictures', '-x!Documents\My Videos')
        $r = New-KitArchive (Join-Path $KitPath 'userfolders.7z') $sources (@('-mx=1') + $skip)
        if ($r.Ok) { Note 'user folders' 'ok' $r.Detail; $userArchive = 'userfolders.7z' } else { Note 'user folders' 'FAIL' $r.Detail }
    }

    # repos: recorded for reference only; their files travel through OneDrive
    $repoManifest = @()
    foreach ($rel in $Repos) {
        $path = Join-Path $Workspace $rel
        if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) { continue }
        $repoManifest += [ordered]@{
            path    = $rel
            branch  = [string](git -C $path branch --show-current 2>$null)
            changes = @(git -C $path status --porcelain 2>$null).Count
            remotes = @(git -C $path remote -v 2>$null | Where-Object { $_ -match '\(push\)' } | ForEach-Object { ($_ -split '\s+')[0..1] -join ' ' })
        }
    }

    # manifest and scripts
    Step 'Manifest and setup scripts'
    $manifest = [ordered]@{
        kitVersion             = 2
        createdAt              = (Get-Date).ToString('s')
        encrypted              = $true
        oldMachine             = $env:COMPUTERNAME
        oldUser                = "$env:USERDOMAIN\$env:USERNAME"
        oldUserProfile         = $env:USERPROFILE
        oldOneDriveRoot        = $OneDriveRoot
        oldWorkspaceRoot       = $Workspace
        workspaceUnderOneDrive = $underOneDrive
        sqlCollation           = $sqlCollation
        profileArchive         = 'profile.7z'
        userFoldersArchive     = $userArchive
        databases              = @($dbManifest)
        repos                  = @($repoManifest)
    }
    Write-Utf8 (Join-Path $KitPath 'kit.json') ($manifest | ConvertTo-Json -Depth 8)
    $scriptsOk = $true
    foreach ($f in 'Setup-NewMachine.ps1', 'Setup-NewMachine.cmd', 'Setup-NewMachine-Cutover.cmd', 'Export-OldMachine.ps1', 'README.md') {
        if (-not (Copy-One (Join-Path $PSScriptRoot $f) (Join-Path $KitPath $f))) { $scriptsOk = $false }
    }
    if ($scriptsOk) { Note 'kit.json and setup scripts' 'ok' } else { Note 'kit.json and setup scripts' 'FAIL' 'a script did not copy' }
} finally {
    Stop-Transcript | Out-Null
    # the staging copy is unencrypted: never leave it behind
    if (Test-Path -LiteralPath $Staging) { Remove-Item -LiteralPath $Staging -Recurse -Force -ErrorAction SilentlyContinue }
    $script:Pass = $null
}

# ------------------------------------------------------------------ summary
Step 'Done'
$failed = @($results | Where-Object { $_.Status -eq 'FAIL' })
$kitSize = Get-FolderBytes $KitPath
Say "kit: $KitPath  ($(GB $kitSize))"
if ($failed.Count) {
    Say "$($failed.Count) item(s) failed; see above and $KitPath\logs." 'Red'
} else {
    Say 'Everything packed and encrypted.' 'Green'
}
Say 'Next: wait until the OneDrive icon says "Up to date", then follow README.md on the new laptop.'
Say 'Remember the passphrase. Delete the ScanB-Migration-Kit folder from OneDrive once the new laptop works.' 'Yellow'
if ($failed.Count) { exit 1 }
exit 0
