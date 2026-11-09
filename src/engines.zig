const std = @import("std");
const config = @import("config.zig");
const dsp = @import("dsp.zig");
const fifo = @import("fifo.zig");
const rock = @import("rock.zig");
const weights = @import("weights.zig");
const voice = @import("voice.zig");
const options = @import("build_options");

pub const OpenOptions = struct {
    profile: config.Profile = .desktop,
    threads: u32 = 1,
    cpu_budget: f32 = 0.05,
};

pub const Spec = struct {
    name: []const u8,
    frame: usize,
    algo_delay: usize,
};

pub const catalog = [_]Spec{
    .{ .name = "leveler", .frame = dsp.hop, .algo_delay = 0 },
    .{ .name = "dsp", .frame = dsp.hop, .algo_delay = dsp.hop },
    .{ .name = "dsp-dereverb", .frame = dsp.hop, .algo_delay = dsp.hop },
    .{ .name = "speex-dereverb", .frame = 480, .algo_delay = 480 },
    .{ .name = "rnnoise", .frame = 480, .algo_delay = 0 },
    .{ .name = "dpdfnet2", .frame = 480, .algo_delay = 2400 },
    .{ .name = "dpdfnet8", .frame = 480, .algo_delay = 2400 },
    .{ .name = "localvqe-v1.2", .frame = 768, .algo_delay = 814 },
    .{ .name = "localvqe-v1.3", .frame = 768, .algo_delay = 814 },
    .{ .name = "mossformer2-48k", .frame = 256, .algo_delay = 0 },
    .{ .name = "frcrn-16k", .frame = 256, .algo_delay = 0 },
    .{ .name = "mossformer-gan-16k", .frame = 256, .algo_delay = 0 },
};

pub const Availability = struct {
    ok: bool,
    reason: []const u8,
};

const localvqe_mod = @import("localvqe.zig");

pub fn findSpec(name: []const u8) ?Spec {
    for (catalog) |spec| if (std.mem.eql(u8, spec.name, name)) return spec;
    return null;
}

const SpeexEng = opaque {};
extern fn speex_eng_new(dereverb: c_int) ?*SpeexEng;
extern fn speex_eng_free(eng: ?*SpeexEng) void;
extern fn speex_eng_process(eng: *SpeexEng, in: [*]const f32, out: [*]f32) void;

const RnnoiseEng = opaque {};
extern fn rnnoise_eng_new() ?*RnnoiseEng;
extern fn rnnoise_eng_free(eng: ?*RnnoiseEng) void;
extern fn rnnoise_eng_process(eng: *RnnoiseEng, in: [*]const f32, out: [*]f32) void;

const DpdfEng = opaque {};
extern fn dpdf_eng_cpu_ok() c_int;
extern fn dpdf_eng_new(model_id: c_int, w: [*]const f32, count: usize) ?*DpdfEng;
extern fn dpdf_eng_free(eng: ?*DpdfEng) void;
extern fn dpdf_eng_process(eng: *DpdfEng, in: [*]const f32, out: [*]f32) void;

var clearer_state: ?[]const u8 = null;

fn clearerReason() []const u8 {
    if (clearer_state) |reason| return reason;
    const res = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "python3", "-c", "import clearvoice" },
        .max_output_bytes = 16 * 1024,
    }) catch {
        clearer_state = "ClearerVoice-Studio is not installed (python3 could not start)";
        return clearer_state.?;
    };
    std.heap.page_allocator.free(res.stdout);
    std.heap.page_allocator.free(res.stderr);
    const ok = switch (res.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    clearer_state = if (ok)
        "ClearerVoice-Studio imports, but it is non-realtime PyTorch and is not run in this binary"
    else
        "ClearerVoice-Studio is not installed (python3: import clearvoice failed)";
    return clearer_state.?;
}

pub fn availability(name: []const u8) Availability {
    const spec = findSpec(name) orelse return .{ .ok = false, .reason = "unknown engine" };
    if (std.mem.eql(u8, spec.name, "localvqe-v1.2") or std.mem.eql(u8, spec.name, "localvqe-v1.3")) {
        const found = localvqe_mod.probe(spec.name);
        return .{ .ok = found.ok, .reason = found.reason };
    }
    if (std.mem.eql(u8, spec.name, "mossformer2-48k") or std.mem.eql(u8, spec.name, "frcrn-16k") or std.mem.eql(u8, spec.name, "mossformer-gan-16k")) {
        return .{ .ok = false, .reason = clearerReason() };
    }
    if (std.mem.eql(u8, spec.name, "speex-dereverb")) {
        if (comptime !options.with_speex) return .{ .ok = false, .reason = "not linked in this build" };
        return .{ .ok = true, .reason = "" };
    }
    if (std.mem.eql(u8, spec.name, "rnnoise")) {
        if (!options.with_rnnoise) return .{ .ok = false, .reason = "not linked in this build" };
        return .{ .ok = true, .reason = "" };
    }
    if (std.mem.eql(u8, spec.name, "dpdfnet2") or std.mem.eql(u8, spec.name, "dpdfnet8")) {
        if (comptime !options.with_dpdfnet) return .{ .ok = false, .reason = "not linked in this build" };
        if (dpdf_eng_cpu_ok() == 0) return .{ .ok = false, .reason = "this CPU does not support AVX2 and FMA" };
        const file = if (std.mem.eql(u8, spec.name, "dpdfnet2")) weights.dpdfnet2_file else weights.dpdfnet8_file;
        const sha = if (std.mem.eql(u8, spec.name, "dpdfnet2")) weights.dpdfnet2_sha256 else weights.dpdfnet8_sha256;
        const hint = if (std.mem.eql(u8, spec.name, "dpdfnet2"))
            "weights missing (nearmic fetch dpdfnet2)"
        else
            "weights missing (nearmic fetch dpdfnet8)";
        if (weights.find(std.heap.page_allocator, file, sha)) |path| {
            std.heap.page_allocator.free(path);
            return .{ .ok = true, .reason = "" };
        }
        return .{ .ok = false, .reason = hint };
    }
    return .{ .ok = true, .reason = "" };
}

pub fn printList(writer: anytype) !void {
    for (catalog) |spec| {
        const avail = availability(spec.name);
        if (avail.ok) {
            try writer.print("{s:<22} yes\n", .{spec.name});
        } else {
            try writer.print("{s:<22} no   {s}\n", .{ spec.name, avail.reason });
        }
    }
}

const Kind = union(enum) {
    chain: *dsp.Chain,
    rock: *rock.Engine,
    speex: *SpeexEng,
    rnnoise: *RnnoiseEng,
    dpdf: *DpdfEng,
    localvqe: *localvqe_mod.Engine,
};

pub const Slot = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    adapter: fifo.Adapter,
    kind: Kind,
    post: ?*voice.Post = null,
    profile: config.Profile = .desktop,
    thread_request: u32 = 1,
    threads_used: usize = 1,
    cpu_budget: f32 = 0.05,

    pub fn threadsUsed(self: *const Slot) usize {
        return self.threads_used;
    }

    pub fn process(self: *Slot, input: []const f32, output: []f32) void {
        self.adapter.pushHop(input, output);
        if (self.post) |post| post.process(output);
    }

    pub fn delaySamples(self: *const Slot) usize {
        // The post chain's look-ahead limiter delays every neural engine by
        // one DSP hop on top of the model's own delay.
        const post_delay = if (self.post != null) voice.Post.latency else 0;
        return self.adapter.delaySamples() + post_delay;
    }

    pub fn setGainDb(self: *Slot, db: f32) void {
        self.adapter.setGainDb(db);
    }

    pub fn deinit(self: *Slot) void {
        if (self.post) |post| {
            self.allocator.destroy(post);
            self.post = null;
        }
        switch (self.kind) {
            .chain => |chain| self.allocator.destroy(chain),
            .rock => |eng| {
                eng.deinit();
                self.allocator.destroy(eng);
            },
            .speex => |eng| if (comptime options.with_speex) speex_eng_free(eng),
            .rnnoise => |eng| if (comptime options.with_rnnoise) rnnoise_eng_free(eng),
            .dpdf => |eng| if (comptime options.with_dpdfnet) dpdf_eng_free(eng),
            .localvqe => |eng| {
                eng.deinit();
                self.allocator.destroy(eng);
            },
        }
    }
};

fn processChain(ctx: *anyopaque, input: []const f32, output: []f32) void {
    const chain: *dsp.Chain = @ptrCast(@alignCast(ctx));
    chain.process(input, output);
}

fn processSpeex(ctx: *anyopaque, input: []const f32, output: []f32) void {
    if (comptime !options.with_speex) {
        @memset(output, 0);
        return;
    }
    const eng: *SpeexEng = @ptrCast(@alignCast(ctx));
    speex_eng_process(eng, input.ptr, output.ptr);
}

fn processRock(ctx: *anyopaque, input: []const f32, output: []f32) void {
    const eng: *rock.Engine = @ptrCast(@alignCast(ctx));
    eng.process(input, output);
}

fn processRnnoise(ctx: *anyopaque, input: []const f32, output: []f32) void {
    if (comptime !options.with_rnnoise) {
        @memset(output, 0);
        return;
    }
    const eng: *RnnoiseEng = @ptrCast(@alignCast(ctx));
    rnnoise_eng_process(eng, input.ptr, output.ptr);
}

fn processDpdf(ctx: *anyopaque, input: []const f32, output: []f32) void {
    if (comptime !options.with_dpdfnet) {
        @memset(output, 0);
        return;
    }
    const eng: *DpdfEng = @ptrCast(@alignCast(ctx));
    dpdf_eng_process(eng, input.ptr, output.ptr);
}

fn useRock(name: []const u8, opts: OpenOptions) bool {
    if (opts.profile != .rock_pi_plus) return false;
    return std.mem.eql(u8, name, "dsp") or std.mem.eql(u8, name, "dsp-dereverb");
}

pub fn open(allocator: std.mem.Allocator, name: []const u8, opts: OpenOptions) !Slot {
    const spec = findSpec(name) orelse return error.UnknownEngine;
    const avail = availability(spec.name);
    const dpdf_can_fetch = options.with_dpdfnet and (std.mem.eql(u8, spec.name, "dpdfnet2") or std.mem.eql(u8, spec.name, "dpdfnet8"));
    if (!avail.ok and !dpdf_can_fetch) return error.Unavailable;
    var slot = Slot{
        .allocator = allocator,
        .name = spec.name,
        .adapter = .{ .frame = spec.frame, .algo_delay = spec.algo_delay },
        .kind = undefined,
        .profile = opts.profile,
        .thread_request = opts.threads,
        .threads_used = 1,
        .cpu_budget = opts.cpu_budget,
    };
    if (useRock(spec.name, opts)) {
        const denoise = true;
        const dereverb = std.mem.eql(u8, spec.name, "dsp-dereverb");
        const eng = try rock.Engine.open(allocator, denoise, dereverb, opts.threads, opts.cpu_budget);
        slot.kind = .{ .rock = eng };
        slot.threads_used = eng.threadsUsed();
        slot.adapter.algo_delay = eng.delaySamples();
        slot.adapter.ctx = eng;
        slot.adapter.process_frame = processRock;
    } else if ((comptime options.with_speex) and std.mem.eql(u8, spec.name, "speex-dereverb")) {
        const eng = speex_eng_new(1) orelse return error.Unavailable;
        slot.kind = .{ .speex = eng };
        slot.adapter.ctx = eng;
        slot.adapter.process_frame = processSpeex;
    } else if (std.mem.eql(u8, spec.name, "rnnoise")) {
        if (comptime !options.with_rnnoise) return error.Unavailable;
        const eng = rnnoise_eng_new() orelse return error.Unavailable;
        slot.kind = .{ .rnnoise = eng };
        slot.adapter.ctx = eng;
        slot.adapter.process_frame = processRnnoise;
    } else if (std.mem.eql(u8, spec.name, "dpdfnet2") or std.mem.eql(u8, spec.name, "dpdfnet8")) {
        if (comptime !options.with_dpdfnet) return error.Unavailable;
        const which: u8 = if (std.mem.eql(u8, spec.name, "dpdfnet2")) 2 else 8;
        const file = if (which == 2) weights.dpdfnet2_file else weights.dpdfnet8_file;
        const sha = if (which == 2) weights.dpdfnet2_sha256 else weights.dpdfnet8_sha256;
        const path = weights.find(allocator, file, sha) orelse blk: {
            const fetched = weights.fetchDpdf(allocator, which) catch return error.Unavailable;
            break :blk fetched;
        };
        defer allocator.free(path);
        const samples = try weights.readF32(allocator, path);
        defer allocator.free(samples);
        const eng = dpdf_eng_new(which, samples.ptr, samples.len) orelse return error.Unavailable;
        slot.kind = .{ .dpdf = eng };
        slot.adapter.ctx = eng;
        slot.adapter.process_frame = processDpdf;
    } else if (std.mem.eql(u8, spec.name, "localvqe-v1.2") or std.mem.eql(u8, spec.name, "localvqe-v1.3")) {
        const eng = try allocator.create(localvqe_mod.Engine);
        errdefer allocator.destroy(eng);
        eng.* = localvqe_mod.Engine.open(allocator, spec.name) catch |err| return err;
        slot.kind = .{ .localvqe = eng };
        slot.adapter.ctx = eng;
        slot.adapter.process_frame = localvqe_mod.process;
    } else {
        const chain = try allocator.create(dsp.Chain);
        chain.* = if (std.mem.eql(u8, spec.name, "leveler"))
            dsp.Chain.init(false, false)
        else if (std.mem.eql(u8, spec.name, "dsp"))
            dsp.Chain.init(true, false)
        else
            dsp.Chain.init(true, true);
        slot.kind = .{ .chain = chain };
        slot.adapter.ctx = chain;
        slot.adapter.process_frame = processChain;
    }
    switch (slot.kind) {
        .rnnoise, .dpdf, .localvqe => {
            if (std.posix.getenv("NEARMIC_NO_POST") == null) {
                const post = try allocator.create(voice.Post);
                post.* = voice.Post.init(true);
                slot.post = post;
            }
        },
        else => {},
    }
    slot.adapter.begin();
    return slot;
}
