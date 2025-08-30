# =========================
# deploy-infinityfree.ps1 (deploy-only, no bake)
# =========================
param(
  [string]$LocalPath  = (Join-Path $PSScriptRoot 'parametric-static'),
  [string]$HostName   = 'ftpupload.net',
  [int]   $Port       = 21,
  [string]$UserName   = 'if0_39735787',     # ← your InfinityFree FTP user
  [string]$RemotePath = '/htdocs',
  [switch]$WriteHtaccess,
  [switch]$RemoveRemoteExtras,              # mirror-delete remote files not present locally
  [switch]$AllowPlainFTP                    # insecure fallback if FTPS handshake fails
)

function Import-WinScp {
  $candidates = @(
    'C:\Program Files (x86)\WinSCP\WinSCPnet.dll',
    'C:\Program Files\WinSCP\WinSCPnet.dll'
  )
  foreach ($p in $candidates) { if (Test-Path $p) { Add-Type -Path $p; return } }
  throw "WinSCP .NET assembly not found. Install WinSCP from https://winscp.net/ and rerun."
}
function ConvertTo-Plain([SecureString]$s) {
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
  try { [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# Sanity
if (-not (Test-Path $LocalPath)) { throw "LocalPath not found: $LocalPath" }
if (-not (Test-Path (Join-Path $LocalPath 'index.html'))) {
  Write-Warning "index.html not found in $LocalPath. Are you sure you baked already? (Continuing anyway.)"
}

# Optional .htaccess writer (you already have your own; leave -WriteHtaccess off)
if ($WriteHtaccess) {
$htaccess = @"
Options -Indexes
ErrorDocument 404 /404.html
<IfModule mod_headers.c>
  <FilesMatch "\.html?$">
    Header set Cache-Control "no-cache"
  </FilesMatch>
  <FilesMatch "\.(css|js|png|jpe?g|gif|svg|ico|webp|woff2?)$">
    Header set Cache-Control "public, max-age=31536000, immutable"
  </FilesMatch>
</IfModule>
"@
  Set-Content -Path (Join-Path $LocalPath '.htaccess') -Value $htaccess -Encoding ascii
}

# Load WinSCP
Import-WinScp
$ver = [WinSCP.Session].Assembly.GetName().Version
Write-Host "[WinSCP] .NET assembly version: $ver" -ForegroundColor DarkGray

# Credentials
$sec = Read-Host "Enter FTP password for $UserName@$HostName" -AsSecureString
$pwd = ConvertTo-Plain $sec

# Session options (compatible with 1.16.x)
$sessionOptions = New-Object WinSCP.SessionOptions
$sessionOptions.Protocol   = [WinSCP.Protocol]::Ftp
$sessionOptions.HostName   = $HostName
$sessionOptions.PortNumber = $Port
$sessionOptions.UserName   = $UserName
$sessionOptions.Password   = $pwd

if ($AllowPlainFTP) {
  if ($sessionOptions | Get-Member -Name FtpSecure -MemberType Property) {
    $sessionOptions.FtpSecure = [WinSCP.FtpSecure]::None
  }
  Write-Warning "Using plain FTP (no TLS). Password and data are unencrypted."
} else {
  if ($sessionOptions | Get-Member -Name FtpSecure -MemberType Property) {
    $names = [System.Enum]::GetNames([WinSCP.FtpSecure])
    if ($names -contains 'ExplicitTls') {
      $sessionOptions.FtpSecure = [System.Enum]::Parse([WinSCP.FtpSecure], 'ExplicitTls')
    } elseif ($names -contains 'Explicit') {
      $sessionOptions.FtpSecure = [System.Enum]::Parse([WinSCP.FtpSecure], 'Explicit')
    } else {
      Write-Warning "WinSCP.FtpSecure lacks Explicit/ExplicitTls; continuing without FTPS (insecure)."
      $sessionOptions.FtpSecure = [WinSCP.FtpSecure]::None
    }
  }
  Write-Host "[FTPS] Using explicit TLS on port 21" -ForegroundColor DarkGray
}

# Transfer options
$transferOptions = New-Object WinSCP.TransferOptions
$transferOptions.TransferMode      = [WinSCP.TransferMode]::Binary
$transferOptions.PreserveTimestamp = $true

# CORRECT file mask for 1.16.x: include everything (*) and exclude our script/exec patterns
# Note: No extra include before '|', and no stray "*/ | * | ..."
$transferOptions.FileMask = "* | scripts/; scripts.__bak__*/; *.ps1; *.psm1; *.bat; *.cmd; *.sh; *.py; *.exe; *.dll; *.msi"

# Connect & sync (7-arg overload)
$session = New-Object WinSCP.Session
try {
  Write-Host "[FTP] Connecting to $HostName…" -ForegroundColor Cyan
  try {
    $session.Open($sessionOptions)
  } catch {
    $msg = $_.Exception.Message
    if ($msg -match 'handshake failure|dh key too small|TLS|SSL') {
      Write-Error "FTPS handshake failed: $msg"
      Write-Host "Workarounds: Update WinSCP OR rerun with -AllowPlainFTP (INSECURE)." -ForegroundColor Yellow
      throw
    } else { throw }
  }

  try { $session.CreateDirectory($RemotePath) | Out-Null } catch { }

  Write-Host "[FTP] Syncing $LocalPath → $RemotePath" -ForegroundColor Cyan
  $result = $session.SynchronizeDirectories(
    [WinSCP.SynchronizationMode]::Remote,
    $LocalPath,
    $RemotePath,
    $RemoveRemoteExtras.IsPresent,
    $true,
    [WinSCP.SynchronizationCriteria]::Time,
    $transferOptions
  )
  $result.Check()
  Write-Host "[DONE] Uploaded $($result.Uploads.Count) file(s). Failures: $($result.Failures.Count)" -ForegroundColor Green
}
finally {
  if ($session -ne $null) { $session.Dispose() }
  if ($pwd) { $pwd = $null }
}

Write-Host "Live URL should be: https://<your-site-domain>/" -ForegroundColor Yellow
