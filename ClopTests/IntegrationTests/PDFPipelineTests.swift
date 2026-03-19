@testable import Clop
import Foundation
import PDFKit
import System
import Testing

@Suite("runPDFPipeline()", .tags(.integration))
@MainActor
struct PDFPipelineTests {
    init() throws {
        try #require(binariesAvailable())
        tempDir = try copyFixturesToTempDir()
        setTestDefaults()
        resetGlobalState()
        _ = try setTestWorkdir()
    }

    let tempDir: URL

    @Test("Optimise PDF → valid output with same page count")
    func optimisePDF() async throws {
        let path = fixture("sample.pdf", in: tempDir)
        let originalDoc = try #require(PDFDocument(url: path.url))
        let originalPageCount = originalDoc.pageCount

        let pdf = makeTestPDF(path: path)
        let result = try await runPDFPipeline(pdf, actions: [.optimise], allowLarger: true, hideFloatingResult: true, aggressiveOptimisation: false)

        #expect(result != nil)
        #expect(isPDFValid(path: path))
        let resultDoc = PDFDocument(url: path.url)
        #expect(resultDoc?.pageCount == originalPageCount)
    }

    @Test("Aggressive optimisation → valid output")
    func aggressiveOptimisation() async throws {
        let path = fixture("sample.pdf", in: tempDir)

        let pdf = makeTestPDF(path: path)
        let result = try await runPDFPipeline(pdf, actions: [.optimise], allowLarger: true, hideFloatingResult: true, aggressiveOptimisation: true)

        #expect(result != nil)
        #expect(isPDFValid(path: path))
    }

    @Test("Encrypted PDF → returns nil or throws")
    func encryptedPDF() async throws {
        // Create a password-protected PDF
        let encPath = tempDir.appendingPathComponent("encrypted.pdf")
        let doc = PDFDocument()
        let page = PDFPage()
        doc.insert(page, at: 0)
        doc.write(to: encPath, withOptions: [.ownerPasswordOption: "secret123", .userPasswordOption: "secret123"])

        let path = FilePath(encPath.path)
        let pdf = makeTestPDF(path: path)

        // Pipeline may throw or return nil for encrypted PDFs
        do {
            let result = try await runPDFPipeline(pdf, actions: [.optimise], hideFloatingResult: true)
            #expect(result == nil, "Expected nil result for encrypted PDF")
        } catch {
            // Throwing is also acceptable
        }
    }

    @Test("Invalid PDF → returns nil or throws")
    func invalidPDF() async throws {
        // Create a non-PDF file with .pdf extension
        let invalidPath = tempDir.appendingPathComponent("invalid.pdf")
        try "This is not a PDF".write(to: invalidPath, atomically: true, encoding: .utf8)

        let path = FilePath(invalidPath.path)
        let pdf = makeTestPDF(path: path)

        // Pipeline may throw or return nil for invalid PDFs
        do {
            let result = try await runPDFPipeline(pdf, actions: [.optimise], hideFloatingResult: true)
            #expect(result == nil, "Expected nil result for invalid PDF")
        } catch {
            // Throwing is also acceptable
        }
    }
}
