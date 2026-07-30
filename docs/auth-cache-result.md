# Front Door cache status under an `Authorization` header

What [`auth-cache-test.sh`](../auth-cache-test.sh) measured. The script's header
comment covers the method — the arms, how each gets its own cache key, and why status
classification avoids a hardcoded vocabulary. This file records the findings.

## The question

[Front Door's caching docs](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-caching)
say a request carrying an `Authorization` header isn't cached unless the response
carries a `Cache-Control` directive permitting it — but not *which* cache status such a
response reports. Three arms over one asset, each on its own path:

| Arm | `Authorization` | Origin `Cache-Control` | Role |
|-----|-----------------|------------------------|------|
| 1 | absent | absent | control — must cache, or arm 2 proves nothing |
| 2 | present | absent | the measurement |
| 3 | present | `public, max-age=300` | does a permitting directive restore caching? |

## Recorded result

Three runs, 2026-07-29, Japan East, Front Door Premium, asset `app.js`, all served by
the `TYO` POP (`auth-cache-20260729T024205Z`, `...T030333Z`, `...T030634Z`):

| Arm | Request 1 | Requests 2–3 | Post-prime `cacheStatus` |
|-----|-----------|--------------|--------------------------|
| 1 — no `Authorization`, no `Cache-Control` | `TCP_MISS` ×3 | cached in 3/3 runs | HIT, REMOTE_HIT |
| 2 — `Authorization`, no `Cache-Control` | `TCP_MISS` ×3 | **never cached, 6/6 requests `TCP_MISS`** | MISS |
| 3 — `Authorization`, `public, max-age=300` | `TCP_MISS` ×3 | cached in 3/3 runs | HIT, REMOTE_HIT |

An auth-suppressed response reports `X-Cache: TCP_MISS` and `cacheStatus: MISS` — *not*
`PRIVATE_NOSTORE`, which the docs reserve for a `Cache-Control` of `private` or
`no-store`. `timeTaken` corroborates arm 2's misses as real origin fetches: in every run
its slowest post-prime request was slower than the cached control arm's (0.028–0.121 s
against 0.001–0.005 s). Adding `Cache-Control: public, max-age=300` restored caching for
the identical authorized request, in all three runs.

**The consequence is diagnostically negative.** Because an auth-suppressed response is
reported exactly like an ordinary cold miss, *no cache-status value can tell you the
`Authorization` header was the cause*. A `TCP_MISS` is not evidence of auth suppression,
and an access log alone can never establish it. The only way to implicate this mechanism
is to check whether the request actually carried an `Authorization` header. Browsers
don't attach one to `<script src>` or `<link href>` subresource loads — only to explicit
`fetch`/XHR calls — so for a plain static asset this is usually the wrong suspect.

**Scope.** Three runs, 27 requests, all served by a single POP — `TYO`, confirmed from
the access log's `pop_s` column rather than assumed. Reproducible and not a single-sample
artefact, but not enough to characterise Front Door as a whole: caching is per-POP, and
POP-to-POP and profile-to-profile behaviour is untested.

## Cache status vocabulary

Which values have actually been observed here, and therefore have a settled meaning:

| | Confirmed 2026-07-29 | Documented, never observed here |
|---|---|---|
| `X-Cache` | `TCP_HIT`, `TCP_REMOTE_HIT`, `TCP_MISS` | `TCP_PARTIAL_HIT`, `PRIVATE_NOSTORE`, `CONFIG_NOCACHE` |
| `cacheStatus_s` | `HIT`, `REMOTE_HIT`, `MISS` | `PARTIAL_HIT`, `PRIVATE_NOSTORE`, `CACHE_NOCONFIG`, `N/A` |

The script halts rather than guessing if it sees anything in the right-hand column.

## Two incidental observations

Offered as observations rather than properties:

- **No `Age` header observed.** Absent from all 27 responses, and from a separate probe
  that re-fetched cached objects at ~10 s, ~70 s and ~190 s of age, on both scenarios and
  both cache tiers — but all from one profile and the `TYO` POP, so this is consistent
  behaviour here rather than an established property of Front Door.
  `FrontDoorAccessLog` has **no `Age` column** either (verified via `getschema`), so
  object age isn't observable from the log — only from the response header, where it did
  not appear.
- **`X-Cache-Info: L1_T2` / `L2_T2`**, undocumented. Where present it correlated perfectly
  with the tier that answered — `L1_T2` with every `TCP_HIT`, `L2_T2` with every
  `TCP_REMOTE_HIT`. It is not always sent. This makes the `TCP_HIT` ↔ `TCP_REMOTE_HIT`
  alternation ordinary edge-versus-regional tier routing rather than noise.

`Content-Encoding` was absent throughout: the assets sit below the compression size floor.
