import XCTest
import CoreVideo
@testable import LockscreenDah

/// The blind-frame / warm-up gate. It has to read *luma*, and it has to read it
/// from the right byte: the IR camera streams packed 2vuy (UYVY), where every
/// even byte is chroma and sits at a constant 128. An earlier implementation
/// sampled every 16th byte, always hit those chroma bytes, and therefore called
/// every frame flat — including frames Vision could see a face in. That
/// misjudgement disabled the warm-up gate, the dim-mode early close and the
/// blind-session rebuild all at once, so the byte layout is pinned here.
final class FrameFlatnessTests: XCTestCase {
    private let width = 64
    private let height = 32

    private func makeBuffer(_ format: OSType) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, format, nil, &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return buffer!
    }

    /// Fill a packed pair-per-pixel buffer: `lumaOffset` is the byte carrying Y,
    /// the other byte of each pair carries chroma.
    private func fillPacked(
        _ buffer: CVPixelBuffer,
        lumaOffset: Int,
        luma: UInt8,
        chroma: UInt8 = 128
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rows = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<rows {
            var x = 0
            while x + 1 < rowBytes {
                base[y * rowBytes + x + lumaOffset] = luma
                base[y * rowBytes + x + (1 - lumaOffset)] = chroma
                x += 2
            }
        }
    }

    private func setPackedByte(
        _ buffer: CVPixelBuffer,
        offset: Int,
        value: UInt8
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        base[offset] = value
    }

    // MARK: - Packed 2vuy (the IR camera's format)

    func testPackedUYVYConstantLumaIsFlat() {
        let buffer = makeBuffer(kCVPixelFormatType_422YpCbCr8)
        fillPacked(buffer, lumaOffset: 1, luma: 16)
        XCTAssertTrue(FaceMonitor.frameIsFlat(buffer))
    }

    func testPackedUYVYChromaVariationDoesNotCountAsImage() {
        let buffer = makeBuffer(kCVPixelFormatType_422YpCbCr8)
        fillPacked(buffer, lumaOffset: 1, luma: 16)
        // Alternating chroma: exactly what the old scan saw, and why every
        // frame looked flat. Luma is unchanged, so the frame is still flat.
        setPackedByte(buffer, offset: 0, value: 0)
        setPackedByte(buffer, offset: 2, value: 255)
        XCTAssertTrue(FaceMonitor.frameIsFlat(buffer))
    }

    func testPackedUYVYLumaVariationIsNotFlat() {
        let buffer = makeBuffer(kCVPixelFormatType_422YpCbCr8)
        fillPacked(buffer, lumaOffset: 1, luma: 16)
        setPackedByte(buffer, offset: 1, value: 200) // row 0, first sampled pixel
        XCTAssertFalse(FaceMonitor.frameIsFlat(buffer))
    }

    func testPackedYUY2LumaVariationIsNotFlat() {
        let buffer = makeBuffer(kCVPixelFormatType_422YpCbCr8_yuvs)
        fillPacked(buffer, lumaOffset: 0, luma: 16)
        setPackedByte(buffer, offset: 0, value: 200)
        XCTAssertFalse(FaceMonitor.frameIsFlat(buffer))
    }

    // MARK: - Planar 420 (the built-in camera's usual format)

    private func fillPlanar(_ buffer: CVPixelBuffer, luma: UInt8, chroma: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
                .assumingMemoryBound(to: UInt8.self)
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let value = plane == 0 ? luma : chroma
            for y in 0..<rows {
                for x in 0..<rowBytes { base[y * rowBytes + x] = value }
            }
        }
    }

    func testPlanarConstantLumaIsFlat() {
        let buffer = makeBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        fillPlanar(buffer, luma: 16, chroma: 128)
        XCTAssertTrue(FaceMonitor.frameIsFlat(buffer))
    }

    func testPlanarLumaVariationIsNotFlat() {
        let buffer = makeBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        fillPlanar(buffer, luma: 16, chroma: 128)
        CVPixelBufferLockBaseAddress(buffer, [])
        CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
            .assumingMemoryBound(to: UInt8.self)[0] = 200
        CVPixelBufferUnlockBaseAddress(buffer, [])
        XCTAssertFalse(FaceMonitor.frameIsFlat(buffer))
    }

    func testPlanarChromaVariationIsIgnored() {
        let buffer = makeBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        fillPlanar(buffer, luma: 16, chroma: 128)
        CVPixelBufferLockBaseAddress(buffer, [])
        CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
            .assumingMemoryBound(to: UInt8.self)[0] = 0
        CVPixelBufferUnlockBaseAddress(buffer, [])
        XCTAssertTrue(FaceMonitor.frameIsFlat(buffer))
    }

    // MARK: - Unknown packed formats keep a conservative scan

    func testPackedBGRAPixelsAreStillScanned() {
        let buffer = makeBuffer(kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rows = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<rows {
            for x in 0..<rowBytes { base[y * rowBytes + x] = 16 }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        XCTAssertTrue(FaceMonitor.frameIsFlat(buffer))

        CVPixelBufferLockBaseAddress(buffer, [])
        base[0] = 200
        CVPixelBufferUnlockBaseAddress(buffer, [])
        XCTAssertFalse(FaceMonitor.frameIsFlat(buffer))
    }
}
