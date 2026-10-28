import Foundation
import Testing
@testable import LZLibrary
#if canImport(Photos)
import Photos
#endif

/// What each access allows, and how PhotoKit's statuses map onto it.
@Suite struct PhotoAccessTests {
    #if canImport(Photos)
    @Test func mapsEveryPhotoKitStatus() {
        #expect(PhotoAccess(PHAuthorizationStatus.notDetermined) == .notDetermined)
        #expect(PhotoAccess(PHAuthorizationStatus.restricted) == .restricted)
        #expect(PhotoAccess(PHAuthorizationStatus.denied) == .denied)
        #expect(PhotoAccess(PHAuthorizationStatus.limited) == .limited)
        #expect(PhotoAccess(PHAuthorizationStatus.authorized) == .full)
    }
    #endif

    @Test func helpersSayWhatEachAccessAllows() {
        #expect(PhotoAccess.allCases.filter(\.canRead) == [.limited, .full])
        #expect(PhotoAccess.allCases.filter(\.canAsk) == [.notDetermined])
        #expect(PhotoAccess.allCases.filter(\.canChangeInSettings) == [.denied, .limited, .full])
    }
}

/// The access store over the fake library: the prompt shows at most once, counting happens only
/// with access, and library changes recount.
@MainActor @Suite struct PhotoAccessStoreTests {
    @Test func startsFromTheCurrentAccessWithoutCounting() {
        let client = FakePhotoLibraryClient(access: .full)
        let store = PhotoAccessStore(client: client)
        #expect(store.access == .full)
        #expect(store.readableCount == nil)
        #expect(!store.isRequesting)
        #expect(client.calls == [.currentAccess])
    }

    @Test func requestShowsThePromptOnceAndCountsTheAnswer() async throws {
        let client = FakePhotoLibraryClient(access: .notDetermined, answer: .limited)
        let store = PhotoAccessStore(client: client)
        #expect(await store.request() == .limited)
        #expect(client.prompts == 1)
        #expect(store.access == .limited)
        try await waitUntil { store.readableCount != nil }
        #expect(store.readableCount == 36)

        client.resetCalls()
        #expect(await store.request() == .limited)
        #expect(!client.calls.contains(.requestAccess))
        #expect(client.prompts == 1)
    }

    @Test func requestReturnsWithoutWaitingForTheCount() async throws {
        // Onboarding finishes as soon as the prompt answers, however long a large library takes to count.
        let client = FakePhotoLibraryClient(access: .notDetermined, answer: .full)
        let (counting, didCount) = AsyncStream<Void>.makeStream()
        let (release, finishCount) = AsyncStream<Void>.makeStream()
        client.setBeforeCount {
            didCount.yield()
            for await _ in release { break }
        }
        let store = PhotoAccessStore(client: client)
        #expect(await store.request() == .full)
        #expect(store.readableCount == nil)
        for await _ in counting { break }

        finishCount.yield()
        try await waitUntil { store.readableCount != nil }
        #expect(store.readableCount == 12_480)
    }

    @Test(arguments: [PhotoAccess.restricted, .denied, .limited, .full])
    func neverAsksOnceDecided(_ access: PhotoAccess) async {
        let client = FakePhotoLibraryClient(access: access)
        let store = PhotoAccessStore(client: client)
        #expect(await store.request() == access)
        #expect(!client.calls.contains(.requestAccess))
        #expect(client.prompts == 0)
        #expect(!store.isRequesting)
    }

    @Test func accessDecidedInSettingsIsNeverAskedAgain() async {
        // The store still thinks access is undecided, but the person chose in iPhone Settings.
        let client = FakePhotoLibraryClient(access: .notDetermined)
        let store = PhotoAccessStore(client: client)
        client.setAccess(.denied)
        #expect(await store.request() == .denied)
        #expect(!client.calls.contains(.requestAccess))
    }

    @Test func aDeniedAnswerLeavesNothingToCount() async {
        let client = FakePhotoLibraryClient(access: .notDetermined, answer: .denied)
        let store = PhotoAccessStore(client: client)
        #expect(await store.request() == .denied)
        #expect(client.prompts == 1)
        #expect(store.readableCount == 0)
        #expect(!client.calls.contains(.readableCount))
    }

    @Test(arguments: [PhotoAccess.notDetermined, .restricted, .denied])
    func countsOnlyWhenReadable(_ access: PhotoAccess) async {
        let client = FakePhotoLibraryClient(access: access)
        let store = PhotoAccessStore(client: client)
        await store.refresh()
        #expect(store.readableCount == 0)
        #expect(!client.calls.contains(.readableCount))
        #expect(!client.calls.contains(.requestAccess))
    }

    @Test func refreshFollowsAccessChangedInSettings() async {
        let client = FakePhotoLibraryClient(access: .denied)
        let store = PhotoAccessStore(client: client)
        await store.refresh()
        #expect(store.readableCount == 0)

        client.setAccess(.full)
        await store.refresh()
        #expect(store.access == .full)
        #expect(store.readableCount == 12_480)

        client.setAccess(.limited)
        await store.refresh()
        #expect(store.access == .limited)
        #expect(store.readableCount == 36)
    }

    @Test func aSlowCountNeverOverwritesANewerRefresh() async {
        let client = FakePhotoLibraryClient(access: .full)
        let (counting, didCount) = AsyncStream<Void>.makeStream()
        let (release, finishCount) = AsyncStream<Void>.makeStream()
        client.setBeforeCount {
            didCount.yield()
            for await _ in release { break }
        }
        let store = PhotoAccessStore(client: client)
        let slow = Task { await store.refresh() }
        for await _ in counting { break }

        // Access is turned off in iPhone Settings while the full library is still being counted.
        client.setAccess(.denied)
        await store.refresh()
        #expect(store.readableCount == 0)

        finishCount.yield()
        await slow.value
        #expect(store.access == .denied)
        #expect(store.readableCount == 0)
    }

    @Test func isRequestingWhileThePromptIsUp() async {
        let client = FakePhotoLibraryClient(access: .notDetermined, answer: .full)
        let (opened, didOpen) = AsyncStream<Void>.makeStream()
        let (release, answer) = AsyncStream<Void>.makeStream()
        client.setBeforeAnswer {
            didOpen.yield()
            for await _ in release { break }
        }
        let store = PhotoAccessStore(client: client)
        let request = Task { await store.request() }
        for await _ in opened { break }
        #expect(store.isRequesting)

        // A second tap while the prompt is up does not ask again.
        #expect(await store.request() == .notDetermined)

        answer.yield()
        #expect(await request.value == .full)
        #expect(!store.isRequesting)
        #expect(client.prompts == 1)
        #expect(client.calls.filter { $0 == .requestAccess }.count == 1)
    }

    @Test func aLibraryChangeRecounts() async throws {
        let client = FakePhotoLibraryClient(access: .limited)
        let store = PhotoAccessStore(client: client)
        store.start()
        store.start()
        defer { store.stop() }
        #expect(client.changeSubscriberCount == 1)
        await store.refresh()
        #expect(store.readableCount == 36)

        // The person picks more photos in the limited-library picker.
        client.setCount(48, for: .limited)
        client.emitChange()
        try await waitUntil { store.readableCount == 48 }
        #expect(store.readableCount == 48)
    }

    @Test func stopEndsTheSubscription() async throws {
        let client = FakePhotoLibraryClient(access: .full)
        let store = PhotoAccessStore(client: client)
        store.start()
        #expect(client.changeSubscriberCount == 1)
        store.stop()
        try await waitUntil { client.changeSubscriberCount == 0 }
        #expect(client.changeSubscriberCount == 0)
    }

    /// Polls `condition` for up to a second (stream-driven work lands on a later turn of the actor).
    private func waitUntil(_ condition: () -> Bool) async throws {
        var tries = 0
        while !condition(), tries < 500 {
            tries += 1
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
