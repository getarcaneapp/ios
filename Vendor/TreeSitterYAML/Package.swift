// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TreeSitterYAML",
    products: [.library(name: "TreeSitterYAML", targets: ["TreeSitterYAML"])],
    targets: [.target(name: "TreeSitterYAML", path: ".",
                      sources: ["src/parser.c", "src/scanner.c"],
                      publicHeadersPath: "include",
                      cSettings: [.headerSearchPath("src")])]
)
