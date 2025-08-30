param(
  [Parameter(Mandatory=$true)][string]$Slug
)

# Load config
$__here = Split-Path -Parent $PSCommandPath
. (Join-Path $__here "_lib.ps1")
$__cfg   = Get-ASDConfig
$Brand   = $__cfg.SiteName
$Money   = $__cfg.StoreUrl
$Desc    = $__cfg.Description
$Base    = $__cfg.BaseUrl
$__paths = Get-ASDPaths

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$src  = Join-Path $Root ("blog\" + $Slug + ".html")
if (-not (Test-Path $src)) { Write-Error "Post not found: $src"; exit 1 }

$html = Get-Content $src -Raw

# Prefer ASD markers
$m = [regex]::Match($html,'(?is)<!--\s*ASD:CONTENT_START\s*-->(.*?)<!--\s*ASD:CONTENT_END\s*-->')
if ($m.Success) {
  $content = $m.Groups[1].Value.Trim()
} else {
  # Else <article>, else <main>, else body
  $m2 = [regex]::Match($html,'(?is)<article\b[^>]*>(.*?)</article>')
  if ($m2.Success) {
    $content = $m2.Groups[1].Value.Trim()
  } else {
    $m3 = [regex]::Match($html,'(?is)<main\b[^>]*>(.*?)</main>')
    if ($m3.Success) {
      $content = $m3.Groups[1].Value.Trim()
    } else {
      $b = [regex]::Match($html,'(?is)<body[^>]*>(.*?)</body>')
      $content = if ($b.Success) { $b.Groups[1].Value.Trim() } else { $html.Trim() }
    }
  }
}

$drafts = Join-Path $Root "drafts"
if (-not (Test-Path $drafts)) { New-Item -ItemType Directory -Force -Path $drafts | Out-Null }
$out = Join-Path $drafts ($Slug + ".html")
$content | Set-Content -Encoding UTF8 $out
Write-Host "[ASD] Draft saved -> drafts/$Slug.html"
