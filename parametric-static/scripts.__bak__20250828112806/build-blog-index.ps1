param([int]$PageSize = 10)

# ---- Load config / helpers ----
$ErrorActionPreference = 'Stop'
$__here  = Split-Path -Parent $PSCommandPath
. (Join-Path $__here "_lib.ps1")
$__cfg    = Get-ASDConfig
$__paths  = Get-ASDPaths

$Root    = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Set-Location $Root
$BlogDir = Join-Path $Root "blog"

if (-not (Test-Path $BlogDir)) {
  Write-Error "blog/ folder not found at '$BlogDir'."; exit 1
}

function Get-PostTitle([string]$path) {
  $raw = Get-Content $path -Raw
  $mc = [regex]::Match(
    $raw,
    '(?is)<!--\s*ASD:(CONTENT|BODY)_START\s*-->(.*?)<!--\s*ASD:(CONTENT|BODY)_END\s*-->'
  )
  $segment = if ($mc.Success) { $mc.Groups[2].Value } else {
    $mm = [regex]::Match($raw, '(?is)<main\b[^>]*>(.*?)</main>')
    if ($mm.Success) { $mm.Groups[1].Value } else { $raw }
  }
  $mH1 = [regex]::Match($segment, '(?is)<h1[^>]*>(.*?)</h1>')
  if ($mH1.Success) { return $mH1.Groups[1].Value }
  $mTitle = [regex]::Match($raw, '(?is)<title>(.*?)</title>')
  if ($mTitle.Success) { return $mTitle.Groups[1].Value }
  return [IO.Path]::GetFileNameWithoutExtension($path)
}

function TryParse-Date([string]$v) {
  if ([string]::IsNullOrWhiteSpace($v)) { return $null }
  [datetime]$out = [datetime]::MinValue
  $ok = [datetime]::TryParse(
    $v,
    [System.Globalization.CultureInfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::AssumeLocal,
    [ref]$out
  )
  if ($ok) { return $out } else { return $null }
}

function Get-MetaDateFromHtml([string]$html) {
  if ([string]::IsNullOrWhiteSpace($html)) { return $null }
  $m = [regex]::Match($html, '(?is)<meta\s+name\s*=\s*["'']date["'']\s+content\s*=\s*["'']([^"''<>]+)["'']')
  if ($m.Success) {
    $dt = TryParse-Date ($m.Groups[1].Value.Trim())
    if ($dt) { return $dt.ToString('yyyy-MM-dd') }
  }
  $t = [regex]::Match($html, '(?is)<time[^>]+datetime\s*=\s*["'']([^"''<>]+)["'']')
  if ($t.Success) {
    $dt = TryParse-Date ($t.Groups[1].Value.Trim())
    if ($dt) { return $dt.ToString('yyyy-MM-dd') }
  }
  return $null
}

# Collect posts (skip index/page-*.html) with stable date
$posts = @()
Get-ChildItem $BlogDir -Filter *.html -File |
  Where-Object { $_.Name -ne 'index.html' -and $_.Name -notmatch '^page-\d+\.html$' } |
  ForEach-Object {
    $raw = Get-Content $_.FullName -Raw
    if ($raw -match '(?is)<!--\s*ASD:REDIRECT\b') { return }

    $title = Get-PostTitle $_.FullName
    $dateStr = Get-MetaDateFromHtml $raw
    $dateDt  = $null
    if ($dateStr) {
      $tmp = TryParse-Date $dateStr
      if ($tmp) { $dateDt = $tmp }
    }
    if (-not $dateDt) { $dateDt = $_.CreationTime; $dateStr = $dateDt.ToString('yyyy-MM-dd') }

    $posts += [pscustomobject]@{
      Name    = $_.Name
      Title   = $title
      DateStr = $dateStr
      DateDt  = $dateDt
    }
  }

$posts = $posts | Sort-Object DateDt -Descending

$items = @()
foreach ($p in $posts) {
  $rel = "./$($p.Name)"
  $items += ('<li><a href="{0}">{1}</a><small> &middot; {2}</small></li>' -f $rel, (Normalize-DashesToPipe $p.Title), $p.DateStr)
}

# Remove old paginated pages
Get-ChildItem $BlogDir -Filter 'page-*.html' -File | Remove-Item -Force -ErrorAction SilentlyContinue

if ($items.Count -eq 0) {
  $content = @"
<!-- ASD:CONTENT_START -->
<h1>Blog</h1>
<p>No posts yet.</p>
<!-- ASD:CONTENT_END -->
"@
  Set-Content -Encoding UTF8 (Join-Path $BlogDir 'index.html') $content
  Write-Host "[paginate] Wrote blog/index.html (empty)"
  exit 0
}

$total = $items.Count
$pages = [Math]::Ceiling($total / [double]$PageSize)

for ($i = 1; $i -le $pages; $i++) {
  $start = ($i - 1) * $PageSize
  $count = [Math]::Min($PageSize, $total - $start)
  $slice = $items[$start..($start + $count - 1)]
  $listHtml = [string]::Join([Environment]::NewLine, $slice)

  $prevHref = if ($i -gt 1) { if ($i -eq 2) { "./" } else { "./page-$($i-1).html" } } else { $null }
  $nextHref = if ($i -lt $pages) { "./page-$($i+1).html" } else { $null }

  $prev = if ($prevHref) { ('<a class="pager-prev" href="{0}">&larr; Newer</a>' -f $prevHref) } else { '' }
  $next = if ($nextHref) { ('<a class="pager-next" href="{0}">Older &rarr;</a>' -f $nextHref) } else { '' }

  $nums = @()
  for ($n = 1; $n -le $pages; $n++) {
    $href = if ($n -eq 1) { './' } else { "./page-$n.html" }
    if ($n -eq $i) { $nums += "<strong>$n</strong>" } else { $nums += "<a href=""$href"">$n</a>" }
  }
  $numNav = ($nums -join ' ')
  $pagerHtml = @"
<nav class="pager">
  $prev
  <span class="pager-pages">$numNav</span>
  $next
</nav>
"@

  $h1 = if ($pages -gt 1) { "Blog &mdash; Page $i" } else { "Blog" }

  $content = @"
<!-- ASD:CONTENT_START -->
<h1>$h1</h1>
<ul class="posts">
$listHtml
</ul>
$pagerHtml
<!-- ASD:CONTENT_END -->
"@

  $outName = if ($i -eq 1) { 'index.html' } else { "page-$i.html" }
  Set-Content -Encoding UTF8 (Join-Path $BlogDir $outName) $content
  Write-Host ("[paginate] Wrote blog/{0} ({1} items)" -f $outName, $count)
}

Write-Host ("[paginate] Done. Pages: {0}, Items: {1}" -f $pages, $total)
