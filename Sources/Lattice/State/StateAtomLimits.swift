public enum StateAtomLimits {
    public static let maximumDirectoryBytes = 64
    public static let maximumAccountBytes = 128
    public static let maximumGeneralKeyBytes = 128

    public static func isAccount(_ value: String) -> Bool {
        isVisibleASCII(value, maximumBytes: maximumAccountBytes)
            && !value.contains(DIRECTORY_KEY_SEPARATOR)
    }

    public static func isDirectory(_ value: String) -> Bool {
        isVisibleASCII(value, maximumBytes: maximumDirectoryBytes)
            && !value.contains(DIRECTORY_KEY_SEPARATOR)
    }

    public static func isGeneralKey(_ value: String) -> Bool {
        isVisibleASCII(value, maximumBytes: maximumGeneralKeyBytes)
    }

    private static func isVisibleASCII(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        let bytes = value.utf8
        return !bytes.isEmpty
            && bytes.count <= maximumBytes
            && bytes.allSatisfy { (0x21...0x7e).contains($0) }
    }
}
