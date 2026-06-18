import cashew
import Foundation

let ACCOUNT_STATE_PROPERTY = "accountState"
let GENERAL_STATE_PROPERTY = "generalState"
let DEPOSIT_STATE_PROPERTY = "depositState"
let GENESIS_STATE_PROPERTY = "genesisState"
let RECEIPT_STATE_PROPERTY = "receiptState"

let LATTICE_STATE_PROPERTIES: Set<String> = Set([
    ACCOUNT_STATE_PROPERTY,
    GENERAL_STATE_PROPERTY,
    DEPOSIT_STATE_PROPERTY,
    GENESIS_STATE_PROPERTY,
    RECEIPT_STATE_PROPERTY
])

public struct LatticeState: Node {
    public let accountState: AccountStateHeader
    public let generalState: GeneralStateHeader
    public let depositState: DepositStateHeader
    public let genesisState: GenesisStateHeader
    public let receiptState: ReceiptStateHeader

    static let empty = Self(
        // known-valid local node; CID computation cannot fail (no Float/Double fields)
        accountState: try! AccountStateHeader(node: AccountState()),
        // known-valid local node; CID computation cannot fail (no Float/Double fields)
        generalState: try! GeneralStateHeader(node: GeneralState()),
        // known-valid local node; CID computation cannot fail (no Float/Double fields)
        depositState: try! DepositStateHeader(node: DepositState()),
        // known-valid local node; CID computation cannot fail (no Float/Double fields)
        genesisState: try! GenesisStateHeader(node: GenesisState()),
        // known-valid local node; CID computation cannot fail (no Float/Double fields)
        receiptState: try! ReceiptStateHeader(node: ReceiptState())
    )
    // known-valid local node; CID computation cannot fail (no Float/Double fields)
    public static let emptyHeader = try! LatticeStateHeader(node: empty)

    static func emptyState() -> Self { empty }

    public func get(property: PathSegment) -> (any cashew.Header)? {
        switch property {
            case ACCOUNT_STATE_PROPERTY: return accountState
            case GENERAL_STATE_PROPERTY: return generalState
            case DEPOSIT_STATE_PROPERTY: return depositState
            case GENESIS_STATE_PROPERTY: return genesisState
            case RECEIPT_STATE_PROPERTY: return receiptState
            default: return nil
        }
    }

    public func properties() -> Set<PathSegment> {
        return LATTICE_STATE_PROPERTIES
    }

    public func set(properties: [PathSegment : any cashew.Header]) -> LatticeState {
        return Self(
            accountState: properties[ACCOUNT_STATE_PROPERTY] as? AccountStateHeader ?? accountState,
            generalState: properties[GENERAL_STATE_PROPERTY] as? GeneralStateHeader ?? generalState,
            depositState: properties[DEPOSIT_STATE_PROPERTY] as? DepositStateHeader ?? depositState,
            genesisState: properties[GENESIS_STATE_PROPERTY] as? GenesisStateHeader ?? genesisState,
            receiptState: properties[RECEIPT_STATE_PROPERTY] as? ReceiptStateHeader ?? receiptState
        )
    }

    public func proveAndUpdateState(allAccountActions: [AccountAction], allActions: [Action], allDepositActions: [DepositAction], allGenesisActions: [GenesisAction], allReceiptActions: [ReceiptAction], allWithdrawalActions: [WithdrawalAction], transactionBodies: [TransactionBody], fetcher: Fetcher) async throws -> (LatticeState, StateDiff) {
        // The receipt withdrawer/demander transfer is part of the consensus
        // account-delta rule — one definition, shared with node admission.
        let mergedAccountActions = try TransactionBody.netAccountDeltas(
            accountActions: allAccountActions,
            receiptActions: allReceiptActions
        )
        async let accountResult = accountState.proveAndUpdateState(allAccountActions: mergedAccountActions, transactionBodies: transactionBodies, fetcher: fetcher)
        async let generalResult = generalState.proveAndUpdateState(allActions: allActions, fetcher: fetcher)
        async let genesisResult = genesisState.proveAndUpdateState(allGenesisActions: allGenesisActions, fetcher: fetcher)
        async let receiptResult = receiptState.proveAndUpdateState(allReceiptActions: allReceiptActions, fetcher: fetcher)
        let (afterWithdrawals, withdrawalDiff) = try await depositState.proveAndDeleteForWithdrawals(allWithdrawalActions: allWithdrawalActions, fetcher: fetcher)
        async let depositResult = afterWithdrawals.proveAndUpdateState(allDepositActions: allDepositActions, fetcher: fetcher)

        let (finalAccountState, accountDiff) = try await accountResult
        let (finalGeneralState, generalDiff) = try await generalResult
        let (finalDepositState, depositDiff) = try await depositResult
        let (finalGenesisState, genesisDiff) = try await genesisResult
        let (finalReceiptState, receiptDiff) = try await receiptResult

        var diff = withdrawalDiff
        diff.merge(accountDiff)
        diff.merge(generalDiff)
        diff.merge(depositDiff)
        diff.merge(genesisDiff)
        diff.merge(receiptDiff)

        return (Self(accountState: finalAccountState, generalState: finalGeneralState, depositState: finalDepositState, genesisState: finalGenesisState, receiptState: finalReceiptState), diff)
    }
}

public typealias LatticeStateHeader = VolumeImpl<LatticeState>
