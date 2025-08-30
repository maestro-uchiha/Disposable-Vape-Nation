# delete-page.ps1  (PS 5.1-safe)
# Deletes a non-blog page (e.g., about.html or legal/privacy.html) from the site root.
# - Uses _lib.ps1 for paths/config
# - Protects critical files (layout.html, root index.html) and folders (blog/, assets/, partials/, parametric-static/)
# - Accepts path with or without ".html" and with "/" or "\" separators
# - Cleans up empty parent directories (if they become empty after deletion)

#requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$Path
)

Set-StrictMode -Version 2.0

# Load helpers/config
. (Join-Path $PSScriptRoot "_lib.ps1")
$S   = Get-ASDPaths
$cfg = Get-ASDConfig -Root $S.Root

function Normalize-RelPath([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $null }
  $x = $p.Trim()
  # normalize slashes
  $x = $x -replace '\\','/'
  # drop leading "./" or "/"
  $x = $x -replace '^(?:\./|/)+',''
  # collapse duplicate slashes
  $x = $x -replace '/{2,}','/'

  # if they provided a folder-ish thing (trailing slash), strip trailing slash
  if ($x.EndsWith('/')) { $x = $x.TrimEnd('/') }

  # If no extension, treat as "<path>.html"
  if ($x -notmatch '\.html?$') { $x = $x + '.html' }

  return $x
}

function Is-Protected([string]$rel) {
  # Don't allow deleting anything under these top-level folders
  if ($rel -match '^(?:blog/|assets/|partials/|parametric-static/)' ) { return $true }
  # Don't allow deleting layout.html
  if ($rel -ieq 'layout.html') { return $true }
  # Don't allow deleting root index.html
  if ($rel -ieq 'index.html') { return $true }
  return $false
}

function List-PageCandidates {
  $root = $S.Root
  $all = Get-ChildItem -Path $root -Filter *.html -File -Recurse
  foreach ($f in $all) {
    $rel = ($f.FullName.Substring($root.Length)).TrimStart('\','/') -replace '\\','/'
    if ($rel -match '^(blog/|assets/|partials/|parametric-static/)') { continue }
    if ($rel -ieq 'layout.html') { continue }
    Write-Host "  $rel"
  }
}

function Remove-EmptyParents([string]$fullFilePath) {
  try {
    $dir = Split-Path -Parent $fullFilePath
    while ($dir -and (Split-Path -Parent $dir)) {
      # Stop at the site root
      if ([IO.Path]::GetFullPath($dir).TrimEnd('\') -ieq [IO.Path]::GetFullPath($S.Root).TrimEnd('\')) { break }
      $items = @(Get-ChildItem -LiteralPath $dir -Force)
      if ($items.Count -eq 0) {
        try { Remove-Item -LiteralPath $dir -Force } catch {}
        $dir = Split-Path -Parent $dir
      } else { break }
    }
  } catch {}
}

# -------- main --------
$rel = Normalize-RelPath $Path
if (-not $rel) { Write-Error "Path is required."; exit 1 }

if (Is-Protected $rel) {
  Write-Error "Refusing to delete protected path: $rel"
  Write-Host "Allowed targets are non-blog pages under the site root (e.g., about.html, legal/privacy.html)."
  exit 1
}

$full = Join-Path $S.Root $rel
if (-not (Test-Path -LiteralPath $full)) {
  Write-Error "Page not found: $rel"
  Write-Host "[ASD] Nearby candidates:"
  List-PageCandidates
  exit 1
}

try {
  Remove-Item -LiteralPath $full -Force
  Write-Host "[ASD] Deleted page: $rel"
  Remove-EmptyParents -fullFilePath $full
  Write-Host "[ASD] Done."
} catch {
  Write-Error "Failed to delete '$rel': $($_.Exception.Message)"
  exit 1
}
