import Darwin

/// Resource usage of another process without sudo (same user).
struct ProcStats {
    var footprintMB: Double     // what Activity Monitor calls "Memory"
    var rssMB: Double
    var cpuSeconds: Double
    var uptimeSeconds: Double
    var avgCPUPercent: Double { uptimeSeconds > 0 ? cpuSeconds / uptimeSeconds * 100 : 0 }

    static func of(_ pid: pid_t) -> ProcStats? {
        var ru = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &ru) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard ok == 0 else { return nil }
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        let toS = Double(tb.numer) / Double(tb.denom) / 1e9
        var ti = proc_taskinfo()
        let n = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size))
        var bi = proc_bsdinfo()
        _ = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, Int32(MemoryLayout<proc_bsdinfo>.size))
        var tv = timeval(); gettimeofday(&tv, nil)
        let start = Double(bi.pbi_start_tvsec) + Double(bi.pbi_start_tvusec) / 1e6
        let nowS = Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
        return ProcStats(footprintMB: Double(ru.ri_phys_footprint) / 1_048_576,
                         rssMB: n > 0 ? Double(ti.pti_resident_size) / 1_048_576 : 0,
                         cpuSeconds: Double(ru.ri_user_time + ru.ri_system_time) * toS,
                         uptimeSeconds: max(0, nowS - start))
    }
}
