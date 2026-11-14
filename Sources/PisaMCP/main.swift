import Foundation
#if !XCODE_BUILD
import PisaCore
#endif
let home = FileManager.default.homeDirectoryForCurrentUser
let root = home.appendingPathComponent("Library/Containers/com.docomoz.pisa/Data/Library/Application Support/Pisa")
do {
    let library = try MeetingLibrary(root: root)
    let analyticsSpool = MCPAnalyticsSpool(root: root)
    let handler = MCPHandler(library: library) { call in
        try? analyticsSpool.record(call.tool, succeeded: call.succeeded)
    }
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        // The client keeps stdin open while waiting for each response.
        let count = read(STDIN_FILENO, &chunk, chunk.count)
        if count == 0 { break }
        if count < 0 {
            if errno == EINTR { continue }
            exit(1)
        }
        buffer.append(contentsOf: chunk.prefix(count))
        if buffer.count > 1_048_576 { exit(1) }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]; buffer.removeSubrange(...end)
            let response: [String: Any]?
            if let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                response = handler.handle(request)
            } else { response = ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]] }
            if let response, var data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) {
                data.append(10); FileHandle.standardOutput.write(data)
            }
        }
    }
} catch { FileHandle.standardError.write(Data("Cannot open Pisa library\n".utf8)); exit(1) }
