#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only migration audit of the OLD Windows laptop (Phase 1: inventory only).

.DESCRIPTION
    Builds an inventory of projects (including Claude-related ones), Claude Desktop /
    Claude Code configuration, scheduled tasks, startup items, services, PM2,
    running script processes, stand-alone scripts, HTML pages, Excel workbooks,
    important data files, installed software and cloud-tool configuration.

    WHAT THIS SCRIPT DOES NOT DO
      * It does not delete, move, rename, edit or re-save any existing file.
      * It does not create, enable, disable, start, stop, run or change any scheduled
        task, service or process (other than the short read-only child processes below).
      * It does not upload anything, and it never opens OneDrive/Google Drive
        "online-only" files (opening them would download them).
      * It does not read secret files. For .env files only the variable NAMES are kept.
      * It writes ONLY inside a new output folder, and refuses an output folder that is
        cloud-synced (OneDrive, Google Drive, Dropbox, iCloud, Box), on a network share,
        inside a system folder or inside a Git repository.

    EXTERNAL PROGRAMS IT RUNS (read-only, timeout, hidden window, stdin closed,
    working directory = output folder, update checks/telemetry disabled for the child):
      git (local queries only: status/log/rev-parse/rev-list/for-each-ref/stash list/
      remote -v/config --get), node -v, python --version, py --list-paths,
      python -B -m pip list, docker --version, docker ps -a (only if the engine is
      already running), gh --version, uv --version, winget --version, psql --version,
      cmdkey /list (credential target names only), schtasks /Query (fallback only).
      Optional (-IncludeWinget): winget export into the output folder.
      All other tools (npm, pnpm, yarn, clasp, vercel, railway, supabase, n8n, pm2,
      claude, code, pwsh, gcloud, ngrok, wsl, ...) are detected from files only and are
      NOT executed, because running them can trigger updates, downloads, logs or daemons.

    OUTPUT LAYOUT
      <OutputRoot>\SHAREABLE\               redacted CSV/JSON (review before sharing)
      <OutputRoot>\PRIVATE_DO_NOT_UPLOAD\   raw scheduled-task XML, identity map,
                                            secret-file hashes (current user + SYSTEM only)
      <OutputRoot>\audit_log.txt            redacted log incl. every error
      <OutputRoot>\AUDIT_STATUS.txt         verdict: COMPLETE / PARTIAL / INCOMPLETE
      <OutputRoot>\MANIFEST_SHA256.csv      checksums of all output files

.PARAMETER OutputRoot
    New (or empty) local folder for the results.
    Default: %USERPROFILE%\MIGRATION_AUDIT_<computer>_<timestamp>
    (not the Desktop: the Desktop is often synced to OneDrive).

.PARAMETER ExtraRoots
    Additional folders to search, e.g. -ExtraRoots 'D:\Work','E:\Archive'

.PARAMETER MaxDepth
    Folder depth searched under each root (default 6).

.PARAMETER MaxScanFileMB
    Larger text files are listed but their content is not scanned (default 2).

.PARAMETER IncludeWinget
    Also run "winget export" (writes only into the output folder, but winget may refresh
    its own package-source cache). Off by default.

.PARAMETER SelfTest
    Run the built-in redaction/parsing tests only. Scans nothing and writes nothing.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Audit-OldLaptop.ps1 -SelfTest
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Audit-OldLaptop.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Audit-OldLaptop.ps1 -ExtraRoots 'D:\Work'

.NOTES
    Version 2.0.1 - Windows PowerShell 5.1 and PowerShell 7+.
    "-ExecutionPolicy Bypass" applies to this one process only.
    Exit codes: 0 = COMPLETE, 2 = PARTIAL (usable, with gaps), 1 = INCOMPLETE / refused.
#>
[CmdletBinding()]
param(
    [string]$OutputRoot,
    [string[]]$ExtraRoots = @(),
    [ValidateRange(1, 20)][int]$MaxDepth = 6,
    [ValidateRange(1, 50)][int]$MaxScanFileMB = 2,
    [switch]$IncludeWinget,
    [switch]$SelfTest
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$ScriptVersion = '2.0.1'
$StartTime = Get-Date
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)

# "-File" passes  -ExtraRoots "D:\a","E:\b"  as ONE string; split it into folders
$ExtraRoots = @($ExtraRoots | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().Trim('"').Trim("'") } | Where-Object { $_ })

# =====================================================================================
#  Redaction (secrets) and masking (personal data)
# =====================================================================================
$script:PiiProfile = $env:USERPROFILE
$script:PiiUser = $env:USERNAME

function Protect-KnownTokens {
    # Safe over whole CSV text: no pattern consumes quotes or commas.
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $t = $Text
    $t = [regex]::Replace($t, '-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)', '<REDACTED-PRIVATE-KEY>')
    # credentials inside URLs: scheme://user:pass@host  or  scheme://token@host
    $t = [regex]::Replace($t, '(?i)\b([a-z][a-z0-9+.-]{1,15}://)[^/\s@"'',<>]+@', '${1}<REDACTED>@')
    # query strings / fragments of URLs
    $t = [regex]::Replace($t, '(?i)(https?://[^\s"'',<>?#]+)[?#][^\s"'',<>]*', '${1}?<QUERY-REDACTED>')
    # webhook URLs: everything after the fixed prefix is the secret
    $t = [regex]::Replace($t, '(?i)(hooks\.slack\.com/services/|discord(app)?\.com/api/webhooks/|/webhook(-test)?/|outlook\.office(365)?\.com/webhook/|api\.telegram\.org/bot)[^\s"'',<>]+', '${1}<REDACTED>')
    # long opaque path segments inside URLs (deployment ids, sheet ids, tokens)
    $t = [regex]::Replace($t, '(?i)(https?://[^\s"'',<>/]+)(/[^\s"'',<>]*)', {
            param($m)
            $segs = $m.Groups[2].Value -split '/'
            $out = foreach ($s in $segs) {
                if ($s.Length -ge 24 -and $s -match '^[A-Za-z0-9_-]+$' -and $s -match '[0-9]' -and $s -match '[A-Za-z]') { '<ID>' } else { $s }
            }
            $m.Groups[1].Value + ($out -join '/')
        })
    # well-known key formats
    $t = [regex]::Replace($t, '\b(sk-ant-[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{20,}|(sk|rk|pk)_(live|test)_[A-Za-z0-9]{10,}|sb_(secret|publishable)_[A-Za-z0-9_-]{10,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|xox[abprs]-[A-Za-z0-9-]+|AIza[0-9A-Za-z_-]{20,}|ya29\.[A-Za-z0-9_-]+|1//[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|npm_[A-Za-z0-9]{30,}|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*|\d{8,10}:AA[A-Za-z0-9_-]{30,})', '<REDACTED-KEY>')
    # any other long opaque token (>= 32 chars, not part of a path or file name)
    $t = [regex]::Replace($t, '(?<![A-Za-z0-9\\/._=-])[A-Za-z0-9+_-]{32,}={0,2}(?![A-Za-z0-9\\/._-])', '<REDACTED-LONG>')
    return $t
}

function Protect-Text {
    # Field-level redaction (use per value, NOT over whole CSV text).
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $t = $Text
    $t = [regex]::Replace($t, '(?i)(https?://[^\s"'',<>?#]+)[?#][^\s"'',<>]*', '${1}?<QUERY-REDACTED>')
    $t = [regex]::Replace($t, '(?i)\b(Bearer|Basic|Token)\s+[A-Za-z0-9._~+/=-]{8,}', '${1} <REDACTED>')
    # name=value / name: value / --name value / -Name value   for secret-looking names
    $t = [regex]::Replace($t, '(?i)(?<![A-Za-z0-9])(?<name>(--?)?[A-Za-z0-9_.-]*(?:pass(?:word|wd|phrase)?|pwd|secret|token|api[_-]?key|apikey|[_-]key|auth|bearer|credential|private[_-]?key|service[_-]?key|access[_-]?key|client[_-]?secret|conn(?:ection)?[_-]?string|signature)[A-Za-z0-9_.-]*)(?<sep>\s*[=:]\s*|\s+)(?<val>"[^"]*"|''[^'']*''|[^\s;&]+)', '${name}${sep}<REDACTED>')
    $t = [regex]::Replace($t, '(?i)\b(password|pwd)\s*=\s*[^;"]*', '${1}=<REDACTED>')
    return (Protect-KnownTokens $t)
}

function Hide-Pii {
    # Safe over whole CSV text.
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $t = $Text
    $opt = [Text.RegularExpressions.RegexOptions]::IgnoreCase
    if ($script:PiiProfile -and $script:PiiProfile.Length -gt 3) {
        foreach ($f in @(($script:PiiProfile -replace '\\', '\\'), $script:PiiProfile, ($script:PiiProfile -replace '\\', '/'))) {
            $t = [regex]::Replace($t, [regex]::Escape($f), '%USERPROFILE%', $opt)
        }
    }
    # other profiles  C:\Users\<name>  (names may contain spaces when the path continues)
    $t = [regex]::Replace($t, '(?i)\b([A-Z]:(\\\\|\\|/)Users(\\\\|\\|/))(?!Public\b|Default\b|All Users\b|<USER>)([^\\/"'',;:*?<>|\r\n]+)(?=\\|/)', '${1}<USER>')
    $t = [regex]::Replace($t, '(?i)\b([A-Z]:(\\\\|\\|/)Users(\\\\|\\|/))(?!Public\b|Default\b|All Users\b|<USER>)([^\\/"'',;:*?<>|\s]+)', '${1}<USER>')
    if ($script:PiiUser -and $script:PiiUser.Length -ge 3) {
        $t = [regex]::Replace($t, '(?<![A-Za-z0-9])' + [regex]::Escape($script:PiiUser) + '(?![A-Za-z0-9])', '<USER>', $opt)
    }
    # e-mail addresses (domain kept: it shows which kind of account is involved)
    $t = [regex]::Replace($t, '(?i)(?<![A-Za-z0-9._%+-])([A-Za-z0-9._%+-]+)@([A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})', {
            param($m)
            if ($m.Groups[1].Value -ieq 'git') { $m.Value } else { '<EMAIL>@' + $m.Groups[2].Value }
        })
    $t = [regex]::Replace($t, '(?<![\w+])(\+|00)[1-9]\d{0,3}[\s.-]?\(?\d{1,4}\)?([\s.-]?\d{2,4}){2,4}(?![\w])', '<PHONE>')
    $t = [regex]::Replace($t, '(?<!\d)01[0125]\d{8}(?!\d)', '<PHONE>')
    $t = [regex]::Replace($t, '\b[A-Z]{2}\d{2}(\s?[A-Z0-9]{4}){3,7}(\s?[A-Z0-9]{1,4})?\b', '<IBAN>')
    $t = [regex]::Replace($t, 'S-1-5-21-\d+-\d+-\d+(-\d+)?', 'S-1-5-21-<SID>')
    return $t
}

function Format-Safe { param([string]$Text) return (Hide-Pii (Protect-Text $Text)) }
function Protect-Output { param([string]$Text) return (Hide-Pii (Protect-KnownTokens $Text)) }
function Test-SecretName {
    param([string]$Name)
    return ($Name -match '(?i)(pass|pwd|secret|token|key|auth|credential|cert|private|session|cookie|conn(ection)?str|database_url|dsn|webhook|signature)')
}

# =====================================================================================
#  Pure helpers (also used by -SelfTest)
# =====================================================================================
function ConvertTo-ArgString {
    # Quote arguments for CreateProcess (MSVCRT rules).
    param([string[]]$ArgList)
    $out = foreach ($a in $ArgList) {
        if ($null -eq $a -or $a -eq '') { '""' }
        elseif ($a -notmatch '[\s"]') { $a }
        else {
            $e = $a -replace '(\\*)"', '$1$1\"'
            $e = $e -replace '(\\+)$', '$1$1'
            '"' + $e + '"'
        }
    }
    return ($out -join ' ')
}

$ScriptExtensions = @('.ps1', '.psm1', '.bat', '.cmd', '.vbs', '.vbe', '.wsf', '.js', '.mjs', '.cjs', '.ts', '.py', '.pyw', '.sh', '.ahk', '.gs', '.rb', '.php', '.r')
function Get-PathsFromCommand {
    # File paths referenced by a command line (scheduled tasks / startup items).
    param([string]$Execute, [string]$Arguments, [string]$WorkingDirectory)
    $result = New-Object System.Collections.Generic.List[string]
    $wd = ''
    if ($WorkingDirectory) { $wd = [Environment]::ExpandEnvironmentVariables($WorkingDirectory.Trim().Trim('"')) }
    $all = [Environment]::ExpandEnvironmentVariables("$Execute $Arguments")
    foreach ($m in [regex]::Matches($all, '"([^"]+)"|(\S+)')) {
        $tok = $m.Groups[1].Value
        if (-not $tok) { $tok = $m.Groups[2].Value }
        $tok = $tok.Trim().TrimEnd(',', ';')
        if ($tok -match '^(-|/)[A-Za-z]') { continue }
        $cand = $null
        if ($tok -match '^[A-Za-z]:\\' -or $tok -match '^\\\\') { $cand = $tok }
        elseif ($wd -and $tok -notmatch '[:*?<>|]' -and ($ScriptExtensions -contains ([IO.Path]::GetExtension($tok).ToLowerInvariant()))) { $cand = $wd.TrimEnd('\') + '\' + $tok }
        if ($cand -and -not $result.Contains($cand)) { $result.Add($cand) }
    }
    return , $result
}

$PathPattern = '(?i)(?<![A-Za-z0-9])([A-Z]:\\{1,2}[^"''`<>|\r\n\t*?]{2,160}|[A-Z]:/[^"''`<>|\r\n\t*?\s]{2,160}|\\\\[A-Za-z0-9._-]+\\[^"''`<>|\r\n\t*?]{2,160})'
$HostPattern = '(?i)(https?://[a-z0-9.-]*(supabase\.co|railway\.app|vercel\.app|netlify\.app|n8n\.cloud|app\.n8n\.io|script\.google\.com|docs\.google\.com|drive\.google\.com|googleapis\.com|graph\.microsoft\.com|sharepoint\.com|office\.com|office365\.com|outlook\.com|intuit\.com|quickbooks|api\.anthropic\.com|claude\.ai|openai\.com|github\.com|githubusercontent\.com|hooks\.slack\.com|slack\.com|api\.telegram\.org|twilio\.com|sendgrid\.(com|net)|mailgun|stripe\.com|ngrok|herokuapp\.com|amazonaws\.com|azurewebsites\.net)[a-z0-9./_-]*|localhost:\d+|127\.0\.0\.1:\d+|vessel-profit-ingest|smtp\.[a-z0-9.-]+)'
function Get-PathRefs {
    param([string]$Line)
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($Line, $PathPattern)) {
        $p = $m.Value.Trim()
        $p = ($p -split '\s+(?=(-{1,2}|/)[A-Za-z])')[0]
        $p = ($p -split '\s+(?=https?:)')[0]
        $p = $p.TrimEnd(',', ';', ')', ']', '}', ' ', '.')
        if ($p -match '^[A-Za-z]:\\[nrtsdbwSDWBfv](\W|$)') { continue }   # regex escapes such as e:\s
        if ($p -match '\\[sdwSDWbB][\*\+\?\{\)]') { continue }
        if ($p.Length -lt 5) { continue }
        if (-not $found.Contains($p)) { $found.Add($p) }
    }
    return , $found
}

# =====================================================================================
#  Self-test: no scanning, no writing
# =====================================================================================
if ($SelfTest) {
    $script:PiiProfile = 'C:\Users\test.user'
    $script:PiiUser = 'test.user'
    $cases = @(
        @{ F = 'Format-Safe'; In = 'python C:\x\push.py --api-key abc123xyz'; MustNot = @('abc123xyz'); Must = @('C:\x\push.py') },
        @{ F = 'Format-Safe'; In = 'MONTE_INGEST_KEY=supersecretvalue node run.js'; MustNot = @('supersecretvalue'); Must = @('MONTE_INGEST_KEY') },
        @{ F = 'Format-Safe'; In = 'curl -H "Authorization: Bearer abcdefghijklmnop" https://x.up.railway.app/api'; MustNot = @('abcdefghijklmnop') },
        @{ F = 'Format-Safe'; In = 'postgres://dbuser:Pa55word!@db.supabase.co:5432/postgres'; MustNot = @('Pa55word', 'dbuser') },
        @{ F = 'Format-Safe'; In = 'Server=x;Database=y;User Id=u;Password=P@ss;'; MustNot = @('P@ss') },
        @{ F = 'Format-Safe'; In = 'key sk-ant-api03-AbCdEf123456 and ghp_abcdefghijklmnopqrstuvwxyz0123'; MustNot = @('sk-ant-api03', 'ghp_abc') },
        @{ F = 'Format-Safe'; In = 'https://script.google.com/macros/s/AKfycbx1234567890abcdefghijklmnopqrstuv/exec'; MustNot = @('AKfycbx1234567890') },
        @{ F = 'Format-Safe'; In = 'https://api.example.com/v1/items?token=zzz999&x=1'; MustNot = @('zzz999') },
        @{ F = 'Format-Safe'; In = 'https://hooks.slack.com/services/T000/B000/XXXXSECRET'; MustNot = @('XXXXSECRET') },
        @{ F = 'Format-Safe'; In = 'C:\Users\test.user\Desktop\proj and C:\Users\other.person\x'; MustNot = @('test.user', 'other.person'); Must = @('%USERPROFILE%\Desktop\proj') },
        @{ F = 'Format-Safe'; In = 'C:\Users\Jane Doe\Documents\a.xlsx'; MustNot = @('Jane Doe') },
        @{ F = 'Format-Safe'; In = 'C:\\Users\\test.user\\AppData'; MustNot = @('test.user') },
        @{ F = 'Format-Safe'; In = 'contact mezzo.someone@gmail.com or git@github.com:me/repo.git'; MustNot = @('mezzo.someone'); Must = @('@gmail.com', 'git@github.com') },
        @{ F = 'Format-Safe'; In = 'call +20 100 123 4567 or 01001234567'; MustNot = @('123 4567', '01001234567') },
        @{ F = 'Format-Safe'; In = 'IBAN EG380019000500000000263180002'; MustNot = @('263180002') },
        @{ F = 'Format-Safe'; In = 'owner S-1-5-21-1111111111-2222222222-3333333333-1001'; MustNot = @('2222222222') },
        @{ F = 'Format-Safe'; In = 'C:\x\_PMS\monte_pms.json'; Must = @('C:\x\_PMS\monte_pms.json') },
        @{ F = 'Format-Safe'; In = 'C:\Program Files\nodejs\node.exe C:\tools\sync.js'; Must = @('C:\Program Files\nodejs\node.exe', 'C:\tools\sync.js') },
        @{ F = 'Format-Safe'; In = 'v20.11.1 build 22631 version 3.11.9'; Must = @('v20.11.1', '22631', '3.11.9') },
        @{ F = 'Protect-Output'; In = '"a","eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcDEF123","b"'; MustNot = @('eyJhbGci'); Must = @('"a","', '","b"') }
    )
    $fail = 0
    foreach ($c in $cases) {
        $out = & $c.F $c.In
        $ok = $true
        foreach ($bad in @($c.MustNot)) { if ($bad -and $out.Contains($bad)) { $ok = $false } }
        foreach ($good in @($c.Must)) { if ($good -and -not $out.Contains($good)) { $ok = $false } }
        if ($ok) { Write-Host ('PASS  ' + $out) -ForegroundColor Green } else { $fail++; Write-Host ('FAIL  in : ' + $c.In) -ForegroundColor Red; Write-Host ('      out: ' + $out) -ForegroundColor Red }
    }
    $q = ConvertTo-ArgString @('-C', 'C:\My Repo', 'log', '--format=%ci', 'a"b', 'D:\')
    if ($q -eq '-C "C:\My Repo" log --format=%ci "a\"b" D:\') { Write-Host "PASS  args: $q" -ForegroundColor Green } else { $fail++; Write-Host "FAIL  args: $q" -ForegroundColor Red }
    $p1 = Get-PathsFromCommand 'powershell.exe' '-NoProfile -File "C:\x\My Script.ps1" -Mode run' 'C:\x'
    if ($p1 -contains 'C:\x\My Script.ps1') { Write-Host "PASS  task paths: $($p1 -join ' | ')" -ForegroundColor Green } else { $fail++; Write-Host "FAIL  task paths: $($p1 -join ' | ')" -ForegroundColor Red }
    $p2 = Get-PathsFromCommand 'python.exe' 'push.py --line monte' 'C:\x\_PMS'
    if ($p2 -contains 'C:\x\_PMS\push.py') { Write-Host "PASS  relative script: $($p2 -join ' | ')" -ForegroundColor Green } else { $fail++; Write-Host "FAIL  relative script: $($p2 -join ' | ')" -ForegroundColor Red }
    $r1 = Get-PathRefs 'const f = "C:\x\_PMS\monte_pms.json"; re = /e:\s*avoid/'
    if ($r1.Count -eq 1 -and $r1[0] -eq 'C:\x\_PMS\monte_pms.json') { Write-Host "PASS  path refs: $($r1 -join ' | ')" -ForegroundColor Green } else { $fail++; Write-Host "FAIL  path refs: $($r1 -join ' | ')" -ForegroundColor Red }
    if ($fail -eq 0) { Write-Host 'SELF-TEST PASSED (nothing was scanned or written)' -ForegroundColor Green; exit 0 }
    Write-Host "SELF-TEST FAILED: $fail case(s)" -ForegroundColor Red
    exit 1
}

if ($env:OS -ne 'Windows_NT') { Write-Host 'This audit must run on Windows.' -ForegroundColor Red; exit 1 }

# =====================================================================================
#  Output location: new/empty, local, not cloud-synced, not in a system folder or Git repo
# =====================================================================================
$script:EarlyWarnings = New-Object System.Collections.Generic.List[string]
function Get-SyncRoots {
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($v in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial)) { if ($v) { $list.Add($v) } }
    Get-ChildItem 'HKCU:\Software\Microsoft\OneDrive\Accounts' -ErrorAction SilentlyContinue | ForEach-Object {
        $uf = (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).UserFolder
        if ($uf) { $list.Add($uf) }
    }
    Get-ChildItem 'HKCU:\Software\SyncEngines\Providers\OneDrive' -ErrorAction SilentlyContinue | ForEach-Object {
        $mp = (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).MountPoint
        if ($mp) { $list.Add($mp) }
    }
    foreach ($ij in @((Join-Path $env:APPDATA 'Dropbox\info.json'), (Join-Path $env:LOCALAPPDATA 'Dropbox\info.json'))) {
        if (Test-Path -LiteralPath $ij) {
            try { $dj = [IO.File]::ReadAllText($ij) | ConvertFrom-Json; foreach ($p in $dj.PSObject.Properties) { if ($p.Value.path) { $list.Add($p.Value.path) } } } catch { $script:EarlyWarnings.Add("Dropbox info.json unreadable ($ij): sync folder may be undetected") }
        }
    }
    Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.VolumeName -match '(?i)google ?drive' } | ForEach-Object { $list.Add($_.DeviceID + '\') }
    foreach ($p in @('Google Drive', 'My Drive', 'iCloudDrive', 'iCloud Drive', 'Box', 'Dropbox')) {
        $fp = Join-Path $env:USERPROFILE $p
        if (Test-Path -LiteralPath $fp) { $list.Add($fp) }
    }
    return @($list | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') } | Select-Object -Unique)
}
function Test-UnderPath {
    param([string]$Child, [string]$Parent)
    if (-not $Child -or -not $Parent) { return $false }
    $c = $Child.TrimEnd('\') + '\'
    $p = $Parent.TrimEnd('\') + '\'
    return $c.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)
}
function Test-OutputLocation {
    param([string]$Path, [string[]]$SyncRoots)
    if ($Path.StartsWith('\\')) { return 'network path (results must stay on this computer or your own external drive)' }
    $ld = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $Path.Substring(0, 2)) -ErrorAction SilentlyContinue
    if ($ld -and $ld.DriveType -eq 4) { return 'mapped network drive' }
    foreach ($r in $SyncRoots) { if (Test-UnderPath $Path $r) { return "inside a cloud-synced folder ($r) - PRIVATE files would be uploaded" } }
    foreach ($sys in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:APPDATA, $env:LOCALAPPDATA)) {
        if ($sys -and (Test-UnderPath $Path $sys)) { return "inside a system/application folder ($sys)" }
    }
    $probe = Split-Path $Path -Parent
    while ($probe) {
        if (Test-Path -LiteralPath (Join-Path $probe '.git')) { return "inside a Git repository ($probe) - results could be committed by mistake" }
        $next = Split-Path $probe -Parent
        if (-not $next -or $next -eq $probe) { break }
        $probe = $next
    }
    return $null
}

$SyncRoots = @(Get-SyncRoots)
$leafName = 'MIGRATION_AUDIT_{0}_{1}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss')
if ($OutputRoot) {
    $OutputRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot).TrimEnd('\')
    $why = Test-OutputLocation $OutputRoot $SyncRoots
    if ($why) { Write-Host "Refusing output folder: $OutputRoot" -ForegroundColor Red; Write-Host "Reason: $why" -ForegroundColor Red; Write-Host 'Nothing was written.' -ForegroundColor Red; exit 1 }
} else {
    foreach ($c in @((Join-Path $env:USERPROFILE $leafName), (Join-Path ($env:SystemDrive + '\') $leafName))) { if (-not (Test-OutputLocation $c $SyncRoots)) { $OutputRoot = $c; break } }
    if (-not $OutputRoot) { Write-Host 'No safe default output folder (profile and system drive look cloud-synced). Use -OutputRoot with a local folder or external drive. Nothing was written.' -ForegroundColor Red; exit 1 }
}
if ((Test-Path -LiteralPath $OutputRoot) -and @(Get-ChildItem -LiteralPath $OutputRoot -Force -ErrorAction SilentlyContinue).Count -gt 0) {
    Write-Host "Output folder already exists and is not empty: $OutputRoot" -ForegroundColor Red
    Write-Host 'Choose a new folder with -OutputRoot. Nothing was written.' -ForegroundColor Red
    exit 1
}
$Shareable = Join-Path $OutputRoot 'SHAREABLE'
$Private = Join-Path $OutputRoot 'PRIVATE_DO_NOT_UPLOAD'
$TaskXml = Join-Path $Private 'scheduled_tasks_xml'
try { foreach ($d in @($OutputRoot, $Shareable, $Private, $TaskXml)) { New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null } }
catch { Write-Host "Cannot create output folder: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
$LogFile = Join-Path $OutputRoot 'audit_log.txt'
$script:SafeWorkDir = $OutputRoot

# Child-process environment for THIS process only (nothing is changed on the system):
# no update checks, telemetry, prompts, optional Git locks, npm log files or .pyc writes.
$ChildEnv = @{
    GIT_OPTIONAL_LOCKS = '0'; GIT_TERMINAL_PROMPT = '0'; GCM_INTERACTIVE = 'never'; GIT_PAGER = 'cat'; PAGER = 'cat'
    PYTHONDONTWRITEBYTECODE = '1'; PIP_DISABLE_PIP_VERSION_CHECK = '1'; PIP_NO_INPUT = '1'; PYTHONIOENCODING = 'utf-8'
    NO_UPDATE_NOTIFIER = '1'; npm_config_update_notifier = 'false'; npm_config_logs_max = '0'
    GH_NO_UPDATE_NOTIFIER = '1'; GH_PROMPT_DISABLED = '1'; GH_SPINNER_DISABLED = '1'
    DOCKER_CLI_HINTS = 'false'; POWERSHELL_TELEMETRY_OPTOUT = '1'; POWERSHELL_UPDATECHECK = 'Off'
    DISABLE_AUTOUPDATER = '1'; COREPACK_ENABLE_DOWNLOAD_PROMPT = '0'
}
foreach ($k in $ChildEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $ChildEnv[$k], 'Process') }

# =====================================================================================
#  Logging, issues, coverage notes, step status
# =====================================================================================
$script:Issues = New-Object System.Collections.Generic.List[object]
$script:Coverage = New-Object System.Collections.Generic.List[object]
$script:Steps = New-Object System.Collections.Generic.List[object]
$script:CurrentStep = 'setup'
$script:LogWriteFailures = 0
$script:Counters = @{ ContentSkippedSize = 0; CloudOnlySkipped = 0; LegacyXls = 0; DepthLimited = 0; PathTooLong = 0; ExcelUnreadable = 0 }

function Write-AuditLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, (Format-Safe $Message)
    try { [IO.File]::AppendAllText($LogFile, $line + "`r`n", $Utf8Bom) } catch { $script:LogWriteFailures++ }
    if ($Level -eq 'ERROR') { Write-Host $line -ForegroundColor Red }
    elseif ($Level -eq 'WARN') { Write-Host $line -ForegroundColor Yellow }
    elseif ($Level -eq 'STEP') { Write-Host $line -ForegroundColor Cyan }
}
function Add-Issue {
    param([string]$Area, [string]$Path, [string]$Reason, [string]$Severity = 'WARN')
    $script:Issues.Add([pscustomobject]@{ Step = $script:CurrentStep; Severity = $Severity; Area = $Area; Path = (Format-Safe $Path); Reason = (Format-Safe $Reason) })
    if ($script:Issues.Count -le 300) { Write-AuditLog ("{0}: {1} -> {2}" -f $Area, $Path, $Reason) $(if ($Severity -eq 'ERROR') { 'ERROR' } else { 'WARN' }) }
    elseif ($script:Issues.Count -eq 301) { Write-AuditLog 'More than 300 issues - the rest are only in access_issues.csv' 'WARN' }
}
function Add-Coverage {
    param([string]$Area, [string]$Note, [bool]$Partial = $true)
    $script:Coverage.Add([pscustomobject]@{ Step = $script:CurrentStep; Area = $Area; AffectsCompleteness = $Partial; Note = (Format-Safe $Note) })
    Write-AuditLog ('COVERAGE {0}: {1}' -f $Area, $Note) $(if ($Partial) { 'WARN' } else { 'INFO' })
}
function Start-Step {
    param([string]$Name)
    $script:CurrentStep = $Name
    $script:StepStart = Get-Date
    $script:StepIssues0 = $script:Issues.Count
    $script:StepCoverage0 = @($script:Coverage | Where-Object { $_.AffectsCompleteness }).Count
    Write-AuditLog "=== $Name" 'STEP'
}
function Complete-Step {
    param($Failure)
    $status = 'OK'
    if ($Failure) { Add-Issue 'Step' '' ('step aborted: ' + $Failure.Exception.Message + ' (line ' + $Failure.InvocationInfo.ScriptLineNumber + ')') 'ERROR' }
    $newIssues = $script:Issues.Count - $script:StepIssues0
    $newCov = @($script:Coverage | Where-Object { $_.AffectsCompleteness }).Count - $script:StepCoverage0
    if ($Failure) { $status = 'FAILED' } elseif ($newIssues -gt 0 -or $newCov -gt 0) { $status = 'PARTIAL' }
    $script:Steps.Add([pscustomobject]@{ Step = $script:CurrentStep; Status = $status; NewIssues = $newIssues; CompletenessGaps = $newCov; Seconds = [math]::Round(((Get-Date) - $script:StepStart).TotalSeconds, 1) })
    Write-AuditLog ('--- {0}: {1} (issues {2}, coverage gaps {3})' -f $script:CurrentStep, $status, $newIssues, $newCov) $(if ($status -eq 'OK') { 'INFO' } else { 'WARN' })
}
function Save-Csv {
    param($Data, [string]$Name, [switch]$PrivateFile)
    $folder = $Shareable
    if ($PrivateFile) { $folder = $Private }
    $path = Join-Path $folder $Name
    $rows = @($Data | Where-Object { $null -ne $_ })
    if ($rows.Count -eq 0) { $text = '"(no rows)"' } else { $text = (@($rows | ConvertTo-Csv -NoTypeInformation) -join "`r`n") }
    if (-not $PrivateFile) { $text = Protect-Output $text }
    try { [IO.File]::WriteAllText($path, $text + "`r`n", $Utf8Bom); Write-AuditLog "Wrote $Name ($($rows.Count) rows)" }
    catch { Add-Issue 'Output' $path $_.Exception.Message 'ERROR' }
}
function Save-Json {
    param($Data, [string]$Name, [switch]$PrivateFile)
    $folder = $Shareable
    if ($PrivateFile) { $folder = $Private }
    $text = ($Data | ConvertTo-Json -Depth 8)
    if (-not $PrivateFile) { $text = Protect-Output $text }
    try { [IO.File]::WriteAllText((Join-Path $folder $Name), $text, $Utf8Bom); Write-AuditLog "Wrote $Name" }
    catch { Add-Issue 'Output' $Name $_.Exception.Message 'ERROR' }
}

# =====================================================================================
#  External programs: read-only, timeout, hidden, stdin closed, cwd = output folder
# =====================================================================================
function Invoke-External {
    param([string]$FilePath, [string[]]$ArgList = @(), [int]$TimeoutSec = 30)
    $res = [pscustomobject]@{ ExitCode = $null; StdOut = ''; StdErr = ''; TimedOut = $false; Error = '' }
    $p = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.Arguments = ConvertTo-ArgString $ArgList
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.CreateNoWindow = $true
        $psi.WorkingDirectory = $script:SafeWorkDir
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()
        try { $p.StandardInput.Close() } catch { $null = $_ }   # best effort: child may already have exited
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            $res.TimedOut = $true
            try { $p.Kill() } catch { $res.Error = 'timed out and could not be stopped: ' + $_.Exception.Message }   # our own child process only
        }
        if ($outTask.Wait(5000)) { $res.StdOut = $outTask.Result }
        if ($errTask.Wait(5000)) { $res.StdErr = $errTask.Result }
        if (-not $res.TimedOut) { $res.ExitCode = $p.ExitCode }
    } catch { $res.Error = $_.Exception.Message }
    finally { if ($p) { $p.Dispose() } }
    return $res
}
function Get-AppPath {
    param([string]$Name)
    $c = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    return $null
}
$script:GitExe = Get-AppPath 'git.exe'
$script:GitDubious = @{}
function Invoke-GitRead {
    param([string]$Repo, [string[]]$GitArgs, [int]$TimeoutSec = 60)
    if (-not $script:GitExe) { return $null }
    $base = @('--no-optional-locks', '-c', 'core.fsmonitor=false', '-c', 'core.untrackedCache=false', '-c', 'gc.auto=0',
        '-c', 'maintenance.auto=false', '-c', 'filter.lfs.process=', '-c', 'filter.lfs.clean=', '-c', 'filter.lfs.smudge=',
        '-c', 'filter.lfs.required=false', '-c', 'core.pager=cat', '-C', $Repo)
    $r = Invoke-External $script:GitExe ($base + $GitArgs) $TimeoutSec
    if ($r.TimedOut) { Add-Issue 'Git' $Repo ('timeout: git ' + ($GitArgs -join ' ')); return $null }
    if ($r.Error) { Add-Issue 'Git' $Repo $r.Error; return $null }
    if ($r.ExitCode -ne 0) { if ($r.StdErr -match 'dubious ownership') { $script:GitDubious[$Repo] = $true }; return $null }
    return @($r.StdOut -split "`r?`n" | Where-Object { $_ -ne '' })
}

# =====================================================================================
#  File-system helpers (read-only)
# =====================================================================================
$RecallMask = 0x00400000 -bor 0x00040000 -bor 0x00001000   # RECALL_ON_DATA_ACCESS | RECALL_ON_OPEN | OFFLINE
function Test-CloudOnly { param($Attributes) return ((([int64]$Attributes) -band $RecallMask) -ne 0) }
function Get-SubDirs {
    param([string]$Path, [switch]$Quiet)
    try { return [IO.Directory]::GetDirectories($Path) }
    catch [System.IO.PathTooLongException] { $script:Counters.PathTooLong++; if (-not $Quiet) { Add-Issue 'PathTooLong' $Path 'path longer than Windows PowerShell can read' }; return @() }
    catch { if (-not $Quiet) { Add-Issue 'DirectoryWalk' $Path $_.Exception.GetType().Name }; return @() }
}
function Get-Files {
    param([string]$Path)
    try { return [IO.Directory]::GetFiles($Path) }
    catch [System.IO.PathTooLongException] { $script:Counters.PathTooLong++; Add-Issue 'PathTooLong' $Path 'path longer than Windows PowerShell can read'; return @() }
    catch { Add-Issue 'FileList' $Path $_.Exception.GetType().Name; return @() }
}
function Test-Reparse {
    param([string]$Path)
    try { return (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) } catch { return $true }
}
function Read-TextSafe {
    # File text, or $null when the file must not / cannot be read.
    param([IO.FileInfo]$Fi, [string]$Area)
    if (Test-CloudOnly $Fi.Attributes) { $script:Counters.CloudOnlySkipped++; return $null }
    if ($Fi.Length -gt ($MaxScanFileMB * 1MB)) { $script:Counters.ContentSkippedSize++; return $null }
    $fs = $null
    try {
        $fs = New-Object IO.FileStream($Fi.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $sr = New-Object IO.StreamReader($fs, $true)
        return $sr.ReadToEnd()
    } catch { Add-Issue $Area $Fi.FullName ('not readable: ' + $_.Exception.GetType().Name); return $null }
    finally { if ($fs) { $fs.Dispose() } }
}
function Read-JsonFile {
    param([string]$Path)
    $raw = [IO.File]::ReadAllText($Path)
    try { return ($raw | ConvertFrom-Json -ErrorAction Stop) } catch { $null = $_ }   # fall back to a more tolerant parser below
    if ($PSVersionTable.PSVersion.Major -ge 6) { $jp = @{ AsHashtable = $true }; return (ConvertFrom-Json -InputObject $raw -ErrorAction Stop @jp) }
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    $ser.RecursionLimit = 512
    return , $ser.DeserializeObject($raw)
}
function Get-JKeys {
    param($o)
    if ($null -eq $o -or $o -is [string] -or $o -is [ValueType]) { return @() }
    if ($o -is [System.Collections.IDictionary]) { return @($o.Keys) }
    return @($o.PSObject.Properties | ForEach-Object { $_.Name })
}
function Get-JVal {
    param($o, [string]$k)
    if ($null -eq $o -or $o -is [string] -or $o -is [ValueType]) { return $null }
    if ($o -is [System.Collections.IDictionary]) { if ($o.Contains($k)) { return $o[$k] } else { return $null } }
    $p = $o.PSObject.Properties[$k]
    if ($p) { return $p.Value }
    return $null
}
function Get-JsonStrings {
    param($Node, [int]$Depth, $Acc)
    if ($Acc.Count -gt 20000 -or $Depth -gt 40 -or $null -eq $Node) { return }
    if ($Node -is [string]) { $Acc.Add($Node); return }
    if ($Node -is [ValueType]) { return }
    if ($Node -is [System.Collections.IDictionary]) { foreach ($k in @($Node.Keys)) { $Acc.Add([string]$k); Get-JsonStrings $Node[$k] ($Depth + 1) $Acc }; return }
    if ($Node -is [System.Collections.IEnumerable]) { foreach ($x in $Node) { Get-JsonStrings $x ($Depth + 1) $Acc }; return }
    foreach ($p in $Node.PSObject.Properties) { $Acc.Add($p.Name); Get-JsonStrings $p.Value ($Depth + 1) $Acc }
}

try { Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop; $script:ZipOk = $true } catch { $script:ZipOk = $false }
function Get-ExcelInfo {
    # Reads only the zip directory and a few small XML parts; never opens Excel, never writes.
    param([IO.FileInfo]$Fi)
    $r = [pscustomobject]@{ HasMacros = ''; ExternalLinkCount = ''; ExternalLinkTargets = ''; DataConnections = ''; PowerQuery = ''; QueryTables = ''; Inspected = 'No'; Note = '' }
    $ext = $Fi.Extension.ToLowerInvariant()
    if ($ext -in @('.xlsm', '.xlsb', '.xltm', '.xlam')) { $r.HasMacros = 'macro-capable' }
    if ($ext -in @('.xls', '.xlt')) { $r.Note = 'legacy binary format - not inspected (may contain macros/links)'; $script:Counters.LegacyXls++; return $r }
    if ($ext -notin @('.xlsx', '.xlsm', '.xlsb', '.xltx', '.xltm', '.xlam')) { $r.Inspected = 'n/a'; return $r }
    if (Test-CloudOnly $Fi.Attributes) { $r.Note = 'cloud-only placeholder - not opened (opening would download it)'; $script:Counters.CloudOnlySkipped++; return $r }
    if ($Fi.Length -gt 300MB) { $r.Note = 'larger than 300 MB - not inspected'; return $r }
    if (-not $script:ZipOk) { $r.Note = 'zip support unavailable'; return $r }
    $fs = $null; $zip = $null
    try {
        $fs = New-Object IO.FileStream($Fi.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Read, $true)
        $names = @($zip.Entries | ForEach-Object { $_.FullName })
        if ($names -contains 'xl/vbaProject.bin') { $r.HasMacros = 'YES' } elseif ($r.HasMacros) { $r.HasMacros = 'no (macro-capable format)' } else { $r.HasMacros = 'no' }
        $r.ExternalLinkCount = @($names | Where-Object { $_ -match '^xl/externalLinks/externalLink\d+\.(xml|bin)$' }).Count
        $targets = New-Object System.Collections.Generic.List[string]
        foreach ($ln in @($names | Where-Object { $_ -match '^xl/externalLinks/_rels/.+\.rels$' })) {
            $sr = New-Object IO.StreamReader($zip.GetEntry($ln).Open()); $x = $sr.ReadToEnd(); $sr.Dispose()
            foreach ($m in [regex]::Matches($x, 'Target="([^"]+)"')) { $v = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value); if (-not $targets.Contains($v)) { $targets.Add($v) } }
        }
        $r.ExternalLinkTargets = (@($targets | Select-Object -First 5 | ForEach-Object { Format-Safe $_ }) -join ' ; ')
        $r.DataConnections = 0
        if ($names -contains 'xl/connections.xml') { $sr = New-Object IO.StreamReader($zip.GetEntry('xl/connections.xml').Open()); $x = $sr.ReadToEnd(); $sr.Dispose(); $r.DataConnections = [regex]::Matches($x, '<connection\s').Count }
        $r.QueryTables = @($names | Where-Object { $_ -match '^xl/queryTables/' }).Count
        $r.PowerQuery = 'no'
        foreach ($cx in @($names | Where-Object { $_ -match '^customXml/item\d+\.xml$' })) {
            $e = $zip.GetEntry($cx)
            if ($e.Length -lt 20MB) { $sr = New-Object IO.StreamReader($e.Open()); $x = $sr.ReadToEnd(); $sr.Dispose(); if ($x -match 'DataMashup') { $r.PowerQuery = 'YES'; break } }
        }
        $r.Inspected = 'Yes'
    } catch {
        $ex = $_.Exception
        while ($ex.InnerException) { $ex = $ex.InnerException }
        if ($ex -is [System.IO.InvalidDataException]) {
            # not a zip package: password-protected/encrypted workbook, damaged file, or old .xls renamed to .xlsx
            $r.Inspected = 'No'; $r.Note = 'not a standard workbook package (password-protected, damaged, or legacy format renamed)'
            $script:Counters.ExcelUnreadable++
        } else {
            $r.Note = 'could not inspect: ' + $ex.GetType().Name + ': ' + $ex.Message
            Add-Issue 'Excel' $Fi.FullName ('workbook not inspected: ' + $ex.GetType().Name + ': ' + $ex.Message)
        }
    } finally { if ($zip) { $zip.Dispose() }; if ($fs) { $fs.Dispose() } }
    return $r
}

# =====================================================================================
#  STEP 0 - system
# =====================================================================================
Start-Step '0 System'
$fail = $null
$isAdmin = $false
$script:Disks = @()
try {
    Write-AuditLog "Audit-OldLaptop.ps1 v$ScriptVersion. Output: $OutputRoot"
    try { Write-AuditLog ('Script SHA256: ' + (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash) } catch { Write-AuditLog ('Script hash not computed: ' + $_.Exception.Message) 'WARN' }
    foreach ($w in $script:EarlyWarnings) { Add-Issue 'Setup' '' $w }
    if (-not $script:ZipOk) { Add-Issue 'Excel' '' 'System.IO.Compression not available - Excel workbooks will not be inspected' }
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { Add-Coverage 'Privileges' 'Not running as Administrator: tasks/services registered by other accounts or SYSTEM, and command lines of elevated or other users'' processes, may be missing.' $true }
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $script:Disks = @(Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
            $type = "$($_.DriveType)"
            switch ($_.DriveType) { 2 { $type = 'Removable' } 3 { $type = 'Fixed' } 4 { $type = 'Network' } 5 { $type = 'CD/DVD' } }
            [pscustomobject]@{ Drive = $_.DeviceID; Type = $type; Label = $_.VolumeName; FileSystem = $_.FileSystem; SizeGB = [math]::Round($_.Size / 1GB, 1); FreeGB = [math]::Round($_.FreeSpace / 1GB, 1); NetworkPath = $_.ProviderName }
        })
    $explorerOwner = ''
    try {
        $ex = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | Select-Object -First 1
        if ($ex) { $explorerOwner = (Invoke-CimMethod -InputObject $ex -MethodName GetOwner -ErrorAction Stop).User }
    } catch { Write-AuditLog ('Could not determine the logged-on desktop user: ' + $_.Exception.Message) 'WARN' }
    if ($explorerOwner -and $explorerOwner -ne $env:USERNAME) { Add-Coverage 'Account' 'The script runs as a different account than the logged-on desktop user; only the running account''s profile is scanned.' $true }
    $otherProfiles = @(Get-ChildItem -LiteralPath (Join-Path ($env:SystemDrive + '\') 'Users') -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '^(Public|Default|Default User|All Users|defaultuser\d*|WDAGUtilityAccount)$' -and $_.FullName -ne $env:USERPROFILE -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
    if ($otherProfiles.Count -gt 0) { Add-Coverage 'Profiles' ('{0} other user profile folder(s) exist and are NOT scanned.' -f $otherProfiles.Count) $true }
    foreach ($nd in @($script:Disks | Where-Object { $_.Type -eq 'Network' })) { Add-Coverage 'Network drives' ('Mapped network drive {0} is not scanned.' -f $nd.Drive) $true }
    $system = [pscustomobject]@{
        AuditTime = $StartTime.ToString('s'); ScriptVersion = $ScriptVersion; ComputerName = $env:COMPUTERNAME
        RunningAsAdmin = $isAdmin; RunningAccountIsDesktopUser = (-not $explorerOwner -or $explorerOwner -eq $env:USERNAME)
        OS = $(if ($os) { "$($os.Caption) $($os.Version) build $($os.BuildNumber)" } else { '' }); OSArchitecture = $(if ($os) { $os.OSArchitecture } else { '' })
        Manufacturer = $(if ($cs) { $cs.Manufacturer } else { '' }); Model = $(if ($cs) { $cs.Model } else { '' })
        RAM_GB = $(if ($cs) { [math]::Round($cs.TotalPhysicalMemory / 1GB, 1) } else { '' }); CPU = $(if ($cpu) { $cpu.Name } else { '' })
        PartOfDomain = $(if ($cs) { $cs.PartOfDomain } else { '' }); PowerShell = $PSVersionTable.PSVersion.ToString()
        TimeZone = (Get-TimeZone -ErrorAction SilentlyContinue).Id; Culture = (Get-Culture).Name
        DesktopFolder = [Environment]::GetFolderPath('Desktop'); DocumentsFolder = [Environment]::GetFolderPath('MyDocuments')
        CloudSyncedRoots = $SyncRoots; Disks = $script:Disks; OtherUserProfilesNotScanned = $otherProfiles.Count
    }
    Save-Json $system '00_system_info.json'
    Save-Json ([pscustomobject]@{ UserName = $env:USERNAME; UserProfile = $env:USERPROFILE; ComputerName = $env:COMPUTERNAME; Domain = $(if ($cs) { $cs.Domain } else { '' }); LoggedOnDesktopUser = $explorerOwner; Note = 'SHAREABLE files show %USERPROFILE% and <USER> instead of these values.' }) 'identity_map.json' -PrivateFile
    # restrict PRIVATE folder (our own new folder only) to the current user + SYSTEM
    try {
        $acl = Get-Acl -LiteralPath $Private
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
        foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User, (New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'))) {
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        }
        Set-Acl -LiteralPath $Private -AclObject $acl -ErrorAction Stop
        Write-AuditLog 'PRIVATE_DO_NOT_UPLOAD restricted to the current user and SYSTEM'
    } catch { Add-Issue 'Output' $Private ('could not restrict folder permissions: ' + $_.Exception.Message) }
    if ($SyncRoots.Count -gt 0) { Write-AuditLog ('Cloud-synced folders detected: ' + ($SyncRoots -join '; ')) }
} catch { $fail = $_ }
Complete-Step $fail

$home_ = $env:USERPROFILE
$OutputRootFull = $OutputRoot.TrimEnd('\')
$ScriptDirFull = ''
if ($PSScriptRoot) { $ScriptDirFull = $PSScriptRoot.TrimEnd('\') }
$BroadFolders = @($home_, [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'), (Join-Path $home_ 'Downloads')) + $SyncRoots
function Test-SkipDir { param([string]$Path) return ($OutputRootFull -and ($Path.TrimEnd('\') -ieq $OutputRootFull)) }

# =====================================================================================
#  STEP 1 - Claude Desktop / Claude Code
# =====================================================================================
Start-Step '1 Claude environment'
$fail = $null
$script:ClaudeRows = New-Object System.Collections.Generic.List[object]
$script:ClaudeProjectPaths = @{}   # working folders of Claude Code (scanned as projects)
$script:ClaudeLinkedFolders = @{}  # folders referenced by Claude configuration (reported)
function Add-ClaudeItem {
    param($Area, $Item, $Path, $Detail, $Transfer)
    $script:ClaudeRows.Add([pscustomobject]@{ Area = $Area; Item = (Format-Safe "$Item"); Path = (Format-Safe "$Path"); Detail = (Format-Safe "$Detail"); HowToTransfer = $Transfer })
}
function Add-ClaudePath {
    param([string]$Path, [string]$Source, [bool]$AsProject)
    if (-not $Path) { return }
    $p = ($Path.Trim() -replace '/', '\').TrimEnd('\')
    if ($p -notmatch '^[A-Za-z]:\\.') { return }
    if ($p -match '(?i)\\(AppData|Program Files|Program Files \(x86\)|Windows|ProgramData)(\\|$)') { return }
    try { if (-not [IO.Directory]::Exists($p)) { return } } catch { return }
    if (-not $script:ClaudeLinkedFolders.ContainsKey($p)) { $script:ClaudeLinkedFolders[$p] = $Source }
    $broad = $false
    foreach ($b in $BroadFolders) { if ($b -and $p -ieq $b.TrimEnd('\')) { $broad = $true } }
    if ($AsProject -and -not $broad -and $p.Length -gt 3 -and -not $script:ClaudeProjectPaths.ContainsKey($p)) { $script:ClaudeProjectPaths[$p] = $Source }
}
function Resolve-ClaudeEncodedPath {
    # ~\.claude\projects\<encoded>: every non-alphanumeric character became "-". Resolve by walking the disk.
    param([string]$Encoded)
    if ($Encoded -notmatch '^([A-Za-z])--(.+)$') { return $null }
    $cur = $Matches[1] + ':\'
    $rest = $Matches[2]
    for ($guard = 0; $guard -lt 40 -and $rest; $guard++) {
        $best = $null; $bestEnc = ''
        foreach ($sd in (Get-SubDirs $cur -Quiet)) {
            $enc = ((Split-Path $sd -Leaf) -replace '[^A-Za-z0-9]', '-')
            if (($rest -ieq $enc) -or $rest.StartsWith($enc + '-', [StringComparison]::OrdinalIgnoreCase)) { if ($enc.Length -gt $bestEnc.Length) { $best = $sd; $bestEnc = $enc } }
        }
        if (-not $best) { return $null }
        $cur = $best
        $rest = $rest.Substring([Math]::Min($rest.Length, $bestEnc.Length + 1))
    }
    return $cur
}
function Get-McpSummary {
    param($Server)
    $parts = @()
    foreach ($k in @('type', 'command', 'url')) { $v = Get-JVal $Server $k; if ($v) { $parts += "$k=$v" } }
    $a = Get-JVal $Server 'args'; if ($a) { $parts += ('args=' + (@($a) -join ' ')) }
    $e = Get-JVal $Server 'env'; if ($e) { $parts += ('envNames=[' + ((Get-JKeys $e) -join ', ') + ']') }
    $h = Get-JVal $Server 'headers'; if ($h) { $parts += ('headerNames=[' + ((Get-JKeys $h) -join ', ') + ']') }
    return ($parts -join ' ')
}
try {
    $locations = @(
        @{ P = (Join-Path $env:APPDATA 'Claude'); A = 'Claude Desktop data (Roaming\Claude)' },
        @{ P = (Join-Path $env:LOCALAPPDATA 'AnthropicClaude'); A = 'Claude Desktop install (Local\AnthropicClaude)' },
        @{ P = (Join-Path $env:LOCALAPPDATA 'Programs\Claude'); A = 'Claude Desktop install (Local\Programs\Claude)' },
        @{ P = (Join-Path $env:LOCALAPPDATA 'Claude'); A = 'Claude (Local\Claude)' },
        @{ P = (Join-Path $home_ '.claude'); A = 'Claude Code user folder (~\.claude)' },
        @{ P = (Join-Path $home_ '.claude.json'); A = 'Claude Code state file (~\.claude.json)' },
        @{ P = (Join-Path $home_ '.local\bin\claude.exe'); A = 'Claude Code native binary' },
        @{ P = (Join-Path $env:ProgramData 'ClaudeCode'); A = 'Claude Code managed settings (ProgramData)' },
        @{ P = (Join-Path $env:ProgramFiles 'ClaudeCode'); A = 'Claude Code managed settings (Program Files)' }
    )
    foreach ($loc in $locations) {
        if (Test-Path -LiteralPath $loc.P) {
            $it = Get-Item -LiteralPath $loc.P -Force
            if ($it.PSIsContainer) { $d = 'folder; top-level: ' + ((Get-ChildItem -LiteralPath $loc.P -Force -ErrorAction SilentlyContinue | Select-Object -First 40 | ForEach-Object { $_.Name }) -join ', ') }
            else { $d = "file; $([math]::Round($it.Length/1KB,1)) KB; modified $($it.LastWriteTime.ToString('s'))"; if ($it.VersionInfo -and $it.VersionInfo.ProductVersion) { $d += "; version $($it.VersionInfo.ProductVersion)" } }
            Add-ClaudeItem $loc.A 'location' $loc.P $d 'see detail rows'
        } else { Add-ClaudeItem $loc.A 'location' $loc.P 'not present' '' }
    }
    $ac = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
    if (Test-Path -LiteralPath $ac) { Get-ChildItem -LiteralPath $ac -Directory -Filter 'app-*' -ErrorAction SilentlyContinue | ForEach-Object { Add-ClaudeItem 'Claude Desktop version' $_.Name $_.FullName 'installed app folder' 'Install the latest Claude Desktop on the new laptop and sign in' } }
    Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue | ForEach-Object { Add-ClaudeItem 'Claude Desktop (MSIX/Store)' $_.Name $_.InstallLocation "version $($_.Version)" 'Re-install on the new laptop and sign in' }

    $roam = Join-Path $env:APPDATA 'Claude'
    $deskCfg = Join-Path $roam 'claude_desktop_config.json'
    if (Test-Path -LiteralPath $deskCfg) {
        try {
            $cfg = Read-JsonFile $deskCfg
            $mcp = Get-JVal $cfg 'mcpServers'
            foreach ($name in (Get-JKeys $mcp)) { Add-ClaudeItem 'Claude Desktop MCP server' $name $deskCfg (Get-McpSummary (Get-JVal $mcp $name)) 'Re-create on the new laptop; install its runtime (node/python/uvx) first; re-enter secrets from the password manager' }
            Add-ClaudeItem 'Claude Desktop config' 'top-level keys' $deskCfg ((Get-JKeys $cfg) -join ', ') 'Re-create via Settings; never copy secrets in plain text'
            $acc = New-Object System.Collections.Generic.List[string]; Get-JsonStrings $cfg 0 $acc
            foreach ($s in $acc) { Add-ClaudePath $s 'claude_desktop_config.json' $false }
        } catch { Add-Issue 'Claude' $deskCfg ('unreadable JSON: ' + $_.Exception.Message) }
    }
    if (Test-Path -LiteralPath $roam) {
        $skipDirs = '^(Cache|Code Cache|GPUCache|DawnCache|DawnGraphiteCache|DawnWebGPUCache|blob_storage|IndexedDB|Local Storage|Session Storage|Service Worker|Crashpad|Network|Partitions|shared_proto_db|WebStorage|logs|sentry|VideoDecodeStats|Dictionaries|component_crx_cache|extensions_crx_cache)$'
        $jsonFiles = @(Get-ChildItem -LiteralPath $roam -File -Filter '*.json' -Force -ErrorAction SilentlyContinue)
        foreach ($sub in @(Get-ChildItem -LiteralPath $roam -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch $skipDirs })) {
            if ($sub.Name -match '(?i)schedul|task|routine|cron|trigger|cowork|agent|automation') { Add-ClaudeItem 'Claude local automation candidate' $sub.Name $sub.FullName "folder; modified $($sub.LastWriteTime.ToString('s'))" 'Tasks stored by the desktop app run where the app runs: list them in the app; re-create PAUSED on the new laptop' }
            $jsonFiles += @(Get-ChildItem -LiteralPath $sub.FullName -File -Filter '*.json' -Recurse -Depth 2 -Force -ErrorAction SilentlyContinue)
        }
        if ($jsonFiles.Count -gt 300) { Add-Coverage 'Claude' ('{0} JSON files in Claude Desktop data; only the first 300 were inspected.' -f $jsonFiles.Count) $true }
        foreach ($jf in ($jsonFiles | Select-Object -First 300)) {
            if ($jf.FullName -ieq $deskCfg) { continue }
            $keys = ''
            $cand = ($jf.Name -match '(?i)schedul|task|routine|cron|trigger|cowork|agent|automation')
            if ($jf.Length -le 5MB -and -not (Test-CloudOnly $jf.Attributes)) {
                try {
                    $j = Read-JsonFile $jf.FullName
                    $keys = ((Get-JKeys $j) | Select-Object -First 40) -join ', '
                    if ($keys -match '(?i)schedul|cron|trigger|routine') { $cand = $true }
                    $acc = New-Object System.Collections.Generic.List[string]; Get-JsonStrings $j 0 $acc
                    foreach ($s in $acc) { Add-ClaudePath $s ('Claude Desktop: ' + $jf.Name) $false }
                } catch { $keys = '(not JSON-parsable)' }
            } else { $keys = '(not parsed: larger than 5 MB or online-only)' }
            $area = 'Claude Desktop data file'
            if ($cand) { $area = 'Claude local automation candidate' }
            Add-ClaudeItem $area $jf.Name $jf.FullName ('{0} KB; modified {1}; keys: {2}' -f [math]::Round($jf.Length / 1KB, 1), $jf.LastWriteTime.ToString('s'), $keys) 'Values NOT recorded. Review in the app before migrating.'
        }
        foreach ($extDir in @((Join-Path $roam 'Claude Extensions'), (Join-Path $roam 'extensions'))) {
            if (Test-Path -LiteralPath $extDir) { Get-ChildItem -LiteralPath $extDir -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { Add-ClaudeItem 'Claude Desktop extension' $_.Name $_.FullName "modified $($_.LastWriteTime.ToString('s'))" 'Re-install from Settings > Extensions; re-enter its settings' } }
        }
    }
    $cc = Join-Path $home_ '.claude'
    if (Test-Path -LiteralPath $cc) {
        foreach ($f in @('settings.json', 'settings.local.json', 'CLAUDE.md', 'keybindings.json')) {
            $fp = Join-Path $cc $f
            if (-not (Test-Path -LiteralPath $fp)) { continue }
            $d = "$([math]::Round((Get-Item -LiteralPath $fp -Force).Length/1KB,1)) KB"
            if ($f -like 'settings*.json') {
                try {
                    $sj = Read-JsonFile $fp
                    $d += '; keys: ' + ((Get-JKeys $sj) -join ', ')
                    $envs = Get-JVal $sj 'env'; if ($envs) { $d += '; envNames: ' + ((Get-JKeys $envs) -join ', ') }
                    $hooks = Get-JVal $sj 'hooks'
                    foreach ($ev in (Get-JKeys $hooks)) {
                        $acc = New-Object System.Collections.Generic.List[string]; Get-JsonStrings (Get-JVal $hooks $ev) 0 $acc
                        $cmds = @($acc | Where-Object { $_ -match '\s|\\|/' } | Select-Object -First 5)
                        Add-ClaudeItem 'Claude Code hook' $ev $fp ('commands: ' + ($cmds -join ' ;; ')) 'Copy settings; fix absolute paths in hook commands for the new laptop'
                    }
                } catch { Add-Issue 'Claude' $fp ('unreadable JSON: ' + $_.Exception.Message) }
            }
            Add-ClaudeItem 'Claude Code user file' $f $fp $d 'Copy as file after review (secrets in env -> re-enter)'
        }
        foreach ($sub in @('skills', 'agents', 'commands', 'plugins', 'hooks', 'output-styles', 'workflows', 'rules')) {
            $sp = Join-Path $cc $sub
            if (-not (Test-Path -LiteralPath $sp)) { continue }
            foreach ($it in @(Get-ChildItem -LiteralPath $sp -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('cache', 'repos', 'marketplaces') } | Select-Object -First 300)) {
                $how = 'Copy folder as-is'
                if ($sub -eq 'plugins') { $how = 'Re-install via /plugin from the same marketplace; do not copy cache' }
                Add-ClaudeItem "Claude Code $sub" $it.Name $it.FullName "modified $($it.LastWriteTime.ToString('s'))" $how
            }
        }
        foreach ($pj in @('plugins\installed_plugins.json', 'plugins\known_marketplaces.json')) {
            $fp = Join-Path $cc $pj
            if (Test-Path -LiteralPath $fp) {
                try {
                    $j = Read-JsonFile $fp; $names = @(Get-JKeys $j); $inner = Get-JVal $j 'plugins'; if ($inner) { $names = @(Get-JKeys $inner) }
                    Add-ClaudeItem 'Claude Code plugin registry' $pj $fp ('entries: ' + ($names -join ', ')) 'Re-add marketplaces and re-install plugins'
                } catch { Add-Issue 'Claude' $fp ('unreadable JSON: ' + $_.Exception.Message) }
            }
        }
        foreach ($sensitive in @('.credentials.json', 'history.jsonl', 'shell-snapshots', 'todos', 'statsig', 'ide', 'session-env')) {
            $fp = Join-Path $cc $sensitive
            if (Test-Path -LiteralPath $fp) { Add-ClaudeItem 'Claude Code sensitive/local-only' $sensitive $fp 'present - NOT read (may contain tokens, environment values or chat content)' 'Do NOT copy credentials; sign in again. History is optional and private.' }
        }
        $projDir = Join-Path $cc 'projects'
        if (Test-Path -LiteralPath $projDir) {
            $tdirs = @(Get-ChildItem -LiteralPath $projDir -Directory -Force -ErrorAction SilentlyContinue)
            Add-ClaudeItem 'Claude Code session history' 'projects\' $projDir ('{0} project transcript folders (content NOT read)' -f $tdirs.Count) 'Optional private copy; resuming old sessions on new paths is not guaranteed'
            foreach ($td in $tdirs) {
                $resolved = Resolve-ClaudeEncodedPath $td.Name
                if ($resolved) { Add-ClaudePath $resolved 'Claude Code transcript folder' $true }
                else { Add-ClaudeItem 'Claude Code transcript (folder not found)' $td.Name $td.FullName "modified $($td.LastWriteTime.ToString('s'))" 'Project folder no longer exists at that path, or could not be matched - check manually' }
            }
        }
    }
    $ccj = Join-Path $home_ '.claude.json'
    if (Test-Path -LiteralPath $ccj) {
        try {
            $j = Read-JsonFile $ccj
            $mcp = Get-JVal $j 'mcpServers'
            foreach ($name in (Get-JKeys $mcp)) { Add-ClaudeItem 'Claude Code MCP server (user scope)' $name $ccj (Get-McpSummary (Get-JVal $mcp $name)) 'Re-add with "claude mcp add" on the new laptop; re-enter secrets' }
            $projects = Get-JVal $j 'projects'
            foreach ($pp in (Get-JKeys $projects)) {
                $pm = Get-JVal (Get-JVal $projects $pp) 'mcpServers'
                Add-ClaudeItem 'Claude Code known project' $pp $ccj ('project-scoped MCP: [' + ((Get-JKeys $pm) -join ', ') + ']') 'Path must exist on the new laptop; re-add project MCP servers'
                Add-ClaudePath $pp '~\.claude.json' $true
            }
            Add-ClaudeItem 'Claude Code login' 'account' $ccj 'Sign-in tokens are not transferable' 'Run claude and sign in again on the new laptop'
        } catch { Add-Issue 'Claude' $ccj ('unreadable JSON: ' + $_.Exception.Message) }
    }
    foreach ($ms in @((Join-Path $env:ProgramData 'ClaudeCode\managed-settings.json'), (Join-Path $env:ProgramFiles 'ClaudeCode\managed-settings.json'))) {
        if (Test-Path -LiteralPath $ms) { try { Add-ClaudeItem 'Claude Code managed settings' (Split-Path $ms -Leaf) $ms ('keys: ' + ((Get-JKeys (Read-JsonFile $ms)) -join ', ')) 'Organisation policy - re-apply on the new laptop' } catch { Add-Issue 'Claude' $ms $_.Exception.Message } }
    }
    $vdir = Join-Path $home_ '.local\share\claude\versions'
    if (Test-Path -LiteralPath $vdir) { Add-ClaudeItem 'Claude Code native versions' 'versions' $vdir ((Get-ChildItem -LiteralPath $vdir -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ', ') 'Install Claude Code on the new laptop' }
    foreach ($kp in $script:ClaudeLinkedFolders.Keys) {
        $asProj = 'reported only'
        if ($script:ClaudeProjectPaths.ContainsKey($kp)) { $asProj = 'scanned as project' }
        Add-ClaudeItem 'Claude-linked folder' $kp $script:ClaudeLinkedFolders[$kp] $asProj 'Migrate together with its project'
    }
    Save-Csv $script:ClaudeRows 'claude_environment.csv'
} catch { $fail = $_ }
Complete-Step $fail

# =====================================================================================
#  STEP 2 - projects
# =====================================================================================
Start-Step '2 Projects'
$fail = $null
$script:Roots = New-Object System.Collections.Generic.List[string]
$script:Projects = New-Object System.Collections.Generic.List[object]
$script:ProjectSet = @{}
$script:ProjRows = New-Object System.Collections.Generic.List[object]
$script:HardPaths = New-Object System.Collections.Generic.List[object]
$script:HostRefs = New-Object System.Collections.Generic.List[object]
$script:SecretFiles = New-Object System.Collections.Generic.List[object]
$script:SecretHashes = New-Object System.Collections.Generic.List[object]
$script:DataFiles = New-Object System.Collections.Generic.List[object]
$script:EnvNames = New-Object System.Collections.Generic.List[object]
$script:DepthExamples = New-Object System.Collections.Generic.List[string]
$ExcludeDirNames = @('node_modules', '.git', '.hg', '.svn', '.next', '.nuxt', '.svelte-kit', '.venv', 'venv', '__pycache__', '.pytest_cache',
    '.mypy_cache', '.ruff_cache', '.tox', '.gradle', '.idea', '.vs', '.cache', '.turbo', '.parcel-cache', '.terraform', 'site-packages',
    '$RECYCLE.BIN', 'System Volume Information', 'AppData', 'Windows', 'Program Files', 'Program Files (x86)', 'ProgramData',
    'WindowsApps', 'WinSxS', 'Recovery', 'PerfLogs', 'MSOCache', 'Config.Msi')
$HeavyDirNames = @('node_modules', '.next', '.nuxt', '.svelte-kit', '.venv', 'venv', 'env', 'dist', 'build', 'out', '__pycache__', '.cache',
    'coverage', 'target', 'bin', 'obj', '.turbo', '.parcel-cache', '.gradle', '.terraform', 'vendor')
$MarkerFiles = @('package.json', 'requirements.txt', 'pyproject.toml', 'Pipfile', 'setup.py', 'environment.yml', 'appsscript.json', '.clasp.json',
    'Dockerfile', 'docker-compose.yml', 'docker-compose.yaml', 'compose.yaml', 'railway.json', 'railway.toml', 'vercel.json', 'netlify.toml', 'Procfile',
    'CLAUDE.md', 'CLAUDE.local.md', 'AGENTS.md', '.mcp.json', 'go.mod', 'Cargo.toml', 'composer.json', 'pom.xml', 'build.gradle',
    'ecosystem.config.js', 'ecosystem.config.cjs', 'supabase', 'manage.py', 'deno.json', 'bun.lockb', '.cursorrules')
$SecretFilePattern = '(?i)^(\.env(\..*)?|.*\.env|\.envrc|.*\.pem|.*\.key|.*\.pfx|.*\.p12|.*\.p8|.*\.ppk|.*\.jks|.*\.keystore|.*\.ovpn|.*\.rdp|id_rsa.*|id_ecdsa.*|id_ed25519.*|credentials(\..*)?|client_secret.*\.json|service[-_]?account.*\.json|.*-sa\.json|token(s)?\.json|\.clasprc\.json|\.npmrc|\.pypirc|\.netrc|_netrc|\.pgpass|\.git-credentials|.*\.kdbx|secrets?\..*|appsettings\..*\.json|wp-config\.php)$'
$NotSecretPattern = '(?i)(\.example|\.sample|\.template|\.dist|\.defaults)$|^\.env\.(example|sample|template)'
$DataFilePattern = '(?i)\.(xlsx|xlsm|xlsb|xls|csv|tsv|db|sqlite|sqlite3|mdb|accdb|qbw|qbb|msg|eml|pst|pdf|docx|parquet|json)$'
$SourceExt = @('.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.py', '.gs', '.ps1', '.psm1', '.bat', '.cmd', '.vbs', '.json', '.yml', '.yaml', '.toml', '.ini', '.cfg', '.conf', '.html', '.htm', '.sql', '.sh', '.md', '.txt', '.xml')

function Find-Projects {
    param([string]$Dir, [int]$Depth)
    if ($Depth -gt $MaxDepth) { return }
    if (Test-SkipDir $Dir) { return }
    $name = Split-Path $Dir -Leaf
    if ($Depth -gt 0 -and ($ExcludeDirNames -contains $name)) { return }
    if ($Depth -gt 0 -and (Test-Reparse $Dir)) { return }
    $subs = @(Get-SubDirs $Dir)
    $files = @(Get-Files $Dir | ForEach-Object { [IO.Path]::GetFileName($_) })
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($x in $files) { [void]$set.Add($x) }
    $dirSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($x in $subs) { [void]$dirSet.Add([IO.Path]::GetFileName($x)) }
    $markers = New-Object System.Collections.Generic.List[string]
    if ($set.Contains('.git') -or $dirSet.Contains('.git')) { $markers.Add('.git') }
    if ($dirSet.Contains('.claude')) { $markers.Add('.claude/') }
    foreach ($m in $MarkerFiles) { if ($set.Contains($m) -or $dirSet.Contains($m)) { $markers.Add($m) } }
    $broad = ($name -match '(?i)^(Downloads|Desktop|Documents|My Documents|Pictures|Videos|Music)$') -or ($Dir.TrimEnd('\').Length -le 2)
    foreach ($b in $BroadFolders) { if ($b -and $Dir.TrimEnd('\') -ieq $b.TrimEnd('\')) { $broad = $true } }
    if ($markers.Count -eq 0 -and -not $broad -and $name -notmatch '_files$') {
        if (@($files | Where-Object { $_ -match '(?i)\.gs$' }).Count -gt 0) { $markers.Add('*.gs') }
        if (@($files | Where-Object { $_ -match '(?i)\.(sln|csproj)$' }).Count -gt 0) { $markers.Add('*.sln/csproj') }
        if ($set.Contains('index.html') -and @($files | Where-Object { $_ -match '(?i)\.(js|css|gs)$' -or $_ -ieq 'manifest.json' }).Count -gt 0) { $markers.Add('static-web(index.html)') }
        if (@($files | Where-Object { $_ -match '(?i)\.(py|ps1)$' }).Count -ge 3) { $markers.Add('script-folder(3+ py/ps1)') }
    }
    if ($script:ClaudeProjectPaths.ContainsKey($Dir)) { $markers.Add('claude-known') }
    if ($markers.Count -gt 0 -and -not $script:ProjectSet.ContainsKey($Dir)) {
        $script:ProjectSet[$Dir] = $true
        $script:Projects.Add([pscustomobject]@{ Path = $Dir; Markers = ($markers -join ',') })
        if ($markers.Contains('.git')) {
            foreach ($sub in $subs) { if (([IO.Path]::GetFileName($sub)) -ne '.git') { Find-Projects $sub ($Depth + 3) } }
            return
        }
    }
    if ($Depth -eq $MaxDepth -and $subs.Count -gt 0) {
        $script:Counters.DepthLimited++
        if ($script:DepthExamples.Count -lt 50) { $script:DepthExamples.Add($Dir) }
        return
    }
    foreach ($sub in $subs) { Find-Projects $sub ($Depth + 1) }
}

function Get-TreeStats {
    param([string]$Root)
    $stats = @{ Files = 0; Bytes = [int64]0; Newest = [datetime]::MinValue; Heavy = New-Object System.Collections.Generic.List[string]; Ext = @{}; CloudOnly = 0; NotScanned = 0 }
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        foreach ($f in (Get-Files $d)) {
            try {
                $fi = New-Object IO.FileInfo($f)
                $stats.Files++; $stats.Bytes += $fi.Length
                if ($fi.LastWriteTime -gt $stats.Newest) { $stats.Newest = $fi.LastWriteTime }
                $ext = $fi.Extension.ToLowerInvariant(); if ($ext) { $stats.Ext[$ext] = 1 + [int]$stats.Ext[$ext] }
                $cloudOnly = Test-CloudOnly $fi.Attributes
                if ($cloudOnly) { $stats.CloudOnly++ }
                $rel = $f.Substring($Root.Length).TrimStart('\', '/')
                if ($fi.Name -match $SecretFilePattern -and $fi.Name -notmatch $NotSecretPattern) {
                    $script:SecretFiles.Add([pscustomobject]@{ Project = $Root; RelativePath = $rel; SizeBytes = $fi.Length; LastWrite = $fi.LastWriteTime.ToString('s'); CloudOnly = $cloudOnly; Note = 'content NOT copied; for .env files only variable names recorded' })
                    if (-not $cloudOnly) {
                        try { $script:SecretHashes.Add([pscustomobject]@{ Path = $f; SHA256 = (Get-FileHash -LiteralPath $f -Algorithm SHA256 -ErrorAction Stop).Hash }) } catch { Add-Issue 'SecretHash' $f $_.Exception.GetType().Name }
                        if ($fi.Name -match '(?i)^\.env|\.env$') {
                            $txt = Read-TextSafe $fi 'EnvNames'
                            if ($null -ne $txt) {
                                foreach ($line in ($txt -split "`r?`n")) {
                                    if ($line -match '^\s*(export\s+)?([A-Za-z_][A-Za-z0-9_.-]*)\s*=') { $script:EnvNames.Add([pscustomobject]@{ Project = $Root; File = $rel; VariableName = $Matches[2]; LooksSecret = (Test-SecretName $Matches[2]); Value = '<not recorded>' }) }
                                }
                            }
                        }
                    }
                    continue
                }
                if ($fi.Name -match $DataFilePattern -and -not $fi.Name.StartsWith('~$') -and $fi.Name -notmatch '(?i)^(package(-lock)?|tsconfig.*|jsconfig|composer|appsscript|\.clasp|components|vercel|railway|manifest|settings|launch|tasks|extensions)\.json$' -and ($ext -ne '.json' -or $fi.Length -gt 200KB)) {
                    $x = $null
                    if ($ext -match '^\.(xlsx|xlsm|xlsb|xls)$') { $x = Get-ExcelInfo $fi }
                    $script:DataFiles.Add([pscustomobject]@{ Project = $Root; RelativePath = $rel; SizeKB = [math]::Round($fi.Length / 1KB, 1); LastWrite = $fi.LastWriteTime.ToString('s'); CloudOnly = $cloudOnly
                            HasMacros = $(if ($x) { $x.HasMacros } else { '' }); ExternalLinks = $(if ($x) { $x.ExternalLinkTargets } else { '' }); DataConnections = $(if ($x) { $x.DataConnections } else { '' }); PowerQuery = $(if ($x) { $x.PowerQuery } else { '' }) })
                }
                if (($SourceExt -contains $ext -or $fi.Name -like '*.env.example') -and $fi.Name -notmatch '(?i)(-lock\.|\.lock$|\.min\.|lockfile)') {
                    $txt = Read-TextSafe $fi 'ContentScan'
                    if ($null -eq $txt) { $stats.NotScanned++; continue }
                    $lineNo = 0
                    foreach ($line in ($txt -split "`n")) {
                        $lineNo++
                        if ($line.Length -gt 4000) { continue }
                        if ($line.IndexOf(':\') -ge 0 -or $line.IndexOf(':/') -ge 0 -or $line.IndexOf('\\') -ge 0) {
                            foreach ($p in (Get-PathRefs $line)) { $script:HardPaths.Add([pscustomobject]@{ Project = $Root; File = $rel; Line = $lineNo; Path = (Format-Safe $p) }) }
                        }
                        if ($line -match '(?i)http|localhost|127\.0\.0\.1|smtp\.|vessel-profit') {
                            foreach ($m in [regex]::Matches($line, $HostPattern)) { $script:HostRefs.Add([pscustomobject]@{ Project = $Root; File = $rel; Line = $lineNo; Reference = (Format-Safe $m.Value) }) }
                        }
                    }
                }
            } catch { Add-Issue 'ProjectFile' $f $_.Exception.Message }
        }
        foreach ($sd in (Get-SubDirs $d)) {
            $leaf = Split-Path $sd -Leaf
            if ($leaf -eq '.git') { continue }
            if ($HeavyDirNames -contains $leaf) { $stats.Heavy.Add($sd.Substring($Root.Length).TrimStart('\', '/')); continue }
            if (Test-Reparse $sd) { continue }
            if (Test-SkipDir $sd) { continue }
            if ($script:ProjectSet.ContainsKey($sd)) { continue }
            $stack.Push($sd)
        }
    }
    return $stats
}

try {
    $candidateRoots = @(
        [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'), (Join-Path $home_ 'Downloads'),
        $env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer,
        'C:\x', 'C:\Projects', 'C:\dev', 'C:\code', 'C:\src', 'C:\repos', 'C:\work', 'C:\Scripts', 'C:\Tools', 'C:\automation',
        (Join-Path ($env:SystemDrive + '\') 'Users\Public\Documents')
    )
    Get-ChildItem -LiteralPath $home_ -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '^(AppData|\..*|NTUSER.*|Application Data|Local Settings|Cookies|NetHood|PrintHood|Recent|SendTo|Start Menu|Templates|My Documents|scoop|MicrosoftEdgeBackups|IntelGraphicsProfiles)$' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        ForEach-Object { $candidateRoots += $_.FullName }
    Get-ChildItem -LiteralPath ($env:SystemDrive + '\') -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '^(Windows|Program Files|Program Files \(x86\)|ProgramData|Users|\$.*|System Volume Information|Recovery|PerfLogs|Documents and Settings|MSOCache|Intel|AMD|NVIDIA|OneDriveTemp|inetpub|Config\.Msi|Drivers|ESD|swsetup|XboxGames)$' } |
        ForEach-Object { $candidateRoots += $_.FullName }
    foreach ($d in $script:Disks) { if ($d.Drive -ne $env:SystemDrive -and $d.Type -in @('Fixed', 'Removable')) { $candidateRoots += ($d.Drive + '\') } }
    $candidateRoots += $ExtraRoots
    foreach ($r in $candidateRoots) {
        if (-not $r) { continue }
        if (-not (Test-Path -LiteralPath $r -PathType Container)) { if ($ExtraRoots -contains $r) { Add-Issue 'Roots' $r 'extra root not found' }; continue }
        $full = (Resolve-Path -LiteralPath $r).ProviderPath.TrimEnd('\')
        if ($full.Length -eq 2) { $full += '\' }
        if (Test-SkipDir $full) { continue }
        $covered = $false
        foreach ($x in $script:Roots) { if ($full -ieq $x -or (Test-UnderPath $full $x)) { $covered = $true; break } }
        if (-not $covered) {
            for ($i = $script:Roots.Count - 1; $i -ge 0; $i--) { if (Test-UnderPath $script:Roots[$i] $full) { $script:Roots.RemoveAt($i) } }
            $script:Roots.Add($full)
        }
    }
    Write-AuditLog ('Search roots: ' + ($script:Roots -join '; '))
    foreach ($r in $script:Roots) { Write-AuditLog "  scanning $r"; Find-Projects $r 0 }
    foreach ($kp in $script:ClaudeProjectPaths.Keys) {
        if (-not $script:ProjectSet.ContainsKey($kp)) { $script:ProjectSet[$kp] = $true; $script:Projects.Add([pscustomobject]@{ Path = $kp; Markers = 'claude-known' }) }
    }
    if ($script:Counters.DepthLimited -gt 0) {
        Add-Coverage 'Search depth' ('{0} folders were not searched deeper because of -MaxDepth {1}. Re-run with a higher -MaxDepth if projects may be deeper.' -f $script:Counters.DepthLimited, $MaxDepth) $true
        foreach ($ex in $script:DepthExamples) { Add-Coverage 'Search depth example' $ex $false }
    }
    Write-AuditLog ('Found {0} project folders' -f $script:Projects.Count)

    $idx = 0
    foreach ($p in $script:Projects) {
        $idx++
        $dir = $p.Path
        Write-AuditLog ('  [{0}/{1}] {2}' -f $idx, $script:Projects.Count, $dir)
        try {
            $s = Get-TreeStats $dir
            $tech = New-Object System.Collections.Generic.List[string]
            $hints = ''
            $pkg = Join-Path $dir 'package.json'
            if (Test-Path -LiteralPath $pkg) {
                try {
                    $j = Read-JsonFile $pkg
                    $deps = @(@(Get-JKeys (Get-JVal $j 'dependencies')) + @(Get-JKeys (Get-JVal $j 'devDependencies')))
                    $tech.Add('Node.js')
                    foreach ($k in @('next', 'react', 'vue', 'svelte', '@nestjs/core', 'express', 'fastify', 'typeorm', 'prisma', '@supabase/supabase-js', 'pg', 'mongoose', 'electron', 'vite', 'typescript', '@anthropic-ai/sdk', '@modelcontextprotocol/sdk', '@google/clasp', 'googleapis', 'n8n', 'puppeteer', 'playwright', 'node-cron', 'nodemailer', 'xlsx', 'exceljs')) { if ($deps -contains $k) { $tech.Add($k) } }
                    $eng = Get-JVal $j 'engines'; if ($eng -and (Get-JVal $eng 'node')) { $hints = 'engines.node=' + (Get-JVal $eng 'node') }
                    $scr = Get-JVal $j 'scripts'; if ($scr) { $hints = ($hints + ' scripts=' + ((Get-JKeys $scr) -join '|')).Trim() }
                } catch { $tech.Add('Node.js(package.json unreadable)'); Add-Issue 'package.json' $pkg $_.Exception.Message }
            }
            foreach ($f in @('.nvmrc', '.node-version', '.python-version', 'runtime.txt', '.tool-versions')) { $fp = Join-Path $dir $f; if (Test-Path -LiteralPath $fp) { $hints += " $f=" + ((Get-Content -LiteralPath $fp -TotalCount 1 -ErrorAction SilentlyContinue) -join '') } }
            if (Test-Path -LiteralPath (Join-Path $dir 'requirements.txt')) { $tech.Add('Python') }
            if (Test-Path -LiteralPath (Join-Path $dir 'pyproject.toml')) { $tech.Add('Python(pyproject)') }
            if ($s.Ext['.py'] -and -not ($tech -match 'Python')) { $tech.Add('Python(scripts)') }
            if ($s.Ext['.gs'] -or (Test-Path -LiteralPath (Join-Path $dir 'appsscript.json'))) { $tech.Add('Google Apps Script') }
            if (Test-Path -LiteralPath (Join-Path $dir '.clasp.json')) { $tech.Add('clasp') }
            if ($s.Ext['.ps1']) { $tech.Add('PowerShell') }
            if ($s.Ext['.bat'] -or $s.Ext['.cmd']) { $tech.Add('Batch') }
            if ($s.Ext['.html'] -or $s.Ext['.htm']) { $tech.Add('HTML') }
            if ($s.Ext['.xlsm'] -or $s.Ext['.xlsb'] -or $s.Ext['.xlsx'] -or $s.Ext['.xls']) { $tech.Add('Excel files') }
            foreach ($pair in @(@('Dockerfile', 'Docker'), @('railway.json', 'Railway'), @('railway.toml', 'Railway'), @('vercel.json', 'Vercel'), @('.vercel', 'Vercel'), @('netlify.toml', 'Netlify'), @('supabase', 'Supabase CLI'), @('ecosystem.config.js', 'PM2'), @('ecosystem.config.cjs', 'PM2'), @('.github\workflows', 'GitHub Actions'))) {
                if (Test-Path -LiteralPath (Join-Path $dir $pair[0])) { $tech.Add($pair[1]) }
            }
            if ($s.Ext['.qbw']) { $tech.Add('QuickBooks data') }
            if ($s.Ext['.sln'] -or $s.Ext['.csproj']) { $tech.Add('.NET') }

            $claude = New-Object System.Collections.Generic.List[string]
            foreach ($c in @('CLAUDE.md', 'CLAUDE.local.md', 'AGENTS.md', '.mcp.json')) { if (Test-Path -LiteralPath (Join-Path $dir $c)) { $claude.Add($c) } }
            $dotClaude = Join-Path $dir '.claude'
            if (Test-Path -LiteralPath $dotClaude -PathType Container) { $claude.Add('.claude/ [' + ((Get-ChildItem -LiteralPath $dotClaude -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join '|') + ']') }
            $mcpNames = ''
            $mj = Join-Path $dir '.mcp.json'
            if (Test-Path -LiteralPath $mj) { try { $mcpNames = ((Get-JKeys (Get-JVal (Read-JsonFile $mj) 'mcpServers')) -join ', ') } catch { Add-Issue 'Claude' $mj 'unreadable .mcp.json' } }
            if ($script:ClaudeLinkedFolders.ContainsKey($dir)) { $claude.Add('known to Claude (' + $script:ClaudeLinkedFolders[$dir] + ')') }

            $isGit = Test-Path -LiteralPath (Join-Path $dir '.git')
            $g = @{ Remote = ''; Branch = ''; Dirty = ''; Untracked = ''; Ahead = ''; NoUpstream = ''; Stash = ''; LastCommit = ''; LocalOnly = ''; BranchesAhead = ''; ClaudeCommits = ''; Lfs = ''; Submodules = '' }
            if ($isGit -and $script:GitExe) {
                $remotes = @(Invoke-GitRead $dir @('remote', '-v'))
                $g.Remote = (@($remotes | Where-Object { $_ -match '\(fetch\)$' } | ForEach-Object { $_ -replace '\s+\(fetch\)$', '' }) -join ' ; ')
                $g.Branch = "$(Invoke-GitRead $dir @('rev-parse', '--abbrev-ref', 'HEAD'))"
                $st = @(Invoke-GitRead $dir @('status', '--porcelain', '--untracked-files=normal') 180)
                $g.Dirty = @($st | Where-Object { $_ -and $_ -notmatch '^\?\?' }).Count
                $g.Untracked = @($st | Where-Object { $_ -match '^\?\?' }).Count
                $up = "$(Invoke-GitRead $dir @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}'))"
                if ($up) { $g.Ahead = "$(Invoke-GitRead $dir @('rev-list', '--count', '@{u}..HEAD'))" } else { $g.NoUpstream = 'YES' }
                $g.Stash = @(Invoke-GitRead $dir @('stash', 'list')).Count
                $g.LastCommit = "$(Invoke-GitRead $dir @('log', '-1', '--format=%ci'))"
                $refs = @(Invoke-GitRead $dir @('for-each-ref', '--format=%(refname:short)|%(upstream:short)|%(upstream:track)', 'refs/heads'))
                $g.LocalOnly = (@($refs | Where-Object { ($_ -split '\|')[1] -eq '' } | ForEach-Object { ($_ -split '\|')[0] }) -join ' ')
                $g.BranchesAhead = @($refs | Where-Object { $_ -match '\[ahead' }).Count
                $bodies = @(Invoke-GitRead $dir @('log', '-n', '300', '--format=%an|%B'))
                $g.ClaudeCommits = @($bodies | Where-Object { $_ -match '(?i)co-authored-by:.*claude|generated with \[?claude code|claude\.ai/code|^claude\|' }).Count
                $ga = Join-Path $dir '.gitattributes'
                if ((Test-Path -LiteralPath $ga) -and ((Get-Content -LiteralPath $ga -Raw -ErrorAction SilentlyContinue) -match 'filter=lfs')) { $g.Lfs = 'YES' }
                if (Test-Path -LiteralPath (Join-Path $dir '.gitmodules')) { $g.Submodules = 'YES' }
                if ($script:GitDubious.ContainsKey($dir)) { Add-Issue 'Git' $dir 'Git refused to read this repository ("dubious ownership": created by another account). Status NOT inspected.' }
            } elseif ($isGit) { Add-Issue 'Git' $dir 'git.exe not found - repository status not inspected' }
            if ($g.ClaudeCommits -and [int]$g.ClaudeCommits -gt 0) { $claude.Add("Claude-assisted commits: $($g.ClaudeCommits)") }

            $inSync = ''
            foreach ($sr in $SyncRoots) { if (Test-UnderPath $dir $sr) { $inSync = $sr } }
            $risk = @()
            if (-not $isGit) { $risk += 'NOT-IN-GIT' } elseif (-not $g.Remote) { $risk += 'NO-REMOTE' }
            if ($g.Dirty -and [int]$g.Dirty -gt 0) { $risk += "UNCOMMITTED($($g.Dirty))" }
            if ($g.Untracked -and [int]$g.Untracked -gt 0) { $risk += "UNTRACKED($($g.Untracked))" }
            if ($g.Ahead -and [int]$g.Ahead -gt 0) { $risk += "UNPUSHED-COMMITS($($g.Ahead))" }
            if ($g.BranchesAhead -and [int]$g.BranchesAhead -gt 0) { $risk += "BRANCHES-AHEAD($($g.BranchesAhead))" }
            if ($g.NoUpstream) { $risk += 'BRANCH-WITHOUT-UPSTREAM' }
            if ($g.LocalOnly) { $risk += 'LOCAL-ONLY-BRANCHES' }
            if ($g.Stash -and [int]$g.Stash -gt 0) { $risk += "STASH($($g.Stash))" }
            if (@($script:SecretFiles | Where-Object { $_.Project -eq $dir }).Count -gt 0) { $risk += 'HAS-SECRET-FILES' }
            if (@($script:DataFiles | Where-Object { $_.Project -eq $dir }).Count -gt 0) { $risk += 'HAS-LOCAL-DATA-FILES' }
            if (@($script:HardPaths | Where-Object { $_.Project -eq $dir }).Count -gt 0) { $risk += 'HARDCODED-PATHS' }
            if ($s.CloudOnly -gt 0) { $risk += "CLOUD-ONLY-FILES($($s.CloudOnly))" }
            if ($inSync) { $risk += 'IN-CLOUD-SYNC-FOLDER' }

            $script:ProjRows.Add([pscustomobject]@{
                    ProjectName = Split-Path $dir -Leaf; Path = $dir; Markers = $p.Markers; Technologies = (($tech | Select-Object -Unique) -join ', ')
                    RuntimeHints = $hints.Trim(); ClaudeEvidence = ($claude -join ' ; '); ProjectMcpServers = $mcpNames
                    SizeMB_excl_heavy = [math]::Round($s.Bytes / 1MB, 2); FileCount_excl_heavy = $s.Files; HeavyDirsSkipped = (($s.Heavy | Select-Object -First 10) -join ' ; ')
                    LastModifiedFile = $(if ($s.Newest -gt [datetime]::MinValue) { $s.Newest.ToString('s') } else { '' })
                    CloudOnlyFiles = $s.CloudOnly; FilesNotContentScanned = $s.NotScanned; InCloudSyncFolder = $inSync
                    IsGit = $isGit; GitRemote = (Format-Safe $g.Remote); GitBranch = $g.Branch; LastCommit = $g.LastCommit; UncommittedChanges = $g.Dirty; UntrackedFiles = $g.Untracked
                    UnpushedCommits = $g.Ahead; BranchesAhead = $g.BranchesAhead; NoUpstream = $g.NoUpstream; LocalOnlyBranches = $g.LocalOnly; StashCount = $g.Stash
                    GitLfs = $g.Lfs; Submodules = $g.Submodules; LinkedScheduledTasks = ''; LinkedStartupItems = ''; RiskFlags = ($risk -join ' ')
                })
        } catch { Add-Issue 'Project' $dir ('project inspection failed: ' + $_.Exception.Message) 'ERROR' }
    }
} catch { $fail = $_ }
Complete-Step $fail

# =====================================================================================
#  STEP 3 - scheduled tasks (inventory + XML export to PRIVATE only; no state change)
# =====================================================================================
Start-Step '3 Scheduled tasks'
$fail = $null
$script:TaskRows = New-Object System.Collections.Generic.List[object]
$script:TaskRefs = @{}   # referenced path -> list of task names
function Format-Trigger {
    param($t)
    $parts = @(($t.CimClass.CimClassName -replace '^MSFT_Task', '' -replace 'Trigger$', ''))
    if ($t.StartBoundary) { $parts += "start=$($t.StartBoundary)" }
    if ($t.EndBoundary) { $parts += "end=$($t.EndBoundary)" }
    if ($t.DaysInterval) { $parts += "everyDays=$($t.DaysInterval)" }
    if ($t.WeeksInterval) { $parts += "everyWeeks=$($t.WeeksInterval)" }
    if ($t.DaysOfWeek) { $parts += "daysOfWeek=$($t.DaysOfWeek)" }
    if ($t.Repetition -and $t.Repetition.Interval) { $parts += "repeat=$($t.Repetition.Interval) for=$($t.Repetition.Duration)" }
    if ($t.Delay) { $parts += "delay=$($t.Delay)" }
    if ($t.RandomDelay) { $parts += "randomDelay=$($t.RandomDelay)" }
    if ($t.UserId) { $parts += "user=$($t.UserId)" }
    if ($t.Subscription) { $parts += 'eventSubscription' }
    if ($t.StateChange) { $parts += "sessionStateChange=$($t.StateChange)" }
    if ($null -ne $t.Enabled -and -not $t.Enabled) { $parts += '(trigger disabled)' }
    return ($parts -join ' ')
}
try {
    $allTasks = @()
    $taskApiOk = $true
    try { $allTasks = @(Get-ScheduledTask -ErrorAction Stop) } catch {
        $taskApiOk = $false
        Add-Issue 'ScheduledTasks' 'Get-ScheduledTask' ('API failed: ' + $_.Exception.Message + ' - falling back to schtasks /Query (raw output, PRIVATE only)') 'ERROR'
        $r = Invoke-External (Join-Path $env:SystemRoot 'System32\schtasks.exe') @('/Query', '/FO', 'CSV', '/V') 120
        if ($r.StdOut) { [IO.File]::WriteAllText((Join-Path $Private 'schtasks_query_raw.csv'), $r.StdOut, $Utf8Bom); Add-Coverage 'Scheduled tasks' 'Only raw schtasks output is available (PRIVATE_DO_NOT_UPLOAD\schtasks_query_raw.csv); no XML exports.' $true }
    }
    $nonMs = @($allTasks | Where-Object { $_.TaskPath -notlike '\Microsoft\*' })
    Write-AuditLog ('Scheduled tasks: total={0}, under \Microsoft\ (not exported)={1}, others={2}' -f $allTasks.Count, ($allTasks.Count - $nonMs.Count), $nonMs.Count)
    $vendorPattern = '(?i)^(MicrosoftEdgeUpdate|OneDrive|GoogleUpdate|GoogleUpdater|Google(Chrome|Drive)|Adobe|Acrobat|NvTm|NVIDIA|NvProfile|NvDriver|Intel|CreateExplorerShellUnelevatedTask|npcapwatchdog|User_Feed_Synchronization|MozillaUpdate|Firefox|Opera|Brave|Dropbox|Zoom|Teams|Dell|HP|Lenovo|ASUS|Acer|Realtek|Logitech|Avast|AVG|McAfee|Norton|Kaspersky|ESET|CCleaner|Spotify|Apple|iTunes|Office |Microsoft Office|MicrosoftOffice|PowerToys|WinRAR|7-Zip|AnyDesk|TeamViewer|Docker)'
    $usedNames = @{}
    foreach ($t in $nonMs) {
        $full = $t.TaskPath + $t.TaskName
        try {
            $info = $null
            try { $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop } catch { Add-Issue 'ScheduledTaskInfo' $full $_.Exception.Message }
            $category = 'Custom'
            if ($t.TaskName -match $vendorPattern -or "$($t.Author)" -match '(?i)^(Microsoft|Google|Adobe|NVIDIA|Intel|Mozilla|Dell|HP|Lenovo|Apple)') { $category = 'Vendor/Updater' }
            $execs = @(); $argsList = @(); $wds = @(); $refFiles = New-Object System.Collections.Generic.List[string]
            foreach ($a in @($t.Actions)) {
                if ($a.Execute) { $execs += $a.Execute } elseif ($a.ClassId) { $execs += "COM:$($a.ClassId)" } else { $execs += "$($a.CimClass.CimClassName)" }
                $argsList += "$($a.Arguments)"
                $wds += "$($a.WorkingDirectory)"
                foreach ($pp in (Get-PathsFromCommand "$($a.Execute)" "$($a.Arguments)" "$($a.WorkingDirectory)")) { if (-not $refFiles.Contains($pp)) { $refFiles.Add($pp) } }
            }
            $refDetail = @()
            foreach ($rf in $refFiles) {
                $state = 'MISSING'; $extra = ''
                try {
                    if ([IO.File]::Exists($rf)) {
                        $state = 'exists'
                        $rfi = New-Object IO.FileInfo($rf)
                        $extra = ', ' + $rfi.LastWriteTime.ToString('s')
                        if ($rfi.Length -lt 50MB -and -not (Test-CloudOnly $rfi.Attributes) -and $rfi.Name -notmatch $SecretFilePattern) { $extra += ', sha256:' + (Get-FileHash -LiteralPath $rf -Algorithm SHA256 -ErrorAction Stop).Hash.Substring(0, 16) + '...' }
                    } elseif ([IO.Directory]::Exists($rf)) { $state = 'folder' }
                } catch { $state = 'not checked' }
                $refDetail += ('{0} [{1}{2}]' -f $rf, $state, $extra)
                if (-not $script:TaskRefs.ContainsKey($rf)) { $script:TaskRefs[$rf] = New-Object System.Collections.Generic.List[string] }
                $script:TaskRefs[$rf].Add($full)
            }
            $joined = ($execs + $argsList) -join ' '
            $runtime = @()
            foreach ($k in @('python', 'pythonw', 'py.exe', 'node', 'npm', 'npx', 'powershell', 'pwsh', 'cmd.exe', 'wscript', 'cscript', 'mshta', 'curl', 'claude', 'pm2', 'docker', 'git', 'rclone', 'robocopy', 'excel', 'qbw', 'outlook')) { if ($joined -match [regex]::Escape($k)) { $runtime += $k } }
            $external = ($joined -match '(?i)https?://|supabase|railway|vercel|n8n|googleapis|script\.google|graph\.microsoft|sharepoint|smtp|sendmail|gmail|outlook|anthropic|claude|\bapi\b|ingest|webhook')
            $dup = 'LOW (vendor task; reinstalling the software recreates it)'
            if ($category -eq 'Custom') { if ($runtime.Count -gt 0 -or $external) { $dup = 'HIGH - custom script / external service; must never run on both laptops' } else { $dup = 'MEDIUM - custom task; check what it does' } }
            $set = $t.Settings
            $xmlName = (($t.TaskPath.Trim('\') -replace '[\\/:*?"<>|]', '_') + '__' + ($t.TaskName -replace '[\\/:*?"<>|]', '_')).Trim('_')
            if ($xmlName.Length -gt 150) { $xmlName = $xmlName.Substring(0, 150) }
            $n = 1; $candidate = $xmlName
            while ($usedNames.ContainsKey($candidate.ToLowerInvariant())) { $n++; $candidate = "$xmlName($n)" }
            $usedNames[$candidate.ToLowerInvariant()] = $true
            $xmlName = $candidate + '.xml'
            $exported = 'No'
            try {
                $xml = Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop
                [IO.File]::WriteAllText((Join-Path $TaskXml $xmlName), $xml, (New-Object System.Text.UnicodeEncoding($false, $true)))
                $exported = 'Yes'
            } catch { Add-Issue 'ScheduledTaskExport' $full $_.Exception.Message }
            $script:TaskRows.Add([pscustomobject]@{
                    TaskName = $t.TaskName; TaskPath = $t.TaskPath; Category = $category; State = "$($t.State)"; Author = (Format-Safe "$($t.Author)")
                    Description = (Format-Safe "$($t.Description)"); Triggers = (Format-Safe ((@($t.Triggers) | ForEach-Object { Format-Trigger $_ }) -join ' || '))
                    RunsAtLogon = [bool](@($t.Triggers) | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' })
                    RunsAtStartup = [bool](@($t.Triggers) | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' })
                    Execute = (Format-Safe ($execs -join ' ;; ')); Arguments = (Format-Safe ($argsList -join ' ;; ')); WorkingDirectory = (Format-Safe ($wds -join ' ;; '))
                    ReferencedFiles = (Format-Safe ($refDetail -join ' ; '))
                    RunAsUser = (Format-Safe "$($t.Principal.UserId)"); LogonType = "$($t.Principal.LogonType)"; RunLevel = "$($t.Principal.RunLevel)"
                    Hidden = $(if ($set) { $set.Hidden } else { '' }); MultipleInstances = $(if ($set) { "$($set.MultipleInstances)" } else { '' })
                    StartWhenAvailable = $(if ($set) { $set.StartWhenAvailable } else { '' }); WakeToRun = $(if ($set) { $set.WakeToRun } else { '' })
                    RunOnlyIfNetwork = $(if ($set) { $set.RunOnlyIfNetworkAvailable } else { '' }); ExecutionTimeLimit = $(if ($set) { "$($set.ExecutionTimeLimit)" } else { '' })
                    LastRunTime = $(if ($info) { "$($info.LastRunTime)" } else { '' }); LastTaskResult = $(if ($info) { '0x{0:X}' -f $info.LastTaskResult } else { '' })
                    NextRunTime = $(if ($info) { "$($info.NextRunTime)" } else { '' }); MissedRuns = $(if ($info) { $info.NumberOfMissedRuns } else { '' })
                    RuntimeDetected = ($runtime -join ','); CallsExternal = $external; DuplicateRisk = $dup
                    XmlExported = $exported; XmlFile = "PRIVATE_DO_NOT_UPLOAD\scheduled_tasks_xml\$xmlName"
                })
        } catch { Add-Issue 'ScheduledTask' $full ('not inventoried: ' + $_.Exception.Message) 'ERROR' }
    }
    Save-Csv $script:TaskRows 'SCHEDULED_TASKS_INVENTORY.csv'
    if (-not $taskApiOk) { throw 'Scheduled task API unavailable - inventory incomplete' }
} catch { $fail = $_ }
Complete-Step $fail

foreach ($row in $script:ProjRows) {
    $linked = New-Object System.Collections.Generic.List[string]
    foreach ($rf in $script:TaskRefs.Keys) {
        if ((Test-UnderPath $rf $row.Path) -or ($rf -ieq $row.Path)) { foreach ($tn in $script:TaskRefs[$rf]) { if (-not $linked.Contains($tn)) { $linked.Add($tn) } } }
    }
    $safeProj = (Format-Safe $row.Path).ToLowerInvariant()
    if ($safeProj.Length -ge 4) {
        foreach ($tr in $script:TaskRows) {
            if ($tr.Category -eq 'Custom' -and "$($tr.WorkingDirectory)".ToLowerInvariant().Contains($safeProj)) { $nm = $tr.TaskPath + $tr.TaskName; if (-not $linked.Contains($nm)) { $linked.Add($nm) } }
        }
    }
    $row.LinkedScheduledTasks = ($linked -join ' ; ')
    if ($linked.Count -gt 0) { $row.RiskFlags = ($row.RiskFlags + ' HAS-SCHEDULED-TASKS').Trim() }
}

# =====================================================================================
#  STEP 4 - startup items, services, processes, PM2 (no state change)
# =====================================================================================
Start-Step '4 Startup, services, processes, PM2'
$fail = $null
try {
    $startup = New-Object System.Collections.Generic.List[object]
    $approved = @{}
    foreach ($ak in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder',
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder')) {
        $props = Get-ItemProperty -Path $ak -ErrorAction SilentlyContinue
        if ($props) { foreach ($pr in $props.PSObject.Properties) { if ($pr.Name -notlike 'PS*' -and $pr.Value -is [byte[]] -and $pr.Value.Length -gt 0) { if (($pr.Value[0] -band 1) -eq 1) { $approved[$pr.Name] = 'Disabled' } else { $approved[$pr.Name] = 'Enabled' } } } }
    }
    foreach ($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce')) {
        $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($pr in $props.PSObject.Properties) {
            if ($pr.Name -like 'PS*') { continue }
            $state = 'Enabled'; if ($approved.ContainsKey($pr.Name)) { $state = $approved[$pr.Name] }
            $startup.Add([pscustomobject]@{ Source = $key; Name = $pr.Name; State = $state; Command = (Format-Safe "$($pr.Value)"); WorkingDirectory = '' })
        }
    }
    $shell = $null
    try { $shell = New-Object -ComObject WScript.Shell } catch { Add-Issue 'Startup' 'WScript.Shell' 'shortcut targets not readable' }
    foreach ($sf in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
        if (-not $sf -or -not (Test-Path -LiteralPath $sf)) { continue }
        foreach ($it in @(Get-ChildItem -LiteralPath $sf -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
            $target = $it.FullName; $wd = ''
            if ($it.Extension -eq '.lnk' -and $shell) { try { $lnk = $shell.CreateShortcut($it.FullName); $target = "$($lnk.TargetPath) $($lnk.Arguments)"; $wd = $lnk.WorkingDirectory } catch { Add-Issue 'Startup' $it.FullName 'shortcut not readable' } }   # read only: .Save() is never called
            $state = 'Enabled'; if ($approved.ContainsKey($it.Name)) { $state = $approved[$it.Name] }
            $startup.Add([pscustomobject]@{ Source = "StartupFolder: $sf"; Name = $it.Name; State = $state; Command = (Format-Safe $target); WorkingDirectory = (Format-Safe $wd) })
        }
    }
    Save-Csv $startup 'startup_items.csv'
    foreach ($row in $script:ProjRows) {
        $sp = (Format-Safe $row.Path).ToLowerInvariant()
        if ($sp.Length -lt 4) { continue }
        $hits = @($startup | Where-Object { "$($_.Command) $($_.WorkingDirectory)".ToLowerInvariant().Contains($sp) } | ForEach-Object { $_.Name })
        if ($hits.Count -gt 0) { $row.LinkedStartupItems = ($hits -join ' ; '); $row.RiskFlags = ($row.RiskFlags + ' HAS-STARTUP-ITEMS').Trim() }
    }

    $services = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($sv in @(Get-CimInstance Win32_Service -ErrorAction Stop)) {
            if (-not $sv.PathName) { continue }
            if ($sv.PathName -match '(?i)\\Windows\\(system32|SysWOW64|servicing|Microsoft\.NET|WinSxS)\\|\\Windows Defender\\|\\Windows Defender Advanced Threat Protection\\') { continue }
            $wrapped = ''
            if ($sv.PathName -match '(?i)nssm') {
                $pp = Get-ItemProperty -Path ('HKLM:\SYSTEM\CurrentControlSet\Services\{0}\Parameters' -f $sv.Name) -ErrorAction SilentlyContinue
                if ($pp) { $wrapped = "NSSM -> app=$($pp.Application) dir=$($pp.AppDirectory) args=$($pp.AppParameters)" }
            } elseif ($sv.PathName -match '(?i)winsw|\\daemon\\') { $wrapped = 'WinSW / node-windows wrapper (see the .xml next to the exe)' }
            $services.Add([pscustomobject]@{ Name = $sv.Name; DisplayName = $sv.DisplayName; State = $sv.State; StartMode = $sv.StartMode; DelayedAutoStart = $sv.DelayedAutoStart; Account = (Format-Safe "$($sv.StartName)"); Path = (Format-Safe $sv.PathName); WrappedApp = (Format-Safe $wrapped); Description = (Format-Safe "$($sv.Description)") })
        }
    } catch { Add-Issue 'Services' 'Win32_Service' $_.Exception.Message 'ERROR' }
    Save-Csv $services 'services_non_windows.csv'

    $procRows = New-Object System.Collections.Generic.List[object]
    $projPathsLower = @($script:ProjRows | ForEach-Object { $_.Path.ToLowerInvariant() })
    $hiddenCmd = 0
    try {
        foreach ($pr in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
            $cl = "$($pr.CommandLine)"
            $interesting = ($pr.Name -match '(?i)^(node|python|pythonw|py|pwsh|powershell|cmd|wscript|cscript|mshta|pm2|n8n|docker|com\.docker.*|ngrok|cloudflared|claude|java|javaw|php|ruby|deno|bun|uvicorn|gunicorn|rclone|robocopy|qbw.*|autohotkey.*)(\.exe)?$')
            if (-not $interesting -and $cl) { foreach ($pp in $projPathsLower) { if ($cl.ToLowerInvariant().Contains($pp)) { $interesting = $true; break } } }
            if (-not $interesting) { continue }
            if (-not $cl) { $hiddenCmd++ }
            $procRows.Add([pscustomobject]@{ Name = $pr.Name; PID = $pr.ProcessId; ParentPID = $pr.ParentProcessId; Started = "$($pr.CreationDate)"; CommandLine = (Format-Safe $cl); ExecutablePath = (Format-Safe "$($pr.ExecutablePath)") })
        }
    } catch { Add-Issue 'Processes' 'Win32_Process' $_.Exception.Message 'ERROR' }
    if ($hiddenCmd -gt 0) { Add-Coverage 'Processes' ('{0} relevant processes hide their command line (other accounts / elevated). Run as Administrator to see them.' -f $hiddenCmd) $true }
    Save-Csv $procRows 'running_script_processes.csv'

    # PM2: the pm2 CLI is NOT executed (it can start a daemon). The saved list is read instead.
    $pm2Rows = New-Object System.Collections.Generic.List[object]
    $pm2Home = $env:PM2_HOME; if (-not $pm2Home) { $pm2Home = Join-Path $home_ '.pm2' }
    $dump = Join-Path $pm2Home 'dump.pm2'
    if (Test-Path -LiteralPath $dump) {
        try {
            $items = @(Read-JsonFile $dump)
            if ($items.Count -eq 1 -and $items[0] -is [System.Collections.IList]) { $items = @($items[0]) }
            foreach ($it in $items) {
                $pm2Rows.Add([pscustomobject]@{ Source = 'dump.pm2 (saved list - restored at boot if pm2 startup is configured)'; Name = (Get-JVal $it 'name'); Script = (Format-Safe "$(Get-JVal $it 'pm_exec_path')"); Cwd = (Format-Safe "$(Get-JVal $it 'pm_cwd')")
                        Interpreter = (Get-JVal $it 'exec_interpreter'); CronRestart = (Get-JVal $it 'cron_restart'); Args = (Format-Safe ((@(Get-JVal $it 'args')) -join ' ')); Note = 'environment values NOT recorded' })
            }
        } catch { Add-Issue 'PM2' $dump ('unreadable: ' + $_.Exception.Message) }
    }
    if (@($procRows | Where-Object { $_.CommandLine -match '(?i)pm2' }).Count -gt 0) { Add-Coverage 'PM2' 'A PM2 daemon is running; its live list was not queried (that needs the pm2 CLI). Saved list + process list are used instead.' $false }
    Save-Csv $pm2Rows 'pm2_processes.csv'
} catch { $fail = $_ }
Complete-Step $fail

# =====================================================================================
#  STEP 5 - stand-alone scripts, HTML, Excel and important data files (outside projects)
# =====================================================================================
Start-Step '5 Stand-alone files'
$fail = $null
$script:Scripts = New-Object System.Collections.Generic.List[object]
$script:Html = New-Object System.Collections.Generic.List[object]
$script:Excel = New-Object System.Collections.Generic.List[object]
$script:DataOut = New-Object System.Collections.Generic.List[object]
$Caps = @{ Scripts = 5000; Html = 3000; Excel = 5000; Data = 3000 }
$script:CapHit = @{}
$ImportantDataExt = @('.qbw', '.qbb', '.qbm', '.qbx', '.tlg', '.nd', '.pst', '.ost', '.kdbx', '.accdb', '.mdb', '.sqlite', '.sqlite3', '.db', '.bak')
$ExcelExt = @('.xlsx', '.xlsm', '.xlsb', '.xls', '.xltm', '.xlam', '.csv')
$HtmlExt = @('.html', '.htm')
function Test-Cap {
    param([string]$Kind, $List)
    if ($List.Count -ge $Caps[$Kind]) { $script:CapHit[$Kind] = $true; return $true }
    return $false
}
function Get-ScriptFlags {
    param([string]$Text)
    $f = @()
    if ($Text -match '(?i)Invoke-RestMethod|Invoke-WebRequest|requests\.(get|post|put|patch|delete)|urllib|httpx|aiohttp|fetch\(|axios|XMLHttpRequest|UrlFetchApp|\bcurl(\.exe)?\s|\bwget\s|Net\.WebClient|HttpClient') { $f += 'HTTP' }
    if ($Text -match '(?i)Send-MailMessage|smtplib|nodemailer|MailApp|GmailApp|Outlook\.Application|win32com\.client|sendgrid|mailgun|SmtpClient') { $f += 'EMAIL' }
    if ($Text -match '(?i)schtasks|Register-ScheduledTask|New-ScheduledTask|ScriptApp\.newTrigger|node-cron|cron\.schedule|schedule\.every|APScheduler|setInterval\(') { $f += 'SCHEDULER' }
    if ($Text -match '(?i)Remove-Item|\brm\s+-r|\brmdir\b|\bdel\s+/|\berase\b|os\.remove|os\.unlink|shutil\.rmtree|fs\.(unlink|rm)Sync|DROP\s+TABLE|TRUNCATE\s+TABLE|DELETE\s+FROM|setTrashed') { $f += 'DESTRUCTIVE-OPS' }
    if ($Text -match '(?i)postgres(ql)?://|psycopg|supabase|sqlite3|pyodbc|mysql|mongodb|DATABASE_URL|typeorm|prisma') { $f += 'DATABASE' }
    if ($Text -match '(?i)QBXML|QBFC|QuickBooks|openpyxl|xlsxwriter|Excel\.Application|read_excel|xlrd|exceljs') { $f += 'OFFICE/FINANCE' }
    if ($Text -match '(?i)anthropic|claude') { $f += 'CLAUDE' }
    $hits = [regex]::Matches($Text, '(?i)(api[_-]?key|secret|token|password|passwd|bearer)\s*[=:]\s*["'']?[A-Za-z0-9_\-\.]{8,}').Count + [regex]::Matches($Text, '\b(sk-ant-|sk-[A-Za-z0-9]{10}|ghp_|github_pat_|xox[abprs]-|AIza|eyJ[A-Za-z0-9_-]{8,}\.)').Count
    if ($hits -gt 0) { $f += "POSSIBLE-INLINE-SECRETS($hits)" }
    return ($f -join ' ')
}
function Find-Standalone {
    param([string]$Dir, [int]$Depth)
    if ($Depth -gt $MaxDepth) { return }
    if (Test-SkipDir $Dir) { return }
    if ($ScriptDirFull -and ($Dir.TrimEnd('\') -ieq $ScriptDirFull)) { return }
    if ($Depth -gt 0 -and ($ExcludeDirNames -contains (Split-Path $Dir -Leaf))) { return }
    if ($Depth -gt 0 -and (Test-Reparse $Dir)) { return }
    if ($script:ProjectSet.ContainsKey($Dir)) { return }
    foreach ($f in (Get-Files $Dir)) {
        try {
            $fi = New-Object IO.FileInfo($f)
            $ext = $fi.Extension.ToLowerInvariant()
            $cloudOnly = Test-CloudOnly $fi.Attributes
            if ($ScriptExtensions -contains $ext) {
                if (Test-Cap 'Scripts' $script:Scripts) { continue }
                $flags = ''; $refs = ''; $paths = ''
                $txt = Read-TextSafe $fi 'Scripts'
                if ($null -ne $txt) {
                    $flags = Get-ScriptFlags $txt
                    $refs = (@([regex]::Matches($txt, $HostPattern) | ForEach-Object { $_.Value } | Select-Object -Unique -First 8 | ForEach-Object { Format-Safe $_ }) -join ' ; ')
                    $plist = New-Object System.Collections.Generic.List[string]
                    foreach ($line in @($txt -split "`n" | Select-Object -First 5000)) {
                        if ($line.IndexOf(':\') -lt 0 -and $line.IndexOf(':/') -lt 0 -and $line.IndexOf('\\') -lt 0) { continue }
                        foreach ($p in (Get-PathRefs $line)) { if (-not $plist.Contains($p)) { $plist.Add($p) } }
                        if ($plist.Count -ge 5) { break }
                    }
                    $paths = (@($plist | ForEach-Object { Format-Safe $_ }) -join ' ; ')
                } elseif ($cloudOnly) { $flags = 'CLOUD-ONLY (not read)' } else { $flags = 'NOT-READ (size or lock)' }
                $usedBy = ''; if ($script:TaskRefs.ContainsKey($f)) { $usedBy = ($script:TaskRefs[$f] -join ' ; ') }
                $script:Scripts.Add([pscustomobject]@{ Path = (Format-Safe $f); Type = $ext; SizeKB = [math]::Round($fi.Length / 1KB, 1); LastWrite = $fi.LastWriteTime.ToString('s'); CloudOnly = $cloudOnly; UsedByScheduledTask = $usedBy; Flags = $flags; ServiceRefs = $refs; HardcodedPaths = $paths })
            } elseif ($HtmlExt -contains $ext) {
                if (Test-Cap 'Html' $script:Html) { continue }
                $title = ''; $flags = @(); $refs = ''
                $txt = Read-TextSafe $fi 'HTML'
                if ($null -ne $txt) {
                    $m = [regex]::Match($txt, '(?is)<title[^>]*>(.*?)</title>')
                    if ($m.Success) { $title = Format-Safe (($m.Groups[1].Value -replace '\s+', ' ').Trim()); if ($title.Length -gt 120) { $title = $title.Substring(0, 120) } }
                    if ($txt -match '(?i)saved from url=') { $flags += 'SAVED-WEB-PAGE' }
                    if ($txt -match '(?i)<script') { $flags += 'HAS-SCRIPT' }
                    if ($txt -match '(?i)google\.script\.run|script\.google\.com') { $flags += 'APPS-SCRIPT-FRONTEND' }
                    if ($txt -match '(?i)fetch\(|XMLHttpRequest|axios|\$\.ajax') { $flags += 'CALLS-API' }
                    if ($txt -match '(?i)react|babel|tailwind|recharts|cdnjs|unpkg|jsdelivr') { $flags += 'APP-LIKE' }
                    if ($txt -match '(?i)claude|anthropic') { $flags += 'MENTIONS-CLAUDE' }
                    $refs = (@([regex]::Matches($txt, $HostPattern) | ForEach-Object { $_.Value } | Select-Object -Unique -First 6 | ForEach-Object { Format-Safe $_ }) -join ' ; ')
                } elseif ($cloudOnly) { $flags += 'CLOUD-ONLY (not read)' } else { $flags += 'NOT-READ (size or lock)' }
                $script:Html.Add([pscustomobject]@{ Path = (Format-Safe $f); SizeKB = [math]::Round($fi.Length / 1KB, 1); LastWrite = $fi.LastWriteTime.ToString('s'); CloudOnly = $cloudOnly; Title = $title; Flags = ($flags -join ' '); ServiceRefs = $refs })
            } elseif ($ExcelExt -contains $ext) {
                if ($fi.Name.StartsWith('~$')) { continue }   # Excel owner/lock file
                if (Test-Cap 'Excel' $script:Excel) { continue }
                $x = Get-ExcelInfo $fi
                $script:Excel.Add([pscustomobject]@{ Path = (Format-Safe $f); Type = $ext; SizeKB = [math]::Round($fi.Length / 1KB, 1); LastWrite = $fi.LastWriteTime.ToString('s'); CloudOnly = $cloudOnly
                        HasMacros = $x.HasMacros; ExternalLinkCount = $x.ExternalLinkCount; ExternalLinkTargets = $x.ExternalLinkTargets; DataConnections = $x.DataConnections; PowerQuery = $x.PowerQuery; QueryTables = $x.QueryTables; Inspected = $x.Inspected; Note = $x.Note })
            } elseif ($ImportantDataExt -contains $ext) {
                if ($fi.Name -ieq 'Thumbs.db') { continue }
                if (Test-Cap 'Data' $script:DataOut) { continue }
                $script:DataOut.Add([pscustomobject]@{ Path = (Format-Safe $f); Type = $ext; SizeMB = [math]::Round($fi.Length / 1MB, 2); LastWrite = $fi.LastWriteTime.ToString('s'); CloudOnly = $cloudOnly })
            }
        } catch { Add-Issue 'StandaloneFile' $f $_.Exception.Message }
    }
    foreach ($sd in (Get-SubDirs $Dir)) { Find-Standalone $sd ($Depth + 1) }
}
try {
    $standaloneRoots = @($script:Roots)
    foreach ($extra in @((Join-Path $env:LOCALAPPDATA 'Microsoft\Outlook'), (Join-Path ($env:SystemDrive + '\') 'Users\Public\Documents\Intuit'))) {
        if (Test-Path -LiteralPath $extra) { $covered = $false; foreach ($r in $standaloneRoots) { if (Test-UnderPath $extra $r) { $covered = $true } }; if (-not $covered) { $standaloneRoots += $extra } }
    }
    foreach ($r in $standaloneRoots) { Write-AuditLog "  scanning $r"; Find-Standalone $r 0 }
    foreach ($k in $script:CapHit.Keys) { Add-Coverage 'Caps' ('Limit of {0} {1} rows reached - that list is incomplete.' -f $Caps[$k], $k) $true }
    Save-Csv $script:Scripts 'standalone_scripts.csv'
    Save-Csv $script:Html 'standalone_html_files.csv'
    Save-Csv $script:Excel 'excel_workbooks.csv'
    Save-Csv $script:DataOut 'important_data_files.csv'
    $missing = @($script:TaskRefs.Keys | Where-Object { -not ([IO.File]::Exists($_) -or [IO.Directory]::Exists($_)) })
    if ($missing.Count -gt 0) { Write-AuditLog ('{0} file(s) referenced by scheduled tasks do not exist (see ReferencedFiles)' -f $missing.Count) 'WARN' }
} catch { $fail = $_ }
Complete-Step $fail

Save-Csv $script:ProjRows 'PROJECT_INVENTORY_LOCAL.csv'
Save-Csv $script:HardPaths 'project_hardcoded_paths.csv'
Save-Csv $script:HostRefs 'project_external_service_refs.csv'
Save-Csv $script:SecretFiles 'project_secret_files_NAMES_ONLY.csv'
Save-Csv $script:SecretHashes 'secret_file_hashes.csv' -PrivateFile
Save-Csv $script:EnvNames 'project_env_variable_NAMES_ONLY.csv'
Save-Csv $script:DataFiles 'project_local_data_files.csv'

# =====================================================================================
#  STEP 6 - software (file-based versions; only a short list of safe programs executed)
# =====================================================================================
Start-Step '6 Software'
$fail = $null
function Get-NpmPkgVersion {
    param([string]$ShimPath, [string]$Package)
    if (-not $ShimPath) { return '' }
    $dir = Split-Path $ShimPath -Parent
    foreach ($cand in @((Join-Path $dir ('node_modules\' + $Package + '\package.json')), (Join-Path (Split-Path $dir -Parent) ('node_modules\' + $Package + '\package.json')))) {
        if (Test-Path -LiteralPath $cand) { try { return [string](Get-JVal (Read-JsonFile $cand) 'version') } catch { return '(package.json unreadable)' } }
    }
    return ''
}
function Get-ToolInfo {
    param([string]$Name, [string[]]$ExecArgs, [string]$NpmPackage, [string[]]$AltPaths = @())
    $path = Get-AppPath $Name
    if (-not $path) { foreach ($ap in $AltPaths) { if ($ap -and (Test-Path -LiteralPath $ap)) { $path = $ap; break } } }
    if (-not $path) { return [pscustomobject]@{ Tool = $Name; Found = 'No'; Version = ''; VersionSource = ''; Path = '' } }
    $ver = ''; $src = ''
    if ($NpmPackage) { $ver = Get-NpmPkgVersion $path $NpmPackage; if ($ver) { $src = "package.json ($NpmPackage)" } }
    if (-not $ver -and $path -match '(?i)\.exe$') {
        try { $vi = (Get-Item -LiteralPath $path -Force -ErrorAction Stop).VersionInfo; if ($vi.ProductVersion) { $ver = $vi.ProductVersion.Trim(); $src = 'file version' } } catch { $src = 'file version unreadable' }
    }
    if (-not $ver -and $ExecArgs) {
        $r = Invoke-External $path $ExecArgs 20
        if ($r.TimedOut) { Add-Issue 'Software' $Name 'version query timed out' }
        $o = ((("$($r.StdOut)`n$($r.StdErr)") -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 3) -join ' | '
        if ($o) { $ver = $o.Trim(); $src = 'executed: ' + ($ExecArgs -join ' ') }
    }
    if (-not $ver) { $src = 'not executed (could have side effects); version unknown' }
    return [pscustomobject]@{ Tool = $Name; Found = 'Yes'; Version = (Format-Safe $ver); VersionSource = $src; Path = (Format-Safe $path) }
}
try {
    $tools = New-Object System.Collections.Generic.List[object]
    $pyPath = Get-AppPath 'python.exe'
    $storePy = @(Get-AppxPackage -Name 'PythonSoftwareFoundation.Python*' -ErrorAction SilentlyContinue).Count -gt 0
    if ($pyPath -and $pyPath -match '(?i)\\WindowsApps\\' -and -not $storePy) {
        $tools.Add([pscustomobject]@{ Tool = 'python.exe'; Found = 'Store alias only'; Version = 'not installed (Microsoft Store stub)'; VersionSource = 'not executed (would open the Store)'; Path = (Format-Safe $pyPath) })
        $pyPath = $null
    } elseif ($pyPath) { $tools.Add((Get-ToolInfo 'python.exe' @('--version'))) } else { $tools.Add((Get-ToolInfo 'python.exe')) }
    $tools.Add((Get-ToolInfo 'py.exe' @('--list-paths')))
    $tools.Add((Get-ToolInfo 'git.exe' @('--version')))
    $tools.Add((Get-ToolInfo 'node.exe' @('-v')))
    foreach ($pair in @(@('npm.cmd', 'npm'), @('npx.cmd', 'npm'), @('pnpm.cmd', 'pnpm'), @('yarn.cmd', 'yarn'), @('corepack.cmd', 'corepack'), @('clasp.cmd', '@google/clasp'), @('vercel.cmd', 'vercel'),
            @('railway.cmd', '@railway/cli'), @('supabase.cmd', 'supabase'), @('n8n.cmd', 'n8n'), @('pm2.cmd', 'pm2'), @('claude.cmd', '@anthropic-ai/claude-code'), @('tsx.cmd', 'tsx'), @('ts-node.cmd', 'ts-node'), @('nest.cmd', '@nestjs/cli'))) {
        $tools.Add((Get-ToolInfo $pair[0] $null $pair[1]))
    }
    $tools.Add((Get-ToolInfo 'claude.exe' $null $null @((Join-Path $home_ '.local\bin\claude.exe'))))
    $tools.Add((Get-ToolInfo 'pwsh.exe'))
    $codeCmd = Get-AppPath 'code.cmd'; $codeExe = $null
    if ($codeCmd) { $codeExe = Join-Path (Split-Path (Split-Path $codeCmd -Parent) -Parent) 'Code.exe' }
    $tools.Add((Get-ToolInfo 'Code.exe' $null $null @($codeExe, (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'), (Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe'))))
    $tools.Add((Get-ToolInfo 'Cursor.exe' $null $null @((Join-Path $env:LOCALAPPDATA 'Programs\cursor\Cursor.exe'))))
    $tools.Add((Get-ToolInfo 'docker.exe' @('--version')))
    $tools.Add((Get-ToolInfo 'gh.exe' @('--version')))
    $tools.Add((Get-ToolInfo 'uv.exe' @('--version')))
    $tools.Add((Get-ToolInfo 'winget.exe' @('--version')))
    $tools.Add((Get-ToolInfo 'psql.exe' @('--version')))
    foreach ($n in @('supabase.exe', 'railway.exe', 'vercel.exe', 'ngrok.exe', 'rclone.exe', 'choco.exe', 'scoop.cmd', 'nvm.exe', 'deno.exe', 'bun.exe', 'java.exe', 'pythonw.exe', 'wsl.exe')) { $tools.Add((Get-ToolInfo $n)) }
    $gc = Get-AppPath 'gcloud.cmd'
    if ($gc) {
        $vf = Join-Path (Split-Path (Split-Path $gc -Parent) -Parent) 'VERSION'; $gv = ''
        if (Test-Path -LiteralPath $vf) { $gv = "$(Get-Content -LiteralPath $vf -TotalCount 1)" }
        $tools.Add([pscustomobject]@{ Tool = 'gcloud'; Found = 'Yes'; Version = $gv; VersionSource = 'VERSION file'; Path = (Format-Safe $gc) })
    }
    $tools.Add([pscustomobject]@{ Tool = 'Windows PowerShell (this run)'; Found = 'Yes'; Version = $PSVersionTable.PSVersion.ToString(); VersionSource = 'runtime'; Path = (Format-Safe $PSHOME) })
    Save-Csv $tools 'software_cli_versions.csv'

    $runtimes = New-Object System.Collections.Generic.List[object]
    foreach ($hive in @('HKCU:\Software\Python\PythonCore', 'HKLM:\Software\Python\PythonCore', 'HKLM:\Software\WOW6432Node\Python\PythonCore')) {
        foreach ($pk in @(Get-ChildItem -Path $hive -ErrorAction SilentlyContinue)) {
            $ip = (Get-ItemProperty -Path (Join-Path $pk.PSPath 'InstallPath') -ErrorAction SilentlyContinue).'(default)'
            $runtimes.Add([pscustomobject]@{ Runtime = 'Python'; Version = $pk.PSChildName; Location = (Format-Safe "$ip"); Source = $hive })
        }
    }
    if ($env:NVM_HOME -and (Test-Path -LiteralPath $env:NVM_HOME)) { foreach ($nv in @(Get-ChildItem -LiteralPath $env:NVM_HOME -Directory -Filter 'v*' -ErrorAction SilentlyContinue)) { $runtimes.Add([pscustomobject]@{ Runtime = 'Node.js (nvm)'; Version = $nv.Name; Location = (Format-Safe $nv.FullName); Source = 'NVM_HOME' }) } }
    foreach ($wk in @(Get-ChildItem -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue)) {
        $pp = Get-ItemProperty -LiteralPath $wk.PSPath -ErrorAction SilentlyContinue
        if ($pp.DistributionName) { $runtimes.Add([pscustomobject]@{ Runtime = 'WSL distro'; Version = $pp.DistributionName; Location = (Format-Safe "$($pp.BasePath)"); Source = 'registry' }) }
    }
    if (@($runtimes | Where-Object { $_.Runtime -eq 'WSL distro' }).Count -gt 0) { Add-Coverage 'WSL' 'WSL distributions exist; cron jobs, files and services inside WSL are NOT inspected.' $true }
    $chocoRoot = $env:ChocolateyInstall; if (-not $chocoRoot) { $chocoRoot = Join-Path $env:ProgramData 'chocolatey' }
    $chocoLib = Join-Path $chocoRoot 'lib'
    if (Test-Path -LiteralPath $chocoLib) { foreach ($cp in @(Get-ChildItem -LiteralPath $chocoLib -Directory -ErrorAction SilentlyContinue)) { $runtimes.Add([pscustomobject]@{ Runtime = 'Chocolatey package'; Version = $cp.Name; Location = ''; Source = 'choco lib folder' }) } }
    $scoopApps = Join-Path $home_ 'scoop\apps'
    if (Test-Path -LiteralPath $scoopApps) { foreach ($sa in @(Get-ChildItem -LiteralPath $scoopApps -Directory -ErrorAction SilentlyContinue)) { $runtimes.Add([pscustomobject]@{ Runtime = 'Scoop app'; Version = $sa.Name; Location = ''; Source = 'scoop apps folder' }) } }
    $c2r = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
    if ($c2r) { $runtimes.Add([pscustomobject]@{ Runtime = 'Microsoft Office (Click-to-Run)'; Version = "$($c2r.VersionToReport) $($c2r.Platform)"; Location = "$($c2r.ProductReleaseIds)"; Source = 'registry' }) }
    Save-Csv $runtimes 'software_runtimes.csv'

    # installed programs from the registry (Win32_Product is deliberately NOT used: it can trigger MSI repairs)
    $installed = New-Object System.Collections.Generic.List[object]
    foreach ($k in @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        foreach ($ip in @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName })) {
            $scope = 'Machine'; if ($k -like 'HKCU*') { $scope = 'User' }
            $installed.Add([pscustomobject]@{ Name = $ip.DisplayName; Version = $ip.DisplayVersion; Publisher = $ip.Publisher; InstallDate = $ip.InstallDate; InstallLocation = (Format-Safe "$($ip.InstallLocation)"); Scope = $scope })
        }
    }
    $installedSorted = @($installed | Sort-Object Name, Version -Unique)
    Save-Csv $installedSorted 'software_installed_programs.csv'
    Save-Csv @($installedSorted | Where-Object { $_.Name -match '(?i)python|node\.?js|\bgit\b|visual studio code|cursor|claude|powershell|docker|quickbooks|intuit|microsoft 365|office|outlook|excel|postgres|mysql|sql server|sqlite|dbeaver|pgadmin|google drive|onedrive|dropbox|n8n|wsl|ubuntu|java|7-zip|winrar|chrome|edge|firefox|anydesk|teamviewer|vpn|forti|cisco|github|nvm|keepass|bitwarden|1password' }) 'software_key_programs.csv'
    $appx = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)claude|python|WindowsSubsystemForLinux|WindowsTerminal|DesktopAppInstaller|PowerShell|Ubuntu|Debian|Office|Outlook|Teams|WhatsApp|OneNote' } | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Version = "$($_.Version)"; Publisher = (Format-Safe "$($_.Publisher)") } })
    Save-Csv $appx 'software_store_apps.csv'

    $globalPkgs = New-Object System.Collections.Generic.List[object]
    $npmGlobal = Join-Path $env:APPDATA 'npm\node_modules'
    if (Test-Path -LiteralPath $npmGlobal) {
        foreach ($d in @(Get-ChildItem -LiteralPath $npmGlobal -Directory -Force -ErrorAction SilentlyContinue)) {
            $pkgDirs = @($d); if ($d.Name.StartsWith('@')) { $pkgDirs = @(Get-ChildItem -LiteralPath $d.FullName -Directory -Force -ErrorAction SilentlyContinue) }
            foreach ($pd in $pkgDirs) {
                $pj = Join-Path $pd.FullName 'package.json'; $v = ''
                if (Test-Path -LiteralPath $pj) { try { $v = [string](Get-JVal (Read-JsonFile $pj) 'version') } catch { $v = '(package.json unreadable)' } }
                $nm = $pd.Name; if ($d.Name.StartsWith('@')) { $nm = $d.Name + '/' + $pd.Name }
                $globalPkgs.Add([pscustomobject]@{ Manager = 'npm -g (read from disk)'; Package = $nm; Version = $v })
            }
        }
    }
    if ($pyPath) {
        $r = Invoke-External $pyPath @('-B', '-m', 'pip', 'list', '--format=json', '--disable-pip-version-check', '--no-color', '--no-input') 90
        if ($r.TimedOut) { Add-Issue 'Software' 'pip list' 'timed out' }
        elseif ($r.StdOut -and $r.StdOut.Trim().StartsWith('[')) { foreach ($x in @($r.StdOut | ConvertFrom-Json)) { foreach ($y in @($x)) { $globalPkgs.Add([pscustomobject]@{ Manager = 'pip (default python)'; Package = $y.name; Version = $y.version }) } } }
        elseif ($r.ExitCode -ne 0) { Add-Issue 'Software' 'pip list' ('failed: ' + (($r.StdErr -split "`n") | Select-Object -First 1)) }
    }
    Save-Csv $globalPkgs 'software_global_packages.csv'
    if ($IncludeWinget) {
        $wg = Get-AppPath 'winget.exe'
        if ($wg) {
            $wgOut = Join-Path $Shareable 'winget_export.json'
            $r = Invoke-External $wg @('export', '-o', $wgOut, '--include-versions', '--accept-source-agreements', '--disable-interactivity') 300
            if (Test-Path -LiteralPath $wgOut) { Write-AuditLog 'Wrote winget_export.json' } else { Add-Issue 'Software' 'winget export' ('no file produced: ' + $r.StdErr) }
        } else { Add-Issue 'Software' 'winget' 'winget not found' }
    }
} catch { $fail = $_ }
Complete-Step $fail

# =====================================================================================
#  STEP 7 - cloud services and tool configuration (presence and names only)
# =====================================================================================
Start-Step '7 Cloud and tool configuration'
$fail = $null
$script:Cloud = New-Object System.Collections.Generic.List[object]
function Add-Cloud {
    param($Service, $Item, $Path, $Detail, $Transfer)
    $present = $false
    if ($Path) { try { $present = Test-Path -LiteralPath $Path } catch { $present = 'unknown' } }
    $script:Cloud.Add([pscustomobject]@{ Service = $Service; Item = $Item; Path = (Format-Safe "$Path"); Present = $present; Detail = (Format-Safe "$Detail"); HowToTransfer = $Transfer })
}
try {
    if ($script:GitExe) {
        $gd = @()
        foreach ($k in @('user.name', 'user.email', 'credential.helper', 'core.autocrlf', 'core.longpaths', 'init.defaultBranch', 'core.editor')) {
            $r = Invoke-External $script:GitExe @('config', '--global', '--get', $k) 15
            if ($r.StdOut) { $gd += "$k=$($r.StdOut.Trim())" }
        }
        $r = Invoke-External $script:GitExe @('config', '--global', '--name-only', '--list') 15
        $names = @(($r.StdOut -split "`r?`n") | Where-Object { $_ } | Select-Object -Unique)
        Add-Cloud 'Git' 'global config' (Join-Path $home_ '.gitconfig') (($gd -join '; ') + ' | key names: ' + ($names -join ', ')) 'Copy .gitconfig after review; sign in again through Git Credential Manager'
    }
    $ghHosts = Join-Path $env:APPDATA 'GitHub CLI\hosts.yml'
    if (Test-Path -LiteralPath $ghHosts) {
        $lines = @(Get-Content -LiteralPath $ghHosts -ErrorAction SilentlyContinue)
        $hostsList = @($lines | Where-Object { $_ -match '^[^\s#][^:]*:\s*$' } | ForEach-Object { $_.TrimEnd(':', ' ') })
        $users = @($lines | Where-Object { $_ -match '^\s+user:\s*\S' } | ForEach-Object { ($_ -split ':', 2)[1].Trim() })
        Add-Cloud 'GitHub CLI' 'hosts.yml' $ghHosts ('hosts: ' + ($hostsList -join ', ') + '; users: ' + ($users -join ', ') + ' (tokens NOT read)') 'gh auth login on the new laptop'
    } else { Add-Cloud 'GitHub CLI' 'hosts.yml' $ghHosts '' 'gh auth login if used' }
    $cmdkey = Join-Path $env:SystemRoot 'System32\cmdkey.exe'
    if (Test-Path -LiteralPath $cmdkey) {
        $r = Invoke-External $cmdkey @('/list') 20
        $targets = @(($r.StdOut -split "`r?`n") | Where-Object { $_ -match 'target=' -or $_ -match '^\s*Target:' } | ForEach-Object { $_.Trim() })
        Add-Cloud 'Windows Credential Manager' 'saved credential targets (names only, no passwords)' '' (($targets | Select-Object -First 80) -join ' ; ') 'Each target is a sign-in to repeat on the new laptop (do not export passwords)'
    }
    $ssh = Join-Path $home_ '.ssh'
    if (Test-Path -LiteralPath $ssh) {
        $files = (Get-ChildItem -LiteralPath $ssh -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ', '
        $hostsCfg = ''
        $cfgFile = Join-Path $ssh 'config'
        if (Test-Path -LiteralPath $cfgFile) { $hostsCfg = (@(Get-Content -LiteralPath $cfgFile -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*(Host|HostName|User|IdentityFile)\s' } | ForEach-Object { $_.Trim() }) -join ' | ') }
        Add-Cloud 'SSH' '~\.ssh' $ssh ("files: $files; config: $hostsCfg (key contents NOT read)") 'Prefer a NEW key on the new laptop; otherwise move private keys only inside an encrypted container'
    }
    $presence = @(
        @('Vercel CLI', 'auth/config', (Join-Path $env:APPDATA 'com.vercel.cli'), 'vercel login'),
        @('Vercel CLI', 'auth/config (alt)', (Join-Path $home_ '.vercel'), 'vercel login'),
        @('Railway CLI', 'config', (Join-Path $home_ '.railway'), 'railway login'),
        @('Supabase CLI', 'config', (Join-Path $home_ '.supabase'), 'supabase login'),
        @('Google clasp', '.clasprc.json (OAuth token - NOT read)', (Join-Path $home_ '.clasprc.json'), 'clasp login on the new laptop'),
        @('Google Cloud SDK', 'config', (Join-Path $env:APPDATA 'gcloud'), 'gcloud auth login'),
        @('n8n (self-hosted on this laptop!)', '~\.n8n', (Join-Path $home_ '.n8n'), 'If present: export workflows; credentials need the same encryption key'),
        @('npm', '.npmrc (may hold registry tokens - NOT read)', (Join-Path $home_ '.npmrc'), 'Re-create; re-enter tokens'),
        @('Python', 'pip.ini', (Join-Path $env:APPDATA 'pip\pip.ini'), 'Copy if a custom index is used'),
        @('Docker', 'config', (Join-Path $home_ '.docker'), 'docker login'),
        @('AWS', 'config (NOT read)', (Join-Path $home_ '.aws'), 'Re-create from the password manager'),
        @('Azure', 'config', (Join-Path $home_ '.azure'), 'az login'),
        @('PM2', 'PM2 home', (Join-Path $home_ '.pm2'), 'Re-create processes from ecosystem files; do not copy logs'),
        @('VS Code', 'user settings', (Join-Path $env:APPDATA 'Code\User'), 'Settings Sync, or copy settings.json / keybindings.json'),
        @('Google Drive for desktop', 'DriveFS', (Join-Path $env:LOCALAPPDATA 'Google\DriveFS'), 'Install and sign in; check folders marked "available offline"'),
        @('Dropbox', 'app data', (Join-Path $env:LOCALAPPDATA 'Dropbox'), 'Install and sign in'),
        @('Outlook', 'data files folder', (Join-Path $env:LOCALAPPDATA 'Microsoft\Outlook'), 'Microsoft 365 mail re-syncs; local .pst files must be copied'),
        @('QuickBooks Desktop', 'public company files folder', (Join-Path ($env:SystemDrive + '\') 'Users\Public\Documents\Intuit'), 'Use QuickBooks backup/restore (.qbb) - never copy an open company file')
    )
    foreach ($pz in $presence) {
        $detail = ''
        if (Test-Path -LiteralPath $pz[2] -PathType Container) { $detail = 'entries: ' + ((Get-ChildItem -LiteralPath $pz[2] -Force -ErrorAction SilentlyContinue | Select-Object -First 30 | ForEach-Object { $_.Name }) -join ', ') }
        Add-Cloud $pz[0] $pz[1] $pz[2] $detail $pz[3]
    }
    $vsx = Join-Path $home_ '.vscode\extensions'
    if (Test-Path -LiteralPath $vsx) { $exts = @(Get-ChildItem -LiteralPath $vsx -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^\.' } | ForEach-Object { $_.Name }); Add-Cloud 'VS Code' 'extensions (folder names)' $vsx ("$($exts.Count): " + ($exts -join ', ')) 'Settings Sync or reinstall from this list' }
    foreach ($sr in $SyncRoots) { Add-Cloud 'Cloud sync folder' 'sync root' $sr 'already stored at the cloud provider (online-only placeholders are NOT on this disk)' 'Sign in on the new laptop; make sure local-only files are uploaded first' }
    foreach ($kf in @(@('Desktop', [Environment]::GetFolderPath('Desktop')), @('Documents', [Environment]::GetFolderPath('MyDocuments')))) {
        foreach ($sr in $SyncRoots) { if (Test-UnderPath $kf[1] $sr) { Add-Cloud 'OneDrive Known Folder' $kf[0] $kf[1] "redirected into $sr" 'Folder content follows the OneDrive account' } }
    }
    $dockerExe = Get-AppPath 'docker.exe'
    if ($dockerExe) {
        $enginePipe = $false
        try { $enginePipe = @([IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -match '(?i)docker_engine' }).Count -gt 0 } catch { Write-AuditLog ('Docker engine check failed: ' + $_.Exception.Message) 'WARN' }
        if ($enginePipe) {
            $r = Invoke-External $dockerExe @('ps', '-a', '--format', '{{.Names}} | {{.Image}} | {{.Status}} | {{.Mounts}}') 30
            Add-Cloud 'Docker' 'containers' '' ((($r.StdOut -split "`r?`n") | Where-Object { $_ }) -join ' ;; ') 'Rebuild from compose files; export volumes that hold data'
        } else { Add-Cloud 'Docker' 'containers' '' 'Docker engine not running - containers not listed (Docker was NOT started)' 'Start Docker yourself and re-run if containers matter' }
    }
    $hostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (Test-Path -LiteralPath $hostsFile) { $custom = @(Get-Content -LiteralPath $hostsFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }); Add-Cloud 'Windows' 'hosts file custom entries' $hostsFile ($custom -join ' | ') 'Re-create entries that local development needs' }
    foreach ($md in @(Get-CimInstance Win32_MappedLogicalDisk -ErrorAction SilentlyContinue)) { Add-Cloud 'Network share' $md.DeviceID '' "$($md.ProviderName)" 'Re-map on the new laptop; files on the share are not part of this audit' }
    Save-Csv $script:Cloud 'cloud_and_tool_config.csv'

    $envRows = New-Object System.Collections.Generic.List[object]
    foreach ($scope in @('User', 'Machine')) {
        $vars = [Environment]::GetEnvironmentVariables($scope)
        foreach ($n in $vars.Keys) {
            $val = '<not recorded>'
            if ($n -match '(?i)^(path|pathext|psmodulepath|pythonpath|node_path|java_home|nvm_home|nvm_symlink|pyenv.*|onedrive.*|temp|tmp|chocolateyinstall|pm2_home|n8n_user_folder)$') { $val = Format-Safe "$($vars[$n])" }
            $envRows.Add([pscustomobject]@{ Scope = $scope; Name = $n; LooksSecret = (Test-SecretName $n); Value = $val })
        }
    }
    Save-Csv $envRows 'windows_environment_variable_NAMES.csv'
} catch { $fail = $_ }
Complete-Step $fail

# =====================================================================================
#  STEP 8 - verdict, summary, manifest
# =====================================================================================
$script:CurrentStep = '8 Summary'
if ($script:Counters.ContentSkippedSize -gt 0) { Add-Coverage 'Content scan' ('{0} files larger than {1} MB were listed but their content was not scanned.' -f $script:Counters.ContentSkippedSize, $MaxScanFileMB) $false }
if ($script:Counters.CloudOnlySkipped -gt 0) { Add-Coverage 'Cloud-only files' ('{0} online-only (cloud placeholder) files were listed but not opened, to avoid downloading them.' -f $script:Counters.CloudOnlySkipped) $false }
if ($script:Counters.ExcelUnreadable -gt 0) { Add-Coverage 'Excel' ('{0} workbooks are not standard packages (usually password-protected) and were listed without inspection.' -f $script:Counters.ExcelUnreadable) $false }
if ($script:Counters.LegacyXls -gt 0) { Add-Coverage 'Excel' ('{0} legacy .xls workbooks could not be inspected for macros/links.' -f $script:Counters.LegacyXls) $false }
$coverageGaps = @($script:Coverage | Where-Object { $_.AffectsCompleteness })
$failedSteps = @($script:Steps | Where-Object { $_.Status -eq 'FAILED' })
$partialSteps = @($script:Steps | Where-Object { $_.Status -eq 'PARTIAL' })
$reasons = New-Object System.Collections.Generic.List[string]
foreach ($s in $failedSteps) { $reasons.Add("Step '$($s.Step)' FAILED") }
foreach ($s in $partialSteps) { $reasons.Add("Step '$($s.Step)' PARTIAL ($($s.NewIssues) issues, $($s.CompletenessGaps) coverage gaps)") }
foreach ($c in @($coverageGaps | Where-Object { $_.Area -ne 'Search depth example' } | Select-Object -First 15)) { $reasons.Add("Coverage: $($c.Area) - $($c.Note)") }
if ($failedSteps.Count -gt 0) { $verdict = 'INCOMPLETE'; $exitCode = 1 }
elseif ($partialSteps.Count -gt 0 -or $coverageGaps.Count -gt 0 -or $script:Issues.Count -gt 0) { $verdict = 'PARTIAL'; $exitCode = 2 }
else { $verdict = 'COMPLETE'; $exitCode = 0 }
Save-Csv $script:Issues 'access_issues.csv'
Save-Csv $script:Coverage 'coverage_notes.csv'
Save-Csv $script:Steps 'step_status.csv'

function ConvertTo-IntSafe { param($Value) $n = 0; if ([int]::TryParse("$Value", [ref]$n)) { return $n }; return 0 }
$summary = [ordered]@{}
function Add-Summary {
    param([string]$Key, [scriptblock]$Value)
    try { $summary[$Key] = (& $Value) } catch { $summary[$Key] = 'not computed'; Add-Issue 'Summary' $Key $_.Exception.Message }
}
Add-Summary 'verdict' { $verdict }
Add-Summary 'reasons' { , @($reasons) }
Add-Summary 'computer' { $env:COMPUTERNAME }
Add-Summary 'auditTime' { $StartTime.ToString('s') }
Add-Summary 'scriptVersion' { $ScriptVersion }
Add-Summary 'durationMinutes' { [math]::Round(((Get-Date) - $StartTime).TotalMinutes, 1) }
Add-Summary 'runningAsAdmin' { $isAdmin }
Add-Summary 'searchRoots' { , @($script:Roots) }
Add-Summary 'maxDepth' { $MaxDepth }
Add-Summary 'projectsFound' { $script:ProjRows.Count }
Add-Summary 'claudeLinkedProjects' { @($script:ProjRows | Where-Object { $_.ClaudeEvidence }).Count }
Add-Summary 'projectsNotInGit' { @($script:ProjRows | Where-Object { -not $_.IsGit }).Count }
Add-Summary 'projectsWithUncommitted' { @($script:ProjRows | Where-Object { (ConvertTo-IntSafe $_.UncommittedChanges) -gt 0 }).Count }
Add-Summary 'projectsWithUnpushed' { @($script:ProjRows | Where-Object { ((ConvertTo-IntSafe $_.UnpushedCommits) + (ConvertTo-IntSafe $_.BranchesAhead)) -gt 0 }).Count }
Add-Summary 'secretFilesFound' { $script:SecretFiles.Count }
Add-Summary 'localDataFilesInProjects' { $script:DataFiles.Count }
Add-Summary 'hardcodedPathRefs' { $script:HardPaths.Count }
Add-Summary 'scheduledTasksNonMicrosoft' { $script:TaskRows.Count }
Add-Summary 'scheduledTasksCustom' { @($script:TaskRows | Where-Object { $_.Category -eq 'Custom' }).Count }
Add-Summary 'scheduledTasksCustomEnabled' { @($script:TaskRows | Where-Object { $_.Category -eq 'Custom' -and $_.State -ne 'Disabled' }).Count }
Add-Summary 'scheduledTasksXmlExported' { @($script:TaskRows | Where-Object { $_.XmlExported -eq 'Yes' }).Count }
Add-Summary 'standaloneScripts' { $script:Scripts.Count }
Add-Summary 'standaloneHtml' { $script:Html.Count }
Add-Summary 'excelWorkbooks' { $script:Excel.Count }
Add-Summary 'excelWithMacros' { @($script:Excel | Where-Object { $_.HasMacros -eq 'YES' }).Count }
Add-Summary 'excelWithExternalLinks' { @($script:Excel | Where-Object { (ConvertTo-IntSafe $_.ExternalLinkCount) -gt 0 }).Count }
Add-Summary 'excelNotStandardPackage' { $script:Counters.ExcelUnreadable }
Add-Summary 'importantDataFiles' { $script:DataOut.Count }
Add-Summary 'issues' { $script:Issues.Count }
Add-Summary 'coverageGaps' { $coverageGaps.Count }
Add-Summary 'steps' { , @($script:Steps) }
Save-Json $summary 'audit_summary.json'

$statusLines = @(
    "AUDIT VERDICT: $verdict", '',
    'COMPLETE   = every step finished with no errors and no coverage gaps.',
    'PARTIAL    = results are usable, but something could not be read or was out of scope (see reasons).',
    'INCOMPLETE = at least one step failed. Do not rely on this inventory; fix and re-run.', '',
    'Reasons:'
)
$statusLines += @($reasons | ForEach-Object { '  - ' + $_ })
$statusLines += @('', "Output folder: $OutputRoot",
    'SHAREABLE\             redacted results - review before sharing.',
    'PRIVATE_DO_NOT_UPLOAD\ raw task XML, identity map, secret-file hashes - keep offline, never upload.',
    'This script wrote only inside the output folder.')
try { [IO.File]::WriteAllText((Join-Path $OutputRoot 'AUDIT_STATUS.txt'), (Format-Safe ($statusLines -join "`r`n")), $Utf8Bom) } catch { Write-AuditLog ('AUDIT_STATUS.txt not written: ' + $_.Exception.Message) 'ERROR' }
try { [IO.File]::WriteAllText((Join-Path $Private 'README_DO_NOT_UPLOAD.txt'), "Raw data: scheduled task definitions, real user/computer names, secret-file hashes.`r`nDo not upload to GitHub, e-mail, chat or any cloud service. Keep it with the encrypted backup.`r`n", $Utf8Bom) } catch { Add-Issue 'Output' $Private ('README not written: ' + $_.Exception.Message) }
Write-AuditLog ('Verdict: {0}' -f $verdict) $(if ($verdict -eq 'COMPLETE') { 'STEP' } else { 'WARN' })

try {
    $manifest = @(Get-ChildItem -LiteralPath $OutputRoot -Recurse -File -Force | Where-Object { $_.Name -ne 'MANIFEST_SHA256.csv' } | ForEach-Object {
            [pscustomobject]@{ RelativePath = $_.FullName.Substring($OutputRoot.Length).TrimStart('\', '/'); SizeBytes = $_.Length; SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
        })
    [IO.File]::WriteAllText((Join-Path $OutputRoot 'MANIFEST_SHA256.csv'), ((@($manifest | ConvertTo-Csv -NoTypeInformation)) -join "`r`n"), $Utf8Bom)
} catch { Write-AuditLog ('manifest failed: ' + $_.Exception.Message) 'ERROR'; if ($exitCode -eq 0) { $exitCode = 2 } }

Write-Host ''
if ($verdict -eq 'COMPLETE') { Write-Host 'AUDIT COMPLETE - no errors and no coverage gaps.' -ForegroundColor Green }
elseif ($verdict -eq 'PARTIAL') { Write-Host 'AUDIT FINISHED WITH GAPS (PARTIAL). Do not treat this inventory as complete - read AUDIT_STATUS.txt.' -ForegroundColor Yellow }
else { Write-Host 'AUDIT INCOMPLETE - at least one step failed. Read AUDIT_STATUS.txt and audit_log.txt.' -ForegroundColor Red }
foreach ($rs in @($reasons | Select-Object -First 10)) { Write-Host ('  - ' + (Format-Safe $rs)) -ForegroundColor Yellow }
Write-Host ('Results: ' + (Format-Safe $OutputRoot))
if ($script:LogWriteFailures -gt 0) { Write-Host ("WARNING: {0} log lines could not be written to audit_log.txt" -f $script:LogWriteFailures) -ForegroundColor Red }
Write-Host 'Share at most the SHAREABLE folder, after reviewing it. Never upload PRIVATE_DO_NOT_UPLOAD.' -ForegroundColor Yellow
exit $exitCode
