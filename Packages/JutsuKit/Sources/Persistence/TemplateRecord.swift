import Foundation
import JutsuCore
import SwiftData

/// A persisted `JobTemplate`, stored as JSON in `templateData` like `JobRecord`; `name` and `createdAt`
/// are copies for sorting.
@Model
public final class TemplateRecord {
    @Attribute(.unique) public private(set) var id: UUID
    public private(set) var name: String
    public private(set) var createdAt: Date
    public private(set) var templateData: Data

    public init(template: JobTemplate) throws {
        id = template.id
        name = template.name
        createdAt = template.createdAt
        templateData = try JSONEncoder().encode(template)
    }

    /// The stored template.
    public func template() throws -> JobTemplate {
        try JSONDecoder().decode(JobTemplate.self, from: templateData)
    }

    /// Renames the template; the name column and the stored JSON change together.
    public func rename(to newName: String) throws {
        var template = try template()
        template.name = newName
        templateData = try JSONEncoder().encode(template)
        name = newName
    }

    /// Every template, by name.
    public static var byName: FetchDescriptor<TemplateRecord> {
        FetchDescriptor<TemplateRecord>(
            sortBy: [SortDescriptor(\TemplateRecord.name), SortDescriptor(\TemplateRecord.createdAt)])
    }
}
