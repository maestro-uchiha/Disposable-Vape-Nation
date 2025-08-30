# parametric-static/scripts/bake.ps1
<# ============================================
   Amaterasu Static Deploy (ASD) - bake.ps1
   - Uses config.json as the single source of truth
   - Generates instant redirect stubs from redirects.json
   - Wraps HTML with layout.html and {{PREFIX}} (except redirect stubs)
   - Rewrites root-absolute links -> prefix-relative (except 404)
   - Normalizes dashes to "|"
   - Rebuilds /blog/ index (stable dates; respects <meta name="date">)
   - Generates sitemap.xml, robots.txt (single Sitemap line)
   - Generates RSS (feed.xml) and Atom (atom.xml)
   - Builds assets/search-index.json for search.html
   - Injects Prev/Next post links into blog posts if missing
   - Injects Suggested posts (related) into blog posts if missing
   - Per-page canonical and robots
   - Per-page OG image absolute URL (if assets/img/og.* exists)
   - Preserves file timestamps so baking doesn't change dates
   - PowerShell 5.1-safe
   ============================================ #>

#requires -Version 5.1
. "$PSScriptRoot\_lib.ps1"

# ---------- Helpers (PS 5.1-safe) ----------
function TryParse-Date([string]$v){ if([string]::IsNullOrWhiteSpace($v)){return $null}
  [datetime]$out=[datetime]::MinValue
  $ok=[datetime]::TryParse($v,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeLocal,[ref]$out)
  if($ok){$out}else{$null}
}
function Rfc1123([datetime]$dt){ if($null -eq $dt){$dt=Get-Date}
  if($dt.Kind -ne [System.DateTimeKind]::Utc){$dt=$dt.ToUniversalTime()}
  $dt.ToString("R",[Globalization.CultureInfo]::InvariantCulture)
}
function Get-MetaDateFromHtml([string]$html){
  if([string]::IsNullOrWhiteSpace($html)){return $null}
  $m=[regex]::Match($html,'(?is)<meta\s+name\s*=\s*["'']date["'']\s+content\s*=\s*["'']([^"''<>]+)["'']')
  if($m.Success){$dt=TryParse-Date ($m.Groups[1].Value.Trim()); if($dt){return $dt.ToString('yyyy-MM-dd')}}
  $t=[regex]::Match($html,'(?is)<time[^>]+datetime\s*=\s*["'']([^"''<>]+)["'']')
  if($t.Success){$dt=TryParse-Date ($t.Groups[1].Value.Trim()); if($dt){return $dt.ToString('yyyy-MM-dd')}}
  $null
}
function Get-MetaDescriptionFromHtml([string]$html){
  if([string]::IsNullOrWhiteSpace($html)){return $null}
  $m=[regex]::Match($html,'(?is)<meta\s+name\s*=\s*["'']description["'']\s+content\s*=\s*["'']([^"''<>]*)["'']')
  if($m.Success){ return $m.Groups[1].Value.Trim() }
  return $null
}
function HtmlStrip([string]$s){
  if([string]::IsNullOrWhiteSpace($s)){return ""}
  $s = [regex]::Replace($s,'(?is)<script[^>]*>.*?</script>','')
  $s = [regex]::Replace($s,'(?is)<style[^>]*>.*?</style>','')
  $s = [regex]::Replace($s,'(?s)<[^>]+>',' ')
  $s = [regex]::Replace($s,'\s+',' ').Trim()
  return $s
}
function Preserve-FileTimes($p,[datetime]$c,[datetime]$w){try{(Get-Item $p).CreationTimeUtc=$c}catch{};try{(Get-Item $p).LastWriteTimeUtc=$w}catch{}}
function Collapse-DoubleSlashesPreserveSchemeLocal([string]$u){
  if([string]::IsNullOrWhiteSpace($u)){return $u}
  $m=[regex]::Match($u,'^(https?://)(.*)$')
  if($m.Success){$m.Groups[1].Value + ($m.Groups[2].Value -replace '/{2,}','/')} else { $u -replace '/{2,}','/' }
}
function Normalize-BaseUrlLocal([string]$b){
  if([string]::IsNullOrWhiteSpace($b)){return "/"}
  $x=$b.Trim(); $x=$x -replace '^/+(?=https?:)',''; $x=$x -replace '^((?:https?):)/{1,}','$1//'
  $m=[regex]::Match($x,'^(https?://)(.+)$')
  if($m.Success){ $x=$m.Groups[1].Value + $m.Groups[2].Value.TrimStart('/'); if(-not $x.EndsWith('/')){$x+='/'}; $x }
  else { '/' + $x.Trim('/') + '/' }
}
function Resolve-RedirectTarget([string]$to,[string]$base){
  if([string]::IsNullOrWhiteSpace($to)){return $base}
  $t=$to.Trim()
  if($t -match '^[a-z]+://'){return Collapse-DoubleSlashesPreserveSchemeLocal($t)}
  if($t.StartsWith('/')){return Collapse-DoubleSlashesPreserveSchemeLocal(($base.TrimEnd('/')+$t))}
  Collapse-DoubleSlashesPreserveSchemeLocal(($base.TrimEnd('/')+'/'+$t))
}
function Make-RedirectOutputPath([string]$from,[string]$root){
  if([string]::IsNullOrWhiteSpace($from)){return $null}
  $rel=$from.Trim(); if($rel.StartsWith('/')){$rel=$rel.TrimStart('/')}
  if(-not ($rel -match '\.html?$')){ if($rel.EndsWith('/')){$rel+='index.html'} else {$rel+='/index.html'} }
  $out=Join-Path $root $rel; $dir=Split-Path $out -Parent; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $out
}
function HtmlEscape([string]$s){ if($null -eq $s){return ''}; $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;') }
function JsString([string]$s){ if($null -eq $s){return ''}; $s.Replace('\','\\').Replace("'", "\'") }
function Write-RedirectStub([string]$outPath,[string]$absUrl,[int]$code){
  $href=HtmlEscape($absUrl); $jsu=JsString($absUrl)
  $html=@"
<!doctype html><html lang="en"><head>
<meta charset="utf-8"><title>Redirecting…</title>
<meta name="robots" content="noindex">
<meta http-equiv="refresh" content="0;url=$href">
<script>location.replace('$jsu');</script>
</head><body>
<!-- ASD:REDIRECT to="$href" code="$code" -->
<p>If you are not redirected, <a href="$href">click here</a>.</p>
</body></html>
"@
  Set-Content -Encoding UTF8 $outPath $html
}
function Generate-RedirectStubs([string]$redirectsJson,[string]$root,[string]$base){
  if(-not (Test-Path $redirectsJson)){return 0}
  $items=@()
  try{ $raw=Get-Content $redirectsJson -Raw; if(-not [string]::IsNullOrWhiteSpace($raw)){$items=$raw|ConvertFrom-Json} }
  catch{ Write-Warning "[ASD] redirects.json is invalid; skipping."; return 0 }
  if($null -eq $items){return 0}
  $count=0
  foreach($r in $items){
    $enabled=$true; if($r.PSObject.Properties.Name -contains 'enabled'){$enabled=[bool]$r.enabled}
    if(-not $enabled){continue}
    $from=$null; $to=$null; $code=301
    if($r.PSObject.Properties.Name -contains 'from'){$from=[string]$r.from}
    if($r.PSObject.Properties.Name -contains 'to'){$to=[string]$r.to}
    if($r.PSObject.Properties.Name -contains 'code'){ try{$code=[int]$r.code} catch { $code=301 } }
    if([string]::IsNullOrWhiteSpace($from) -or [string]::IsNullOrWhiteSpace($to)){continue}
    if($from -match '\*'){continue}
    $outPath=Make-RedirectOutputPath $from $root; $abs=Resolve-RedirectTarget $to $base
    Write-RedirectStub $outPath $abs $code; $count++
  }
  $count
}
function AddOrReplaceMetaRobots([string]$html,[string]$value){
  if([string]::IsNullOrWhiteSpace($html)){return $html}
  $rx=[regex]'(?is)<meta\s+name\s*=\s*["'']robots["''][^>]*>'; $tag='<meta name="robots" content="' + (HtmlEscape $value) + '">'
  if($rx.IsMatch($html)){ $rx.Replace($html,$tag,1) } else {
    $m=[regex]::Match($html,'(?is)<head[^>]*>'); $nl=[Environment]::NewLine
    if($m.Success){ $idx=$m.Index+$m.Length; $html.Substring(0,$idx)+$nl+$tag+$nl+$html.Substring($idx) } else { $tag+$nl+$html }
  }
}
function DetermineRobotsForFile([string]$fullPath,[string]$rawHtml){ if(([IO.Path]::GetFileName($fullPath)) -ieq '404.html'){'noindex,nofollow'} else {'index,follow'} }

# --- Head feed injector ---
function Insert-AfterHeadOpen([string]$html,[string[]]$snips){
  if([string]::IsNullOrWhiteSpace($html)){return $html}
  $m=[regex]::Match($html,'(?is)<head[^>]*>'); $nl=[Environment]::NewLine
  if($m.Success){ $idx=$m.Index+$m.Length; $html.Substring(0,$idx)+$nl+([string]::Join($nl,$snips))+$nl+$html.Substring($idx) }
  else { ([string]::Join($nl,$snips))+$nl+$html }
}
function Ensure-HeadFeeds([string]$html,[string]$prefix,[string]$brand){
  $needRss  = -not ([regex]::IsMatch($html,'(?is)<link[^>]+type\s*=\s*["'']application/rss\+xml["''][^>]*>'))
  $needAtom = -not ([regex]::IsMatch($html,'(?is)<link[^>]+type\s*=\s*["'']application/atom\+xml["''][^>]*>'))
  $snips=@()
  if($needRss){  $snips += ('<link rel="alternate" type="application/rss+xml" title="' + (HtmlEscape $brand) + ' RSS" href="' + $prefix + 'feed.xml">') }
  if($needAtom){ $snips += ('<link rel="alternate" type="application/atom+xml" title="' + (HtmlEscape $brand) + ' Atom" href="' + $prefix + 'atom.xml">') }
  if($snips.Count -gt 0){ $html = Insert-AfterHeadOpen $html $snips }
  $html
}

# --- 404 helpers ---
function Get-RootPrefixFromBase([string]$base){
  if([string]::IsNullOrWhiteSpace($base)){ return "/" }
  if($base -match '^[a-z]+://'){
    try{
      $u = New-Object System.Uri($base)
      $p = $u.AbsolutePath
      if([string]::IsNullOrWhiteSpace($p)){ $p = "/" }
      if(-not $p.StartsWith("/")){ $p = "/" + $p }
      if(-not $p.EndsWith("/")){ $p = $p + "/" }
      return $p
    } catch { return "/" }
  } else {
    $x = "/" + ($base.Trim() -replace '^/+','')
    if(-not $x.EndsWith("/")){ $x += "/" }
    return $x
  }
}
function Fix-404Links([string]$html,[string]$base){
  $root = Get-RootPrefixFromBase $base
  $html = [regex]::Replace($html,'(?i)\b(href|src|content)\s*=\s*"((\{\{PREFIX\}\})?assets/)', '$1="' + $root + 'assets/')
  $html = [regex]::Replace($html,'(?i)<link\s+rel\s*=\s*"canonical"\s+href\s*=\s*"[^"]*"\s*>','<link rel="canonical" href="' + $root + 'index.html">')
  $html = [regex]::Replace($html,'(?i)href\s*=\s*"(?!https?://|mailto:|tel:|#|/)([^"]+)"','href="' + $root + '$1"')
  return $html
}

# ------ Description helpers ------
function Get-FirstParagraphDesc([string]$content){
  if([string]::IsNullOrWhiteSpace($content)){ return $null }
  $m=[regex]::Match($content,'(?is)<h1[^>]*>.*?</h1>\s*<p[^>]*>(.*?)</p>')
  if(-not $m.Success){ $m=[regex]::Match($content,'(?is)<p[^>]*>(.*?)</p>') }
  if($m.Success){
    $txt = HtmlStrip $m.Groups[1].Value
    $txt = [regex]::Replace($txt,'\s+',' ').Trim()
    if($txt.Length -gt 160){ $txt = $txt.Substring(0,160) }
    return $txt
  }
  return $null
}
function Get-ASDDescription([string]$raw,[string]$content){
  $m = [regex]::Match($content,'(?is)<!--\s*ASD:DESCRIPTION:\s*(.*?)\s*-->')
  if($m.Success){ $d = $m.Groups[1].Value } else { $d = Get-MetaDescriptionFromHtml $raw }
  if([string]::IsNullOrWhiteSpace($d)){ return $null }
  $d = [regex]::Replace($d,'\s+',' ').Trim()
  if($d.Length -gt 160){ $d = $d.Substring(0,160) }
  return $d
}

# ------ Canonical helpers ------
function Build-Canonical([string]$base,[string]$relPath){
  if([string]::IsNullOrWhiteSpace($relPath)){ return $base }
  $rel = $relPath.Replace('\','/')
  if($rel -ieq 'index.html'){
    return Collapse-DoubleSlashesPreserveSchemeLocal($base)
  }
  $m = [regex]::Match($rel,'^(.+)/index\.html$')
  if($m.Success){
    if($base -match '^[a-z]+://'){
      return (New-Object Uri((New-Object Uri($base)), ($m.Groups[1].Value.Trim('/') + '/'))).AbsoluteUri
    } else {
      return Collapse-DoubleSlashesPreserveSchemeLocal($base.TrimEnd('/') + '/' + $m.Groups[1].Value.Trim('/') + '/')
    }
  } else {
    if($base -match '^[a-z]+://'){
      return (New-Object Uri((New-Object Uri($base)), $rel)).AbsoluteUri
    } else {
      return Collapse-DoubleSlashesPreserveSchemeLocal($base.TrimEnd('/') + '/' + $rel)
    }
  }
}
function Ensure-CanonicalTag([string]$html,[string]$href){
  $tag = '<link rel="canonical" href="' + (HtmlEscape $href) + '">'
  $rx  = [regex]'(?is)<link\s+rel\s*=\s*["'']canonical["''][^>]*>'
  if($rx.IsMatch($html)){ return $rx.Replace($html,$tag,1) } else { return Insert-AfterHeadOpen $html @($tag) }
}

# ------ OG image (absolute) helper ------
function Ensure-OgImageAbsolute([string]$html,[string]$base,[string]$root){
  if([string]::IsNullOrWhiteSpace($html)){ return $html }
  $candidates = @('assets/img/og.jpg','assets/img/og.jpeg','assets/img/og.png','assets/img/og.webp')
  $found = $null
  foreach($c in $candidates){
    if (Test-Path (Join-Path $root $c)) { $found = $c; break }
  }
  if ($null -eq $found) { return $html }
  if ($base -match '^[a-z]+://') {
    $ogAbs = (New-Object Uri((New-Object Uri($base)), $found)).AbsoluteUri
  } else {
    $ogAbs = Collapse-DoubleSlashesPreserveSchemeLocal($base.TrimEnd('/') + '/' + $found)
  }
  $tag = '<meta property="og:image" content="' + (HtmlEscape $ogAbs) + '">'
  $rx  = [regex]'(?is)<meta\s+property\s*=\s*["'']og:image["''][^>]*>'
  if ($rx.IsMatch($html)) { $html = $rx.Replace($html,$tag,1) } else { $html = Insert-AfterHeadOpen $html @($tag) }
  return $html
}

# ------ Feed builders (RSS + Atom) ------
function Build-PostList($BlogDir,$Base){
  $list=New-Object System.Collections.ArrayList
  $files=Get-ChildItem -Path $BlogDir -Filter *.html -File | Where-Object { $_.Name -ne 'index.html' -and $_.Name -notmatch '^page-\d+\.html$' }
  foreach($f in $files){
    $html=Get-Content $f.FullName -Raw
    if($html -match '(?is)<!--\s*ASD:REDIRECT\b'){continue}
    $title=$null; $mTitle=[regex]::Match($html,'(?is)<title>(.*?)</title>')
    if($mTitle.Success){$title=$mTitle.Groups[1].Value}else{
      $mH1=[regex]::Match($html,'(?is)<h1[^>]*>(.*?)</h1>'); if($mH1.Success){$title=$mH1.Groups[1].Value}else{$title=$f.BaseName}
    }
    $title=Normalize-DashesToPipe $title
    $metaDate=Get-MetaDateFromHtml $html
    if($metaDate){$dateDt=TryParse-Date $metaDate; $dateText=$metaDate}else{$dateDt=$f.CreationTime; $dateText=$f.CreationTime.ToString('yyyy-MM-dd')}
    if($Base -match '^[a-z]+://'){ $abs=(New-Object Uri((New-Object Uri($Base)),('blog/'+$f.Name))).AbsoluteUri } else { $abs=($Base.TrimEnd('/') + '/blog/' + $f.Name) }
    [void]$list.Add([pscustomobject]@{ Name=$f.Name; Title=$title; Date=$dateDt; DateText=$dateText; Link=(Collapse-DoubleSlashesPreserveSchemeLocal $abs) })
  }
  ($list | Sort-Object Date -Descending)
}
function Generate-RssFeed($posts,[string]$base,[string]$title,[string]$desc,[string]$outPath,[int]$maxItems=20){
  $lines=New-Object System.Collections.Generic.List[string]
  $chTitle=HtmlEscape $title; $chDesc=HtmlEscape $desc; $chLink=$base
  if($base -match '^[a-z]+://'){ $chLink=(New-Object Uri((New-Object Uri($base)),'/')).AbsoluteUri }
  $lines.Add('<?xml version="1.0" encoding="UTF-8"?>')|Out-Null
  $lines.Add('<rss version="2.0">')|Out-Null
  $lines.Add('  <channel>')|Out-Null
  $lines.Add('    <title>'+ $chTitle +'</title>')|Out-Null
  $lines.Add('    <link>'+ (HtmlEscape $chLink) +'</link>')|Out-Null
  $lines.Add('    <description>'+ $chDesc +'</description>')|Out-Null
  $count=0
  foreach($p in $posts){ if($count -ge $maxItems){break}
    $lines.Add('    <item>')|Out-Null
    $lines.Add('      <title>'+ (HtmlEscape $p.Title) +'</title>')|Out-Null
    $lines.Add('      <link>'+ (HtmlEscape $p.Link) +'</link>')|Out-Null
    $pub=$null; if($p.Date -is [datetime]){$pub=Rfc1123 $p.Date}else{$pub=Rfc1123 (TryParse-Date $p.DateText)}
    $lines.Add('      <pubDate>'+ $pub +'</pubDate>')|Out-Null
    $lines.Add('    </item>')|Out-Null
  }
  $lines.Add('  </channel>')|Out-Null
  $lines.Add('</rss>')|Out-Null
  Set-Content -Encoding UTF8 $outPath ($lines -join [Environment]::NewLine)
}
function Generate-AtomFeed($posts,[string]$base,[string]$title,[string]$desc,[string]$outPath,[int]$maxItems=20){
  $lines=New-Object System.Collections.Generic.List[string]
  $feedId=$base; if($base -notmatch '^[a-z]+://'){ $feedId='tag:local,'+(Get-Date -Format 'yyyy-MM-dd')+':'+$base }
  $selfHref=$base
  if($base -match '^[a-z]+://'){ $selfHref=(New-Object Uri((New-Object Uri($base)),'atom.xml')).AbsoluteUri } else { $selfHref=($base.TrimEnd('/') + '/atom.xml') }
  $nowIso=(Get-Date).ToUniversalTime().ToString('s')+'Z'
  $lines.Add('<?xml version="1.0" encoding="utf-8"?>')|Out-Null
  $lines.Add('<feed xmlns="http://www.w3.org/2005/Atom">')|Out-Null
  $lines.Add('  <title>'+ (HtmlEscape $title) +'</title>')|Out-Null
  $lines.Add('  <id>'+ (HtmlEscape $feedId) +'</id>')|Out-Null
  $lines.Add('  <updated>'+ $nowIso +'</updated>')|Out-Null
  $lines.Add('  <link rel="self" href="'+ (HtmlEscape $selfHref) +'"/>')|Out-Null
  $count=0
  foreach($p in $posts){ if($count -ge $maxItems){break}
    $lines.Add('  <entry>')|Out-Null
    $lines.Add('    <title>'+ (HtmlEscape $p.Title) +'</title>')|Out-Null
    $lines.Add('    <link href="'+ (HtmlEscape $p.Link) +'"/>')|Out-Null
    $lines.Add('    <id>'+ (HtmlEscape $p.Link) +'</id>')|Out-Null
    $updDt=$null; if($p.Date -is [datetime]){$updDt=$p.Date}else{$updDt=TryParse-Date $p.DateText}; if($null -eq $updDt){$updDt=Get-Date}
    $lines.Add('    <updated>'+ ($updDt.ToUniversalTime().ToString('s')+'Z') +'</updated>')|Out-Null
    $lines.Add('  </entry>')|Out-Null
  }
  $lines.Add('</feed>')|Out-Null
  Set-Content -Encoding UTF8 $outPath ($lines -join [Environment]::NewLine)
}

# --- Build Search Index (JSON at assets/search-index.json) ---
function Build-SearchIndex($BlogDir,$RootDir){
  $rows = @()
  $files=Get-ChildItem -Path $BlogDir -Filter *.html -File | Where-Object { $_.Name -ne 'index.html' -and $_.Name -notmatch '^page-\d+\.html$' }
  foreach($f in $files){
    $html = Get-Content $f.FullName -Raw
    if ($html -match '(?is)<!--\s*ASD:REDIRECT\b'){ continue }
    $title=$f.BaseName
    $mTitle=[regex]::Match($html,'(?is)<title>(.*?)</title>')
    if($mTitle.Success){ $title=$mTitle.Groups[1].Value }
    $title=Normalize-DashesToPipe $title

    $date = Get-MetaDateFromHtml $html
    if(-not $date){ $date = $f.CreationTime.ToString('yyyy-MM-dd') }

    # Prefer ASD:DESCRIPTION; else meta; else first <p>
    $desc = $null
    $mDesc = [regex]::Match($html,'(?is)<!--\s*ASD:DESCRIPTION:\s*(.*?)\s*-->')
    if($mDesc.Success){ $desc = $mDesc.Groups[1].Value.Trim() }
    if([string]::IsNullOrWhiteSpace($desc)){ $desc = Get-MetaDescriptionFromHtml $html }
    if([string]::IsNullOrWhiteSpace($desc)){
      $mP=[regex]::Match($html,'(?is)<p[^>]*>(.*?)</p>')
      if($mP.Success){ $desc = HtmlStrip $mP.Groups[1].Value } else { $desc = "" }
    }
    $desc = [regex]::Replace($desc,'\s+',' ').Trim()
    if($desc.Length -gt 240){ $desc = $desc.Substring(0,240) + '…' }

    $rows += [pscustomobject]@{
      title = $title
      url   = ('blog/' + $f.Name)
      date  = $date
      desc  = $desc
    }
  }

  $assetsDir = Join-Path $RootDir 'assets'
  if(-not (Test-Path $assetsDir)){ New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null }
  $outPath = Join-Path $assetsDir 'search-index.json'
  $json = $rows | ConvertTo-Json -Depth 4 -Compress
  Set-Content -Encoding UTF8 $outPath $json
  Write-Host "[ASD] search-index.json built ($($rows.Count) items)"
}

# ------ Prev/Next helpers ------
function Build-PrevNextMap($posts){
  $map = @{}
  $count = $posts.Count
  for($i=0; $i -lt $count; $i++){
    $prev = $null; $next = $null
    if($i -lt ($count-1)){ $prev = $posts[$i+1] }  # older
    if($i -gt 0){ $next = $posts[$i-1] }          # newer
    $map[$posts[$i].Name] = @{ Prev = $prev; Next = $next }
  }
  return $map
}
function Inject-PostNav([string]$content, $prev, $next){
  if([string]::IsNullOrWhiteSpace($content)){ return $content }
  if([regex]::IsMatch($content,'(?is)<div\s+class\s*=\s*["'']post-nav["'']')){ return $content }
  $prevHtml = '<span></span>'
  $nextHtml = '<span></span>'
  if($prev -ne $null){
    $prevHtml = '<a class="prev" href="/blog/' + $prev.Name + '"><span>← ' + (HtmlEscape $prev.Title) + '</span></a>'
  }
  if($next -ne $null){
    $nextHtml = '<a class="next" href="/blog/' + $next.Name + '"><span>' + (HtmlEscape $next.Title) + ' →</span></a>'
  }
  $nav = '<div class="post-nav">' + $prevHtml + '<span></span>' + $nextHtml + '</div>'
  $m=[regex]::Match($content,'(?is)</article>')
  if($m.Success){
    $idx=$m.Index
    return $content.Substring(0,$idx) + $nav + $content.Substring($idx)
  } else {
    return $content + $nav
  }
}

# ------ Suggested posts ------
$script:ASD_Stop = @{}
foreach($w in @('the','a','an','and','or','for','with','from','to','of','in','on','how','what','is','are','vs','using','use','your','you','this','that','guide','worth','price','ace','ultra','premium')){
  $script:ASD_Stop[$w] = $true
}
function Get-TitleTokens([string]$t){
  if([string]::IsNullOrWhiteSpace($t)){ return @() }
  $s = $t.ToLowerInvariant()
  $s = [regex]::Replace($s,'[^a-z0-9\s]',' ')
  $parts = @()
  foreach($p in ($s -split '\s+')){
    if([string]::IsNullOrWhiteSpace($p)){ continue }
    if($p.Length -lt 3){ continue }
    if($script:ASD_Stop.ContainsKey($p)){ continue }
    if($parts -notcontains $p){ $parts += $p }
  }
  return $parts
}
function Build-RelatedList($posts,[string]$currentName,[int]$max=3){
  $current = $null
  foreach($p in $posts){ if($p.Name -eq $currentName){ $current=$p; break } }
  if($null -eq $current){ return @() }
  $curTok = Get-TitleTokens $current.Title

  $scored = @()
  foreach($p in $posts){
    if($p.Name -eq $currentName){ continue }
    $tok = Get-TitleTokens $p.Title
    $score = 0
    foreach($t in $tok){ if($curTok -contains $t){ $score++ } }
    $scored += [pscustomobject]@{ Name=$p.Name; Title=$p.Title; Date=$p.Date; DateText=$p.DateText; Score=$score }
  }

  $top = $scored | Sort-Object @{Expression='Score';Descending=$true}, @{Expression='Date';Descending=$true}
  $pick = @()
  foreach($x in $top){
    if($x.Score -gt 0){ $pick += $x }
    if($pick.Count -ge $max){ break }
  }
  if($pick.Count -lt $max){
    foreach($x in $top){
      if($pick.Count -ge $max){ break }
      $already = $false
      foreach($y in $pick){ if($y.Name -eq $x.Name){ $already=$true; break } }
      if(-not $already){ $pick += $x }
    }
  }
  if($pick.Count -le 0){ return @() }
  return ($pick | Select-Object -First $max)
}
function Inject-RelatedSection([string]$content, $items){
  if([string]::IsNullOrWhiteSpace($content)){ return $content }
  if([regex]::IsMatch($content,'(?is)<div\s+class\s*=\s*["'']related["'']')){ return $content }
  if($null -eq $items -or $items.Count -lt 1){ return $content }

  $lis = New-Object System.Collections.Generic.List[string]
  foreach($it in $items){
    $lis.Add('<li><a href="/blog/' + $it.Name + '">' + (HtmlEscape $it.Title) + '</a><small> | ' + $it.DateText + '</small></li>') | Out-Null
  }
  $html = '<div class="related"><h2>Suggested posts</h2><ul class="posts">' + ([string]::Join('', $lis)) + '</ul></div>'

  $m=[regex]::Match($content,'(?is)</article>')
  if($m.Success){
    $idx=$m.Index
    return $content.Substring(0,$idx) + $html + $content.Substring($idx)
  } else {
    return $content + $html
  }
}

# ---------------- start ----------------
$paths=Get-ASDPaths; $cfg=Get-ASDConfig
$RootDir=$paths.Root; $LayoutPath=$paths.Layout; $BlogDir=$paths.Blog

# Robust brand/site mapping: supports new "SiteName" and old "Brand"
if ($cfg.PSObject.Properties.Name -contains 'SiteName' -and -not [string]::IsNullOrWhiteSpace($cfg.SiteName)) {
  $Brand = $cfg.SiteName
} elseif ($cfg.PSObject.Properties.Name -contains 'Brand' -and -not [string]::IsNullOrWhiteSpace($cfg.Brand)) {
  $Brand = $cfg.Brand
} else {
  $Brand = 'My Site'
}
$Money    = $cfg.StoreUrl
$SiteDesc = $cfg.Description
$Base     = Normalize-BaseUrlLocal ([string]$cfg.BaseUrl)
$Year     = (Get-Date).Year

Write-Host "[ASD] Baking... brand='$Brand' store='$Money' base='$Base'"

# Redirect stubs
$made=Generate-RedirectStubs -redirectsJson $paths.Redirects -root $RootDir -base $Base
if($made -gt 0){Write-Host "[ASD] Redirect stubs generated: $made"}

if(-not (Test-Path $LayoutPath)){Write-Error "[ASD] layout.html not found at $LayoutPath"; exit 1}
$Layout=Get-Content $LayoutPath -Raw

# Build a sorted post list once (for index, feeds, Prev/Next, Related)
$postsForFeed = Build-PostList -BlogDir $BlogDir -Base $Base
$prevNextMap  = Build-PrevNextMap -posts $postsForFeed

# ---- Build /blog/ index (stable dates) ----
$BlogIndex=Join-Path $BlogDir "index.html"
if(Test-Path $BlogIndex){
  $entries=New-Object System.Collections.ArrayList
  $files=Get-ChildItem -Path $BlogDir -Filter *.html -File | Where-Object { $_.Name -ne "index.html" -and $_.Name -notmatch '^page-\d+\.html$' }
  foreach($f in $files){
    $html=Get-Content $f.FullName -Raw
    if($html -match '(?is)<!--\s*ASD:REDIRECT\b'){continue}
    $title=$null; $mTitle=[regex]::Match($html,'(?is)<title>(.*?)</title>')
    if($mTitle.Success){$title=$mTitle.Groups[1].Value}else{
      $mH1=[regex]::Match($html,'(?is)<h1[^>]*>(.*?)</h1>'); if($mH1.Success){$title=$mH1.Groups[1].Value}else{$title=$f.BaseName}
    }
    $title=Normalize-DashesToPipe $title
    $metaDate=Get-MetaDateFromHtml $html
    if($metaDate){$dateDisplay=$metaDate; $sortKey=TryParse-Date $metaDate}else{$dateDisplay=$f.CreationTime.ToString('yyyy-MM-dd'); $sortKey=$f.CreationTime}
    [void]$entries.Add([pscustomobject]@{ Title=$title; Href=$f.Name; DateText=$dateDisplay; SortKey=$sortKey })
  }
  $posts=New-Object System.Collections.Generic.List[string]
  foreach($e in ($entries | Sort-Object SortKey -Descending)){
    [void]$posts.Add('<li><a href="./'+$e.Href+'">'+$e.Title+'</a><small> | '+$e.DateText+'</small></li>')
  }
  $bi=Get-Content $BlogIndex -Raw
  $joined=[string]::Join([Environment]::NewLine,$posts)
  $pattern='(?s)<!-- POSTS_START -->.*?<!-- POSTS_END -->'
  $replacement='<!-- POSTS_START -->' + $joined + '<!-- POSTS_END -->'
  $bi=[regex]::Replace($bi,$pattern,$replacement)
  Set-Content -Encoding UTF8 $BlogIndex $bi
  Write-Host "[ASD] Blog index updated"
}

# ---- Wrap every HTML (except layout.html) ----
Get-ChildItem -Path $RootDir -Recurse -File | Where-Object { $_.Extension -eq ".html" -and $_.FullName -ne $LayoutPath } | ForEach-Object {
  $it=Get-Item $_.FullName; $origC=$it.CreationTimeUtc; $origW=$it.LastWriteTimeUtc
  $raw=Get-Content $_.FullName -Raw

  if($raw -match '(?is)<!--\s*ASD:REDIRECT\b'){ Write-Host ("[ASD] Skipped redirect stub: {0}" -f $_.FullName.Substring($RootDir.Length+1)); return }

  $content=Extract-Content $raw
  if($null -eq $content){ $content='' }
  $content=$content.Trim()
  $content=[regex]::Replace($content,'(\r?\n){3,}',([Environment]::NewLine + [Environment]::NewLine))

  # If this is a blog post, inject .post-nav and .related if missing
  $rel = $_.FullName.Substring($RootDir.Length + 1) -replace '\\','/'
  $isBlogPost = ($rel -match '^blog/') -and ($_.Name -ne 'index.html') -and ($_.Name -notmatch '^page-\d+\.html$')
  if($isBlogPost){
    if($prevNextMap.ContainsKey($_.Name)){
      $pn = $prevNextMap[$_.Name]
      $content = Inject-PostNav -content $content -prev $pn.Prev -next $pn.Next
    }
    $related = Build-RelatedList -posts $postsForFeed -currentName $_.Name -max 3
    if($related -and $related.Count -gt 0){
      $content = Inject-RelatedSection -content $content -items $related
    }
  }

  # Title for layout (H1 -> Title)
  $tm=[regex]::Match($content,'(?is)<h1[^>]*>(.*?)</h1>'); $pageTitle=$null
  if($tm.Success){$pageTitle=$tm.Groups[1].Value}else{$pageTitle=$_.BaseName}

  # Description for layout
  $pageDesc = Get-ASDDescription -raw $raw -content $content
  if([string]::IsNullOrWhiteSpace($pageDesc) -and $isBlogPost){
    $pageDesc = Get-FirstParagraphDesc -content $content
  }
  if([string]::IsNullOrWhiteSpace($pageDesc)){
    $pageDesc = $SiteDesc
  }

  $prefix=Get-RelPrefix -RootDir $RootDir -FilePath $_.FullName

  # ---- Ordered replacements (always do {{PREFIX}} last) ----
  $final = $Layout.Replace('{{CONTENT}}',     $content)
  $final = $final.Replace('{{TITLE}}',       $pageTitle)
  $final = $final.Replace('{{DESCRIPTION}}', $pageDesc)

  # Support {{BRAND}} and {{SITE_NAME}} (either token in layout)
  $final = $final.Replace('{{BRAND}}',     $Brand)
  $final = $final.Replace('{{SITE_NAME}}', $Brand)

  $final = $final.Replace('{{MONEY}}', $Money)
  $final = $final.Replace('{{YEAR}}',  "$Year")

  # Finally apply prefix
  $final = $final.Replace('{{PREFIX}}', $prefix)

  # Robots
  $final=AddOrReplaceMetaRobots $final (DetermineRobotsForFile $_.FullName $raw)
  # Feed links
  $final=Ensure-HeadFeeds $final $prefix $Brand

  # Canonical & rewrites
  $name=[IO.Path]::GetFileName($_.FullName)
  if($name -ieq '404.html'){
    $final = Fix-404Links $final $Base
  } else {
    $canonical = Build-Canonical -base $Base -relPath $rel
    $final = Ensure-CanonicalTag -html $final -href $canonical
    $final = Rewrite-RootLinks $final $prefix
  }

  # OG image (absolute)
  $final = Ensure-OgImageAbsolute -html $final -base $Base -root $RootDir

  $final=Normalize-DashesToPipe $final

  Set-Content -Encoding UTF8 $_.FullName $final
  Preserve-FileTimes $_.FullName $origC $origW
  Write-Host ("[ASD] Wrapped {0} (prefix='{1}')" -f $_.FullName.Substring($RootDir.Length+1), $prefix)
}

# ---- sitemap & robots ----
Write-Host "[ASD] Using base URL for sitemap: $Base"
$urls=New-Object System.Collections.Generic.List[object]
Get-ChildItem -Path $RootDir -Recurse -File -Include *.html |
  Where-Object { $_.FullName -ne $LayoutPath -and $_.FullName -notmatch '\\assets\\' -and $_.FullName -notmatch '\\partials\\' -and $_.Name -ne '404.html' } |
  ForEach-Object {
    $raw=Get-Content $_.FullName -Raw
    if($raw -match '(?is)<!--\s*ASD:REDIRECT\b'){return}
    $rel=$_.FullName.Substring($RootDir.Length+1) -replace '\\','/'
    $loc=$null
    if($rel -ieq 'index.html'){$loc=$Base}else{
      $m=[regex]::Match($rel,'^(.+)/index\.html$')
      if($m.Success){$loc=($Base.TrimEnd('/')+'/'+$m.Groups[1].Value+'/')}else{$loc=($Base.TrimEnd('/')+'/'+$rel)}
    }
    $loc=Collapse-DoubleSlashesPreserveSchemeLocal $loc
    $last=(Get-Item $_.FullName).LastWriteTime.ToString('yyyy-MM-dd')
    $urls.Add([pscustomobject]@{loc=$loc;lastmod=$last})|Out-Null
  }
$sitemapPath=Join-Path $RootDir 'sitemap.xml'
$xml=New-Object System.Text.StringBuilder
[void]$xml.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$xml.AppendLine('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">')
foreach($u in $urls | Sort-Object loc){ [void]$xml.AppendLine("  <url><loc>$($u.loc)</loc><lastmod>$($u.lastmod)</lastmod></url>") }
[void]$xml.AppendLine('</urlset>')
Set-Content -Encoding UTF8 $sitemapPath $xml.ToString()
Write-Host "[ASD] sitemap.xml generated ($($urls.Count) urls)"

$robotsPath=Join-Path $RootDir 'robots.txt'
$robots= if(Test-Path $robotsPath){ Get-Content $robotsPath -Raw } else { @"
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
"@ }
$robots=[regex]::Replace($robots,'(?im)^\s*Sitemap:\s*.*\r?\n?','')
$absMap='sitemap.xml'; if($Base -match '^[a-z]+://'){ $absMap=(New-Object Uri((New-Object Uri($Base)),'sitemap.xml')).AbsoluteUri }
if($robots -notmatch "\r?\n$"){ $robots += [Environment]::NewLine }
$robots += "Sitemap: $absMap" + [Environment]::NewLine
Set-Content -Encoding UTF8 $robotsPath $robots
Write-Host "[ASD] robots.txt: Sitemap -> $absMap"

# ---- Feeds ----
$rssPath=Join-Path $RootDir 'feed.xml'
$atomPath=Join-Path $RootDir 'atom.xml'
Generate-RssFeed  -posts $postsForFeed -base $Base -title $Brand -desc $SiteDesc -outPath $rssPath  -maxItems 20
Generate-AtomFeed -posts $postsForFeed -base $Base -title $Brand -desc $SiteDesc -outPath $atomPath -maxItems 20

# ---- Search index ----
Build-SearchIndex -BlogDir $BlogDir -RootDir $RootDir

Write-Host "[ASD] Done."
