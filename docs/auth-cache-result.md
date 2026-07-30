# Front Door cache status under an `Authorization` header

Design notes and recorded results for [`auth-cache-test.sh`](../auth-cache-test.sh).
See the [README](../README.md#front-door-cache-tests) for how this fits with the other
cache scripts.

## The question

[Front Door's caching docs](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-caching)
say a request carrying an `Authorization` header isn't cached unless the response
carries a `Cache-Control` directive that permits caching, but they don't say which
cache status such a response reports. This measures it, using one asset and three arms:

| Arm | `Authorization` | Origin `Cache-Control` | Expected |
|-----|-----------------|------------------------|----------|
| 1 | absent | absent | 2nd request HIT — AFD's default 1–3 day cache applies |
| 2 | present | absent | stays MISS |
| 3 | present | `public, max-age=300` | 2nd request HIT |

Hypotheses: **H1** — arm 2 is reported as `X-Cache: TCP_MISS` rather than
`PRIVATE_NOSTORE`. **H2** — `Cache-Control: public, max-age=300` restores caching for
the same authorized request. H1 is falsified if arm 2 turns HIT.

Arm 1 is the control: it must cache, or arm 2's flat MISS proves nothing about the
header. The script hard-fails if it doesn't.

## What makes the arms trustworthy

- With no `Cache-Control`, AFD caches for a **random 1–3 days**, so arm 1 can leave an
  object that makes arm 2 falsely HIT. Every arm therefore uses a **unique path**
  (`/static-test/{scenario}/{run-id}-{arm}/app.js`). Waiting doesn't help, because the
  cache is per-POP.
- Query strings can't provide that uniqueness: the `static-test/` route runs with
  `queryStringCachingBehavior: IgnoreQueryString`. That is exactly why they are safe
  to use as per-request labels (`?run=...&req=N`), which is how log rows are attributed
  back to an arm.

All arms stay on the same route, so no redeployment happens mid-run.

## Avoiding a circular verdict

Classifying a status as a hit requires a vocabulary, and hardcoding one is circular
when establishing that vocabulary is itself an open question. Statuses are therefore
split into **confirmed** (observed here, meaning settled), **uninterpreted**
(documented by Microsoft but never observed here), and unrecognised. Hitting either of
the latter two stops the run and says so, rather than silently folding an unknown hit
into "not a hit" and then blaming the control arm for never caching — that check runs
*before* the control-arm guard for exactly this reason. An absent `X-Cache` is reported
separately, since "not observed" is not "not recognised".

Classification happens in bash over raw log rows, not in an `in (...)` KQL clause, so
there is one vocabulary to audit. `timeTaken` is reported alongside as an origin-fetch
signal that owes nothing to the vocabulary, and the script warns if the timing ordering
contradicts the status classification.

Confirmed so far: `HIT`, `REMOTE_HIT`, `MISS` and their `X-Cache` counterparts
`TCP_HIT`, `TCP_REMOTE_HIT`, `TCP_MISS`. Still uninterpreted: `PARTIAL_HIT`,
`PRIVATE_NOSTORE`, `CACHE_NOCONFIG`, `N/A`.

## Running it

```bash
./auth-cache-test.sh <workspace-customer-id> <afd-url> [direct-url]
```

The script prints `X-Cache`, `Age`, `X-Cache-Info`, `Cache-Control` and
`Content-Encoding` per request, then the `cacheStatus_s` and `pop_s` values from the
access log. Its exit code reflects whether the experiment was **conclusive** — a
falsified hypothesis is a result, not a failure — so it exits non-zero only when
requests fail, logs never arrive, the unauthenticated control arm never caches, or a
cache status turns up that the script has no validated meaning for.

The `Authorization` value it sends is a throwaway placeholder. Front Door only needs
the header to be present, and the origin never inspects it. Pass `AZ_SUBSCRIPTION` if
the workspace isn't in the az CLI's default subscription.

## Recorded result

Three runs, 2026-07-29, Japan East, Front Door Premium, asset `app.js`, all served by
the `TYO` POP (`auth-cache-20260729T024205Z`, `...T030333Z`, `...T030634Z`):

| Arm | Request 1 | Requests 2–3 | Post-prime `cacheStatus` |
|-----|-----------|--------------|--------------------------|
| 1 — no `Authorization`, no `Cache-Control` | `TCP_MISS` ×3 | cached in 3/3 runs | HIT, REMOTE_HIT |
| 2 — `Authorization`, no `Cache-Control` | `TCP_MISS` ×3 | **never cached, 6/6 requests `TCP_MISS`** | MISS |
| 3 — `Authorization`, `public, max-age=300` | `TCP_MISS` ×3 | cached in 3/3 runs | HIT, REMOTE_HIT |

**H1 supported.** An auth-suppressed response reports `X-Cache: TCP_MISS` and
`cacheStatus: MISS` — *not* `PRIVATE_NOSTORE`, which the docs reserve for a
`Cache-Control` of `private` or `no-store`. `timeTaken` corroborates the arm-2 misses
as real origin fetches: in every run arm 2's slowest post-prime request was slower than
the cached control arm's (0.028–0.121 s against 0.001–0.005 s).

**H2 supported.** `Cache-Control: public, max-age=300` restored caching for the
identical authorized request, in all three runs.

**The consequence is diagnostically negative.** Because an auth-suppressed response is
reported exactly like an ordinary cold miss, *no cache-status value can tell you the
`Authorization` header was the cause*. A `TCP_MISS` is not evidence of auth
suppression, and an access log alone can never establish it. The only way to implicate
this mechanism is to check whether the request actually carried an `Authorization`
header. Browsers don't attach one to `<script src>` or `<link href>` subresource
loads — only to explicit `fetch`/XHR calls — so for a plain static asset this mechanism
is usually the wrong suspect.

**Scope of these numbers.** Three runs, 27 requests, all served by a single POP —
`TYO`, confirmed from the access log's `pop_s` column rather than assumed. That is
enough to say the effect is reproducible and not a single-sample artefact, and the
result is further credible because the documented mechanism predicts it. It is *not*
enough to characterise Front Door as a whole: caching is per-POP, and POP-to-POP and
profile-to-profile behaviour is untested here.

## Two incidental observations

Offered as observations rather than properties:

- **No `Age` header, ever.** Absent from all 27 responses across the three runs, and
  from a separate probe that deliberately re-fetched cached objects at ~10 s, ~70 s and
  ~190 s of age on both scenarios. Consistent, but all from the `TYO` POP on one
  profile. If you have asked someone to report the `Age` header on a Front Door
  response, their "no such field" answer may be a property of Front Door rather than of
  their asset. Note also that `FrontDoorAccessLog` has **no `Age` column** — verified
  via `getschema` — so a log-based check and a response-header check are different
  questions, and only the latter is answerable at all.
- **`X-Cache-Info: L1_T2` / `L2_T2`**, undocumented. Where present it correlated
  perfectly with the tier that answered — `L1_T2` with every `TCP_HIT`, `L2_T2` with
  every `TCP_REMOTE_HIT`. It is not always sent. This makes the `TCP_HIT` ↔
  `TCP_REMOTE_HIT` alternation across requests ordinary edge-versus-regional tier
  routing rather than noise.

`Content-Encoding` was absent throughout: the assets sit below the compression size
floor.
