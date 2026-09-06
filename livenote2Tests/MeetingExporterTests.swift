import XCTest
@testable import LiveNote

@MainActor
final class MeetingExporterTests: XCTestCase {

    private var tempDir: URL!
    private var previousLogOverride: URL?

    override func setUp() {
        super.setUp()
        TestLogSandbox.activate()
        previousLogOverride = AppLog.directoryOverride
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingExporterTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        AppLog.directoryOverride = tempDir
    }

    override func tearDown() {
        AppLog.flush()
        AppLog.directoryOverride = previousLogOverride
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - MarkdownHTML Tests

    func testEscapeSpecialCharacters() {
        let raw = #"Apple & Orange <tag> "quote" 'single'"#
        let escaped = MarkdownHTML.escape(raw)
        XCTAssertEqual(escaped, "Apple &amp; Orange &lt;tag&gt; &quot;quote&quot; &#39;single&#39;")
    }

    func testInlineFormatting() {
        let raw = "This is **bold** text and *italic* style with `let x = 1` and [Google](https://google.com)."
        let rendered = MarkdownHTML.inline(raw)
        XCTAssertTrue(rendered.contains("<strong>bold</strong>"))
        XCTAssertTrue(rendered.contains("<em>italic</em>"))
        XCTAssertTrue(rendered.contains("<code>let x = 1</code>"))
        XCTAssertTrue(rendered.contains(#"<a href="https://google.com">Google</a>"#))

        // Underscore italic
        let underscoreItalic = "Here is _italic text_ in sentence."
        XCTAssertEqual(MarkdownHTML.inline(underscoreItalic), "Here is <em>italic text</em> in sentence.")

        // HTTP vs non-HTTP links
        let mixedLinks = "[Good](http://example.com) and [Bad](javascript:alert(1)) and [Rel](/path)"
        let renderedLinks = MarkdownHTML.inline(mixedLinks)
        XCTAssertTrue(renderedLinks.contains(#"<a href="http://example.com">Good</a>"#))
        XCTAssertTrue(renderedLinks.contains("[Bad](javascript:alert(1))"))
        XCTAssertTrue(renderedLinks.contains("[Rel](/path)"))
    }

    func testHeadingLevels() {
        let md = """
        # Main Title
        ## Sub Title
        Paragraph under subtitle
        """
        let body = MarkdownHTML.renderBody(markdown: md)
        XCTAssertTrue(body.contains("<h1>Main Title</h1>\n"))
        XCTAssertTrue(body.contains("<h2>Sub Title</h2>\n"))
        XCTAssertTrue(body.contains("<p>Paragraph under subtitle</p>\n"))
    }

    func testNestedListsAndParagraphClosing() {
        // level 0 -> 1 -> 0
        let list1 = """
        - Item 1
          - Sub 1
        - Item 2

        Paragraph after list
        """
        let body1 = MarkdownHTML.renderBody(markdown: list1)
        XCTAssertEqual(
            body1,
            """
            <ul>
            <li>Item 1<ul><li>Sub 1</li></ul></li>
            <li>Item 2</li>
            </ul>
            <p>Paragraph after list</p>

            """
        )

        // level 0 -> 2 jumps, then closed at paragraph
        let list2 = """
        - Root
            - Deep item
        Following paragraph
        """
        let body2 = MarkdownHTML.renderBody(markdown: list2)
        XCTAssertEqual(
            body2,
            """
            <ul>
            <li>Root<ul><li><ul><li>Deep item</li></ul></li>
            </ul></li>
            </ul>
            <p>Following paragraph</p>

            """
        )
    }

    func testNestedListStructureAndJump() {
        // - a followed by   - b produces <li>a<ul><li>b</li></ul></li>
        let md1 = """
        - a
          - b
        """
        let body1 = MarkdownHTML.renderBody(markdown: md1)
        XCTAssertTrue(
            body1.contains("<li>a<ul><li>b</li></ul></li>"),
            "Expected <li>a<ul><li>b</li></ul></li> structure, got: \(body1)"
        )

        // 0 -> 2 jump produces valid nesting with wrapper <li> and no consecutive <ul> tags
        let md2 = """
        - Root
            - Deep item
        """
        let body2 = MarkdownHTML.renderBody(markdown: md2)
        XCTAssertFalse(
            body2.contains("<ul>\n<ul>") || body2.contains("<ul><ul>"),
            "Nested lists must not contain consecutive <ul> tags without <li>, got: \(body2)"
        )
        XCTAssertTrue(
            body2.contains("<li>Root<ul><li><ul><li>Deep item</li></ul></li>"),
            "Expected wrapper <li> between nested <ul> tags, got: \(body2)"
        )
    }

    func testEmptyLinesBreakParagraphs() {
        let md = """
        Paragraph A

        Paragraph B
        Paragraph C
        """
        let body = MarkdownHTML.renderBody(markdown: md)
        XCTAssertEqual(
            body,
            """
            <p>Paragraph A</p>
            <p>Paragraph B</p>
            <p>Paragraph C</p>

            """
        )
    }

    func testFullHtmlPage() {
        let html = MarkdownHTML.render(markdown: "# Test\n\nContent", title: "Meeting & Notes")
        XCTAssertTrue(html.contains("<!doctype html>"))
        XCTAssertTrue(html.contains("<title>Meeting &amp; Notes</title>"))
        XCTAssertTrue(html.contains(#"charset="utf-8""#))
        XCTAssertTrue(html.contains("<h1>Test</h1>"))
        XCTAssertTrue(html.contains("<p>Content</p>"))
    }

    // MARK: - MeetingExporter Tests

    private func makeFixtureMeeting(
        title: String? = "Sprint Sync",
        summary: String? = "Discussed release plan.",
        attendees: [Attendee]? = [
            Attendee(name: "Alice", email: "alice@example.com"),
            Attendee(name: "Bob", email: nil)
        ],
        rows: [TranscriptRow] = [
            TranscriptRow(
                channel: .me,
                english: "Hello team.",
                korean: "안녕하세요 팀 여러분.",
                startSeconds: 0,
                endSeconds: 4
            ),
            TranscriptRow(
                channel: .them,
                speakerSlot: 0,
                english: "Good morning.",
                korean: "좋은 아침입니다.",
                startSeconds: 5,
                endSeconds: 8
            )
        ]
    ) -> SavedMeeting {
        SavedMeeting(
            startedAt: Date(timeIntervalSince1970: 1770000000), // fixed timestamp
            durationSeconds: 125,
            title: title,
            myName: "Philip",
            speakerNames: [0: "Alice"],
            rows: rows,
            summary: summary,
            attendees: attendees
        )
    }

    func testMarkdownGenerationWithAllFields() {
        let meeting = makeFixtureMeeting()
        let mdWithTranscript = MeetingExporter.markdown(for: meeting, includeTranscript: true)

        XCTAssertTrue(mdWithTranscript.hasPrefix("# Sprint Sync\n\n"))
        XCTAssertTrue(mdWithTranscript.contains("· 2m · 2 participants\n\n"))
        XCTAssertTrue(mdWithTranscript.contains("## Attendees\n- Alice <alice@example.com>\n- Bob\n\n"))
        XCTAssertTrue(mdWithTranscript.contains("Discussed release plan.\n\n"))
        XCTAssertTrue(mdWithTranscript.contains("## Transcript\n\n"))
        XCTAssertTrue(mdWithTranscript.contains("- **[00:00] Philip:** Hello team.\n  - 안녕하세요 팀 여러분.\n"))
        XCTAssertTrue(mdWithTranscript.contains("- **[00:05] Alice:** Good morning.\n  - 좋은 아침입니다.\n"))
        XCTAssertTrue(mdWithTranscript.hasSuffix("\n"))
        XCTAssertFalse(mdWithTranscript.hasSuffix("\n\n"))

        let mdWithoutTranscript = MeetingExporter.markdown(for: meeting, includeTranscript: false)
        XCTAssertFalse(mdWithoutTranscript.contains("## Transcript"))
    }

    func testMarkdownNoMinutesFallback() {
        let meeting = makeFixtureMeeting(summary: nil)
        let md = MeetingExporter.markdown(for: meeting, includeTranscript: false)
        XCTAssertTrue(md.contains("_No minutes._\n"))
    }

    func testParticipantCountingDistinct() {
        var meeting = makeFixtureMeeting()
        // Add another row by Philip
        meeting.rows.append(
            TranscriptRow(channel: .me, english: "Next topic.", startSeconds: 10, endSeconds: 15)
        )
        let participants = MeetingExporter.participantNames(meeting)
        XCTAssertEqual(participants.count, 2)
        XCTAssertTrue(participants.contains("Philip"))
        XCTAssertTrue(participants.contains("Alice"))
    }

    func testFileNameFormattingAndSafeTitle() {
        let date = Date(timeIntervalSince1970: 1770000000)
        let mdName = MeetingExporter.fileName(title: "Project / Alpha: Sync?", startedAt: date, format: .markdown)
        XCTAssertTrue(mdName.contains("Project Alpha Sync.md"))
        XCTAssertFalse(mdName.contains("/"))
        XCTAssertFalse(mdName.contains(":"))
        XCTAssertFalse(mdName.contains("?"))

        let nilTitleName = MeetingExporter.fileName(title: nil, startedAt: date, format: .html)
        XCTAssertTrue(nilTitleName.contains("Meeting.html"))
    }

    func testDocumentThrowsOnEmpty() {
        XCTAssertThrowsError(
            try MeetingExporter.document(markdown: "   \n\t  ", title: "Empty", format: .markdown)
        ) { error in
            XCTAssertEqual(error as? ExportError, ExportError.emptyDocument)
        }
    }

    func testWriteAtomicAndRoundTrip() throws {
        let doc = try MeetingExporter.document(
            markdown: "# Test\n\nSample content.",
            title: "RoundTrip",
            format: .markdown
        )
        let fileURL = tempDir.appendingPathComponent(doc.fileName)

        try MeetingExporter.write(doc, to: fileURL)

        let readBack = try Data(contentsOf: fileURL)
        XCTAssertEqual(readBack, doc.data)

        // Unwritable path should throw writeFailed
        let invalidURL = URL(fileURLWithPath: "/nonexistent_folder_xyz/forbidden/file.md")
        XCTAssertThrowsError(try MeetingExporter.write(doc, to: invalidURL)) { error in
            guard case .writeFailed = (error as? ExportError) else {
                XCTFail("Expected ExportError.writeFailed, got \(error)")
                return
            }
        }
    }

    func testHtmlExportMatchesRenderer() throws {
        let meeting = makeFixtureMeeting()
        let doc = try MeetingExporter.document(for: meeting, format: .html, includeTranscript: true)
        let expectedMarkdown = MeetingExporter.markdown(for: meeting, includeTranscript: true)
        let expectedHtml = MarkdownHTML.render(
            markdown: expectedMarkdown,
            title: meeting.title ?? MeetingStore.resolveTitleFallback(meeting)
        )
        let actualHtml = String(data: doc.data, encoding: .utf8)
        XCTAssertEqual(actualHtml, expectedHtml)
    }

    // MARK: - Fix Round 2 Tests

    func testInlineStripsNulAndDoesNotExpandForgedPlaceholders() {
        var input = ""
        for i in 0..<14 {
            input += "[\(i)](http://example.com/\u{0000}LINK_\(i + 1)\u{0000}) "
        }
        let output = MarkdownHTML.inline(input)
        XCTAssertFalse(output.contains("\u{0000}"), "Output must not contain NUL character")
        XCTAssertLessThanOrEqual(output.count, input.count * 4, "Output length must not exponentially explode")
    }

    func testInlineNestedCodeInsideLinkLabel() {
        let input = "[`myCode`](https://example.com)"
        let output = MarkdownHTML.inline(input)
        XCTAssertEqual(output, #"<a href="https://example.com"><code>myCode</code></a>"#)
    }

    func testLinkURLContainingBackticksIsPreserved() {
        let input = "[x](https://example.com/`v1`)"
        let output = MarkdownHTML.inline(input)
        XCTAssertFalse(output.contains("\u{0000}"), "Output must not contain NUL character")
        XCTAssertFalse(output.contains("CODE_"), "Output must not contain CODE_ placeholder token")
        XCTAssertTrue(output.contains(#"href="https://example.com/`v1`""#), "href must contain backticks literally")
        XCTAssertEqual(output, #"<a href="https://example.com/`v1`">x</a>"#)
    }

    func testClipboardWriterReportsFailureWithoutSuccess() {
        let successStatus = ClipboardWriter.copy("Some text", write: { text in
            XCTAssertEqual(text, "Some text")
            return true
        })
        XCTAssertEqual(successStatus, .copied)

        let failureStatus = ClipboardWriter.copy("Some text", write: { _ in
            return false
        })
        XCTAssertEqual(failureStatus, .failed("Copy failed: clipboard write was rejected"))
    }

    func testCompletionRetainsOnlyFeedbackNotParent() throws {
        @MainActor
        final class ParentProbe {
            let feedback = ExportFeedback()
            var app = NSObject()
        }

        var parent: ParentProbe? = ParentProbe()
        weak var w: AnyObject?
        w = parent

        let feedback = parent!.feedback
        let onStatus: @MainActor (ExportStatus) -> Void = { [feedback] in
            feedback.apply($0)
        }

        var provider: (() -> ExportDocument)? = { [parent] in
            _ = parent?.app
            return ExportDocument(fileName: "test.md", data: Data("# Title\n\nBody\n".utf8), format: .markdown)
        }

        let document = provider!()
        let completion = ExportMenu.makeCompletion(
            document: document,
            transcriptIncluded: false,
            onStatus: onStatus
        )

        provider = nil
        parent = nil

        XCTAssertNil(w, "ParentProbe must be deallocated because completion retains only feedback, not parent")

        let targetURL = tempDir.appendingPathComponent("parent-probe-export.md")
        completion(targetURL)

        XCTAssertTrue(feedback.isExported, "Calling completion must update feedback.isExported")
    }

    func testExportFeedbackAppliesStatuses() async throws {
        let feedback = ExportFeedback(resetDelay: .milliseconds(20))
        feedback.apply(.copied)
        XCTAssertTrue(feedback.isCopied)

        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(feedback.isCopied)

        feedback.apply(.exported(URL(fileURLWithPath: "/tmp/test.md")))
        XCTAssertTrue(feedback.isExported)

        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(feedback.isExported)

        feedback.apply(.failed("Test failure"))
        XCTAssertEqual(feedback.message, "Test failure")

        feedback.dismiss()
        XCTAssertNil(feedback.message)
    }

    func testExportFeedbackTimerDoesNotRetainAfterCancel() {
        var feedback: ExportFeedback? = ExportFeedback(resetDelay: .seconds(5))
        weak var weakFeedback: AnyObject?
        weakFeedback = feedback
        feedback?.apply(.copied)
        feedback?.apply(.exported(URL(fileURLWithPath: "/tmp/test.md")))
        feedback?.cancelTimers()
        feedback = nil
        XCTAssertNil(weakFeedback, "Feedback must be deallocated after cancelTimers and dropping strong reference")
    }

    func testMakeCompletionWritesAndReportsExported() throws {
        let doc = try MeetingExporter.document(
            markdown: "# Exported Document\n\nContent",
            title: "Exported Document",
            format: .markdown
        )
        let targetURL = tempDir.appendingPathComponent("test-export.md")
        var recordedStatus: ExportStatus?
        let completion = ExportMenu.makeCompletion(
            document: doc,
            transcriptIncluded: true,
            onStatus: { status in
                recordedStatus = status
            }
        )
        completion(targetURL)
        XCTAssertEqual(recordedStatus, .exported(targetURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path))
        let readBack = try String(contentsOf: targetURL, encoding: .utf8)
        XCTAssertTrue(readBack.contains("# Exported Document"))
    }

    func testMakeCompletionReportsWriteFailure() throws {
        let doc = try MeetingExporter.document(
            markdown: "# Exported Document\n\nContent",
            title: "Exported Document",
            format: .markdown
        )
        let unwritableURL = URL(fileURLWithPath: "/dev/null/x")
        var recordedStatus: ExportStatus?
        let completion = ExportMenu.makeCompletion(
            document: doc,
            transcriptIncluded: false,
            onStatus: { status in
                recordedStatus = status
            }
        )
        completion(unwritableURL)
        guard case .failed(let msg)? = recordedStatus else {
            XCTFail("Expected .failed status, got \(String(describing: recordedStatus))")
            return
        }
        XCTAssertTrue(msg.contains("Export failed:"))
    }

    func testSummaryIsVerbatimIncludingLeadingIndentAndTrailingSpaces() {
        let summaryWithSpaces = "   Indented line 1\n   Indented line 2 with spaces   \n"
        let meeting = makeFixtureMeeting(
            title: "Verbatim Test",
            summary: summaryWithSpaces
        )

        let withoutTranscript = MeetingExporter.markdown(for: meeting, includeTranscript: false)
        XCTAssertTrue(withoutTranscript.contains(summaryWithSpaces.trimmingCharacters(in: .newlines)))

        let withTranscript = MeetingExporter.markdown(for: meeting, includeTranscript: true)
        XCTAssertTrue(withTranscript.contains(summaryWithSpaces.trimmingCharacters(in: .newlines)))
        XCTAssertTrue(withTranscript.contains("## Transcript"))
    }

    func testDocumentUsesSourceTitleAndDate() throws {
        let staleTitle = "Stale Title"
        let freshDate = Date(timeIntervalSince1970: 1700000000)
        let source = ExportSource(
            markdown: "# Updated Notes\n\nFresh content",
            title: "Fresh Updated Title",
            date: freshDate
        )

        let mdDoc = try MeetingExporter.document(
            markdown: source.markdown,
            title: source.title,
            format: .markdown,
            date: source.date
        )
        XCTAssertTrue(mdDoc.fileName.contains("Fresh Updated Title"))
        XCTAssertFalse(mdDoc.fileName.contains(staleTitle))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        let expectedDateStr = formatter.string(from: freshDate)
        XCTAssertTrue(mdDoc.fileName.hasPrefix(expectedDateStr))

        let htmlDoc = try MeetingExporter.document(
            markdown: source.markdown,
            title: source.title,
            format: .html,
            date: source.date
        )
        let htmlStr = String(data: htmlDoc.data, encoding: .utf8)!
        XCTAssertTrue(htmlStr.contains("<title>Fresh Updated Title</title>"))
        XCTAssertFalse(htmlStr.contains(staleTitle))
    }

    // MARK: - Fix Round 4 Tests

    func testCodeSpanContainingLinkIsLiteral() {
        let input = "`[x](https://example.com)`"
        let output = MarkdownHTML.inline(input)
        XCTAssertEqual(output, "<code>[x](https://example.com)</code>")
        XCTAssertFalse(output.contains("\u{0000}"), "Output must not contain NUL character")
    }

    func testLinkThenCodeAndCodeThenLinkOrderIndependent() {
        let input1 = "[a](https://a.com) and `code`"
        let output1 = MarkdownHTML.inline(input1)
        XCTAssertEqual(output1, #"<a href="https://a.com">a</a> and <code>code</code>"#)
        XCTAssertFalse(output1.contains("\u{0000}"), "Output must not contain NUL character")

        let input2 = "`code` and [a](https://a.com)"
        let output2 = MarkdownHTML.inline(input2)
        XCTAssertEqual(output2, #"<code>code</code> and <a href="https://a.com">a</a>"#)
        XCTAssertFalse(output2.contains("\u{0000}"), "Output must not contain NUL character")
    }

    func testItalicWrappingCodeAndLink() {
        let italicCode = "_`name`_"
        let outputCode = MarkdownHTML.inline(italicCode)
        XCTAssertEqual(outputCode, "<em><code>name</code></em>")
        XCTAssertFalse(outputCode.contains("\u{0000}"), "Output must not contain NUL character")

        let italicLink = "_[x](https://e.com)_"
        let outputLink = MarkdownHTML.inline(italicLink)
        XCTAssertEqual(outputLink, #"<em><a href="https://e.com">x</a></em>"#)
        XCTAssertFalse(outputLink.contains("\u{0000}"), "Output must not contain NUL character")
    }

    func testBoldSpanningCodeSpan() {
        let input = "**a `b` c**"
        let output = MarkdownHTML.inline(input)
        XCTAssertEqual(output, "<strong>a <code>b</code> c</strong>")
        XCTAssertFalse(output.contains("\u{0000}"), "Output must not contain NUL character")
    }

    // MARK: - Fix Round 5 Tests

    func testManyCodeSpansOnOneLineRenderCorrectly() {
        let count = 5_000
        let input = String(repeating: "`x` ", count: count)
        let output = MarkdownHTML.inline(input)
        XCTAssertFalse(output.contains("\u{0000}"), "Output must not contain NUL character")
        XCTAssertFalse(output.contains("C0"), "Output must not contain unexpanded token")

        let target = "<code>x</code>"
        var occurrences = 0
        var searchRange = output.startIndex..<output.endIndex
        while let range = output.range(of: target, range: searchRange) {
            occurrences += 1
            searchRange = range.upperBound..<output.endIndex
        }
        XCTAssertEqual(occurrences, count, "Must render exactly 5,000 <code>x</code> occurrences")
        XCTAssertEqual(output, String(repeating: "<code>x</code> ", count: count))
    }

    func testManyLinksOnOneLineRenderCorrectly() {
        let count = 5_000
        let input = String(repeating: "[a](https://a.com) ", count: count)
        let output = MarkdownHTML.inline(input)
        XCTAssertFalse(output.contains("\u{0000}"), "Output must not contain NUL character")
        XCTAssertFalse(output.contains("L0"), "Output must not contain unexpanded token")

        let target = #"<a href="https://a.com">a</a>"#
        var occurrences = 0
        var searchRange = output.startIndex..<output.endIndex
        while let range = output.range(of: target, range: searchRange) {
            occurrences += 1
            searchRange = range.upperBound..<output.endIndex
        }
        XCTAssertEqual(occurrences, count, "Must render exactly 5,000 anchor occurrences")
        XCTAssertEqual(output, String(repeating: #"<a href="https://a.com">a</a> "#, count: count))
    }

    func testRepeatedBacktickBracketMixRendersLinear() {
        let count = 5_000
        let input = String(repeating: "`[` ", count: count)
        let output = MarkdownHTML.inline(input)
        XCTAssertFalse(output.contains("\u{0000}"), "Output must not contain NUL character")

        let target = "<code>[</code>"
        var occurrences = 0
        var searchRange = output.startIndex..<output.endIndex
        while let range = output.range(of: target, range: searchRange) {
            occurrences += 1
            searchRange = range.upperBound..<output.endIndex
        }
        XCTAssertEqual(occurrences, count, "Must render exactly 5,000 <code>[</code> occurrences")
        XCTAssertEqual(output, String(repeating: "<code>[</code> ", count: count))
    }

    func testInlineScalesLinearly() {
        func measureTime(for count: Int) -> TimeInterval {
            let input = String(repeating: "`x` ", count: count)
            let t0 = Date()
            _ = MarkdownHTML.inline(input)
            return Date().timeIntervalSince(t0)
        }

        let t2k = min(measureTime(for: 2_000), measureTime(for: 2_000))
        let t8k = min(measureTime(for: 8_000), measureTime(for: 8_000))
        let bound = 8.0 * max(t2k, 0.005)

        XCTAssertLessThan(
            t8k,
            bound,
            "t(8000) = \(t8k)s should scale linearly compared to t(2000) = \(t2k)s (bound: \(bound)s)"
        )
    }

    // MARK: - U3: Scanner Equivalence Corpus and Pathological Scaling Tests

    func testInlineScannerEquivalenceCorpus() {
        let corpus: [(input: String, expected: String)] = [
            (
                "`hello world`",
                "<code>hello world</code>"
            ),
            (
                "[Google](https://google.com)",
                #"<a href="https://google.com">Google</a>"#
            ),
            (
                "`unclosed backtick",
                "`unclosed backtick"
            ),
            (
                "[unclosed bracket",
                "[unclosed bracket"
            ),
            (
                "[label](notaurl)",
                "[label](notaurl)"
            ),
            (
                "[label](http://example.com with space)",
                "[label](http://example.com with space)"
            ),
            (
                "[](http://example.com)",
                "[](http://example.com)"
            ),
            (
                "[`code`](https://example.com)",
                #"<a href="https://example.com"><code>code</code></a>"#
            ),
            (
                "](https://example.com)",
                "](https://example.com)"
            ),
            (
                "`e\u{0301}`",
                "<code>e\u{0301}</code>"
            ),
            (
                "[x](https://example.com/`v1`)",
                #"<a href="https://example.com/`v1`">x</a>"#
            ),
            (
                "Text with `code` and [link](https://example.com) end",
                #"Text with <code>code</code> and <a href="https://example.com">link</a> end"#
            ),
            (
                "**bold** and *italic* with `code` and [link](http://test.com)",
                #"<strong>bold</strong> and <em>italic</em> with <code>code</code> and <a href="http://test.com">link</a>"#
            )
        ]

        for (input, expected) in corpus {
            XCTAssertEqual(MarkdownHTML.inline(input), expected, "Mismatch for input: \(input)")
        }
    }

    private func assertScalingLinear(patternName: String, generator: (Int) -> String) {
        func measure(count: Int) -> TimeInterval {
            let input = generator(count)
            let t0 = Date()
            _ = MarkdownHTML.inline(input)
            return Date().timeIntervalSince(t0)
        }
        let t2k = min(measure(count: 2_000), measure(count: 2_000))
        let t8k = min(measure(count: 8_000), measure(count: 8_000))
        let bound = 8.0 * max(t2k, 0.005)
        XCTAssertLessThan(
            t8k,
            bound,
            "\(patternName) t(8000) = \(t8k)s should scale linearly compared to t(2000) = \(t2k)s (bound: \(bound)s)"
        )
    }

    func testScalingUnclosedOpenBracket() {
        assertScalingLinear(patternName: "unclosed [ ") { String(repeating: "[ ", count: $0) }
    }

    func testScalingUnclosedLinkUrl() {
        assertScalingLinear(patternName: "unclosed [a](http://x") { String(repeating: "[a](http://x", count: $0) }
    }

    func testScalingRepeatedOpenBracketFollowedByOneCloseBracket() {
        assertScalingLinear(patternName: "[ repeated then ]") { String(repeating: "[", count: $0) + "]" }
    }

    func testScalingRepeatedBackticksFollowedByOneLetter() {
        assertScalingLinear(patternName: "` repeated then a") { String(repeating: "`", count: $0) + "a" }
    }

    func testScalingRepeatedDoubleAsterisk() {
        assertScalingLinear(patternName: "** repeated") { String(repeating: "**", count: $0) }
    }
}
