# ============================================
#  Amaterasu Static Deploy (ASD) - bake.ps1
#  SINGLE SOURCE OF TRUTH = config.json
#  - Wraps HTML with layout.html and {{PREFIX}}
#  - Rewrites root-absolute links → prefix-relative
#  - Normalizes en/em dashes (and mojibake) to "|"
#  - Rebuilds /blog/ index (simple list inside markers)
#  - Generates sitemap.xml from actual files + site.url
#  - robots.txt: preserve existing rules if file exists;
#                otherwise write your strict default,
#                and always append one canonical Sitemap line.
# ============================================

. "$PSScriptRoot\_lib.ps1"
$S   = Get-ASDPaths
$cfg = Get-ASDConfig -Root $S.Root

$Brand = if ($cfg.site.name) { $cfg.site.name } else { "Amaterasu Static Deploy" }
$Money = if ($cfg.moneySite) { $cfg.moneySite } else { "https://example.com" }
$Desc  = if ($cfg.site.description) { $cfg.site.description } else { "Premium $Brand | quality, reliability, trust." }
$Base  = Ensure-AbsoluteBaseUrl $cfg.site.url

Write-Host ("[ASD] Baking… brand='{0}' store='{1}' base='{2}'" -f $Brand,$Money,$Base)

$RootDir    = $S.Root
$LayoutPath = Join-Path $RootDir "layout.html"
$BlogDir    = Join-Path $RootDir "blog"
$Year       = (Get-Date).Year

if (-not (Test-Path $LayoutPath)) {
  Write-Error "[ASD] layout.html not found at $LayoutPath"
  exit 1
}
$Layout = Get-Content $LayoutPath -Raw

# --- Helpers -----------------------------

function Normalize-DashesToPipe {
  param([string]$s)
  if ($null -eq $s) { return $s }
  $pipe = '|'
  $s = $s.Replace([string][char]0x2013, $pipe) # –
  $s = $s.Replace([string][char]0x2014, $pipe) # —
  $s = $s.Replace('&ndash;', $pipe).Replace('&mdash;', $pipe)
  $seq_en = [string]([char]0x00E2)+[char]0x0080+[char]0x0093
  $seq_em = [string]([char]0x00E2)+[char]0x0080+[char]0x0094
  $s = $s.Replace($seq_en, $pipe).Replace($seq_em, $pipe)
  return $s
}

function Rewrite-RootLinks {
  param([string]$html, [string]$prefix)
  if ([string]::IsNullOrEmpty($html)) { return $html }
  $hrefEval = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) 'href="'  + $prefix + $m.Groups[1].Value }
  $srcEval  = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) 'src="'   + $prefix + $m.Groups[1].Value }
  $actEval  = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) 'action="' + $prefix + $m.Groups[1].Value }
  $html = [regex]::Replace($html, 'href="/(?!/)([^"#?]+)',   $hrefEval)
  $html = [regex]::Replace($html, 'src="/(?!/)([^"#?]+)',    $srcEval)
  $html = [regex]::Replace($html, 'action="/(?!/)([^"#?]+)', $actEval)
  return $html
}

function Get-RelPrefix {
  param([string]$FilePath)
  $fileDir = Split-Path $FilePath -Parent
  $rootSeg = ($RootDir.TrimEnd('\')).Split('\')
  $dirSeg  = ($fileDir.TrimEnd('\')).Split('\')
  $depth = $dirSeg.Length - $rootSeg.Length
  if ($depth -lt 1) { return '' }
  $p = ''
  for ($i=0; $i -lt $depth; $i++) { $p += '../' }
  return $p
}

function Extract-Content {
  param([string]$raw)
  $mark = [regex]::Match($raw, '(?is)<!--\s*ASD:CONTENT_START\s*-->(.*?)<!--\s*ASD:CONTENT_END\s*-->')
  if ($mark.Success) {
    $raw = $mark.Groups[1].Value
  } else {
    $body = [regex]::Match($raw, '(?is)<body[^>]*>(.*?)</body>')
    if ($body.Success) { $raw = $body.Groups[1].Value }
  }
  $raw = [regex]::Replace($raw, '(?is)<!--#include\s+virtual="partials/.*?-->', '')
  $raw = [regex]::Replace($raw, '(?is)<header\b[^>]*>.*?</header>', '')
  $raw = [regex]::Replace($raw, '(?is)<nav\b[^>]*>.*?</nav>', '')
  $raw = [regex]::Replace($raw, '(?is)<footer\b[^>]*>.*?</footer>', '')
  $m = [regex]::Match($raw, '(?is)<main\b[^>]*>(.*?)</main>')
  if ($m.Success) { $raw = $m.Groups[1].Value }
  $raw = [regex]::Replace($raw, '(?is)</?main\b[^>]*>', '')
  return $raw
}

# --- Update the simple blog list on /blog/index.html ----------
$BlogIndex = Join-Path $BlogDir "index.html"
if (Test-Path $BlogIndex) {
  $posts = New-Object System.Collections.Generic.List[string]
  Get-ChildItem -Path $BlogDir -Filter *.html -File |
    Where-Object { $_.Name -ne "index.html" } |
    Sort-Object LastWriteTime -Descending |
    ForEach-Object {
      $html  = Get-Content $_.FullName -Raw
      # prefer <title>, else first <h1>, else filename
      $mTitle = [regex]::Match($html, '<title>(.*?)</title>', 'IgnoreCase')
      if ($mTitle.Success) {
        $title = $mTitle.Groups[1].Value
      } else {
        $mH1 = [regex]::Match($html, '(?is)<h1[^>]*>(.*?)</h1>')
        $title = if ($mH1.Success) { $mH1.Groups[1].Value } else { $_.BaseName }
      }
      $title = Normalize-DashesToPipe $title
      $date  = $_.LastWriteTime.ToString('yyyy-MM-dd')
      $rel   = $_.Name
      $li    = ('<li><a href="./{0}">{1}</a><small> | {2}</small></li>' -f $rel, $title, $date)
      $posts.Add($li)
    }

  $bi = Get-Content $BlogIndex -Raw
  $joined = [string]::Join([Environment]::NewLine, $posts)
  $pattern = '(?s)<!-- POSTS_START -->.*?<!-- POSTS_END -->'
  $replacement = @"
<!-- POSTS_START -->
$joined
<!-- POSTS_END -->
"@
  $bi = [regex]::Replace($bi, $pattern, $replacement)
  Set-Content -Encoding UTF8 $BlogIndex $bi
  Write-Host "[ASD] Blog index updated"
}

# --- Wrap each HTML using layout + page-specific prefix -----------
Get-ChildItem -Path $RootDir -Recurse -File |
  Where-Object { $_.Extension -eq ".html" -and $_.FullName -ne $LayoutPath } |
  ForEach-Object {
    $raw = Get-Content $_.FullName -Raw
    $content = Extract-Content $raw

    # Title: prefer first <h1> in content, fallback to filename
    $tm = [regex]::Match($content, '(?is)<h1[^>]*>(.*?)</h1>')
    $pageTitle = if ($tm.Success) { $tm.Groups[1].Value } else { $_.BaseName }

    $prefix = Get-RelPrefix -FilePath $_.FullName

    $final = $Layout
    $final = $final.Replace('{{CONTENT}}', $content)
    $final = $final.Replace('{{TITLE}}', $pageTitle)
    $final = $final.Replace('{{BRAND}}', $Brand)
    $final = $final.Replace('{{DESCRIPTION}}', $Desc)
    $final = $final.Replace('{{MONEY}}', $Money)
    $final = $final.Replace('{{YEAR}}', (Get-Date).Year.ToString())
    $final = $final.Replace('{{PREFIX}}', $prefix)

    $final = Rewrite-RootLinks $final $prefix
    $final = Normalize-DashesToPipe $final

    Set-Content -Encoding UTF8 $_.FullName $final
    Write-Host ("[ASD] Wrapped {0} (prefix='{1}')" -f $_.FullName.Substring($RootDir.Length+1), $prefix)
  }

# --- Sitemap & Robots -------------------------------------------------

# Build sitemap.xml from actual files
$sitemapPath = Join-Path $RootDir 'sitemap.xml'
$urls = New-Object System.Collections.Generic.List[object]
Get-ChildItem -Path $RootDir -Recurse -File -Include *.html |
  Where-Object {
    $_.FullName -ne $LayoutPath -and
    $_.FullName -notmatch '\\assets\\' -and
    $_.FullName -notmatch '\\partials\\' -and
    $_.Name -ne '404.html'
  } |
  ForEach-Object {
    $rel = $_.FullName.Substring($RootDir.Length + 1) -replace '\\','/'
    if ($rel -ieq 'index.html') {
      $loc = $Base
    } elseif ($rel -match '^(.+)/index\.html$') {
      $loc = ($Base.TrimEnd('/') + '/' + $matches[1] + '/')
    } else {
      $loc = ($Base.TrimEnd('/') + '/' + $rel)
    }
    $loc = $loc -replace ':/','://' -replace '/{2,}','/'
    $loc = $loc -replace '://','§§' -replace '/{2,}','/' -replace '§§','://'
    $last = $_.LastWriteTime.ToString('yyyy-MM-dd')
    $urls.Add([pscustomobject]@{ loc=$loc; lastmod=$last })
  }

$xml = New-Object System.Text.StringBuilder
[void]$xml.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$xml.AppendLine('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">')
foreach($u in $urls | Sort-Object loc){
  [void]$xml.AppendLine("  <url><loc>$($u.loc)</loc><lastmod>$($u.lastmod)</lastmod></url>")
}
[void]$xml.AppendLine('</urlset>')
Set-Content -Encoding UTF8 $sitemapPath $xml.ToString()
Write-Host ("[ASD] sitemap.xml generated ({0} urls)" -f $urls.Count)

# robots.txt logic
$robotsPath = Join-Path $RootDir 'robots.txt'
$absMap = if ($Base -match '^[a-z][a-z0-9+\.-]*://') { (New-Object Uri((New-Object Uri($Base)), 'sitemap.xml')).AbsoluteUri } else { 'sitemap.xml' }

# If robots.txt exists → preserve rules, just ensure a single canonical Sitemap line.
if (Test-Path $robotsPath) {
  $rob = Get-Content $robotsPath -Raw
  $rob = [regex]::Replace($rob, '(?im)^\s*Sitemap:\s*.*\r?\n?', '')
  if ($rob -notmatch "\r?\n$") { $rob += "`r`n" }
  $rob += "Sitemap: $absMap`r`n"
  Set-Content -Encoding UTF8 $robotsPath $rob
  Write-Host "[ASD] robots.txt updated (preserved rules; canonical Sitemap set)"
}
else {
  # No robots.txt → write your preferred strict template.
  $robots = @"
# Allow trusted search engine bots
User-agent: Googlebot
Disallow:

User-agent: Bingbot
Disallow:

User-agent: Slurp
Disallow:

User-agent: DuckDuckBot
Disallow:

User-agent: YandexBot
Disallow:

# Allow reputable AI bots
User-agent: ChatGPT-User
Disallow:

User-agent: GPTBot
Disallow:

User-agent: PerplexityBot
Disallow:

User-agent: YouBot
Disallow:

User-agent: Google-Extended
Disallow:

User-agent: AnthropicBot
Disallow:

User-agent: Neevabot
Disallow:

User-agent: Amazonbot
Disallow:

# Block SEO/backlink crawlers
User-agent: AhrefsBot
Disallow: /

User-agent: SemrushBot
Disallow: /

User-agent: MJ12bot
Disallow: /

User-agent: rogerbot
Disallow: /

User-agent: dotbot
Disallow: /

User-agent: Ubersuggest
Disallow: /

# Catch-all: Block everything else
User-agent: *
Disallow: /

# Sitemap location
Sitemap: $absMap
"@
  Set-Content -Encoding UTF8 $robotsPath $robots
  Write-Host "[ASD] robots.txt created (strict template)"
}

Write-Host "[ASD] Done."
