<#
  mark-milestone.ps1
  Sets version in config.json, updates CHANGELOG.md, and (optionally) commits + tags.

  Usage example:
    .\parametric-static\scripts\mark-milestone.ps1 `
      -Version 1.1.0 `
      -Name "Config SOT + Wizard hardening" `
      -Notes @(
        "config.json is now the single source of truth (flat schema).",
        "_lib.ps1: PowerShell 5.1-safe helpers + legacy schema migration.",
        "Wizard and modules stabilized; end-to-end tests pass.",
        "redirects.ps1: list/add/enable/disable/remove reworked.",
        "check-links.ps1: crash fixed on error formatting.",
        "bake.ps1: now reads config.json; sitemap/robots normalized."
      )

  Parameters:
    -Version   : SemVer like 1.1.0 (required)
    -Name      : Short milestone title (optional)
    -Notes     : String[] bullet points for CHANGELOG (optional)
    -NoGit     : Skip all git actions
    -NoCommit  : Skip git commit (but still tag if NoGit is not set and NoTag not set)
    -NoTag     : Skip git tag
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Version,
  [string]$Name = "",
  [string[]]$Notes = @(),
  [switch]$NoGit,
  [switch]$NoCommit,
  [switch]$NoTag
)

# --- Load shared helpers
$here = $PSScriptRoot
. (Join-Path $here "_lib.ps1")

function _IsSemVer([string]$v) {
  return ($v -match '^\d+\.\d+\.\d+$')
}

if (-not (_IsSemVer $Version)) {
  throw "Version '$Version' is not SemVer (expected: MAJOR.MINOR.PATCH, e.g. 1.1.0)."
}

$paths = Get-ASDPaths
$cfg   = Get-ASDConfig

# Ensure Version property lives in flat config.json
if ($cfg.PSObject.Properties.Name -contains 'Version') {
  $cfg.Version = $Version
} else {
  Add-Member -InputObject $cfg -MemberType NoteProperty -Name Version -Value $Version -Force | Out-Null
}

Save-ASDConfig $cfg

# --- Update CHANGELOG.md
$changelogPath = Join-Path $paths.Root "CHANGELOG.md"
if (-not (Test-Path $changelogPath)) {
  Set-Content -Encoding UTF8 $changelogPath "# Changelog`r`n" | Out-Null
}

$today  = Get-Date -Format "yyyy-MM-dd"
$header = "## v$Version - $today"
if (-not [string]::IsNullOrWhiteSpace($Name)) {
  $header = "$header - $Name"
}

$defaultNotes = @(
  "config.json is the single source of truth (flat schema).",
  "_lib.ps1: PowerShell 5.1-safe helpers + legacy schema migration.",
  "Wizard and modules stabilized; end-to-end tests pass.",
  "redirects.ps1: list/add/enable/disable/remove reworked.",
  "check-links.ps1: crash fixed on error formatting.",
  "bake.ps1: now reads config.json; sitemap/robots normalized."
)

if ($Notes.Count -eq 0) { $Notes = $defaultNotes }

$bulletLines = ($Notes | ForEach-Object { "- $_" }) -join "`r`n"
$block = @"
$header

$bulletLines

"@

# Prepend unless this version already exists
$verEsc   = [regex]::Escape($Version)
$current  = Get-Content $changelogPath -Raw
if ($current -match "(?ms)^\s*##\s*v$verEsc\b") {
  Write-Host "[ASD] CHANGELOG already contains v$Version; not adding a duplicate entry."
} else {
  $newContent = $block + $current
  Set-Content -Encoding UTF8 $changelogPath $newContent
  Write-Host "[ASD] CHANGELOG updated -> $changelogPath"
}

# --- Git actions (optional)
function _GitExists { return (Get-Command git -ErrorAction SilentlyContinue) -ne $null }
$inRepo = Test-Path (Join-Path $paths.Root ".git")

if (-not $NoGit -and $inRepo -and (_GitExists)) {
  Push-Location $paths.Root
  try {
    if (-not $NoCommit) {
      $trimmedName = ($Name -replace '^\s+|\s+$','')
      if ([string]::IsNullOrWhiteSpace($trimmedName)) {
        $msg = "ASD ${Version}"
      } else {
        # Use ${Version} since a colon follows immediately after the variable
        $msg = "ASD ${Version}: " + $trimmedName
      }
      git add -A | Out-Null
      git commit -m $msg 2>$null | Out-Null
      Write-Host "[ASD] git commit: $msg"
    } else {
      Write-Host "[ASD] Skipping git commit (per -NoCommit)."
    }

    if (-not $NoTag) {
      $tag    = "v$Version"
      $tagMsg = "ASD v$Version"
      if (-not [string]::IsNullOrWhiteSpace($Name)) { $tagMsg += " - $Name" }
      git tag -a $tag -m $tagMsg 2>$null | Out-Null
      Write-Host "[ASD] git tag created: $tag"
    } else {
      Write-Host "[ASD] Skipping git tag (per -NoTag)."
    }

    # To push automatically, uncomment:
    # git push origin HEAD
    # if (-not $NoTag) { git push origin "v$Version" }

  } finally {
    Pop-Location
  }
} else {
  if ($NoGit) {
    Write-Host "[ASD] Skipping git actions (per -NoGit)."
  } elseif (-not $inRepo) {
    Write-Warning "[ASD] No .git folder detected; skipping git actions."
  } else {
    Write-Warning "[ASD] git CLI not found in PATH; skipping git actions."
  }
}

Write-Host "[ASD] Milestone marked: v$Version"
