// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "KeyTypeDev",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "KeyTypeDev", targets: ["KeyTypeDev"])],
    dependencies: [
        .package(path: "Packages/AppCompatibility"),
        .package(path: "Packages/AutocompleteCore"),
        .package(path: "Packages/CompletionUI"),
        .package(path: "Packages/ConstrainedGeneration"),
        .package(path: "Packages/MacContextCapture"),
        .package(path: "Packages/ModelManagement"),
        .package(path: "Packages/ModelRuntime"),
        .package(path: "Packages/Personalization"),
        .package(path: "Packages/Prompting"),
        .package(path: "Packages/TextInsertion"),
        .package(path: "Packages/TokenProfiles"),
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", from: "1.1.0")
    ],
    targets: [
        .executableTarget(
            name: "KeyTypeDev",
            dependencies: [
                "AppCompatibility", "AutocompleteCore", "CompletionUI", "ConstrainedGeneration",
                "MacContextCapture", .product(name: "ModelManagement", package: "ModelManagement"),
                .product(name: "ModelProfileGeneration", package: "ModelManagement"),
                .product(name: "ModelRuntime", package: "ModelRuntime"),
                .product(name: "LlamaModelRuntime", package: "ModelRuntime"),
                "Personalization", "Prompting", "TextInsertion", "TokenProfiles",
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern")
            ],
            path: "KeyType",
            exclude: ["Assets.xcassets", "KeyType.icon", "Info.plist", "KeyType.entitlements"]
        )
    ]
)
