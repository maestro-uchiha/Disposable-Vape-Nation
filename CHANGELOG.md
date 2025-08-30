# from the repository root
@"
# Changelog

## v1.1.0 — Stable whitespace + robots defaults
- Trim + normalize whitespace inside `<main>` during bake.
- Keep strict default `robots.txt`; bake appends only the absolute `Sitemap:` line from `config.site.url`.
- Safer root-link rewriting for GitHub Pages subpaths.
- Blog index builder prefers `<title>`, then `<h1>`, then filename.

## v1.0.0 — Initial release
- Parametric static template, layout wrapper, sitemap generation.
- Basic posts tooling, manual bake, GitHub Pages workflow.
"@ | Set-Content -Encoding UTF8 CHANGELOG.md

git add CHANGELOG.md
git commit -m "docs: add CHANGELOG.md for v1.1.0"
git push

## 1.1.0 - 2025-08-24
- Wizard end-to-end OK
- Pagination, redirects manager, link checker
- Bake & sitemap/robots auto-gen

## [v1.1.1] – 2025-08-24
### Changed
- **Licensing:** Switched from MIT to **Proprietary (All rights reserved)**.
- Docs: Updated `README.md` and repository notices to reflect proprietary licensing.

### Notes
- This change applies to new versions going forward.

# Changelog

All notable changes to this project will be documented here.

## [1.2.0] - 2025-08-25
### Added
- SEO-safe robots handling:
  - Default `<meta name="robots" content="index,follow">` injected into normal pages (only if missing).
  - `404.html` forced to `noindex,follow`.
  - Redirect stubs remain `noindex`.

### Fixed
- BaseUrl normalization to prevent `https:/` / `https:///` variants.
- 404 page pathing: CSS and “Return home” now resolve correctly under nested paths.
- Extra blank lines around `<main>` removed during bake (content block trim + whitespace collapse).
- Redirects script robustness (array vs. object, listing/enable/disable/add).

### Improved
- Blog index pagination uses stable dates:
  - Prefers `<meta name="date">`, otherwise falls back to file `CreationTime`.
- Timestamps preserved across bake (no unintended post date changes).
- Sitemap/robots:
  - Absolute sitemap URL when BaseUrl is absolute.
  - robots.txt always has exactly one `Sitemap:` line.

## [1.1.0] - 2025-08-10
- Initial import of Ace Ultra Premium static site with ASD structure.
