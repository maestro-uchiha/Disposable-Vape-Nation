<# 
  new-post.ps1
  Create a new blog post with ASD body markers and update feed.xml.
  - PowerShell 5.1 compatible
  - Reads config.json via _lib.ps1 (single source of truth)
  - Prompts for Author if not supplied; defaults to config or "Maestro"
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)] [string]$Title,
  [Parameter(Mandatory=$true)] [string]$Slug,
  [string]$Description = "",
  [datetime]$Date = (Get-Date),
  [string]$Author
)

. (Join-Path $PSScriptRoot "_lib.ps1")

$S   = Get-ASDPaths
$cfg = Get-ASDConfig -Root $S.Root

# --- Simple HTML escape for meta/text contexts ---
function HtmlEscape([string]$s) {
  if ($null -eq $s) { return "" }
  $s = $s -replace '&','&amp;'
  $s = $s -replace '<','&lt;'
  $s = $s -replace '>','&gt;'
  $s = $s -replace '"','&quot;'
  return $s
}

# --- Resolve default author from config or "Maestro" ---
$defaultAuthor = 'Maestro'
if ($cfg -ne $null) {
  if ($cfg.PSObject.Properties.Name -contains 'AuthorName' -and -not [string]::IsNullOrWhiteSpace($cfg.AuthorName)) {
    $defaultAuthor = $cfg.AuthorName
  } elseif ($cfg.PSObject.Properties.Name -contains 'author' -and $cfg.author -ne $null) {
    if ($cfg.author.PSObject.Properties.Name -contains 'name' -and -not [string]::IsNullOrWhiteSpace($cfg.author.name)) {
      $defaultAuthor = $cfg.author.name
    } elseif ($cfg.author.PSObject.Properties.Name -contains 'Name' -and -not [string]::IsNullOrWhiteSpace($cfg.author.Name)) {
      $defaultAuthor = $cfg.author.Name
    }
  }
}

# --- If Author not supplied, ask the user (defaulting to resolved default) ---
$authorName = $defaultAuthor
if ($PSBoundParameters.ContainsKey('Author') -and -not [string]::IsNullOrWhiteSpace($Author)) {
  $authorName = $Author
} elseif (-not $PSBoundParameters.ContainsKey('Author')) {
  $input = Read-Host "Author name [$defaultAuthor]"
  if (-not [string]::IsNullOrWhiteSpace($input)) { $authorName = $input }
}

# --- Sanitize slug ---
$slug = $Slug
if ($slug) { $slug = $slug.Trim().ToLower() }
$slug = $slug -replace '\s+','-'
$slug = $slug -replace '[^a-z0-9\-]',''
if ([string]::IsNullOrWhiteSpace($slug)) { throw "Slug became empty after sanitization." }

# --- Paths / ensure blog dir ---
$blogDir = $S.Blog
New-Item -ItemType Directory -Force -Path $blogDir | Out-Null
$outPath = Join-Path $blogDir ($slug + ".html")
if (Test-Path $outPath) { Write-Error "Post already exists: $outPath"; exit 1 }

# --- Compose HTML (no ASD markers in <head>; body markers only) ---
$titleText = $Title.Trim()
$titleEsc  = HtmlEscape($titleText)
$descEsc   = HtmlEscape($Description)
$dateIso   = $Date.ToString('yyyy-MM-dd')
$authorEsc = HtmlEscape($authorName)

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>$titleEsc</title>
  <meta name="description" content="$descEsc">
  <meta name="author" content="$authorEsc">
  <meta name="date" content="$dateIso">
</head>
<body>
<main>
  <!-- ASD:CONTENT_START -->
  <article>
    <h1>$titleEsc</h1>
    <p><em>$dateIso</em></p>
    <p>Write your post here...</p>
  </article>
  <!-- ASD:CONTENT_END -->
</main>
</body>
</html>
"@

Set-Content -Encoding UTF8 -Path $outPath -Value $html
Write-Host "[ASD] Created blog\$slug.html"

# --- Update (or create) a simple feed.xml ---
$feedPath = Join-Path $S.Root "feed.xml"
if (-not (Test-Path $feedPath)) {
  $feedInit = @"
<?xml version="1.0" encoding="utf-8"?>
<feed>
  <updated>$(Get-Date -Format o)</updated>
</feed>
"@
  Set-Content -Encoding UTF8 -Path $feedPath -Value $feedInit
} else {
  try { $feed = Get-Content -Raw -ErrorAction Stop $feedPath } catch { $feed = "" }
  if ($feed -match '<updated>.*?</updated>') {
    $feed = [regex]::Replace($feed, '<updated>.*?</updated>', ('<updated>' + (Get-Date -Format o) + '</updated>'))
  } else {
    $feed += "`n<updated>$(Get-Date -Format o)</updated>`n"
  }
  Set-Content -Encoding UTF8 -Path $feedPath -Value $feed
}
Write-Host "[ASD] feed.xml updated"

Write-Host ""
Write-Host "[ASD] Next:"
Write-Host "  .\parametric-static\scripts\bake.ps1"
