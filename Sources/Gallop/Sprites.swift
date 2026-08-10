import AppKit

/// Procedurally-rendered 4-frame pixel-art run cycles for the runner animals.
/// One shared quadruped body, facing left; species differ by palette, small
/// accessories, and coat patterns.
enum Sprites {
    static let pixelSize: CGFloat = 3.2
    private static let gridW = 22
    private static let gridH = 14

    static var size: NSSize {
        NSSize(width: CGFloat(gridW) * pixelSize, height: CGFloat(gridH) * pixelSize)
    }

    /// Frame shown while halted at a wall (legs vertical).
    static let standingFrame = 1

    private enum Accessory {
        case mane, horn, hump, shell, longEars, antlers, catEars,
             floppyEar, thickTail, bushyTail, spikes, none
    }

    private struct Species {
        let body: NSColor
        let accent: NSColor
        let spots: Bool
        let accessory: Accessory

        init(body: (CGFloat, CGFloat, CGFloat), accent: (CGFloat, CGFloat, CGFloat),
             spots: Bool = false, accessory: Accessory = .none) {
            self.body = NSColor(calibratedRed: body.0, green: body.1, blue: body.2, alpha: 1)
            self.accent = NSColor(calibratedRed: accent.0, green: accent.1, blue: accent.2, alpha: 1)
            self.spots = spots
            self.accessory = accessory
        }
    }

    private static let species: [String: Species] = [
        "🐎": Species(body: (0.63, 0.42, 0.27), accent: (0.33, 0.20, 0.12), accessory: .mane),
        "🦄": Species(body: (0.96, 0.94, 0.96), accent: (0.95, 0.55, 0.78), accessory: .horn),
        "🐫": Species(body: (0.80, 0.62, 0.36), accent: (0.60, 0.44, 0.22), accessory: .hump),
        "🐕": Species(body: (0.76, 0.55, 0.32), accent: (0.45, 0.30, 0.15), accessory: .floppyEar),
        "🐈": Species(body: (0.55, 0.55, 0.58), accent: (0.35, 0.35, 0.38), accessory: .catEars),
        "🐇": Species(body: (0.93, 0.91, 0.89), accent: (0.95, 0.70, 0.75), accessory: .longEars),
        "🐢": Species(body: (0.48, 0.66, 0.36), accent: (0.26, 0.44, 0.24), accessory: .shell),
        "🦖": Species(body: (0.38, 0.68, 0.44), accent: (0.20, 0.45, 0.28), accessory: .spikes),
        "🐖": Species(body: (0.94, 0.66, 0.70), accent: (0.80, 0.48, 0.54)),
        "🐄": Species(body: (0.94, 0.93, 0.90), accent: (0.20, 0.18, 0.18), spots: true),
        "🦌": Species(body: (0.62, 0.44, 0.26), accent: (0.38, 0.26, 0.14), accessory: .antlers),
        "🦘": Species(body: (0.72, 0.51, 0.33), accent: (0.52, 0.36, 0.22), accessory: .thickTail),
        "🐆": Species(body: (0.89, 0.72, 0.36), accent: (0.30, 0.24, 0.12), spots: true),
        "🐿️": Species(body: (0.62, 0.40, 0.22), accent: (0.78, 0.55, 0.32), accessory: .bushyTail),
    ]

    private static var cache: [String: [NSImage]] = [:]

    static func frames(for emoji: String) -> [NSImage] {
        if let cached = cache[emoji] { return cached }
        let spec = species[emoji] ?? species["🐎"]!
        let images = (0..<4).map { render(spec, frame: $0) }
        cache[emoji] = images
        return images
    }

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

        let dark = NSColor(calibratedWhite: 0.12, alpha: 1)

        // Head (left) and torso, on rows 1–8 of the grid (y grows downward).
        for y in 1...4 { for x in 1...4 { fill(x, y, spec.body) } }
        for x in 4...17 { fill(x, 5, spec.body) }
        for x in 4...18 { fill(x, 6, spec.body) }
        for x in 5...17 { fill(x, 7, spec.body) }
        for x in 5...16 { fill(x, 8, spec.body) }
        fill(2, 2, dark)  // eye

        let hasTailAccessory = spec.accessory == .thickTail || spec.accessory == .bushyTail
        if !hasTailAccessory {
            fill(18, 5, spec.accent)
            fill(19, 6, spec.accent)
        }

        switch spec.accessory {
        case .mane:
            for x in [1, 2] { fill(x, 0, spec.accent) }
            for x in 5...8 { fill(x, 4, spec.accent) }
        case .horn:
            fill(1, 0, spec.accent)
            fill(2, 0, spec.accent)
            for x in 5...7 { fill(x, 4, spec.accent) }
        case .hump:
            fill(10, 3, spec.body)
            for x in 9...12 { fill(x, 4, spec.body) }
        case .shell:
            for x in 8...13 { fill(x, 3, spec.accent) }
            for x in 6...15 { fill(x, 4, spec.accent) }
            for x in 6...15 { fill(x, 5, spec.accent) }
        case .longEars:
            fill(1, 0, spec.body)
            fill(3, 0, spec.body)
            fill(1, 1, spec.accent)
        case .antlers:
            for x in [0, 2, 4] { fill(x, 0, spec.accent) }
            fill(1, 1, spec.accent)
            fill(3, 1, spec.accent)
        case .catEars:
            fill(1, 0, spec.body)
            fill(4, 0, spec.body)
        case .floppyEar:
            fill(4, 1, spec.accent)
            fill(4, 2, spec.accent)
        case .thickTail:
            fill(17, 6, spec.accent)
            fill(18, 7, spec.accent)
            fill(19, 7, spec.accent)
            fill(20, 8, spec.accent)
            fill(21, 8, spec.accent)
        case .bushyTail:
            for x in 18...20 { fill(x, 3, spec.accent) }
            for x in 18...21 { fill(x, 4, spec.accent) }
            for x in 19...21 { fill(x, 5, spec.accent) }
            fill(20, 6, spec.accent)
        case .spikes:
            for x in [6, 9, 12, 15] { fill(x, 4, spec.accent) }
        case .none:
            break
        }

        if spec.spots {
            for (x, y) in [(8, 6), (11, 5), (13, 7), (15, 6), (9, 8)] {
                fill(x, y, spec.accent)
            }
        }

        // Legs: front pair anchored at x 5 and 8, hind pair at x 13 and 16,
        // rows 9–13. Each frame slants the pairs differently to form a gait:
        // reach → pass → gather → pass.
        let slants: [[Int]] = [
            [-1, 0, 1, 0],
            [0, -1, 0, 1],
            [1, 0, -1, 0],
            [0, 1, 0, -1],
        ]
        for (leg, anchor) in [5, 8, 13, 16].enumerated() {
            let slant = slants[frame % slants.count][leg]
            for row in 0...4 {
                let shift = slant * ((row + 1) / 2)
                let color = row == 4 ? dark : spec.body
                fill(anchor + shift, 9 + row, color)
                fill(anchor + shift + 1, 9 + row, color)
            }
        }

        image.unlockFocus()
        return image
    }
}
