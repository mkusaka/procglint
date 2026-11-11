import Darwin
import Foundation

func readInterfaceCounters() -> [UInt32: NetworkBytes]? {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    // Interfaces can appear between the sizing and data reads.
    for _ in 0 ..< 4 {
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size <= 16 * 1024 * 1024 else { return nil }
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
        if result == 0 {
            return interfaceCounters(data.prefix(size))
        }
        if errno != ENOMEM {
            return nil
        }
    }
    return nil
}

func interfaceCounters(_ data: Data) -> [UInt32: NetworkBytes]? {
    data.withUnsafeBytes { bytes in
        var offset = 0
        var result: [UInt32: NetworkBytes] = [:]
        while offset < bytes.count {
            guard bytes.count - offset >= 4 else { return nil }
            let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            guard length >= 4, length <= bytes.count - offset else { return nil }
            if bytes[offset + 3] == RTM_IFINFO2 {
                guard length >= MemoryLayout<if_msghdr2>.size else { return nil }
                let header = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                if header.ifm_flags & IFF_UP != 0, header.ifm_flags & IFF_LOOPBACK == 0 {
                    result[UInt32(header.ifm_index)] = NetworkBytes(received: header.ifm_data.ifi_ibytes,
                                                                    sent: header.ifm_data.ifi_obytes)
                }
            }
            offset += length
        }
        return result
    }
}
