// swift-tools-version:5.2
import PackageDescription

let package = Package(
    name: "Peertalk",
    products: [
        .library(name: "Peertalk", targets: ["Peertalk"]),
    ],
    targets: [
        .target(
            name: "Peertalk",
            path: "peertalk",
            exclude: [
                "Info.plist",
                "Peertalk.h",
                "prefix.pch",
                "PTPrivate.h"
            ],
            publicHeadersPath: "includes"
        ),
        .testTarget(
            name: "PeertalkTests",
            dependencies: ["Peertalk"],
            path: "peertalk-tests",
            exclude: [
                "en.lproj",
                "peertalkTests-Info.plist"
            ]
        )
    ]
)
