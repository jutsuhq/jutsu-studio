import Testing

/// Suites that write `UserDefaults` run one test at a time: swift-corelibs-foundation's UserDefaults is not
/// safe for concurrent writes across suites, and a parallel run occasionally read back a default instead of
/// the value just set.
@Suite(.serialized) enum UserDefaultsBackedTests {}
