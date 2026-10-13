import CoreGraphics
import Foundation

/// The launch logo's outline, read from the bundled SVG so the splash can
/// trace and fill it natively.
nonisolated struct LaunchLogoPaths: Sendable {
    /// One traced piece of the logo, in drawing order.
    /// `CGPath` isn't marked Sendable, but these are immutable copies that
    /// are never mutated after parsing, so sharing them is safe.
    struct Piece: @unchecked Sendable {
        let path: CGPath
        /// Position in the trace sequence; later pieces start later.
        let order: Int
    }

    let pieces: [Piece]
    let size: CGSize

    static let bundled: LaunchLogoPaths? = {
        let url =
            Bundle.main.url(forResource: "logo-animated", withExtension: "svg", subdirectory: "Resources")
            ?? Bundle.main.url(forResource: "logo-animated", withExtension: "svg")
        guard let url, let svg = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return LaunchLogoPaths(svg: svg)
    }()

    init?(svg: String) {
        guard let viewBox = Self.firstMatch(Self.viewBoxPattern, in: svg) else { return nil }
        let box = viewBox.split(separator: " ").compactMap { Double($0) }
        guard box.count == 4 else { return nil }
        size = CGSize(width: box[2], height: box[3])

        // The paths sit inside one translated group.
        var offset = CGPoint.zero
        if let translate = Self.firstMatch(Self.translatePattern, in: svg) {
            let parts = translate.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
            if parts.count == 2 { offset = CGPoint(x: parts[0], y: parts[1]) }
        }
        var transform = CGAffineTransform(translationX: offset.x, y: offset.y)

        var pieces: [Piece] = []
        let elementPattern = try! NSRegularExpression(pattern: #"<(?:path|polygon)\b[^>]*>"#)
        for match in elementPattern.matches(in: svg, range: NSRange(svg.startIndex..., in: svg)) {
            guard let range = Range(match.range, in: svg) else { continue }
            let element = String(svg[range])
            let parsed: CGPath?
            if let data = Self.firstMatch(Self.pathDataPattern, in: element) {
                parsed = Self.parsePath(data)
            } else if let points = Self.firstMatch(Self.pointsPattern, in: element) {
                parsed = Self.parsePolygon(points)
            } else {
                parsed = nil
            }
            guard let path = parsed?.copy(using: &transform) else { continue }
            let order = Self.firstMatch(Self.orderPattern, in: element).flatMap { Int($0) } ?? pieces.count
            pieces.append(Piece(path: path, order: order))
        }
        guard !pieces.isEmpty else { return nil }
        self.pieces = pieces.sorted { $0.order < $1.order }
    }

    // Compiled once rather than once per SVG element.
    private static let viewBoxPattern = try! NSRegularExpression(pattern: #"viewBox="([^"]+)""#)
    private static let translatePattern = try! NSRegularExpression(pattern: #"translate\(([^)]+)\)"#)
    private static let pathDataPattern = try! NSRegularExpression(pattern: #"\bd="([^"]+)""#)
    private static let pointsPattern = try! NSRegularExpression(pattern: #"\bpoints="([^"]+)""#)
    private static let orderPattern = try! NSRegularExpression(pattern: #"--i:\s*(\d+)"#)

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    /// A closed polygon from an SVG `points` list.
    static func parsePolygon(_ points: String) -> CGPath? {
        let values = points.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" }).compactMap { Double($0) }
        guard values.count >= 6, values.count.isMultiple(of: 2) else { return nil }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: values[0], y: values[1]))
        for index in stride(from: 2, to: values.count, by: 2) {
            path.addLine(to: CGPoint(x: values[index], y: values[index + 1]))
        }
        path.closeSubpath()
        return path
    }

    /// Parses the SVG path commands the logo uses: move, line, horizontal,
    /// vertical, cubic curve, and close, absolute or relative, with the
    /// implicit repeats SVG allows.
    static func parsePath(_ data: String) -> CGPath? {
        let tokenPattern = try! NSRegularExpression(pattern: #"[MmLlHhVvCcZz]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?"#)
        let tokens = tokenPattern.matches(in: data, range: NSRange(data.startIndex..., in: data)).compactMap {
            Range($0.range, in: data).map { String(data[$0]) }
        }
        let path = CGMutablePath()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var command: Character?
        var index = 0

        func number() -> CGFloat? {
            guard index < tokens.count, let value = Double(tokens[index]) else { return nil }
            index += 1
            return CGFloat(value)
        }

        while index < tokens.count {
            if let first = tokens[index].first, first.isLetter {
                command = first
                index += 1
            }
            guard let command else { return nil }
            let relative = command.isLowercase
            switch command.uppercased() {
            case "M":
                guard let x = number(), let y = number() else { return nil }
                current = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                subpathStart = current
                path.move(to: current)
                // Further pairs after a move are implicit line-tos.
                while index < tokens.count, Double(tokens[index]) != nil {
                    guard let x = number(), let y = number() else { return nil }
                    current = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                    path.addLine(to: current)
                }
            case "L":
                guard let x = number(), let y = number() else { return nil }
                current = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addLine(to: current)
            case "H":
                guard let x = number() else { return nil }
                current.x = relative ? current.x + x : x
                path.addLine(to: current)
            case "V":
                guard let y = number() else { return nil }
                current.y = relative ? current.y + y : y
                path.addLine(to: current)
            case "C":
                guard let x1 = number(), let y1 = number(), let x2 = number(), let y2 = number(), let x = number(),
                    let y = number()
                else { return nil }
                let origin = relative ? current : .zero
                let control1 = CGPoint(x: origin.x + x1, y: origin.y + y1)
                let control2 = CGPoint(x: origin.x + x2, y: origin.y + y2)
                current = CGPoint(x: origin.x + x, y: origin.y + y)
                path.addCurve(to: current, control1: control1, control2: control2)
            case "Z":
                path.closeSubpath()
                current = subpathStart
            default:
                return nil
            }
        }
        return path.isEmpty ? nil : path
    }
}
