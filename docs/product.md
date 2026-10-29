# Lahza: product overview

> **Lahza (لحظة)** means "moment" in Arabic. Status: pre-MVP, October 2026. Settled choices are listed in [decisions.md](decisions.md). Parts of the design may still change after the Phase 0 tests.

## What it is

Lahza is an iPhone app that finds photos and videos in your own library from a plain description of what you remember:

- "The times I played soccer at Al-Nakheel Park"
- "Sunsets from the Greece trip"
- "The hotel receipt"

It works on top of Apple Photos. It doesn't replace the gallery or copy your photos anywhere, and photos are analyzed on the phone.

## The problem

- People have thousands of photos. They remember **what happened**, but not when it was or which album it's in.
- Scrolling is slow, and keyword search misses the context of an outing: where it was, who was there, what you were doing.
- One experience is scattered across dozens of photos and videos, so it is hard to get the whole moment back.
- Built-in natural-language search exists, but it leaves real gaps (see below).

**Core problem:** photos are stored as files, but people remember moments.

## What already exists (October 2026)

| Product | What it does | Gap |
|---|---|---|
| **Apple Photos** | Descriptive search on the device, on iPhone 15 Pro or newer in 16 languages. Other iPhones and languages get keyword search, which still finds categories, places, text, and people you've named. | Results come back as a grid, not as outings. No reasons. "At this park" is loose. |
| **Google Photos (Ask Photos)** | Conversational search powered by Gemini. | Only works on photos uploaded to Google. Users complain results are slow and incomplete. |
| **Ente Photos** | Private photo service with on-device "describe a photo" search and face grouping. | Place, date and person filters are applied by hand; they aren't understood from your sentence. |
| **Small indie apps** (Queryable, Memoria, Momento…) | On-device "describe a photo" search. | Mostly pure image similarity: they don't understand "at this place" or "last summer". Little traction. |

Natural-language search on its own is **not** a differentiator. Most of our users will have iPhone 15 Pro or newer, so they already have Apple's descriptive search. Lahza has to win on the points below.

## Where Lahza is different

1. **"At this place" is precise.** A named park, pitch or saved place ("my pitch") becomes a tight area around where you actually took photos, and that area is combined with the activity in a single question.
2. **All the matches, grouped as moments.** Results are complete outings ("Sat 14 Jun · Al-Nakheel Park · 37 photos · 2 videos"), not a top-10 grid.
3. **Every result says why it matched** ("Soccer · Inside Al-Nakheel Park"), and one tap fixes a mistake.
4. **Private.** Photos and everything learned from them stay on the phone. The only things that leave are place-name lookups sent to Apple Maps and purchases handled by the App Store and RevenueCat; there is no Lahza server. (Google requires uploading.)

## Who it's for

iPhone users, mostly on iPhone 15 Pro or newer, with large libraries, who remember activities, places and outings and want the whole moment back. Lahza also runs on older iPhones, with simpler question understanding.

## MVP at a glance

**In the MVP:**
- Typed search in English.
- Matching on activities, objects and scenes.
- Places (including saved places like "home") and dates.
- Names, read from albums you create in Apple Photos' People view.
- Moment cards with a grid toggle, showing every match in tiers.
- Text inside photos (receipts, signs).
- Videos.
- A reason on every result, plus corrections.
- Saved moments and "add results to a Photos album".

**Not in the MVP:**
- Face recognition (Phase 2).
- Arabic (later).
- Follow-up questions or chat.
- Cloud AI.
- Accounts.

**Business model:** freemium. Search over the last 12 months is free, and a one-time purchase unlocks the whole library (no subscription). The Moments timeline is free.

## What we must prove first

Before building, we test Apple Photos' descriptive search, which is what our users already have, on 30 real searches. If Lahza can't clearly beat it on at least one of place precision, completeness or grouping, the positioning changes.

## How we'll know it works

We test on real libraries with labelled searches. We measure whether Lahza finds **all** the right photos and none of the wrong ones, and compare it with Apple Photos. The MVP is a "go" if it ties or beats Apple's descriptive search on at least 18 of 30 searches, and clearly wins on at least 10.

## Roadmap at a glance

| Phase | Goal |
|---|---|
| 0: Tests | Short experiments on real iPhones and libraries that can confirm or reshape the plan |
| 1: MVP | On-device search with places, moments, reasons and videos; ends in a go/no-go decision |
| 2 | On-device face recognition, Arabic, spoken words in videos, follow-up refinements |
| 3 | User-confirmed relationships, notes, timelines |

## Principles

- On-device by default. No photo leaves the phone.
- Use AI only where it measurably improves accuracy.
- Show everything that matches, with reasons. Never invent details.
- Be honest about what Lahza can't know, such as who is in a photo.

See [how-it-works.md](how-it-works.md) for how search works and [architecture.md](architecture.md) for the system design.
