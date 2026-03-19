@testable import Clop
import Foundation
import Testing

@Suite("gsArgs()")
struct GSArgsTests {
    @Test("Lossy args contain expected flags")
    func lossyArgs() {
        let args = gsArgs("/tmp/input.pdf", "/tmp/output.pdf", lossy: true)
        #expect(args.contains("-dPassThroughJPEGImages=false"))
        #expect(args.contains("-dDownsampleColorImages=true"))
        #expect(args.contains("-dPassThroughJPXImages=false"))
        #expect(args.contains("-dShowAcroForm=false"))
    }

    @Test("Lossless args contain expected flags")
    func losslessArgs() {
        let args = gsArgs("/tmp/input.pdf", "/tmp/output.pdf", lossy: false)
        #expect(args.contains("-dPassThroughJPEGImages=true"))
        #expect(args.contains("-dDownsampleColorImages=false"))
        #expect(args.contains("-dPassThroughJPXImages=true"))
        #expect(args.contains("-dShowAcroForm=true"))
    }

    @Test("Both lossy and lossless contain device and font path")
    func commonArgs() {
        for lossy in [true, false] {
            let args = gsArgs("/tmp/in.pdf", "/tmp/out.pdf", lossy: lossy)
            #expect(args.contains("-sDEVICE=pdfwrite"))
            #expect(args.contains(where: { $0.hasPrefix("-sFONTPATH=") }))
        }
    }

    @Test("Output flag present with correct path")
    func outputFlag() {
        let args = gsArgs("/tmp/in.pdf", "/tmp/out.pdf", lossy: true)
        let oIndex = args.firstIndex(of: "-o")
        #expect(oIndex != nil)
        if let i = oIndex {
            #expect(args[args.index(after: i)] == "/tmp/out.pdf")
        }
    }

    @Test("Input file appears after GS_PRE_ARGS")
    func inputAfterPreArgs() {
        let args = gsArgs("/tmp/input.pdf", "/tmp/output.pdf", lossy: true)
        let inputIndex = args.lastIndex(of: "/tmp/input.pdf")
        let preArgsFIndex = args.lastIndex(of: "-f")
        #expect(inputIndex != nil)
        // Input should be near the end, before POST args
        if let ii = inputIndex {
            #expect(ii > args.count / 2)
        }
    }

    @Test("GS_ARGS come first")
    func gsArgsFirst() {
        let args = gsArgs("/tmp/in.pdf", "/tmp/out.pdf", lossy: true)
        // First arg should be from GS_ARGS
        #expect(args.first == GS_ARGS.first)
    }

    @Test("Contains base GS_ARGS flags")
    func containsBaseArgs() {
        let args = gsArgs("/tmp/in.pdf", "/tmp/out.pdf", lossy: true)
        #expect(args.contains("-dBATCH"))
        #expect(args.contains("-dNOPAUSE"))
        #expect(args.contains("-dSAFER"))
        #expect(args.contains("-r150"))
    }

    @Test("Paths with spaces are preserved")
    func pathsWithSpaces() {
        let args = gsArgs("/tmp/my input.pdf", "/tmp/my output.pdf", lossy: true)
        #expect(args.contains("/tmp/my input.pdf"))
        #expect(args.contains("/tmp/my output.pdf"))
    }

    @Test("POST args include pdfmark restoration")
    func postArgs() {
        let args = gsArgs("/tmp/in.pdf", "/tmp/out.pdf", lossy: true)
        #expect(args.contains("/pdfmark { originalpdfmark } bind def"))
    }

    @Test("Lossy vs lossless differ on downsample flags")
    func lossyVsLosslessDifference() {
        let lossyResult = gsArgs("/tmp/in.pdf", "/tmp/out.pdf", lossy: true)
        let losslessResult = gsArgs("/tmp/in.pdf", "/tmp/out.pdf", lossy: false)
        // They should differ on key flags
        #expect(lossyResult.contains("-dDownsampleColorImages=true"))
        #expect(losslessResult.contains("-dDownsampleColorImages=false"))
        #expect(lossyResult.contains("-dDownsampleGrayImages=true"))
        #expect(losslessResult.contains("-dDownsampleGrayImages=false"))
    }
}
