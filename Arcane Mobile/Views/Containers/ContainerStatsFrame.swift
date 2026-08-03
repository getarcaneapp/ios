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

    /// Overload that accepts the SDK's `ContainerStatsPayload` (which exposes
    /// the Docker stats blob as a `[String: JSONValue]` map under `raw`).
    static func from(json: ContainerStatsPayload, previous: ContainerStatsFrame?, now: Date = Date()) -> ContainerStatsFrame? {
        from(json: .object(json.raw), previous: previous, now: now)
    }

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

        let cpuDelta = nonnegativeDelta(cpuTotal, preTotal)
        let sysDelta = nonnegativeDelta(sysTotal, preSys)
        let rawCPUPercent: Double = (sysDelta > 0 && cpuDelta > 0)
            ? (cpuDelta / sysDelta) * Double(max(online, 1)) * 100.0
            : 0.0
        let cpuPercent = rawCPUPercent.isFinite ? min(max(rawCPUPercent, 0), 100_000) : 0

        let mem = root["memory_stats"]?.asObject ?? [:]
        let usage = mem["usage"]?.asInt64 ?? 0
        let cache = mem["stats"]?.asObject?["cache"]?.asInt64
            ?? mem["stats"]?.asObject?["inactive_file"]?.asInt64
            ?? 0
        let memUsed = safeNonnegativeSubtract(usage, cache)
        let memLimit = RemoteDataLimits.nonnegative(mem["limit"]?.asInt64 ?? 0)
        let rawMemoryPercent = memLimit > 0 ? Double(memUsed) / Double(memLimit) * 100.0 : 0
        let memPct = rawMemoryPercent.isFinite ? min(max(rawMemoryPercent, 0), 100_000) : 0

        var rx: Int64 = 0
        var tx: Int64 = 0
        if let nets = root["networks"]?.asObject {
            for (_, ifc) in nets.prefix(1_024) {
                rx = RemoteDataLimits.saturatingAdd(rx, ifc.asObject?["rx_bytes"]?.asInt64 ?? 0)
                tx = RemoteDataLimits.saturatingAdd(tx, ifc.asObject?["tx_bytes"]?.asInt64 ?? 0)
            }
        }

        var blkR: Int64 = 0
        var blkW: Int64 = 0
        if let entries = root["blkio_stats"]?.asObject?["io_service_bytes_recursive"]?.asArray {
            for e in entries.prefix(1_024) {
                let op = e.asObject?["op"]?.asString ?? ""
                let v = e.asObject?["value"]?.asInt64 ?? 0
                if op.caseInsensitiveCompare("Read") == .orderedSame {
                    blkR = RemoteDataLimits.saturatingAdd(blkR, v)
                } else if op.caseInsensitiveCompare("Write") == .orderedSame {
                    blkW = RemoteDataLimits.saturatingAdd(blkW, v)
                }
            }
        }

        let dt = previous.map { now.timeIntervalSince($0.timestamp) } ?? 1.0
        let safeDt = dt.isFinite ? max(dt, 0.001) : 1
        let netRxPS = rate(current: rx, previous: previous?.netRxBytes, duration: safeDt)
        let netTxPS = rate(current: tx, previous: previous?.netTxBytes, duration: safeDt)
        let blkRPS = rate(current: blkR, previous: previous?.blockReadBytes, duration: safeDt)
        let blkWPS = rate(current: blkW, previous: previous?.blockWriteBytes, duration: safeDt)

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

    private static func nonnegativeDelta(_ current: Int64, _ previous: Int64) -> Double {
        let (delta, overflow) = current.subtractingReportingOverflow(previous)
        guard !overflow, delta > 0 else { return 0 }
        return Double(delta)
    }

    private static func safeNonnegativeSubtract(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let left = RemoteDataLimits.nonnegative(lhs)
        let right = RemoteDataLimits.nonnegative(rhs)
        let (result, overflow) = left.subtractingReportingOverflow(right)
        return overflow ? 0 : max(result, 0)
    }

    private static func rate(current: Int64, previous: Int64?, duration: TimeInterval) -> Double {
        guard let previous else { return 0 }
        let delta = nonnegativeDelta(current, previous)
        let value = delta / duration
        return value.isFinite ? min(max(value, 0), 1_000_000_000_000_000) : 0
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
        guard case let .number(v) = self,
              v.isFinite,
              v >= Double(Int64.min),
              v < Double(Int64.max) else { return nil }
        return Int64(v)
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
