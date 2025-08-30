# parametric-static/scripts/redirects.ps1
param(
  [switch]$Add,
  [switch]$List,
  [switch]$Disable,
  [switch]$Enable,
  [switch]$Remove,
  [switch]$RebuildStubs,
  [int]$Index = -1,
  [string]$From,
  [string]$To,
  [int]$Code = 301,
  [string]$File
)

# ---------------- env / paths ----------------
$__here = Split-Path -Parent $PSCommandPath
. (Join-Path $__here "_lib.ps1")
$paths = Get-ASDPaths
$Root  = $paths.Root

$DefaultFile = Join-Path $Root "redirects.json"
if (-not $File) { $File = $DefaultFile }

# ---------------- helpers ----------------

function New-ArrayList { New-Object System.Collections.ArrayList }

function To-ArrayList { param($x)
  $list = New-ArrayList
  if ($null -eq $x) { return $list }
  if ($x -is [System.Collections.IEnumerable] -and -not ($x -is [string])) { foreach ($i in $x) { [void]$list.Add($i) } }
  else { [void]$list.Add($x) }
  return $list
}

function Ensure-ArrayList { param($x)
  if ($x -is [System.Collections.ArrayList]) { return $x }
  return (To-ArrayList $x)
}

function Append-Item { param($list, $item)
  $out = New-ArrayList
  foreach ($i in (To-ArrayList $list)) { [void]$out.Add($i) }
  [void]$out.Add($item)
  return $out
}

function Get-Count { param($x)
  if ($null -eq $x) { return 0 }
  if ($x -is [System.Collections.ICollection]) { return $x.Count }
  if ($x -is [System.Array]) { return $x.Length }
  if ($x -is [System.Collections.IEnumerable] -and -not ($x -is [string])) { $n=0; foreach($i in $x){$n++}; return $n }
  return 1
}

function Fix-Urlish([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $s }
  $s = $s.Trim()
  # Fix single-slash schemes: https:/... -> https://...
  $s = $s -replace '^((?:https?|HTTP|Http):)/(?=[^/])', '$1//'
  return $s
}

function Normalize-Pathish([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $p }
  $p = Fix-Urlish $p
  if ($p -match '^(https?://)') { return $p }
  if (-not $p.StartsWith('/')) { $p = '/' + $p }
  return $p
}

function Strip-Query([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $p }
  $ix = $p.IndexOf('?')
  if ($ix -gt -1) { return $p.Substring(0,$ix) }
  return $p
}

# --- Config helpers (read BaseUrl and ensure a trailing slash) ---
function Read-ASDConfig {
  $cfgPath = Join-Path $Root "parametric-static/config.json"
  if (-not (Test-Path $cfgPath)) { return $null }
  try {
    $raw = Get-Content $cfgPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json -ErrorAction Stop)
  } catch { return $null }
}

function Get-BaseUrl {
  $cfg = Read-ASDConfig
  if ($null -eq $cfg -or [string]::IsNullOrWhiteSpace($cfg.BaseUrl)) { return "" }
  $b = [string]$cfg.BaseUrl
  # ensure trailing slash
  if (-not $b.EndsWith('/')) { $b = $b + '/' }
  return $b
}

function Join-Url($base, $path) {
  if ([string]::IsNullOrWhiteSpace($base)) { return $path }
  $base = $base.TrimEnd('/')
  $path = [string]$path
  if ($path.StartsWith('/')) { $path = $path.Substring(1) }
  return ($base + '/' + $path)
}

# Return a FINAL ABSOLUTE URL for the stub target.
# Rules:
# - If $toPath is absolute (http/https), return as-is (after Fix-Urlish).
# - Otherwise, prepend config BaseUrl (which may include a repo subpath for GH Pages).
function Make-AbsoluteUrl([string]$toPath) {
  $toPath = Fix-Urlish $toPath
  if ($toPath -match '^(https?://)') { return $toPath }
  $base = Get-BaseUrl
  if ([string]::IsNullOrWhiteSpace($base)) {
    # Fallback: treat rooted as-is
    return (Normalize-Pathish $toPath)
  }
  # If the user gave "/blog/new.html", glue to BaseUrl path ONLY once
  if ($toPath.StartsWith('/')) { return (Join-Url $base $toPath) }
  return (Join-Url $base ('/' + $toPath))
}

function Migrate-Entry { param($r)
  if ($null -eq $r) { return $r }
  # old -> new: disabled => enabled
  if ($r.PSObject.Properties.Name -contains 'disabled' -and -not ($r.PSObject.Properties.Name -contains 'enabled')) {
    $enabled = -not ([bool]$r.disabled)
    if ($r.PSObject.Properties.Name -contains 'enabled') { $r.enabled = $enabled }
    else { Add-Member -InputObject $r -NotePropertyName enabled -NotePropertyValue $enabled -Force | Out-Null }
    try { $r.PSObject.Properties.Remove('disabled') | Out-Null } catch {}
  }
  if (-not ($r.PSObject.Properties.Name -contains 'enabled')) {
    Add-Member -InputObject $r -NotePropertyName enabled -NotePropertyValue $true -Force | Out-Null
  }
  if (-not ($r.PSObject.Properties.Name -contains 'code')) {
    Add-Member -InputObject $r -NotePropertyName code -NotePropertyValue 301 -Force | Out-Null
  }

  # sanitize from/to
  if ($r.PSObject.Properties.Match('from').Count -gt 0 -and $r.from) { $r.from = Normalize-Pathish ([string]$r.from) }
  if ($r.PSObject.Properties.Match('to').Count   -gt 0 -and $r.to)   { $r.to   = Fix-Urlish ([string]$r.to) } # don't force leading slash here; Make-AbsoluteUrl handles both
  return $r
}

function Load-Redirects { param([string]$path)
  if (-not (Test-Path $path)) { return (New-ArrayList) }
  try {
    $raw = Get-Content $path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return (New-ArrayList) }
    if ($raw -notmatch '^\s*[\[\{]') { throw "Not JSON" }
    $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    $arr = To-ArrayList $obj
    $out = New-ArrayList
    foreach ($e in $arr) { [void]$out.Add((Migrate-Entry $e)) }
    return $out
  } catch {
    Write-Warning "[redirects] Could not parse $path; backing up and starting fresh. $($_.Exception.Message)"
    try { Copy-Item $path ($path + ".corrupt.bak") -Force } catch {}
    return (New-ArrayList)
  }
}

function Save-Redirects { param($items, [string]$path)
  $items = Ensure-ArrayList $items
  $dir = Split-Path -Parent $path
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $ary = @(); foreach ($i in $items) { $ary += ,$i }  # force array, keep order
  $json = ConvertTo-Json -InputObject $ary -Depth 6
  Set-Content -Encoding UTF8 $path $json
  Write-Host "[redirects] Saved -> $path"
}

function Get-StubPath {
  param([string]$fromPath)
  $rel = Strip-Query $fromPath
  if ($rel.StartsWith('/')) { $rel = $rel.Substring(1) }
  if ([string]::IsNullOrWhiteSpace($rel)) { $rel = "index.html" }
  $fs = Join-Path $Root $rel
  if ($fs.ToLower().EndsWith(".html")) { return $fs }
  return (Join-Path $fs "index.html")
}

function Remove-Stub {
  param([string]$fromPath)
  $stub = Get-StubPath $fromPath
  if (Test-Path $stub) {
    try { Remove-Item -LiteralPath $stub -Force } catch {}
  }
}

function Write-Stub {
  param([string]$fromPath, [string]$toPath, [int]$code = 301)
  $absolute = Make-AbsoluteUrl $toPath   # <— now uses BaseUrl for rooted/relative paths
  $stub  = Get-StubPath $fromPath
  $dir   = Split-Path -Parent $stub
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

  $html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Redirecting…</title>
  <meta http-equiv="refresh" content="0; url=$absolute">
  <meta name="robots" content="noindex,nofollow">
  <script>
    (function(){
      var u = "$absolute";
      try { if (window.location && window.location.replace) { window.location.replace(u); return; } } catch(e) {}
      window.location.href = u;
    })();
  </script>
  <noscript><meta http-equiv="refresh" content="0; url=$absolute"></noscript>
</head>
<body></body>
</html>
"@
  Set-Content -Encoding UTF8 -LiteralPath $stub $html
  Write-Host "[redirects] stub -> $stub"
}

function Validate-Index { param([int]$i, $arr)
  $list  = Ensure-ArrayList $arr
  $count = Get-Count $list
  if ($i -lt 0 -or $i -ge $count) {
    Write-Error "Index out of range. Use -List to see entries." ; exit 1
  }
}

function Rebuild-AllStubs {
  param($items)
  $items = Ensure-ArrayList $items
  foreach ($r in $items) { if ($r.from) { Remove-Stub $r.from } }
  foreach ($r in $items) {
    if ($r.enabled -and $r.from -and $r.to) { Write-Stub $r.from $r.to $r.code }
  }
}

# ---------------- load ----------------
$items = Ensure-ArrayList (Load-Redirects -path $File)

# ---------------- ops -----------------

if ($Add) {
  if ([string]::IsNullOrWhiteSpace($From) -or [string]::IsNullOrWhiteSpace($To)) {
    Write-Error 'Use -Add -From "/old" -To "/new" or -To "https://domain/path" [-Code 301]' ; exit 1
  }
  $From = Normalize-Pathish $From
  $To   = Fix-Urlish $To
  if ($From -notmatch '^(\/|https?://)') { Write-Error '-From must start with "/" or "http(s)://".' ; exit 1 }
  if (($To -notmatch '^(\/|https?://)') -and ($To -notmatch '^[^/].*')) { Write-Error '-To must be rooted ("/x") or absolute ("http(s)://") or relative ("x").' ; exit 1 }
  if ($Code -notin 301,302,307,308) { $Code = 301 }

  $new = [pscustomobject]@{ from=$From; to=$To; code=$Code; enabled=$true }
  $items = Append-Item $items $new

  Save-Redirects -items $items -path $File
  Write-Stub -fromPath $From -toPath $To -code $Code
  Write-Host "[redirects] added: $From -> $To (code $Code)"
  Write-Host ("[redirects] total: {0}" -f (Get-Count $items))
  exit 0
}

if ($List) {
  Write-Host "[redirects] entries:"
  $items = Ensure-ArrayList $items
  $count = Get-Count $items
  if ($count -eq 0) { Write-Host "  (none)"; exit 0 }
  for ($i = 0; $i -lt $count; $i++) {
    $r = $items[$i]
    $state = if ($r.PSObject.Properties.Match('enabled').Count -gt 0 -and $r.enabled -eq $false) { "DISABLED" } else { "ENABLED" }
    $code  = if ($r.PSObject.Properties.Match('code').Count -gt 0 -and $r.code) { $r.code } else { 301 }
    $from  = if ($r.PSObject.Properties.Match('from').Count -gt 0) { $r.from } else { "(missing from)" }
    $to    = if ($r.PSObject.Properties.Match('to').Count   -gt 0) { $r.to }   else { "(missing to)" }
    Write-Host ("  #{0}: {1} -> {2}  (code {3}, {4})" -f $i, $from, $to, $code, $state)
  }
  Write-Host ("[redirects] total: {0}" -f $count)
  exit 0
}

if ($Disable) {
  Validate-Index -i $Index -arr $items
  if ($null -eq $items[$Index].PSObject.Properties['enabled']) {
    Add-Member -InputObject $items[$Index] -NotePropertyName enabled -NotePropertyValue $true -Force | Out-Null
  }
  $items[$Index].enabled = $false
  Save-Redirects -items $items -path $File
  Remove-Stub $items[$Index].from
  Write-Host ("[redirects] disabled #{0}: {1} -> {2}" -f $Index, $items[$Index].from, $items[$Index].to)
  exit 0
}

if ($Enable) {
  Validate-Index -i $Index -arr $items
  if ($null -eq $items[$Index].PSObject.Properties['enabled']) {
    Add-Member -InputObject $items[$Index] -NotePropertyName enabled -NotePropertyValue $true -Force | Out-Null
  }
  $items[$Index].enabled = $true
  Save-Redirects -items $items -path $File
  if ($items[$Index].from -and $items[$Index].to) {
    Write-Stub $items[$Index].from $items[$Index].to $items[$Index].code
  }
  Write-Host ("[redirects] enabled #{0}: {1} -> {2}" -f $Index, $items[$Index].from, $items[$Index].to)
  exit 0
}

if ($Remove) {
  Validate-Index -i $Index -arr $items
  $removed = $items[$Index]
  $newList = New-ArrayList
  for ($i = 0; $i -lt (Get-Count $items); $i++) {
    if ($i -ne $Index) { [void]$newList.Add($items[$i]) }
  }
  $items = $newList
  Save-Redirects -items $items -path $File
  if ($removed -and $removed.from) { Remove-Stub $removed.from }
  if ($removed) {
    Write-Host ("[redirects] removed #{0}: {1} -> {2}" -f $Index, $removed.from, $removed.to)
  } else {
    Write-Host ("[redirects] removed #{0}" -f $Index)
  }
  Write-Host ("[redirects] total: {0}" -f (Get-Count $items))
  exit 0
}

if ($RebuildStubs) {
  Rebuild-AllStubs -items $items
  Write-Host "[redirects] stubs rebuilt."
  exit 0
}

Write-Host @"
Usage:
  redirects.ps1 -Add -From "/old" -To "/new" [-Code 301]
  redirects.ps1 -List
  redirects.ps1 -Disable -Index N
  redirects.ps1 -Enable  -Index N
  redirects.ps1 -Remove  -Index N
  redirects.ps1 -RebuildStubs
  (optional) -File <path\to\redirects.json>
"@
exit 0
