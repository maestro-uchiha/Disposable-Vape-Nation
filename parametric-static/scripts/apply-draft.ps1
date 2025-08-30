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
$post = Join-Path $Root ("blog\" + $Slug + ".html")
$draft = Join-Path $Root ("drafts\" + $Slug + ".html")

if (-not (Test-Path $post))  { Write-Error "Post not found: $post";  exit 1 }
if (-not (Test-Path $draft)) { Write-Error "Draft not found: $draft"; exit 1 }

$d = Get-Content $draft -Raw
$p = Get-Content $post -Raw

# 1) If ASD markers exist, replace inner
if ($p -match '(?is)<!--\s*ASD:CONTENT_START\s*-->.*?<!--\s*ASD:CONTENT_END\s*-->') {
  $p = [regex]::Replace($p,'(?is)<!--\s*ASD:CONTENT_START\s*-->.*?<!--\s*ASD:CONTENT_END\s*-->',
    "<!-- ASD:CONTENT_START -->`r`n$d`r`n<!-- ASD:CONTENT_END -->",1)
}
# 2) Else if <main> exists, replace its inner with markers + draft
elseif ($p -match '(?is)<main\b[^>]*>') {
  $eval = [System.Text.RegularExpressions.MatchEvaluator]{
    param($m)
    $m.Groups[1].Value + "`r`n<!-- ASD:CONTENT_START -->`r`n$d`r`n<!-- ASD:CONTENT_END -->`r`n" + $m.Groups[3].Value
  }
  $p = [regex]::Replace($p,'(?is)(<main\b[^>]*>)(.*?)(</main>)',$eval,1)
}
# 3) Else inject a <main> block before </body>
elseif ($p -match '(?is)</body>') {
  $p = [regex]::Replace($p,'(?is)</body>',
    "<main>`r`n<!-- ASD:CONTENT_START -->`r`n$d`r`n<!-- ASD:CONTENT_END -->`r`n</main>`r`n</body>",1)
}
# 4) Else just append markers (last resort)
else {
  $p += "`r`n<!-- ASD:CONTENT_START -->`r`n$d`r`n<!-- ASD:CONTENT_END -->`r`n"
}

$p | Set-Content -Encoding UTF8 $post
Write-Host "[ASD] Applied draft to blog/$Slug.html (markers ensured)"
