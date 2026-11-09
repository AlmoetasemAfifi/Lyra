// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Wordlight",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Wordlight",
            path: "Sources/Wordlight",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ServiceManagement"), .linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox")]
        )
    ]
)
