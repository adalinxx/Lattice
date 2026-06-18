import ArrayTrie
import cashew

public extension Block {
    /// Cashew resolution policy for the content carried by this block.
    ///
    /// This intentionally resolves the block's own content package, not its
    /// transitive execution inputs. State roots, parent blocks, and child block
    /// values remain external Volume roots with independent validation and
    /// retention policies.
    static var contentResolutionPaths: ArrayTrie<ResolutionStrategy> {
        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set([SPEC_PROPERTY], value: .targeted)
        paths.set([TRANSACTIONS_PROPERTY], value: .recursive)
        paths.set([CHILDREN_PROPERTY, ""], value: .list)
        return paths
    }
}

public extension VolumeImpl where NodeType == Block {
    /// Resolve the block content package:
    /// block internals, chain spec, transaction trie + transaction bodies, and
    /// the child-link trie structure. This does not resolve state Volumes,
    /// parent/ancestor block Volumes, or child block Volumes.
    func resolveBlockContent(fetcher: Fetcher) async throws -> Self {
        try await resolve(paths: Block.contentResolutionPaths, fetcher: fetcher)
    }

    /// `source:` overload of ``resolveBlockContent(fetcher:)``: resolve the same
    /// content package, but drive resolution from a batched cashew
    /// ``ContentSource`` instead of a per-CID ``Fetcher``. cashew wraps the
    /// source in a single ``CoalescingFetcher`` for the whole walk, so this is
    /// byte-identical to the `fetcher:` path — it runs the same resolution walk
    /// over the same `contentResolutionPaths` — while collapsing each concurrent
    /// wave of child fetches into one batched request.
    func resolveBlockContent(source: any ContentSource) async throws -> Self {
        try await resolve(paths: Block.contentResolutionPaths, source: source)
    }
}
