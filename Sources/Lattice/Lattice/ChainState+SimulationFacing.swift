import UInt256

// Simulation-facing surface for the `LatticeSimulation` target (which lives
// outside this module and therefore sees only public API). These are thin,
// behavior-free shims over the existing internals — promoted here, in a
// separate file, so the simulator drives the REAL consensus paths without
// widening the internals themselves.

public extension ChainState {
    /// Simulation-facing: run the REAL fork-choice reorg evaluation for a newly
    /// released block — the same internal `checkForReorg` path `submitBlock`
    /// uses. The `LatticeSimulation` target releases blocks into a `ChainState`
    /// and reads reorg decisions straight off this, so fork choice is never
    /// reimplemented in the simulator.
    func evaluateForkChoice(forReleasedBlock block: BlockMeta) -> Reorganization? {
        checkForReorg(block: block)
    }
}

public extension BlockInfoImpl {
    /// Simulation-facing factory mirroring the internal memberwise initializer,
    /// so the `LatticeSimulation` target can build the block fixtures it feeds
    /// into the real `ChainState`.
    static func make(
        blockHash: String,
        parentBlockHash: String?,
        blockHeight: UInt64,
        work: UInt256
    ) -> BlockInfoImpl {
        BlockInfoImpl(
            blockHash: blockHash,
            parentBlockHash: parentBlockHash,
            blockHeight: blockHeight,
            work: work
        )
    }
}
