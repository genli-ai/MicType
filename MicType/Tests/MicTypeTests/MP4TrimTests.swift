import XCTest
@testable import MicType
#if os(macOS)
import AVFoundation
#endif

/// 移植自 iOS `MP4TrimTests`（2026-09-28），只改了 import 那一行。
///
/// `MP4Trim.stripFreeBoxes` (2026-09-28, DECISIONS L39 补记): drops the ~23 KB `free` padding box
/// `AVAudioFile` writes into every upload m4a, moving the absolute `stco` / `co64` chunk offsets back by
/// what was removed in front of them — and must hand anything it doesn't fully understand back untouched,
/// because its output goes straight to the provider. Synthetic layouts pin the arithmetic; the macOS
/// round trip proves the REAL encoder output still decodes to the same samples after stripping.
final class MP4TrimTests: XCTestCase {

    // MARK: - Synthetic MP4 builder (big-endian boxes; only what the trimmer reads is meaningful)

    private func be32(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(v).bigEndian, Array.init) }
    private func be64(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt64(v).bigEndian, Array.init) }
    private func zeros(_ n: Int) -> [UInt8] { [UInt8](repeating: 0, count: n) }
    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { be32(8 + payload.count) + Array(type.utf8) + payload }
    /// Same box with a 32-bit size of 1 and a 64-bit `largesize` after the type.
    private func largeBox(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        be32(1) + Array(type.utf8) + be64(16 + payload.count) + payload
    }
    private func stco(_ offsets: [Int]) -> [UInt8] { box("stco", zeros(4) + be32(offsets.count) + offsets.flatMap(be32)) }
    private func co64(_ offsets: [Int]) -> [UInt8] { box("co64", zeros(4) + be32(offsets.count) + offsets.flatMap(be64)) }
    private var ftyp: [UInt8] { box("ftyp", Array("M4A ".utf8) + zeros(4) + Array("M4A mp42isom".utf8)) }

    /// moov · trak · mdia · minf · stbl · <chunk table>, with filler siblings like a real file has.
    private func moov(_ table: [UInt8]) -> [UInt8] {
        box("moov", box("mvhd", zeros(100))
            + box("trak", box("tkhd", zeros(84))
                + box("mdia", box("mdhd", zeros(24)) + box("hdlr", zeros(25))
                    + box("minf", box("smhd", zeros(8))
                        + box("stbl", box("stsd", zeros(8)) + box("stsz", zeros(12)) + table)))))
    }

    private enum Part { case raw([UInt8]), moov, mdat }
    /// Two 8-byte "chunks" the chunk table points at, recognisable wherever they end up.
    private let chunks: [[UInt8]] = [[0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7],
                                     [0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7]]

    /// Lays out `parts` in order; the chunk table in `moov` holds the ABSOLUTE offsets of the two chunks
    /// inside `mdat`. The table's size doesn't depend on its values, so a placeholder pass finds them.
    private func build(_ parts: [Part], largeMdat: Bool = false, useCo64: Bool = false) -> (data: Data, offsets: [Int]) {
        let payload = chunks.flatMap { $0 }
        let mdat = largeMdat ? largeBox("mdat", payload) : box("mdat", payload)
        func assemble(_ offsets: [Int]) -> (bytes: [UInt8], payloadStart: Int) {
            var bytes: [UInt8] = []
            var payloadStart = 0
            for part in parts {
                switch part {
                case .raw(let raw): bytes += raw
                case .moov: bytes += moov(useCo64 ? co64(offsets) : stco(offsets))
                case .mdat: payloadStart = bytes.count + (largeMdat ? 16 : 8); bytes += mdat
                }
            }
            return (bytes, payloadStart)
        }
        let start = assemble([0, 0]).payloadStart
        let offsets = [start, start + chunks[0].count]
        return (Data(assemble(offsets).bytes), offsets)
    }

    // MARK: - Independent reader for the assertions (not the implementation's parser)

    private func read(_ b: [UInt8], _ at: Int, _ width: Int) -> Int {
        Int((0..<width).reduce(UInt64(0)) { $0 << 8 | UInt64(b[at + $1]) })
    }

    private func topLevelTypes(_ d: Data) -> [String] {
        let b = [UInt8](d)
        var types: [String] = []
        var at = 0
        while at + 8 <= b.count {
            var size = read(b, at, 4)
            if size == 1 { size = read(b, at + 8, 8) }
            types.append(String(decoding: b[(at + 4)..<(at + 8)], as: UTF8.self))
            guard size > 0 else { break }
            at += size
        }
        return types
    }

    /// Chunk offsets from the `stco` / `co64` (the synthetic files have a single track).
    private func chunkOffsets(_ d: Data) -> [Int] {
        let b = [UInt8](d)
        for (type, width) in [("stco", 4), ("co64", 8)] {
            guard let r = b.firstRange(of: Array(type.utf8)) else { continue }
            let count = read(b, r.lowerBound + 8, 4)   // type · version+flags · entry_count · entries
            return (0..<count).map { read(b, r.lowerBound + 12 + $0 * width, width) }
        }
        return []
    }

    private func assertChunksIntact(_ d: Data, at offsets: [Int], file: StaticString = #filePath, line: UInt = #line) {
        let b = [UInt8](d)
        XCTAssertEqual(offsets.count, chunks.count, file: file, line: line)
        for (chunk, offset) in zip(chunks, offsets) {
            guard offset + chunk.count <= b.count else {
                return XCTFail("chunk offset \(offset) points past the end (\(b.count) bytes)", file: file, line: line)
            }
            XCTAssertEqual(Array(b[offset..<(offset + chunk.count)]), chunk,
                           "chunk offset \(offset) no longer points at its audio", file: file, line: line)
        }
    }

    // MARK: - Stripping

    func test_freeBeforeMoov_isRemoved_andChunkOffsetsMoveBackByItsSize() {
        let free = box("free", zeros(1_000))
        let (input, offsets) = build([.raw(ftyp), .raw(free), .moov, .mdat])
        assertChunksIntact(input, at: offsets)   // the builder itself is right

        let out = MP4Trim.stripFreeBoxes(input)
        XCTAssertEqual(topLevelTypes(out), ["ftyp", "moov", "mdat"])
        XCTAssertEqual(out.count, input.count - free.count)
        XCTAssertEqual(chunkOffsets(out), offsets.map { $0 - free.count })
        assertChunksIntact(out, at: chunkOffsets(out))
    }

    /// The layout `AVAudioFile` actually writes (box dump 2026-09-28): ftyp · moov · free · mdat.
    func test_avAudioFileLayout_freeBetweenMoovAndMdat_isRemoved() {
        let free = box("free", zeros(23_497))
        let (input, offsets) = build([.raw(ftyp), .moov, .raw(free), .mdat])
        let out = MP4Trim.stripFreeBoxes(input)
        XCTAssertEqual(topLevelTypes(out), ["ftyp", "moov", "mdat"])
        XCTAssertEqual(out.count, input.count - free.count)
        XCTAssertEqual(chunkOffsets(out), offsets.map { $0 - free.count })
        assertChunksIntact(out, at: chunkOffsets(out))
    }

    func test_co64_offsetsAreShiftedToo() {
        let free = box("free", zeros(500))
        let (input, offsets) = build([.raw(ftyp), .moov, .raw(free), .mdat], useCo64: true)
        let out = MP4Trim.stripFreeBoxes(input)
        XCTAssertEqual(topLevelTypes(out), ["ftyp", "moov", "mdat"])
        XCTAssertEqual(chunkOffsets(out), offsets.map { $0 - free.count })
        assertChunksIntact(out, at: chunkOffsets(out))
    }

    func test_largesizeHeaders_areParsed() {
        let free = largeBox("free", zeros(300))
        let (input, offsets) = build([.raw(ftyp), .moov, .raw(free), .mdat], largeMdat: true)
        assertChunksIntact(input, at: offsets)
        let out = MP4Trim.stripFreeBoxes(input)
        XCTAssertEqual(topLevelTypes(out), ["ftyp", "moov", "mdat"])
        XCTAssertEqual(out.count, input.count - free.count)
        XCTAssertEqual(chunkOffsets(out), offsets.map { $0 - free.count })
        assertChunksIntact(out, at: chunkOffsets(out))
    }

    func test_freeAfterMdat_isRemoved_offsetsUntouched() {
        let free = box("free", zeros(64))
        let (input, offsets) = build([.raw(ftyp), .moov, .mdat, .raw(free)])
        let out = MP4Trim.stripFreeBoxes(input)
        XCTAssertEqual(topLevelTypes(out), ["ftyp", "moov", "mdat"])
        XCTAssertEqual(out.count, input.count - free.count)
        XCTAssertEqual(chunkOffsets(out), offsets)
        assertChunksIntact(out, at: offsets)
    }

    func test_freeAndSkip_bothRemoved_shiftIsTheirSum() {
        let free = box("free", zeros(100)), skip = box("skip", zeros(40))
        let (input, offsets) = build([.raw(ftyp), .raw(free), .moov, .raw(skip), .mdat])
        let out = MP4Trim.stripFreeBoxes(input)
        XCTAssertEqual(topLevelTypes(out), ["ftyp", "moov", "mdat"])
        XCTAssertEqual(chunkOffsets(out), offsets.map { $0 - free.count - skip.count })
        assertChunksIntact(out, at: chunkOffsets(out))
    }

    /// `Data` slices keep their parent's indices; the trimmer must not assume they start at 0.
    func test_dataSliceWithNonZeroStartIndex_isHandled() {
        let free = box("free", zeros(200))
        let (input, offsets) = build([.raw(ftyp), .moov, .raw(free), .mdat])
        let slice = (Data([0xEE, 0xEE, 0xEE]) + input).dropFirst(3)
        XCTAssertNotEqual(slice.startIndex, 0)
        let out = MP4Trim.stripFreeBoxes(slice)
        XCTAssertEqual(out, MP4Trim.stripFreeBoxes(input))
        XCTAssertEqual(chunkOffsets(out), offsets.map { $0 - free.count })
        assertChunksIntact(out, at: chunkOffsets(out))
    }

    // MARK: - Returned unchanged

    func test_noPadding_returnsInputIdentical() {
        let (input, _) = build([.raw(ftyp), .moov, .mdat])
        XCTAssertEqual(MP4Trim.stripFreeBoxes(input), input)
    }

    func test_garbageEmptyAndTruncated_returnInputIdentical() {
        // Deterministic noise (a multiplicative hash of the index), so a failure reproduces.
        let garbage = Data((0..<4_096).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 13) })
        XCTAssertEqual(MP4Trim.stripFreeBoxes(garbage), garbage)
        XCTAssertEqual(MP4Trim.stripFreeBoxes(Data()), Data())
        XCTAssertEqual(MP4Trim.stripFreeBoxes(Data("free".utf8)), Data("free".utf8))

        let (input, _) = build([.raw(ftyp), .moov, .raw(box("free", zeros(200))), .mdat])
        let truncated = input.dropLast(5)   // mdat now claims more bytes than the file has
        XCTAssertEqual(MP4Trim.stripFreeBoxes(truncated), truncated)
        let trailingJunk = input + Data([0x00, 0x01, 0x02])   // shorter than a box header
        XCTAssertEqual(MP4Trim.stripFreeBoxes(trailingJunk), trailingJunk)
    }

    /// An offset that doesn't land in the `mdat` payload (here: inside the padding) means the file isn't
    /// what we think — rewriting it could make it worse, so leave it alone.
    func test_offsetOutsideMdat_returnsInputIdentical() throws {
        var bytes = [UInt8](build([.raw(ftyp), .raw(box("free", zeros(100))), .moov, .mdat]).data)
        let r = try XCTUnwrap(bytes.firstRange(of: Array("stco".utf8)))
        bytes.replaceSubrange((r.lowerBound + 12)..<(r.lowerBound + 16), with: be32(ftyp.count + 20))   // inside `free`
        let input = Data(bytes)
        XCTAssertEqual(MP4Trim.stripFreeBoxes(input), input)
    }

    func test_unknownTopLevelBox_returnsInputIdentical() {
        // `moof` = a fragmented file, whose own offsets this doesn't rewrite.
        let (input, _) = build([.raw(ftyp), .moov, .raw(box("free", zeros(100))), .mdat, .raw(box("moof", zeros(16)))])
        XCTAssertEqual(MP4Trim.stripFreeBoxes(input), input)
    }

    func test_trackWithoutChunkOffsetTable_returnsInputIdentical() {
        let noTable = box("moov", box("trak", box("mdia", box("minf", box("stbl", box("stsd", zeros(8)))))))
        let input = Data(ftyp + noTable + box("free", zeros(100)) + box("mdat", chunks.flatMap { $0 }))
        XCTAssertEqual(MP4Trim.stripFreeBoxes(input), input)
    }

    // MARK: - Real encoder output (macOS — where `swift test` runs; AVAudioFile writes the same layout)

    #if os(macOS)
    /// Writes 3 s of 16 kHz mono audio with EXACTLY the writer settings of
    /// `SpeechTranscription.m4a48k16kMonoData` (app target; AAC-LC 48 kbps), strips it, and checks the
    /// stripped file still opens, reports the same length, and decodes to bit-identical samples — the
    /// proof the rewritten chunk offsets still point at the same AAC packets.
    func test_realAVAudioFileM4A_stripsPadding_andDecodesToTheSameSamples() throws {
        let tmp = FileManager.default.temporaryDirectory
        let original = tmp.appendingPathComponent("mp4trim-\(UUID().uuidString).m4a")
        let stripped = tmp.appendingPathComponent("mp4trim-\(UUID().uuidString)-stripped.m4a")
        defer { try? FileManager.default.removeItem(at: original); try? FileManager.default.removeItem(at: stripped) }

        try writeAAC48(seconds: 3, to: original)
        let encoded = try Data(contentsOf: original)
        XCTAssertTrue(topLevelTypes(encoded).contains("free"), "AVAudioFile no longer pads — this test lost its subject")

        let trimmed = MP4Trim.stripFreeBoxes(encoded)
        XCTAssertFalse(topLevelTypes(trimmed).contains("free"))
        XCTAssertGreaterThan(encoded.count - trimmed.count, 10_000, "expected the ~23 KB padding to go")
        try trimmed.write(to: stripped)

        let a = try decode(original), b = try decode(stripped)
        XCTAssertGreaterThan(a.length, 0)
        XCTAssertEqual(b.length, a.length)
        XCTAssertEqual(b.samples.count, a.samples.count)
        XCTAssertTrue(b.samples == a.samples, "the stripped file decodes to different audio")
    }

    /// The writer is a local here so it deinits (finalising the file) before the caller reads it —
    /// `close()` is macOS 15+ and this package still builds for 13.
    private func writeAAC48(seconds: Double, to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                 channels: 1, interleaved: false))
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(frames) {   // a gliding tone + a steady one, so every packet carries real content
            let t = Double(i) / 16_000
            samples[i] = Float(0.25 * sin(2 * .pi * (220 + 300 * t) * t) + 0.1 * sin(2 * .pi * 1_760 * t))
        }
        let writer = try AVAudioFile(forWriting: url,
                                     settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                AVSampleRateKey: 16_000,
                                                AVNumberOfChannelsKey: 1,
                                                AVEncoderBitRateKey: 48_000],
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        try writer.write(from: buffer)
    }

    private func decode(_ url: URL) throws -> (length: AVAudioFramePosition, samples: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        return (file.length, Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
    }
    #endif
}
