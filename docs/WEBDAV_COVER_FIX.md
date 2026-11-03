# WebDAV original cover chain repair

Baseline: upstream `v1.11.11`; recovery branch:
`backup/before-webdav-cover-fix`; repair branch: `fix/webdav-original-cover`.

The scraper previously tried TMDB and public Bangumi before the original
Dandanplay mapping and could replace the original detail image with a public
Bangumi image. The poster widget itself still uses the original image cache.

The repair tries the existing signed/routed `getBangumiByTmdbId` first for TV
and unknown IDs, parses `BangumiAnime.fromDandanplayDetail`, prefers the same
work's high-resolution mapped Bangumi cover with the Dandanplay thumbnail as a
fallback, and verifies it with `ImageCacheManager.loadImage` before persisting.
Legacy Dandanplay `medium` thumbnails are upgraded during an unchanged scan.
Manual records
are preserved. Catalog scraping now passes the work folder title as a candidate
hint, so works whose TMDB ID maps to several seasons or OVAs can select the
matching Dandanplay entry instead of discarding every candidate as ambiguous.
Original playback callers retain their season-number/first-result behavior.
Existing fallback paths remain available.

No new dependency or database migration. No video reads or cloud writes are
introduced. TMDB, Dandanplay and Bangumi identifiers remain separate.

Focused tests cover cover verification before persistence, independent ID
storage, metadata persistence, candidate selection for real multi-season
examples and PROPFIND-only scanning. These are simulated tests, not GUI
acceptance.

Network evidence on 2026-11-03 through the configured China gateway:

- TMDB `100565` returned two Dandanplay candidates;
- TMDB `65844` returned six Dandanplay candidates;
- the selected `86` and KonoSuba seasons returned Dandanplay covers on
  `assets.anixplayer.net`, and their image URLs returned HTTP 200.

Remaining acceptance gaps: the existing local catalog still contains covers
from the pre-fix scan and must be refreshed in the GUI. The real WebDAV work
has not yet been rescanned after this patch; image decoding/disk restoration
and cross-device image-file restoration remain unverified. URL/metadata
synchronization does not establish image-file synchronization.

Rollback: revert the repair commit on this branch; the recovery branch retains
the entire previous source tree. No catalog or watch history needs deleting.
