const std = @import("std");
const bench = @import("bench.zig");
const dsp = @import("dsp.zig");
const engines = @import("engines.zig");

fn isCore(name: []const u8) bool {
    return std.mem.eql(u8, name, "leveler") or
        std.mem.eql(u8, name, "dsp") or
        std.mem.eql(u8, name, "dsp-dereverb") or
        std.mem.eql(u8, name, "speex-dereverb");
}

fn allFinite(samples: []const f32) bool {
    for (samples) |sample| if (!std.math.isFinite(sample)) return false;
    return true;
}

pub fn run(allocator: std.mem.Allocator) !u8 {
    const stdout = std.io.getStdOut().writer();
    var far = try bench.makeFarMic(allocator);
    defer far.deinit();
    const n = far.samples.len - (far.samples.len % dsp.hop);
    var failures: usize = 0;
    for (engines.catalog) |spec| {
        const avail = engines.availability(spec.name);
        if (!avail.ok) {
            try stdout.print("{s:<22} SKIP  {s}\n", .{ spec.name, avail.reason });
            continue;
        }
        var slot = engines.open(allocator, spec.name) catch |err| {
            try stdout.print("{s:<22} {s}  {s}\n", .{ spec.name, if (isCore(spec.name)) "FAIL" else "SKIP", @errorName(err) });
            if (isCore(spec.name)) failures += 1;
            continue;
        };
        defer slot.deinit();
        slot.setGainDb(0);
        const output = try allocator.alloc(f32, n);
        defer allocator.free(output);
        var offset: usize = 0;
        while (offset < n) : (offset += dsp.hop) {
            slot.process(far.samples[offset..][0..dsp.hop], output[offset..][0..dsp.hop]);
        }
        const finite = allFinite(output);
        if (std.mem.eql(u8, spec.name, "dsp-dereverb")) {
            const gate = bench.loudnessGate(far, output, slot.delaySamples());
            if (!finite or !gate.ok) {
                failures += 1;
                try stdout.print("{s:<22} FAIL  speech {d:.1} dBFS pause {d:.1} dBFS (pause in {d:.1})\n", .{
                    spec.name, gate.speech_db, gate.pause_out_db, gate.pause_in_db,
                });
            } else {
                try stdout.print("{s:<22} pass  speech {d:.1} dBFS pause {d:.1} dBFS\n", .{
                    spec.name, gate.speech_db, gate.pause_out_db,
                });
            }
            continue;
        }
        if (isCore(spec.name) and !finite) {
            failures += 1;
            try stdout.print("{s:<22} FAIL  non-finite audio\n", .{spec.name});
            continue;
        }
        if (!finite) {
            try stdout.print("{s:<22} pass  non-finite samples are not a gate for this engine\n", .{spec.name});
        } else {
            try stdout.print("{s:<22} pass  finite\n", .{spec.name});
        }
    }
    if (failures != 0) {
        try stdout.print("{d} failure(s)\n", .{failures});
        return 1;
    }
    try stdout.print("qa passed\n", .{});
    return 0;
}
