<#
.SYNOPSIS
    Read-only migration audit of the OLD Windows laptop (Phase 1: inventory only).

.DESCRIPTION
    Collects an inventory of projects, Claude configuration, scheduled tasks,
    startup items, services, running processes, installed software and cloud
    tool configuration, and writes it to ONE output folder.

    SAFETY GUARANTEES (by design of this script):
      * It never deletes, moves, renames or edits any existing file.
      * It never enables, disables, starts, stops or changes any task/service.
      * The ONLY files it writes are inside the output folder (-OutputRoot).
      * Git is queried with --no-optional-locks so the repository index is not rewritten.
      * Secret files (.env, keys, tokens) are never copied or printed.
        For .env files only the variable NAMES are recorded, never the values.
      * Command lines / task arguments are passed through a redaction filter.

    OUTPUT LAYOUT
      <OutputRoot>\SHAREABLE\            redacted CSV/JSON/MD - safe to review with Claude
      <OutputRoot>\PRIVATE_DO_NOT_UPLOAD\ raw scheduled-task XML exports (may contain
                                           arguments, paths, account names) - keep offline
      <OutputRoot>\audit_log.txt          progress + every error / access-denied path

.PARAMETER OutputRoot
    Folder to write results to. Default: Desktop\MIGRATION_AUDIT_<computer>_<timestamp>

.PARAMETER ExtraRoots
    Additional folders to search for projects (e.g. D:\Work).

.PARAMETER MaxDepth
    How deep to search for projects under each root. Default 6.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Audit-OldLaptop.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Audit-OldLaptop.ps1 -ExtraRoots 'D:\Work','E:\Archive'

    "-ExecutionPolicy Bypass" applies to this one process only; it does not change
    the machine's policy. Run first as a normal user. Running "as Administrator"
    additionally reveals tasks/services owned by other accounts.

    Compatible with Windows PowerShell 5.1 and PowerShell 7+.
#>
[CmdletBinding()]
param(
    [string]$OutputRoot,
    [string[]]$ExtraRoots = @(),
    [int]$MaxDepth = 6
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$ScriptVersion = '1.0.0'
$StartTime = Get-Date
# "-File" passes  -ExtraRoots "D:\a","E:\b"  as ONE string; split it into folders
$ExtraRoots = @($ExtraRoots | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().Trim('"').Trim("'") } | Where-Object { $_ })

# ---------------------------------------------------------------- output setup
if (-not $OutputRoot) {
    $desk = [Environment]::GetFolderPath('Desktop')
    if (-not $desk) { $desk = $env:USERPROFILE }
    $OutputRoot = Join-Path $desk ("MIGRATION_AUDIT_{0}_{1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
}
if (Test-Path -LiteralPath $OutputRoot) {
    $existing = @(Get-ChildItem -LiteralPath $OutputRoot -Force -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        Write-Host "Output folder already exists and is not empty: $OutputRoot" -ForegroundColor Red
        Write-Host "Choose a new folder with -OutputRoot (nothing was written)." -ForegroundColor Red
        exit 1
    }
}
$Shareable = Join-Path $OutputRoot 'SHAREABLE'
$Private   = Join-Path $OutputRoot 'PRIVATE_DO_NOT_UPLOAD'
$TaskXml   = Join-Path $Private 'scheduled_tasks_xml'
foreach ($d in @($OutputRoot, $Shareable, $Private, $TaskXml)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}
$LogFile = Join-Path $OutputRoot 'audit_log.txt'
$Utf8 = New-Object System.Text.UTF8Encoding($true)

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    [IO.File]::AppendAllText($LogFile, $line + [Environment]::NewLine, $Utf8)
    if ($Level -eq 'ERROR' -or $Level -eq 'WARN') { Write-Host $line -ForegroundColor Yellow }
    elseif ($Level -eq 'STEP') { Write-Host $line -ForegroundColor Cyan }
}
$script:AccessIssues = New-Object System.Collections.Generic.List[object]
function Add-AccessIssue {
    param([string]$Area, [string]$Path, [string]$Reason)
    $script:AccessIssues.Add([pscustomobject]@{ Area = $Area; Path = $Path; Reason = $Reason })
    Write-Log ("{0}: {1} -> {2}" -f $Area, $Path, $Reason) 'WARN'
}

function Save-Csv {
    param($Data, [string]$Name)
    $path = Join-Path $Shareable $Name
    $rows = @($Data)
    if ($rows.Count -eq 0) {
        [IO.File]::WriteAllText($path, '"(no rows)"' + [Environment]::NewLine, $Utf8)
    } else {
        $rows | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
    }
    Write-Log "Wrote $Name ($($rows.Count) rows)"
}
function Save-Json {
    param($Data, [string]$Name)
    $path = Join-Path $Shareable $Name
    [IO.File]::WriteAllText($path, ($Data | ConvertTo-Json -Depth 8), $Utf8)
    Write-Log "Wrote $Name"
}

# ---------------------------------------------------------------- redaction
function Protect-Text {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $t = $Text
    # credentials embedded in URLs  https://user:pass@host  /  https://token@host
    $t = [regex]::Replace($t, '(?i)([a-z][a-z0-9+.-]*://)[^/\s@"'']+@', '${1}<REDACTED>@')
    # key=value / key: value / --key value for secret-looking names
    $t = [regex]::Replace($t, '(?i)\b([A-Za-z0-9_.-]*(pass(word|wd)?|pwd|secret|token|api[_-]?key|apikey|[_-]key|auth|bearer|credential|private[_-]?key|service[_-]?key|access[_-]?key)[A-Za-z0-9_.-]*)(\s*[=:]\s*|\s+)("[^"]*"|''[^'']*''|\S+)', '${1}${4}<REDACTED>')
    # Authorization headers
    $t = [regex]::Replace($t, '(?i)(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}', '${1} <REDACTED>')
    # well-known key prefixes
    $t = [regex]::Replace($t, '\b(sk-ant-[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abpr]-[A-Za-z0-9-]+|AIza[0-9A-Za-z_-]{20,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+)', '<REDACTED-KEY>')
    # any other long opaque token (>=32 chars of base64/hex-ish without path separators)
    $t = [regex]::Replace($t, '(?<![A-Za-z0-9\\/._=-])[A-Za-z0-9+_-]{32,}={0,2}(?![A-Za-z0-9\\/._-])', '<REDACTED-LONG>')
    return $t
}
function Test-SecretName {
    param([string]$Name)
    return ($Name -match '(?i)(pass|pwd|secret|token|key|auth|credential|cert|private|session|cookie|conn(ection)?str|database_url|dsn)')
}

# ---------------------------------------------------------------- helpers
$ExcludeDirNames = @('node_modules', '.git', '.next', '.nuxt', 'dist', 'build', 'out', '.venv', 'venv', 'env',
    '__pycache__', '.pytest_cache', '.mypy_cache', '.tox', 'target', 'bin', 'obj', '.gradle', '.idea',
    '.vs', '.vscode', 'coverage', '.cache', '.turbo', '.vercel', '.terraform', 'site-packages', 'Lib',
    '$RECYCLE.BIN', 'System Volume Information', 'AppData', 'Windows', 'Program Files', 'Program Files (x86)', 'ProgramData')
$HeavyDirNames = @('node_modules', '.next', '.venv', 'venv', 'dist', 'build', '__pycache__', '.cache', 'coverage', 'target', 'bin', 'obj')

function Get-SubDirs {
    param([string]$Path)
    try {
        return [IO.Directory]::GetDirectories($Path)
    } catch {
        Add-AccessIssue 'DirectoryWalk' $Path $_.Exception.GetType().Name
        return @()
    }
}
function Test-Reparse {
    param([string]$Path)
    try { return (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) } catch { return $true }
}

function Get-CommandVersion {
    param([string]$Exe, [string[]]$VersionArgs = @('--version'))
    $cmd = Get-Command $Exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { return [pscustomobject]@{ Tool = $Exe; Found = 'No'; Version = ''; Path = '' } }
    $ver = ''
    try {
        $out = & $cmd.Source @VersionArgs 2>&1 | Select-Object -First 3
        $ver = (($out | ForEach-Object { "$_" }) -join ' | ').Trim()
    } catch { $ver = "error: $($_.Exception.Message)" }
    return [pscustomobject]@{ Tool = $Exe; Found = 'Yes'; Version = (Protect-Text $ver); Path = $cmd.Source }
}

$GitExe = (Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1).Source
function Invoke-GitRead {
    param([string]$Repo, [string[]]$GitArgs)
    if (-not $GitExe) { return $null }
    try {
        $out = & $GitExe --no-optional-locks -C $Repo @GitArgs 2>$null
        return $out
    } catch { return $null }
}

# ---------------------------------------------------------------- 0. system info
Write-Log "Audit-OldLaptop.ps1 v$ScriptVersion started. Output: $OutputRoot" 'STEP'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$os  = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$cs  = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
$disks = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | ForEach-Object {
    [pscustomobject]@{ Drive = $_.DeviceID; Label = $_.VolumeName; FileSystem = $_.FileSystem
        SizeGB = [math]::Round($_.Size / 1GB, 1); FreeGB = [math]::Round($_.FreeSpace / 1GB, 1) }
}
$system = [pscustomobject]@{
    AuditTime        = $StartTime.ToString('s')
    ScriptVersion    = $ScriptVersion
    ComputerName     = $env:COMPUTERNAME
    UserName         = $env:USERNAME
    UserProfile      = $env:USERPROFILE
    RunningAsAdmin   = $isAdmin
    OS               = if ($os) { "$($os.Caption) $($os.Version) build $($os.BuildNumber)" } else { '' }
    OSArchitecture   = if ($os) { $os.OSArchitecture } else { '' }
    Manufacturer     = if ($cs) { $cs.Manufacturer } else { '' }
    Model            = if ($cs) { $cs.Model } else { '' }
    RAM_GB           = if ($cs) { [math]::Round($cs.TotalPhysicalMemory / 1GB, 1) } else { '' }
    CPU              = if ($cpu) { $cpu.Name } else { '' }
    PartOfDomain     = if ($cs) { $cs.PartOfDomain } else { '' }
    Domain           = if ($cs) { $cs.Domain } else { '' }
    PowerShell       = $PSVersionTable.PSVersion.ToString()
    TimeZone         = (Get-TimeZone -ErrorAction SilentlyContinue).Id
    Disks            = $disks
}
Save-Json $system '00_system_info.json'

# ---------------------------------------------------------------- 1. project discovery
Write-Log 'Step 1/9: discovering projects' 'STEP'
$home_ = $env:USERPROFILE
$roots = New-Object System.Collections.Generic.List[string]
$candidateRoots = @(
    [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'),
    (Join-Path $home_ 'Downloads'), (Join-Path $home_ 'source'), (Join-Path $home_ 'Projects'),
    (Join-Path $home_ 'projects'), (Join-Path $home_ 'dev'), (Join-Path $home_ 'code'), (Join-Path $home_ 'repos'),
    (Join-Path $home_ 'Claude'), (Join-Path $home_ 'GitHub'), $env:OneDrive, $env:OneDriveCommercial,
    'C:\x', 'C:\Projects', 'C:\dev', 'C:\code', 'C:\src', 'C:\repos', 'C:\work', 'C:\Scripts', 'C:\Tools', 'C:\automation'
)
# every other first-level folder directly under the user profile (skipping AppData and dot folders),
# and non-system first-level folders on C:\ plus every other fixed drive root
Get-ChildItem -LiteralPath $home_ -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '^(AppData|\..*|NTUSER.*|Application Data|Local Settings|Cookies|NetHood|PrintHood|Recent|SendTo|Start Menu|Templates|My Documents)$' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
    ForEach-Object { $candidateRoots += $_.FullName }
Get-ChildItem -LiteralPath 'C:\' -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '^(Windows|Program Files|Program Files \(x86\)|ProgramData|Users|\$.*|System Volume Information|Recovery|PerfLogs|Documents and Settings|MSOCache|Intel|AMD|NVIDIA|OneDriveTemp|inetpub)$' } |
    ForEach-Object { $candidateRoots += $_.FullName }
foreach ($d in $disks) { if ($d.Drive -ne 'C:') { $candidateRoots += ($d.Drive + '\') } }
$candidateRoots += $ExtraRoots
foreach ($r in $candidateRoots) {
    if ($r -and (Test-Path -LiteralPath $r -PathType Container)) {
        $full = (Resolve-Path -LiteralPath $r).ProviderPath.TrimEnd('\')
        if ($full.Length -eq 2) { $full += '\' }
        $covered = $false
        foreach ($x in $roots) { if ($full -eq $x -or $full.StartsWith($x.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { $covered = $true; break } }
        if (-not $covered) {
            # remove roots that are inside this new one
            for ($i = $roots.Count - 1; $i -ge 0; $i--) { if ($roots[$i].StartsWith($full.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { $roots.RemoveAt($i) } }
            $roots.Add($full)
        }
    }
}
Write-Log ("Search roots: " + ($roots -join '; '))

$MarkerFiles = @('package.json', 'requirements.txt', 'pyproject.toml', 'Pipfile', 'setup.py', 'appsscript.json', '.clasp.json',
    'Dockerfile', 'docker-compose.yml', 'docker-compose.yaml', 'railway.json', 'vercel.json', 'netlify.toml',
    'CLAUDE.md', 'AGENTS.md', '.mcp.json', 'go.mod', 'Cargo.toml', 'composer.json', 'pom.xml', 'build.gradle',
    'ecosystem.config.js', 'supabase', 'manage.py')
$projects = New-Object System.Collections.Generic.List[object]
$projectSet = @{}

function Find-Projects {
    param([string]$Dir, [int]$Depth)
    if ($Depth -gt $MaxDepth) { return }
    $name = Split-Path $Dir -Leaf
    if ($ExcludeDirNames -contains $name) { return }
    if (Test-Reparse $Dir) { return }
    $isProject = $false; $markers = @()
    if (Test-Path -LiteralPath (Join-Path $Dir '.git')) { $isProject = $true; $markers += '.git' }
    if (Test-Path -LiteralPath (Join-Path $Dir '.claude') -PathType Container) { $isProject = $true; $markers += '.claude/' }
    foreach ($m in $MarkerFiles) { if (Test-Path -LiteralPath (Join-Path $Dir $m)) { $isProject = $true; $markers += $m } }
    if (-not $isProject) {
        try {
            $gs = @([IO.Directory]::GetFiles($Dir, '*.gs')); $sln = @([IO.Directory]::GetFiles($Dir, '*.sln')); $csproj = @([IO.Directory]::GetFiles($Dir, '*.csproj'))
            if ($gs.Count -gt 0) { $isProject = $true; $markers += '*.gs' }
            if ($sln.Count -gt 0 -or $csproj.Count -gt 0) { $isProject = $true; $markers += '*.sln/csproj' }
        } catch { }
    }
    if ($isProject -and -not $projectSet.ContainsKey($Dir)) {
        $projectSet[$Dir] = $true
        $projects.Add([pscustomobject]@{ Path = $Dir; Markers = ($markers -join ',') })
        # keep descending only through a short distance: monorepos / nested projects
        if ($markers -contains '.git') {
            foreach ($sub in (Get-SubDirs $Dir)) { Find-Projects $sub ($Depth + 3) }
            return
        }
    }
    foreach ($sub in (Get-SubDirs $Dir)) { Find-Projects $sub ($Depth + 1) }
}
foreach ($r in $roots) { Write-Log "  scanning $r"; Find-Projects $r 0 }
Write-Log ("Found {0} project folders" -f $projects.Count)

# ---- per-project detail
$SourceExt = @('.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.py', '.gs', '.ps1', '.psm1', '.bat', '.cmd', '.vbs', '.json', '.yml', '.yaml', '.toml', '.ini', '.cfg', '.html', '.sql', '.sh', '.md', '.env.example')
$SecretFilePattern = '(?i)^(\.env(\..*)?|.*\.pem|.*\.key|.*\.pfx|.*\.p12|id_rsa.*|id_ed25519.*|credentials.*\.json|client_secret.*\.json|service[-_]?account.*\.json|token(s)?\.json|\.clasprc\.json|\.npmrc|\.pypirc|\.netrc|.*\.kdbx|secrets?\..*)$'
$DataFilePattern = '(?i)\.(xlsx|xlsm|xls|csv|db|sqlite|sqlite3|mdb|accdb|qbw|qbb|msg|pst|pdf|json)$'
$PathPattern = '(?i)(?<![A-Za-z0-9])([A-Z]:\\{1,2}[^"''`<>|\r\n\t*?]{2,120}|[A-Z]:/[^"''`<>|\r\n\t*?\s]{2,120}|\\\\[A-Za-z0-9._-]+\\[^"''`<>|\r\n\t*?]{2,120})'
$HostPattern = '(?i)(https?://[a-z0-9.-]*(supabase\.co|railway\.app|vercel\.app|n8n\.cloud|app\.n8n\.io|script\.google\.com|googleapis\.com|graph\.microsoft\.com|sharepoint\.com|office\.com|intuit\.com|quickbooks|api\.anthropic\.com|github\.com|hooks\.slack\.com|ngrok)[a-z0-9./_-]*|localhost:\d+|127\.0\.0\.1:\d+|vessel-profit-ingest)'

$projRows = New-Object System.Collections.Generic.List[object]
$hardPaths = New-Object System.Collections.Generic.List[object]
$hostRefs = New-Object System.Collections.Generic.List[object]
$secretFiles = New-Object System.Collections.Generic.List[object]
$dataFiles = New-Object System.Collections.Generic.List[object]
$envNames = New-Object System.Collections.Generic.List[object]

function Get-TreeStats {
    # walks a project, skipping heavy/derived folders; returns counts and collects findings
    param([string]$Root)
    $stats = @{ Files = 0; Bytes = [int64]0; Newest = [datetime]::MinValue; Heavy = New-Object System.Collections.Generic.List[string]; Ext = @{} }
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        $files = @()
        try { $files = [IO.Directory]::GetFiles($d) } catch { Add-AccessIssue 'ProjectFiles' $d $_.Exception.GetType().Name }
        foreach ($f in $files) {
            try {
                $fi = New-Object IO.FileInfo($f)
                $stats.Files++; $stats.Bytes += $fi.Length
                if ($fi.LastWriteTime -gt $stats.Newest) { $stats.Newest = $fi.LastWriteTime }
                $ext = $fi.Extension.ToLowerInvariant(); if ($ext) { $stats.Ext[$ext] = 1 + [int]$stats.Ext[$ext] }
                $rel = $f.Substring($Root.Length).TrimStart('\')
                if ($fi.Name -match $SecretFilePattern -and $fi.Name -notmatch '(?i)\.example$|\.sample$|\.template$') {
                    $hash = ''
                    try { $hash = (Get-FileHash -LiteralPath $f -Algorithm SHA256 -ErrorAction Stop).Hash } catch { }
                    $script:secretFiles.Add([pscustomobject]@{ Project = $Root; RelativePath = $rel; SizeBytes = $fi.Length; LastWrite = $fi.LastWriteTime.ToString('s'); SHA256 = $hash; Note = 'contents NOT read/copied (except variable names for .env*)' })
                    if ($fi.Name -match '(?i)^\.env') {
                        try {
                            foreach ($line in [IO.File]::ReadAllLines($f)) {
                                if ($line -match '^\s*(export\s+)?([A-Za-z_][A-Za-z0-9_.-]*)\s*=') {
                                    $script:envNames.Add([pscustomobject]@{ Project = $Root; File = $rel; VariableName = $Matches[2]; LooksSecret = (Test-SecretName $Matches[2]); Value = '<not recorded>' })
                                }
                            }
                        } catch { }
                    }
                }
                elseif ($fi.Name -match $DataFilePattern -and $fi.Name -notmatch '(?i)^(package(-lock)?|tsconfig.*|composer|appsscript|\.clasp|components|vercel|railway|manifest)\.json$' -and ($fi.Extension -ne '.json' -or $fi.Length -gt 200KB)) {
                    $script:dataFiles.Add([pscustomobject]@{ Project = $Root; RelativePath = $rel; SizeKB = [math]::Round($fi.Length / 1KB, 1); LastWrite = $fi.LastWriteTime.ToString('s') })
                }
                if ($SourceExt -contains $ext -and $fi.Length -lt 1MB -and $fi.Name -notmatch '(?i)lock|\.min\.') {
                    $lineNo = 0
                    foreach ($line in [IO.File]::ReadLines($f)) {
                        $lineNo++
                        if ($line.Length -gt 4000) { continue }
                        foreach ($m in [regex]::Matches($line, $PathPattern)) {
                            $p = $m.Value.Trim().TrimEnd(',', ';', ')', ']', '}')
                            if ($p -match '^[A-Za-z]:\\[nrtsdbwSDW](\W|$)') { continue }  # regex escapes such as e:\s
                            $script:hardPaths.Add([pscustomobject]@{ Project = $Root; File = $rel; Line = $lineNo; Path = (Protect-Text $p) })
                        }
                        foreach ($m in [regex]::Matches($line, $HostPattern)) {
                            $script:hostRefs.Add([pscustomobject]@{ Project = $Root; File = $rel; Line = $lineNo; Reference = (Protect-Text $m.Value) })
                        }
                    }
                }
            } catch { }
        }
        foreach ($sd in (Get-SubDirs $d)) {
            $leaf = Split-Path $sd -Leaf
            if ($leaf -eq '.git') { continue }
            if ($HeavyDirNames -contains $leaf) { $stats.Heavy.Add($sd.Substring($Root.Length).TrimStart('\')); continue }
            if (Test-Reparse $sd) { continue }
            if ($projectSet.ContainsKey($sd)) { continue }   # nested project is reported on its own
            $stack.Push($sd)
        }
    }
    return $stats
}

$i = 0
foreach ($p in $projects) {
    $i++
    Write-Log ("  [{0}/{1}] {2}" -f $i, $projects.Count, $p.Path)
    $dir = $p.Path
    $s = Get-TreeStats $dir
    $tech = New-Object System.Collections.Generic.List[string]
    $pkg = Join-Path $dir 'package.json'
    $nodeInfo = ''
    if (Test-Path -LiteralPath $pkg) {
        try {
            $j = Get-Content -LiteralPath $pkg -Raw -Encoding UTF8 | ConvertFrom-Json
            $deps = @(); if ($j.dependencies) { $deps += $j.dependencies.PSObject.Properties.Name }; if ($j.devDependencies) { $deps += $j.devDependencies.PSObject.Properties.Name }
            $tech.Add('Node.js')
            foreach ($k in @('next', 'react', 'vue', '@nestjs/core', 'express', 'typeorm', 'prisma', '@supabase/supabase-js', 'pg', 'electron', 'vite', 'typescript', '@anthropic-ai/sdk', '@google/clasp', 'n8n', 'puppeteer', 'playwright')) { if ($deps -contains $k) { $tech.Add($k) } }
            if ($j.engines -and $j.engines.node) { $nodeInfo = "engines.node=$($j.engines.node)" }
            if ($j.scripts) { $nodeInfo = ($nodeInfo + ' scripts=' + (($j.scripts.PSObject.Properties.Name) -join '|')).Trim() }
        } catch { $tech.Add('Node.js(package.json unreadable)') }
    }
    foreach ($f in @('.nvmrc', '.node-version', '.python-version', 'runtime.txt')) { $fp = Join-Path $dir $f; if (Test-Path -LiteralPath $fp) { $nodeInfo += " $f=" + ((Get-Content -LiteralPath $fp -TotalCount 1) -join '') } }
    if (Test-Path -LiteralPath (Join-Path $dir 'requirements.txt')) { $tech.Add('Python') }
    if (Test-Path -LiteralPath (Join-Path $dir 'pyproject.toml')) { $tech.Add('Python(pyproject)') }
    if ($s.Ext['.py'] -and -not ($tech -match 'Python')) { $tech.Add('Python(scripts)') }
    if ($s.Ext['.gs'] -or (Test-Path -LiteralPath (Join-Path $dir 'appsscript.json'))) { $tech.Add('Google Apps Script') }
    if (Test-Path -LiteralPath (Join-Path $dir '.clasp.json')) { $tech.Add('clasp') }
    if ($s.Ext['.ps1']) { $tech.Add('PowerShell') }
    if ($s.Ext['.bat'] -or $s.Ext['.cmd']) { $tech.Add('Batch') }
    if (Test-Path -LiteralPath (Join-Path $dir 'Dockerfile')) { $tech.Add('Docker') }
    if (Test-Path -LiteralPath (Join-Path $dir 'railway.json')) { $tech.Add('Railway') }
    if ((Test-Path -LiteralPath (Join-Path $dir 'vercel.json')) -or (Test-Path -LiteralPath (Join-Path $dir '.vercel'))) { $tech.Add('Vercel') }
    if (Test-Path -LiteralPath (Join-Path $dir 'supabase')) { $tech.Add('Supabase CLI') }
    if ($s.Ext['.qbw']) { $tech.Add('QuickBooks data') }
    if ($s.Ext['.sln'] -or $s.Ext['.csproj']) { $tech.Add('.NET') }
    $claude = @()
    foreach ($c in @('CLAUDE.md', 'AGENTS.md', '.mcp.json', '.claude')) { if (Test-Path -LiteralPath (Join-Path $dir $c)) { $claude += $c } }

    # git (read-only)
    $isGit = Test-Path -LiteralPath (Join-Path $dir '.git')
    $remote = ''; $branch = ''; $dirty = ''; $untracked = ''; $ahead = ''; $noUpstream = ''; $stash = ''; $lastCommit = ''; $branchesNotPushed = ''
    if ($isGit -and $GitExe) {
        $remote = ((Invoke-GitRead $dir @('remote', '-v')) | Select-Object -First 1)
        $remote = Protect-Text ("$remote" -replace '\s+\(fetch\)$', '')
        $branch = "$(Invoke-GitRead $dir @('rev-parse', '--abbrev-ref', 'HEAD'))"
        $st = @(Invoke-GitRead $dir @('status', '--porcelain'))
        $dirty = @($st | Where-Object { $_ -and $_ -notmatch '^\?\?' }).Count
        $untracked = @($st | Where-Object { $_ -match '^\?\?' }).Count
        $up = "$(Invoke-GitRead $dir @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}'))"
        if ($up) { $ahead = "$(Invoke-GitRead $dir @('rev-list', '--count', '@{u}..HEAD'))" } else { $noUpstream = 'YES' }
        $stash = @(Invoke-GitRead $dir @('stash', 'list') | Where-Object { $_ }).Count
        $lastCommit = "$(Invoke-GitRead $dir @('log', '-1', '--format=%ci'))"
        # local branches that are not on any remote
        $lb = @(Invoke-GitRead $dir @('for-each-ref', '--format=%(refname:short)|%(upstream:short)', 'refs/heads') | Where-Object { $_ })
        $branchesNotPushed = (@($lb | Where-Object { $_ -match '\|$' } | ForEach-Object { $_.TrimEnd('|') }) -join ' ')
    }
    $risk = @()
    if (-not $isGit) { $risk += 'NOT-IN-GIT' }
    elseif (-not $remote) { $risk += 'NO-REMOTE' }
    if ($dirty -and [int]$dirty -gt 0) { $risk += "UNCOMMITTED($dirty)" }
    if ($untracked -and [int]$untracked -gt 0) { $risk += "UNTRACKED($untracked)" }
    if ($ahead -and [int]$ahead -gt 0) { $risk += "UNPUSHED-COMMITS($ahead)" }
    if ($noUpstream) { $risk += 'BRANCH-WITHOUT-UPSTREAM' }
    if ($branchesNotPushed) { $risk += "LOCAL-ONLY-BRANCHES" }
    if ($stash -and [int]$stash -gt 0) { $risk += "STASH($stash)" }
    if (@($secretFiles | Where-Object { $_.Project -eq $dir }).Count -gt 0) { $risk += 'HAS-SECRET-FILES' }
    if (@($dataFiles | Where-Object { $_.Project -eq $dir }).Count -gt 0) { $risk += 'HAS-LOCAL-DATA-FILES' }
    if (@($hardPaths | Where-Object { $_.Project -eq $dir }).Count -gt 0) { $risk += 'HARDCODED-PATHS' }

    $projRows.Add([pscustomobject]@{
        ProjectName        = Split-Path $dir -Leaf
        Path               = $dir
        Markers            = $p.Markers
        Technologies       = (($tech | Select-Object -Unique) -join ', ')
        RuntimeHints       = $nodeInfo.Trim()
        ClaudeFiles        = ($claude -join ', ')
        SizeMB_excl_heavy  = [math]::Round($s.Bytes / 1MB, 2)
        FileCount_excl_heavy = $s.Files
        HeavyDirsSkipped   = (($s.Heavy | Select-Object -First 10) -join ' ; ')
        LastModifiedFile   = if ($s.Newest -gt [datetime]::MinValue) { $s.Newest.ToString('s') } else { '' }
        IsGit              = $isGit
        GitRemote          = $remote
        GitBranch          = $branch
        LastCommit         = $lastCommit
        UncommittedChanges = $dirty
        UntrackedFiles     = $untracked
        UnpushedCommits    = $ahead
        NoUpstream         = $noUpstream
        LocalOnlyBranches  = $branchesNotPushed
        StashCount         = $stash
        RiskFlags          = ($risk -join ' ')
    })
}
Save-Csv $projRows 'PROJECT_INVENTORY_LOCAL.csv'
Save-Csv $hardPaths 'project_hardcoded_paths.csv'
Save-Csv $hostRefs 'project_external_service_refs.csv'
Save-Csv $secretFiles 'project_secret_files_NAMES_ONLY.csv'
Save-Csv $envNames 'project_env_variable_NAMES_ONLY.csv'
Save-Csv $dataFiles 'project_local_data_files.csv'

# ---------------------------------------------------------------- 2. Claude environment
Write-Log 'Step 2/9: Claude Desktop / Claude Code configuration' 'STEP'
$claudeRows = New-Object System.Collections.Generic.List[object]
function Add-ClaudeItem { param($Area, $Item, $Path, $Detail, $Transfer)
    $claudeRows.Add([pscustomobject]@{ Area = $Area; Item = $Item; Path = $Path; Detail = (Protect-Text "$Detail"); HowToTransfer = $Transfer }) }

$claudeLocations = @(
    @{ P = (Join-Path $env:APPDATA 'Claude'); A = 'Claude Desktop (AppData\Roaming\Claude)' },
    @{ P = (Join-Path $env:LOCALAPPDATA 'AnthropicClaude'); A = 'Claude Desktop install (LocalAppData\AnthropicClaude)' },
    @{ P = (Join-Path $env:LOCALAPPDATA 'Programs\Claude'); A = 'Claude Desktop install (LocalAppData\Programs\Claude)' },
    @{ P = (Join-Path $env:LOCALAPPDATA 'Claude'); A = 'Claude (LocalAppData\Claude)' },
    @{ P = (Join-Path $home_ '.claude'); A = 'Claude Code user folder (~\.claude)' },
    @{ P = (Join-Path $home_ '.claude.json'); A = 'Claude Code state file (~\.claude.json)' },
    @{ P = (Join-Path $env:APPDATA 'Claude Code'); A = 'Claude Code (AppData)' },
    @{ P = (Join-Path $env:ProgramData 'ClaudeCode'); A = 'Claude Code managed settings (ProgramData)' }
)
foreach ($loc in $claudeLocations) {
    if (Test-Path -LiteralPath $loc.P) {
        $it = Get-Item -LiteralPath $loc.P -Force
        $detail = if ($it.PSIsContainer) { 'folder; top-level: ' + ((Get-ChildItem -LiteralPath $loc.P -Force -ErrorAction SilentlyContinue | Select-Object -First 40 | ForEach-Object { $_.Name }) -join ', ') } else { "file; $([math]::Round($it.Length/1KB,1)) KB; modified $($it.LastWriteTime.ToString('s'))" }
        Add-ClaudeItem $loc.A 'location' $loc.P $detail 'see per-item rows'
    } else { Add-ClaudeItem $loc.A 'location' $loc.P 'not present' '' }
}
# Claude Desktop MCP servers (names / commands only; env values never recorded)
$deskCfg = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
if (Test-Path -LiteralPath $deskCfg) {
    try {
        $cfg = Get-Content -LiteralPath $deskCfg -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.mcpServers) {
            foreach ($srv in $cfg.mcpServers.PSObject.Properties) {
                $v = $srv.Value
                $envKeys = if ($v.env) { ($v.env.PSObject.Properties.Name -join ', ') } else { '' }
                Add-ClaudeItem 'Claude Desktop MCP server' $srv.Name $deskCfg ("command=$($v.command) args=$(@($v.args) -join ' ') url=$($v.url) envNames=[$envKeys]") 'Re-create entry on new laptop; re-enter secrets from password manager; install the command (node/python/uvx) first'
            }
        }
        $otherKeys = ($cfg.PSObject.Properties.Name | Where-Object { $_ -ne 'mcpServers' }) -join ', '
        Add-ClaudeItem 'Claude Desktop config' 'other top-level keys' $deskCfg $otherKeys 'Copy file after removing secrets, or re-enter in Settings'
    } catch { Add-AccessIssue 'Claude' $deskCfg "unreadable JSON: $($_.Exception.Message)" }
}
# Claude Desktop extensions (.dxt / extensions folder)
foreach ($extDir in @((Join-Path $env:APPDATA 'Claude\Claude Extensions'), (Join-Path $env:APPDATA 'Claude\extensions'))) {
    if (Test-Path -LiteralPath $extDir) {
        Get-ChildItem -LiteralPath $extDir -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { Add-ClaudeItem 'Claude Desktop extension' $_.Name $_.FullName "modified $($_.LastWriteTime.ToString('s'))" 'Re-install from Settings > Extensions on new laptop' }
    }
}
# anything that looks like locally-stored scheduled tasks / automations in Claude app data (names only)
foreach ($base in @((Join-Path $env:APPDATA 'Claude'), (Join-Path $env:LOCALAPPDATA 'Claude'), (Join-Path $home_ '.claude'))) {
    if (Test-Path -LiteralPath $base) {
        Get-ChildItem -LiteralPath $base -Recurse -Force -Depth 3 -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)schedul|trigger|cron|routine|task' -and $_.FullName -notmatch '(?i)\\(Cache|Code Cache|GPUCache|blob_storage|IndexedDB|Service Worker)\\' } |
            Select-Object -First 50 | ForEach-Object { Add-ClaudeItem 'Claude local automation candidate' $_.Name $_.FullName "modified $($_.LastWriteTime.ToString('s'))" 'Review: Cowork/desktop scheduled tasks stored locally must be re-created on the new laptop and DISABLED on the old one at cutover' }
    }
}
# Claude Code user settings, skills, agents, commands, plugins, hooks
$cc = Join-Path $home_ '.claude'
if (Test-Path -LiteralPath $cc) {
    foreach ($f in @('settings.json', 'settings.local.json', 'CLAUDE.md', 'keybindings.json')) {
        $fp = Join-Path $cc $f
        if (Test-Path -LiteralPath $fp) {
            $detail = "$([math]::Round((Get-Item -LiteralPath $fp).Length/1KB,1)) KB"
            if ($f -like 'settings*.json') {
                try { $sj = Get-Content -LiteralPath $fp -Raw -Encoding UTF8 | ConvertFrom-Json
                    $detail += '; keys: ' + (($sj.PSObject.Properties.Name) -join ', ')
                    if ($sj.hooks) { $detail += '; hooks: ' + (($sj.hooks.PSObject.Properties.Name) -join ', ') }
                    if ($sj.env) { $detail += '; envNames: ' + (($sj.env.PSObject.Properties.Name) -join ', ') }
                } catch { }
            }
            Add-ClaudeItem 'Claude Code user file' $f $fp $detail 'Copy as file (check hooks for absolute paths; secrets in env -> re-enter)'
        }
    }
    foreach ($sub in @('skills', 'agents', 'commands', 'plugins', 'hooks', 'output-styles', 'workflows')) {
        $sp = Join-Path $cc $sub
        if (Test-Path -LiteralPath $sp) {
            Get-ChildItem -LiteralPath $sp -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('cache', 'repos', 'marketplaces') } | Select-Object -First 200 |
                ForEach-Object { Add-ClaudeItem "Claude Code $sub" $_.Name $_.FullName "modified $($_.LastWriteTime.ToString('s'))" $(if ($sub -eq 'plugins') { 'Re-install via /plugin (marketplace) - do not copy cache' } else { 'Copy folder as-is' }) }
        }
    }
    $projDir = Join-Path $cc 'projects'
    if (Test-Path -LiteralPath $projDir) {
        $n = @(Get-ChildItem -LiteralPath $projDir -Directory -Force -ErrorAction SilentlyContinue).Count
        Add-ClaudeItem 'Claude Code session history' 'projects/' $projDir "$n project transcript folders (local chat history; folder names encode old absolute paths)" 'Optional copy for reference; resuming old sessions on new paths is NOT guaranteed'
    }
}
$ccj = Join-Path $home_ '.claude.json'
if (Test-Path -LiteralPath $ccj) {
    try {
        $j = Get-Content -LiteralPath $ccj -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.mcpServers) { foreach ($srv in $j.mcpServers.PSObject.Properties) { $v = $srv.Value; $envKeys = if ($v.env) { ($v.env.PSObject.Properties.Name -join ', ') } else { '' }
            Add-ClaudeItem 'Claude Code MCP server (user scope)' $srv.Name $ccj ("type=$($v.type) command=$($v.command) args=$(@($v.args) -join ' ') url=$($v.url) envNames=[$envKeys]") 'Re-add with "claude mcp add" on new laptop; re-enter secrets' } }
        if ($j.projects) {
            foreach ($pp in $j.projects.PSObject.Properties) {
                $mcp = ''; if ($pp.Value.mcpServers) { $mcp = ($pp.Value.mcpServers.PSObject.Properties.Name -join ', ') }
                Add-ClaudeItem 'Claude Code known project' $pp.Name $ccj ("project-scoped MCP: [$mcp]") 'Path must exist on new laptop; re-add project MCP servers'
            }
        }
        Add-ClaudeItem 'Claude Code login' 'account' $ccj 'Login/OAuth tokens are NOT transferable - run "claude" and sign in again on the new laptop' 'Re-login'
    } catch { Add-AccessIssue 'Claude' $ccj "unreadable JSON: $($_.Exception.Message)" }
}
# installed Claude packages
Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue | ForEach-Object { Add-ClaudeItem 'Claude Desktop (MSIX/Store)' $_.Name $_.InstallLocation "version $($_.Version)" 'Re-install on new laptop' }
Save-Csv $claudeRows 'claude_environment.csv'

# ---------------------------------------------------------------- 3. scheduled tasks
Write-Log 'Step 3/9: scheduled tasks (export only - no state changes)' 'STEP'
$taskRows = New-Object System.Collections.Generic.List[object]
$allTasks = @()
try { $allTasks = @(Get-ScheduledTask -ErrorAction Stop) } catch { Add-AccessIssue 'ScheduledTasks' 'Get-ScheduledTask' $_.Exception.Message }
$customTasks = @($allTasks | Where-Object {
    $_.TaskPath -notlike '\Microsoft\*' -and $_.TaskName -notmatch '^(MicrosoftEdgeUpdate|OneDrive|GoogleUpdate|Adobe|NvTm|NVIDIA|Intel|CreateExplorerShellUnelevatedTask|npcapwatchdog|User_Feed_Synchronization)' })
Write-Log ("Scheduled tasks: total={0}, custom/third-party={1}" -f $allTasks.Count, $customTasks.Count)
function Format-Trigger { param($t)
    $type = ($t.CimClass.CimClassName -replace '^MSFT_Task', '' -replace 'Trigger$', '')
    $parts = @($type)
    if ($t.StartBoundary) { $parts += "start=$($t.StartBoundary)" }
    if ($t.DaysInterval) { $parts += "everyDays=$($t.DaysInterval)" }
    if ($t.WeeksInterval) { $parts += "everyWeeks=$($t.WeeksInterval)" }
    if ($t.DaysOfWeek) { $parts += "daysOfWeek=$($t.DaysOfWeek)" }
    if ($t.Repetition -and $t.Repetition.Interval) { $parts += "repeat=$($t.Repetition.Interval) for=$($t.Repetition.Duration)" }
    if ($t.Delay) { $parts += "delay=$($t.Delay)" }
    if ($t.UserId) { $parts += "user=$($t.UserId)" }
    if ($t.Subscription) { $parts += 'eventSubscription' }
    if (-not $t.Enabled) { $parts += '(trigger disabled)' }
    return ($parts -join ' ')
}
foreach ($t in $customTasks) {
    $info = $null; try { $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop } catch { }
    $actions = @($t.Actions)
    $exec = ($actions | ForEach-Object { if ($_.Execute) { $_.Execute } elseif ($_.ClassId) { "COM:$($_.ClassId)" } }) -join ' ;; '
    $args_ = ($actions | ForEach-Object { $_.Arguments }) -join ' ;; '
    $wd = ($actions | ForEach-Object { $_.WorkingDirectory }) -join ' ;; '
    $trig = (@($t.Triggers) | ForEach-Object { Format-Trigger $_ }) -join ' || '
    $atLogon = [bool](@($t.Triggers) | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' })
    $atBoot = [bool](@($t.Triggers) | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' })
    $joined = "$exec $args_"
    $runtime = @()
    foreach ($k in @('python', 'pythonw', 'py.exe', 'node', 'npm', 'npx', 'powershell', 'pwsh', 'cmd', 'wscript', 'cscript', 'curl', 'claude', 'pm2', 'docker', 'git', 'rclone', 'robocopy')) { if ($joined -match [regex]::Escape($k)) { $runtime += $k } }
    $external = ($joined -match '(?i)https?://|supabase|railway|vercel|n8n|googleapis|script\.google|graph\.microsoft|sharepoint|smtp|sendmail|gmail|outlook|anthropic|api')
    $dup = if ($runtime.Count -gt 0 -or $external) { 'HIGH - custom script/API; running on both laptops may duplicate work' } else { 'CHECK' }
    $xmlName = (($t.TaskPath.Trim('\') -replace '[\\/:*?"<>|]', '_') + '__' + ($t.TaskName -replace '[\\/:*?"<>|]', '_')).Trim('_') + '.xml'
    $exported = 'No'
    try {
        $xml = Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop
        [IO.File]::WriteAllText((Join-Path $TaskXml $xmlName), $xml, (New-Object System.Text.UnicodeEncoding($false, $true)))
        $exported = 'Yes'
    } catch { Add-AccessIssue 'ScheduledTaskExport' ($t.TaskPath + $t.TaskName) $_.Exception.Message }
    $taskRows.Add([pscustomobject]@{
        TaskName          = $t.TaskName
        TaskPath          = $t.TaskPath
        State             = "$($t.State)"
        Author            = $t.Author
        Description       = (Protect-Text $t.Description)
        Triggers          = (Protect-Text $trig)
        RunsAtLogon       = $atLogon
        RunsAtStartup     = $atBoot
        Execute           = (Protect-Text $exec)
        Arguments         = (Protect-Text $args_)
        WorkingDirectory  = $wd
        RunAsUser         = $t.Principal.UserId
        LogonType         = "$($t.Principal.LogonType)"
        RunLevel          = "$($t.Principal.RunLevel)"
        LastRunTime       = if ($info) { "$($info.LastRunTime)" } else { '' }
        LastTaskResult    = if ($info) { '0x{0:X}' -f $info.LastTaskResult } else { '' }
        NextRunTime       = if ($info) { "$($info.NextRunTime)" } else { '' }
        RuntimeDetected   = ($runtime -join ',')
        CallsExternal     = $external
        DuplicateRisk     = $dup
        XmlExported       = $exported
        XmlFile           = "PRIVATE_DO_NOT_UPLOAD\scheduled_tasks_xml\$xmlName"
    })
}
Save-Csv $taskRows 'SCHEDULED_TASKS_INVENTORY.csv'

# ---------------------------------------------------------------- 4. startup / services / processes / PM2
Write-Log 'Step 4/9: startup items, services, processes, PM2' 'STEP'
$startup = New-Object System.Collections.Generic.List[object]
foreach ($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')) {
    if (Test-Path $key) {
        $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($props) { foreach ($pr in $props.PSObject.Properties) { if ($pr.Name -notlike 'PS*') {
            $startup.Add([pscustomobject]@{ Source = $key; Name = $pr.Name; Command = (Protect-Text "$($pr.Value)") }) } } }
    }
}
foreach ($sf in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
    if ($sf -and (Test-Path -LiteralPath $sf)) {
        $shell = $null; try { $shell = New-Object -ComObject WScript.Shell } catch { }
        Get-ChildItem -LiteralPath $sf -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object {
            $target = ''
            if ($_.Extension -eq '.lnk' -and $shell) { try { $lnk = $shell.CreateShortcut($_.FullName); $target = "$($lnk.TargetPath) $($lnk.Arguments) (in: $($lnk.WorkingDirectory))" } catch { } }
            $startup.Add([pscustomobject]@{ Source = "StartupFolder: $sf"; Name = $_.Name; Command = (Protect-Text $target) })
        }
    }
}
Save-Csv $startup 'startup_items.csv'

$services = @()
try {
    $services = @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { $_.PathName -and $_.PathName -notmatch '(?i)\\Windows\\(system32|SysWOW64|servicing|Microsoft\.NET|WinSxS)\\|\\Windows Defender' } |
        ForEach-Object { [pscustomobject]@{ Name = $_.Name; DisplayName = $_.DisplayName; State = $_.State; StartMode = $_.StartMode; Account = $_.StartName; Path = (Protect-Text $_.PathName) } })
} catch { Add-AccessIssue 'Services' 'Win32_Service' $_.Exception.Message }
Save-Csv $services 'services_non_windows.csv'

$procRows = @()
try {
    $procRows = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.Name -match '(?i)^(node|python|pythonw|py|pwsh|powershell|cmd|wscript|cscript|pm2|n8n|docker|com\.docker.*|ngrok|cloudflared|claude|java|php|ruby|deno|bun|uvicorn|gunicorn|rclone)(\.exe)?$' } |
        ForEach-Object { [pscustomobject]@{ Name = $_.Name; PID = $_.ProcessId; ParentPID = $_.ParentProcessId; Started = "$($_.CreationDate)"; CommandLine = (Protect-Text $_.CommandLine); ExecutablePath = $_.ExecutablePath } })
} catch { Add-AccessIssue 'Processes' 'Win32_Process' $_.Exception.Message }
Save-Csv $procRows 'running_script_processes.csv'

$pm2Rows = @()
# "pm2 jlist" would START a pm2 daemon if none is running, so only query an already-running daemon
$pm2Running = @($procRows | Where-Object { $_.CommandLine -match '(?i)pm2' }).Count -gt 0
if (-not $pm2Running -and (Get-Command pm2 -ErrorAction SilentlyContinue)) { Write-Log 'pm2 is installed but no pm2 daemon is running - not queried (would start it)' 'WARN' }
if ($pm2Running -and (Get-Command pm2 -ErrorAction SilentlyContinue)) {
    try {
        $pj = (& pm2 jlist 2>$null) -join ''
        if ($pj) { $pm2Rows = @(($pj | ConvertFrom-Json) | ForEach-Object { [pscustomobject]@{ Name = $_.name; Status = $_.pm2_env.status; Script = $_.pm2_env.pm_exec_path; Cwd = $_.pm2_env.pm_cwd; Cron = $_.pm2_env.cron_restart; Restarts = $_.pm2_env.restart_time; Interpreter = $_.pm2_env.exec_interpreter } }) }
    } catch { Add-AccessIssue 'PM2' 'pm2 jlist' $_.Exception.Message }
}
$pm2Dump = Join-Path $home_ '.pm2\dump.pm2'
if (Test-Path -LiteralPath $pm2Dump) { $pm2Rows += [pscustomobject]@{ Name = '(dump.pm2 exists)'; Status = 'saved process list - resurrected at boot if pm2-startup is installed'; Script = $pm2Dump; Cwd = ''; Cron = ''; Restarts = ''; Interpreter = '' } }
Save-Csv $pm2Rows 'pm2_processes.csv'

# ---------------------------------------------------------------- 5. stand-alone scripts outside projects
Write-Log 'Step 5/9: stand-alone scripts (ps1/bat/cmd/vbs/py/js) outside project folders' 'STEP'
$scriptRows = New-Object System.Collections.Generic.List[object]
function Find-Scripts { param([string]$Dir, [int]$Depth)
    if ($Depth -gt $MaxDepth) { return }
    if ($ExcludeDirNames -contains (Split-Path $Dir -Leaf)) { return }
    if (Test-Reparse $Dir) { return }
    if ($projectSet.ContainsKey($Dir)) { return }
    if ($scriptRows.Count -ge 5000) { return }
    try {
        foreach ($f in [IO.Directory]::GetFiles($Dir)) {
            if ($f -match '(?i)\.(ps1|psm1|bat|cmd|vbs|py|pyw|js|mjs|ts|sh|ahk)$') {
                $fi = New-Object IO.FileInfo($f)
                $refs = ''
                if ($fi.Length -lt 512KB) {
                    try { $txt = [IO.File]::ReadAllText($f)
                        $refs = ((@([regex]::Matches($txt, $HostPattern) | ForEach-Object { $_.Value }) + @([regex]::Matches($txt, $PathPattern) | Select-Object -First 5 | ForEach-Object { $_.Value })) | Select-Object -Unique | ForEach-Object { Protect-Text $_ }) -join ' ; '
                    } catch { }
                }
                $scriptRows.Add([pscustomobject]@{ Path = $f; SizeKB = [math]::Round($fi.Length / 1KB, 1); LastWrite = $fi.LastWriteTime.ToString('s'); ReferencesFound = $refs })
            }
        }
    } catch { }
    foreach ($sd in (Get-SubDirs $Dir)) { Find-Scripts $sd ($Depth + 1) }
}
foreach ($r in $roots) { Find-Scripts $r 0 }
Save-Csv $scriptRows 'standalone_scripts.csv'

# ---------------------------------------------------------------- 6. software
Write-Log 'Step 6/9: software and versions' 'STEP'
$tools = @(
    (Get-CommandVersion 'python'), (Get-CommandVersion 'py' @('--list-paths')), (Get-CommandVersion 'pip' @('--version')),
    (Get-CommandVersion 'node' @('-v')), (Get-CommandVersion 'npm' @('-v')), (Get-CommandVersion 'npx' @('-v')),
    (Get-CommandVersion 'pnpm' @('-v')), (Get-CommandVersion 'yarn' @('-v')), (Get-CommandVersion 'nvm' @('version')),
    (Get-CommandVersion 'git'), (Get-CommandVersion 'gh'), (Get-CommandVersion 'code'), (Get-CommandVersion 'cursor'),
    (Get-CommandVersion 'claude'), (Get-CommandVersion 'pwsh' @('-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()')),
    (Get-CommandVersion 'docker'), (Get-CommandVersion 'wsl' @('--version')), (Get-CommandVersion 'clasp'),
    (Get-CommandVersion 'vercel'), (Get-CommandVersion 'railway'), (Get-CommandVersion 'supabase'), (Get-CommandVersion 'n8n'),
    (Get-CommandVersion 'pm2' @('-v')), (Get-CommandVersion 'gcloud' @('--version')), (Get-CommandVersion 'psql'),
    (Get-CommandVersion 'uv'), (Get-CommandVersion 'uvx'), (Get-CommandVersion 'winget' @('--version')), (Get-CommandVersion 'choco' @('--version')),
    (Get-CommandVersion 'ngrok' @('version')), (Get-CommandVersion 'rclone' @('version'))
)
$tools += [pscustomobject]@{ Tool = 'Windows PowerShell (this session)'; Found = 'Yes'; Version = $PSVersionTable.PSVersion.ToString(); Path = $PSHOME }
Save-Csv $tools 'software_cli_versions.csv'

$installed = New-Object System.Collections.Generic.List[object]
foreach ($k in @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    Get-ItemProperty -Path $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and -not $_.SystemComponent } | ForEach-Object {
        $installed.Add([pscustomobject]@{ Name = $_.DisplayName; Version = $_.DisplayVersion; Publisher = $_.Publisher; InstallDate = $_.InstallDate; InstallLocation = $_.InstallLocation; Scope = $(if ($k -like 'HKCU*') { 'User' } else { 'Machine' }) })
    }
}
$installedSorted = $installed | Sort-Object Name -Unique
Save-Csv $installedSorted 'software_installed_programs.csv'
$keyApps = $installedSorted | Where-Object { $_.Name -match '(?i)python|node\.?js|git|visual studio code|claude|powershell|docker|quickbooks|intuit|microsoft (365|office)|office|outlook|excel|postgres|mysql|sql server|sqlite|dbeaver|pgadmin|google drive|onedrive|dropbox|n8n|wsl|ubuntu|java|7-zip|winrar|chrome|edge|firefox|anydesk|teamviewer|vpn|forti|cisco' }
Save-Csv $keyApps 'software_key_programs.csv'

$globalPkgs = New-Object System.Collections.Generic.List[object]
if (Get-Command npm -ErrorAction SilentlyContinue) {
    try { $g = (& npm ls -g --depth=0 --json 2>$null) -join ''
        if ($g) { $gj = $g | ConvertFrom-Json; if ($gj.dependencies) { foreach ($d in $gj.dependencies.PSObject.Properties) { $globalPkgs.Add([pscustomobject]@{ Manager = 'npm -g'; Package = $d.Name; Version = $d.Value.version }) } } }
    } catch { }
}
foreach ($py in @('python', 'py')) {
    if (Get-Command $py -ErrorAction SilentlyContinue) {
        try { $pl = (& $py -m pip list --format=json 2>$null) -join ''
            if ($pl -and $pl.Trim().StartsWith('[')) { foreach ($x in ($pl | ConvertFrom-Json)) { $globalPkgs.Add([pscustomobject]@{ Manager = "$py -m pip"; Package = $x.name; Version = $x.version }) } }
        } catch { }
        break
    }
}
Save-Csv $globalPkgs 'software_global_packages.csv'
if (Get-Command winget -ErrorAction SilentlyContinue) {
    try {
        $wgOut = Join-Path $Shareable 'winget_export.json'
        # winget export only WRITES the output file; it does not install or change anything
        & winget export -o $wgOut --include-versions --accept-source-agreements 2>&1 | Out-Null
        if (Test-Path -LiteralPath $wgOut) { Write-Log 'Wrote winget_export.json' } else { Write-Log 'winget export produced no file' 'WARN' }
    } catch { Add-AccessIssue 'Software' 'winget export' $_.Exception.Message }
}

# ---------------------------------------------------------------- 7. cloud / tool configuration (presence only)
Write-Log 'Step 7/9: cloud service and tool configuration (presence only, no secrets)' 'STEP'
$cloud = New-Object System.Collections.Generic.List[object]
function Add-Cloud { param($Service, $Item, $Path, $Detail, $Transfer)
    $cloud.Add([pscustomobject]@{ Service = $Service; Item = $Item; Path = $Path; Present = [bool]($Path -and (Test-Path -LiteralPath $Path)); Detail = (Protect-Text "$Detail"); HowToTransfer = $Transfer }) }
$gitcfg = Join-Path $home_ '.gitconfig'
$gitDetail = ''
if ($GitExe) {
    $gitDetail = 'user.name=' + "$(& $GitExe config --global user.name 2>$null)" + '; user.email=' + "$(& $GitExe config --global user.email 2>$null)" + '; credential.helper=' + "$(& $GitExe config --global credential.helper 2>$null)" + '; core.autocrlf=' + "$(& $GitExe config --global core.autocrlf 2>$null)"
}
Add-Cloud 'Git' '.gitconfig' $gitcfg $gitDetail 'Copy .gitconfig; credentials -> sign in again (Git Credential Manager)'
if (Get-Command gh -ErrorAction SilentlyContinue) { $ghs = (& gh auth status 2>&1 | Select-Object -First 6) -join ' | '; Add-Cloud 'GitHub CLI' 'gh auth status' (Join-Path $env:APPDATA 'GitHub CLI') $ghs 'gh auth login on new laptop' }
Add-Cloud 'SSH' '~\.ssh' (Join-Path $home_ '.ssh') ((Get-ChildItem -LiteralPath (Join-Path $home_ '.ssh') -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ', ') 'Prefer NEW key on new laptop and add to GitHub; otherwise move private key only via encrypted container'
Add-Cloud 'Vercel CLI' 'auth' (Join-Path $env:APPDATA 'com.vercel.cli') '' 'vercel login'
Add-Cloud 'Vercel CLI' 'auth (alt)' (Join-Path $home_ '.vercel') '' 'vercel login'
Add-Cloud 'Railway CLI' 'config' (Join-Path $home_ '.railway') '' 'railway login'
Add-Cloud 'Supabase CLI' 'config' (Join-Path $home_ '.supabase') '' 'supabase login'
Add-Cloud 'Google clasp' '.clasprc.json (OAuth token)' (Join-Path $home_ '.clasprc.json') 'token file - NOT copied' 'clasp login on new laptop'
Add-Cloud 'Google Cloud SDK' 'config' (Join-Path $env:APPDATA 'gcloud') '' 'gcloud auth login'
Add-Cloud 'n8n (self-hosted local!)' '~\.n8n' (Join-Path $home_ '.n8n') ((Get-ChildItem -LiteralPath (Join-Path $home_ '.n8n') -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ', ') 'If present, local n8n holds workflows+credentials: export workflows; encryption key needed for credentials'
Add-Cloud 'npm' '.npmrc (may contain registry token)' (Join-Path $home_ '.npmrc') 'NOT read' 'Re-create; re-enter tokens'
Add-Cloud 'Python' 'pip.ini' (Join-Path $env:APPDATA 'pip\pip.ini') '' 'Copy if custom index'
Add-Cloud 'Docker' 'config' (Join-Path $home_ '.docker') '' 'docker login'
Add-Cloud 'AWS' 'config' (Join-Path $home_ '.aws') 'NOT read' 'Re-create; credentials from password manager'
Add-Cloud 'Azure' 'config' (Join-Path $home_ '.azure') '' 'az login'
Add-Cloud 'VS Code' 'user settings' (Join-Path $env:APPDATA 'Code\User') '' 'Use VS Code Settings Sync, or copy settings.json/keybindings.json'
if (Get-Command code -ErrorAction SilentlyContinue) { try { $ext = (& code --list-extensions --show-versions 2>$null); Add-Cloud 'VS Code' 'extensions' '' ("$(@($ext).Count) extensions: " + (@($ext) -join ', ')) 'Settings Sync or reinstall list' } catch { } }
foreach ($gd in @('Google\DriveFS', 'Google\Drive')) { Add-Cloud 'Google Drive for desktop' $gd (Join-Path $env:LOCALAPPDATA $gd) '' 'Install and sign in; files stream from cloud (check offline-only folders)' }
Add-Cloud 'OneDrive' 'sync root' $env:OneDrive '' 'Sign in; confirm "Files On-Demand" items that exist only locally are uploaded'
Add-Cloud 'OneDrive for Business' 'sync root' $env:OneDriveCommercial '' 'Sign in with Microsoft 365 account'
if (Get-Command docker -ErrorAction SilentlyContinue) { try { $dps = (& docker ps -a --format '{{.Names}} | {{.Image}} | {{.Status}}' 2>$null) -join ' ;; '; Add-Cloud 'Docker' 'containers' '' $dps 'Rebuild from compose files; export volumes if they hold data' } catch { } }

# Machine/user environment variable NAMES only
$envRows = New-Object System.Collections.Generic.List[object]
foreach ($scope in @('User', 'Machine')) {
    $vars = [Environment]::GetEnvironmentVariables($scope)
    foreach ($n in $vars.Keys) {
        $val = "$($vars[$n])"
        $show = if ($n -match '(?i)^(path|pathext|psmodulepath|pythonpath|node_path|java_home|nvm_home|nvm_symlink|pyenv.*|onedrive.*|temp|tmp)$') { Protect-Text $val } else { '<not recorded>' }
        $envRows.Add([pscustomobject]@{ Scope = $scope; Name = $n; LooksSecret = (Test-SecretName $n); Value = $show })
    }
}
Save-Csv $envRows 'windows_environment_variable_NAMES.csv'
Save-Csv $cloud 'cloud_and_tool_config.csv'

# ---------------------------------------------------------------- 8. important user data outside projects
Write-Log 'Step 8/9: QuickBooks / Outlook / database data files (locations only)' 'STEP'
$dataOutside = New-Object System.Collections.Generic.List[object]
$dataSearch = @([Environment]::GetFolderPath('MyDocuments'), [Environment]::GetFolderPath('Desktop'), (Join-Path $home_ 'Downloads'), 'C:\Users\Public\Documents', (Join-Path $env:LOCALAPPDATA 'Microsoft\Outlook'), 'C:\x') + ($disks | Where-Object { $_.Drive -ne 'C:' } | ForEach-Object { $_.Drive + '\' })
foreach ($ds in $dataSearch) {
    if ($ds -and (Test-Path -LiteralPath $ds)) {
        Get-ChildItem -LiteralPath $ds -Recurse -Force -File -Depth 6 -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -match '(?i)^\.(qbw|qbb|qbm|tlg|nd|pst|ost|kdbx|accdb|mdb|sqlite|db)$' -and $_.FullName -notmatch '(?i)\\node_modules\\|\\AppData\\Local\\(Google|Microsoft\\Edge|Packages)\\' } |
            Select-Object -First 500 | ForEach-Object { $dataOutside.Add([pscustomobject]@{ Type = $_.Extension; Path = $_.FullName; SizeMB = [math]::Round($_.Length / 1MB, 2); LastWrite = $_.LastWriteTime.ToString('s') }) }
    }
}
Save-Csv $dataOutside 'important_data_files.csv'

# ---------------------------------------------------------------- 9. summary + manifest
Write-Log 'Step 9/9: summary and checksum manifest' 'STEP'
Save-Csv $script:AccessIssues 'access_issues.csv'
$summary = [ordered]@{
    computer                 = $env:COMPUTERNAME
    auditTime                = $StartTime.ToString('s')
    durationMinutes          = [math]::Round(((Get-Date) - $StartTime).TotalMinutes, 1)
    runningAsAdmin           = $isAdmin
    searchRoots              = $roots
    projectsFound            = $projRows.Count
    projectsNotInGit         = @($projRows | Where-Object { -not $_.IsGit }).Count
    projectsWithUncommitted  = @($projRows | Where-Object { $_.UncommittedChanges -and [int]$_.UncommittedChanges -gt 0 }).Count
    projectsWithUnpushed     = @($projRows | Where-Object { $_.UnpushedCommits -and [int]$_.UnpushedCommits -gt 0 }).Count
    secretFilesFound         = $secretFiles.Count
    localDataFilesInProjects = $dataFiles.Count
    hardcodedPathRefs        = $hardPaths.Count
    customScheduledTasks     = $taskRows.Count
    scheduledTasksEnabled    = @($taskRows | Where-Object { $_.State -ne 'Disabled' }).Count
    scheduledTasksDisabled   = @($taskRows | Where-Object { $_.State -eq 'Disabled' }).Count
    startupItems             = $startup.Count
    nonWindowsServices       = @($services).Count
    runningScriptProcesses   = @($procRows).Count
    pm2Entries               = @($pm2Rows).Count
    standaloneScripts        = $scriptRows.Count
    importantDataFiles       = $dataOutside.Count
    accessIssues             = $script:AccessIssues.Count
}
Save-Json $summary 'audit_summary.json'

$manifest = Get-ChildItem -LiteralPath $OutputRoot -Recurse -File -Force | Where-Object { $_.Name -ne 'MANIFEST_SHA256.csv' } | ForEach-Object {
    [pscustomobject]@{ RelativePath = $_.FullName.Substring($OutputRoot.Length).TrimStart('\'); SizeBytes = $_.Length; SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
}
$manifest | Export-Csv -LiteralPath (Join-Path $OutputRoot 'MANIFEST_SHA256.csv') -NoTypeInformation -Encoding UTF8
Write-Log ("DONE in {0} min. Results: {1}" -f $summary.durationMinutes, $OutputRoot) 'STEP'
Write-Host ''
Write-Host 'Audit finished. Nothing on this computer was changed.' -ForegroundColor Green
Write-Host "Share ONLY the SHAREABLE folder: $Shareable" -ForegroundColor Green
Write-Host "Keep PRIVATE_DO_NOT_UPLOAD offline: $Private" -ForegroundColor Yellow
