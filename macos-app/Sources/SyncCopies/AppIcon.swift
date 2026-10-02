import AppKit

@MainActor
enum AppIcon {
    /// Approved one-way copy motif. Template graphics inherit the menu bar contrast.
    static func image(size: CGFloat = 18, template: Bool = true) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { bounds in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let transform = NSAffineTransform()
            transform.scale(by: bounds.width / 128)
            transform.concat()
            if !template {
                NSColor(red: 35 / 255, green: 58 / 255, blue: 89 / 255, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 3, y: 3, width: 122, height: 122), xRadius: 27, yRadius: 27).fill()
            }
            let source = template ? NSColor.black : NSColor(red: 150 / 255, green: 183 / 255, blue: 227 / 255, alpha: 1)
            let target = template ? NSColor.black : NSColor(red: 236 / 255, green: 245 / 255, blue: 1, alpha: 1)
            source.setFill()
            NSBezierPath(roundedRect: NSRect(x: 20, y: 30, width: 36, height: 53), xRadius: 7, yRadius: 7).fill()
            target.setFill()
            NSBezierPath(roundedRect: NSRect(x: 72, y: 45, width: 36, height: 53), xRadius: 7, yRadius: 7).fill()
            source.setStroke()
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 43, y: 96))
            arrow.line(to: NSPoint(x: 82, y: 96))
            arrow.move(to: NSPoint(x: 73, y: 87))
            arrow.line(to: NSPoint(x: 82, y: 96))
            arrow.line(to: NSPoint(x: 73, y: 105))
            arrow.lineWidth = 7
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.stroke()
            return true
        }
        image.isTemplate = template
        return image
    }
}
