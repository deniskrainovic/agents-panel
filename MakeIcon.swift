import AppKit

@main enum MakeIcon {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let bitmap = ClankerIcon.appBitmap(pixels: size * scale)
                let suffix = scale == 2 ? "@2x" : ""
                try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            }
        }
    }
}
