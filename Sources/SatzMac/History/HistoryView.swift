import SatzKit
import SwiftUI

/// Everything dictated, newest first. It is what opens when satz itself is
/// opened from Finder, Spotlight or the Dock: the reason to open a dictation
/// app is to find something said earlier. Search narrows it, a click copies,
/// × forgets one.
struct HistoryView: View {
    let history: History
    let preferences: Preferences

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !history.entries.isEmpty { search }

            if history.limit == 0 && history.entries.isEmpty {
                quiet(de("Der Verlauf ist aus. In den Einstellungen lässt er sich wieder einschalten.",
                         en: "History is off. It can be switched back on in Settings."))
            } else if history.entries.isEmpty {
                EmptyHint(trigger: preferences.trigger, mode: preferences.triggerMode)
            } else if shown.isEmpty {
                quiet(de("Nichts gefunden für „\(query)“.", en: "Nothing found for “\(query)”."))
            } else if isSnapshot {
                // ImageRenderer draws a ScrollView's content as nothing.
                list
            } else {
                ScrollView { list }
                    .scrollIndicators(.automatic)
            }

            Spacer(minLength: 0)

            // When it is off, the message above says so already.
            if history.limit > 0 {
                Text(keeping)
                    .font(Typography.text(13))
                    .foregroundStyle(theme.inkSecondary)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.ground)
        // A search kept from last time showed a filtered list, or "Nothing found".
        .onDisappear { query = "" }
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.inkSecondary)
            if isSnapshot {
                Text(de("Suchen", en: "Search"))
                    .foregroundStyle(theme.inkOnCard)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: $query, prompt: Text(de("Suchen", en: "Search")).foregroundStyle(theme.inkOnCard))
                    .textFieldStyle(.plain)
                    // Escape empties the search before it does anything else.
                    .onExitCommand { query = "" }
            }
        }
        .font(Typography.text(15))
        .foregroundStyle(theme.ink)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .surface(radius: 10)
    }

    private var list: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(days, id: \.start) { day in
                VStack(alignment: .leading, spacing: 4) {
                    Text(day.title)
                        .font(Typography.text(12, .semibold))
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(theme.inkSecondary)
                        .padding(.leading, 10)
                    VStack(spacing: 0) {
                        ForEach(day.entries) { entry in
                            HistoryRow(entry: entry, remove: { history.remove(entry) })
                        }
                    }
                    .padding(4)
                    .surface(radius: 14)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private var shown: [History.Entry] {
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return history.entries }
        return history.entries.filter { $0.text.localizedCaseInsensitiveContains(words) || ($0.app?.localizedCaseInsensitiveContains(words) ?? false) }
    }

    /// The entries by day, newest day first, each day as one surface.
    private var days: [(start: Date, title: String, entries: [History.Entry])] {
        let calendar = Calendar.current
        var result: [(start: Date, title: String, entries: [History.Entry])] = []
        for entry in shown {
            let start = calendar.startOfDay(for: entry.date)
            if result.last?.start == start {
                result[result.count - 1].entries.append(entry)
            } else {
                result.append((start, Self.dayTitle(entry.date, calendar: calendar), [entry]))
            }
        }
        return result
    }

    private static func dayTitle(_ date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return de("Heute", en: "Today") }
        if calendar.isDateInYesterday(date) { return de("Gestern", en: "Yesterday") }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    private var keeping: String {
        switch history.limit {
        case History.keepAll: de("Alles wird behalten. Ändern in den Einstellungen.", en: "Everything is kept. Change it in Settings.")
        default: de("Die letzten \(history.limit) werden behalten. Ändern in den Einstellungen.", en: "The last \(history.limit) are kept. Change it in Settings.")
        }
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(Typography.text(15))
            .foregroundStyle(theme.inkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }
}

/// One dictation: the text in full up to three lines, where it went and when.
/// The row copies on click; under the pointer it also offers to forget it.
private struct HistoryRow: View {
    let entry: History.Entry
    let remove: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: copy) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.text)
                        .font(Typography.text(15))
                        .lineSpacing(2)
                        .lineLimit(3)
                        .foregroundStyle(theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        Image(systemName: copied ? "checkmark" : (entry.pasted ? "arrow.down.to.line" : "doc.on.clipboard"))
                            .font(.system(size: 10, weight: .semibold))
                        Text(copied ? de("Kopiert", en: "Copied") : meta)
                            .font(Typography.text(12.5))
                    }
                    .foregroundStyle(theme.inkSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(de("Kopieren", en: "Copy"))

            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.inkSecondary)
            .opacity(hovering ? 1 : 0)
            .help(de("Aus dem Verlauf entfernen", en: "Remove from history"))
            .accessibilityLabel(de("Entfernen", en: "Remove"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? theme.hover : .clear))
        .onHover { hovering = $0 }
        // The × shows only under the pointer; a right click and VoiceOver
        // reach both actions without it.
        .contextMenu {
            Button(de("Kopieren", en: "Copy"), action: copy)
            Button(de("Aus dem Verlauf entfernen", en: "Remove from history"), action: remove)
        }
        .accessibilityAction(named: Text(de("Aus dem Verlauf entfernen", en: "Remove from history")), remove)
    }

    private var meta: String {
        let time = entry.date.formatted(date: .omitted, time: .shortened)
        let place = entry.pasted ? (entry.app ?? de("Eingefügt", en: "Pasted")) : de("Zwischenablage", en: "Clipboard")
        return "\(place) · \(time)"
    }

    private func copy() {
        Clipboard.put(entry.text)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}
