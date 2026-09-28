// MARK: - 整段上传的 m4a 去掉 `free` 填充盒（2026-09-28，移植自 iOS）
//
// 出处：iOS `MicTypeCore/MP4Trim.swift`（DECISIONS L39 补记），**逐字移植，代码一行没改**，
// 只把 `public` 留着（Mac 这边同模块，不影响）。为什么要它：`AVAudioFile(forWriting:)` 写 m4a 时
// 在文件前部为 `moov` 预留约 24 KB，没用完的部分变成一个顶层 `free` 盒——短句里这块填充比音频本身还大
// （iOS 编解码评测：5 秒 aac48 带填充 56 KB、去掉后 33 KB，docs/from-ios-260928/ASR-UPLOAD-CODEC-BENCH_260928.md）。
// 去掉它要把 `stco` / `co64` 里的绝对偏移往回挪；认不出的布局一律原样返回（下面英文注释是原文）。

import Foundation

/// Strips the padding `AVAudioFile` writes into every m4a it produces (2026-09-28, DECISIONS L39 补记).
///
/// The batch lane uploads AAC-LC 48 kbps m4a written by `AVAudioFile(forWriting:)`
/// (`SpeechTranscription.m4a48k16kMonoData`). That writer reserves ~24 KB at the front of the file for
/// the `moov` box, and whatever the finished `moov` does not use stays behind as a top-level `free` box —
/// ~23 KB on a short dictation, still ~11 KB at the 3-minute cap (box dumps of real output on macOS 26,
/// 1.2 s–180 s: ftyp · moov · free · mdat, `mdat` at byte 24 568 every time). On a 1–3 s clip that
/// padding is bigger than the audio itself: the 09-28 codec bench
/// (docs/ASR-UPLOAD-CODEC-BENCH_260928.md) measured a 5 s aac48 upload at 56 KB padded vs 33 KB without,
/// and the old "~6.5 KB/s … AAC-LC floors the rate" note in the encoder was this padding amortised.
///
/// Removing a box that sits in front of `mdat` moves every audio chunk forward, and the `stco` / `co64`
/// chunk-offset tables in `moov` hold ABSOLUTE file offsets — so each offset is moved back by the bytes
/// removed in front of it (the tables keep their width, so `moov` itself does not change size).
///
/// Deliberately conservative — the output goes straight to the provider, so a wrong offset would be a
/// lost sentence while leaving the padding in costs only bytes: anything this does not fully understand
/// returns the input UNCHANGED (truncated / overlapping / garbage boxes, an unknown top-level box, a
/// fragmented file, not exactly one `moov`, a track without a chunk-offset table, a table version it
/// doesn't know, an offset that doesn't land inside an `mdat` payload). Pure, no I/O, unit-tested
/// against synthetic layouts and a real `AVAudioFile` round trip on macOS.
public enum MP4Trim {

    /// `data` without its top-level `free` / `skip` boxes, chunk offsets adjusted; `data` itself when it
    /// has none, or on any anomaly (see the type comment).
    public static func stripFreeBoxes(_ data: Data) -> Data {
        let bytes = [UInt8](data)   // re-based at 0 whatever `data`'s own indices are
        guard let top = boxes(in: bytes, from: 0, to: bytes.count, topLevel: true) else { return data }
        let removed = top.filter { padding.contains($0.type) }
        guard !removed.isEmpty else { return data }
        // Only layouts we understand end to end: any other top-level box could carry absolute offsets
        // of its own (`moof`/`sidx` fragments, a HEIF `meta`/`iloc`) that this would leave pointing
        // at the wrong bytes.
        guard top.allSatisfy({ knownTopLevel.contains($0.type) }) else { return data }
        let moovs = top.filter { $0.type == "moov" }
        let mdats = top.filter { $0.type == "mdat" }
        guard moovs.count == 1, let moov = moovs.first, !mdats.isEmpty,
              let tables = chunkOffsetTables(in: bytes, moov: moov) else { return data }

        var patched = bytes
        for table in tables {
            for i in 0..<table.count {
                let at = table.firstEntry + i * table.width
                let offset = table.width == 4 ? read32(bytes, at) : read64(bytes, at)
                // A chunk must start inside an `mdat` payload — which also rules out an offset pointing
                // into one of the boxes being removed (top-level boxes never overlap).
                guard mdats.contains(where: { offset >= UInt64($0.payloadStart) && offset < UInt64($0.end) })
                else { return data }
                let shift = removed.reduce(UInt64(0)) { $0 + (offset >= UInt64($1.end) ? UInt64($1.size) : 0) }
                if table.width == 4 {
                    write32(&patched, at, UInt32(offset - shift))   // only ever shrinks → still fits 32 bits
                } else {
                    write64(&patched, at, offset - shift)
                }
            }
        }

        var out = Data(capacity: bytes.count - removed.reduce(0) { $0 + $1.size })
        var cursor = 0
        for box in removed {   // in file order (parsed front to back)
            out.append(contentsOf: patched[cursor..<box.start])
            cursor = box.end
        }
        out.append(contentsOf: patched[cursor..<patched.count])
        return out
    }

    // MARK: - Box parsing

    private static let padding: Set<String> = ["free", "skip"]
    /// What `AVAudioFile` writes (ftyp · moov · free · mdat) plus the other offset-free boxes a plain
    /// non-fragmented audio MP4 may carry (`skip`, QuickTime's 8-byte `wide` placeholder).
    private static let knownTopLevel: Set<String> = ["ftyp", "moov", "mdat", "free", "skip", "wide"]

    private struct Box {
        let type: String
        let start: Int
        let size: Int        // whole box, header included
        let headerSize: Int  // 8, or 16 with a 64-bit `largesize`
        var end: Int { start + size }
        var payloadStart: Int { start + headerSize }
    }

    /// The boxes tiling `bytes[from..<to]` exactly, or nil if they don't (truncated, overrunning, or a
    /// size smaller than its own header). A 32-bit size of 1 means a 64-bit `largesize` follows the type;
    /// a size of 0 means "to the end of the file", which only means something at the top level.
    private static func boxes(in bytes: [UInt8], from: Int, to: Int, topLevel: Bool) -> [Box]? {
        var result: [Box] = []
        var at = from
        while at < to {
            guard to - at >= 8 else { return nil }
            let size32 = read32(bytes, at)
            let type = String(decoding: bytes[(at + 4)..<(at + 8)], as: UTF8.self)
            var headerSize = 8
            let size: UInt64
            if size32 == 1 {
                guard to - at >= 16 else { return nil }
                size = read64(bytes, at + 8)
                headerSize = 16
            } else if size32 == 0 {
                guard topLevel else { return nil }
                size = UInt64(to - at)
            } else {
                size = size32
            }
            guard size >= UInt64(headerSize), size <= UInt64(to - at) else { return nil }
            result.append(Box(type: type, start: at, size: Int(size), headerSize: headerSize))
            at += Int(size)
        }
        return result
    }

    /// The only child of `parent` with this type; nil if it is missing, repeated, or `parent`'s children
    /// don't parse.
    private static func onlyChild(_ type: String, of parent: Box, in bytes: [UInt8]) -> Box? {
        guard let children = boxes(in: bytes, from: parent.payloadStart, to: parent.end, topLevel: false)
        else { return nil }
        let matches = children.filter { $0.type == type }
        return matches.count == 1 ? matches[0] : nil
    }

    private struct ChunkOffsetTable {
        let firstEntry: Int   // byte index of entry 0
        let count: Int
        let width: Int        // 4 (`stco`) or 8 (`co64`)
    }

    /// Every track's chunk-offset table (`moov/trak/mdia/minf/stbl/stco|co64`), or nil if any track
    /// lacks exactly one, or carries sample-auxiliary offsets (`saio`, also absolute) we'd leave stale.
    private static func chunkOffsetTables(in bytes: [UInt8], moov: Box) -> [ChunkOffsetTable]? {
        guard let children = boxes(in: bytes, from: moov.payloadStart, to: moov.end, topLevel: false)
        else { return nil }
        let traks = children.filter { $0.type == "trak" }
        guard !traks.isEmpty else { return nil }
        var tables: [ChunkOffsetTable] = []
        for trak in traks {
            guard let mdia = onlyChild("mdia", of: trak, in: bytes),
                  let minf = onlyChild("minf", of: mdia, in: bytes),
                  let stbl = onlyChild("stbl", of: minf, in: bytes),
                  let stblChildren = boxes(in: bytes, from: stbl.payloadStart, to: stbl.end, topLevel: false),
                  !stblChildren.contains(where: { $0.type == "saio" })
            else { return nil }
            let candidates = stblChildren.filter { $0.type == "stco" || $0.type == "co64" }
            guard candidates.count == 1, let table = candidates.first else { return nil }
            // FullBox: version (1) + flags (3), then entry_count (4), then the entries.
            guard table.end - table.payloadStart >= 8, bytes[table.payloadStart] == 0 else { return nil }
            let width = table.type == "stco" ? 4 : 8
            let count = Int(read32(bytes, table.payloadStart + 4))
            let firstEntry = table.payloadStart + 8
            guard count <= (table.end - firstEntry) / width else { return nil }
            tables.append(ChunkOffsetTable(firstEntry: firstEntry, count: count, width: width))
        }
        return tables
    }

    // MARK: - Big-endian helpers (callers bounds-check first)

    private static func read32(_ b: [UInt8], _ at: Int) -> UInt64 {
        UInt64(b[at]) << 24 | UInt64(b[at + 1]) << 16 | UInt64(b[at + 2]) << 8 | UInt64(b[at + 3])
    }

    private static func read64(_ b: [UInt8], _ at: Int) -> UInt64 {
        read32(b, at) << 32 | read32(b, at + 4)
    }

    private static func write32(_ b: inout [UInt8], _ at: Int, _ v: UInt32) {
        for i in 0..<4 { b[at + i] = UInt8(truncatingIfNeeded: v >> (24 - 8 * i)) }
    }

    private static func write64(_ b: inout [UInt8], _ at: Int, _ v: UInt64) {
        for i in 0..<8 { b[at + i] = UInt8(truncatingIfNeeded: v >> (56 - 8 * i)) }
    }
}
