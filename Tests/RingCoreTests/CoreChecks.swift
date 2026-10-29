import Foundation
import RingCore

// Dependency-free checks run on Macs with Command Line Tools and without an Xcode XCTest SDK.
private var failures = 0
func fail(_ message: String, file: StaticString, line: UInt) { failures += 1; print("FAIL \(file):\(line): \(message)") }
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if a != b { fail("\(a) != \(b)", file: file, line: line) } }
func XCTAssertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { if !value { fail("Expected true", file: file, line: line) } }
func XCTAssertFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { if value { fail("Expected false", file: file, line: line) } }
func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if a < b { fail("\(a) < \(b)", file: file, line: line) } }
func XCTAssertLessThanOrEqual<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if a > b { fail("\(a) > \(b)", file: file, line: line) } }
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) { do { _ = try expression(); fail("Expected an error", file: file, line: line) } catch {} }
@main enum CoreChecks {
    static func main() async {
        let checks: [(String, () throws -> Void)] = [
            ("Fresh transcription reruns the same model and preserves imported evidence", { try MeetingTranscriptVersionTests().testFreshAttemptPreservesActiveTranscriptAndImportedEvidence() }),
            ("Transcript activation and repeated restoration retain aliases and import receipts", { try MeetingTranscriptVersionTests().testModelSwitchActivationAndRepeatedRestoreKeepEvidenceAndReceipts() }),
            ("New transcript checkpoints survive restart while the active version stays ready", { try MeetingTranscriptVersionTests().testDraftRestartRetainsCheckpointsWithoutInterruptingActiveVersion() }),
            ("Switching models preserves a partial previous attempt", { try MeetingTranscriptVersionTests().testStartingAnotherModelArchivesPartialWork() }),
            ("System capture modes retain old recording source compatibility", {
                XCTAssertEqual(try JSONDecoder().decode(MeetingAudioSource.self, from: Data("\"callAndMicrophone\"".utf8)), .callAndMicrophone)
                XCTAssertTrue(MeetingAudioSource.systemAndMicrophone.includesMicrophone && MeetingAudioSource.systemAndMicrophone.usesSystemAudio)
                XCTAssertFalse(MeetingAudioSource.system.includesMicrophone); XCTAssertTrue(MeetingAudioSource.system.includesCall)
                XCTAssertFalse(MeetingAudioSource.callAndMicrophone.usesSystemAudio)
            }),
            ("Shared speaker aliases, explicit Me and consistent pink identity", { try MeetingSpeakerTests().testSharedAliasesMeColorAndGroupedFiltering() }),
            ("Speaker ownership groups sort tasks and preserve source evidence", { try MeetingSpeakerTests().testTaskOrderChangesWithAliasesAndOwnerEditsWithoutChangingEvidence() }),
            ("Legacy speaker names and aliases survive repository restart", { try MeetingSpeakerTests().testLegacyNamesAliasEditsAndSelfSelectionSurviveRepositoryRestart() }),
            ("Hour-long transcription coverage and legacy checkpoint migration", { LongMeetingTests().testHourCoverageAndLegacyResume() }),
            ("Adaptive audio splits resume only missing intervals", { LongMeetingTests().testAdaptiveSplitsResumeOnlyUncoveredAudio() }),
            ("Long-meeting analysis bounds and durable idempotent checkpoints", { try LongMeetingTests().testAnalysisIsBoundedAndCheckpointIsDurable() }),
            ("Meeting retry policy preserves cancellation and permanent errors", { LongMeetingTests().testRetryPolicyDoesNotRetryInvalidModelsOrCancellation() }),
            ("Event alerts fire one minute early without all-day or late alerts", { EventReminderTests().testExactLeadTimeAndPastAllDayFiltering() }),
            ("Moved events replace alerts while separate calendars retain identity", { EventReminderTests().testMovedEventReplacesReminderAndCalendarsHaveIndependentIdentity() }),
            ("Calendar mirrors and deleted events cannot create duplicate alerts", { EventReminderTests().testPublishedMirrorsDoNotDuplicateAndDeletedEventsDoNotReturn() }),
            ("Completed tasks and skipped routines suppress upcoming alerts", { EventReminderTests().testCompletedTasksAndClosedRoutineOccurrencesAreSilent() }),
            ("Unconfirmed drafts stay silent and confirmed local work alerts", { EventReminderTests().testOnlyConfirmedLocalWorkAlertsAndUnrelatedDraftsStaySilent() }),
            ("Rolling reminder capacity retains the nearest events", { EventReminderTests().testRollingLimitKeepsNearestEvents() }),
            ("Q2 uses earlier useful chunks only when splitting is allowed", { TaskSlotTests().testSplittableTaskUsesEarlierGapsWithoutTinyRemainders() }),
            ("Q2 searches today and ignores closed drafts and stale meetings", { TaskSlotTests().testTodaySearchAndClosedDraftsDoNotHideCurrentWeekGaps() }),
            ("Explicit Q2 booking exposes reserve instead of hiding free time", { TaskSlotTests().testExplicitBookingUsesReserveWithAVisibleWarning() }),
            ("Manual calendar choice checks conflicts and explains work preferences", { TaskSlotTests().testManualCalendarChoiceValidatesOverlapAndExplainsPreferences() }),
            ("Q2 includes owned Google events and releases missing old bookings", { TaskSlotTests().testOwnedCalendarEventsAndMissingOldBookingsUseActualAvailability() }),
            ("Bilingual transcript search, speakers and overlapping passages", { MeetingNavigationTests().testBilingualSearchAndSpeakerFiltering() }),
            ("AI topics derive times only from cited transcript evidence", { try MeetingNavigationTests().testTopicTimesAreDerivedOnlyFromCitedEvidence() }),
            ("Legacy recordings and topic indexes survive restart", { try MeetingNavigationTests().testLegacyRecordingsAndTopicIndexSurviveRestart() }),
            ("Absolute playback bounds and long-call part boundaries", { MeetingNavigationTests().testAbsolutePlaybackBoundsAndPartBoundaries() }),
            ("Calendar drag snapping, resize limits and DST preserve elapsed duration", { CalendarEditingTests().testGeometryAndDST() }),
            ("Scoped occurrence edits preserve owner identity and other drafts", { CalendarEditingTests().testScopedEditRetainsOtherDraftsAndOwnerIdentity() }),
            ("Calendar edit queue survives restart and replaces stale grid times", { try CalendarEditingTests().testQueueRestartAndOptimisticOverlay() }),
            ("Task resizing adjusts remaining effort without changing history", { CalendarEditingTests().testTaskResizePreservesHistoryAndOtherChunks() }),
            ("Calendar grid heights preserve 5/30/60/90-minute durations", { CalendarGridTests().testHeightsAreProportionalToDuration() }),
            ("Calendar grid overlap groups use stable non-colliding lanes", { CalendarGridTests().testOverlapGroupsUseStableNonCollidingLanes() }),
            ("Calendar grid uses Google identity and moved times without duplicates", { CalendarGridTests().testPublishedBlocksDeduplicateByIdentityAtGoogleTimes() }),
            ("Calendar grid suppresses legacy copies only with authenticated source/time identity", { CalendarGridTests().testLegacyCopiesUseAuthenticatedSourceAndExactTimes() }),
            ("Calendar grid clips overnight and all-day events at exclusive boundaries", { CalendarGridTests().testOvernightAndAllDayClippingUseExclusiveDayEnds() }),
            ("Calendar occupied hours count overlaps once and exclude free events", { CalendarGridTests().testOccupiedTimeCountsOverlapOnceAndHonorsFreeEvents() }),
            ("Calendar weeks and clock changes retain actual event durations", { CalendarGridTests().testCalendarWeeksAndDSTKeepActualDurations() }),
            ("Task completion works in every quadrant regardless of planned date", { TaskCompletionTests().testCompletionFromEveryQuadrantIgnoresFuturePlannedDate() }),
            ("Task completion closes running work and preserves prior history", { TaskCompletionTests().testCompletionClosesRunningWorkAndPreservesPriorHistoryAcrossPlans() }),
            ("Restoration keeps original snapshots and multiple completion cycles", { try TaskCompletionTests().testRestoreRetainsSnapshotsAcrossMultipleCompletionCycles() }),
            ("Legacy completions retain unknown dates without duplicate migration", { try TaskCompletionTests().testLegacyMigrationKeepsUnknownDatesHonestAndIsIdempotent() }),
            ("Completion and restoration recover atomically after interruption", { try TaskCompletionTests().testCompletionAndRestorationSurviveRestartAndInterruptedWrite() }),
            ("Timeline completion retains block identity and flags future calendar review", { TaskCompletionTests().testTimelineCompletionRecordsBlockAndInvalidatesFutureBookings() }),
            ("Meeting transcript timing and chunk-scoped speaker labels", { try MeetingTests().testTranscriptLabelsAndBounds() }),
            ("Meeting tasks require transcript evidence and valid speakers", { try MeetingTests().testAnalysisRequiresEvidenceAndRealSpeakerIDs() }),
            ("Reviewed meeting tasks keep only selected evidence in Git", { try MeetingTests().testReviewedImportKeepsOnlyApprovedEvidence() }),
            ("Interrupted meetings preserve durable import receipts outside Git", { try MeetingTests().testRecoveryAndImportReceiptStayOutsideTaskHistory() }),
            ("Meeting model catalog and long transcript batches", { try MeetingTests().testCatalogAndEndpointCapabilities() }),
            ("Missing calendar events retain last times with an honest Q2 status", { CalendarScheduleTests().testMissingCalendarEventsKeepLastTimesWithoutClaimingTheyAreBooked() }),
            ("Calendar moves preserve stable identity, history and publication", { CalendarScheduleTests().testMovesPreserveIdentityHistoryAndDoNotDirtyPublication() }),
            ("Cross-day calendar moves survive DST and replan without duplication", { CalendarScheduleTests().testCrossDayMovesProjectOnceAndReplanningDoesNotDuplicateOrRepublish() }),
            ("Calendar moves retain other blocks and expose scheduling conflicts", { CalendarScheduleTests().testMovesPreserveOtherBlocksAndExposeOverlapsAndWorkBounds() }),
            ("Concurrent local and Google edits require confirmation", { CalendarScheduleTests().testLocalConflictsRetainDraftAndRequireConfirmation() }),
            ("Pending publication preflight preserves the correct side's time changes", { CalendarScheduleTests().testPendingPreflightDistinguishesLocalMovesRemoteMovesAndConflicts() }),
            ("Q2 schedule dates distinguish calendar bookings, drafts and pending work", { CalendarScheduleTests().testScheduleEntriesDistinguishDraftPendingAndBookedAndExcludeClosedWork() }),
            ("Imported schedule times and baselines survive restart", { try CalendarScheduleTests().testImportedTimesAndBaselineSurviveRepositoryRestart() }),
            ("Determinism, overlaps, reserve and work bounds", { SchedulerTests().testDeterministicAndNoOvertimeOrOverlaps() }),
            ("Priorities, outcomes, waiting and Q4", { SchedulerTests().testPriorityOutcomesWaitingAndQ4() }),
            ("Transitions consume real capacity", { SchedulerTests().testTransitionMustFitRealCapacity() }),
            ("Back-to-back fixed meetings", { SchedulerTests().testTouchingMeetingsArePreservedAndReportMissingGap() }),
            ("Shared gaps use maximum, not sum", { SchedulerTests().testSharedGapIsMaxNotSum() }),
            ("Pins and remaining effort", { SchedulerTests().testPinsRemainAndRemainingEffortSchedulesOnce() }),
            ("Dependencies and deadline risk", { SchedulerTests().testDependencyAndDeadlineRisk() }),
            ("Protected routine preservation", { SchedulerTests().testProtectedRoutineSurvivesReplanAndFlexibleCanOverflow() }),
            ("Daily, weekday, weekend and custom routine schedules", { RoutineTests().testDailyWeekdayWeekendAndCustomSchedules() }),
            ("Routine weekdays follow local dates across DST and midnight", { RoutineTests().testRepeatDaysUsePlanningTimeZoneAcrossDSTAndMidnight() }),
            ("Routine day changes remove only unstarted occurrences", { RoutineTests().testTurningOffDaysRemovesOnlyUnstartedOccurrences() }),
            ("Routine completions stay independent without replan duplicates", { RoutineTests().testOccurrencesCompleteIndependentlyWithoutReplanDuplicates() }),
            ("Custom routines and legacy templates survive restart", { try RoutineTests().testCustomRoutinesAndLegacyTemplatesSurviveRestart() }),
            ("Invalid routines stay outside drafts", { RoutineTests().testInvalidRoutinesDoNotEnterDrafts() }),
            ("Calendar publication and workspace identity survive restart", { try CalendarPublishingTests().testPendingPublicationSurvivesRestartAndWorkspaceIdentity() }),
            ("Routine publication follows scheduled occurrences and repeat dates", { CalendarPublishingTests().testRoutinePublicationUsesOnlyScheduledOccurrencesAndDistinctDates() }),
            ("Legacy task publications and routine records survive restart", { try CalendarPublishingTests().testLegacyTaskPublicationsAndRoutineRecordsSurviveRestart() }),
            ("Q2 preserves confirmed routines and leaves draft routines unpublished", { CalendarPublishingTests().testQ2RetainsConfirmedRoutinesAndLeavesDraftRoutinesUnpublished() }),
            ("Q2 slots avoid calendar, lunch and existing work and offer alternatives", { TaskSlotTests().testSuggestionsRespectCalendarLunchExistingWorkAndAlternatives() }),
            ("Q2 slots honor prerequisites, deadlines and reserve", { TaskSlotTests().testSuggestionsHonorDeadlinePrerequisitesReserveAndLocalTime() }),
            ("Accepting one Q2 slot leaves unrelated draft tasks unpublished", { TaskSlotTests().testAcceptingOneSlotDoesNotPublishOtherDraftTasks() }),
            ("Scoped bookings survive restart and full confirmation", { try TaskSlotTests().testScopeSurvivesRestartAndFullConfirmationIncludesRemainingWork() }),
            ("New Q2 bookings do not remove prior confirmed closed work", { TaskSlotTests().testNewSlotDoesNotRemovePreviouslyConfirmedClosedWork() }),
            ("Task chooser capacity includes calendar, activities, gaps and reserve", { PlanningPreviewTests().testAvailableTimeAccountsForCalendarActivitiesTransitionsAndReserve() }),
            ("Task chooser counts overlapping commitments once within work hours", { PlanningPreviewTests().testOverlappingCalendarAndLunchUseUnionInsideWorkday() }),
            ("Task chooser accounts for existing pins and changed selections", { PlanningPreviewTests().testExistingPinnedWorkConsumesCapacityUntilDeselected() }),
            ("Task chooser excludes elapsed time and handles full days", { PlanningPreviewTests().testRemainingTodayAndPastOrFullDaysNeverOverstateTime() }),
            ("Task chooser fit honors overflow, prerequisites and task windows", { PlanningPreviewTests().testFitHonorsOverflowDependenciesAndTaskWindows() }),
            ("Task chooser explains flexible and off-day activities", { PlanningPreviewTests().testFlexibleActivitiesAndRecurrenceAreExplainedByActualDraft() }),
            ("Toronto DST boundaries", { SchedulerTests().testLocalCalendarUsesTorontoAcrossDST() }),
            ("Capture persistence and literal input", { try RepositoryTests().testCaptureAndTaskSurviveRestartWithSeparateGitHistory() }),
            ("Interrupted write recovery", { try RepositoryTests().testWriteAheadJournalRecoversInterruptedSave() }),
            ("Incomplete drops remain unsaved drafts", { TaskTriageTests().testIncompleteDropStaysADraft() }),
            ("Confirmed triage preserves task identity and context", { TaskTriageTests().testConfirmedEstimateMovesOriginalTaskWithoutLosingContext() }),
            ("Dropdown changes preserve execution state", { TaskTriageTests().testReprioritizationPreservesExecutionState() }),
            ("Invalid task details cannot enter the matrix", { TaskTriageTests().testInvalidDetailsAndFinishedTasksCannotBePlaced() }),
            ("Priority changes survive repository restart", { try TaskTriageTests().testConfirmedPrioritySurvivesRepositoryRestart() }),
            ("Corruption is reported and preserved", { try RepositoryTests().testCorruptFilesArePreservedAndReported() }),
            ("Legacy tasks migrate and project tags survive restart", { try CaptureTests().testLegacyTasksAndTagsSurviveRestart() }),
            ("Reviewed splits save only selected tasks with one source", { try CaptureTests().testReviewedSplitSavesSelectedTasksAndSourceTogether() }),
            ("Inbox refinement preserves identity and explicit choices", { try CaptureTests().testRefiningInboxItemPreservesIdentityAndExplicitChoices() }),
            ("Tag groups and filters preserve every matching task once", { CaptureTests().testTagGroupingAndFilteringNeverDuplicateOrHideUntagged() }),
            ("LiteLLM output and endpoint validation", { try CaptureTests().testLiteLLMResponseValidation() }),
            ("Calendar occurrences, recurrence identity and busy bounds", { CalendarTests().testOccurrencesAndBusyNormalization() }),
            ("Google OAuth PKCE, client import and verified callbacks", { try GoogleCalendarTests().testPKCEAndVerifiedCallbacks() }),
            ("Inbox and archive clean planned work and pause running tasks", { TaskManagementTests().testInboxAndArchiveRemovePlannedWorkAndPauseRunningWork() }),
            ("Deletion cleans plans and captures without unblocking prerequisites", { TaskManagementTests().testDeleteCleansEveryPlanAndCaptureWithoutUnblockingDependencies() }),
            ("Day selection overrides automatic tasks and future pins", { TaskManagementTests().testDaySelectionOverridesAutomaticTasksAndFuturePins() }),
            ("Task selection keeps dependency facts and execution history", { TaskManagementTests().testSelectedTasksStillSeeDependenciesAndKeepExecutionHistory() }),
            ("Date-specific selection survives restart and legacy plans", { try TaskManagementTests().testSelectionSurvivesRestartAndLegacyPlansStayAutomatic() }),
            ("Task deletion and interrupted recovery are idempotent", { try TaskManagementTests().testDeletionTransactionAndInterruptedRecoveryAreIdempotent() })
        ]
        for (name, check) in checks {
            let before = failures
            do { try check() } catch { failures += 1; print("FAIL \(name): \(error)") }
            if before == failures { print("PASS \(name)") }
        }
        let asyncChecks: [(String, () async throws -> Void)] = [
            ("Whisper and GPT transcription contracts omit unsupported diarization options", { try await MeetingTests().testTranscriptionModelContracts() }),
            ("Long meeting HTTP recovery, hour-long resume and cancelled retry", { try await MeetingTests().testLongMeetingHTTPRetriesResumeAndCancellation() }),
            ("Meeting gateway errors identify model and failed stage with safe transcript-only recovery", { try await MeetingTests().testGatewayFailuresIdentifyStageAndModelWithoutEchoingPayloads() }),
            ("AI topic requests supply real segment times and validate evidence", { try await MeetingTests().testTopicAnalysisHTTPContractIncludesRealTimes() }),
            ("Analysis retries incomplete replies and restores original evidence and speakers", { try await MeetingTests().testAnalysisRecoversInvalidRepliesAndRestoresDurableEvidence() }),
            ("Single-event edits preserve details, colors and unrelated events", { try await CalendarPublishingTests().testScopedCalendarEditPreservesDetailsAndOtherEvents() }),
            ("Calendar edit conflicts, deletions and ownership fail closed", { try await CalendarPublishingTests().testScopedEditConflictsDeletionAndOwnershipFailClosed() }),
            ("Lost calendar edit responses retry without duplicate writes", { try await CalendarPublishingTests().testScopedEditUnknownResponsesRetryWithoutDuplicates() }),
            ("Calendar edits require write access and the original account", { try await CalendarPublishingTests().testScopedEditRequiresWritingAndOriginalAccount() }),
            ("Week calendar reads leave the daily planning snapshot unchanged", { try await CalendarTests().testRangeReadsPreserveDailyPlanningSnapshot() }),
            ("Calendar range reads reject late selection changes and cancellation", { try await CalendarTests().testRangeReadsRejectLateSelectionAndCancellation() }),
            ("Meeting audio HTTP contract and restricted catalog metadata", { try await MeetingTests().testAudioHTTPContractAndPartialFailure() }),
            ("Calendar refresh awaits reconciliation and rejects late disconnects", { try await CalendarTests().testRefreshAwaitsScheduleReconciliationAndRejectsLateDisconnect() }),
            ("External Google moves reconcile without duplicate or restoring writes", { try await CalendarPublishingTests().testExternalMovesAreReadByIDAndReconfirmedWithoutWritesOrDuplicates() }),
            ("Schedule sync uses read permission and verifies every event identity", { try await CalendarPublishingTests().testScheduleReadsUseReadPermissionAndRejectForeignInvalidAndDeletedEvents() }),
            ("Calendar creation is private and repeated confirmation is idempotent", { try await CalendarPublishingTests().testCreatesPrivateEventsAndRepeatedConfirmationIsIdempotent() }),
            ("Event recoloring preserves details and repeats without extra writes", { try await CalendarPublishingTests().testColorRepairPreservesExistingDetailsAndIsIdempotent() }),
            ("Recoloring skips missing events and preserves ownership and ETag guards", { try await CalendarPublishingTests().testColorRepairSkipsMissingEventsAndRetainsOwnershipAndETagGuards() }),
            ("Incorrect Google colors cannot be reported as successful publication", { try await CalendarPublishingTests().testWrongColorResponsesCannotReportSuccessfulPublication() }),
            ("Routine events retry without duplicates and do not block their own plan", { try await CalendarPublishingTests().testRoutineEventsRetryWithoutDuplicatesAndDoNotBlockTheirOwnPlan() }),
            ("Routine reconfirmation updates and removes obsolete occurrences", { try await CalendarPublishingTests().testRoutineReconfirmationUpdatesAndRemovesObsoleteOccurrences() }),
            ("Routine ownership cannot be replaced with task metadata", { try await CalendarPublishingTests().testRoutineOwnershipCannotBeSubstitutedWithTaskMetadata() }),
            ("Lost Calendar responses retry without duplicate events", { try await CalendarPublishingTests().testLostInsertResponseRetriesWithoutDuplicates() }),
            ("Reconfirmation updates events and removes obsolete owned blocks", { try await CalendarPublishingTests().testReconfirmationUpdatesTimesAndRemovesOnlyObsoleteOwnedBlocks() }),
            ("Calendar ownership, account and concurrent-edit guards", { try await CalendarPublishingTests().testOwnershipAccountAndConcurrentEditsFailClosed() }),
            ("Writing consent upgrades without losing read access on denial", { try await CalendarPublishingTests().testWritingPermissionUpgradePreservesReadConnectionWhenDeclined() }),
            ("Published task events do not block their own replanning", { try await CalendarPublishingTests().testPublishedTasksStayVisibleButDoNotBlockTheirOwnReplan() }),
            ("Deleted events and refused writes remain visible failures", { try await CalendarPublishingTests().testDeletedEventsAndForbiddenWritesRemainVisibleFailures() }),
            ("New Google consent never mixes refresh tokens across accounts", { try await CalendarPublishingTests().testNewConsentNeverMixesAnOldAccountsRefreshToken() }),
            ("LiteLLM HTTP contract and authenticated failures", { try await CaptureTests().testClientContractAndHTTPFailures() }),
            ("Calendar permission and explicit selection", { try await CalendarTests().testPermissionAndExplicitSelection() }),
            ("Calendar selection, DST, restart and permission revocation", { try await CalendarTests().testSelectedCalendarBoundsDSTAndRestart() }),
            ("Calendar disconnect ignores late reads and missing calendars", { try await CalendarTests().testDisconnectRejectsLateReadsAndMissingCalendar() }),
            ("Planner avoids selected calendar busy events", { try await CalendarTests().testSchedulerAvoidsSelectedBusyEvents() }),
            ("Concurrent calendar reads keep dates and latest UI separate", { try await CalendarTests().testConcurrentReadsKeepTheirDatesAndLatestUI() }),
            ("Google production loopback rejects forged callbacks", { try await GoogleCalendarTests().testProductionLoopbackCallback() }),
            ("Google production loopback cancels without a callback", { try await GoogleCalendarTests().testProductionLoopbackCancellation() }),
            ("Google tokens survive restart, refresh and clear on revocation", { try await GoogleCalendarTests().testTokensRestartRefreshAndRevocation() }),
            ("Google partial consent and cancelled sign-in stay disconnected", { try await GoogleCalendarTests().testDeniedScopesAndCancelledSignIn() }),
            ("Concurrent Google token refresh uses one exchange", { try await GoogleCalendarTests().testConcurrentRefreshUsesOneExchange() }),
            ("Direct Google API pagination, recurrence, DST and selection", { try await GoogleCalendarTests().testDirectAPIPaginationRecurrenceDSTAndSelection() }),
            ("Google unauthorized retries and API failures stay visible", { try await GoogleCalendarTests().testUnauthorizedRetryAndAPIFailuresStayVisible() }),
            ("macOS calendar selection does not become a Google connection", { GoogleCalendarTests().testOldMacOSConnectionDoesNotMigrate() })
        ]
        for (name, check) in asyncChecks {
            let before = failures
            do { try await check() } catch { failures += 1; print("FAIL \(name): \(error)") }
            if before == failures { print("PASS \(name)") }
        }
        print("\(checks.count + asyncChecks.count) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
