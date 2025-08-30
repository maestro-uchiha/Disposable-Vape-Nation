<#
  post-wizard.ps1
  Interactive helper to run common ASD tasks.
  - PowerShell 5.1 compatible
  - Reads config.json via _lib.ps1 (single source of truth)
#>

#requires -Version 5.1
[CmdletBinding()]
param()

$ScriptsDir = Split-Path -Parent $PSCommandPath
. (Join-Path $ScriptsDir "_lib.ps1")

# PS 5.1-safe strict mode
Set-StrictMode -Version 2.0

# Paths + config
$S   = Get-ASDPaths
$cfg = Get-ASDConfig -Root $S.Root

function Ask {
  param([string]$Prompt, [string]$Default = "")
  if ([string]::IsNullOrWhiteSpace($Default)) {
    return (Read-Host $Prompt)
  } else {
    $v = Read-Host ("{0} [{1}]" -f $Prompt, $Default)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default } else { return $v }
  }
}

function Ask-YesNo {
  param([string]$Prompt, [bool]$DefaultNo = $true)
  $suffix = ""
  if ($DefaultNo) { $suffix = "(y/N)" } else { $suffix = "(Y/n)" }
  $ans = Read-Host ("{0} {1}" -f $Prompt, $suffix)
  if ([string]::IsNullOrWhiteSpace($ans)) { return (-not $DefaultNo) }
  return ($ans -match '^[Yy]')
}

function Show-Menu {
  Write-Host ""
  Write-Host "ASD Wizard - pick an option:"
  Write-Host "  1) New post           2) Edit post            3) Rename post"
  Write-Host "  4) Delete post        5) Extract to drafts     6) Apply draft to post"
  Write-Host "  7) Redirects          8) Build pagination      9) Bake"
  Write-Host " 10) Build + Bake      11) Check links          12) List posts"
  Write-Host " 13) Open post         14) Edit config.json     15) Commit all (git)"
  Write-Host "  q) Quit"
}

function Do-NewPost {
  $title = Ask "Title"
  $slug  = Ask "Slug (kebab-case)"
  $desc  = Ask "Description" ""
  $when  = Ask "ISO date (yyyy-MM-dd) or blank for today" ""

  $newPostPath = Join-Path $ScriptsDir "new-post.ps1"
  if (-not [string]::IsNullOrWhiteSpace($when)) {
    try { $d = [datetime]::Parse($when) } catch { $d = Get-Date }
    try { & $newPostPath -Title $title -Slug $slug -Description $desc -Date $d }
    catch { & $newPostPath -Title $title -Slug $slug -Description $desc }
  } else {
    & $newPostPath -Title $title -Slug $slug -Description $desc
  }
}

function Do-EditPost {
  $slug = Ask "Slug to edit"
  $t = Ask "New Title (leave blank to keep)" ""
  $d = Ask "New Description (leave blank to keep)" ""
  $b = Ask "New BodyHtml (leave blank to keep)" ""

  $callArgs = @('-Slug', $slug)
  if (-not [string]::IsNullOrWhiteSpace($t)) { $callArgs += @('-Title', $t) }
  if (-not [string]::IsNullOrWhiteSpace($d)) { $callArgs += @('-Description', $d) }
  if (-not [string]::IsNullOrWhiteSpace($b)) { $callArgs += @('-BodyHtml', $b) }

  & (Join-Path $ScriptsDir "update-post.ps1") @callArgs
}

function Do-RenamePost {
  $old = Ask "Old slug"
  $new = Ask "New slug"
  $keep = Ask-YesNo "Leave redirect file in place?" $true
  $switch = @()
  if ($keep) { $switch = @('-LeaveRedirect') }
  & (Join-Path $ScriptsDir "rename-post.ps1") -OldSlug $old -NewSlug $new @switch
}

function Do-DeletePost {
  $slug = Ask "Slug to delete"
  & (Join-Path $ScriptsDir "delete-post.ps1") -Slug $slug
}

function Do-Extract {
  $slug = Ask "Slug to extract to drafts"
  & (Join-Path $ScriptsDir "extract-post.ps1") -Slug $slug
}

function Do-ApplyDraft {
  $slug = Ask "Slug to apply draft to"
  & (Join-Path $ScriptsDir "apply-draft.ps1") -Slug $slug
}

function Do-Redirects {
  Write-Host ""
  Write-Host "Redirects:"
  Write-Host "  1) Add"
  Write-Host "  2) Remove by index"
  Write-Host "  3) Disable by index"
  Write-Host "  4) Enable by index"
  Write-Host "  5) List"
  $c = Read-Host "Choose 1-5"
  $redir = Join-Path $ScriptsDir "redirects.ps1"
  switch ($c) {
    '1' {
      $from = Ask "From path (e.g. /legacy or /old/*)"
      $to   = Ask "To URL or path (e.g. /blog/new.html)"
      $code = Ask "HTTP code (301, 302, 307, 308)" "301"
      & $redir -Add -From $from -To $to -Code ([int]$code)
    }
    '2' { $i = Ask "Index to remove";   & $redir -Remove  -Index ([int]$i) }
    '3' { $i = Ask "Index to disable";  & $redir -Disable -Index ([int]$i) }
    '4' { $i = Ask "Index to enable";   & $redir -Enable  -Index ([int]$i) }
    '5' { & $redir -List }
    default { Write-Host "Invalid choice." }
  }
}

function Do-BuildPagination {
  $size = Ask "Page size" "10"
  & (Join-Path $ScriptsDir "build-blog-index.ps1") -PageSize ([int]$size)
}

# --- Run heavy scripts in a clean child PowerShell to isolate parsing/strict-mode ---
function Invoke-Clean {
  param([string]$ScriptFullPath, [string[]]$Args = @())
  $psiArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $ScriptFullPath) + $Args
  & powershell.exe @psiArgs
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    Write-Error ("Child process exited with code {0} running {1}" -f $code, $ScriptFullPath)
  }
}

function Do-Bake       { Invoke-Clean (Join-Path $ScriptsDir "bake.ps1") }
function Do-BuildBake  { Invoke-Clean (Join-Path $ScriptsDir "build-and-bake.ps1") }
function Do-CheckLinks { Invoke-Clean (Join-Path $ScriptsDir "check-links.ps1") }

function Do-ListPosts {
  if (-not (Test-Path $S.Blog)) { Write-Host "(no blog/ folder yet)"; return }
  Get-ChildItem -Path $S.Blog -Filter *.html -File | ForEach-Object { Write-Host $_.Name }
}

function Do-OpenPost {
  $slug = Ask "Slug to open in VS Code"
  $p = Join-Path $S.Blog ($slug + ".html")
  if (Test-Path $p) {
    Write-Host "[ASD] Opening $p in VS Code..."
    try { Start-Process code -ArgumentList @("--reuse-window","`"$p`"") -ErrorAction Stop }
    catch { Write-Warning "VS Code not found on PATH. Opening in Notepad."; notepad.exe $p }
  } else {
    Write-Warning "Post not found: $p"
  }
}

function Do-EditConfig {
  $cfgPath = Join-Path $S.Root "config.json"
  if (-not (Test-Path $cfgPath)) { $null = Get-ASDConfig -Root $S.Root } # ensure exists
  Write-Host "[ASD] Opening $cfgPath..."
  try { Start-Process code -ArgumentList @("--reuse-window","`"$cfgPath`"") -ErrorAction Stop }
  catch { notepad.exe $cfgPath }
}

# ------- Git helpers -------
function Test-GitAvailable { try { $null = (& git --version) 2>$null; return ($LASTEXITCODE -eq 0) } catch { return $false } }
function Get-GitRoot {
  try {
    $root = (& git rev-parse --show-toplevel) 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($root)) { return $root }
  } catch {}
  return $null
}
function Git-Run { param([string[]]$GitArgs,[switch]$Capture)
  if ($Capture) { $out = & git @GitArgs 2>&1; return @{ code = $LASTEXITCODE; out = $out } }
  else          { & git @GitArgs;         return @{ code = $LASTEXITCODE; out = $null } }
}
function Do-CommitAll {
  if (-not (Test-GitAvailable)) { Write-Error "git is not installed or not on PATH."; return }
  $repoRoot = Get-GitRoot
  if (-not $repoRoot) {
    if (-not (Ask-YesNo "This folder isn't a git repo. Initialize one at '$($S.Root)'?")) { return }
    Push-Location $S.Root
    try {
      $init = Git-Run -GitArgs @('init') -Capture
      if ($init.code -ne 0) { Write-Error "git init failed:`n$($init.out)"; return }
      $bm = Git-Run -GitArgs @('branch','-M','main') -Capture
      if ($bm.code -ne 0) { Write-Warning "Could not set default branch to 'main':`n$($bm.out)" }
      Write-Host "[ASD] Git repository initialized at $($S.Root)."
    } finally { Pop-Location }
    $repoRoot = $S.Root
  }

  Push-Location $repoRoot
  try {
    & git status
    $add = Git-Run -GitArgs @('add','-A','--','.') -Capture
    if ($add.code -ne 0) { Write-Error "git add failed:`n$($add.out)"; return }
    $staged = (& git diff --cached --name-only) 2>$null
    if ([string]::IsNullOrWhiteSpace($staged)) { Write-Host "[ASD] Nothing staged; nothing to commit."; return }

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm"
    $defaultMsg = "asd: batch changes ($ts)"
    $msg = Ask "Commit message" $defaultMsg
    if ([string]::IsNullOrWhiteSpace($msg)) { $msg = $defaultMsg }

    $commit = Git-Run -GitArgs @('commit','-m', $msg) -Capture
    if ($commit.code -ne 0) { Write-Error "git commit failed:`n$($commit.out)"; return }
    Write-Host "[ASD] Commit created."

    if (Ask-YesNo "Push to remote? (requires your git remote auth)") {
      $push = Git-Run -GitArgs @('push') -Capture
      if ($push.code -ne 0) { Write-Warning "git push failed:`n$($push.out)" } else { Write-Host "[ASD] Pushed commits." }
      if (Ask-YesNo "Push tags too?") {
        $pt = Git-Run -GitArgs @('push','--tags') -Capture
        if ($pt.code -ne 0) { Write-Warning "git push --tags failed:`n$($pt.out)" } else { Write-Host "[ASD] Pushed tags." }
      }
    }
  } finally { Pop-Location }
}

# -------- Main loop --------
while ($true) {
  Show-Menu
  $choice = Read-Host "Enter choice"
  switch ($choice) {
    '1'  { Do-NewPost }
    '2'  { Do-EditPost }
    '3'  { Do-RenamePost }
    '4'  { Do-DeletePost }
    '5'  { Do-Extract }
    '6'  { Do-ApplyDraft }
    '7'  { Do-Redirects }
    '8'  { Do-BuildPagination }
    '9'  { Do-Bake }
    '10' { Do-BuildBake }
    '11' { Do-CheckLinks }
    '12' { Do-ListPosts }
    '13' { Do-OpenPost }
    '14' { Do-EditConfig }
    '15' { Do-CommitAll }
    'q'  { break }
    'Q'  { break }
    default { Write-Host "Unknown choice." }
  }
}
