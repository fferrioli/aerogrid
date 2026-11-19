import Darwin
import Foundation

/// The caller serializes access. Diagnostic paths are fixed children of a private directory.
final class DiagnosticLogFile {
    static let directoryName = "diagnostics"
    private let url: URL
    private let limit: Int
    private var didOpen = false

    init(url: URL, limit: Int) {
        self.url = url
        self.limit = limit
    }

    @discardableResult func append(_ data: Data) throws -> Bool {
        guard data.count <= limit else { throw POSIXError(.EFBIG) }
        try prepareDirectory()
        var fd = try openFile()
        defer { close(fd) }
        var size = try fileSize(fd)
        let rotated = size + data.count > limit
        if rotated {
            let previous = url.appendingPathExtension("previous")
            guard rename(url.path, previous.path) == 0 else { throw failure() }
            close(fd)
            fd = -1
            fd = try openFile()
            size = 0
        } else if !didOpen {
            size = try removePartialLine(fd, size: size)
        }
        didOpen = true
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        do { try file.write(contentsOf: data) }
        catch {
            _ = ftruncate(fd, off_t(size))
            throw error
        }
        return rotated
    }

    private func prepareDirectory() throws {
        let directory = url.deletingLastPathComponent()
        guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else { throw failure() }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid() else { throw POSIXError(.EPERM) }
        if info.st_mode & 0o777 != 0o700, fchmod(fd, 0o700) != 0 { throw failure() }
    }

    private func openFile() throws -> Int32 {
        let fd = open(url.path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1 else {
            close(fd)
            throw POSIXError(.EPERM)
        }
        if info.st_mode & 0o777 != 0o600, fchmod(fd, 0o600) != 0 {
            let error = failure()
            close(fd)
            throw error
        }
        return fd
    }

    private func fileSize(_ fd: Int32) throws -> Int {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw failure() }
        return Int(info.st_size)
    }

    private func removePartialLine(_ fd: Int32, size: Int) throws -> Int {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var end = size
        while end > 0 {
            let start = max(0, end - buffer.count)
            let count = end - start
            guard pread(fd, &buffer, count, off_t(start)) == count else { throw failure() }
            if let newline = buffer[..<count].lastIndex(of: 10) {
                end = start + newline + 1
                break
            }
            end = start
        }
        if end < size, ftruncate(fd, off_t(end)) != 0 { throw failure() }
        return end
    }

    private func failure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
