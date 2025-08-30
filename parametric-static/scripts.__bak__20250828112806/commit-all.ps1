<#
  commit-all.ps1
  Stages and commits all changes. Optionally creates a tag from config.json's Version and pushes.

  Run from anywhere:
    .\parametric-static\scripts\commit-all.ps1 -Message "ASD: stabilize wizard + config SOT" -Push

  Flags:
    -Message "..."   Commit message (default: "ASD sync")
    -NoTag           Do not create/update a git tag
    -Push            Push HEAD (and tag if created) to 'origin'
#>

[CmdletBinding()]
param(
  [string]$Message = "ASD sync",
  [switch]$NoTag,
  [switch]$Push
)

function _die($msg) { Write-Error $msg; exit 1 }
function _git { param([Parameter(ValueFromRemainingArguments=$true)]$rest); & git @rest }

# Repo root is two levels up from this script: parametric-static\scripts -> repo root
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { _die "git CLI not found in PATH." }
if (-not (Test-Path (Join-Path $RepoRoot ".git")))       { _die "No .git folder at $RepoRoot." }

Push-Location $RepoRoot
try {
  $status = _git status --porcelain
  if ([string]::IsNullOrWhiteSpace($status)) {
    Write-Host "[ASD] Nothing to commit."
  } else {
    _git add -A | Out-Null
    _git commit -m $Message 2>$null | Out-Null
    Write-Host "[ASD] Committed: $Message"
  }

  $tag = $null
  if (-not $NoTag) {
    $cfgPath = Join-Path $RepoRoot "config.json"
    if (Test-Path $cfgPath) {
      try {
        $v = (Get-Content $cfgPath -Raw | ConvertFrom-Json).Version
        if (-not [string]::IsNullOrWhiteSpace($v)) {
          $tag = "v$($v.Trim())"
          $exists = _git tag --list $tag
          if ([string]::IsNullOrWhiteSpace($exists)) {
            _git tag -a $tag -m "ASD $tag" 2>$null | Out-Null
            Write-Host "[ASD] Tag created: $tag"
          } else {
            Write-Host "[ASD] Tag $tag already exists; skipping."
          }
        } else {
          Write-Host "[ASD] config.json has no Version; skipping tag."
        }
      } catch {
        Write-Warning "[ASD] Could not read config.json Version; skipping tag. $_"
      }
    } else {
      Write-Host "[ASD] config.json not found; skipping tag."
    }
  } else {
    Write-Host "[ASD] Tagging disabled via -NoTag."
  }

  if ($Push) {
    _git push origin HEAD
    if ($tag) { _git push origin $tag }
    Write-Host "[ASD] Pushed HEAD" + ($(if($tag){" and $tag"}else{""}))
  } else {
    Write-Host "[ASD] Skipped push (add -Push to push to origin)."
  }
}
finally { Pop-Location }
