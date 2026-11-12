#if os(macOS)
import Foundation

/// A persistent lab host reuses a private local PSK; media session keys remain ephemeral.
enum LabHostKey {
    static func loadOrCreate(at path: String, reuseExisting: Bool) throws -> String {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        if fd >= 0 {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                let key = try SignalTransport.newPairingKey()
                try handle.write(contentsOf: Data(key.utf8))
                try handle.close()
                return key
            } catch {
                try? handle.close()
                unlink(path)
                throw error
            }
        }
        guard errno == EEXIST, reuseExisting else {
            throw LabError.message("配对码文件已存在或无法创建；仅常驻主机可复用已有文件")
        }
        let input = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard input >= 0 else { throw LabError.message("无法读取配对码文件") }
        let handle = FileHandle(fileDescriptor: input, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(input, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_mode & 0o077 == 0,
              metadata.st_size > 0, metadata.st_size <= 128 else {
            throw LabError.message("配对码文件必须为当前用户拥有的私有普通文件（权限 0600）")
        }
        let data = try handle.read(upToCount: 129) ?? Data()
        guard data.count <= 128, let text = String(data: data, encoding: .utf8) else {
            throw LabError.message("配对码文件内容无效")
        }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Data(base64Encoded: key)?.count == 32 else { throw LabError.message("配对码文件内容无效") }
        return key
    }
}
#endif
