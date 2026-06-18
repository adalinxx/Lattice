import cashew

public enum TransactionSigning {
    public static let domain = "lattice-tx-v1"

    public static func preimage(bodyCID: String, chainPath: [String], nonce: UInt64) -> String {
        var lines: [String] = [
            "domain:\(domain.utf8.count):\(domain)",
            "chainPath.count:\(chainPath.count)"
        ]
        for component in chainPath {
            lines.append("chainPath.component:\(component.utf8.count):\(component)")
        }
        lines.append("nonce:\(nonce)")
        lines.append("bodyCID:\(bodyCID.utf8.count):\(bodyCID)")
        return lines.joined(separator: "\n")
    }

    public static func preimage(body: TransactionBody, bodyCID: String? = nil) -> String {
        // known-valid local node; CID computation cannot fail (no Float/Double fields)
        let cid = bodyCID ?? (try! HeaderImpl<TransactionBody>(node: body).rawCID)
        return preimage(bodyCID: cid, chainPath: body.chainPath, nonce: body.nonce)
    }

    public static func preimage(bodyHeader: HeaderImpl<TransactionBody>) -> String? {
        guard let body = bodyHeader.node else { return nil }
        return preimage(body: body, bodyCID: bodyHeader.rawCID)
    }

    public static func sign(body: TransactionBody, bodyCID: String? = nil, privateKeyHex: String) -> String? {
        CryptoUtils.sign(message: preimage(body: body, bodyCID: bodyCID), privateKeyHex: privateKeyHex)
    }

    public static func sign(bodyHeader: HeaderImpl<TransactionBody>, privateKeyHex: String) -> String? {
        guard let signingPreimage = preimage(bodyHeader: bodyHeader) else { return nil }
        return CryptoUtils.sign(message: signingPreimage, privateKeyHex: privateKeyHex)
    }

    public static func verify(body: TransactionBody, bodyCID: String, signature: String, publicKeyHex: String) -> Bool {
        CryptoUtils.verify(
            message: preimage(body: body, bodyCID: bodyCID),
            signature: signature,
            publicKeyHex: publicKeyHex
        )
    }

    public static func verify(bodyHeader: HeaderImpl<TransactionBody>, signature: String, publicKeyHex: String) -> Bool {
        guard let signingPreimage = preimage(bodyHeader: bodyHeader) else { return false }
        return CryptoUtils.verify(message: signingPreimage, signature: signature, publicKeyHex: publicKeyHex)
    }
}
