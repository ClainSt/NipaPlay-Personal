# NipaPlay Personal — 2026-11-03

## Version policy

This personal build keeps the upstream release version, **1.11.11** (base tag
`v1.11.11`). Personal changes do not advance the upstream version number. Future
upstream updates should advance both versions together.

## Changes

- Show TMDB episode titles and still images by season and episode, caching the
  metadata without storing API credentials in the media catalog.
- Show concise extra titles such as NCOP, NCED and SP01; recognize MENU files
  and folders as extras, including previously indexed entries in the detail page.
- Size poster grid rows from poster and title heights to remove unused space.
- Enlarge character portraits to 80 logical pixels and crop from the top so
  character heads remain visible.
- Preserve episode titles supplied by Jellyfin, Emby and matched local metadata.
- Include the current shared library detail layout, scan progress display and
  WebDAV playback and authentication fixes.

## Validation

- Full Flutter test suite: **1,228 passed, 37 skipped, 0 failed**.
- Regression coverage includes TMDB caching, extra filters, compact poster rows,
  media server season switching, library ordering and the legacy comments view.
- Real-device playback and a visual launch check are not covered by these tests.

## Packages

The personal release packaging script produces:

- `release/NipaPlay-Personal-Windows-Portable.zip`
- `release/NipaPlay-Personal-Android.apk` (arm64, existing personal signing key)

Signing keys, credentials, diagnostic heap dumps and generated installation
packages are excluded from the source repository.
