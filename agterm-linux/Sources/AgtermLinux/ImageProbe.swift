import CGtk
import Foundation
#if canImport(Glibc)
import Glibc
#endif
import agtermCore

/// ImageProbe reads a picture file for an image page: its bytes, its format by signature, and its pixel size
/// and EXIF orientation from the header alone.
struct ImageProbe: Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let orientation: Int
    let mimeType: String

    enum Failure: Error, Sendable, CustomStringConvertible {
        case unreadable(String)
        case tooLarge(String)
        case notAnImage(String)
        case tooManyPixels(String)

        var description: String {
            switch self {
            case .unreadable(let path): "unreadable image: \(path)"
            case .tooLarge(let path): "image too large (over \(ImagePage.maxBytes >> 20) MB): \(path)"
            case .notAnImage(let path): "not a png, jpg, gif or webp image: \(path)"
            case .tooManyPixels(let path): "image too large (over \(ImagePage.maxPixels / 1_000_000) megapixels): \(path)"
            }
        }
    }

    /// load reads the file and probes the bytes it read, so the sniffed type describes the data it returns.
    static func load(path: String, maxBytes: Int = ImagePage.maxBytes) -> Result<(ImageProbe, Data), Failure> {
        BoundedFile.read(path: path, maxBytes: maxBytes)
            .mapError { $0 == .tooLarge ? .tooLarge(path) : .unreadable(path) }
            .flatMap { data in probe(data, path: path).map { ($0, data) } }
    }

    private static func probe(_ data: Data, path: String) -> Result<ImageProbe, Failure> {
        guard let mime = ImagePage.mimeType(sniffing: data) else { return .failure(.notAnImage(path)) }
        guard let loader = gdk_pixbuf_loader_new() else { return .failure(.notAnImage(path)) }
        defer {
            _ = gdk_pixbuf_loader_close(loader, nil)
            g_object_unref(loader)
        }
        let written = data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return gdk_pixbuf_loader_write(loader, base, gsize(buf.count), nil) != 0
        }
        guard written, let pixbuf = gdk_pixbuf_loader_get_pixbuf(loader) else {
            return .failure(.notAnImage(path))
        }
        let width = Int(gdk_pixbuf_get_width(pixbuf))
        let height = Int(gdk_pixbuf_get_height(pixbuf))
        guard width > 0, height > 0 else { return .failure(.notAnImage(path)) }
        guard ImagePage.allowsPixels(width: width, height: height) else { return .failure(.tooManyPixels(path)) }
        var orientation = 1
        if let opt = gdk_pixbuf_get_option(pixbuf, "orientation"), let parsed = Int(String(cString: opt)) {
            orientation = parsed
        }
        return .success(ImageProbe(pixelWidth: width, pixelHeight: height, orientation: orientation, mimeType: mime))
    }

    /// natural is the picture's drawn size in points on a display of `scale`.
    func natural(scale: Double) -> (width: Double, height: Double) {
        ImagePage.natural(pixelWidth: pixelWidth, pixelHeight: pixelHeight, orientation: orientation, scale: scale)
    }

    /// loadDetached runs `load` off the main actor, for the routes untrusted terminal output reaches.
    static func loadDetached(path: String) async -> Result<(ImageProbe, Data), Failure> {
        await Task.detached(priority: .userInitiated) { load(path: path) }.value
    }
}

/// BoundedFile reads a file named by untrusted output through one descriptor and judges what that descriptor
/// names: a symlink is measured at its target, and a file over the caller's cap is refused before a byte is read.
enum BoundedFile {
    enum Failure: Error, Sendable, Equatable {
        case unreadable
        case tooLarge
    }

    static func check(path: String, maxBytes: Int) -> Result<Void, Failure> {
        withDescriptor(path: path, maxBytes: maxBytes) { _, _ in .success(()) }
    }

    static func read(path: String, maxBytes: Int) -> Result<Data, Failure> {
        withDescriptor(path: path, maxBytes: maxBytes) { fd, size in
            var data = Data(count: size)
            var filled = 0
            while filled < data.count {
                let count = data.withUnsafeMutableBytes { buffer in
                    #if canImport(Darwin)
                    Darwin.read(fd, buffer.baseAddress! + filled, buffer.count - filled)
                    #else
                    Glibc.read(fd, buffer.baseAddress! + filled, buffer.count - filled)
                    #endif
                }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                filled += count
            }
            return filled == data.count ? .success(data) : .failure(.unreadable)
        }
    }

    private static func withDescriptor<T>(path: String, maxBytes: Int,
                                          _ body: (Int32, Int) -> Result<T, Failure>) -> Result<T, Failure> {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .failure(.unreadable) }
        defer { close(fd) }
        var info = stat()
        #if canImport(Darwin)
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_flags & UInt32(SF_DATALESS) == 0 else {
            return .failure(.unreadable)
        }
        #else
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            return .failure(.unreadable)
        }
        #endif
        guard info.st_size <= maxBytes else { return .failure(.tooLarge) }
        return body(fd, Int(info.st_size))
    }
}
