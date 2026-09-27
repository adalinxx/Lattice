import cashew

public enum TransactionPreflightDisposition: Sendable, Equatable {
    case ready
    case future
    case invalid
    case unavailable
}

public struct TransactionPreflightResult: Sendable, Equatable {
    public let tipCID: String
    public let disposition: TransactionPreflightDisposition
}

public extension ChainLevel {
    /// Classify one transaction against a coherent canonical-tip snapshot.
    /// `parentState` is needed only for a child-chain withdrawal; it must be the
    /// entering parent state of the carrier the caller is considering.
    /// Block-wide reward, conservation, count, and aggregate-growth checks
    /// remain the block builder's responsibility.
    func preflightTransaction(
        _ transaction: Transaction,
        parentState: LatticeStateHeader? = nil,
        fetcher: any Fetcher
    ) async -> TransactionPreflightResult {
        let tip = await chain.transactionPreflightTip()
        guard let snapshot = tip.snapshot else {
            return TransactionPreflightResult(
                tipCID: tip.cid,
                disposition: .unavailable
            )
        }

        do {
            let bodyHeader = try await transaction.body.resolve(fetcher: fetcher)
            guard let body = bodyHeader.node else {
                return result(.unavailable, tipCID: tip.cid)
            }
            let resolved = Transaction(
                signatures: transaction.signatures,
                body: bodyHeader
            )
            guard try await resolved.validateTransactionForNexus(fetcher: fetcher),
                  body.genesisActionsAreValid(),
                  body.chainPath == context.path,
                  context.path.count > 1
                    || (body.depositActions.isEmpty
                        && body.withdrawalActions.isEmpty) else {
                return result(.invalid, tipCID: tip.cid)
            }

            let specHeader = VolumeImpl<ChainSpec>(rawCID: snapshot.specCID)
            guard let spec = try await specHeader.resolve(fetcher: fetcher).node else {
                return result(.unavailable, tipCID: tip.cid)
            }
            guard spec.isValid,
                  try body.getStateDelta() <= spec.maxStateGrowth,
                  try await TransactionBody.batchVerifyPolicies(
                    bodies: [body],
                    spec: spec,
                    chainPath: context.path,
                    fetcher: fetcher
                  ) else {
                return result(.invalid, tipCID: tip.cid)
            }

            let stateHeader = LatticeStateHeader(rawCID: snapshot.postStateCID)
            guard let state = try await stateHeader.resolve(fetcher: fetcher).node else {
                return result(.unavailable, tipCID: tip.cid)
            }

            var hasFutureNonce = false
            for signer in Set(body.signers).sorted() {
                let expected = try await state.accountState.nextExpectedNonce(
                    for: signer,
                    fetcher: fetcher
                )
                if body.nonce < expected {
                    return result(.invalid, tipCID: tip.cid)
                }
                if body.nonce > expected { hasFutureNonce = true }
            }
            if hasFutureNonce {
                return result(.future, tipCID: tip.cid)
            }

            if !body.withdrawalActions.isEmpty {
                guard let parentState,
                      let directory = context.path.last,
                      let parent = try await parentState.resolve(fetcher: fetcher).node
                else {
                    return result(.unavailable, tipCID: tip.cid)
                }
                guard try await body.withdrawalsAreValid(
                    directory: directory,
                    prevState: state,
                    parentState: parent,
                    fetcher: fetcher
                ) else {
                    return result(.invalid, tipCID: tip.cid)
                }
            }

            _ = try await state.proveAndUpdateState(
                allAccountActions: body.accountActions,
                allActions: body.actions,
                allDepositActions: body.depositActions,
                allGenesisActions: body.genesisActions,
                allReceiptActions: body.receiptActions,
                allWithdrawalActions: body.withdrawalActions,
                transactionBodies: [body],
                fetcher: fetcher
            )
            return result(.ready, tipCID: tip.cid)
        } catch {
            return result(
                transactionPreflightEvidenceUnavailable(error)
                    ? .unavailable
                    : .invalid,
                tipCID: tip.cid
            )
        }
    }

    private func result(
        _ disposition: TransactionPreflightDisposition,
        tipCID: String
    ) -> TransactionPreflightResult {
        TransactionPreflightResult(tipCID: tipCID, disposition: disposition)
    }
}

private func transactionPreflightEvidenceUnavailable(_ error: Error) -> Bool {
    if error is FetcherError { return true }
    if let error = error as? DataErrors {
        switch error {
        case .nodeNotAvailable, .keyNotFound:
            return true
        default:
            return false
        }
    }
    if let error = error as? WasmPolicyError,
       case .missingModule = error {
        return true
    }
    if let error = error as? TransformErrors,
       case .missingData = error {
        return true
    }
    if let error = error as? ValidationErrors {
        switch error {
        case .transactionNotResolved, .prevStateNotResolved,
             .postStateNotResolved:
            return true
        case .serializationError:
            return false
        }
    }
    return false
}
