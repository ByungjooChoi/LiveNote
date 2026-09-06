import SwiftUI

/// People 목록 및 인물별 회의 타임라인 뷰.
struct PeopleView: View {
    @Environment(AppState.self) private var app
    @Bindable var directory: PeopleDirectory
    @Binding var screen: ContentView.Screen
    @State private var query = ""
    @State private var selected: PersonCard?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let card = selected {
                personTimeline(card)
            } else {
                directoryContent
            }
        }
        .task(id: app.meetingStore.meetings) {
            await directory.refresh(meetings: app.meetingStore.meetings, myName: app.myName)
            if let current = selected {
                selected = directory.people.first(where: { $0.id == current.id })
            }
        }
    }

    // MARK: - 디렉터리 목록 (검색 + 회사별 그룹)

    private var directoryContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchBar

            if let warning = directory.lastWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(Theme.vermilion)
                    .padding(.horizontal, 2)
            }

            if directory.isLoading && directory.groups.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else if directory.people.isEmpty {
                Text("No people yet. Attendees and named speakers from saved meetings appear here.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 20)
            } else {
                let filteredGroups = PeopleAggregator.filter(directory.groups, query: query)
                if filteredGroups.isEmpty {
                    Text("No results for \"\(query)\"")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 20)
                } else {
                    ForEach(filteredGroups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(group.people) { card in
                                personCard(card)
                            }
                        }
                    }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search people by name, alias, or email…", text: $query)
                .textFieldStyle(.plain)
                .font(.body)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .themedCard()
    }

    private func personCard(_ card: PersonCard) -> some View {
        Button {
            selected = card
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.accent.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Text(String(card.displayName.prefix(1)).uppercased())
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    let lastLabel = card.lastMeetingAt.map { PeopleAggregator.lastMeetingLabel($0) } ?? "Never"
                    let meetingCountText = "\(card.meetingCount) \(card.meetingCount == 1 ? "meeting" : "meetings")"
                    let captionParts = [card.company, meetingCountText, "Last \(lastLabel)"].compactMap { $0 }
                    Text(captionParts.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                let openTaskCount = app.tasks.openCount(forAttendeeNames: card.aliases)
                if openTaskCount > 0 {
                    Text("\(openTaskCount) open")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.12))
                        .clipShape(Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .themedCard()
        }
        .buttonStyle(.plain)
    }

    // MARK: - 인물 회의 타임라인

    private func personTimeline(_ card: PersonCard) -> some View {
        let meetingsByURL = Dictionary(app.meetingStore.meetings.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let personMeetings = card.meetingURLs.compactMap { meetingsByURL[$0] }
        let openTaskCount = app.tasks.openCount(forAttendeeNames: card.aliases)

        return VStack(alignment: .leading, spacing: 14) {
            Button {
                selected = nil
            } label: {
                Label("People", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)

            VStack(alignment: .leading, spacing: 4) {
                Text(card.displayName)
                    .font(.title2.weight(.bold))
                if let company = card.company {
                    Text(company)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !card.emails.isEmpty {
                    Text(card.emails.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                let meetingCountText = "\(personMeetings.count) \(personMeetings.count == 1 ? "meeting" : "meetings")"
                let taskCountText = "\(openTaskCount) \(openTaskCount == 1 ? "open task" : "open tasks")"
                Text("\(meetingCountText) · \(taskCountText)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)

            if personMeetings.isEmpty {
                Text("No saved meetings found for this person.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 14)
            } else {
                ForEach(personMeetings) { meeting in
                    MeetingCardView(meeting: meeting) {
                        screen = .meeting(meeting.url)
                    }
                }
            }
        }
    }
}
