import Foundation
import Darwin

/// One visible process, as much of it as VibeCheck needs.
struct ProcessEntry: Sendable {
    let pid: Int32
    let ppid: Int32
    /// Executable basename, truncated by the kernel to 15 characters.
    let command: String
    /// Full argv joined by spaces — the same shape `ps -o args=` prints.
    let args: String
}

/// Enumerates processes through libproc and sysctl instead of shelling out.
///
/// The previous implementation ran `/bin/ps` on every poll — 40 subprocesses a
/// minute, forever, in an app whose pitch is that it is not heavy. libproc
/// answers the same questions with syscalls, and full argv is fetched only for
/// the handful of processes that could possibly be an assistant.
enum ProcessList {
    /// Executable names worth reading full arguments for: the assistants
    /// themselves plus the interpreters their CLIs are commonly launched
    /// through. Everything else never needs its argv read.
    private static let interpreters: Set<String> = ["node", "bun", "deno", "npx", "npm"]

    /// All processes, with argv filled in only for plausible assistants.
    /// Returns nil when the kernel gives us nothing, so the caller can decide
    /// whether to fall back.
    static func snapshot(argvFor candidates: Set<String>) -> [ProcessEntry]? {
        guard let pids = allPIDs(), !pids.isEmpty else { return nil }
        let wanted = candidates.union(interpreters)

        var result: [ProcessEntry] = []
        result.reserveCapacity(pids.count)
        for pid in pids where pid > 0 {
            guard var info = bsdInfo(pid) else { continue }
            let command = withUnsafeBytes(of: &info.pbi_comm) { raw -> String in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
                return String(cString: base)
            }
            let ppid = Int32(bitPattern: info.pbi_ppid)
            // Reading argv is the expensive part, so it is limited to
            // processes whose name could belong to an assistant.
            let args = wanted.contains(command.lowercased())
                ? (arguments(of: pid) ?? command) : command
            result.append(
                ProcessEntry(pid: pid, ppid: ppid, command: command, args: args))
        }
        return result.isEmpty ? nil : result
    }

    private static func allPIDs() -> [Int32]? {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return nil }
        // Ask for headroom: processes can appear between the two calls.
        var buffer = [Int32](repeating: 0, count: Int(capacity) + 64)
        let size = Int32(buffer.count * MemoryLayout<Int32>.size)
        let count = buffer.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, size)
        }
        guard count > 0 else { return nil }
        return Array(buffer.prefix(Int(count)))
    }

    private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    /// Full command line via KERN_PROCARGS2, joined the way `ps` joins it.
    static func arguments(of pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size
        else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard buffer.withUnsafeMutableBytes({ raw in
            sysctl(&mib, 3, raw.baseAddress, &size, nil, 0)
        }) == 0 else { return nil }

        // Layout: argc, exec path, padding NULs, then argc NUL-separated args.
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { destination in
            buffer.withUnsafeBytes { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(
                    rebasing: source.prefix(MemoryLayout<Int32>.size)))
            }
        }
        guard argc > 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        // Skip the exec path and the NUL padding that follows it.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var parts: [String] = []
        var current: [UInt8] = []
        while index < size, parts.count < Int(argc) {
            let byte = buffer[index]
            if byte == 0 {
                parts.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
            index += 1
        }
        if !current.isEmpty, parts.count < Int(argc) {
            parts.append(String(decoding: current, as: UTF8.self))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Total CPU time a process has consumed, in nanoseconds. Sampling this
    /// twice gives real utilisation over the interval — `ps` only ever
    /// reported a decaying lifetime average.
    static func cpuTime(of pid: Int32) -> UInt64? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, rebound)
            }
        }
        guard result == 0 else { return nil }
        return info.ri_user_time &+ info.ri_system_time
    }

    // MARK: - Fallback

    /// Last resort if libproc gives us nothing: the original `ps` call.
    static func snapshotViaPS() -> [ProcessEntry]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Axo", "pid=,ppid=,comm=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        var result: [ProcessEntry] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1])
            else { continue }
            result.append(ProcessEntry(
                pid: pid, ppid: ppid,
                command: URL(fileURLWithPath: String(parts[2])).lastPathComponent,
                args: String(parts[3])))
        }
        return result.isEmpty ? nil : result
    }
}
