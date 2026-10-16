import Foundation
import JutsuCore
import Presentation
import SwiftUI

extension LibraryView {
    // MARK: Delivery sets

    /// A new delivery set of the materials' current versions, in the order given, opened in the sets sheet.
    func newDeliverySet(_ ids: [UUID]) {
        let wanted = Set(ids)
        let byID = Dictionary(
            records.filter { wanted.contains($0.id) }.compactMap { record in
                (try? record.material()).map { (record.id, $0) }
            }
        ) { first, _ in first }
        let materials = ids.compactMap { byID[$0] }
        guard !materials.isEmpty else { return }
        let set = DeliverySet(name: DeliveryContent.defaultName(at: .now), items: DeliverySet.items(from: materials))
        let store = environment.store
        Task {
            do {
                try await store.saveDeliverySet(set)
                selected.clear()
                imageSelected = []
                deliverySets = DeliverySetsRoute(selection: set.id)
            } catch {
                exportMessage = UserMessage(
                    title: String(localized: "Couldn't make the delivery set"), message: error.localizedDescription)
            }
        }
    }

    // MARK: Outside editor

    /// The catalog entry behind a card; `nil` when it is gone or can't be read.
    func catalogMaterial(_ id: UUID) -> JutsuCore.Material? {
        try? records.first { $0.id == id }?.material()
    }

    func editInOtherApp(_ id: UUID) {
        guard let material = catalogMaterial(id) else { return }
        exportMessage = environment.editInOtherApp(material)
    }

    func importEditedVersion(_ id: UUID) {
        guard let material = catalogMaterial(id) else { return }
        Task { exportMessage = await environment.pickEditedVersion(of: material) }
    }

    /// A file dropped on a card becomes the card's new version. A file the library already holds, such as another
    /// card dragged onto it, is not an edit.
    func dropEditedVersion(_ urls: [URL], on id: UUID) -> Bool {
        guard let file = urls.first, file.isFileURL, let material = catalogMaterial(id),
            material.current.fileURL != nil,
            !records.contains(where: { record in
                (try? record.material()).map { OutsideEdit.isOwnFile(file, of: $0) } ?? false
            })
        else { return false }
        Task { exportMessage = await environment.importEditedVersion(file, of: material) }
        return true
    }
}

/// "Edit in…" and "Import as New Version…" in a card's menu, for a result or image with a file on this Mac.
struct OutsideEditButtons: View {
    let edit: () -> Void
    let importVersion: () -> Void

    var body: some View {
        Button("Edit in…", systemImage: "paintbrush", action: edit)
            .help("Open a copy in another app; the original stays as it is")
        Button("Import as New Version…", systemImage: "square.and.arrow.down.on.square", action: importVersion)
            .help("Bring an edited file back as this item's next version, linked to the one it was made from")
    }
}
