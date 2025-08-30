# parametric-static/scripts/update-page.ps1
<#
  update-page.ps1  (PS 5.1-safe, wizard-proof)
  Edits a *page* (not a post) anywhere under the site root:
    -Path         : "about" or "legal/privacy" (".html" optional)
    -Title        : Updates first <h1> in content and <title> in <head>; also writes <!-- ASD:TITLE: ... -->
    -Description  : Updates <meta name="description"> and <!-- ASD:DESCRIPTION: ... -->
    -BodyHtml     : Replaces the content of the ASD block (keeps markers)
    -Author       : Upserts <meta name="author"> (if omitted, falls back to config author when present)
  Also robust to stray positional args (parses $__rest).
#>

#requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Path,
  [string]$Title,
  [string]$Description,
  [string]$BodyHtml,
  [string]$Author,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$__rest
)

. (Join-Path $PSScriptRoot "_lib.ps1")
$S   = Get-ASDPaths
$cfg = Get-ASDConfig -Root $S.Root

# ---------- helpers ----------
function HtmlEscape([string]$s){ if($null -eq $s){return ""}; ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;') }
function OneLine([string]$s){ if($null -eq $s){return ""}; ($s -replace '\s+',' ').Trim() }
function Clamp160([string]$s){ $t=OneLine $s; if($t.Length -gt 160){$t=$t.Substring(0,160)}; $t }

function Normalize-PagePath([string]$p){
  $p = ($p -replace '\\','/').Trim()
  if([string]::IsNullOrWhiteSpace($p)){ return $p }
  if($p -like '*.html'){ return $p }
  return ($p + '.html')
}

function Ensure-Markers($html){
  if([regex]::IsMatch($html,'(?is)<!--\s*ASD:CONTENT_START\s*-->.*<!--\s*ASD:CONTENT_END\s*-->')){ return $html }
  $m=[regex]::Match($html,'(?is)<main[^>]*>(.*?)</main>')
  if($m.Success){
    $inside = $m.Groups[1].Value
    $seg = @"
<!-- ASD:CONTENT_START -->
$inside
<!-- ASD:CONTENT_END -->
"@
    return ($html.Substring(0,$m.Index) + "<main>`r`n" + $seg + "`r`n</main>" + $html.Substring($m.Index+$m.Length))
  }
  $b=[regex]::Match($html,'(?is)<body[^>]*>(.*?)</body>')
  if($b.Success){
    $inside = $b.Groups[1].Value
    $seg = @"
<!-- ASD:CONTENT_START -->
$inside
<!-- ASD:CONTENT_END -->
"@
    return ($html.Substring(0,$b.Index) + "<body>`r`n" + $seg + "`r`n</body>" + $html.Substring($b.Index+$b.Length))
  }
  return @"
<!-- ASD:CONTENT_START -->
$html
<!-- ASD:CONTENT_END -->
"@
}

function Update-Head([string]$html,[string]$newTitle,[string]$newDesc,[string]$newAuthor){
  if(-not [string]::IsNullOrWhiteSpace($newTitle)){
    if([regex]::IsMatch($html,'(?is)<title>.*?</title>')){
      $html = [regex]::Replace($html,'(?is)(<title>)(.*?)(</title>)',{ param($m) $m.Groups[1].Value + $newTitle + $m.Groups[3].Value },1)
    } elseif($html -match '(?is)</head>'){
      $html = [regex]::Replace($html,'(?is)</head>',("  <title>$newTitle</title>`r`n</head>"),1)
    }
  }
  if(-not [string]::IsNullOrWhiteSpace($newDesc)){
    $esc = HtmlEscape (Clamp160 $newDesc)
    if([regex]::IsMatch($html,'(?is)<meta\s+name\s*=\s*"description"[^>]*>')){
      $html = [regex]::Replace($html,'(?is)(<meta\s+name\s*=\s*"description"\s+content\s*=\s*")(.*?)(")',{ param($m) $m.Groups[1].Value + $esc + $m.Groups[3].Value },1)
    } elseif($html -match '(?is)</head>'){
      $html = [regex]::Replace($html,'(?is)</head>',("  <meta name=""description"" content=""$esc"">`r`n</head>"),1)
    }
  }
  if(-not [string]::IsNullOrWhiteSpace($newAuthor)){
    $escA = HtmlEscape $newAuthor
    if([regex]::IsMatch($html,'(?is)<meta\s+name\s*=\s*"author"[^>]*>')){
      $html = [regex]::Replace($html,'(?is)(<meta\s+name\s*=\s*"author"\s+content\s*=\s*")(.*?)(")',{ param($m) $m.Groups[1].Value + $escA + $m.Groups[3].Value },1)
    } elseif($html -match '(?is)</head>'){
      $html = [regex]::Replace($html,'(?is)</head>',("  <meta name=""author"" content=""$escA"">`r`n</head>"),1)
    }
  }
  return $html
}

function Update-ContentSegment([string]$segment,[string]$newTitle,[string]$newDesc,[string]$newBody){
  $seg = $segment
  if(-not [string]::IsNullOrWhiteSpace($newBody)){ $seg = $newBody }

  if(-not [string]::IsNullOrWhiteSpace($newTitle)){
    if([regex]::IsMatch($seg,'(?is)<h1[^>]*>.*?</h1>')){
      $seg = [regex]::Replace($seg,'(?is)(<h1[^>]*>)(.*?)(</h1>)',{ param($m) $m.Groups[1].Value + $newTitle + $m.Groups[3].Value },1)
    } else {
      $seg = "<h1>$newTitle</h1>`r`n" + $seg
    }
  }
  if(-not [string]::IsNullOrWhiteSpace($newTitle)){
    if([regex]::IsMatch($seg,'(?is)<!--\s*ASD:TITLE:')){
      $seg = [regex]::Replace($seg,'(?is)<!--\s*ASD:TITLE:\s*.*?-->','<!-- ASD:TITLE: ' + $newTitle + ' -->',1)
    } else {
      $seg = $seg + "`r`n" + '<!-- ASD:TITLE: ' + $newTitle + ' -->'
    }
  }
  if(-not [string]::IsNullOrWhiteSpace($newDesc)){
    $desc160 = Clamp160 $newDesc
    if([regex]::IsMatch($seg,'(?is)<!--\s*ASD:DESCRIPTION:')){
      $seg = [regex]::Replace($seg,'(?is)<!--\s*ASD:DESCRIPTION:\s*.*?-->','<!-- ASD:DESCRIPTION: ' + $desc160 + ' -->',1)
    } else {
      $seg = $seg + "`r`n" + '<!-- ASD:DESCRIPTION: ' + $desc160 + ' -->'
    }
  }
  # Clean "<h1>- Title</h1>" placeholder
  if(-not [string]::IsNullOrWhiteSpace($newTitle)){
    $seg = [regex]::Replace($seg,'(?is)<h1[^>]*>\s*-\s*Title\s*</h1>','<h1>' + $newTitle + '</h1>',1)
  }
  return $seg
}

# ---------- tolerate bad arg passing (wizard fallbacks) ----------
if (($Path -eq '-Path' -or [string]::IsNullOrWhiteSpace($Path)) -and $null -ne $__rest -and $__rest.Count -gt 0) {
  # normalize unicode dashes
  for ($i=0; $i -lt $__rest.Count; $i++){ $__rest[$i] = [string]$__rest[$i] -replace '^[\u2012\u2013\u2014\u2212]', '-' }
  for ($i=0; $i -lt $__rest.Count; $i++){
    $t = [string]$__rest[$i]
    $nxt = if ($i+1 -lt $__rest.Count -and -not ([string]$__rest[$i+1]).StartsWith('-')) { [string]$__rest[$i+1] } else { $null }
    switch -regex ($t) {
      '^(?i)-Path$'        { if ($nxt -ne $null) { $Path        = $nxt } continue }
      '^(?i)-Title$'       { if ($nxt -ne $null) { $Title       = $nxt } continue }
      '^(?i)-Description$' { if ($nxt -ne $null) { $Description = $nxt } continue }
      '^(?i)-BodyHtml$'    { if ($nxt -ne $null) { $BodyHtml    = $nxt } continue }
      '^(?i)-Author$'      { if ($nxt -ne $null) { $Author      = $nxt } continue }
      default {
        if ([string]::IsNullOrWhiteSpace($Path) -and -not $t.StartsWith('-')) { $Path = $t; continue }
      }
    }
  }
}

# ---------- locate file ----------
$rel = Normalize-PagePath $Path
$fs  = Join-Path $S.Root $rel
if(-not (Test-Path $fs)){
  Write-Error ("Page not found: {0}" -f $rel)
  exit 1
}

# ---------- load & ensure markers ----------
$html = Get-Content $fs -Raw
$html = Ensure-Markers $html

# ---------- split at markers ----------
$m = [regex]::Match($html,'(?is)(.*?<!--\s*ASD:CONTENT_START\s*-->)(.*?)(<!--\s*ASD:CONTENT_END\s*-->.*)')
if($m.Success){
  $prefix  = $m.Groups[1].Value
  $segment = $m.Groups[2].Value
  $suffix  = $m.Groups[3].Value
} else {
  $prefix  = ''
  $segment = $html
  $suffix  = ''
}

# ---------- derive author fallback from config ----------
$cfgAuthor = $null
try {
  if($cfg -ne $null){
    if($cfg.PSObject.Properties.Name -contains 'author' -and $cfg.author -ne $null){
      if($cfg.author.PSObject.Properties.Name -contains 'name' -and -not [string]::IsNullOrWhiteSpace($cfg.author.name)){ $cfgAuthor = [string]$cfg.author.name }
    } elseif($cfg.PSObject.Properties.Name -contains 'AuthorName' -and -not [string]::IsNullOrWhiteSpace($cfg.AuthorName)){
      $cfgAuthor = [string]$cfg.AuthorName
    }
  }
} catch {}

$wantAuth  = if ($PSBoundParameters.ContainsKey('Author')) { $Author } else { $cfgAuthor }
$wantTitle = $Title
$wantDesc  = $Description
$wantBody  = $BodyHtml

# ---------- apply updates ----------
$segment = Update-ContentSegment -segment $segment -newTitle $wantTitle -newDesc $wantDesc -newBody $wantBody
$html    = $prefix + $segment + $suffix
$html    = Update-Head -html $html -newTitle $wantTitle -newDesc $wantDesc -newAuthor $wantAuth

# ---------- save ----------
Set-Content -Encoding UTF8 $fs $html
Write-Host ("[ASD] Updated page: {0} (markers ensured; H1/title/description applied)" -f $rel)
