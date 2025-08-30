## v1.1.0 - 2025-08-24 - Config SOT + Wizard hardening

- config.json is the single source of truth (flat schema).
- _lib.ps1: PowerShell 5.1-safe helpers + legacy schema migration.
- Wizard and modules stabilized; end-to-end tests pass.
- redirects.ps1: list/add/enable/disable/remove reworked.
- check-links.ps1: crash fixed on error formatting.
- bake.ps1: now reads config.json; sitemap/robots normalized.
# Changelog


# Contributing

Thanks for your interest in improving **My ASD Site**!

## Development Setup

1. Install PowerShell 5.1+ (or PowerShell 7) and git.
2. Clone the repo and create a feature branch.
3. Run the wizard locally:
   ```powershell
   powershell -ExecutionPolicy Bypass -File parametric-static\scripts\post-wizard.ps1
