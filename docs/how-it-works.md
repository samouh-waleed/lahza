# How Lahza finds your photos

This is a plain-language explanation of how Lahza understands photos and answers a question. Parts may still change after the Phase 0 tests. For components and data flow, see [architecture.md](architecture.md).

## The core idea

A question like *"I played soccer a lot — show me the ones at Al-Nakheel Park"* has several parts:
- an **activity** (playing soccer);
- a **place** (Al-Nakheel Park);
- sometimes a **time** ("last summer"), **people** ("with Ahmed") or **text** ("receipt").

Lahza answers each part with the cheapest signal that is reliable for that part, then combines the answers.

The research behind this is clear:
- Image-understanding models fail on place and time questions on their own. They find photos that *look like* Spain, not photos *taken in* Spain.
- Metadata alone can't tell soccer from a picnic.
- Accuracy comes from combining the two.

## What Lahza knows about each photo

| Signal | Where it comes from | AI? | Helps answer |
|---|---|---|---|
| Date and time | Photo metadata | No | "last summer", "2024" |
| Location | Photo GPS | No | "at Al-Nakheel Park", "in Greece" |
| Place names | Offline city/country list, Apple Maps for parks and restaurants, and places you save ("home", "my pitch") | No | Turning a place name into a location |
| Moment / trip | Grouping photos taken close together in time and place | No | "the day we went hiking"; returning the whole outing |
| Type | Metadata: video, screenshot, selfie, Live Photo | No | "videos of…"; keeping screenshots out of the way |
| Names | Albums you create from Apple Photos' People view (e.g. an album called "Ahmed") | No | "with Ahmed" |
| Labels | Apple's built-in image recognition (~1,300 labels: soccer, sushi, beach, dog…) | Built-in (free, on device) | Common activities and objects |
| People present | Apple's built-in face and person detection: *how many*, not *who* | Built-in | "with friends"; is someone actually playing? |
| Text in the photo | Apple's built-in text recognition | Built-in | "hotel receipt", signs, menus |
| Visual meaning (embedding) | One bundled image–text model | Yes: the one model we plan to ship, kept only if early tests show it clearly helps | Anything labels can't cover, like "black shirt", or "playing" vs "a ball on the floor" |

## What an embedding is, and why we need one model

An **embedding model** turns a photo into a list of about 768 numbers that captures what the photo shows. Think of it as a coordinate in a "meaning space". The same model turns a sentence into a list of numbers in that same space. If a photo's numbers are close to the sentence's numbers, the photo is probably a match. The model learned this from billions of image–caption pairs, so it understands phrases no fixed label list covers.

- It runs once per photo, and the result is stored on the phone (about 1.5 KB per photo).
- **Speed:**
  - Comparing a question against 100,000 photos takes a few milliseconds on a Mac. We haven't measured an iPhone yet.
  - The slower step is turning the question itself into numbers.
  - No special database is needed.
- **Weak spots:** it has no idea of place, time or *who* someone is, and it struggles with counting and with "not". That's why it is one signal among several, not the whole system.

The model must be licensed for commercial use. Apple's MobileCLIP, which some competitors use, is now licensed for research only. We use Google's **SigLIP 2**, which is Apache-2.0 licensed. Its word list covers 100+ languages; trimming it to English roughly halves the download, to about 200 MB. Arabic can be added back later.

## From question to results

1. **Understand the question.**
   - On iPhone 15 Pro and newer, Apple's on-device language model splits the question into parts (activity, place, time, people).
   - On other iPhones, or for simple searches, rules do it.
   - Either way, the parts show as editable chips: `[playing soccer] [at Al-Nakheel Park] [any time]`.
   - The language model only reads your question. It never sees photos and never makes up results.
2. **Resolve place and time.** "Al-Nakheel Park" becomes coordinates plus a radius, preferring the park where you actually have photos. "Last summer" becomes a date range.
3. **Score every photo on each part.** For example: visual match 0.9, place match 1.0.
4. **Combine the scores softly.**
   - A photo with no GPS borrows a location from the same outing when it can. Otherwise it goes to a "location unknown" section instead of disappearing.
   - A photo clearly taken somewhere else is dropped.
   - Filtering strictly on every part is a known way to lose good results, so Lahza doesn't do it.
5. **Share evidence within a moment**, if early tests confirm it helps. If many photos from one match are confidently soccer at the park, a huddle shot taken minutes later is included too.
6. **Group and explain.**
   - Results come back as moment cards (or a grid, if you prefer) that hold every matching photo, sorted into Best / More / Location unknown.
   - Each photo shows why it matched.
   - If nothing is a confident match, Lahza says so instead of showing junk.

### Example

*"I played soccer a lot — give me the ones at Al-Nakheel Park"*

"The ones I played" means every photo from the sessions you were at, including shots of teammates.

| Photo | Result |
|---|---|
| A teammate mid-match, GPS inside the park | **Best match**: "Soccer · Inside Al-Nakheel Park" |
| A friend's WhatsApp photo, saved that evening (no GPS) | **Included**: "Received the day of your park session" |
| Soccer at another pitch 5 km away | **Excluded**: wrong place |
| A FIFA video-game screenshot | **Excluded**: a screenshot, not real soccer |

## Where AI is used, and where it isn't

- **No AI:**
  - dates, places, saved places and moments;
  - names from your albums;
  - combining the scores;
  - the fallback rules.
- **Apple's built-in recognition:** labels, people detection and text reading. These are free, run on the device, and carry no license risk.
- **Apple's on-device language model**, only to understand the question, on iPhones that have it. It works with words only; it never sees photos.
- **One bundled model:** the image–text embedding. It is kept only if early tests show it measurably improves results.
- **Not used in the MVP:**
  - cloud AI;
  - using AI to write a description of every photo;
  - face recognition (Phase 2).

## Videos

- Lahza analyzes the cover frame of every video.
- Videos stored on the phone also get sampled frames: about one every 2 seconds, up to 30 frames, for videos up to 10 minutes long.
- A search result can open the video at the matching moment.

## Known limits

- **Who is in a photo.**
  - iOS doesn't share Apple Photos' People data with other apps.
  - In the MVP, Lahza learns names from albums you create: in Apple Photos you open a person, select their photos, and add them to an album with their name.
  - New photos need adding to the album now and then.
  - On-device face recognition, so this happens automatically, comes in Phase 2.
- **Photos without a location**, often ones received through WhatsApp, can borrow a location from your own photos taken the same day. Otherwise they are shown separately.
- **Photos kept only in iCloud.** If the phone has no preview of a photo, Lahza can still find it by place and time, but not by what's in it. Lahza never downloads originals.
- **English only at launch.** Arabic comes later.
