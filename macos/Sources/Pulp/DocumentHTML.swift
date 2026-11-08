import AppKit
import Foundation

struct Figure: Identifiable, Equatable {
    let id: UUID
    let png: Data
    var marker: String { "[[figure:\(id.uuidString)]]" }
}

struct DraftPage: Identifiable {
    let id = UUID()
    var text = ""
    var figures: [Figure] = []
    var status = "Not recognized"
    var revision = 0
    var timings = PageTimings()
    var previousCorrection: (before: String, after: String)?
}

enum DocumentHTML {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // Close only the formatting marker. The recognized characters remain unchanged.
    // An unclosed marker can also indicate truncated output, so callers must flag it.
    static func repairMathDelimiters(_ text: String) -> (text: String, needsReview: Bool) {
        let chars = Array(text)
        var active: String?
        var openingIndex = 0
        var braceDepth = 0
        var needsReview = false
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if c == "\\", index + 1 < chars.count {
                let next = chars[index + 1]
                let pair = String([c, next])
                if active == nil && (pair == "\\(" || pair == "\\[") { active = pair; openingIndex = index; braceDepth = 0; index += 2; continue }
                if (active == "\\(" && pair == "\\)") || (active == "\\[" && pair == "\\]") { needsReview = needsReview || braceDepth != 0; active = nil; index += 2; continue }
                index += 2; continue
            }
            if c == "$" {
                let doubled = index + 1 < chars.count && chars[index + 1] == "$"
                let marker = doubled ? "$$" : "$"
                if active == nil { active = marker; openingIndex = index; braceDepth = 0 }
                else if active == marker { needsReview = needsReview || braceDepth != 0; active = nil }
                index += doubled ? 2 : 1; continue
            }
            if active != nil && c == "{" { braceDepth += 1 }
            if active != nil && c == "}" { braceDepth -= 1; if braceDepth < 0 { needsReview = true } }
            index += 1
        }
        guard let active else { return (text, needsReview) }
        let closing = active == "\\(" ? "\\)" : active == "\\[" ? "\\]" : active
        let end = (active == "$" || active == "\\(") ? (chars[openingIndex...].firstIndex(of: "\n") ?? chars.endIndex) : chars.endIndex
        return (String(chars[..<end]) + closing + String(chars[end...]), true)
    }

    static func validate(_ page: DraftPage) throws {
        let pattern = #"\[\[figure:([^\]]+)\]\]"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(page.text.startIndex..., in: page.text)
        let known = Set(page.figures.map { $0.id.uuidString })
        for match in regex.matches(in: page.text, range: range) {
            guard let range = Range(match.range(at: 1), in: page.text), known.contains(String(page.text[range])) else {
                throw ExportError.invalidFigure
            }
        }
    }

    static func make(pages: [DraftPage]) throws -> String {
        guard let root = Bundle.module.resourceURL?.appendingPathComponent("Resources") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let css = try String(contentsOf: root.appendingPathComponent("katex.min.css"), encoding: .utf8)
        let katex = try String(contentsOf: root.appendingPathComponent("katex.min.js"), encoding: .utf8)
        let auto = try String(contentsOf: root.appendingPathComponent("auto-render.min.js"), encoding: .utf8)
        for page in pages { try validate(page) }
        let body = pages.map { page in
            let repair = repairMathDelimiters(page.text)
            var source = escape(repair.text)
            for figure in page.figures {
                let img = "</pre><figure><img alt=\"Original diagram crop\" src=\"data:image/png;base64,\(figure.png.base64EncodedString())\"></figure><pre>"
                source = source.replacingOccurrences(of: figure.marker, with: img)
            }
            let warning = repair.needsReview ? "<p class=\"math-review\">Check the equation against the original. The recognized text may be incomplete.</p>" : ""
            return "<section><pre>\(source)</pre>\(warning)</section>"
        }.joined()
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>\(css)
        @page { size: letter; margin: 0.65in; } body { margin: 0; font: 13pt/1.5 -apple-system, sans-serif; color: #111; } section + section { break-before: page; } pre { white-space: pre-wrap; overflow-wrap: anywhere; font: inherit; margin: 0; } figure { margin: 14px 0; break-inside: avoid; } img { max-width: 100%; max-height: 5in; object-fit: contain; } .katex-error, .math-review { color: #b00020; } @media screen { body { padding: 20px; } section + section { border-top: 1px solid #ccc; margin-top: 24px; padding-top: 24px; } }
        </style><script>\(katex)</script><script>\(auto)</script></head><body>\(body)
        <script>window.renderErrors=[]; try { renderMathInElement(document.body, { delimiters:[{left:'$$',right:'$$',display:true},{left:'\\\\[',right:'\\\\]',display:true},{left:'\\\\(',right:'\\\\)',display:false},{left:'$',right:'$',display:false}], ignoredTags:[], throwOnError:true, errorCallback:function(_,e){window.renderErrors.push(String(e));} }); } catch(e) { window.renderErrors.push(String(e)); }
        for (const node of document.querySelectorAll('.katex-error')) { window.renderErrors.push('An equation could not be displayed.'); const note = document.createElement('p'); note.className = 'math-review'; note.textContent = 'Check this equation against the original. It could not be displayed.'; node.after(note); }
        if (window.renderErrors.length && !document.querySelector('.math-review')) { const note = document.createElement('p'); note.className = 'math-review'; note.textContent = 'Check the equations against the original. Some could not be displayed.'; document.body.appendChild(note); }
        window.safePageEnd = function(start, limit) {
          const height = document.documentElement.scrollHeight;
          if (height <= start + limit) return height;
          let boundary = start + limit;
          const rectangles = [];
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          while (walker.nextNode()) {
            const node = walker.currentNode;
            if (node.parentElement.closest('script, style, .katex-mathml, .katex')) continue;
            const text = node.nodeValue || '';
            const words = /\\S+/g; let match;
            while ((match = words.exec(text))) {
              const range = document.createRange(); range.setStart(node, match.index); range.setEnd(node, match.index + match[0].length);
              for (const rect of range.getClientRects()) if (rect.height) rectangles.push([rect.top + window.scrollY, rect.bottom + window.scrollY]);
            }
          }
          for (const element of document.querySelectorAll('figure, .katex')) {
            const rect = element.getBoundingClientRect(); if (rect.height) rectangles.push([rect.top + window.scrollY, rect.bottom + window.scrollY]);
          }
          let changed = true;
          while (changed) {
            changed = false;
            for (const [top, bottom] of rectangles) if (top < boundary && bottom > boundary) { boundary = top - 1; changed = true; }
          }
          return boundary > start + 30 ? Math.floor(boundary) : -1;
        };
        </script></body></html>
        """
    }
}
