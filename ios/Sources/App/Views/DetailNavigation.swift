import SwiftUI

/// Shared route validation for collection-backed detail screens.
///
/// A detail destination is an id, not a retained model value. Once a refreshed
/// collection no longer contains that id, the destination has no truthful
/// content to show and should return to its parent list.
enum DetailNavigation {
    static func missingDestination(
        in path: [String],
        availableDestinations: Set<String>
    ) -> String? {
        guard let destination = path.last,
              !availableDestinations.contains(destination)
        else { return nil }
        return destination
    }
}

/// The short explanation shown after an invalid detail route is removed.
struct DetailRemovalNotice: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "info.circle.fill")
            .font(.callout.weight(.medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(.primary)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .accessibilityAddTraits(.isStaticText)
    }
}

/// Avoids leaving a blank pushed screen during the render in which its model
/// disappears. The owning stack also removes the invalid id and shows a notice.
struct DismissingDetailPlaceholder: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Color.clear.onAppear { dismiss() }
    }
}
