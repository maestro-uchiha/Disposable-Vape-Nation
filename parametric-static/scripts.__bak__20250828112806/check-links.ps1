param(
  [string]$Root = $(Split-Path -Parent (Split-Path -Parent $PSCommandPath)),
  [switch]$External,              # also check http(s) links with HEAD/GET
  [int]$TimeoutSec = 8,           # external check timeout
  [switch]$Strict                 # if set, exit 1 on problems; otherwise warn-only
)

# Load config/helpers (PS 5.1-safe)
$__here  = Split-Path -Parent $PSCommandPath
. (Join-Path $__here "_lib.ps1")
$cfg   = Get-ASDConfig | ForEach-Object { $_ }  # avoid unrolling to $null
$null  = Get-ASDPaths  # parity with other scripts

$ErrorActionPreference = 'Stop'

# Paths
$site   = $Root
$layout = Join-Path $site 'layout.html'

# Collect .html files to scan (skip layout/partials/assets)
$files = Get-ChildItem -Path $site -Recurse -File -Include *.html |
  Where-Object {
    $_.FullName -ne $layout -and
    $_.FullName -notmatch '\\assets\\'   -and
    $_.FullName -notmatch '\\partials\\'
  }

# ===== Helpers =====

function Normalize-PathSafe {
  param([string]$Path, [string]$BaseDir)
  $p = $Path -replace '/', '\'
  if ([IO.Path]::IsPathRooted($p)) {
    return [IO.Path]::GetFullPath($p)
  } else {
    return [IO.Path]::GetFullPath((Join-Path $BaseDir $p))
  }
}

function Normalize-BaseUrlLocal([string]$b) {
  if ([string]::IsNullOrWhiteSpace($b)) { return "/" }
  $x = $b.Trim()
  $x = $x -replace '^/+(?=https?:)', ''
  $x = $x -replace '^((?:https?):)/{1,}', '$1//'
  $m = [regex]::Match($x, '^(https?://)(.+)$')
  if ($m.Success) {
    $x = $m.Groups[1].Value + $m.Groups[2].Value.TrimStart('/')
    if (-not $x.EndsWith('/')) { $x += '/' }
    return $x
  } else { return '/' + $x.Trim('/') + '/' }
}

function Get-RepoPathPrefix([string]$baseUrl) {
  if ([string]::IsNullOrWhiteSpace($baseUrl)) { return "" }
  $b = Normalize-BaseUrlLocal $baseUrl
  if ($b -match '^[a-z]+://') {
    try {
      $u = New-Object System.Uri($b)
      $p = $u.AbsolutePath
      if ([string]::IsNullOrWhiteSpace($p)) { return "" }
      $p = '/' + $p.Trim('/')    # "/repo"
      if ($p -eq "/") { return "" }
      return $p
    } catch { return "" }
  } else {
    $p = '/' + $b.Trim('/')      # "/repo"
    if ($p -eq "/") { return "" }
    return $p
  }
}

$repoPrefix = Get-RepoPathPrefix ($cfg.BaseUrl)

function Resolve-LinkPath {
  param(
    [string]$FromFile,
    [string]$Href
  )

  if ([string]::IsNullOrWhiteSpace($Href)) { return $null }

  # Ignore anchors & special schemes
  if ($Href -match '^(?i)(#|mailto:|tel:|javascript:|data:)') { return $null }

  # Protocol-relative -> treat as external
  if ($Href -match '^(?i)//') { return $Href }

  # External absolute
  if ($Href -match '^(?i)https?:') { return $Href }

  # Strip query/hash for local checks
  $clean = $Href -replace '\#.*$','' -replace '\?.*$',''
  if ([string]::IsNullOrWhiteSpace($clean)) { return $null }

  # Root-absolute vs relative
  if ($clean.StartsWith('/')) {
    # Remove GH Pages repo prefix if present
    $trimmed = $clean
    if (-not [string]::IsNullOrWhiteSpace($repoPrefix)) {
      if ($trimmed -eq $repoPrefix) { $trimmed = '/' }
      elseif ($trimmed.StartsWith($repoPrefix + '/')) { $trimmed = $trimmed.Substring($repoPrefix.Length) }
    }

    $rel  = $trimmed.TrimStart('/')
    $full = Normalize-PathSafe -Path $rel -BaseDir $site

    if ($trimmed.EndsWith('/')) { return (Join-Path $full 'index.html') }

    if (-not [IO.Path]::GetExtension($full)) {
      if (Test-Path $full -PathType Container) { return (Join-Path $full 'index.html') }
    }
    return $full
  } else {
    $dir  = Split-Path $FromFile -Parent
    $full = Normalize-PathSafe -Path $clean -BaseDir $dir

    if ($clean.EndsWith('/')) { return (Join-Path $full 'index.html') }

    if (-not [IO.Path]::GetExtension($full)) {
      if (Test-Path $full -PathType Container) { return (Join-Path $full 'index.html') }
    }
    return $full
  }
}

# Regexes (PS 5.1-safe)
$rxHref = [regex]'(?is)\bhref\s*=\s*["'']([^"''<>]+)["'']'
$rxSrc  = [regex]'(?is)\bsrc\s*=\s*["'']([^"''<>]+)["'']'

# Buckets
$broken         = New-Object System.Collections.Generic.List[string]
$externalFails  = New-Object System.Collections.Generic.List[string]

Write-Host "[links] Scanning HTML under: $site"

foreach ($f in $files) {
  $html = Get-Content $f.FullName -Raw

  # Collect candidate links (href + src)
  $hrefs = @()
  foreach ($m in $rxHref.Matches($html)) { $hrefs += $m.Groups[1].Value }
  foreach ($m in $rxSrc.Matches($html))  { $hrefs += $m.Groups[1].Value }

  # Unique
  $hrefs = $hrefs | Sort-Object -Unique

  foreach ($h in $hrefs) {
    $target = Resolve-LinkPath -FromFile $f.FullName -Href $h
    if ($null -eq $target) { continue }

    if ($target -match '^(?i)https?://') {
      if ($External) {
        try {
          $resp = Invoke-WebRequest -Uri $target -Method Head -TimeoutSec $TimeoutSec -MaximumRedirection 5 -ErrorAction Stop
          if (-not $resp.StatusCode -or $resp.StatusCode -ge 400) {
            $externalFails.Add(("{0} -> {1} (code {2})" -f ($f.FullName.Substring($site.Length+1).Replace('\','/')),$target,$resp.StatusCode)) | Out-Null
          }
        } catch {
          try {
            $resp2 = Invoke-WebRequest -Uri $target -Method Get -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 5 -ErrorAction Stop
            if (-not $resp2.StatusCode -or $resp2.StatusCode -ge 400) {
              $externalFails.Add(("{0} -> {1} (code {2})" -f ($f.FullName.Substring($site.Length+1).Replace('\','/')),$target,$resp2.StatusCode)) | Out-Null
            }
          } catch {
            $externalFails.Add(("{0} -> {1} (unreachable)" -f ($f.FullName.Substring($site.Length+1).Replace('\','/')),$target)) | Out-Null
          }
        }
      }
      continue
    }

    # Local existence
    if (-not (Test-Path $target -PathType Leaf)) {
      $ok = $false
      if (-not [IO.Path]::GetExtension($target)) {
        if (Test-Path $target -PathType Container) {
          $tryIdx = Join-Path $target 'index.html'
          if (Test-Path $tryIdx -PathType Leaf) { $ok = $true }
        }
      }
      if (-not $ok) {
        $relFile = ($f.FullName.Substring($site.Length+1)).Replace('\','/')
        $broken.Add(("{0} -> {1}" -f $relFile, $h)) | Out-Null
      }
    }
  }
}

# ===== Results =====
if ($broken.Count -gt 0) {
  Write-Host "`nBroken LOCAL links:" -ForegroundColor Yellow
  ($broken | Sort-Object -Unique) | ForEach-Object { Write-Host "  $_" }
} else {
  Write-Host "No broken local links found." -ForegroundColor Green
}

if ($External) {
  if ($externalFails.Count -gt 0) {
    Write-Host "`nExternal URL issues:" -ForegroundColor Yellow
    ($externalFails | Sort-Object -Unique) | ForEach-Object { Write-Host "  $_" }
  } else {
    Write-Host "External URLs look OK." -ForegroundColor Green
  }
}

# Exit code: default warn-only; use -Strict to fail builds/wizard
$hasLocal = ($broken.Count -gt 0)
$hasExt   = ($External -and $externalFails.Count -gt 0)
if ($Strict -and ($hasLocal -or $hasExt)) { exit 1 } else { exit 0 }
