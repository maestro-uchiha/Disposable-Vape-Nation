param(
  [Parameter(Mandatory=$true)][string]$FromSlug,
  [Parameter(Mandatory=$true)][string]$ToSlug
)

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Set-Location $Root

$cfg = $null
if (Test-Path ".\config.json") { try { $cfg = Get-Content .\config.json -Raw | ConvertFrom-Json } catch {} }
$dom = if ($cfg -and $cfg.site -and $cfg.site.url) { $cfg.site.url.TrimEnd('/') } else { "https://YOUR-DOMAIN.example" }

$from = Join-Path $Root ("blog\" + $FromSlug + ".html")
$toUrl = "$dom/blog/$ToSlug.html"

$html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>Moved — {{BRAND}}</title>
  <meta http-equiv="refresh" content="0; url=$toUrl">
  <link rel="canonical" href="$toUrl">
</head>
<body>
  <p>This post has moved. If you are not redirected, <a href="$toUrl">click here</a>.</p>
</body>
</html>
"@
$html | Set-Content -Encoding UTF8 $from
Write-Host "[ASD] Redirect stub written: blog/$FromSlug.html -> $toUrl"
