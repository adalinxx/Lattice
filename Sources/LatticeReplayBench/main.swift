import Foundation
import cashew
import UInt256
import LatticePrimitives
import LatticePoW
import LatticeBlockTree

// Restore-replay cost on the node's boot shape: a linear chain of N blocks,
// four facts each (block + its grind, a second grind, a validation).
// `swift run -c release LatticeReplayBench 100000`.

let count = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 25_000

func cid(_ seed: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: seed)).rawCID
}

let state = cid("replay-bench:state")
let spec = cid("replay-bench:spec")
func block(_ hash: String, parent: String?, height: Int) -> ChainFact {
    .block(ChainBlockFact(
        blockHash: hash, parentBlockHash: parent, blockHeight: UInt64(height),
        postStateCID: state, prevStateCID: state, specCID: spec,
        target: "ff", nextTarget: "ff", timestamp: Int64(height) * 1_000,
        stateDiff: .empty, childCommitments: [:]
    ))
}
func work(_ hash: String, _ id: String) -> ChainFact {
    .work(ChainWorkFact(
        blockHash: hash,
        contribution: VerifiedWorkContribution(id: id, work: UInt256(2))
    ))
}

let genesis = cid("replay-bench:0")
var batches = [BlockImportBatch.staged([
    block(genesis, parent: nil, height: 0),
    work(genesis, cid("replay-bench:grind:0")),
])]
var parent = genesis
for height in 1...count {
    let hash = cid("replay-bench:\(height)")
    batches.append(.staged([
        block(hash, parent: parent, height: height),
        work(hash, cid("replay-bench:grind:\(height)")),
    ]))
    batches.append(.staged([work(hash, cid("replay-bench:grind2:\(height)"))]))
    batches.append(.validation(blockHash: hash))
    parent = hash
}

// The fixture's own CID handling warmed the canonical-string cache; replay
// must pay its own way.
CIDIdentity.forgetProvenCanonical()
let start = Date()
let tree = try ChainTree.restoreWithoutContext(replaying: batches)
let elapsed = Date().timeIntervalSince(start)
precondition(tree.canonicalTip == parent, "replay did not reach the tip")
print(String(
    format: "REPLAY-BENCH blocks=%d facts=%d restore=%.3fs per-block=%.1fus",
    count, count * 4, elapsed, elapsed / Double(count) * 1_000_000
))
