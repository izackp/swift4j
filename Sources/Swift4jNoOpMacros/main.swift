#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

let protocolVersion = 7

func readExactly(_ count: Int) -> [UInt8]? {
    var buffer = [UInt8](repeating: 0, count: count)
    var offset = 0
    while offset < count {
        let read = buffer.withUnsafeMutableBytes { raw in
            fread(raw.baseAddress! + offset, 1, count - offset, stdin)
        }
        if read == 0 { return nil }
        offset += read
    }
    return buffer
}

func send(_ json: String) {
    let payload = Array(json.utf8)
    var header = UInt64(payload.count).littleEndian
    withUnsafeBytes(of: &header) { _ = fwrite($0.baseAddress, 1, 8, stdout) }
    payload.withUnsafeBytes { _ = fwrite($0.baseAddress, 1, payload.count, stdout) }
    fflush(stdout)
}

func messageKind(_ payload: [UInt8]) -> String {
    guard let open = payload.firstIndex(of: UInt8(ascii: "\"")),
          let close = payload[(open + 1)...].firstIndex(of: UInt8(ascii: "\"")) else { return "" }
    return String(decoding: payload[(open + 1)..<close], as: UTF8.self)
}

while let header = readExactly(8) {
    let length = header.withUnsafeBytes { Int(UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))) }
    guard let payload = readExactly(length) else { break }
    switch messageKind(payload) {
    case "getCapability":
        send(#"{"getCapabilityResult":{"capability":{"protocolVersion":\#(protocolVersion)}}}"#)
    case "expandAttachedMacro", "expandFreestandingMacro":
        send(#"{"expandMacroResult":{"expandedSource":"","diagnostics":[]}}"#)
    case "loadPluginLibrary":
        send(#"{"loadPluginLibraryResult":{"loaded":false,"diagnostics":[]}}"#)
    default:
        exit(1)
    }
}
