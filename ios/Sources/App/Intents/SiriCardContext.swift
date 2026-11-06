import AppIntents
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension DashboardCardEntity: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { entity in
            [entity.title, entity.value, entity.status, entity.detail,
             "Last updated: " + ZeroZeroWidgetDateFormat.iso.string(from: entity.updatedAt)]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }
}

extension View {
    func siriCardContext(_ card: DashboardCard) -> some View {
        appEntityIdentifier(
            SpotlightIndex.indexable([card]).isEmpty ? nil
                : EntityIdentifier(for: DashboardCardEntity.self, identifier: card.id)
        )
    }
}
