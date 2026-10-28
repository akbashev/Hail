import HailCore
import HailModelRuntime

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public enum PortFinder {
    /// Returns a port the OS says is currently free on the given host.
    ///
    /// First asks the OS for an ephemeral port (port `0`) on the requested host.
    /// If that fails, falls back to scanning from `startingAt`.
    public static func findAvailablePort(host: String = "127.0.0.1", startingAt: Int = 10000) -> Int {
        if let port = ephemeralPort(on: host) {
            return port
        }

        for port in startingAt..<65000 {
            if canBind(port: port, host: host) {
                return port
            }
        }

        return 7337
    }

    private static func ephemeralPort(on host: String) -> Int? {
        resolveAndBind(host: host, port: "0") { _, _ in
            // The actual bound port is read from the socket after binding.
        }
    }

    private static func canBind(port: Int, host: String) -> Bool {
        resolveAndBind(host: host, port: String(port)) { _, _ in } != nil
    }

    /// Creates a socket, resolves the host, binds, and returns the bound port if successful.
    /// The socket is always closed before returning, so the caller must race the OS to bind again.
    private static func resolveAndBind(
        host: String,
        port: String,
        onBind: (Int32, UnsafePointer<sockaddr>) -> Void
    ) -> Int? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if os(Linux)
            hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
            hints.ai_socktype = SOCK_STREAM
        #endif

        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, port, &hints, &info) == 0, let addrList = info else {
            return nil
        }
        defer { freeaddrinfo(addrList) }

        var result: Int?
        for ptr in sequence(first: addrList, next: { $0.pointee.ai_next }) {
            let fd = socket(ptr.pointee.ai_family, ptr.pointee.ai_socktype, 0)
            guard fd >= 0 else { continue }
            defer { close(fd) }

            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

            guard bind(fd, ptr.pointee.ai_addr, ptr.pointee.ai_addrlen) == 0 else {
                continue
            }

            onBind(fd, ptr.pointee.ai_addr)

            var addr = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let nameResult = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getsockname(fd, sa, &len)
                }
            }
            guard nameResult == 0 else { continue }

            switch addr.ss_family {
            case sa_family_t(AF_INET):
                let sin = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                }
                result = Int(UInt16(bigEndian: sin.sin_port))
            case sa_family_t(AF_INET6):
                let sin6 = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                }
                result = Int(UInt16(bigEndian: sin6.sin6_port))
            default:
                break
            }

            if result != nil { break }
        }

        return result
    }
}
