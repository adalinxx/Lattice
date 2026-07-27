public struct GenesisAction: Codable, Sendable {
    public let directory: String
    public let blockCID: String

    public init(directory: String, blockCID: String) {
        self.directory = directory
        self.blockCID = CIDIdentity.canonicalString(blockCID) ?? blockCID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        directory = try container.decode(String.self, forKey: .directory)
        let decoded = try container.decode(String.self, forKey: .blockCID)
        blockCID = CIDIdentity.canonicalString(decoded) ?? decoded
    }

    private enum CodingKeys: String, CodingKey {
        case directory
        case blockCID
    }

    func stateDelta() -> Int {
        blockCID.utf8.count + directory.utf8.count
    }
}
