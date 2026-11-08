import AppKit
import PDFKit
import WebKit

@MainActor
final class PDFExporter: NSObject, WKNavigationDelegate {
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private var webView: WKWebView?

    func export(pages: [DraftPage], to url: URL) async throws {
        let (data, _) = try await render(pages: pages)
        try data.write(to: url, options: .atomic)
        guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else { throw ExportError.failed }
    }

    func render(pages: [DraftPage]) async throws -> (Data, [Int]) {
        let result = PDFDocument()
        var pagesToReview: [Int] = []
        for (index, draft) in pages.enumerated() {
            do {
            try Task.checkCancellation()
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 816, height: 1056))
            webView = view
            view.navigationDelegate = self
            let html = try DocumentHTML.make(pages: [draft])
            try await withCheckedThrowingContinuation { continuation in
                navigationContinuation = continuation
                view.loadHTMLString(html, baseURL: Bundle.module.resourceURL?.appendingPathComponent("Resources"))
            }
            _ = try await view.callAsyncJavaScript("await document.fonts.ready; await Promise.all(Array.from(document.images).map(i => i.decode().catch(() => {}))); return true;", arguments: [:], in: nil, contentWorld: .page)
            let errors = try await view.evaluateJavaScript("window.renderErrors.join('\\n')") as? String ?? ""
            if !errors.isEmpty || DocumentHTML.repairMathDelimiters(draft.text).needsReview { pagesToReview.append(index) }
            let heightValue = try await view.evaluateJavaScript("Math.ceil(document.documentElement.scrollHeight)") as? NSNumber
            let height = max(1, heightValue?.doubleValue ?? 0)
            var offset = 0.0
            while offset < height {
                let end = (try await view.evaluateJavaScript("window.safePageEnd(\(offset), 1056)") as? NSNumber)?.doubleValue ?? -1
                guard end > offset else { throw ExportError.failed }
                let config = WKPDFConfiguration()
                config.rect = CGRect(x: 0, y: offset, width: 816, height: end - offset)
                let data = try await view.pdf(configuration: config)
                guard let source = PDFDocument(data: data), let page = source.page(at: 0) else { throw ExportError.failed }
                result.insert(page, at: result.pageCount)
                offset = end
            }
            webView = nil
            } catch {
                throw PageExportError(index: index, underlying: error)
            }
        }
        guard let data = result.dataRepresentation() else { throw ExportError.failed }
        guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else { throw ExportError.failed }
        return (data, pagesToReview)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error); navigationContinuation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error); navigationContinuation = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationContinuation?.resume(); navigationContinuation = nil
    }
}

struct PageExportError: LocalizedError {
    let index: Int
    let underlying: Error
    var errorDescription: String? { "Page \(index + 1): \(underlying.localizedDescription)" }
}

enum ExportError: LocalizedError {
    case invalidMath(String), invalidFigure, failed
    var errorDescription: String? {
        switch self {
        case .invalidMath(let detail): "The equation could not be rendered: \(detail)"
        case .invalidFigure: "A figure marker does not match a selected crop."
        case .failed: "The PDF could not be created or reopened."
        }
    }
}
