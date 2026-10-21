import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct QueueJobCommandsTests {
    @Test func cancelFollowsTheRowsCancelButton() {
        #expect(QueueJobCommands(JobFixture.job(.queued), now: JobFixture.now).canCancel)
        #expect(QueueJobCommands(JobFixture.job(.paused(.insufficientFunds)), now: JobFixture.now).canCancel)
        // Processing: the API can't cancel it, so the row's button is off.
        #expect(!QueueJobCommands(JobFixture.job(.processing), now: JobFixture.now).canCancel)
        #expect(!QueueJobCommands(JobFixture.job(.done), now: JobFixture.now).canCancel)
        #expect(!QueueJobCommands(JobFixture.job(.failed(reason: .message("x"))), now: JobFixture.now).canCancel)
    }

    @Test func retryRunsWhatTheRowOffers() {
        let failed = QueueJobCommands(JobFixture.job(.failed(reason: .message("x"))), now: JobFixture.now)
        #expect(failed.retry == .retry)
        #expect(failed.retryTitle == "Retry Job")

        var paid = JobFixture.job(.failed(reason: .message("Download failed")))
        paid.remote = RemoteJob(requestID: "r1")
        paid.chargedAt = JobFixture.now
        let download = QueueJobCommands(paid, now: JobFixture.now)
        #expect(download.retry == .retry)
        #expect(download.retryTitle == "Retry Download")

        var timedOut = JobFixture.job(.failed(reason: .deadline))
        timedOut.remote = RemoteJob(requestID: "r1")
        timedOut.timedOutAt = JobFixture.now
        let checkAgain = QueueJobCommands(timedOut, now: JobFixture.now)
        #expect(checkAgain.retry == .checkAgain)
        #expect(checkAgain.retryTitle == "Check Again")
    }

    @Test(arguments: [JobState.processing, .done, .rejected, .paused(.insufficientFunds)])
    func nothingToRetry(_ state: JobState) {
        #expect(QueueJobCommands(JobFixture.job(state), now: JobFixture.now).retry == nil)
    }
}

@Suite struct LibraryMenuTargetsTests {
    @Test func oneLocalDraftCanRenderItsFinal() {
        let draft = LibraryFixture.item(isDraft: true)
        #expect(LibraryMenuTargets([draft]) { _ in true }.renderFinal == draft)
        #expect(LibraryMenuTargets([LibraryFixture.item(isDraft: false)]) { _ in true }.renderFinal == nil)
        #expect(LibraryMenuTargets([draft, LibraryFixture.item(isDraft: true)]) { _ in true }.renderFinal == nil)
        #expect(LibraryMenuTargets([]) { _ in true }.renderFinal == nil)
    }

    @Test func aResultOnlyOnHiggsfieldIsNeitherDeletedNorRenderedHere() {
        let remote = LibraryItemModel(history: HistoryFixture.item("gen-1"))
        let targets = LibraryMenuTargets([remote]) { _ in true }
        #expect(targets.deletable.isEmpty)
        #expect(targets.renderFinal == nil)
        #expect(targets.starrable == [remote])
    }

    @Test func starActsOnTheResultsWhoseStarCanChange() {
        var starred = LibraryFixture.item(prompt: "starred")
        starred.isStarred = true
        let plain = LibraryFixture.item(prompt: "plain")

        let mixed = LibraryMenuTargets([starred, plain]) { _ in true }
        #expect(mixed.starsAll)
        #expect(mixed.starTitle == "Star")
        #expect(mixed.deletable == [starred, plain])

        let onlyStarred = LibraryMenuTargets([starred, plain]) { $0.isStarred }
        #expect(onlyStarred.starrable == [starred])
        #expect(!onlyStarred.starsAll)
        #expect(onlyStarred.starTitle == "Unstar")

        #expect(LibraryMenuTargets([plain]) { _ in false }.starrable.isEmpty)
    }
}

@Suite struct PastedInputTests {
    let video = URL(fileURLWithPath: "/home/me/Movies/dance.mov")
    let image = URL(fileURLWithPath: "/home/me/Pictures/face.png")

    @Test func copiedFilesWinOverTheirIconImage() {
        #expect(PastedInput(fileURLs: [video, image], hasImage: true) == .files([video, image]))
    }

    @Test func imageDataWithoutFiles() {
        #expect(PastedInput(fileURLs: [], hasImage: true) == .image)
    }

    @Test func nothingCreateCanUse() throws {
        #expect(PastedInput(fileURLs: [], hasImage: false) == nil)
        let link = try #require(URL(string: "https://example.com/clip.mp4"))
        #expect(PastedInput(fileURLs: [link], hasImage: false) == nil)
    }
}

@Suite struct JobNotificationActionTests {
    private func done(isDraft: Bool, file: URL?) -> Job {
        var job = JobFixture.job(.done, finishedMinutesAgo: 1)
        job.spec.isDraft = isDraft
        job.outputFile = file
        return job
    }

    private let file = URL(fileURLWithPath: "/home/me/Movies/Jutsu Studio/out.mp4")

    @Test func buttonsFitWhatTheJobCanDoNext() {
        #expect(JobNotification(done(isDraft: true, file: file), kind: .done).category == .draftResult)
        #expect(JobNotification(done(isDraft: false, file: file), kind: .done).category == .result)
        #expect(JobNotification(done(isDraft: true, file: nil), kind: .done).category == nil)
        #expect(JobNotification(JobFixture.job(.failed(reason: .message("x"))), kind: .failed).category == .retryable)
        #expect(JobNotification(JobFixture.job(.rejected), kind: .rejected).category == nil)
        #expect(JobNotification(JobFixture.job(.paused(.insufficientFunds)), kind: .paused).category == nil)
        #expect(JobNotification.Category.draftResult.actions == [.renderFinal, .showInFinder])
    }

    @Test func aResponseCarriesTheButtonAndTheFile() throws {
        let notification = JobNotification(done(isDraft: true, file: file), kind: .done)
        let info: [AnyHashable: Any] = notification.userInfo

        let click = try #require(
            JobNotification.Response(userInfo: info, actionIdentifier: "default", isDefaultAction: true))
        #expect(click.action == nil)
        #expect(click.destination == .library)
        #expect(click.jobID == notification.jobID)
        #expect(click.resultFile == file)

        let button = try #require(
            JobNotification.Response(userInfo: info, actionIdentifier: "showInFinder", isDefaultAction: false))
        #expect(button.action == .showInFinder)

        #expect(JobNotification.Response(userInfo: info, actionIdentifier: "dismiss", isDefaultAction: false) == nil)
        #expect(JobNotification.Response(userInfo: [:], actionIdentifier: "retry", isDefaultAction: false) == nil)
    }
}
