import Darwin
import Foundation

struct CodexDesktopNotifier {
    private let socketURL: URL

    init(codexHome: URL) {
        socketURL = codexHome.appendingPathComponent("ipc/ipc.sock")
    }

    func notify(archived: Bool, taskID: String) {
        guard FileManager.default.fileExists(atPath: socketURL.path) else { return }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        guard Self.suppressSIGPIPE(on: descriptor) else { return }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        withUnsafePointer(to: &timeout) { pointer in
            _ = setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
            _ = setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }

        guard connect(descriptor: descriptor, path: socketURL.path) else { return }

        let requestID = UUID().uuidString
        guard writeFrame([
            "type": "request",
            "requestId": requestID,
            "sourceClientId": "initializing-client",
            "version": 0,
            "method": "initialize",
            "params": ["clientType": "task-deck-for-codex"]
        ], to: descriptor) else { return }

        guard let response = readFrame(from: descriptor),
              response["requestId"] as? String == requestID,
              let result = response["result"] as? [String: Any],
              let clientID = result["clientId"] as? String
        else { return }

        _ = writeFrame([
            "type": "broadcast",
            "method": archived ? "thread-archived" : "thread-unarchived",
            "sourceClientId": clientID,
            "params": [
                "hostId": "local",
                "conversationId": taskID
            ],
            "version": archived ? 2 : 1
        ], to: descriptor)
    }

    static func suppressSIGPIPE(on descriptor: Int32) -> Bool {
        var enabled: Int32 = 1
        return withUnsafePointer(to: &enabled) { pointer in
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0
        }
    }

    private func connect(descriptor: Int32, path: String) -> Bool {
        let pathBytes = Array(path.utf8CString)
        var address = sockaddr_un()
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path) ?? 0
        let addressLength = pathOffset + pathBytes.count
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path),
              addressLength <= Int(UInt8.max)
        else { return false }

        address.sun_len = UInt8(addressLength)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(addressLength)) == 0
            }
        }
    }

    private func writeFrame(_ object: [String: Any], to descriptor: Int32) -> Bool {
        guard let payload = try? JSONSerialization.data(withJSONObject: object),
              payload.count <= Int(UInt32.max)
        else { return false }

        var payloadLength = UInt32(payload.count).littleEndian
        var frame = withUnsafeBytes(of: &payloadLength) { Data($0) }
        frame.append(payload)
        return write(frame, to: descriptor)
    }

    private func write(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private func readFrame(from descriptor: Int32) -> [String: Any]? {
        guard let header = read(count: 4, from: descriptor) else { return nil }
        let length = header.enumerated().reduce(UInt32(0)) { value, byte in
            value | (UInt32(byte.element) << UInt32(byte.offset * 8))
        }
        guard length > 0, length <= 1_048_576,
              let payload = read(count: Int(length), from: descriptor),
              let object = try? JSONSerialization.jsonObject(with: Data(payload))
        else { return nil }
        return object as? [String: Any]
    }

    private func read(count: Int, from descriptor: Int32) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    count - offset
                )
            }
            if received > 0 {
                offset += received
            } else if received < 0, errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return bytes
    }
}
