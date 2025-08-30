param(
  [Parameter(Mandatory=$true)]
  [string]$Slug
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

$root = (Resolve-Path "$PSScriptRoot/..").Path
$blogDir = Join-Path $root "blog"
$feedPath = Join-Path $root "feed.xml"
$configPath = Join-Path $root "config.json"

# Normalize input: allow full path or filename; strip .html; normalize dashes
$in = $Slug
if ($in -match '[\\/]|\.html$') { $in = [IO.Path]::GetFileNameWithoutExtension($in) }
$in = $in.Trim()
$in = ($in -replace '[\u2013\u2014]', '-')              # en/em dash → hyphen
$in = ($in -replace '\s+', '-')                         # spaces → hyphen

# Preferred target path
$target = Join-Path $blogDir ($in + ".html")

# If not found, try a tolerant lookup by basename (case-insensitive; dash-normalized)
if (-not (Test-Path $target)) {
  $cand = Get-ChildItem -Path $blogDir -Filter *.html -File |
    Where-Object {
      ($_.BaseName -ieq $in) -or
      (($_.BaseName -replace '[\u2013\u2014]', '-') -ieq $in)
    } |
    Select-Object -First 1

  if ($cand) { $target = $cand.FullName }
}

if (-not (Test-Path $target)) {
  Write-Error "Post not found: $target"
  Write-Host "`nExisting posts:"
  Get-ChildItem -Path $blogDir -Filter *.html -File | Select-Object -ExpandProperty Name
  exit 1
}

# Compute slug from the file we’re actually deleting
$basename = [IO.Path]::GetFileNameWithoutExtension($target)

# Delete the file
Remove-Item -Force $target
Write-Host "[ASD] Deleted blog/$basename.html"

# Try to update feed.xml (best-effort)
if (Test-Path $feedPath) {
  try {
    [xml]$rss = Get-Content $feedPath
    $chan = $rss.rss.channel
    if ($chan -and $chan.item) {
      # Determine absolute link base if config.site.url is set
      $base = ""
      if (Test-Path $configPath) {
        try {
          $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
          if ($cfg.site -and $cfg.site.url) { $base = [string]$cfg.site.url }
        } catch {}
      }
      $relLink  = "/blog/$basename.html"
      $absLink1 = ($base.TrimEnd('/') + $relLink)     # https://.../blog/slug.html
      $absLink2 = ($base.TrimEnd('/') + "/blog/$basename.html")

      $toRemove = @()
      foreach ($it in @($chan.item)) {
        $linkNode = $it.link
        $guidNode = $it.guid
        $linkVal = if ($linkNode) { $linkNode.InnerText } else { "" }
        $guidVal = if ($guidNode) { $guidNode.InnerText } else { "" }
        if ($linkVal -eq $absLink1 -or $linkVal -eq $absLink2 -or $linkVal -eq $relLink -or
            $guidVal -eq $absLink1 -or $guidVal -eq $absLink2 -or $guidVal -eq $relLink) {
          $toRemove += $it
        }
      }
      foreach ($it in $toRemove) { [void]$chan.RemoveChild($it) }
      if ($toRemove.Count -gt 0) {
        $rss.Save($feedPath)
        Write-Host "[ASD] feed.xml updated (removed $($toRemove.Count) item(s))"
      }
    }
  } catch {
    Write-Warning "[ASD] Could not update feed.xml: $_"
  }
}

Write-Host "`nNext steps:"
Write-Host "  .\parametric-static\scripts\build-blog-index.ps1 -PageSize 10"
Write-Host "  .\parametric-static\scripts\bake.ps1 -Brand \"Ace Ultra Premium\" -Money \"https://acecartstore.com\""
