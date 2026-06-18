// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lattice",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "Lattice",
            targets: ["Lattice"]),
        .executable(
            name: "LatticeDemo",
            targets: ["LatticeDemo"]),
        .executable(
            name: "lattice-determinism-check",
            targets: ["DeterminismCheck"]),
        .executable(
            name: "LatticeSim",
            targets: ["LatticeSim"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0" ..< "4.0.0"),
        .package(url: "https://github.com/adalinxx/Multikey.git", from: "1.0.0"),
        .package(url: "https://github.com/adalinxx/cashew.git", from: "3.1.0"),
        .package(url: "https://github.com/adalinxx/UInt256.git", from: "1.1.0"),
        .package(url: "https://github.com/swift-libp2p/swift-cid.git", from: "0.0.1"),
        .package(url: "https://github.com/swift-libp2p/swift-multicodec.git", .upToNextMinor(from: "0.2.1")),
        .package(url: "https://github.com/JohnSundell/CollectionConcurrencyKit.git", from: "0.2.0"),
        .package(url: "https://github.com/swiftwasm/WasmKit.git", .upToNextMinor(from: "0.2.0")),
    ],
    targets: [
        .target(
            name: "Lattice",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Multikey", package: "Multikey"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "CID", package: "swift-cid"),
                .product(name: "Multicodec", package: "swift-multicodec"),
                .product(name: "UInt256", package: "UInt256"),
                .product(name: "CollectionConcurrencyKit", package: "CollectionConcurrencyKit"),
                .product(name: "WasmKit", package: "WasmKit"),
                .product(name: "WasmParser", package: "WasmKit"),
            ]),
        .executableTarget(
            name: "LatticeDemo",
            dependencies: ["Lattice"]),
        // — shared golden-vector source of truth, imported by
        // both the XCTest suite (macOS) and the determinism executable (Linux).
        .target(
            name: "DeterminismGoldens",
            dependencies: [
                "Lattice",
                .product(name: "WasmParser", package: "WasmKit"),
                .product(name: "WAT", package: "WasmKit"),
            ]),
        // — Linux host-determinism gate (no XCTest).
        .executableTarget(
            name: "DeterminismCheck",
            dependencies: ["DeterminismGoldens"]),
        // Wave-4: the consensus simulator / adversarial-scenario harness lives
        // outside the Lattice library product, so simulation-only code never
        // ships in the consensus library. Drives Lattice through its public
        // (simulation-facing) API only.
        .target(
            name: "LatticeSimulation",
            dependencies: ["Lattice"]),
        .executableTarget(
            name: "LatticeSim",
            dependencies: ["LatticeSimulation"]),
        .testTarget(
            name: "LatticeTests",
            dependencies: [
                "Lattice",
                "LatticeSimulation",
                "DeterminismGoldens",
                .product(name: "WasmParser", package: "WasmKit"),
                .product(name: "WAT", package: "WasmKit"),
            ])
    ]
)
