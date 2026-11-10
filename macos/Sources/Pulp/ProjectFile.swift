import Foundation
import PDFKit

struct ProjectFile: Codable {
    struct Page: Codable {
        var text: String
        var figures: [Figure]
        var status: String
    }
    var version = 1
    var pdf: Data
    var pages: [Page]
    var selectedPage: Int

    func validatedDocument() throws -> PDFDocument {
        guard version == 1, let document = PDFDocument(data: pdf), !document.isLocked,
              document.pageCount > 0, document.pageCount == pages.count,
              pages.indices.contains(selectedPage) else { throw CocoaError(.fileReadCorruptFile) }
        return document
    }

    func write(to url: URL) throws {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> ProjectFile {
        let project = try PropertyListDecoder().decode(Self.self, from: Data(contentsOf: url))
        _ = try project.validatedDocument()
        return project
    }
}
