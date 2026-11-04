// Dessine l'icône de Temps à toutes les tailles d'un .iconset, dans l'esprit des cadrans
// de Max Bill : fond clair, graduations fines, aiguilles minces, une trotteuse orange.
import AppKit

let sortie = CommandLine.arguments[1]
let tailles: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]

func dessiner(_ n: Int) -> Data {
    let s = CGFloat(n)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Gabarit macOS : 824/1024 de côté, coins arrondis à 185/1024.
    let marge = s * 100 / 1024, cote = s * 824 / 1024
    let carre = CGRect(x: marge, y: marge, width: cote, height: cote)
    let forme = CGPath(roundedRect: carre, cornerWidth: s * 185 / 1024, cornerHeight: s * 185 / 1024, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 24 / 1024,
                  color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(forme)
    ctx.setFillColor(NSColor(srgbRed: 0.953, green: 0.945, blue: 0.925, alpha: 1).cgColor)  // #f3f1ec
    ctx.fillPath()
    ctx.restoreGState()

    let centre = CGPoint(x: s / 2, y: s / 2)
    let encre = NSColor(srgbRed: 0.114, green: 0.110, blue: 0.102, alpha: 1).cgColor       // #1d1c1a
    let orange = NSColor(srgbRed: 0.824, green: 0.314, blue: 0.176, alpha: 1).cgColor      // #d2502d
    let r = s * 330 / 1024
    ctx.setLineCap(.butt)
    // 60 graduations ; les heures plus longues et plus grasses. Aux petites tailles, les heures seules.
    for i in 0..<60 {
        let heure = i % 5 == 0
        if !heure && n < 64 { continue }
        let a = CGFloat(i) / 60 * .pi * 2
        let long = s * (heure ? 64 : 26) / 1024
        ctx.setStrokeColor(encre)
        ctx.setLineWidth(s * (heure ? 14 : 5) / 1024)
        ctx.move(to: CGPoint(x: centre.x + sin(a) * r, y: centre.y + cos(a) * r))
        ctx.addLine(to: CGPoint(x: centre.x + sin(a) * (r - long), y: centre.y + cos(a) * (r - long)))
        ctx.strokePath()
    }
    func aiguille(_ angle: CGFloat, _ longueur: CGFloat, _ epaisseur: CGFloat, _ couleur: CGColor, queue: CGFloat = 0) {
        ctx.setStrokeColor(couleur)
        ctx.setLineWidth(epaisseur)
        ctx.move(to: CGPoint(x: centre.x - sin(angle) * queue, y: centre.y - cos(angle) * queue))
        ctx.addLine(to: CGPoint(x: centre.x + sin(angle) * longueur, y: centre.y + cos(angle) * longueur))
        ctx.strokePath()
    }
    // 10 h 08 : l'heure des vitrines d'horloger
    aiguille((10 + 8 / 60) / 12 * .pi * 2, s * 190 / 1024, s * 26 / 1024, encre, queue: s * 40 / 1024)
    aiguille(8 / 60 * .pi * 2, s * 290 / 1024, s * 18 / 1024, encre, queue: s * 40 / 1024)
    aiguille(38 / 60 * .pi * 2, s * 300 / 1024, s * Swift.max(7, 7 * 1024 / s) / 1024, orange, queue: s * 70 / 1024)
    let p = s * 22 / 1024
    ctx.setFillColor(orange)
    ctx.fillEllipse(in: CGRect(x: centre.x - p, y: centre.y - p, width: 2 * p, height: 2 * p))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(atPath: sortie, withIntermediateDirectories: true)
for (nom, n) in tailles {
    try dessiner(n).write(to: URL(fileURLWithPath: "\(sortie)/icon_\(nom).png"))
}
