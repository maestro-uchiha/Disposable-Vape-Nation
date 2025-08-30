<# ===============================
   ASD shared helpers (_lib.ps1)
   - Paths discovery
   - Config load/save (config.json is the single source of truth)
   - Backward-compat migration from old { "site": { ... } } schema
   - URL + HTML helpers
   - Robust Extract-Content supports ASD:CONTENT_* and ASD:BODY_*
   =============================== #>

# Remember where this file lives (scripts folder)
$script:ASD_ScriptsDir = $PSScriptRoot

function Get-ASDPaths {
  <#
    Returns a PSCustomObject with:
      Root       -> parametric-static
      Scripts    -> parametric-static\scripts
      Blog       -> parametric-static\blog
      Drafts     -> parametric-static\drafts
      Config     -> parametric-static\config.json
      Redirects  -> parametric-static\redirects.json
      Layout     -> parametric-static\layout.html
  #>
  $scriptsDir = $script:ASD_ScriptsDir
  if ([string]::IsNullOrWhiteSpace($scriptsDir)) {
    $scriptsDir = Split-Path -Parent $PSCommandPath
  }

  try {
    $root = (Resolve-Path (Join-Path $scriptsDir "..")).Path
  } catch {
    $root = Split-Path $scriptsDir -Parent
  }

  [pscustomobject]@{
    Root      = $root
    Scripts   = $scriptsDir
    Blog      = (Join-Path $root "blog")
    Drafts    = (Join-Path $root "drafts")
    Config    = (Join-Path $root "config.json")
    Redirects = (Join-Path $root "redirects.json")
    Layout    = (Join-Path $root "layout.html")
  }
}

function Ensure-AbsoluteBaseUrl {
  param([string]$u)
  if ([string]::IsNullOrWhiteSpace($u)) { return "/" }

  $u = $u.Trim()

  # If absolute (has a scheme)
  if ($u -match '^[a-z]+://') {
    # Fix "https:/foo" -> "https://foo" (ensure two slashes after scheme)
    $u = $u -replace '(^[a-z]+:)/','${1}//'

    # Preserve scheme while collapsing duplicate slashes only in the path
    if ($u -match '^([a-z]+://)(.*)$') {
      $scheme = $matches[1]
      $rest   = $matches[2]

      # normalize path part
      $rest = $rest.TrimEnd('/')
      $rest = $rest -replace '/{2,}','/'

      return $scheme + $rest + '/'
    }

    # Fallback (shouldn’t hit)
    return ($u.TrimEnd('/') + '/')
  }

  # Rooted path (project pages like /repo/)
  if ($u -eq "/") { return "/" }
  return "/" + ($u.Trim('/')) + "/"
}


# Safely add or overwrite a NoteProperty on a PSCustomObject
function AddOrSet-Prop {
  param(
    [Parameter(Mandatory=$true)] [psobject] $Object,
    [Parameter(Mandatory=$true)] [string]   $Name,
    [Parameter(Mandatory=$true)] $Value
  )
  if ($Object.PSObject.Properties.Name -contains $Name) {
    $Object.$Name = $Value
  } else {
    Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value -Force | Out-Null
  }
}

function Save-ASDConfig {
  param([Parameter(Mandatory=$true)][psobject]$Config)
  $paths = Get-ASDPaths
  $Config | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $paths.Config
  Write-Host "[ASD] config.json updated -> $($paths.Config)"
}

function Get-ASDConfig {
  <#
    Loads config.json (single source of truth).
    If missing or malformed, creates a default.
    If an older { "site": { ... } } schema is detected, migrates to flat:
      SiteName, StoreUrl, Description, BaseUrl
  #>
  $paths   = Get-ASDPaths
  $cfgPath = $paths.Config

  $cfg = $null
  if (Test-Path $cfgPath) {
    try {
      $raw = Get-Content $cfgPath -Raw
      if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
      }
    } catch {
      Write-Warning "[ASD] Could not parse config.json. A fresh default will be created."
    }
  }

  $created  = $false
  $migrated = $false

  if ($null -eq $cfg) {
    # Fresh default flat schema
    $cfg = [pscustomobject]@{}
    AddOrSet-Prop $cfg 'SiteName'    'Amaterasu Static Deploy'
    AddOrSet-Prop $cfg 'StoreUrl'    'https://example.com'
    AddOrSet-Prop $cfg 'Description' 'Premium Amaterasu Static Deploy | quality, reliability, trust.'
    AddOrSet-Prop $cfg 'BaseUrl'     '/'
    $created = $true
  } else {
    # If it's the old nested schema, migrate it to flat properties
    if ($cfg.PSObject.Properties.Name -contains 'site') {
      $site = $cfg.site

      $siteName = $null
      if ($site -and ($site.PSObject.Properties.Name -contains 'name')) {
        if (-not [string]::IsNullOrWhiteSpace($site.name)) { $siteName = $site.name }
      }
      if ([string]::IsNullOrWhiteSpace($siteName)) { $siteName = 'Amaterasu Static Deploy' }

      $desc = $null
      if ($site -and ($site.PSObject.Properties.Name -contains 'description')) {
        if (-not [string]::IsNullOrWhiteSpace($site.description)) { $desc = $site.description }
      }
      if ([string]::IsNullOrWhiteSpace($desc)) {
        $desc = "Premium $siteName | quality, reliability, trust."
      }

      $store = $null
      if ($site -and ($site.PSObject.Properties.Name -contains 'storeUrl')) {
        if (-not [string]::IsNullOrWhiteSpace($site.storeUrl)) { $store = $site.storeUrl }
      } elseif ($cfg.PSObject.Properties.Name -contains 'storeUrl') {
        if (-not [string]::IsNullOrWhiteSpace($cfg.storeUrl)) { $store = $cfg.storeUrl }
      }
      if ([string]::IsNullOrWhiteSpace($store)) { $store = 'https://example.com' }

      $baseUrl = $null
      foreach ($k in @('baseUrl','url','base')) {
        if ($site -and ($site.PSObject.Properties.Name -contains $k)) {
          $v = $site.$k
          if (-not [string]::IsNullOrWhiteSpace($v)) { $baseUrl = $v; break }
        }
      }
      if ([string]::IsNullOrWhiteSpace($baseUrl)) { $baseUrl = '/' }

      $new = [pscustomobject]@{}
      AddOrSet-Prop $new 'SiteName'    $siteName
      AddOrSet-Prop $new 'StoreUrl'    $store
      AddOrSet-Prop $new 'Description' $desc
      AddOrSet-Prop $new 'BaseUrl'     $baseUrl

      $cfg = $new
      $migrated = $true
    }

    # Ensure required keys exist on flat schema
    if (-not ($cfg.PSObject.Properties.Name -contains 'SiteName')    -or [string]::IsNullOrWhiteSpace($cfg.SiteName))    { AddOrSet-Prop $cfg 'SiteName'    'Amaterasu Static Deploy' }
    if (-not ($cfg.PSObject.Properties.Name -contains 'StoreUrl')    -or [string]::IsNullOrWhiteSpace($cfg.StoreUrl))    { AddOrSet-Prop $cfg 'StoreUrl'    'https://example.com' }
    if (-not ($cfg.PSObject.Properties.Name -contains 'Description') -or [string]::IsNullOrWhiteSpace($cfg.Description)) { AddOrSet-Prop $cfg 'Description' ("Premium " + $cfg.SiteName + " | quality, reliability, trust.") }
    if (-not ($cfg.PSObject.Properties.Name -contains 'BaseUrl')     -or [string]::IsNullOrWhiteSpace($cfg.BaseUrl))     { AddOrSet-Prop $cfg 'BaseUrl'     '/' }
  }

  # Normalize BaseUrl to absolute-like (absolute http(s) OR rooted "/.../")
  $normBase = Ensure-AbsoluteBaseUrl $cfg.BaseUrl
  AddOrSet-Prop $cfg 'BaseUrl' $normBase

  if ($created)  { Save-ASDConfig $cfg }
  if ($migrated) { Save-ASDConfig $cfg }

  return $cfg
}

function Normalize-DashesToPipe {
  param([string]$s)
  if ($null -eq $s) { return $s }
  $pipe = '|'
  $s = $s.Replace([string][char]0x2013, $pipe) # en dash
  $s = $s.Replace([string][char]0x2014, $pipe) # em dash
  $s = $s.Replace('&ndash;', $pipe).Replace('&mdash;', $pipe)
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

function Extract-Content {
  param([string]$raw)

  if ([string]::IsNullOrWhiteSpace($raw)) { return $raw }

  # 1) ASD markers take precedence (CONTENT_* or BODY_*)
  $mark = [regex]::Match($raw, '(?is)<!--\s*ASD:(CONTENT|BODY)_START\s*-->(.*?)<!--\s*ASD:(CONTENT|BODY)_END\s*-->')
  if ($mark.Success) {
    return $mark.Groups[2].Value
  }

  # 2) Fallback to <main>, else <body>
  $m = [regex]::Match($raw, '(?is)<main\b[^>]*>(.*?)</main>')
  if ($m.Success) { $raw = $m.Groups[1].Value } else {
    $b = [regex]::Match($raw, '(?is)<body\b[^>]*>(.*?)</body>')
    if ($b.Success) { $raw = $b.Groups[1].Value }
  }

  # 3) Strip SSIs and any existing header/nav/footer wrappers
  $raw = [regex]::Replace($raw, '(?is)<!--#include\s+virtual="partials/.*?-->', '')
  $raw = [regex]::Replace($raw, '(?is)<header\b[^>]*>.*?</header>', '')
  $raw = [regex]::Replace($raw, '(?is)<nav\b[^>]*>.*?</nav>', '')
  $raw = [regex]::Replace($raw, '(?is)<footer\b[^>]*>.*?</footer>', '')
  # If another <main> wrapper remains, drop it
  $raw = [regex]::Replace($raw, '(?is)</?main\b[^>]*>', '')

  return $raw
}

function Get-RelPrefix {
  param([string]$RootDir, [string]$FilePath)
  $fileDir = Split-Path $FilePath -Parent
  $rootSeg = ($RootDir.TrimEnd('\')).Split('\')
  $dirSeg  = ($fileDir.TrimEnd('\')).Split('\')
  $depth = $dirSeg.Length - $rootSeg.Length
  if ($depth -lt 1) { return '' }
  $p = ''
  for ($i=0; $i -lt $depth; $i++) { $p += '../' }
  return $p
}

function Collapse-DoubleSlashesPreserveScheme {
  param([string]$url)
  if ([string]::IsNullOrWhiteSpace($url)) { return $url }
  if ($url -match '^(https?://)(.*)$') {
    $scheme = $matches[1]
    $rest   = $matches[2] -replace '/{2,}','/'
    return $scheme + $rest
  }
  return ($url -replace '/{2,}','/')
}
