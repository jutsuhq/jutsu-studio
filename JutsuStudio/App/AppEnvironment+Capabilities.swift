import JutsuCore

/// What the active connection offers beyond `GenerationProvider`. The one place the provider is cast to its optional
/// services: each is `nil` while disconnected or when the connection doesn't offer it (an API key offers none).
extension AppEnvironment {
    /// The Motion Library.
    var motionLibrary: (any MotionLibrary)? { provider as? any MotionLibrary }

    /// The images and videos the account uploaded.
    var accountUploads: (any AccountUploads)? { provider as? any AccountUploads }

    /// The account's elements.
    var accountElements: (any AccountElements)? { provider as? any AccountElements }

    /// Reference images: Create's Generate… sheet.
    var imageProvider: (any ImageProvider)? { provider as? any ImageProvider }

    /// Character sheets, whether or not their calls are confirmed; Create Character reads `characterMaker`.
    var characterSheets: (any CharacterSheetMaker)? { provider as? any CharacterSheetMaker }

    /// Virality scores in batch comparison.
    var viralityScorer: (any ViralityScoring)? { provider as? any ViralityScoring }

    /// The voices of Change Voice.
    var voiceLibrary: (any VoiceLibrary)? { provider as? any VoiceLibrary }

    /// The account's history, which Library pages through.
    var generationHistory: (any GenerationHistory)? { provider as? any GenerationHistory }

    /// Likes on the account, which the library's star follows.
    var generationLikes: (any GenerationLikes)? { provider as? any GenerationLikes }

    /// The account's credit history, for Settings › Spending.
    var creditHistory: (any CreditHistory)? { provider as? any CreditHistory }

    /// The account's model constraints (`models_explore`).
    var modelConstraintsSource: (any ModelConstraintsSource)? { provider as? any ModelConstraintsSource }
}
