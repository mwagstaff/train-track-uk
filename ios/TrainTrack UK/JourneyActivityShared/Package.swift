// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JourneyActivityShared",
    platforms: [ .iOS(.v16) ],
    products: [
        .library(name: "JourneyActivityShared", targets: ["JourneyActivityShared"])
    ],
    targets: [
        .target(
            name: "JourneyActivityShared",
            dependencies: [],
            swiftSettings: [
                .define("ACTIVITYKIT_AVAILABLE", .when(platforms: [.iOS]))
            ]
        )
    ]
)
