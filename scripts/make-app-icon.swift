// Draws the app icon, so the repository carries no third-party artwork.
// Usage: swift scripts/make-app-icon.swift <output.png>
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let inset = 100.0
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let tile = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.56, alpha: 1),
               ending: NSColor(calibratedRed: 0.05, green: 0.47, blue: 0.62, alpha: 1))!.draw(in: tile, angle: -70)
    let config = NSImage.SymbolConfiguration(pointSize: 460, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "phone.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size, flipped: false) { bounds in
            symbol.draw(in: bounds)
            NSColor.white.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: (size - symbol.size.width) / 2, y: (size - symbol.size.height) / 2,
                               width: symbol.size.width, height: symbol.size.height))
    }
    return true
}
let tiff = image.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
