# rename-post.ps1  (PS 5.1-safe, idempotent)
# Renames a blog post and optionally leaves (or removes) a redirect stub.
# Also upserts/removes an entry in redirects.json { from, to, code, enabled }.
# Manual $args parsing so wizard oddities (blank NewSlug) don't crash binding.

# Load helpers/config
. (Join-Path $PSScriptRoot "_lib.ps1")
$S   = Get-ASDPaths
$cfg = Get-ASDConfig -Root $S.Root

# ---------- manual arg parse ----------
$OldSlug = $null
$NewSlug = $null
$LeaveRedirect = $false
for ($i = 0; $i -lt $args.Count; $i++) {
  $t = [string]$args[$i]
  if ([string]::IsNullOrWhiteSpace($t)) { continue }
  switch -regex ($t) {
    '^(?i)-OldSlug$'      { if ($i+1 -lt $args.Count -and -not ([string]$args[$i+1]).StartsWith('-')) { $OldSlug = [string]$args[++$i] }; continue }
    '^(?i)-NewSlug$'      { if ($i+1 -lt $args.Count -and -not ([string]$args[$i+1]).StartsWith('-')) { $NewSlug = [string]$args[++$i] } else { $NewSlug = "" }; continue }
    '^(?i)-LeaveRedirect(?::(true|false))?$' {
      if ($matches[1]) { $LeaveRedirect = ([string]::Equals($matches[1],'true',[System.StringComparison]::OrdinalIgnoreCase)) } else { $LeaveRedirect = $true }
      continue
    }
    default {
      if (-not $t.StartsWith('-')) {
        if ($null -eq $OldSlug) { $OldSlug = $t; continue }
        if ($null -eq $NewSlug) { $NewSlug = $t; continue }
      }
    }
  }
}

# ---------- helpers ----------
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
function Clean-Slug([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return "" }
  $name = [IO.Path]::GetFileName($s.Trim())
  if ($name -like '*.html') { $name = [IO.Path]::GetFileNameWithoutExtension($name) }
  return $name.Trim()
}
function Make-AbsBlogUrl([string]$baseUrl, [string]$slugNoExt) {
  $b = Normalize-BaseUrlLocal $baseUrl
  if ($b -match '^[a-z]+://') {
    try { return (New-Object System.Uri((New-Object System.Uri($b)), ('blog/' + $slugNoExt + '.html'))).AbsoluteUri }
    catch { return ($b.TrimEnd('/') + '/blog/' + $slugNoExt + '.html') }
  } else { return ($b.TrimEnd('/') + '/blog/' + $slugNoExt + '.html') }
}
function Is-RedirectStub([string]$path) {
  if (-not (Test-Path $path)) { return $false }
  try {
    $raw = Get-Content $path -Raw
    return ($raw -match '(?is)<!--\s*ASD:REDIRECT\b')
  } catch { return $false }
}
function Upsert-Redirect([string]$from, [string]$to, [bool]$enabled) {
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
      # update existing mapping
      $it.to      = $to
      # prefer 'enabled'; if legacy 'active' exists, update both
      if ($it.PSObject.Properties.Name -contains 'enabled') { $it.enabled = $enabled } else { Add-Member -InputObject $it -NotePropertyName enabled -NotePropertyValue $enabled -Force }
      if ($it.PSObject.Properties.Name -contains 'active')  { $it.active  = $enabled }
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
function Remove-Redirect([string]$from) {
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
$OldSlug = Clean-Slug $OldSlug
$NewSlug = Clean-Slug $NewSlug

if ([string]::IsNullOrWhiteSpace($OldSlug)) { Write-Error "OldSlug is required."; exit 1 }
if ([string]::IsNullOrWhiteSpace($NewSlug)) { Write-Error "NewSlug is empty. Re-run without a trailing space."; exit 1 }

$src = Join-Path $S.Blog ($OldSlug + ".html")
$dst = Join-Path $S.Blog ($NewSlug + ".html")
$from = "/blog/$OldSlug.html"
$to   = "/blog/$NewSlug.html"

$srcExists = Test-Path $src
$dstExists = Test-Path $dst
$srcIsStub = $false
if ($srcExists) { $srcIsStub = Is-RedirectStub $src }

# ---------- idempotent cases ----------
if ($dstExists -and $srcIsStub) {
  # Already renamed earlier; old file is a stub.
  if ($LeaveRedirect) {
    # Ensure stub points to correct target + mapping is enabled
    $abs = Make-AbsBlogUrl $cfg.BaseUrl $NewSlug
    $jsu = ($abs -replace '\\','\\' -replace "'","\'")
    $stub = @"
<!doctype html><html lang="en"><head>
  <meta charset="utf-8">
  <title>Redirecting…</title>
  <meta name="robots" content="noindex">
  <meta http-equiv="refresh" content="0;url=$abs">
  <script>location.replace('$jsu');</script>
</head><body>
  <!-- ASD:REDIRECT to="$abs" code="301" -->
  <p>If you are not redirected, <a href="$abs">click here</a>.</p>
</body></html>
"@
    Set-Content -Encoding UTF8 $src $stub
    Upsert-Redirect $from $to $true
    Write-Host "[ASD] No move needed; kept/updated redirect stub at blog/$OldSlug.html"
    Write-Host "[ASD] Done."
    exit 0
  } else {
    # Remove the stub and disable/remove mapping
    Remove-Item -Force $src
    Remove-Redirect $from
    Write-Host "[ASD] Removed redirect stub blog/$OldSlug.html and mapping."
    Write-Host "[ASD] Done."
    exit 0
  }
}

if (-not $srcExists -and $dstExists) {
  # Already renamed and no stub at old path.
  if ($LeaveRedirect) {
    # User wants a stub now; create it at old path
    $abs = Make-AbsBlogUrl $cfg.BaseUrl $NewSlug
    $jsu = ($abs -replace '\\','\\' -replace "'","\'")
    $stub = @"
<!doctype html><html lang="en"><head>
  <meta charset="utf-8">
  <title>Redirecting…</title>
  <meta name="robots" content="noindex">
  <meta http-equiv="refresh" content="0;url=$abs">
  <script>location.replace('$jsu');</script>
</head><body>
  <!-- ASD:REDIRECT to="$abs" code="301" -->
  <p>If you are not redirected, <a href="$abs">click here</a>.</p>
</body></html>
"@
    Set-Content -Encoding UTF8 $src $stub
    Upsert-Redirect $from $to $true
    Write-Host "[ASD] Post already at new slug; created redirect stub at old slug."
  } else {
    Write-Host "[ASD] Post already renamed; no redirect requested. Nothing to do."
  }
  Write-Host "[ASD] Done."
  exit 0
}

if ($dstExists -and -not $srcIsStub -and $srcExists) {
  Write-Error "Target already exists: $dst"
  exit 1
}

# ---------- normal rename flow ----------
if (-not $srcExists) { Write-Error "Source not found: $src"; exit 1 }

Move-Item -Force $src $dst
Write-Host ("[ASD] Renamed blog/{0}.html -> blog/{1}.html" -f $OldSlug, $NewSlug)

if ($LeaveRedirect) {
  $abs = Make-AbsBlogUrl $cfg.BaseUrl $NewSlug
  $jsu = ($abs -replace '\\','\\' -replace "'","\'")
  $stub = @"
<!doctype html><html lang="en"><head>
  <meta charset="utf-8">
  <title>Redirecting…</title>
  <meta name="robots" content="noindex">
  <meta http-equiv="refresh" content="0;url=$abs">
  <script>location.replace('$jsu');</script>
</head><body>
  <!-- ASD:REDIRECT to="$abs" code="301" -->
  <p>If you are not redirected, <a href="$abs">click here</a>.</p>
</body></html>
"@
  Set-Content -Encoding UTF8 $src $stub
  Upsert-Redirect $from $to $true
  Write-Host ("[ASD] Redirect stub left at blog/{0}.html -> {1}" -f $OldSlug, $abs)
} else {
  Remove-Redirect $from  # ensure no stale mapping
}

Write-Host "[ASD] Done."
