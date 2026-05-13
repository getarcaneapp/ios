import Foundation
import Arcane

nonisolated struct ContainerStatsFrame: Identifiable, Hashable, Sendable {
    let id = UUID()
    let timestamp: Date
    let cpuPercent: Double
    let memoryUsed: Int64
    let memoryLimit: Int64
    let memoryPercent: Double
    let netRxBytes: Int64
    let netTxBytes: Int64
    let netRxPerSec: Double
    let netTxPerSec: Double
    let blockReadBytes: Int64
    let blockWriteBytes: Int64
    let blockReadPerSec: Double
    let blockWritePerSec: Double

    static func from(json: JSONValue, previous: ContainerStatsFrame?, now: Date = Date()) -> ContainerStatsFrame? {
        guard let root = json.asObject else { return nil }

        let cpu = root["cpu_stats"]?.asObject ?? [:]
        let pre = root["precpu_stats"]?.asObject ?? [:]
        let cpuTotal = cpu["cpu_usage"]?.asObject?["total_usage"]?.asInt64 ?? 0
        let preTotal = pre["cpu_usage"]?.asObject?["total_usage"]?.asInt64 ?? 0
        let sysTotal = cpu["system_cpu_usage"]?.asInt64 ?? 0
        let preSys = pre["system_cpu_usage"]?.asInt64 ?? 0
        let online = cpu["online_cpus"]?.asInt64
            ?? Int64(cpu["cpu_usage"]?.asObject?["percpu_usage"]?.asArray?.count ?? 1)

        let cpuDelta = Double(cpuTotal - preTotal)
        let sysDelta = Double(sysTotal - preSys)
        let cpuPercent: Double = (sysDelta > 0 && cpuDelta > 0)
            ? (cpuDelta / sysDelta) * Double(max(online, 1)) * 100.0
            : 0.0

        let mem = root["memory_stats"]?.asObject ?? [:]
        let usage = mem["usage"]?.asInt64 ?? 0
        let cache = mem["stats"]?.asObject?["cache"]?.asInt64
            ?? mem["stats"]?.asObject?["inactive_file"]?.asInt64
            ?? 0
        let memUsed = max(0, usage - cache)
        let memLimit = mem["limit"]?.asInt64 ?? 0
        let memPct = memLimit > 0 ? Double(memUsed) / Double(memLimit) * 100.0 : 0

        var rx: Int64 = 0
        var tx: Int64 = 0
        if let nets = root["networks"]?.asObject {
            for (_, ifc) in nets {
                rx += ifc.asObject?["rx_bytes"]?.asInt64 ?? 0
                tx += ifc.asObject?["tx_bytes"]?.asInt64 ?? 0
            }
        }

        var blkR: Int64 = 0
        var blkW: Int64 = 0
        if let entries = root["blkio_stats"]?.asObject?["io_service_bytes_recursive"]?.asArray {
            for e in entries {
                let op = e.asObject?["op"]?.asString ?? ""
                let v = e.asObject?["value"]?.asInt64 ?? 0
                if op.caseInsensitiveCompare("Read") == .orderedSame {
                    blkR += v
                } else if op.caseInsensitiveCompare("Write") == .orderedSame {
                    blkW += v
                }
            }
        }

        let dt = previous.map { now.timeIntervalSince($0.timestamp) } ?? 1.0
        let safeDt = max(dt, 0.001)
        let netRxPS = previous.map { max(0, Double(rx - $0.netRxBytes) / safeDt) } ?? 0
        let netTxPS = previous.map { max(0, Double(tx - $0.netTxBytes) / safeDt) } ?? 0
        let blkRPS = previous.map { max(0, Double(blkR - $0.blockReadBytes) / safeDt) } ?? 0
        let blkWPS = previous.map { max(0, Double(blkW - $0.blockWriteBytes) / safeDt) } ?? 0

        return ContainerStatsFrame(
            timestamp: now,
            cpuPercent: cpuPercent,
            memoryUsed: memUsed,
            memoryLimit: memLimit,
            memoryPercent: memPct,
            netRxBytes: rx,
            netTxBytes: tx,
            netRxPerSec: netRxPS,
            netTxPerSec: netTxPS,
            blockReadBytes: blkR,
            blockWriteBytes: blkW,
            blockReadPerSec: blkRPS,
            blockWritePerSec: blkWPS
        )
    }
}

extension JSONValue {
    nonisolated var asObject: [String: JSONValue]? {
        if case let .object(v) = self { return v } else { return nil }
    }
    nonisolated var asArray: [JSONValue]? {
        if case let .array(v) = self { return v } else { return nil }
    }
    nonisolated var asInt64: Int64? {
        if case let .number(v) = self { return Int64(v) } else { return nil }
    }
    nonisolated var asDouble: Double? {
        if case let .number(v) = self { return v } else { return nil }
    }
    nonisolated var asString: String? {
        if case let .string(v) = self { return v } else { return nil }
    }
    nonisolated var asBool: Bool? {
        if case let .bool(v) = self { return v } else { return nil }
    }
}
