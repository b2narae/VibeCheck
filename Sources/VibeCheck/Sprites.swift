import AppKit

/// Procedurally-rendered 4-frame pixel-art run cycles for the runner animals.
/// Six body templates give distinct silhouettes; species add palette,
/// accessories and coat patterns. All sprites face left and share the same
/// ground row so runners align on a common baseline.
enum Sprites {
    static let pixelSize: CGFloat = 3.2
    private static let gridW = 22
    private static let gridH = 14

    static var size: NSSize {
        NSSize(width: CGFloat(gridW) * pixelSize, height: CGFloat(gridH) * pixelSize)
    }

    /// Frame shown while halted at a wall (legs vertical).
    static let standingFrame = 1

    private enum Template {
        case standard  // horse-like proportions
        case tall      // long legs, high shoulders (camel, deer)
        case low       // long low body, stubby legs (turtle, dachshund)
        case round     // plump body, short legs (pig, cow)
        case small     // compact body, small head (cat, rabbit, squirrel)
        case upright   // bipedal with a heavy tail (kangaroo, t-rex)
    }

    private enum Accessory {
        case mane, horn, humps, shell, longEars, antlers, catEars,
             floppyEar, curlyTail, thickTail, bushyTail, spikes, none
    }

    private struct Species {
        let template: Template
        let body: NSColor
        let accent: NSColor
        let spots: Bool
        let accessory: Accessory

        init(_ template: Template,
             body: (CGFloat, CGFloat, CGFloat), accent: (CGFloat, CGFloat, CGFloat),
             spots: Bool = false, accessory: Accessory = .none) {
            self.template = template
            self.body = NSColor(calibratedRed: body.0, green: body.1, blue: body.2, alpha: 1)
            self.accent = NSColor(calibratedRed: accent.0, green: accent.1, blue: accent.2, alpha: 1)
            self.spots = spots
            self.accessory = accessory
        }
    }

    private static let species: [String: Species] = [
        "🐎": Species(.standard, body: (0.63, 0.42, 0.27), accent: (0.33, 0.20, 0.12), accessory: .mane),
        "🦄": Species(.standard, body: (0.96, 0.94, 0.96), accent: (0.95, 0.55, 0.78), accessory: .horn),
        "🐆": Species(.standard, body: (0.89, 0.72, 0.36), accent: (0.30, 0.24, 0.12), spots: true),
        "🐫": Species(.tall, body: (0.80, 0.62, 0.36), accent: (0.60, 0.44, 0.22), accessory: .humps),
        "🦌": Species(.tall, body: (0.62, 0.44, 0.26), accent: (0.38, 0.26, 0.14), accessory: .antlers),
        "🐢": Species(.low, body: (0.48, 0.66, 0.36), accent: (0.26, 0.44, 0.24), accessory: .shell),
        "🐕": Species(.low, body: (0.76, 0.55, 0.32), accent: (0.45, 0.30, 0.15), accessory: .floppyEar),
        "🐖": Species(.round, body: (0.94, 0.66, 0.70), accent: (0.80, 0.48, 0.54), accessory: .curlyTail),
        "🐄": Species(.round, body: (0.94, 0.93, 0.90), accent: (0.20, 0.18, 0.18), spots: true),
        "🐈": Species(.small, body: (0.55, 0.55, 0.58), accent: (0.35, 0.35, 0.38), accessory: .catEars),
        "🐇": Species(.small, body: (0.93, 0.91, 0.89), accent: (0.95, 0.70, 0.75), accessory: .longEars),
        "🐿️": Species(.small, body: (0.62, 0.40, 0.22), accent: (0.78, 0.55, 0.32), accessory: .bushyTail),
        "🦘": Species(.upright, body: (0.72, 0.51, 0.33), accent: (0.52, 0.36, 0.22), accessory: .thickTail),
        "🦖": Species(.upright, body: (0.38, 0.68, 0.44), accent: (0.20, 0.45, 0.28), accessory: .spikes),
    ]

    private static var cache: [String: [NSImage]] = [:]

    static func frames(for emoji: String) -> [NSImage] {
        if let cached = cache[emoji] { return cached }
        let spec = species[emoji] ?? species["🐎"]!
        let images = (0..<4).map { render(spec, frame: $0) }
        cache[emoji] = images
        return images
    }

    // MARK: - Rendering

    private static func render(_ spec: Species, frame: Int) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none

        func fill(_ x: Int, _ y: Int, _ color: NSColor) {
            guard (0..<gridW).contains(x), (0..<gridH).contains(y) else { return }
            color.setFill()
            NSRect(x: CGFloat(x) * pixelSize,
                   y: CGFloat(gridH - 1 - y) * pixelSize,
                   width: pixelSize, height: pixelSize).fill()
        }
        func row(_ y: Int, _ xs: ClosedRange<Int>, _ color: NSColor) {
            for x in xs { fill(x, y, color) }
        }

        let dark = NSColor(calibratedWhite: 0.12, alpha: 1)
        let body = spec.body
        let accent = spec.accent

        // Body + head per template. Legs always end on row 13 (the ground).
        let legAnchors: [Int]
        let legTop: Int

        switch spec.template {
        case .standard:
            for y in 1...4 { row(y, 1...4, body) }
            row(5, 4...17, body)
            row(6, 4...18, body)
            row(7, 5...17, body)
            row(8, 5...16, body)
            fill(2, 2, dark)
            legAnchors = [5, 8, 13, 16]
            legTop = 9
            if spec.accessory != .bushyTail && spec.accessory != .thickTail {
                fill(18, 5, accent); fill(19, 6, accent)
            }
        case .tall:
            for y in 1...3 { row(y, 1...4, body) }
            fill(4, 3, body); fill(4, 4, body)
            row(4, 4...16, body)
            row(5, 4...17, body)
            row(6, 5...16, body)
            row(7, 5...16, body)
            fill(2, 2, dark)
            legAnchors = [5, 8, 12, 15]
            legTop = 8
            fill(17, 4, accent); fill(18, 5, accent)
        case .low:
            for y in 5...7 { row(y, 1...3, body) }
            row(7, 3...17, body)
            row(8, 3...18, body)
            row(9, 4...17, body)
            row(10, 4...16, body)
            fill(2, 6, dark)
            legAnchors = [5, 8, 13, 16]
            legTop = 11
        case .round:
            for y in 2...5 { row(y, 1...4, body) }
            row(4, 6...15, body)
            row(5, 4...17, body)
            row(6, 4...18, body)
            row(7, 4...18, body)
            row(8, 4...17, body)
            row(9, 5...16, body)
            fill(2, 3, dark)
            legAnchors = [5, 8, 13, 16]
            legTop = 10
        case .small:
            for y in 3...6 { row(y, 2...5, body) }
            row(7, 5...15, body)
            row(8, 5...16, body)
            row(9, 6...15, body)
            fill(3, 4, dark)
            legAnchors = [6, 9, 12, 14]
            legTop = 10
        case .upright:
            for y in 1...3 { row(y, 1...5, body) }
            row(4, 3...8, body)
            row(5, 4...12, body)
            row(6, 5...14, body)
            row(7, 5...15, body)
            row(8, 7...15, body)
            fill(2, 2, dark)
            fill(6, 6, body)   // tiny arm
            fill(6, 7, body)
            legAnchors = [9, 13]
            legTop = 9
            if spec.accessory != .thickTail {   // dino tail in body color
                fill(16, 6, body); fill(17, 7, body)
                fill(18, 7, body); fill(19, 8, body); fill(20, 8, body)
            }
        }

        // Accessories are positioned for their species' template.
        switch spec.accessory {
        case .mane:
            fill(1, 0, accent); fill(2, 0, accent)
            row(4, 5...8, accent)
        case .horn:
            fill(1, 0, accent); fill(2, 0, accent)
            row(4, 5...7, accent)
        case .humps:
            fill(8, 2, body); row(3, 8...9, body)
            fill(13, 2, body); row(3, 12...13, body)
        case .antlers:
            fill(0, 0, accent); fill(2, 0, accent); fill(4, 0, accent)
        case .shell:
            row(4, 8...13, accent)
            row(5, 6...15, accent)
            row(6, 5...16, accent)
        case .floppyEar:
            fill(3, 4, accent); fill(3, 5, accent)
            fill(18, 6, accent); fill(19, 5, accent)   // upright happy tail
        case .curlyTail:
            fill(18, 5, accent); fill(19, 4, accent)
        case .catEars:
            fill(2, 2, body); fill(5, 2, body)
            fill(16, 7, accent); fill(17, 6, accent)   // slender tail
            fill(18, 5, accent); fill(19, 4, accent)
        case .longEars:
            fill(3, 1, body); fill(3, 2, body)
            fill(5, 1, body); fill(5, 2, body)
            fill(3, 2, accent)
        case .bushyTail:
            row(3, 17...19, accent)
            row(4, 16...20, accent)
            row(5, 16...20, accent)
            row(6, 17...20, accent)
            row(7, 17...19, accent)
        case .thickTail:
            fill(16, 6, accent); fill(17, 6, accent)
            fill(18, 7, accent); fill(19, 7, accent)
            fill(20, 8, accent); fill(21, 8, accent)
        case .spikes:
            fill(3, 3, accent); fill(6, 4, accent)
            fill(9, 4, accent); fill(12, 5, accent)
        case .none:
            break
        }

        if spec.spots {
            let positions = spec.template == .round
                ? [(7, 6), (11, 5), (14, 7), (9, 8), (13, 8)]
                : [(8, 6), (11, 5), (13, 7), (15, 6), (9, 8)]
            for (x, y) in positions { fill(x, y, accent) }
        }

        // Legs: pairs slant differently per frame to form a gait
        // (reach → pass → gather → pass). Bipeds stride with both legs.
        let slants: [[Int]] = legAnchors.count == 2
            ? [[-1, 1], [0, 0], [1, -1], [0, 0]]
            : [[-1, 0, 1, 0], [0, -1, 0, 1], [1, 0, -1, 0], [0, 1, 0, -1]]
        for (leg, anchor) in legAnchors.enumerated() {
            let slant = slants[frame % slants.count][leg]
            for legRow in 0...(13 - legTop) {
                let shift = slant * ((legRow + 1) / 2)
                let color = legTop + legRow == 13 ? dark : body
                fill(anchor + shift, legTop + legRow, color)
                fill(anchor + shift + 1, legTop + legRow, color)
            }
        }

        image.unlockFocus()
        return image
    }
}
