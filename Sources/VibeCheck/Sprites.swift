import AppKit

/// Procedurally-rendered 4-frame pixel-art run cycles for the runner animals.
/// Six body templates give distinct silhouettes; species add palette,
/// accessories and coat patterns. All sprites face left and share the same
/// ground row so runners align on a common baseline.
enum Sprites {
    static let pixelSize: CGFloat = 3.2
    fileprivate static let gridW = 22
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

    /// Rendered frames are cached on the main actor, which is the only place
    /// the overlay and the dev flags ever ask for them.
    @MainActor private static var cache: [String: [NSImage]] = [:]

    @MainActor static func frames(for emoji: String) -> [NSImage] {
        if let cached = cache[emoji] { return cached }
        let spec = species[emoji] ?? species["🐎"]!
        let images = (0..<4).map { render(spec, frame: $0) }
        cache[emoji] = images
        return images
    }

    /// Static marker shown in place of a runner once Claude has reported that
    /// the usage limit is reached — a small grave in the animals' pixel grid.
    @MainActor static let tombstone: NSImage = renderTombstone()

    // MARK: - Rendering

    /// Renders one gait frame. `pixelSize` is how many points one art pixel
    /// occupies: the overlay uses the default, the app icon asks for a large
    /// whole number so its edges stay sharp instead of being an upscale of
    /// the small, antialiased on-screen bitmap.
    @MainActor static func sprite(
        _ emoji: String, frame: Int, pixelSize: CGFloat
    ) -> NSImage {
        render(species[emoji] ?? species["\u{1F40E}"]!, frame: frame, pixelSize: pixelSize)
    }

    private static func render(
        _ spec: Species, frame: Int, pixelSize: CGFloat = Sprites.pixelSize
    ) -> NSImage {
        let image = NSImage(size: NSSize(
            width: CGFloat(gridW) * pixelSize, height: CGFloat(gridH) * pixelSize))
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

    private static func renderTombstone() -> NSImage {
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

        let stone = NSColor(calibratedWhite: 0.62, alpha: 1)
        let shade = NSColor(calibratedWhite: 0.42, alpha: 1)
        let outline = NSColor(calibratedWhite: 0.18, alpha: 1)
        let grass = NSColor(calibratedRed: 0.30, green: 0.48, blue: 0.28, alpha: 1)

        // Rounded-top slab centered on the shared ground row (13).
        row(4, 8...13, outline)
        row(5, 7...14, stone)
        for y in 6...11 { row(y, 6...15, stone) }
        row(12, 6...15, outline)
        fill(7, 6, shade); fill(14, 6, shade)
        for y in 7...11 { fill(6, y, shade); fill(15, y, shade) }
        // Etched cross.
        fill(10, 7, outline); fill(11, 7, outline)
        fill(10, 8, outline); fill(11, 8, outline)
        fill(10, 9, outline); fill(11, 9, outline)
        fill(8, 8, outline); fill(9, 8, outline)
        fill(12, 8, outline); fill(13, 8, outline)
        // Grass tuft at the base.
        row(13, 4...17, grass)

        image.unlockFocus()
        return image
    }

    // MARK: - Exported images

    /// Every animal's four gait frames as one contact sheet. The only capture
    /// of this app that contains no session information at all.
    @MainActor static func writeContactSheet(to url: URL) -> Bool {
        let scale: CGFloat = 2
        let columns = 4
        let rows = RunnerSettings.animals.count
        let pad: CGFloat = 8
        let sheet = NSImage(size: NSSize(
            width: (size.width * scale + pad) * CGFloat(columns) + pad,
            height: (size.height * scale + pad) * CGFloat(rows) + pad))
        sheet.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        for (row, animal) in RunnerSettings.animals.enumerated() {
            for (column, frame) in frames(for: animal).enumerated() {
                let origin = NSPoint(
                    x: pad + CGFloat(column) * (size.width * scale + pad),
                    y: sheet.size.height - (pad + size.height * scale
                        + CGFloat(row) * (size.height * scale + pad)))
                frame.draw(in: NSRect(origin: origin, size: NSSize(
                    width: size.width * scale, height: size.height * scale)))
            }
        }
        sheet.unlockFocus()
        return write(sheet, to: url)
    }

    /// The app icon: the horse on a rounded tile, rendered at every size
    /// macOS asks for. Generated at build time so no binary asset has to be
    /// checked in, and so the icon can never drift from the sprites.
    @MainActor static func writeIconSet(to directory: URL) -> Bool {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let variants: [(name: String, pixels: CGFloat)] = [
            ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
        ]
        for variant in variants {
            guard let rep = iconRep(pixels: Int(variant.pixels)),
                  let png = rep.representation(using: .png, properties: [:]),
                  (try? png.write(to: directory.appendingPathComponent(variant.name))) != nil
            else { return false }
        }
        return true
    }

    /// One icon variant at exact pixel dimensions.
    ///
    /// Drawing through `NSImage.lockFocus` would render at the display's
    /// backing scale, so on a Retina machine every icon came out at twice the
    /// size macOS asked for. Drawing into a bitmap of a stated pixel size
    /// makes the output identical on any display.
    @MainActor private static func iconRep(pixels: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)  // one point = one pixel

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .none

        let side = CGFloat(pixels)
        let inset = side * 0.06
        let plate = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.17, alpha: 1).setFill()
        NSBezierPath(roundedRect: plate,
                     xRadius: side * 0.22, yRadius: side * 0.22).fill()

        // Drawn at a whole number of points per art pixel, so the icon has
        // no seams and no half-pixels at any of the ten sizes macOS wants.
        let target = plate.width * 0.78
        let step = max(1, (target / CGFloat(gridW)).rounded(.down))
        let runner = sprite("🐎", frame: 0, pixelSize: step)
        runner.draw(in: NSRect(
            x: plate.midX - runner.size.width / 2,
            y: plate.midY - runner.size.height / 2,
            width: runner.size.width, height: runner.size.height))
        return rep
    }

    private static func write(_ image: NSImage, to url: URL) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return false }
        return (try? png.write(to: url)) != nil
    }
}
