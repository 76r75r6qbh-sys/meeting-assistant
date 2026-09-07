import XCTest
@testable import Casablanca

@MainActor
final class RecordingInterruptionCoordinatorTests: XCTestCase {
    func testShortLockTriggersPauseAndAutoResume() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.screenLock, atOffset: 0)
        await env.flush()
        XCTAssertEqual(env.meeting.status, .pausedRecording)

        env.advance(by: 10)
        env.fireEnd(.screenLock, atOffset: 10)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock), .resume])
        XCTAssertEqual(env.notifier.posted.count, 2)
        XCTAssertEqual(env.meeting.status, .recording)
        XCTAssertGreaterThanOrEqual(env.saveCount, 2)
    }

    /// The fixed 30 s window survives only for `.displayUnavailable`: past it
    /// there is still no display to capture system audio from, so the app does
    /// not resume on its own.
    func testLongDisplayOutageSkipsAutoResumeAndStaysPaused() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.displayUnavailable, atOffset: 0)
        await env.flush()
        env.advance(by: 31)
        env.fireEnd(.displayUnavailable, atOffset: 31)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.displayUnavailable)])
        XCTAssertEqual(env.notifier.posted.count, 1)
        XCTAssertEqual(env.meeting.status, .pausedRecording)
    }

    /// Supersedes the old fixed-window behaviour for locks: a 31 s lock used to
    /// strand the meeting paused. Locks now follow the meeting-slot policy.
    func testLongLockStillAutoResumesWithinTheMeetingSlot() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.screenLock, atOffset: 0)
        await env.flush()
        env.advance(by: 31)
        env.fireEnd(.screenLock, atOffset: 31)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock), .resume])
        XCTAssertEqual(env.meeting.status, .recording)
    }

    func testDisplayLostTriggersPauseAndAutoResumesWhenDisplayReturns() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.displayUnavailable, atOffset: 0)
        await env.flush()
        XCTAssertEqual(env.meeting.status, .pausedRecording)

        env.advance(by: 8)
        env.fireEnd(.displayUnavailable, atOffset: 8)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.displayUnavailable), .resume])
        XCTAssertEqual(env.meeting.status, .recording)
    }

    func testScreenLockPlusDisplayUnavailableResumeOnlyAfterBothEnd() async {
        // The lid-close deadlock guard: closing the lid raises BOTH .screenLock
        // and .displayUnavailable. Resume must wait until both clear, and must
        // not be permanently blocked by either.
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.screenLock, atOffset: 0)
        env.fireStart(.displayUnavailable, atOffset: 0)
        await env.flush()
        XCTAssertEqual(env.meeting.status, .pausedRecording)

        env.advance(by: 3)
        env.fireEnd(.screenLock, atOffset: 3)
        await env.flush()
        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock)], "Must not resume until display also returns")

        env.advance(by: 1)
        env.fireEnd(.displayUnavailable, atOffset: 4)
        await env.flush()
        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock), .resume])
        XCTAssertEqual(env.meeting.status, .recording)
    }

    func testAudioDeviceLostNeverAutoResumes() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.audioDeviceLost(deviceID: "USBMic"), atOffset: 0)
        await env.flush()
        env.advance(by: 5)
        env.fireEnd(.audioDeviceLost(deviceID: "USBMic"), atOffset: 5)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.audioDeviceLost(deviceID: "USBMic"))])
    }

    func testStreamFailureNeverAutoResumes() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.streamFailure(underlyingDescription: "stream not found"), atOffset: 0)
        await env.flush()
        env.advance(by: 1)
        env.fireEnd(.streamFailure(underlyingDescription: "stream not found"), atOffset: 1)
        await env.flush()

        XCTAssertEqual(env.service.calls.count, 1)
        XCTAssertEqual(env.service.calls.first, .handleSystemInterrupt(.streamFailure(underlyingDescription: "stream not found")))
    }

    func testOverlappingReasonsCoalescePauseAndDelayAutoResume() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.screenLock, atOffset: 0)
        env.fireStart(.systemSleep, atOffset: 1)
        await env.flush()
        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock)])

        env.advance(by: 5)
        env.fireEnd(.screenLock, atOffset: 5)
        await env.flush()
        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock)])

        env.advance(by: 2)
        env.fireEnd(.systemSleep, atOffset: 7)
        await env.flush()
        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock), .resume])
    }

    func testManualStopDuringAutoResumeWindowCancelsResume() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.screenLock, atOffset: 0)
        await env.flush()
        env.coordinator.notifyMeetingTransitioned(to: .processing)
        env.fireEnd(.screenLock, atOffset: 5)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock)])
    }

    func testResumeFailureLeavesMeetingPausedAndPostsNotification() async {
        let env = makeEnv()
        env.service.resumeError = NSError(domain: "test", code: 7)
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.screenLock, atOffset: 0)
        await env.flush()
        env.advance(by: 5)
        env.fireEnd(.screenLock, atOffset: 5)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock), .resume])
        XCTAssertEqual(env.notifier.posted.last?.title, "Could not resume recording")
        XCTAssertEqual(env.meeting.status, .pausedRecording)
    }

    /// A failed auto-resume gets exactly one more chance, at the moment the user
    /// comes back: the session unlocking says they are in front of the Mac
    /// again, and whatever transient thing broke the first attempt (a display
    /// still coming back up after a wake) has usually settled by then.
    func testScreenIsUnlockedRetriesFailedResumeOnce() async {
        let env = makeEnv()
        env.service.resumeError = NSError(domain: "test", code: 7)
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.systemSleep, atOffset: 0)
        await env.flush()
        env.advance(by: 10)
        env.fireEnd(.systemSleep, atOffset: 10)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.systemSleep), .resume])
        XCTAssertEqual(env.meeting.status, .pausedRecording)
        XCTAssertEqual(env.notifier.posted.last?.title, "Could not resume recording")

        env.service.resumeError = nil
        env.fireSessionLock(false)
        await env.flush()

        XCTAssertEqual(
            env.service.calls,
            [.handleSystemInterrupt(.systemSleep), .resume, .resume],
            "An unlock must retry the failed auto-resume"
        )
        XCTAssertEqual(env.meeting.status, .recording)

        env.fireSessionLock(false)
        await env.flush()

        XCTAssertEqual(
            env.service.calls.filter { $0 == .resume }.count,
            2,
            "The retry is a one-shot: a second unlock must not resume again"
        )
    }

    /// A retry token belongs to the window that armed it. A later window brings
    /// its own rules — `.audioDeviceLost` forbids auto-resume outright — and an
    /// unlock must not reach past it to a resume the previous window failed.
    func testUnlockDoesNotRetryAResumeFromAnEarlierInterruptionWindow() async {
        let env = makeEnv()
        env.service.resumeError = NSError(domain: "test", code: 7)
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.systemSleep, atOffset: 0)
        await env.flush()
        env.advance(by: 10)
        env.fireEnd(.systemSleep, atOffset: 10)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.systemSleep), .resume])
        XCTAssertEqual(env.meeting.status, .pausedRecording)

        // A second window, whose reason never auto-resumes.
        env.service.resumeError = nil
        env.fireStart(.audioDeviceLost(deviceID: "USBMic"), atOffset: 20)
        await env.flush()
        env.fireEnd(.audioDeviceLost(deviceID: "USBMic"), atOffset: 25)
        await env.flush()

        env.fireSessionLock(false)
        await env.flush()

        XCTAssertEqual(
            env.service.calls.filter { $0 == .resume }.count,
            1,
            "The stale token from the earlier window must not resume the recording"
        )
        XCTAssertEqual(env.meeting.status, .pausedRecording)
    }

    /// The unlock only says the user is back — not that the meeting still is.
    /// A retry stays bound to the same deadline a wake would face, so a Mac
    /// unlocked hours later does not restart a recording nobody is holding.
    func testUnlockDoesNotRetryAFailedResumePastTheResumeDeadline() async {
        let env = makeEnv()
        env.service.resumeError = NSError(domain: "test", code: 7)
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.systemSleep, atOffset: 0)
        await env.flush()
        env.advance(by: 10)
        env.fireEnd(.systemSleep, atOffset: 10)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.systemSleep), .resume])

        env.service.resumeError = nil
        env.advance(by: 4 * 60 * 60)
        env.fireSessionLock(false)
        await env.flush()

        XCTAssertEqual(
            env.service.calls.filter { $0 == .resume }.count,
            1,
            "An unlock past the resume deadline must leave the meeting paused"
        )
        XCTAssertEqual(env.meeting.status, .pausedRecording)
    }

    /// The coordinator cancels `resumeTask` from `clearInterruptionBookkeeping`
    /// when the user presses Stop, so the in-flight resume throws
    /// `CancellationError`. That is the user getting what they asked for, not a
    /// failure to tell them about — and it must not arm the unlock retry either.
    func testCancelledAutoResumeDoesNotPostCouldNotResume() async {
        let env = makeEnv()
        env.service.resumeError = CancellationError()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.screenLock, atOffset: 0)
        await env.flush()
        env.advance(by: 5)
        env.fireEnd(.screenLock, atOffset: 5)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock), .resume])
        XCTAssertFalse(
            env.notifier.posted.contains { $0.title == "Could not resume recording" },
            "A cancelled resume is the user's own Stop, not a failure"
        )

        env.fireSessionLock(false)
        await env.flush()

        XCTAssertEqual(env.service.calls.filter { $0 == .resume }.count, 1)
    }

    /// A sleep or lock while a notes-only workspace is open interrupts nothing.
    /// Persisting `.pausedRecording` there stranded the meeting behind "This
    /// paused recording can no longer be resumed."
    func testInterruptWhileNothingRecordingDoesNotChangeMeetingStatus() async {
        let env = makeEnv(meetingStatus: .notesOnly)
        env.service.interruptOutcome = .nothingRecording
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.systemSleep, atOffset: 0)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.systemSleep)])
        XCTAssertEqual(env.meeting.status, .notesOnly, "Nothing was recording, so nothing may be marked paused")
        XCTAssertTrue(env.notifier.posted.isEmpty, "No recording was paused, so there is nothing to notify about")
        XCTAssertEqual(env.saveCount, 0)
    }

    func testInterruptWithFailedFinalizeStillPausesAndNamesTheError() async {
        let env = makeEnv()
        env.service.interruptOutcome = .finalizeFailed(meetingID: env.meeting.id, "disk full")
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.systemSleep, atOffset: 0)
        await env.flush()

        XCTAssertEqual(env.meeting.status, .pausedRecording)
        XCTAssertEqual(env.notifier.posted.count, 1)
        XCTAssertEqual(env.notifier.posted.first?.title, "Recording paused")
        XCTAssertTrue(
            env.notifier.posted.first?.body.contains("disk full") == true,
            "A failed finalize must name the error: \(env.notifier.posted.first?.body ?? "<none>")"
        )
    }

    /// The finalize now runs before the status flip, so a user Stop can land in
    /// between. Stop merges the segments and deletes the session, so writing
    /// `.pausedRecording` afterwards would strand a finished recording behind
    /// "This paused recording can no longer be resumed."
    func testInterruptFollowedByUserStopDoesNotRevertToPaused() async {
        let env = makeEnv()
        env.service.holdsInterrupt = true
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.audioDeviceLost(deviceID: "USBMic"), atOffset: 0)
        await env.flush()
        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.audioDeviceLost(deviceID: "USBMic"))])
        XCTAssertEqual(env.meeting.status, .recording, "The finalize is still in flight, so nothing is paused yet")

        // The user presses Stop while the finalize is in flight: the view sets
        // .processing itself and then tells the coordinator about it.
        env.meeting.status = .processing
        env.coordinator.notifyMeetingTransitioned(to: .processing)
        let savesBeforeRelease = env.saveCount

        env.service.releaseInterrupt()
        await env.flush()

        XCTAssertEqual(env.meeting.status, .processing, "A stale interrupt outcome must not undo the user's Stop")
        XCTAssertTrue(env.notifier.posted.isEmpty, "The recording was stopped, not paused")
        XCTAssertEqual(env.saveCount, savesBeforeRelease, "A discarded outcome must not save")
    }

    func testRebindDuringPendingInterruptNeitherPausesNorNotifies() async {
        let env = makeEnv()
        env.service.holdsInterrupt = true
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.screenLock, atOffset: 0)
        await env.flush()

        // The user navigates to a different meeting before the finalize returns.
        let otherMeeting = Meeting(title: "Different Meeting", date: .now, status: .recording)
        env.coordinator.bind(meeting: otherMeeting)
        let savesBeforeRelease = env.saveCount

        env.service.releaseInterrupt()
        await env.flush()

        XCTAssertEqual(env.meeting.status, .recording, "The unbound meeting must not be mutated")
        XCTAssertEqual(otherMeeting.status, .recording, "The newly bound meeting was never interrupted")
        XCTAssertTrue(env.notifier.posted.isEmpty, "No toast for a meeting the user navigated away from")
        XCTAssertEqual(env.saveCount, savesBeforeRelease)
    }

    func testBindClearsRecentEventsFromPriorMeeting() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)
        env.fireStart(.screenLock, atOffset: 0)
        await env.flush()

        XCTAssertEqual(env.coordinator.recentEvents.count, 1)

        let secondMeeting = Meeting(title: "Different Meeting", date: .now, status: .recording)
        env.coordinator.bind(meeting: secondMeeting)

        XCTAssertTrue(env.coordinator.recentEvents.isEmpty,
                      "Switching meetings must clear stale interruption events")
    }

    func testAutoResumeAfterMeetingSwitchDoesNotMutateNewMeeting() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.screenLock, atOffset: 0)
        await env.flush()

        let originalStatus = env.meeting.status
        XCTAssertEqual(originalStatus, .pausedRecording)

        // User switches to a different meeting BEFORE the auto-resume window resolves.
        // Use a non-recording initial status so we can detect a buggy mutation to .recording.
        let secondMeeting = Meeting(title: "Different Meeting", date: .now, status: .upcoming)
        env.coordinator.bind(meeting: secondMeeting)

        // Original meeting's auto-resume end fires AFTER the bind. With the bug, this would
        // (a) call resumeRecording for the ORIGINAL meeting (we accept that in v1 since the
        //     resume task was already in-flight at bind time — but here it hasn't been
        //     dispatched yet, so it never even fires) and (b) mutate `secondMeeting.status`.
        env.advance(by: 5)
        env.fireEnd(.screenLock, atOffset: 5)
        await env.flush()

        XCTAssertNotEqual(secondMeeting.status, .recording,
                          "Auto-resume must not mutate a different meeting's status")
    }

    func testResumeMarksCorrectRecordEvenIfNewInterruptionAppended() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        // First interruption — short, should auto-resume
        env.fireStart(.screenLock, atOffset: 0)
        await env.flush()
        XCTAssertEqual(env.coordinator.recentEvents.count, 1)

        let firstStartedAt = env.coordinator.recentEvents[0].startedAt

        // The end event triggers the auto-resume Task. Before that Task runs, simulate a
        // brand-new interruption (lock again) which appends to recentEvents.
        env.advance(by: 5)
        env.fireEnd(.screenLock, atOffset: 5)
        env.fireStart(.screenLock, atOffset: 6)

        await env.flush()

        // The first record (startedAt == 0) must be marked auto-resumed; the new one (startedAt == 6) must NOT be.
        let firstRecord = env.coordinator.recentEvents.first { $0.startedAt == firstStartedAt }
        XCTAssertNotNil(firstRecord)
        XCTAssertTrue(firstRecord?.resumedAutomatically == true,
                      "First interruption should be marked resumed")

        let secondRecord = env.coordinator.recentEvents.first {
            $0.startedAt == Date(timeIntervalSince1970: 6)
        }
        XCTAssertNotNil(secondRecord)
        XCTAssertFalse(secondRecord?.resumedAutomatically == true,
                       "Newly-appended interruption must not inherit resumed=true from the prior one")
    }

    // MARK: - SleepResumePolicy (pure)

    func testPolicyResumesWhileTheMeetingSlotIsStillOpen() {
        // 2 h meeting, paused at its start, woken 2 h 13 min in: past the 30 min
        // fallback, inside the meeting's end + grace.
        XCTAssertTrue(SleepResumePolicy.shouldAutoResume(
            reason: .systemSleep,
            pausedAt: Date(timeIntervalSince1970: 0),
            wakeAt: Date(timeIntervalSince1970: 8000),
            meetingEnd: Date(timeIntervalSince1970: 7200)
        ))
    }

    func testPolicyStaysPausedPastTheMeetingEndGrace() {
        XCTAssertFalse(SleepResumePolicy.shouldAutoResume(
            reason: .systemSleep,
            pausedAt: Date(timeIntervalSince1970: 0),
            wakeAt: Date(timeIntervalSince1970: 8200),
            meetingEnd: Date(timeIntervalSince1970: 7200)
        ))
    }

    func testPolicyFallsBackToThirtyMinutesWithoutAMeetingEnd() {
        let pausedAt = Date(timeIntervalSince1970: 500)
        XCTAssertTrue(SleepResumePolicy.shouldAutoResume(
            reason: .systemSleep,
            pausedAt: pausedAt,
            wakeAt: pausedAt.addingTimeInterval(30 * 60 - 1),
            meetingEnd: nil
        ))
        XCTAssertFalse(SleepResumePolicy.shouldAutoResume(
            reason: .systemSleep,
            pausedAt: pausedAt,
            wakeAt: pausedAt.addingTimeInterval(30 * 60 + 1),
            meetingEnd: nil
        ))
    }

    /// A meeting that pauses at (or after) its scheduled end still gets the
    /// full fallback window, which outlasts end + grace there.
    func testPolicyPrefersTheFallbackWhenItOutlastsTheMeetingSlot() {
        let end = Date(timeIntervalSince1970: 3600)
        XCTAssertEqual(
            SleepResumePolicy.deadline(pausedAt: end, meetingEnd: end),
            end.addingTimeInterval(30 * 60)
        )
        XCTAssertTrue(SleepResumePolicy.shouldAutoResume(
            reason: .screenLock,
            pausedAt: end,
            wakeAt: end.addingTimeInterval(20 * 60),
            meetingEnd: end
        ))
    }

    func testPolicyDeadlineIsExclusive() {
        let pausedAt = Date(timeIntervalSince1970: 0)
        let deadline = SleepResumePolicy.deadline(pausedAt: pausedAt, meetingEnd: nil)
        XCTAssertFalse(SleepResumePolicy.shouldAutoResume(
            reason: .systemSleep,
            pausedAt: pausedAt,
            wakeAt: deadline,
            meetingEnd: nil
        ))
    }

    /// `.displayUnavailable` keeps the old fixed window: the policy declines it
    /// so the coordinator's window check stays the only judge.
    func testPolicyDeclinesWindowBoundReasons() {
        XCTAssertTrue(SleepResumePolicy.isWindowBound(.displayUnavailable))
        XCTAssertFalse(SleepResumePolicy.shouldAutoResume(
            reason: .displayUnavailable,
            pausedAt: Date(timeIntervalSince1970: 0),
            wakeAt: Date(timeIntervalSince1970: 1),
            meetingEnd: nil
        ))
    }

    func testPolicyDeclinesReasonsThatNeverAutoResume() {
        for reason: RecordingInterruptionReason in [
            .audioDeviceLost(deviceID: "USBMic"),
            .streamFailure(underlyingDescription: "stream not found")
        ] {
            XCTAssertFalse(SleepResumePolicy.shouldAutoResume(
                reason: reason,
                pausedAt: Date(timeIntervalSince1970: 0),
                wakeAt: Date(timeIntervalSince1970: 1),
                meetingEnd: nil
            ), "\(reason) must never auto-resume")
        }
    }

    func testPolicyGovernsSleepAndLock() {
        XCTAssertFalse(SleepResumePolicy.isWindowBound(.systemSleep))
        XCTAssertFalse(SleepResumePolicy.isWindowBound(.screenLock))
    }

    // MARK: - Sleep/wake resume policy

    /// The whole point of the task: a real sleep lasts minutes, not seconds, and
    /// the old fixed 30 s window left the meeting paused with the user assuming
    /// the recording was lost.
    func testSleepWakeAfterTwoMinutesStillAutoResumes() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.systemSleep, atOffset: 0)
        await env.flush()
        XCTAssertEqual(env.meeting.status, .pausedRecording)

        env.advance(by: 120)
        env.fireEnd(.systemSleep, atOffset: 120)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.systemSleep), .resume])
        XCTAssertEqual(env.meeting.status, .recording)
    }

    /// Past the meeting's own slot (+ grace) the recording is almost certainly
    /// over, so the app stops guessing and hands the decision to the user.
    func testSleepWakeAfterMeetingEndPlusGraceStaysPaused() async {
        let env = makeEnv()
        let meeting = Meeting(
            title: "Weekly Sync",
            date: Date(timeIntervalSince1970: 0),
            endDate: Date(timeIntervalSince1970: 3600),
            status: .recording
        )
        env.setRecordingMeeting(meeting)
        env.coordinator.bind(meeting: meeting)

        env.fireStart(.systemSleep, atOffset: 0)
        await env.flush()
        XCTAssertEqual(meeting.status, .pausedRecording)

        env.advance(by: 7200)
        env.fireEnd(.systemSleep, atOffset: 7200)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.systemSleep)])
        XCTAssertEqual(meeting.status, .pausedRecording)
        XCTAssertEqual(env.notifier.posted.last?.title, "Recording paused")
        XCTAssertEqual(env.notifier.posted.last?.body, "Open the meeting to Resume or Stop.")
    }

    /// A meeting started by hand has no scheduled end, so the fallback window
    /// from the pause is all there is to go on.
    func testManualMeetingWithoutEndDateResumesWithin30Minutes() async {
        let env = makeEnv()
        let meeting = Meeting(title: "Ad hoc", date: Date(timeIntervalSince1970: 0), status: .recording)
        XCTAssertNil(meeting.endDate)
        env.setRecordingMeeting(meeting)
        env.coordinator.bind(meeting: meeting)

        env.fireStart(.systemSleep, atOffset: 0)
        await env.flush()

        env.advance(by: 25 * 60)
        env.fireEnd(.systemSleep, atOffset: 25 * 60)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.systemSleep), .resume])
        XCTAssertEqual(meeting.status, .recording)
    }

    func testManualMeetingWithoutEndDateStaysPausedAfter30Minutes() async {
        let env = makeEnv()
        let meeting = Meeting(title: "Ad hoc", date: Date(timeIntervalSince1970: 0), status: .recording)
        env.setRecordingMeeting(meeting)
        env.coordinator.bind(meeting: meeting)

        env.fireStart(.systemSleep, atOffset: 0)
        await env.flush()

        env.advance(by: 30 * 60 + 1)
        env.fireEnd(.systemSleep, atOffset: 30 * 60 + 1)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.systemSleep)])
        XCTAssertEqual(meeting.status, .pausedRecording)
        XCTAssertEqual(env.notifier.posted.last?.body, "Open the meeting to Resume or Stop.")
    }

    /// Sleeping closes the recording workspace, so `onDisappear` unbinds the
    /// coordinator. If that unbind won, the wake would find no meeting to resume.
    func testWakeResumesEvenAfterViewUnboundWhilePaused() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.systemSleep, atOffset: 0)
        await env.flush()
        XCTAssertEqual(env.meeting.status, .pausedRecording)

        env.coordinator.bind(meeting: nil)
        XCTAssertFalse(env.coordinator.recentEvents.isEmpty,
                       "The interruption is still live, so its history must survive the unbind")

        env.advance(by: 60)
        env.fireEnd(.systemSleep, atOffset: 60)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.systemSleep), .resume])
        XCTAssertEqual(env.meeting.status, .recording)
    }

    /// The unbind deferral is only for an interruption still in flight. The
    /// ordinary case — the user navigates away between interruptions — must
    /// still release the meeting, or the coordinator would keep steering a
    /// workspace that is no longer on screen.
    func testUnbindWithNoLiveInterruptionStillReleasesTheMeeting() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.screenLock, atOffset: 0)
        await env.flush()
        env.fireEnd(.screenLock, atOffset: 5)
        await env.flush()
        XCTAssertEqual(env.meeting.status, .recording)
        XCTAssertEqual(env.coordinator.recentEvents.count, 1)

        env.coordinator.bind(meeting: nil)
        XCTAssertTrue(env.coordinator.recentEvents.isEmpty,
                      "Nothing is in flight, so the unbind must clear the interruption history")

        // The VIEW is released — but the service is still recording that
        // meeting, and it says so in the outcome. A sleep now must pause the
        // meeting that was recording, not shrug because nothing is on screen:
        // leaving it `.recording` in SwiftData was how a recording became
        // unresumable after the user navigated away before the sleep.
        env.fireStart(.systemSleep, atOffset: 10)
        await env.flush()
        XCTAssertEqual(env.meeting.status, .pausedRecording)
    }

    /// The F4 case: the user navigates to ANOTHER meeting before the Mac sleeps.
    /// The service finalizes the recording it actually holds, so the coordinator
    /// has to pause and resume that one — the viewed meeting is only the
    /// indicator's business.
    func testSleepWhileViewingAnotherMeetingPausesAndResumesTheRecordingMeeting() async {
        let env = makeEnv()
        let recording = env.meeting
        let viewed = Meeting(title: "Different Meeting", date: .now, status: .notesOnly)
        env.register(viewed)
        env.coordinator.bind(meeting: viewed)

        env.fireStart(.systemSleep, atOffset: 0)
        await env.flush()

        XCTAssertEqual(recording.status, .pausedRecording, "The meeting that was recording is the one that pauses")
        XCTAssertEqual(viewed.status, .notesOnly, "The meeting merely on screen is untouched")
        XCTAssertEqual(env.notifier.posted.first?.title, "Recording paused")

        env.advance(by: 120)
        env.fireEnd(.systemSleep, atOffset: 120)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.systemSleep), .resume])
        XCTAssertEqual(env.service.resumedMeetingIDs, [recording.id], "…and the one that resumes")
        XCTAssertEqual(recording.status, .recording)
        XCTAssertEqual(viewed.status, .notesOnly)
    }

    /// Same, with the workspace closed altogether (the dashboard): there is no
    /// bound meeting at all, and the recording must still pause and resume.
    func testSleepWithNoBoundMeetingStillPausesAndResumesTheRecordingMeeting() async {
        let env = makeEnv()
        let recording = env.meeting
        // Never bound — the user is on the dashboard.

        env.fireStart(.systemSleep, atOffset: 0)
        await env.flush()

        XCTAssertEqual(recording.status, .pausedRecording)

        env.advance(by: 120)
        env.fireEnd(.systemSleep, atOffset: 120)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.systemSleep), .resume])
        XCTAssertEqual(env.service.resumedMeetingIDs, [recording.id])
        XCTAssertEqual(recording.status, .recording)
    }

    /// A sleep with a notes-only meeting open interrupts nothing, so the wake
    /// has nothing to resume — asking the service produced a bogus
    /// "Could not resume recording" toast for a recording that never existed.
    func testWakeAfterNothingRecordingInterruptDoesNotResume() async {
        let env = makeEnv(meetingStatus: .notesOnly)
        env.service.interruptOutcome = .nothingRecording
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.systemSleep, atOffset: 0)
        await env.flush()

        env.advance(by: 120)
        env.fireEnd(.systemSleep, atOffset: 120)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.systemSleep)],
                       "Nothing was paused, so nothing may be resumed")
        XCTAssertTrue(env.notifier.posted.isEmpty)
        XCTAssertEqual(env.meeting.status, .notesOnly)
    }

    /// The user pausing on purpose outranks any interruption still in flight:
    /// a later wake must not restart a recording they chose to stop feeding.
    func testManualPauseClearsInterruptionBookkeeping() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.systemSleep, atOffset: 0)
        await env.flush()
        XCTAssertEqual(env.meeting.status, .pausedRecording)

        // The view pauses the recording itself and tells the coordinator.
        env.coordinator.notifyMeetingTransitioned(to: .pausedRecording)

        env.advance(by: 60)
        env.fireEnd(.systemSleep, atOffset: 60)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.systemSleep)],
                       "A manual pause must not be undone by a later wake")
        XCTAssertEqual(env.meeting.status, .pausedRecording)
    }

    // MARK: - Mixed interruption windows (lid close)

    /// Closing the lid raises `.displayUnavailable` and `.systemSleep`, and the
    /// monitor gives no ordering guarantee. When the display event opens the
    /// window, the sleep policy must still govern it: the old 30 s deadline
    /// timer expired during the sleep and vetoed the resume before the policy
    /// was ever consulted. The tiny `autoResumeWindow` plus the real wait below
    /// is what lets that timer fire inside a test.
    func testDisplayThenSleepWindowResumesUnderTheSleepPolicy() async {
        let env = makeEnv(autoResumeWindow: 0.05)
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.displayUnavailable, atOffset: 0)
        await env.flush()
        env.fireStart(.systemSleep, atOffset: 0)
        await env.flush()
        XCTAssertEqual(env.meeting.status, .pausedRecording)

        // Longer than the fixed window, so anything still bound to it has expired.
        try? await Task.sleep(for: .milliseconds(150))

        env.advance(by: 120)
        env.fireEnd(.displayUnavailable, atOffset: 120)
        env.fireEnd(.systemSleep, atOffset: 120)
        await env.flush()

        XCTAssertEqual(
            env.service.calls,
            [.handleSystemInterrupt(.displayUnavailable), .resume],
            "A 2 min sleep inside the meeting slot must resume exactly once"
        )
        XCTAssertEqual(env.meeting.status, .recording)
    }

    /// Same lid-close ordering, but the wake lands past the meeting slot: the
    /// policy declines, and the user has to be told. The old timer returned
    /// early and swallowed this notification.
    func testDisplayThenSleepWindowPastTheMeetingSlotNotifiesAndStaysPaused() async {
        let env = makeEnv(autoResumeWindow: 0.05)
        let meeting = Meeting(
            title: "Weekly Sync",
            date: Date(timeIntervalSince1970: 0),
            endDate: Date(timeIntervalSince1970: 3600),
            status: .recording
        )
        env.setRecordingMeeting(meeting)
        env.coordinator.bind(meeting: meeting)

        env.fireStart(.displayUnavailable, atOffset: 0)
        await env.flush()
        env.fireStart(.systemSleep, atOffset: 0)
        await env.flush()
        XCTAssertEqual(meeting.status, .pausedRecording)
        let savesAfterPause = env.saveCount
        let postsAfterPause = env.notifier.posted.count

        try? await Task.sleep(for: .milliseconds(150))

        env.advance(by: 7200)
        env.fireEnd(.displayUnavailable, atOffset: 7200)
        env.fireEnd(.systemSleep, atOffset: 7200)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.displayUnavailable)],
                       "Past the meeting slot nothing may be resumed")
        XCTAssertEqual(meeting.status, .pausedRecording)
        XCTAssertEqual(env.notifier.posted.count, postsAfterPause + 1,
                       "Exactly one stay-paused notification")
        XCTAssertEqual(env.notifier.posted.last?.title, "Recording paused")
        XCTAssertEqual(env.notifier.posted.last?.body, "Open the meeting to Resume or Stop.")
        XCTAssertEqual(env.saveCount, savesAfterPause,
                       "Staying paused writes nothing: the manifest and the meeting are left alone")
    }

    // MARK: - Sleep deferral completion

    /// The kernel holds the sleep only until the completion runs, so it must run
    /// *after* the finalize — otherwise the mixdown races the suspend again.
    func testHandleStartRunsEventCompletionAfterInterruptFinalize() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        var order: [String] = []
        env.service.onInterruptEntered = { order.append("finalize") }
        env.service.holdsInterrupt = true

        env.fireStart(.systemSleep, atOffset: 0) { order.append("allowPowerChange") }
        await env.flush()
        XCTAssertEqual(order, ["finalize"], "The power change must not be allowed while the finalize is in flight")

        env.service.releaseInterrupt()
        await env.flush()

        XCTAssertEqual(order, ["finalize", "allowPowerChange"])
    }

    /// Nothing was recording, so there is no finalize and no pause — but the
    /// Mac must still be allowed to sleep straight away.
    func testCompletionRunsEvenWhenNothingWasRecording() async {
        let env = makeEnv(meetingStatus: .notesOnly)
        env.service.interruptOutcome = .nothingRecording
        env.coordinator.bind(meeting: env.meeting)

        var completions = 0
        env.fireStart(.systemSleep, atOffset: 0) { completions += 1 }
        await env.flush()

        XCTAssertEqual(completions, 1)
        XCTAssertEqual(env.meeting.status, .notesOnly)
    }

    /// A `.systemSleep` start that lands on top of an already-active reason
    /// takes the early-return path. Without running the completion there, only
    /// the 20 s safety timer would let the Mac sleep.
    func testCompletionRunsForAStartThatIsNotTheFirstActiveReason() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.screenLock, atOffset: 0)
        await env.flush()

        var completions = 0
        env.fireStart(.systemSleep, atOffset: 1) { completions += 1 }
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock)])
        XCTAssertEqual(completions, 1, "A coalesced start must still release the power-change deferral")
    }

    private func makeEnv(
        meetingStatus: MeetingStatus = .recording,
        autoResumeWindow: TimeInterval = 30
    ) -> CoordinatorEnv {
        CoordinatorEnv(meetingStatus: meetingStatus, autoResumeWindow: autoResumeWindow)
    }

    @MainActor
    private final class CoordinatorEnv {
        let service = FakeRecordingService()
        let notifier = FakeNotifier()
        let monitor = FakeMonitor()
        var clock: TimeInterval = 0
        let meeting: Meeting
        var saveCount = 0
        var coordinator: RecordingInterruptionCoordinator!
        /// What `ContentView` wires to `viewModel.fetchMeeting(byID:)`: the
        /// meetings the model context can find, whether or not any of them is
        /// the one on screen.
        private var knownMeetings: [Meeting] = []

        init(meetingStatus: MeetingStatus = .recording, autoResumeWindow: TimeInterval = 30) {
            meeting = Meeting(title: "Weekly Sync", date: .now, status: meetingStatus)
            knownMeetings = [meeting]
            let env = self
            coordinator = RecordingInterruptionCoordinator(
                service: service,
                monitor: monitor,
                notifier: notifier,
                lookupMeeting: { id in env.knownMeetings.first { $0.id == id } },
                autoResumeWindow: autoResumeWindow,
                now: { Date(timeIntervalSince1970: env.clock) },
                save: { env.saveCount += 1 }
            )
            // The service reports which meeting it finalized; by default that is
            // the env's own recording meeting.
            service.interruptOutcome = .segmentFinalized(meetingID: meeting.id, duration: 12)
        }

        /// Makes `meeting` findable by id, as an app-wide lookup would.
        func register(_ meeting: Meeting) { knownMeetings.append(meeting) }

        /// Makes `meeting` the one the service reports as recording (and
        /// findable by id), for the tests that need a meeting with a particular
        /// slot instead of the env's default one.
        func setRecordingMeeting(_ meeting: Meeting) {
            register(meeting)
            service.interruptOutcome = .segmentFinalized(meetingID: meeting.id, duration: 12)
        }

        func bind(meeting: Meeting) { coordinator.bind(meeting: meeting) }

        func advance(by seconds: TimeInterval) { clock += seconds }

        func fireStart(
            _ reason: RecordingInterruptionReason,
            atOffset offset: TimeInterval,
            completion: (@MainActor () -> Void)? = nil
        ) {
            clock = offset
            monitor.fire(
                .init(
                    kind: .started,
                    reason: reason,
                    at: Date(timeIntervalSince1970: offset),
                    completion: completion
                )
            )
        }

        func fireSessionLock(_ locked: Bool) { monitor.fireSessionLock(locked) }

        func fireEnd(_ reason: RecordingInterruptionReason, atOffset offset: TimeInterval) {
            clock = offset
            monitor.fire(.init(kind: .ended, reason: reason, at: Date(timeIntervalSince1970: offset)))
        }

        func flush() async {
            for _ in 0..<10 {
                await Task.yield()
            }
        }
    }

    // Mirrors the real conformer (`AudioRecordingService`), which is `@MainActor`.
    // The coordinator invokes these methods from `Task { @MainActor … }` closures, so
    // without this annotation the recorded-call array would be mutated off the main actor
    // and concurrent interrupts could race on `calls.append` → heap corruption.
    @MainActor
    private final class FakeRecordingService: RecordingInterruptionServicing {
        enum Call: Equatable {
            case handleSystemInterrupt(RecordingInterruptionReason)
            case resume
        }
        var calls: [Call] = []
        var resumeError: Error?
        /// Which meetings `resumeRecording` was actually asked for — the whole
        /// point of the record-bound coordinator.
        var resumedMeetingIDs: [UUID] = []
        /// Overwritten by `CoordinatorEnv.init` with the env's meeting ID.
        var interruptOutcome: InterruptOutcome = .nothingRecording
        /// Holds `handleSystemInterrupt` suspended so a test can act (user Stop,
        /// rebind) while the real finalize would still be in flight.
        var holdsInterrupt = false
        private var interruptGate: CheckedContinuation<Void, Never>?

        /// Fires as soon as the interrupt is entered, so a test can assert the
        /// ordering of the finalize against the sleep-deferral completion.
        var onInterruptEntered: (() -> Void)?

        func handleSystemInterrupt(reason: RecordingInterruptionReason) async -> InterruptOutcome {
            calls.append(.handleSystemInterrupt(reason))
            onInterruptEntered?()
            if holdsInterrupt {
                await withCheckedContinuation { interruptGate = $0 }
            }
            return interruptOutcome
        }

        func releaseInterrupt() {
            interruptGate?.resume()
            interruptGate = nil
        }

        func resumeRecording(for meeting: Meeting) async throws {
            calls.append(.resume)
            resumedMeetingIDs.append(meeting.id)
            if let error = resumeError { throw error }
        }
    }

    private final class FakeNotifier: RecordingInterruptionNotifying {
        struct Post: Equatable {
            let title: String
            let body: String
        }
        var posted: [Post] = []
        func post(title: String, body: String) {
            posted.append(.init(title: title, body: body))
        }
    }

    private final class FakeMonitor: RecordingInterruptionEmitting {
        var onEvent: ((RecordingInterruptionEvent) -> Void)?
        var onSessionLockChanged: ((Bool) -> Void)?
        func fire(_ event: RecordingInterruptionEvent) { onEvent?(event) }
        func fireSessionLock(_ locked: Bool) { onSessionLockChanged?(locked) }
    }
}
