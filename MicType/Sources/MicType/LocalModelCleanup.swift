import Foundation

// MARK: - 5.0.0 升级：把本机识别模型从磁盘上删掉

/// 4.x 的每一位用户机器上都躺着一份 Qwen3-ASR 权重（0.6B-6bit 约 860 MB，1.7B-4bit 更大），
/// 外加一份模型目录缓存。5.0.0 之后**没有任何代码会再读它们**——不删的话，这几百 MB
/// 会在用户完全不知情的情况下一直占着盘，而界面上再也没有一个地方提到"模型"这两个字。
///
/// 三条纪律：
///   • **只删 MicType 自己的目录**（Application Support/MicType/models 与 catalog 缓存），
///     一个路径都不拼用户目录以外的东西；
///   • **只跑一次**（一条 UserDefaults 标记），删不掉就记一行 WARN 走人——
///     磁盘满、权限怪、文件被占着，都不该让 App 启动失败；
///   • 释放了多少**要报给用户**：这是升级当天唯一一件他能感知到的好事，
///     那句话由 LaunchNotice 闪在悬浮窗上。
enum LocalModelCleanup {

    /// 只跑一次的标记
    static let doneKey = "cleanedLocalModels50"

    /// 跑一次（启动时）。返回释放了多少字节；0 = 没什么可删的，或者这次跳过了。
    @discardableResult
    static func runIfNeeded(defaults: UserDefaults = .standard) -> Int64 {
        guard !defaults.bool(forKey: doneKey) else { return 0 }
        defaults.set(true, forKey: doneKey)
        let freed = removeAll(at: staleDirectories())
        Log.info("Local model cleanup done freed=\(freed) bytes (\(gigabytesLabel(freed)))")
        return freed
    }

    /// 要删的那几处。**全部在 Application Support/MicType 下**——这是这个函数唯一
    /// 该碰的地方，多拼一层用户目录就是一次不可撤销的误删。
    static func staleDirectories() -> [URL] {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                         in: .userDomainMask,
                                                         appropriateFor: nil, create: false) else {
            return []
        }
        let root = support.appendingPathComponent("MicType", isDirectory: true)
        return [
            // 模型权重（QwenModelDownloader 当年下到这里）
            root.appendingPathComponent("models", isDirectory: true),
            // 远端模型目录的本机缓存（ModelCatalog）
            root.appendingPathComponent("model-catalog.json", isDirectory: false),
        ]
    }

    /// 删掉这几处并返回释放的字节数。删不动就跳过——这一步永远不许让启动失败。
    static func removeAll(at urls: [URL]) -> Int64 {
        let fm = FileManager.default
        var freed: Int64 = 0
        for url in urls {
            guard fm.fileExists(atPath: url.path) else { continue }
            let size = directorySize(url)
            do {
                try fm.removeItem(at: url)
                freed += size
                Log.info("Local model cleanup removed \(url.lastPathComponent) bytes=\(size)")
            } catch {
                // 路径不进日志（它带着账户短名）；删不掉不是错误路径，下次也不会再试
                Log.warn("Local model cleanup could not remove \(url.lastPathComponent): \(error)")
            }
        }
        return freed
    }

    /// 递归量一下有多少字节。量不出来就算 0——这个数只用来说一句"释放了多少"，
    /// 报少了顶多是这句话保守一点，绝不该为它冒任何风险。
    static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard let walker = fm.enumerator(at: url,
                                         includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    /// 「1.2 GB」/「860 MB」。**纯函数**：这串会出现在升级那一刻的悬浮窗上，
    /// 而那一句是用户对这次升级的全部印象，不能写成 "0.8 GB" 或 "1234567890 bytes"。
    /// 小于 1 GB 按 MB 说（860 MB 比 0.84 GB 好读），1 GB 以上保留一位小数。
    /// 0 返回空串——没释放出空间就不该有这半句话。
    static func gigabytesLabel(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "" }
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Int((Double(bytes) / 1_000_000).rounded())
        return "\(max(mb, 1)) MB"
    }
}
