# pull-template.ps1  (PowerShell 5.1-safe)
# Sync your site's ASD tooling from a template repo.
# - Accepts normal repo URLs, local paths, AND GitHub "tree" URLs.
# - Copies:   parametric-static\scripts\  and  parametric-static\_lib.ps1
# - Optional: -SyncLayout (copies layout.html to site root)
# - Optional: -IncludeAssets (copies parametric-static\assets\)
# - Never touches your blog/drafts/content unless you explicitly copy assets.

param(
  [Parameter(Mandatory=$true)][string]$TemplateRepo,
  [string]$Branch = "main",
  [string]$TemplateSubdir,
  [switch]$SyncLayout,
  [switch]$IncludeAssets,
  [switch]$NoBackup
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Info([string]$m){ Write-Host $m }
function Fail([string]$m){ Write-Error $m; exit 1 }

# --- This script lives in parametric-static\scripts
$ScriptsDir    = Split-Path -Parent $PSCommandPath
$ParametricDir = Split-Path -Parent $ScriptsDir
$SiteRoot      = Split-Path -Parent $ParametricDir

# --- Ensure git is available
try { $null = (& git --version) 2>$null; $gitOk = ($LASTEXITCODE -eq 0) } catch { $gitOk = $false }
if (-not $gitOk) { Fail "git is not installed or not on PATH." }

# --- Parse GitHub 'tree' URLs like:
#     https://github.com/<owner>/<repo>/tree/<branch>/<subdir...>
function Parse-GitHubTreeUrl([string]$u){
  if ([string]::IsNullOrWhiteSpace($u)) { return $null }
  $rx = [regex]'^(?i)https?://github\.com/([^/]+)/([^/]+)/(tree|blob)/([^/]+)/(.*)$'
  $m  = $rx.Match($u.Trim())
  if ($m.Success) {
    $owner  = $m.Groups[1].Value
    $repo   = $m.Groups[2].Value
    $branch = $m.Groups[4].Value
    $subdir = $m.Groups[5].Value
    return [pscustomobject]@{
      Repo   = "https://github.com/$owner/$repo.git"
      Branch = $branch
      Subdir = $subdir
    }
  }
  return $null
}

# --- Normalize TemplateRepo/Branch/Subdir if user pasted a 'tree' URL
$parsed = Parse-GitHubTreeUrl $TemplateRepo
if ($parsed -ne $null) {
  if ([string]::IsNullOrWhiteSpace($TemplateSubdir)) { $TemplateSubdir = $parsed.Subdir }
  if ($Branch -eq "main" -and -not [string]::IsNullOrWhiteSpace($parsed.Branch)) { $Branch = $parsed.Branch }
  $TemplateRepo = $parsed.Repo
}

Info "[sync] SiteRoot:        $SiteRoot"
Info "[sync] ParametricDir:   $ParametricDir"
Info "[sync] TemplateRepo:    $TemplateRepo ($Branch)"
if ($TemplateSubdir) { Info "[sync] TemplateSubdir: $TemplateSubdir" }

# --- Temp clone
$temp = Join-Path $env:TEMP ("asd-tmpl-" + ([Guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Force -Path $temp | Out-Null

Info ""
Info "[sync] Cloning template..."
& git clone --depth 1 --branch $Branch -- $TemplateRepo $temp
if ($LASTEXITCODE -ne 0) { Fail "Clone failed." }

# --- Determine source folder for copying
$src = $temp
if (-not [string]::IsNullOrWhiteSpace($TemplateSubdir)) {
  $src = Join-Path $temp $TemplateSubdir
  if (-not (Test-Path $src)) { Fail "Subfolder not found in template: $TemplateSubdir" }
}

# --- Helpers (PS 5.1-safe)
function Ensure-Dir([string]$p){
  if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
}
function Timestamp(){ Get-Date -Format 'yyyyMMddHHmmss' }

function Backup-Path([string]$path){
  if ($NoBackup) { return $null }
  if (-not (Test-Path $path)) { return $null }
  $bak = $path + ".__bak__" + (Timestamp)
  try {
    if ((Get-Item $path).PSIsContainer) { Move-Item -Force -LiteralPath $path -Destination $bak }
    else { Copy-Item -Force -LiteralPath $path -Destination $bak }
    Info "[sync] backup -> $bak"
    return $bak
  } catch { return $null }
}

function Copy-Tree([string]$from,[string]$to){
  Ensure-Dir (Split-Path -Parent $to)
  if (Test-Path $to) { Remove-Item -Recurse -Force -LiteralPath $to }
  Copy-Item -Recurse -Force -LiteralPath $from -Destination $to
}

function Copy-SelectedItems([string]$fromRoot,[string]$toRoot,[string[]]$relativePaths){
  foreach($rel in $relativePaths){
    if ([string]::IsNullOrWhiteSpace($rel)) { continue }
    $srcPath = Join-Path $fromRoot $rel
    $dstPath = Join-Path $toRoot   $rel
    if (-not (Test-Path $srcPath)) { continue }
    if (Test-Path $dstPath) { $null = Backup-Path $dstPath }
    Copy-Tree -from $srcPath -to $dstPath
    Info ("[sync] copied  -> " + $rel)
  }
}

# --- What to copy by default from template subdir
$includes = @('scripts','_lib.ps1')
if ($IncludeAssets) { $includes += 'assets' }

Info ""
Info "[sync] Updating tooling under parametric-static\ ..."
Copy-SelectedItems -fromRoot $src -toRoot $ParametricDir -relativePaths $includes

# --- Optionally sync layout.html to site root
if ($SyncLayout) {
  $layoutSrc = Join-Path $src 'layout.html'
  if (Test-Path $layoutSrc) {
    $layoutDst = Join-Path $SiteRoot 'layout.html'
    if (Test-Path $layoutDst) { $null = Backup-Path $layoutDst }
    Copy-Item -Force -LiteralPath $layoutSrc -Destination $layoutDst
    Info "[sync] layout.html synced to site root."
  } else {
    Info "[sync] layout.html not found in template; skipped."
  }
}

# --- Cleanup
try { Remove-Item -Recurse -Force -LiteralPath $temp } catch {}

Info ""
Info "[sync] Done. Re-run your bake if needed:"
Info "       powershell -ExecutionPolicy Bypass -File parametric-static\scripts\bake.ps1"
exit 0
