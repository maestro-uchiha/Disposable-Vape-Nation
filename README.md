# My ASD Site

Clean static sites with **ASD (Amaterasu Static Deploy)**—a tiny, Git-friendly toolkit powered by PowerShell.

## What’s inside

- `parametric-static/` – ASD tools (bake, pagination, redirects, wizards)
- `blog/` – your posts as plain HTML
- `assets/` – CSS, images, favicon
- Top-level pages (e.g., `index.html`, `about.html`, etc.)

## Prerequisites

- **Windows PowerShell 5.1+** (or PowerShell 7)  
- **git** on PATH  
- Optional: **VS Code** for editing

## Configure

Edit `parametric-static/config.json`:

```json
{
  "SiteName": "My ASD Site",
  "StoreUrl": "https://example.com/",
  "Description": "Clean static sites with ASD.",
  "BaseUrl": "https://<your-user>.github.io/<your-repo>/",
  "author": { "name": "Maestro" }
}
