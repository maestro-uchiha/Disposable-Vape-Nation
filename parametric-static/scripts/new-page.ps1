# new-page.ps1  (PS 5.1-safe)
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Title,
  [Parameter(Mandatory=$true)][string]$Path,
  [string]$Description = "",
  [string]$BodyHtml = ""
)

. (Join-Path $PSScriptRoot "_lib.ps1")
$S = Get-ASDPaths
$cfg = Get-ASDConfig -Root $S.Root

function Clean-Rel([string]$p){
  if ([string]::IsNullOrWhiteSpace($p)) { return "page" }
  $p = $p.Trim().Trim('/')
  $p = $p -replace '\\','/'
  if ($p -notmatch '\.html?$'){ $p += ".html" }
  return $p
}
function HtmlEscape([string]$s){ if($null -eq $s){return ""}; $s = $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;'; $s }
function Clamp160([string]$s){ $t=($s -replace '\s+',' ').Trim(); if($t.Length -gt 160){$t=$t.Substring(0,160)}; $t }

$rel = Clean-Rel $Path
$dest = Join-Path $S.Root $rel
$dir = Split-Path -Parent $dest
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

$desc = if([string]::IsNullOrWhiteSpace($Description)) { "" } else { Clamp160 $Description }
$descEsc = HtmlEscape $desc
$titleEsc = HtmlEscape $Title

if ([string]::IsNullOrWhiteSpace($BodyHtml)) {
$BodyHtml = @"
<article>
  <h1>$titleEsc</h1>
  <p>$descEsc</p>
  <!-- ASD:DESCRIPTION: $desc -->
</article>
"@
}

$html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>$titleEsc</title>
  <meta name="description" content="$descEsc">
</head>
<body>
<!-- ASD:CONTENT_START -->
$BodyHtml
<!-- ASD:CONTENT_END -->
</body>
</html>
"@

Set-Content -Encoding UTF8 $dest $html
Write-Host "[ASD] New page created: $rel"
