import SwiftUI

/// Disk state belongs beside the usable in-memory history, independently of
/// whether the last dictation reached its destination.
struct HistoryStorageWarning: View {
    let history: History
    @Environment(\.theme) private var theme

    var body: some View {
        if let title = history.storageWarningTitle, let detail = history.storageWarningDetail {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(Typography.text(14, .semibold))
                        .foregroundStyle(theme.ink)
                    Text(detail)
                        .font(Typography.text(13))
                        .foregroundStyle(theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .surface(radius: 12)
            .accessibilityElement(children: .combine)
        }
    }
}
