# Lahza (لحظة)

A private iPhone app that finds the photos and videos in your library from a description of what you remember, such as *"the times I played soccer at Al-Nakheel Park"*. Photos are analyzed on the device; nothing is uploaded to a Lahza server.

**Status:** pre-MVP. The app shell runs (onboarding, Ask, Moments, Settings, Lahza Plus paywall); photo indexing and search come next.

Start with [docs/product.md](docs/product.md), then [docs/how-it-works.md](docs/how-it-works.md), [docs/architecture.md](docs/architecture.md) and [docs/decisions.md](docs/decisions.md).

## Run the app

Needs Xcode 26+ installed (it is only used as the toolchain) plus `brew install xcodegen xcbeautify`.

```bash
cd ios
make run        # build and launch in the iPhone Simulator
make test       # package tests on the Mac, app tests in the Simulator
```

Optional local settings (Apple team ID, RevenueCat key) go in `ios/Config/Local.xcconfig`, copied from `Local.xcconfig.example`. That file is git-ignored; never commit keys.
