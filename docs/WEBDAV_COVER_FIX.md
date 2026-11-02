# WebDAV original cover chain repair

Baseline: upstream `v1.11.11`; recovery branch:
`backup/before-webdav-cover-fix`; repair branch: `fix/webdav-original-cover`.

The scraper previously tried TMDB and public Bangumi before the original
Dandanplay mapping and could replace the original detail image with a public
Bangumi image. The poster widget itself still uses the original image cache.

The repair tries the existing signed/routed `getBangumiByTmdbId` first for TV
and unknown IDs, parses `BangumiAnime.fromDandanplayDetail`, and verifies its
cover with `ImageCacheManager.loadImage` before persisting it. Manual records
are preserved. The new optional strict matching flag rejects multiple TMDB
candidates instead of selecting one by list order; original playback callers
retain their previous behavior. Existing fallback paths remain available.

No new dependency or database migration. No video reads or cloud writes are
introduced. TMDB, Dandanplay and Bangumi identifiers remain separate.

Focused tests: 14 passed, including cover verification before persistence,
independent ID storage, metadata persistence and PROPFIND-only scanning.
These are simulated tests, not verification of mainland network connectivity.

Remaining acceptance gaps: the user's currently selected WebDAV work has not
been refreshed in a live app; image download/decoding and disk restoration have
not been exercised against its real cover; cross-device image-file restoration
is unverified. URL/metadata synchronization does not establish image-file
synchronization. Do not describe this patch as full real-network acceptance.

Rollback: revert the repair commit on this branch; the recovery branch retains
the entire previous source tree. No catalog or watch history needs deleting.
