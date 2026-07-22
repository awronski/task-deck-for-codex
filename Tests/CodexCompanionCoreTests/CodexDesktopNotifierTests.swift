import Darwin
@testable import CodexCompanionCore
import Testing

@Suite
struct CodexDesktopNotifierTests {
    @Test
    func disconnectedPeerReturnsEPIPEWithoutTerminatingTheProcess() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        let socketResult = descriptors.withUnsafeMutableBufferPointer { buffer in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
        }
        try #require(socketResult == 0)

        let writer = descriptors[0]
        var peer = descriptors[1]
        defer {
            Darwin.close(writer)
            if peer >= 0 {
                Darwin.close(peer)
            }
        }

        try #require(CodexDesktopNotifier.suppressSIGPIPE(on: writer))

        var enabled: Int32 = 0
        var optionLength = socklen_t(MemoryLayout<Int32>.size)
        let optionResult = getsockopt(writer, SOL_SOCKET, SO_NOSIGPIPE, &enabled, &optionLength)
        try #require(optionResult == 0)
        try #require(enabled == 1)

        Darwin.close(peer)
        peer = -1

        var byte: UInt8 = 0
        errno = 0
        let writeResult = withUnsafePointer(to: &byte) { pointer in
            Darwin.write(writer, pointer, 1)
        }

        #expect(writeResult == -1)
        #expect(errno == EPIPE)
    }
}
