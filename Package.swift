// swift-tools-version:5.2

import PackageDescription

let package = Package(
    name: "PeerTalk",
    products: [
        .library(name: "PeerTalk", targets: ["PeerTalk"]),
    ],
    targets: [
        .target(
            name: "PeerTalk",
            path: "Sources",
            publicHeadersPath: ""
        )
    ]
)
