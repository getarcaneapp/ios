import Foundation
import os
import Arcane

// Decodes a JSON array element-by-element, dropping (and logging) elements
// whose decode fails so a single malformed item can't take down a whole list.
// Re-encodes as a flat array so the disk cache layer can round-trip it.
nonisolated struct LenientArray<Element: Codable & Sendable>: Codable, Sendable {
    let elements: [Element]

    private static var logger: Logger {
        Logger(subsystem: "com.getarcaneapp.mobile", category: "decoding")
    }

    init(elements: [Element]) {
        self.elements = elements
    }

    nonisolated init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var collected: [Element] = []
        var processedCount = 0
        if let count = container.count {
            guard count <= RemoteDataLimits.maximumCollectionItems else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Array exceeds the supported item limit"
                )
            }
            collected.reserveCapacity(min(count, RemoteDataLimits.maximumCollectionItems))
        }
        while !container.isAtEnd {
            guard processedCount < RemoteDataLimits.maximumCollectionItems else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Array exceeds the supported item limit"
                )
            }
            processedCount += 1
            do {
                let item = try container.decode(Element.self)
                collected.append(item)
            } catch {
                _ = try? container.decode(JSONValue.self)
                Self.logger.warning(
                    "Skipping malformed \(String(describing: Element.self), privacy: .public) element at index \(processedCount - 1): \(String(describing: error), privacy: .public)"
                )
            }
        }
        self.elements = collected
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        for element in elements {
            try container.encode(element)
        }
    }
}
