// swift-tools-version: 5.10

import PackageDescription

#if TUIST
import struct ProjectDescription.PackageSettings
import struct ProjectDescription.Settings

let packageSettings = PackageSettings(
    targetSettings: [
        // Swift macros are host compiler plugins, not distributable app
        // executables. Xcode 27 rejects the plugin protocol when this helper
        // inherits the app's signing identity and entitlements.
        "PerceptionMacros": .settings(base: [
            "CODE_SIGNING_ALLOWED": "NO",
            "CODE_SIGNING_REQUIRED": "NO",
            "CODE_SIGN_IDENTITY": "",
        ]),
    ]
)
#endif

let package = Package(
    name: "dexo",
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.10.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/SDWebImage/SDWebImage.git", from: "5.19.0"),
        .package(url: "https://github.com/SDWebImage/SDWebImageSVGCoder.git", from: "1.7.0"),
        .package(url: "https://github.com/hyperoslo/Lightbox.git", from: "2.5.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        .package(url: "https://github.com/qyz777/DanmakuKit.git", from: "1.5.0"),
        .package(url: "https://github.com/pointfreeco/swift-perception.git", from: "2.0.10"),
       
    ]
)
