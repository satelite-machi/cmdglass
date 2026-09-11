// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Meuwidget",
    platforms: [.macOS(.v14)],
    products: [
        // A droplet is a loadable bundle, so its product is a dynamic library.
        // Do not make it static: the app already carries DroppyKit, and a
        // second copy inside the droplet gives the same type two metadata
        // records, which fails every cast between them.
        .library(name: "Meuwidget", type: .dynamic, targets: ["Meuwidget"])
    ],
    dependencies: [
        .package(url: "https://gitlab.com/droppyformac1/droppykit.git", from: "1.4.1")
    ],
    targets: [
        .target(
            name: "Meuwidget",
            dependencies: [.product(name: "DroppyKit", package: "droppykit")]
        ),
        .executableTarget(
            name: "MeuwidgetHarness",
            dependencies: [
                "Meuwidget",
                .product(name: "DroppyKitHarness", package: "droppykit")
            ]
        )
    ]
)
