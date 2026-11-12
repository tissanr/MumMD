import Foundation
import JavaScriptCore
import QuickLookUI
import UniformTypeIdentifiers

// Quick-Look-Vorschau für Markdown (Leertaste im Finder).
// Quick Look führt in HTML-Vorschauen kein JavaScript aus, deshalb rendert die Erweiterung
// das Markdown selbst – mit denselben marked.js/highlight.js-Dateien wie die App, aber in
// JavaScriptCore – und liefert fertiges, statisches HTML samt style.css aus.
@objc(PreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let data = try Data(contentsOf: request.fileURL)
        let markdown = String(decoding: data, as: UTF8.self)
        let html = try Renderer.shared.page(markdown: markdown, title: request.fileURL.lastPathComponent)
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 900, height: 1000)) { reply in
            reply.stringEncoding = .utf8
            reply.title = request.fileURL.lastPathComponent
            return Data(html.utf8)
        }
    }
}

enum RenderError: Error { case missingResource(String), javascript(String) }

final class Renderer {
    static let shared = Renderer()
    private let lock = NSLock()
    private var context: JSContext?
    private lazy var css: String = Self.resource("style", "css") ?? ""

    private static func resource(_ name: String, _ ext: String) -> String? {
        guard let url = Bundle(for: Renderer.self).url(forResource: name, withExtension: ext) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func makeContext() throws -> JSContext {
        let ctx = JSContext()!
        for name in ["marked.min", "highlight.min"] {
            guard let js = Self.resource(name, "js") else { throw RenderError.missingResource(name) }
            ctx.evaluateScript(js)
        }
        ctx.evaluateScript("""
        marked.use({ gfm: true, breaks: false, renderer: {
          // Wie in der App: nur Blöcke mit bekannter Sprachangabe färben.
          code(token) {
            const lang = (token.lang || '').match(/^\\S*/)[0];
            if (!lang || typeof hljs === 'undefined' || !hljs.getLanguage(lang)) return false;
            try {
              const html = hljs.highlight(token.text, { language: lang, ignoreIllegals: true }).value;
              return '<pre><code class="hljs language-' + lang + '">' + html + '</code></pre>\\n';
            } catch (_) { return false; }
          }
        }});
        function mdviewRender(md) {
          md = md.replace(/^\\uFEFF?---\\r?\\n[\\s\\S]*?\\r?\\n(---|\\.\\.\\.)\\r?\\n/, '');
          return marked.parse(md);
        }
        """)
        if let e = ctx.exception { throw RenderError.javascript(e.toString()) }
        return ctx
    }

    func page(markdown: String, title: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        if context == nil { context = try makeContext() }
        let ctx = context!
        ctx.exception = nil
        let body = ctx.objectForKeyedSubscript("mdviewRender").call(withArguments: [markdown])?.toString() ?? ""
        if let e = ctx.exception { throw RenderError.javascript(e.toString()) }
        let escapedTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
        <meta name="color-scheme" content="light dark">
        <title>\(escapedTitle)</title>
        <style>\(css)</style>
        </head>
        <body>
        <article class="markdown-body">\(body)</article>
        </body>
        </html>
        """
    }
}
