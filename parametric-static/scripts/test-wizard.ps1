<#
ASD test-wizard.ps1
- Creates a fresh TEMP sandbox
- Copies the entire parametric-static folder (so all scripts are available)
- Runs: new-post, update-post, rename-post (with redirect), extract/apply draft,
        delete-post, redirects add/disable/enable/remove, pagination, bake, link check
- Prints a summary; removes sandbox unless -KeepSandbox

Usage:
  .\parametric-static\scripts\test-wizard.ps1 [-PageSize 2] [-KeepSandbox]
#>

param(
  [int]$PageSize = 2,
  [switch]$KeepSandbox
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

# ------------- helpers -------------
$ErrorActionPreference = 'Stop'
$failCount = 0

function _ok {
  param([string]$msg, [bool]$cond)
  if ($cond) {
    Write-Host "[OK] $msg" -ForegroundColor Green
  } else {
    $script:failCount++
    Write-Host "[FAIL] $msg" -ForegroundColor Red
  }
}

function NowStamp {
  return (Get-Date).ToString('yyyyMMdd-HHmmss')
}

# ------------- derive paths -------------
$HereScripts = Split-Path -Parent $PSCommandPath
$RepoRoot    = Split-Path -Parent $HereScripts            # -> parametric-static
$RepoRootRoot= Split-Path -Parent $RepoRoot               # -> repo root
if (-not (Test-Path (Join-Path $RepoRoot 'scripts\new-post.ps1'))) {
  throw "Run this from the repo that contains parametric-static\scripts\*.ps1"
}

# ------------- make sandbox -------------
$sbRoot = Join-Path $env:TEMP ("asd-sandbox-" + (NowStamp))
$sbPS   = Join-Path $sbRoot "parametric-static\scripts"
$sbPSDir= Join-Path $sbRoot "parametric-static"
Write-Host "[ASD TEST] Creating sandbox at: $sbRoot" -ForegroundColor Cyan

# Copy the entire parametric-static (so ALL scripts/files exist in sandbox)
New-Item -Force -ItemType Directory -Path $sbRoot | Out-Null
Copy-Item -Recurse -Force -LiteralPath (Join-Path $RepoRootRoot 'parametric-static') -Destination $sbRoot

# All test operations run INSIDE the sandbox
Set-Location $sbRoot

# quick accessors
$S = [pscustomobject]@{
  Root   = (Join-Path $sbRoot 'parametric-static')
  Blog   = (Join-Path $sbRoot 'parametric-static\blog')
  Drafts = (Join-Path $sbRoot 'parametric-static\drafts')
  PS     = $sbPS
}

# ------------- test data -------------
$slug1         = "tw-post-one"
$slug2         = "tw-post-two"
$slugRenamed   = "tw-post-renamed"
$title1        = "Test Post One"
$title2        = "Test Post Two"
$titleUpdated  = "Test Post One Updated"
$descUpdated   = "Updated short description."
$bodyUpdated   = "<p>Updated body paragraph for automated test.</p>"
$brand         = "ASD Test"
$money         = "https://example.com"

# Ensure clean collisions if the test is re-run with -KeepSandbox
$renamedPath = Join-Path $S.Blog "$slugRenamed.html"
if (Test-Path $renamedPath) { Remove-Item -Force $renamedPath }

# ------------- STEP 1: new-post (2 posts) -------------
& "$($S.PS)\new-post.ps1" -Title $title1 -Slug $slug1 -Description "desc 1" -Date (Get-Date -Format 'yyyy-MM-dd') | Out-Null
& "$($S.PS)\new-post.ps1" -Title $title2 -Slug $slug2 -Description "desc 2" -Date (Get-Date -Format 'yyyy-MM-dd') | Out-Null
_ok "blog/$slug1.html created" (Test-Path (Join-Path $S.Blog "$slug1.html"))
_ok "blog/$slug2.html created" (Test-Path (Join-Path $S.Blog "$slug2.html"))

# ------------- STEP 2: update-post (slug1) -------------
& "$($S.PS)\update-post.ps1" -Slug $slug1 -Title $titleUpdated -Description $descUpdated -BodyHtml $bodyUpdated | Out-Null
$updated = (Get-Content (Join-Path $S.Blog "$slug1.html") -Raw)
_ok "update-post wrote new title" ($updated -match [regex]::Escape($titleUpdated))
_ok "update-post wrote new body"  ($updated -match [regex]::Escape($bodyUpdated))

# ------------- STEP 3: rename-post (slug1 -> slugRenamed, with redirect) -------------
& "$($S.PS)\rename-post.ps1" -OldSlug $slug1 -NewSlug $slugRenamed -LeaveRedirect | Out-Null
_ok "renamed file exists" (Test-Path (Join-Path $S.Blog "$slugRenamed.html"))
# Because -LeaveRedirect, the old file SHOULD REMAIN as a redirect stub
$oldPath = Join-Path $S.Blog "$slug1.html"
_ok "old stub kept" (Test-Path $oldPath)
$oldHtml = (Get-Content $oldPath -Raw)
_ok "old stub contains redirect meta" ($oldHtml -match 'http-equiv="refresh"')

# ------------- STEP 4: extract-post (to drafts) -------------
& "$($S.PS)\extract-post.ps1" -Slug $slugRenamed | Out-Null
$draftPath = Join-Path $S.Drafts "$slugRenamed.html"
_ok "draft saved" (Test-Path $draftPath)

# ------------- STEP 5: apply-draft (back to post) -------------
# Mutate draft slightly so we can detect application
$dhtml = (Get-Content $draftPath -Raw) + "`n<p>Draft tweak applied.</p>`n"
$dhtml | Set-Content -Encoding UTF8 $draftPath
& "$($S.PS)\apply-draft.ps1" -Slug $slugRenamed | Out-Null
$postNow = (Get-Content (Join-Path $S.Blog "$slugRenamed.html") -Raw)
_ok "draft applied back to post" ($postNow -match 'Draft tweak applied\.')
# cleanup draft
Remove-Item -Force $draftPath

# ------------- STEP 6: delete-post (slug2) -------------
& "$($S.PS)\delete-post.ps1" -Slug $slug2 | Out-Null
_ok "deleted post removed" (-not (Test-Path (Join-Path $S.Blog "$slug2.html")))

# ------------- STEP 7: redirects ops -------------
$redirJson = Join-Path $S.Root "redirects.json"
if (Test-Path $redirJson) { Remove-Item -Force $redirJson }
# add
& "$($S.PS)\redirects.ps1" -Add -From "/legacy" -To "/blog/$slugRenamed.html" -Code 301 | Out-Null
# list and ensure 1 entry
$items = @()
try { $items = Get-Content $redirJson -Raw | ConvertFrom-Json } catch { $items = @() }
_ok "redirects.json has 1 item" ($items.Count -eq 1)
# disable/enable/remove index 0 (should not throw)
& "$($S.PS)\redirects.ps1" -Disable -Index 0 | Out-Null
& "$($S.PS)\redirects.ps1" -Enable  -Index 0 | Out-Null
& "$($S.PS)\redirects.ps1" -Remove  -Index 0 | Out-Null
# confirm 0 remaining
$items2 = @()
try { $items2 = Get-Content $redirJson -Raw | ConvertFrom-Json } catch { $items2 = @() }
_ok "redirects.json empty after remove" ($items2.Count -eq 0)

# ------------- STEP 8: pagination -------------
& "$($S.PS)\build-blog-index.ps1" -PageSize $PageSize | Out-Null
_ok "blog/index.html exists" (Test-Path (Join-Path $S.Blog "index.html"))
# If there were > PageSize posts, page-2.html should exist; we created 2 posts then deleted one and added renamed.
# Still validate page-2 optional existence; do not count as failure if it doesn't exist.
$page2 = Test-Path (Join-Path $S.Blog "page-2.html")
if ($page2) { Write-Host "[OK] blog/page-2.html exists" -ForegroundColor Green } else { Write-Host "[note] blog/page-2.html not needed for current count" -ForegroundColor Yellow }

# ------------- STEP 9: bake -------------
& "$($S.PS)\bake.ps1" -Brand $brand -Money $money | Out-Null
$wrapped = (Get-Content (Join-Path $S.Root "index.html") -Raw)
# Heuristic check: header/nav and footer should appear
_ok "bake wrapped header" ($wrapped -match '<header>' -and $wrapped -match '</header>')
_ok "bake wrapped footer" ($wrapped -match '<footer>' -and $wrapped -match '</footer>')

# ------------- STEP 10: check-links -------------
& "$($S.PS)\check-links.ps1" | Out-Null
Write-Host "[OK] check-links executed" -ForegroundColor Green

# ------------- summary -------------
Write-Host "`n========== TEST SUMMARY ==========" -ForegroundColor Cyan
if ($failCount -gt 0) {
  Write-Host "$failCount check(s) failed." -ForegroundColor Red
} else {
  Write-Host "All checks passed. Wizard + scripts look good." -ForegroundColor Green
}

# ------------- cleanup -------------
if ($KeepSandbox) {
  Write-Host "Sandbox location: $($S.Root)" -ForegroundColor Yellow
  Write-Host "[ASD TEST] Sandbox kept (per -KeepSandbox)." -ForegroundColor Yellow
} else {
  # give Windows a moment to release file handles
  Start-Sleep -Milliseconds 200
  try {
    Set-Location $RepoRootRoot
    Remove-Item -Recurse -Force $sbRoot
    Write-Host "[ASD TEST] Sandbox removed." -ForegroundColor DarkGray
  } catch {
    Write-Warning "[ASD TEST] Could not remove sandbox (files in use). Remove manually: $sbRoot"
  }
}
