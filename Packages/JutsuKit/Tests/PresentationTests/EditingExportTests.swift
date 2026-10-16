import JutsuCore
import Presentation
import Testing

@Suite struct EditingExportPresentationTests {
    @Test func menuDescribesEachPreset() {
        #expect(ExportPreset.premiere.formatSummary == "ProRes 422 · PCM · MOV")
        #expect(ExportPreset.editingH264.formatSummary == "H.264 · AAC · MP4")
        #expect(Set(ExportPreset.allCases.map(\.title)).count == ExportPreset.allCases.count)
    }
}
