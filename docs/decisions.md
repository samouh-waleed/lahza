# Decisions

A short log of settled decisions, newest last. Proposed design rules that still depend on Phase 0 tests are in [architecture.md](architecture.md).

## Principles and constraints

| # | Date | Decision | Why | Basis |
|---|---|---|---|---|
| 1 | 2026-10 | Build an iOS-first native app as the MVP | Product direction | Founder |
| 2 | 2026-10 | Process on the device by default; no Lahza backend for the MVP | Users expect privacy (Apple, Ente and indie apps all work on-device; Google requires uploading). Also avoids per-query cloud cost. | Founder + evidence |
| 3 | 2026-10 | Use AI only where it measurably improves accuracy. Every ML component must name the questions that fail without it. | Founder principle. Research shows place and time questions are won by structured data (GPS, dates), not bigger models. | Founder + evidence |
| 4 | 2026-10 | Don't use Apple MobileCLIP / MobileCLIP2, DFN CLIP or FastVLM | Their weights are research-only (relicensed in 2025), and that includes converted copies | Evidence |
| 5 | 2026-10 | Only ship models with clear commercial terms (e.g. Apache-2.0). Avoid OpenAI CLIP, LAION OpenCLIP, MetaCLIP, NLLB-CLIP and jina-clip-v2. | Non-commercial licenses, or data-provenance risk | Evidence |
| 6 | 2026-10 | Answer place questions from GPS plus a place lookup, never from visual similarity alone | Visual models confuse "looks like Spain" with "taken in Spain" | Evidence |

## Product (2026-10-26)

| # | Decision | Why |
|---|---|---|
| 7 | Launch in English. Arabic comes later. | Focus. Arabic search quality is unproven. |
| 8 | Main users are on iPhone 15 Pro and newer. The app still runs on every iPhone that supports iOS 26, with simpler question understanding on older ones. | Founder's expected audience |
| 9 | "The ones I played in" means **whole sessions**: every photo from outings you were at, not only photos showing you | Meets the core query without face recognition |
| 10 | No face recognition in the MVP. Names come from albums the user creates from Apple Photos' People view (e.g. an album "Ahmed"). On-device face recognition comes in Phase 2, after a legal check. | Apple doesn't share People data with apps. Face models need a license/legal review. |
| 11 | Results are moment cards with a grid toggle, and every match is shown in tiers (Best / More / Location unknown) | "Give me all of them". Grouping by outing is the main differentiator. |
| 12 | Screenshots, memes and forwards rank lower. Received photos of people don't. | Junk crowds results, but photos friends send often show you |
| 13 | Videos: the cover frame of every video, plus sampled frames for videos on the phone (up to 10 min), processed while charging | Many memories are videos; this keeps cost bounded |
| 14 | Include the iCloud Shared Library; exclude the Hidden album | Family-taken shots matter. Hidden is private by design. |
| 15 | No follow-up refinements in the MVP. Editable chips cover it. | Scope |
| 16 | Users can save named places ("home", "my pitch") | Cheap, no AI, matches how people talk |
| 17 | Freemium: search over the last 12 months is free; a one-time or yearly unlock covers the full library | Business model |
| 18 | Telemetry: opt-in result feedback only | Privacy, while still letting us measure quality |
| 19 | Legal: a light review (privacy policy, license credits) before App Store launch; a full biometric and face-model review before Phase 2 faces | Risk grows with faces |
| 20 | Go/no-go: Lahza ties or beats Apple's descriptive search on ≥18 of 30 hero searches and clearly wins on ≥10; "all at this place" set F1 ≥0.6; search under 1.5 s | Our users already have Apple's AI search |
| 21 | Solo, part-time build (10–20 h/week). Full MVP before the first TestFlight. No fixed deadline. | Founder capacity |

## Technology (2026-10-26)

| # | Decision | Why |
|---|---|---|
| 22 | Image–text model: SigLIP 2 B/16 with its vocabulary trimmed to English, 8-bit (about 200 MB). Confirmed by on-device tests in Phase 0. | Most accurate license-safe option. Trimming roughly halves the download. |
| 23 | Question understanding: Apple's on-device language model (Foundation Models) on supported iPhones, with rules as the fallback and fast path | Handles free phrasing accurately for most users; rules keep older iPhones working |
| 24 | Minimum iOS 26; iOS 27 extras used when available | Reach |
| 25 | Model delivered by Apple-hosted Background Assets | No server of our own |
| 26 | Storage: SQLite (GRDB) + FTS5 + a flat vector file | Proven, fast, full-text search built in |
| 27 | No cloud AI in the MVP | Privacy story, no running cost |
| 28 | Start the app from a private iOS template (used with permission): keep its design system, navigation shell, settings and RevenueCat paywall; remove its accounts, ads, backend sync, widgets and product content | Fast start on a proven structure; the removed parts conflict with decisions 2, 10 and 27 |
| 29 | Keep RevenueCat for purchases, with its anonymous app user (no accounts) | Founder: keep the template's payment setup. RevenueCat sees an anonymous ID and purchase status only |

## App (2026-10-27)

| # | Decision | Why |
|---|---|---|
| 30 | Photo access is asked on onboarding's last step: one Continue button goes straight to the iOS prompt (no skip, no "not now"). Lahza stays usable without access and points to iPhone Settings afterwards. | App Review 5.1.1 (explain first, then the system prompt, no gating), and respecting the person's choice |

## Search (2026-10-28)

| # | Decision | Why |
|---|---|---|
| 31 | Bundle GeoNames' cities15000 list (places of 15,000+ people, about 1.6 MB) for offline city, country and time zone, credited under its CC BY 4.0 licence | PhotoKit has no capture time zone, and Apple Maps is online and rate-limited. With it, located photos get a city, country and zone on the device, offline |
| 32 | The full-library unlock is a one-time purchase: no subscription and no trial (refines #17) | Founder decision. The paywall and RevenueCat products are reworked before the App Store |
