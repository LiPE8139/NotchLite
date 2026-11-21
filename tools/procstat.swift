// procstat <pid> [seconds]
// Reads another process's resident size and CPU time via libproc (no root needed for same-user procs).
import Darwin
import Foundation

let args = CommandLine.arguments
guard args.count >= 2, let pid = Int32(args[1]) else {
    print("usage: procstat <pid> [seconds]")
    exit(2)
}
let seconds = args.count >= 3 ? (Double(args[2]) ?? 5) : 5

func sample(_ pid: Int32) -> (rss: UInt64, cpuNanos: UInt64, threads: Int32)? {
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    let n = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
    guard n == size else { return nil }
    return (info.pti_resident_size, info.pti_total_user + info.pti_total_system, info.pti_threadnum)
}

guard let a = sample(pid) else {
    print("cannot read pid \(pid) (exited, or not your process)")
    exit(1)
}

Thread.sleep(forTimeInterval: seconds)

guard let b = sample(pid) else {
    print("process exited while sampling")
    exit(1)
}

let cpuSeconds = Double(b.cpuNanos &- a.cpuNanos) / 1_000_000_000
let cpuPercent = cpuSeconds / seconds * 100
let rssMB = Double(b.rss) / 1_048_576

print(String(format: "pid=%d rss=%.1f MB  cpu=%.2f%% (avg over %.1fs, %d threads)",
             pid, rssMB, cpuPercent, seconds, b.threads))
