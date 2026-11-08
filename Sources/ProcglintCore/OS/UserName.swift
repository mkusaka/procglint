import Darwin

func userName(for uid: UInt32) -> String {
    var capacity = 1024
    while true {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: capacity)
        var error: Int32 = 0
        let name = buffer.withUnsafeMutableBufferPointer { buffer -> String? in
            error = getpwuid_r(uid, &entry, buffer.baseAddress, buffer.count, &result)
            guard error == 0, result != nil, let name = entry.pw_name else { return nil }
            return String(cString: name)
        }
        guard error == ERANGE else { return name ?? String(uid) }
        capacity *= 2
    }
}
