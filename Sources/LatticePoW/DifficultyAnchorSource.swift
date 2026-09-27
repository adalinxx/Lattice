/// Anything that can answer the inherited difficulty anchor of an admitted
/// block. Validation asks through this instead of naming the block tree, so the
/// validity rules do not depend on the structure that stores blocks.
public protocol DifficultyAnchorSource: Sendable {
    func difficultyAnchor(forBlockHash hash: String) async -> DifficultyAnchor?
}
