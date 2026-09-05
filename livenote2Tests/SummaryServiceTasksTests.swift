import XCTest

@testable import LiveNote

@MainActor
final class SummaryServiceTasksTests: XCTestCase {

    private var root: URL!
    private var logRoot: URL!
    private var store: TaskStore!
    private var controller: TasksController!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveNoteSummaryTasksTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        logRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveNoteSummaryTasksLogs-\(UUID().uuidString)", isDirectory: true)
        AppLog.directoryOverride = logRoot
        store = TaskStore(rootURL: root)
        controller = TasksController(store: store)
    }

    override func tearDown() {
        AppLog.directoryOverride = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        if let logRoot { try? FileManager.default.removeItem(at: logRoot) }
        controller = nil
        store = nil
        root = nil
        logRoot = nil
        super.tearDown()
    }

    func testCleanedWithTasksSplitsBlock() {
        let raw = """
        # Meeting Minutes

        ## Decisions
        - Decided to adopt Swift 5.

        # Next Steps
        - Task (Craig)

        <!-- tasks
        [{"title":"Adopt Swift 5","owner":"Craig","due":"2026-09-10","quote":"We will adopt Swift 5"}]
        -->
        """

        let output = SummaryService.cleanedWithTasks(raw)
        XCTAssertTrue(output.summary.contains("# Meeting Minutes"))
        XCTAssertTrue(output.summary.contains("## Decisions"))
        XCTAssertFalse(output.summary.contains("<!-- tasks"))
        XCTAssertFalse(output.summary.contains("-->"))
        XCTAssertEqual(output.tasksJSON, "[{\"title\":\"Adopt Swift 5\",\"owner\":\"Craig\",\"due\":\"2026-09-10\",\"quote\":\"We will adopt Swift 5\"}]")
    }

    func testCleanedWithTasksUnclosedLeavesSummaryIntactAndYieldsMalformedSentinel() {
        let raw = """
        # Meeting Minutes

        - Key decision 1

        <!-- tasks
        [{"title":"Unclosed Task"
        """

        let output = SummaryService.cleanedWithTasks(raw)
        XCTAssertEqual(output.summary, raw.trimmingCharacters(in: .whitespacesAndNewlines), "Summary must be kept intact when block is unclosed")
        XCTAssertNotNil(output.tasksJSON)
        XCTAssertEqual(TaskExtractor.parse(output.tasksJSON), .malformed)
    }

    func testCleanedWithTasksCompleteBlockFollowedByTrailingText() {
        let raw = """
        # Meeting Minutes

        ## Decisions
        - Decided to adopt Swift 5.

        <!-- tasks
        [{"title":"Adopt Swift 5","owner":"Craig","due":"2026-09-10","quote":"We will adopt Swift 5"}]
        -->

        ## Additional Notes
        - Remember to update documentation.
        """

        let output = SummaryService.cleanedWithTasks(raw)
        XCTAssertTrue(output.summary.contains("# Meeting Minutes"))
        XCTAssertTrue(output.summary.contains("## Decisions"))
        XCTAssertTrue(output.summary.contains("## Additional Notes"))
        XCTAssertTrue(output.summary.contains("- Remember to update documentation."))
        XCTAssertFalse(output.summary.contains("<!-- tasks"))
        XCTAssertFalse(output.summary.contains("-->"))
        XCTAssertNotNil(output.tasksJSON)
        XCTAssertEqual(TaskExtractor.parse(output.tasksJSON), .malformed)
    }

    func testCleanedWithTasksLegacyTextWithoutBlock() {
        let raw = """
        # Meeting Minutes

        - Discussion point 1
        """

        let output = SummaryService.cleanedWithTasks(raw)
        XCTAssertEqual(output.summary, "# Meeting Minutes\n\n- Discussion point 1")
        XCTAssertNil(output.tasksJSON)
    }

    func testUserPromptContainsMeetingDate() {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 9
        comps.day = 5
        comps.hour = 10
        let date = Calendar(identifier: .gregorian).date(from: comps)!

        let prompt = SummaryService.userPrompt(transcript: "Hello world", meetingDate: date)
        XCTAssertTrue(prompt.contains("2026-09-05"))
        XCTAssertTrue(prompt.contains("<!-- tasks"))
        XCTAssertTrue(prompt.contains("Rules: only explicit commitments"))
    }

    func testAbsentBlockKeepsTasks() throws {
        let meetingURL = root.appendingPathComponent("2026-09-01 1000 Sync", isDirectory: true)
        let initialTask = TaskItem(
            id: "initial-1",
            meetingURL: meetingURL,
            meetingTitle: "Sync",
            meetingDate: Date(),
            title: "Original Task",
            owner: "Craig",
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([initialTask], for: meetingURL)
        controller.refresh()
        XCTAssertEqual(controller.tasks.count, 1)

        // Summary without tasks block (absent)
        let output = SummaryOutput(summary: "# Minutes without tasks", tasksJSON: nil)
        controller.record(
            summaryOutput: output,
            meetingURL: meetingURL,
            meetingTitle: "Sync",
            meetingDate: Date(),
            attendees: [],
            speakerNames: [],
            myName: "Me"
        )

        XCTAssertEqual(controller.tasks.count, 1, "Existing tasks must be kept when block is absent")
        XCTAssertEqual(controller.tasks.first?.title, "Original Task")
        XCTAssertNil(controller.lastError)
    }

    func testMalformedBlockKeepsTasksAndSetsLastError() throws {
        let meetingURL = root.appendingPathComponent("2026-09-01 1000 Sync", isDirectory: true)
        let initialTask = TaskItem(
            id: "initial-1",
            meetingURL: meetingURL,
            meetingTitle: "Sync",
            meetingDate: Date(),
            title: "Original Task",
            owner: "Craig",
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([initialTask], for: meetingURL)
        controller.refresh()
        XCTAssertEqual(controller.tasks.count, 1)

        // Summary with malformed JSON
        let output = SummaryOutput(summary: "# Minutes", tasksJSON: "this is not json {")
        controller.record(
            summaryOutput: output,
            meetingURL: meetingURL,
            meetingTitle: "Sync",
            meetingDate: Date(),
            attendees: [],
            speakerNames: [],
            myName: "Me"
        )

        XCTAssertEqual(controller.tasks.count, 1, "Existing tasks must be kept when block is malformed")
        XCTAssertEqual(controller.tasks.first?.title, "Original Task")
        XCTAssertNotNil(controller.lastError)
        XCTAssertTrue(controller.lastError?.contains("readable tasks block") == true)
    }

    func testNonEmptyArrayWithNoUsableItemsKeepsTasksAndSetsLastError() throws {
        let meetingURL = root.appendingPathComponent("2026-09-01 1000 Sync", isDirectory: true)
        let initialTask = TaskItem(
            id: "initial-1",
            meetingURL: meetingURL,
            meetingTitle: "Sync",
            meetingDate: Date(),
            title: "Original Task",
            owner: "Craig",
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([initialTask], for: meetingURL)
        controller.refresh()
        XCTAssertEqual(controller.tasks.count, 1)

        // Summary with non-empty array but 0 usable items
        let output = SummaryOutput(summary: "# Minutes", tasksJSON: "[{\"owner\":\"Craig\"},{\"due\":\"2026-09-10\"}]")
        controller.record(
            summaryOutput: output,
            meetingURL: meetingURL,
            meetingTitle: "Sync",
            meetingDate: Date(),
            attendees: [],
            speakerNames: [],
            myName: "Me"
        )

        XCTAssertEqual(controller.tasks.count, 1, "Existing tasks must be preserved when no usable items")
        XCTAssertEqual(controller.tasks.first?.title, "Original Task")
        XCTAssertNotNil(controller.lastError)
        XCTAssertTrue(controller.lastError?.contains("no usable items") == true)
    }

    func testExplicitEmptyArrayClearsTasks() throws {
        let meetingURL = root.appendingPathComponent("2026-09-01 1000 Sync", isDirectory: true)
        let initialTask = TaskItem(
            id: "initial-1",
            meetingURL: meetingURL,
            meetingTitle: "Sync",
            meetingDate: Date(),
            title: "Original Task",
            owner: "Craig",
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([initialTask], for: meetingURL)
        controller.refresh()
        XCTAssertEqual(controller.tasks.count, 1)

        // Summary with explicit empty array []
        let output = SummaryOutput(summary: "# Minutes", tasksJSON: "[]")
        controller.record(
            summaryOutput: output,
            meetingURL: meetingURL,
            meetingTitle: "Sync",
            meetingDate: Date(),
            attendees: [],
            speakerNames: [],
            myName: "Me"
        )

        XCTAssertEqual(controller.tasks.count, 0, "Explicit empty array must clear existing tasks")
        XCTAssertNil(controller.lastError)
    }

    func testTasksControllerGroupedOrdering() {
        let t1 = TaskItem(
            id: "1",
            meetingURL: nil,
            meetingTitle: "Beta Sync",
            meetingDate: nil,
            title: "Task without due",
            owner: "Bob",
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(timeIntervalSince1970: 100),
            completedAt: nil
        )
        let t2 = TaskItem(
            id: "2",
            meetingURL: nil,
            meetingTitle: "Alpha Sync",
            meetingDate: nil,
            title: "Task with earlier due",
            owner: "Alice",
            due: "2026-09-01",
            quote: nil,
            status: .open,
            createdAt: Date(timeIntervalSince1970: 50),
            completedAt: nil
        )
        let t3 = TaskItem(
            id: "3",
            meetingURL: nil,
            meetingTitle: "Alpha Sync",
            meetingDate: nil,
            title: "Task with later due",
            owner: "Alice",
            due: "2026-09-10",
            quote: nil,
            status: .open,
            createdAt: Date(timeIntervalSince1970: 200),
            completedAt: nil
        )
        let t4 = TaskItem(
            id: "4",
            meetingURL: nil,
            meetingTitle: "Alpha Sync",
            meetingDate: nil,
            title: "Task without due newer",
            owner: "Alice",
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(timeIntervalSince1970: 300),
            completedAt: nil
        )

        let groupedByMeeting = TasksController.grouped([t1, t2, t3, t4], by: .meeting)
        XCTAssertEqual(groupedByMeeting.map(\.key), ["Alpha Sync", "Beta Sync"])

        let alphaTasks = groupedByMeeting[0].tasks
        XCTAssertEqual(alphaTasks.map(\.id), ["2", "3", "4"], "Due asc first, then nil due by createdAt desc")

        let groupedByOwner = TasksController.grouped([t1, t2, t3, t4], by: .owner)
        XCTAssertEqual(groupedByOwner.map(\.key), ["Alice", "Bob"])
    }

    func testImportRecipeJSONInvalidJSON() {
        let result = controller.importRecipeJSON("not valid json at all", usedMeetings: [], myName: "Me")
        guard case .invalidJSON(let msg) = result else {
            XCTFail("Expected .invalidJSON, got \(result)")
            return
        }
        XCTAssertEqual(msg, "Recipe output was not valid JSON; nothing imported.")
        XCTAssertEqual(controller.lastError, "Recipe output was not valid JSON; nothing imported.")
    }

    func testImportRecipeJSONEndToEndWithFixtureMeeting() throws {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let meetingDate = df.date(from: "2026-09-01")!
        let meetingFolder = root.appendingPathComponent("2026-09-01 1000 Design Review", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingFolder, withIntermediateDirectories: true)

        let fixtureMeeting = MeetingSummary(
            url: meetingFolder,
            title: "Design Review",
            dateLabel: "9/1 10:00",
            startedAt: meetingDate,
            rowCount: 10,
            durationSeconds: 1800,
            attendees: [Attendee(name: "Craig Angulo", email: "craig@apple.com")]
        )

        let recipeOutput = """
        ```json
        [
          {
            "title": "Update design tokens",
            "owner": "craig",
            "due": "2026-09-10",
            "quote": "I will update tokens",
            "meetingTitle": "Design Review",
            "meetingDate": "2026-09-01"
          },
          {
            "title": "Unmatched task",
            "owner": "alice",
            "due": "2026-09-12",
            "quote": "Quote for unmatched",
            "meetingTitle": "Nonexistent Meeting",
            "meetingDate": "2026-08-20"
          }
        ]
        ```
        """

        let result = controller.importRecipeJSON(recipeOutput, usedMeetings: [fixtureMeeting], myName: "Byungjoo")
        guard case .done(let imported, let failed, let msg) = result else {
            XCTFail("Expected .done, got \(result)")
            return
        }
        XCTAssertEqual(imported, 2)
        XCTAssertEqual(failed, 0)
        XCTAssertEqual(msg, "Imported 2 tasks.")

        let all = controller.tasks
        XCTAssertEqual(all.count, 2)

        let matched = try XCTUnwrap(all.first(where: { $0.title == "Update design tokens" }))
        XCTAssertEqual(matched.meetingURL, meetingFolder)
        XCTAssertEqual(matched.owner, "Craig Angulo")
        XCTAssertEqual(matched.due, "2026-09-10")

        let unmatched = try XCTUnwrap(all.first(where: { $0.title == "Unmatched task" }))
        XCTAssertNil(unmatched.meetingURL)
        XCTAssertEqual(unmatched.meetingTitle, "Nonexistent Meeting")
        XCTAssertEqual(unmatched.quote, "Quote for unmatched")
    }

    func testImportRecipeJSONMeetingFileWriteFailureReportsMessage() throws {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let meetingDate = df.date(from: "2026-09-01")!
        let meetingFolder = root.appendingPathComponent("2026-09-01 1000 ReadOnlyMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingFolder, withIntermediateDirectories: true)

        let fixtureMeeting = MeetingSummary(
            url: meetingFolder,
            title: "ReadOnlyMeeting",
            dateLabel: "9/1 10:00",
            startedAt: meetingDate,
            rowCount: 10,
            durationSeconds: 1800,
            attendees: []
        )

        // Make meeting folder read-only
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: meetingFolder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: meetingFolder.path)
        }

        let recipeOutput = """
        [
          {
            "title": "Task in read-only meeting",
            "owner": "me",
            "due": "2026-09-15",
            "meetingTitle": "ReadOnlyMeeting",
            "meetingDate": "2026-09-01"
          }
        ]
        """

        let result = controller.importRecipeJSON(recipeOutput, usedMeetings: [fixtureMeeting], myName: "Me")
        guard case .done(let imported, let failed, let msg) = result else {
            XCTFail("Expected .done, got \(result)")
            return
        }
        XCTAssertEqual(imported, 0, "Items whose meeting write fails must not be added to the index")
        XCTAssertEqual(failed, 1, "Meeting file write failed")
        XCTAssertTrue(msg.contains("could not be saved"), "Message should indicate meeting file could not be saved: \(msg)")
        XCTAssertTrue(controller.lastError?.contains("could not be saved") == true)
        XCTAssertEqual(controller.tasks.count, 0, "Index must remain unchanged")
    }

    func testImportRecipeJSONMeetingFileWriteAndCleanupFailureComposesMessage() throws {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let meetingDate = df.date(from: "2026-09-01")!
        let meetingFolder = root.appendingPathComponent("2026-09-01 1000 WriteAndCleanupFail", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingFolder, withIntermediateDirectories: true)

        let meetingTasksFile = meetingFolder.appendingPathComponent("tasks.json")
        try "[]".write(to: meetingTasksFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: meetingTasksFile.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: meetingTasksFile.path)
        }

        let fixtureMeeting = MeetingSummary(
            url: meetingFolder,
            title: "WriteAndCleanupFail",
            dateLabel: "9/1 10:00",
            startedAt: meetingDate,
            rowCount: 10,
            durationSeconds: 1800,
            attendees: []
        )

        let mockCleanupError = NSError(domain: "test.cleanup", code: 42, userInfo: [NSLocalizedDescriptionKey: "disk cleanup failed"])
        let storeWithFailingCleanup = TaskStore(rootURL: root, indexWriter: nil, fileRemover: { url in
            throw mockCleanupError
        })
        let testController = TasksController(store: storeWithFailingCleanup)

        let recipeOutput = """
        [
          {
            "title": "Task with failing write and cleanup",
            "owner": "me",
            "due": "2026-09-15",
            "meetingTitle": "WriteAndCleanupFail",
            "meetingDate": "2026-09-01"
          }
        ]
        """

        let result = testController.importRecipeJSON(recipeOutput, usedMeetings: [fixtureMeeting], myName: "Me")
        guard case .done(let imported, let failed, let msg) = result else {
            XCTFail("Expected .done, got \(result)")
            return
        }

        XCTAssertEqual(imported, 0)
        XCTAssertEqual(failed, 1)
        XCTAssertTrue(msg.contains("could not be saved"), "Message must contain 'could not be saved': \(msg)")
        XCTAssertTrue(msg.contains("; cleanup also failed: disk cleanup failed"), "Message must contain cleanup failure details: \(msg)")
        XCTAssertTrue(testController.lastError?.contains("; cleanup also failed: disk cleanup failed") == true)
        XCTAssertEqual(testController.tasks.count, 0)
    }
}
