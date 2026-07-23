import XCTest
@testable import Lattice
import Foundation
import UInt256
import cashew

private actor StagingContextRecorder {
    private var contexts: [ChainAdmissionStagingContext] = []

    func append(_ context: ChainAdmissionStagingContext) {
        contexts.append(context)
    }

    func snapshot() -> [ChainAdmissionStagingContext] {
        contexts
    }
}

final class AdmissionStagingContextTests: XCTestCase {
    func testRootBootstrapStagesItsVerifiedCarrierLink() async throws {
        let fetcher = StorableFetcher()
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            maxBlockSize: 1_000_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1_024,
            halvingInterval: 10_000,
            retargetWindow: 5
        )
        let genesis = try await buildAndStoreGenesis(
            spec: spec,
            timestamp: Int64(Date().timeIntervalSince1970 * 1_000),
            target: UInt256.max,
            fetcher: fetcher
        )
        let recorder = StagingContextRecorder()

        let bootstrapped = try await ChainLevel.bootstrap(
            context: testChainContext(),
            genesisHeader: try BlockHeader(node: genesis),
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: { context in
                await recorder.append(context)
            }
        )

        let contexts = await recorder.snapshot()
        let context = try XCTUnwrap(contexts.first)
        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(context.issuedCarrierLink, bootstrapped.parentCarrierLink)
        XCTAssertTrue(context.parentGenesisLinks.isEmpty)
        XCTAssertEqual(context.batch.facts.count, 2)
    }
}
