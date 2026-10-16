import Presentation
import SwiftUI

/// A result's video file, dragged out of the app. It goes out as a file URL (`public.file-url`), the way Finder drags
/// files, so Finder copies the file, Messages attaches it and an editor imports it.
struct ResultFile: Transferable, Identifiable {
    /// The result's ID.
    let id: UUID
    let url: URL

    init?(_ item: LibraryItemModel) {
        guard let url = item.outputFile else { return nil }
        self.init(id: item.id, url: url)
    }

    init(id: UUID, url: URL) {
        self.id = id
        self.url = url
    }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.url)
    }
}

extension View {
    /// The grid around draggable cards: `dragged` gives the results a drag of the card with this ID carries.
    @ViewBuilder
    func resultFileDragContainer(_ dragged: @escaping (UUID) -> [LibraryItemModel]) -> some View {
        if #available(macOS 26, *) {
            dragContainer(for: ResultFile.self) { (cardID: UUID) in dragged(cardID).compactMap(ResultFile.init) }
        } else {
            self
        }
    }

    /// Makes a card in a `resultFileDragContainer` draggable; a card that carries nothing isn't.
    /// - Parameter dragged: what the drag carries. Before macOS 26 a drag carries one item: the first of them.
    @ViewBuilder
    func resultFileDrag(cardID: UUID, dragged: [LibraryItemModel]) -> some View {
        if dragged.isEmpty {
            self
        } else if #available(macOS 26, *) {
            draggable(containerItemID: cardID)
        } else {
            resultFileDrag(dragged.lazy.compactMap(ResultFile.init).first)
        }
    }

    /// Makes a view that stands for one result, like a Queue row, drag its file; nothing without one.
    @ViewBuilder
    func resultFileDrag(_ file: ResultFile?) -> some View {
        if let file {
            draggable(file)
        } else {
            self
        }
    }
}
