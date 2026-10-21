import AppKit
import WebKit

// svg2png <input.svg> <output.png> [width] [height] — renders an SVG through WebKit (no external tools).
final class Shooter: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let output: URL
    init(output: URL) {
        self.output = output
        let config = WKWebViewConfiguration()
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // let fonts/layout settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.shoot() }
    }
    func shoot() {
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        webView.takeSnapshot(with: config) { image, error in
            guard let image else { FileHandle.standardError.write(Data("snapshot failed \(error?.localizedDescription ?? "")\n".utf8)); exit(1) }
            var rect = CGRect(origin: .zero, size: image.size)
            let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
            try? data.write(to: self.output)
            print("wrote \(self.output.path) \(cg.width)x\(cg.height)")
            exit(0)
        }
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { print("usage: svg2png in.svg out.png [w] [h]"); exit(2) }
let input = URL(fileURLWithPath: args[0])
let output = URL(fileURLWithPath: args[1])
let width = args.count > 2 ? Double(args[2])! : 512
let height = args.count > 3 ? Double(args[3])! : 512

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let shooter = Shooter(output: output)
shooter.webView.frame = NSRect(x: 0, y: 0, width: width, height: height)
shooter.webView.setValue(false, forKey: "drawsBackground")
let svg = (try? String(contentsOf: input, encoding: .utf8)) ?? ""
let svgBody = svg.replacingOccurrences(of: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>", with: "")
let html = "<html><head><style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}"
    + "img,svg{width:100vw;height:100vh;display:block}</style></head><body>"
    + svgBody + "</body></html>"
shooter.webView.loadHTMLString(html, baseURL: input.deletingLastPathComponent())
app.run()
