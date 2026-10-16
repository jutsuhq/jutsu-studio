import Foundation

/// Data files bundled with JutsuCore.
public enum JutsuCoreResources {
    /// List prices per model and resolution. Contributors update this file when Higgsfield changes pricing.
    public static var pricingURL: URL? {
        Bundle.module.url(forResource: "pricing", withExtension: "json")
    }

    /// The video models (`VideoModelCatalog`). Contributors add a model here, with its prices in `pricing.json`.
    public static var modelsURL: URL? {
        Bundle.module.url(forResource: "models", withExtension: "json")
    }

    /// Holds `Models.xcstrings`, the models' titles.
    static var bundle: Bundle { .module }
}
