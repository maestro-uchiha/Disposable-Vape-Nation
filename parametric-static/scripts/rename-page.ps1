# rename-page.ps1  (PS 5.1-safe, idempotent)
# Renames a *page* (non-blog) HTML file and optionally leaves (or removes) a redirect stub.
# Also upserts/removes an entry in redirects.json { from, to, code, enabled }.

#requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$OldPath,
  [Parameter(Mandatory = $true)][string]$NewPath,
  [switch]$LeaveRedirect
)

# Load helpers/config AFTER the param block (PS rule)
. (Join-Path $PSScriptRoot "_lib.ps1")
$S   = Get-ASDPaths
$cfg = Get-ASDConfig -Root $S.Root

# ---------- helpers ----------
function Normalize-RelHtml([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return "" }
  $p = ($p -replace '\\','/').Trim()
  if ($p -notlike '*.html') { $p += '.html' }
  # keep repo-relative paths (no leading slash)
  $p = $p.TrimStart('/')
  return $p
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
function Make-AbsUrl([string]$baseUrl, [string]$relPath) {
  $b = Normalize-BaseUrlLocal $baseUrl
  $rel = $relPath.TrimStart('/')
  if ($b -match '^[a-z]+://') {
    try { return (New-Object System.Uri((New-Object System.Uri($b)), $rel)).AbsoluteUri }
    catch { return ($b.TrimEnd('/') + '/' + $rel) }
  } else { return ($b.TrimEnd('/') + '/' + $rel) }
}
function Is-RedirectStub([string]$fullPath) {
  if (-not (Test-Path $fullPath)) { return $false }
  try {
    $raw = Get-Content $fullPath -Raw
    return ($raw -match '(?is)<!--\s*ASD:REDIRECT\b')
  } catch { return $false }
}
function HtmlEscape([string]$s){
  if ($null -eq $s) { return "" }
  $s = $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;'
  return $s
}
function JsEscape([string]$s){
  if ($null -eq $s) { return "" }
  return ($s -replace '\\','\\' -replace "'","\'")
}
function Upsert-Redirect([string]$from,[string]$to,[bool]$enabled){
  $redirPath = Join-Path $S.Root "redirects.json"
  $items = @()
  if (Test-Path $redirPath) {
    try {
      $raw = Get-Content $redirPath -Raw
      if (-not [string]::IsNullOrWhiteSpace($raw)) { $items = $raw | ConvertFrom-Json }
    } catch { $items = @() }
  }
  if ($null -eq $items) { $items = @() }

  $found = $false
  $newItems = @()
  foreach ($it in @($items)) {
    if ($it -and $it.PSObject.Properties.Name -contains 'from' -and ($it.from -eq $from)) {
      $it.to = $to
      if ($it.PSObject.Properties.Name -contains 'enabled') { $it.enabled = $enabled } else { Add-Member -InputObject $it -NotePropertyName enabled -NotePropertyValue $enabled -Force }
      if ($it.PSObject.Properties.Name -contains 'active')  { $it.active  = $enabled } # legacy
      if ($it.PSObject.Properties.Name -notcontains 'code') { Add-Member -InputObject $it -NotePropertyName code -NotePropertyValue 301 -Force }
      $found = $true
    }
    $newItems += ,$it
  }
  if (-not $found) {
    $newItems += ,([pscustomobject]@{ from=$from; to=$to; code=301; enabled=$enabled })
  }
  $newItems | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $redirPath
  if ($enabled) { Write-Host "[ASD] redirects.json: enabled mapping $from -> $to" } else { Write-Host "[ASD] redirects.json: disabled mapping for $from" }
}
function Remove-Redirect([string]$from){
  $redirPath = Join-Path $S.Root "redirects.json"
  if (-not (Test-Path $redirPath)) { return }
  try {
    $raw = Get-Content $redirPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $items = $raw | ConvertFrom-Json
  } catch { return }
  if ($null -eq $items) { return }
  $newItems = @()
  foreach ($it in @($items)) {
    if ($it -and $it.PSObject.Properties.Name -contains 'from' -and ($it.from -eq $from)) { continue }
    $newItems += ,$it
  }
  $newItems | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $redirPath
  Write-Host "[ASD] redirects.json: removed mapping for $from"
}

# ---------- normalize inputs ----------
$relOld = Normalize-RelHtml $OldPath
$relNew = Normalize-RelHtml $NewPath
if ([string]::IsNullOrWhiteSpace($relOld)) { Write-Error "OldPath is required."; exit 1 }
if ([string]::IsNullOrWhiteSpace($relNew)) { Write-Error "NewPath is required."; exit 1 }

$fsOld = Join-Path $S.Root $relOld
$fsNew = Join-Path $S.Root $relNew

$fromMap = "/" + $relOld
$toMap   = "/" + $relNew

$oldExists = Test-Path $fsOld
$newExists = Test-Path $fsNew
$oldIsStub = if ($oldExists) { Is-RedirectStub $fsOld } else { $false }

# ---------- idempotent / edge cases ----------
if (-not $oldExists -and $newExists) {
  if ($LeaveRedirect) {
    $dirOld = Split-Path -Parent $fsOld
    if (-not (Test-Path $dirOld)) { New-Item -ItemType Directory -Force -Path $dirOld | Out-Null }
    $abs = Make-AbsUrl $cfg.BaseUrl $relNew
    $html = @"
<!doctype html><html lang="en"><head>
<meta charset="utf-8"><title>Redirecting…</title>
<meta name="robots" content="noindex">
<meta http-equiv="refresh" content="0;url=$(HtmlEscape $abs)">
<script>location.replace('$(JsEscape $abs)');</script>
</head><body>
<!-- ASD:REDIRECT to="$(HtmlEscape $abs)" code="301" -->
<p>If you are not redirected, <a href="$(HtmlEscape $abs)">click here</a>.</p>
</body></html>
"@
    Set-Content -Encoding UTF8 $fsOld $html
    Upsert-Redirect $fromMap $toMap $true
    Write-Host "[ASD] Created redirect stub at $relOld -> $abs"
  } else {
    Write-Host "[ASD] Page already at new path; no redirect requested."
  }
  Write-Host "[ASD] Done."
  exit 0
}

if ($newExists -and -not $oldIsStub -and $oldExists) {
  Write-Error "Target already exists: $relNew"
  exit 1
}

if ($oldIsStub -and $newExists) {
  if ($LeaveRedirect) {
    $abs = Make-AbsUrl $cfg.BaseUrl $relNew
    $html = @"
<!doctype html><html lang="en"><head>
<meta charset="utf-8"><title>Redirecting…</title>
<meta name="robots" content="noindex">
<meta http-equiv="refresh" content="0;url=$(HtmlEscape $abs)">
<script>location.replace('$(JsEscape $abs)');</script>
</head><body>
<!-- ASD:REDIRECT to="$(HtmlEscape $abs)" code="301" -->
<p>If you are not redirected, <a href="$(HtmlEscape $abs)">click here</a>.</p>
</body></html>
"@
    Set-Content -Encoding UTF8 $fsOld $html
    Upsert-Redirect $fromMap $toMap $true
    Write-Host "[ASD] Updated redirect stub at $relOld -> $abs"
  } else {
    try { Remove-Item -Force $fsOld } catch {}
    Remove-Redirect $fromMap
    Write-Host "[ASD] Removed old redirect stub: $relOld"
  }
  Write-Host "[ASD] Done."
  exit 0
}

# ---------- normal rename flow ----------
if (-not $oldExists) { Write-Error "Source not found: $relOld"; exit 1 }

$dirNew = Split-Path -Parent $fsNew
if (-not (Test-Path $dirNew)) { New-Item -ItemType Directory -Force -Path $dirNew | Out-Null }

Move-Item -Force $fsOld $fsNew
Write-Host ("[ASD] Renamed {0} -> {1}" -f $relOld, $relNew)

if ($LeaveRedirect) {
  $abs = Make-AbsUrl $cfg.BaseUrl $relNew
  $html = @"
<!doctype html><html lang="en"><head>
<meta charset="utf-8"><title>Redirecting…</title>
<meta name="robots" content="noindex">
<meta http-equiv="refresh" content="0;url=$(HtmlEscape $abs)">
<script>location.replace('$(JsEscape $abs)');</script>
</head><body>
<!-- ASD:REDIRECT to="$(HtmlEscape $abs)" code="301" -->
<p>If you are not redirected, <a href="$(HtmlEscape $abs)">click here</a>.</p>
</body></html>
"@
  $dirOld = Split-Path -Parent $fsOld
  if (-not (Test-Path $dirOld)) { New-Item -ItemType Directory -Force -Path $dirOld | Out-Null }
  Set-Content -Encoding UTF8 $fsOld $html
  Upsert-Redirect $fromMap $toMap $true
  Write-Host ("[ASD] Redirect stub left at {0} -> {1}" -f $relOld, $abs)
} else {
  Remove-Redirect $fromMap
}

Write-Host "[ASD] Done."
