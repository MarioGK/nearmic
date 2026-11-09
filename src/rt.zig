const std = @import("std");
const builtin = @import("builtin");

/// Realtime scheduling for the DSP threads.
///
/// PipeWire's data loop runs at a realtime priority around 20. The NearMic
/// worker sits one step below it (10) and the rock pool below that (9), so the
/// graph callback always preempts the DSP and the DSP still beats every
/// SCHED_OTHER task. The user unit already carries `LimitRTPRIO=95`; without
/// that limit the kernel returns EPERM and this is a no-op, so the appliance
/// keeps working on a stock unit.
pub const worker_priority: i32 = 10;
pub const pool_priority: i32 = 9;

pub fn promote(priority: i32) ?std.os.linux.E {
    if (builtin.os.tag != .linux) return null;
    const param = std.os.linux.sched_param{ .priority = priority };
    const policy = std.os.linux.SCHED{ .mode = .FIFO };
    const rc = std.os.linux.sched_setscheduler(0, policy, &param);
    const err = std.os.linux.E.init(rc);
    return if (err == .SUCCESS) null else err;
}
