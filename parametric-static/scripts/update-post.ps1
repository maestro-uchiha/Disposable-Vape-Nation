<#
  update-post.ps1  (PS 5.1-safe, wizard-proof)
  Update an existing blog post:
    -Slug (required)
    -Title (optional)
    -Description (optional)  -> clamps to 160 chars (collapsed whitespace)
    -BodyHtml (optional)     -> replaces the content between ASD markers
    -Author  (optional)      -> upserts <meta name="author">

  Hardened for wizard quirks:
  - Accepts correct named calls AND sloppy token arrays.
  - Captures leftover args so long descriptions never crash binding.
  - Accepts slugs with/without ".html" and trims inputs.
  - Keeps ASD markers; injects <!-- ASD:DESCRIPTION: ... --> inside content.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Slug,
  [string]$Title,
  [string]$Description,
  [string]$BodyHtml,
  [string]$Author,
  # Capture anything the binder can't match (prevents "positional parameter" errors)
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$__rest
)

. (Join-Path $PSScriptRoot "_lib.ps1")
$S   = Get-ASDPaths
$cfg = Get-ASDConfig -Root $S.Root

# ---------------- helpers ----------------
$defaultAuthor = 'Maestro'

function HtmlEscape([string]$s) {
  if ($null -eq $s) { return "" }
  $s = $s -replace '&','&amp;'
  $s = $s -replace '<','&lt;'
  $s = $s -replace '>','&gt;'
  $s = $s -replace '"','&quot;'
  return $s
}
function OneLine([string]$s) {
  if ($null -eq $s) { return "" }
  return ($s -replace '\s+',' ').Trim()
}
function Clamp160([string]$s) {
  $t = OneLine $s
  if ($t.Length -gt 160) { $t = $t.Substring(0,160) }
  return $t
}
function Normalize-Slug([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $s }
  $name = [IO.Path]::GetFileName($s.Trim())
  if ($name -like '*.html') { $name = [IO.Path]::GetFileNameWithoutExtension($name) }
  return $name
}

# --- Tolerate wizard token arrays / weird dashes ---
# 1) If the wizard passed "-Slug" style into $Slug slot, shift once.
if ($Slug -eq '-Slug' -and -not [string]::IsNullOrWhiteSpace($Title)) {
  $Slug        = $Title
  $Title       = $Description
  $Description = $BodyHtml
  $BodyHtml    = $Author
  $Author      = $null
}
# 2) Parse $__rest for pairs like -Title "x" -Description "y"
if ($__rest -and $__rest.Count -gt 0) {
  # Normalize any leading en/em dashes to hyphen
  for ($i=0; $i -lt $__rest.Count; $i++) { $__rest[$i] = [string]$__rest[$i] -replace '^[\u2012\u2013\u2014\u2212]', '-' }
  for ($i=0; $i -lt $__rest.Count; $i++) {
    $t = [string]$__rest[$i]
    if ($t -notmatch '^-') { continue }
    $nxt = if ($i+1 -lt $__rest.Count -and -not ([string]$__rest[$i+1]).StartsWith('-')) { [string]$__rest[$i+1] } else { $null }
    switch -regex ($t) {
      '^(?i)-Slug$'        { if ($nxt -ne $null){ $Slug = $nxt }; continue }
      '^(?i)-Title$'       { if ($nxt -ne $null){ $Title = $nxt }; continue }
      '^(?i)-Description$' { if ($nxt -ne $null){ $Description = $nxt }; continue }
      '^(?i)-BodyHtml$'    { if ($nxt -ne $null){ $BodyHtml = $nxt }; continue }
      '^(?i)-Author$'      { if ($nxt -ne $null){ $Author = $nxt }; continue }
    }
  }
}

# Final slug normalization
$Slug = Normalize-Slug $Slug

# Resolve path and validate
$postPath = Join-Path $S.Blog ($Slug + ".html")
if (-not (Test-Path $postPath)) {
  Write-Error "Post not found: $postPath"
  # Show a few candidates to help
  $hint = (Get-ChildItem -Path $S.Blog -Filter '*.html' -File | Where-Object { $_.BaseName -like "*$Slug*" } | Select-Object -First 5 -ExpandProperty Name) -join ', '
  if ($hint) { Write-Host "[ASD] Did you mean: $hint" }
  exit 1
}

# Load the file
$html = Get-Content $postPath -Raw

# Ensure ASD markers exist around the main body
$hasMarkers = [regex]::IsMatch($html, '(?is)<!--\s*ASD:CONTENT_START\s*-->.*<!--\s*ASD:CONTENT_END\s*-->')
if (-not $hasMarkers) {
  $bodyMatch = [regex]::Match($html, '(?is)<body[^>]*>(.*?)</body>')
  $inside = if ($bodyMatch.Success) { $bodyMatch.Groups[1].Value } else { $html }
  $seg = @"
<!-- ASD:CONTENT_START -->
$inside
<!-- ASD:CONTENT_END -->
"@
  if ($bodyMatch.Success) {
    $html = $html.Substring(0, $bodyMatch.Index) + "<body>`r`n$seg`r`n</body>" + $html.Substring($bodyMatch.Index + $bodyMatch.Length)
  } else {
    $html = $seg
  }
}

# ---------------- updates ----------------

# Replace the content between markers first (so later edits survive)
if ($PSBoundParameters.ContainsKey('BodyHtml') -and -not [string]::IsNullOrWhiteSpace($BodyHtml)) {
  $newSeg = @"
<!-- ASD:CONTENT_START -->
$BodyHtml
<!-- ASD:CONTENT_END -->
"@
  $html = [regex]::Replace(
    $html,
    '(?is)<!--\s*ASD:CONTENT_START\s*-->.*?<!--\s*ASD:CONTENT_END\s*-->',
    { param($m) $newSeg },
    1
  )
}

# Update <title> (head)
if ($PSBoundParameters.ContainsKey('Title') -and -not [string]::IsNullOrWhiteSpace($Title)) {
  if ([regex]::IsMatch($html, '(?is)<title>.*?</title>')) {
    $html = [regex]::Replace($html,'(?is)(<title>)(.*?)(</title>)',{ param($m) $m.Groups[1].Value + $Title + $m.Groups[3].Value },1)
  } elseif ($html -match '(?is)</head>') {
    $html = [regex]::Replace($html,'(?is)</head>',("  <title>$Title</title>`r`n</head>"),1)
  }
}

# Update first <h1> inside marker block to match Title (if provided)
if ($PSBoundParameters.ContainsKey('Title') -and -not [string]::IsNullOrWhiteSpace($Title)) {
  $html = [regex]::Replace(
    $html,
    '(?is)(<!--\s*ASD:CONTENT_START\s*-->)(.*?)(<!--\s*ASD:CONTENT_END\s*-->)',
    {
      param($m)
      $seg = $m.Groups[2].Value
      if ([regex]::IsMatch($seg,'(?is)<h1[^>]*>.*?</h1>')) {
        $seg = [regex]::Replace($seg,'(?is)(<h1[^>]*>)(.*?)(</h1>)',{ param($mm) $mm.Groups[1].Value + $Title + $mm.Groups[3].Value },1)
      } else {
        $seg = ("<h1>" + $Title + "</h1>`r`n" + $seg)
      }
      $m.Groups[1].Value + $seg + $m.Groups[3].Value
    },
    1
  )
}

# Upsert meta description (head) AND ASD:DESCRIPTION (inside content), clamped to 160 chars
if ($PSBoundParameters.ContainsKey('Description')) {
  $descClamped = Clamp160 $Description
  $descEsc     = HtmlEscape $descClamped

  # 1) <meta name="description"> in <head>
  if ([regex]::IsMatch($html,'(?is)<meta\s+name\s*=\s*"description"[^>]*>')) {
    $html = [regex]::Replace($html,'(?is)(<meta\s+name\s*=\s*"description"\s+content\s*=\s*")(.*?)(")',{ param($m) $m.Groups[1].Value + $descEsc + $m.Groups[3].Value },1)
  } elseif ($html -match '(?is)</head>') {
    $html = [regex]::Replace($html,'(?is)</head>',("  <meta name=""description"" content=""$descEsc"">`r`n</head>"),1)
  }

  # 2) ASD:DESCRIPTION just before end of marker block
  $html = [regex]::Replace(
    $html,
    '(?is)(<!--\s*ASD:CONTENT_START\s*-->)(.*?)(<!--\s*ASD:CONTENT_END\s*-->)',
    {
      param($m)
      $seg = $m.Groups[2].Value
      if ([regex]::IsMatch($seg,'(?is)<!--\s*ASD:DESCRIPTION:')) {
        $seg = [regex]::Replace($seg,'(?is)<!--\s*ASD:DESCRIPTION:\s*.*?-->', '<!-- ASD:DESCRIPTION: ' + $descClamped + ' -->', 1)
      } else {
        if ($seg -notmatch '\r?\n$') { $seg += "`r`n" }
        $seg += '<!-- ASD:DESCRIPTION: ' + $descClamped + ' -->' + "`r`n"
      }
      $m.Groups[1].Value + $seg + $m.Groups[3].Value
    },
    1
  )
}

# Upsert meta author only if -Author provided
if ($PSBoundParameters.ContainsKey('Author')) {
  $authorToUse = if (-not [string]::IsNullOrWhiteSpace($Author)) { $Author } else {
    if ($cfg -ne $null) {
      if ($cfg.PSObject.Properties.Name -contains 'AuthorName' -and -not [string]::IsNullOrWhiteSpace($cfg.AuthorName)) { $cfg.AuthorName }
      elseif ($cfg.PSObject.Properties.Name -contains 'author' -and $cfg.author -ne $null) {
        if ($cfg.author.PSObject.Properties.Name -contains 'name' -and -not [string]::IsNullOrWhiteSpace($cfg.author.name)) { $cfg.author.name }
        elseif ($cfg.author.PSObject.Properties.Name -contains 'Name' -and -not [string]::IsNullOrWhiteSpace($cfg.author.Name)) { $cfg.author.Name }
        else { $defaultAuthor }
      } else { $defaultAuthor }
    } else { $defaultAuthor }
  }
  $authorEsc = HtmlEscape $authorToUse

  if ([regex]::IsMatch($html,'(?is)<meta\s+name\s*=\s*"author"[^>]*>')) {
    $html = [regex]::Replace($html,'(?is)(<meta\s+name\s*=\s*"author"\s+content\s*=\s*")(.*?)(")',{ param($m) $m.Groups[1].Value + $authorEsc + $m.Groups[3].Value },1)
  } elseif ($html -match '(?is)</head>') {
    $html = [regex]::Replace($html,'(?is)</head>',("  <meta name=""author"" content=""$authorEsc"">`r`n</head>"),1)
  }
}

# Save
Set-Content -Encoding UTF8 $postPath $html
Write-Host "[ASD] Updated blog\$Slug.html (markers ensured; description clamped to 160 chars)"
