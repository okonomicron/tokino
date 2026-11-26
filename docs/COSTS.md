# Costs

## The headline

**Photo understanding is free, because it happens on the device.** That single
decision removes what would otherwise be the largest operating cost in the
product. Cloud vision inference over a 20,000-photo library would dominate
everything else on this page.

## Indexing a library (one-off, per device)

| Library size | Cost | Wall clock (estimated) |
|---|---|---|
| 5,000 photos | **$0** | ~5–10 min |
| 20,000 photos | **$0** | ~20–40 min |
| 100,000 photos | **$0** | ~2–3 hours |

MobileCLIP-S2 runs on the Neural Engine. The time is dominated by loading
thumbnails, not by inference. Estimates to be measured on a real device in M2.

## Storage

| Item | 20,000 photos | Supabase free tier |
|---|---|---|
| Embeddings (512 floats) | ~41 MB | 500 MB database |
| Asset metadata | ~20 MB | — |
| Derivative media for posts | a few MB per post | 1 GB storage |

One user's library fits comfortably in the free tier. The free tier is the plan
for the MVP; nothing is provisioned beyond it without approval.

## Marginal cost per active user, per month

| Item | Estimate | Basis |
|---|---|---|
| Strategy creation | ~$0.12 each | one LLM call over sampled library metadata |
| Captions, 3 posts/week, EN + ZH | ~$0.40 | ~13 posts |
| Selective vision / OCR | ~$0.25 | a shortlist of candidates, not the library |
| Place matching | ~$6 one-off | ~200 experiences; the monthly free credit likely absorbs it |
| **Total ongoing** | **under $2/month** | after indexing |

These are estimates. Only the free-tier limits and the CI prices on this page
were verified from primary sources. To be validated in M3–M4 against real
invoices.

## CI

| Path | Cost |
|---|---|
| Linux CI (TokinoKit, backend, lint, secrets) | **$0**, unlimited |
| macOS CI, **public repo** | **$0** — standard runners are free for public repos |
| macOS CI, private repo | $0.062/min against $12/month included on GitHub Free (~193 min) |
| Xcode Cloud (from M3) | 25 compute hours/month included with Apple membership |

A full iOS build plus simulator test run is roughly 8–15 minutes. On a private
repo that is ~$0.50 a run and about 24 free runs a month, which is why the
workflow would switch to manual dispatch if the repo goes private.

## Fixed costs

| Item | Cost | When |
|---|---|---|
| Apple Developer Program | $99/year | M3 — required for TestFlight and any device install |
| Supabase | $0 | free tier covers the MVP |
| `tokino-api` hosting | $0–5/month | M4, when there is something to deploy |
| LLM API credit | ~$20 goes a long way | M4 |
| Google Cloud | $0 expected | M3; monthly free credit should cover matching |

**Total to get a working app on your phone with real AI: $99/year plus roughly
$20 of API credit.** Everything before M3 costs nothing.

## What would change the economics at scale

- **Vision, if it moved to the cloud.** It must not. On-device embedding is
  what makes a 100,000-photo library viable at all.
- **Video rendering (M7).** ffmpeg on a container is cheap per video but needs a
  persistent worker, so it is the first thing that implies a real hosting bill.
- **Places, on a large library.** Matching is per *experience*, not per photo,
  which keeps it bounded — a few hundred calls rather than tens of thousands.
- **The free tiers.** Supabase's 500 MB database holds roughly 200,000
  embeddings, so one heavy user is fine and a hundred are not.
