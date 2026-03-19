@testable import Clop
import Foundation
import System
import Testing

@Suite("generateFileName / generateFilePath")
struct FileNameTemplateTests {
    // MARK: - generateFileName

    @Test("%f → filename stem")
    func filenameToken() {
        var num = 0
        let result = generateFileName(template: "%f", for: FilePath("/tmp/photo.jpg"), autoIncrementingNumber: &num, safe: false)
        #expect(result == "photo.jpg")
    }

    @Test("%e → extension")
    func extensionToken() {
        var num = 0
        let result = generateFileName(template: "output.%e", for: FilePath("/tmp/photo.jpg"), autoIncrementingNumber: &num, safe: false)
        #expect(result == "output.jpg.jpg")
        // Note: %e gets extension, and then if path has extension it's appended again
    }

    @Test("%i → auto-incrementing number")
    func autoIncrementToken() {
        var num = 5
        let result = generateFileName(template: "img_%i", for: FilePath("/tmp/photo.jpg"), autoIncrementingNumber: &num, safe: false)
        #expect(result == "img_6.jpg")
        #expect(num == 6)
    }

    @Test("%i increments each call")
    func autoIncrementSequential() {
        var num = 0
        let first = generateFileName(template: "img_%i", for: FilePath("/tmp/photo.jpg"), autoIncrementingNumber: &num)
        let second = generateFileName(template: "img_%i", for: FilePath("/tmp/photo.jpg"), autoIncrementingNumber: &num)
        #expect(first != second)
        #expect(num == 2)
    }

    @Test("%r → 5 random chars")
    func randomCharsToken() {
        var num = 0
        let result = generateFileName(template: "%r", for: FilePath("/tmp/photo.jpg"), autoIncrementingNumber: &num, safe: false)
        // Result should be 5 random chars + ".jpg"
        #expect(result.hasSuffix(".jpg"))
        let stem = result.replacingOccurrences(of: ".jpg", with: "")
        #expect(stem.count == 5)
    }

    @Test("%P → directory path")
    func pathToken() {
        var num = 0
        let result = generateFileName(template: "%P_file", for: FilePath("/tmp/subdir/photo.jpg"), autoIncrementingNumber: &num, safe: false)
        #expect(result.contains("/tmp/subdir"))
    }

    @Test("Date tokens produce expected format")
    func dateTokens() {
        var num = 0
        let result = generateFileName(template: "%y-%m-%d", for: FilePath("/tmp/photo.jpg"), autoIncrementingNumber: &num, safe: false)
        // Should match YYYY-MM-DD pattern
        let parts = result.replacingOccurrences(of: ".jpg", with: "").split(separator: "-")
        #expect(parts.count == 3)
        #expect(parts[0].count == 4) // year
        #expect(parts[1].count == 2) // month
        #expect(parts[2].count == 2) // day
    }

    @Test("Time tokens produce expected format")
    func timeTokens() {
        var num = 0
        let result = generateFileName(template: "%H_%M_%S", for: FilePath("/tmp/photo.jpg"), autoIncrementingNumber: &num, safe: false)
        let stem = result.replacingOccurrences(of: ".jpg", with: "")
        let parts = stem.split(separator: "_")
        #expect(parts.count == 3)
        #expect(parts[0].count == 2) // hour
        #expect(parts[1].count == 2) // minutes
        #expect(parts[2].count == 2) // seconds
    }

    @Test("%p → AM or PM")
    func amPmToken() {
        var num = 0
        let result = generateFileName(template: "%p", for: FilePath("/tmp/photo.jpg"), autoIncrementingNumber: &num, safe: false)
        let stem = result.replacingOccurrences(of: ".jpg", with: "")
        #expect(stem == "AM" || stem == "PM")
    }

    @Test("safe=true sanitises special characters")
    func safeMode() {
        var num = 0
        let result = generateFileName(template: "file/with:special*chars", for: nil, autoIncrementingNumber: &num, safe: true)
        #expect(!result.contains("/"))
        #expect(!result.contains(":"))
        #expect(!result.contains("*"))
    }

    @Test("No path → no extension appended")
    func noPath() {
        var num = 0
        let result = generateFileName(template: "output", for: nil, autoIncrementingNumber: &num, safe: false)
        #expect(result == "output")
    }

    @Test("Combined tokens")
    func combinedTokens() {
        var num = 0
        let result = generateFileName(template: "%f_%i", for: FilePath("/tmp/photo.jpg"), autoIncrementingNumber: &num, safe: false)
        #expect(result == "photo_1.jpg")
        #expect(num == 1)
    }

    // MARK: - generateFilePath

    @Test("generateFilePath with absolute template")
    func absoluteTemplate() throws {
        var num = 0
        let result = try generateFilePath(template: "/tmp/output/file.jpg", for: FilePath("/tmp/photo.jpg"), autoIncrementingNumber: &num, mkdir: false)
        #expect(result != nil)
        #expect(result?.string.hasPrefix("/tmp/output") == true)
    }

    @Test("generateFilePath with relative template uses source dir")
    func relativeTemplate() throws {
        var num = 0
        let result = try generateFilePath(template: "output/file.jpg", for: FilePath("/tmp/source/photo.jpg"), autoIncrementingNumber: &num, mkdir: false)
        #expect(result != nil)
        #expect(result?.string.hasPrefix("/tmp/source") == true)
    }

    @Test("generateFilePath with %P template")
    func pathTemplate() throws {
        var num = 0
        let result = try generateFilePath(template: FilePath("%P/%f_optimised"), for: FilePath("/tmp/photos/image.jpg"), autoIncrementingNumber: &num, mkdir: false)
        #expect(result.string.contains("image_optimised"))
    }
}
