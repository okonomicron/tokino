# Known constraints

What the platforms will not let us do, separated by how well established each
point is. Verified 2026-11-26 unless noted.

## Verified from primary sources

### iOS background execution

- **No API wakes an app when a photo is taken.** `PHPhotoLibraryChangeObserver`
  delivers only to a process that is already running. Any claim of instant sync
  would be false.
- **`BGProcessingTaskRequest`** (iOS 13+) gives no timing guarantee. The system
  runs these when it chooses, typically while charging and idle, and never for
  an app the user force-quit from the app switcher.
- **`BGContinuedProcessingTask`** (iOS 26.0) starts in the foreground and may
  continue in the background, showing progress in a Live Activity the user can
  cancel. The system may terminate it abruptly under resource pressure and
  *prioritises terminating tasks that show minimal or no progress*.
- **Background tasks do not run in the simulator.** Real verification needs a
  physical device, which needs TestFlight, which needs Apple Developer
  enrolment. Until then the scan's background behaviour is unverified.

**Design consequence:** the honest model is a user-initiated scan that continues
in the background, plus an on-launch catch-up diff. Progress must be reported
truthfully, because that is what keeps the task alive.

### Instagram publishing

- Requires an Instagram **professional** account (Business or Creator).
- "Instagram Login" needs **no linked Facebook Page**; scopes are
  `instagram_business_basic` and `instagram_business_content_publish`. The older
  `business_basic` / `business_content_publish` names were deprecated
  2025-01-27.
- **Standard Access is enough for accounts with a role on the app**, so
  publishing to your own account needs no App Review. Serving other people's
  accounts needs Advanced Access: App Review plus Business Verification.
- Media must be **fetchable by Meta at publish time** — "we cURL media used in
  publishing attempts" — so it needs a publicly reachable URL.
- Images: **JPEG only**, ≤8 MB, aspect ratio 4:5 to 1.91:1, width 320–1440 px.
  MPO and JPS unsupported. No shopping tags or filters via API.
- Reels: MOV or MP4 with a leading `moov` atom, H.264 or HEVC, 23–60 fps,
  ≤1920 px wide, ≤25 Mbps, 3 s to 15 min, ≤300 MB.
- Carousels: up to 20 items; Reels cannot be carousel members; all items are
  cropped to the first item's aspect ratio.
- Captions: ≤2200 characters, ≤30 hashtags, ≤20 @ tags.
- **Meta's own docs contradict themselves on the publishing quota**: the
  rate-limit section says 100 posts per rolling 24 hours, the carousel
  limitations section says 50, and `content_publishing_limit` reports
  `quota_total: 50`. Containers also cap at 400 per 24 hours and expire after
  24 hours. **We read the quota at runtime and never hard-code it.**
- **There is no scheduling API.** Meta's docs recommend the developer enforce
  the publishing rate limit "especially if your app allows app users to schedule
  posts", confirming scheduling is ours to build.

### GitHub Actions costs

- Pricing is flat per-minute, not multiplier-based. macOS 3/4-core is
  **$0.062/min**.
- Included compute is a **dollar amount**, not minutes: GitHub Free $12/month,
  Pro $18/month. At the macOS rate that is roughly 193 and 290 minutes.
- **Standard runners in public repositories are free** and do not consume
  included compute. Larger runners are not free for public repos.
- Job limit 6 hours; 5 concurrent macOS jobs on Free, Pro and Team. macOS jobs
  may queue during high demand.

### Xcode Cloud

- **25 compute hours per month included** with Apple Developer Program
  membership — about 8× GitHub's allowance.
- The **first workflow must be created in Xcode or App Store Connect**; the App
  Store Connect API can neither enable Xcode Cloud for an app nor connect the
  repository. Builds triggered by the API count as manual starts, so a manual
  start condition is required.

### Google Maps Platform

- **Place IDs may be stored indefinitely.** Latitude/longitude may be cached for
  at most 30 consecutive days.
- **Display fields — name, address, rating, photos — have no caching
  exception.** They must be refreshed rather than kept. `place_match.cached_at`
  drives this.
- Current listings may not reflect a business that existed years ago, which
  matters directly for matching historical photos.

### Xiaohongshu

- `open.xiaohongshu.com` is a merchant/e-commerce platform covering orders,
  products and inventory. **No public note-publishing API, and registration is
  closed.** Assisted handoff is the only compliant route. Sources are
  third-party rather than XHS's own documentation.

## Engineering assumptions, to be confirmed by compiling

- **`PHPersistentChangeToken` / `PHPhotoLibrary.fetchPersistentChanges(since:)`**
  (iOS 16+) is the mechanism for diffing changes without re-enumerating the
  library. High confidence, but Apple's documentation JSON endpoints return 404
  for these symbols, so this was not verified from a primary source. It will be
  confirmed by compiling against the SDK in Milestone 2. `ScanCheckpoint`
  already carries an opaque `changeTokenData` field for it.
- **MobileCLIP-S2 latency on the Neural Engine** is assumed adequate for
  indexing tens of thousands of photos in tens of minutes. To be measured on a
  real device in M2.
- **Xiaohongshu composer limits** in `PlatformConstraints.xiaohongshu` are
  best-effort, not API-documented. To be confirmed during the M6 handoff work.

## Constraints we have imposed on ourselves

- Fully automatic publishing is **refused** on assisted-handoff platforms,
  because the user must act for the post to exist.
- A venue may only be stated as fact when the user confirmed it, or confidence
  is ≥0.85 *with* corroboration beyond GPS proximity. Proximity alone is never
  enough.
- Scheduling in the past is refused: backdating is not required (§9), so a past
  timestamp is a bug rather than an instruction to publish immediately.
- Cloud-only assets are skipped, not downloaded.

## Currently blocked

| Blocked | Needs | Milestone |
|---|---|---|
| Running on a physical iPhone, TestFlight, Xcode Cloud | Apple Developer enrolment ($99/yr) | M3 |
| Real place matching | Google Cloud billing account | M3 |
| Real strategy interpretation and captions | One LLM API key | M4 |
| Real Instagram publishing | IG professional account; user go-ahead | M6 |

Until each arrives, the corresponding path uses a loudly labelled mock, and
`/capabilities` reports exactly which.
