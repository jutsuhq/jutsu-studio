import Foundation
import JutsuCore
import Persistence
import SwiftData
import Testing

@Suite struct TemplateRecordTests {
    private func template(name: String, createdAt: Date = Date(timeIntervalSince1970: 1_000)) -> JobTemplate {
        JobTemplate(
            name: name, createdAt: createdAt, mode: .restyle,
            references: [LocalImage(fileURL: URL(fileURLWithPath: "/tmp/templates/1-face.png"))], presetID: UUID(),
            prompt: "neon", resolution: .p720, audio: .mute)
    }

    @Test func storesAndRenamesTemplates() throws {
        let context = ModelContext(try StoreContainer.make(inMemory: true))
        let neon = template(name: "Neon")
        context.insert(try TemplateRecord(template: neon))
        context.insert(try TemplateRecord(template: template(name: "Clay")))
        try context.save()

        let records = try context.fetch(TemplateRecord.byName)
        #expect(records.map(\.name) == ["Clay", "Neon"])
        let record = try #require(records.last)
        #expect(try record.template() == neon)

        try record.rename(to: "Alpha")
        try context.save()
        #expect(try context.fetch(TemplateRecord.byName).map(\.name) == ["Alpha", "Clay"])
        #expect(try record.template().name == "Alpha")
        #expect(try record.template().references == neon.references)
    }

    /// Stores written before templates existed must keep opening, with their jobs.
    @Test func storeWithoutTemplatesOpensWithTheCurrentSchema() throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: "TemplateMigration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let layout = FileLayout(root: temp, defaultOutputFolder: temp.appending(path: "Movies"))
        try layout.prepareDirectories()
        let job = makeJob(state: .done)
        do {
            let oldSchema = Schema([JobRecord.self, AssetRecord.self])
            let configuration = ModelConfiguration(schema: oldSchema, url: layout.storeURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: oldSchema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(try JobRecord(job: job))
            try context.save()
        }

        let context = ModelContext(try StoreContainer.make(inMemory: false, layout: layout))
        #expect(try context.fetch(FetchDescriptor<JobRecord>()).map { try $0.job() } == [job])
        context.insert(try TemplateRecord(template: template(name: "Neon")))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<TemplateRecord>()) == 1)
    }
}
