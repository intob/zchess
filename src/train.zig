//! NNUE trainer in plain Zig. Float32 forward/backward passes, AdamW,
//! data-parallel over all cores, cosine learning-rate decay, and quantised
//! export in the format `nnue.zig` loads.
//!
//! Loss: (sigmoid(out) - target)^2 with
//!   target = (1 - wdl) * sigmoid(score / SCALE) + wdl * game_result
//! both from the side to move's point of view.

const std = @import("std");
const Io = std.Io;
const bb = @import("bitboard.zig");
const nnue = @import("nnue.zig");
const cli = @import("cli.zig");
const Record = @import("data.zig").Record;
const Output = @import("output.zig").Output;

const IN = nnue.INPUTS;
const H = nnue.HIDDEN;
const NB = nnue.BUCKETS;

const OFF_FTW = 0;
const OFF_FTB = OFF_FTW + IN * H;
const OFF_OW = OFF_FTB + H;
const OFF_OB = OFF_OW + NB * 2 * H;
const P = OFF_OB + NB;

const CLIP = 1.98;
const CKPT_MAGIC = "ZCCK";

const help =
    \\usage: zchess train --data <file>[,<file>...] --out <net.nnue> [options]
    \\
    \\  --data <files>     comma-separated datagen files (may repeat)
    \\  --out <file>       quantised network output (a .ckpt float checkpoint is written next to it)
    \\  --epochs <n>       passes over the data (default 10)
    \\  --batch <n>        positions per batch (default 16384)
    \\  --lr <x>           initial learning rate, cosine-decayed to 2% (default 0.001)
    \\  --wdl <x>          weight of game result vs. search score in the target (default 0.1)
    \\  --threads <n>      worker threads (default: all cores)
    \\  --init <ckpt>      start from a float checkpoint instead of random weights
    \\  --seed <n>         shuffle/initialisation seed (default 1)
    \\
;

const Feats = struct {
    stm: [32]u16 = undefined,
    nstm: [32]u16 = undefined,
    n: usize = 0,
    side: bb.Color = 0,
};

fn addFeature(f: *Feats, pc: bb.Piece, sq: bb.Square) void {
    f.stm[f.n] = @intCast(nnue.featureIndex(f.side, pc, sq));
    f.nstm[f.n] = @intCast(nnue.featureIndex(f.side ^ 1, pc, sq));
    f.n += 1;
}

inline fn screlu(x: f32) f32 {
    const c = std.math.clamp(x, 0.0, 1.0);
    return c * c;
}

inline fn screluGrad(x: f32) f32 {
    return if (x > 0.0 and x < 1.0) 2.0 * x else 0.0;
}

inline fn sigmoid(x: f32) f32 {
    return 1.0 / (1.0 + @exp(-x));
}

const Trainer = struct {
    data: []const Record,
    params: []f32,
    m: []f32,
    v: []f32,
    grads: [][]f32,
    losses: []f64,
    threads: usize,
    wdl: f32,

    const Sample = struct {
        acc_s: [H]f32 align(64),
        acc_n: [H]f32 align(64),
        act_s: [H]f32 align(64),
        act_n: [H]f32 align(64),
        feats: Feats,
        bucket: usize,
        out: f32,
        target: f32,
    };

    fn forward(t: *const Trainer, rec: *const Record, s: *Sample) void {
        s.feats = .{ .side = @intCast(rec.stm) };
        rec.forEachPiece(&s.feats, addFeature);
        s.bucket = @min((s.feats.n -| 2) / 4, NB - 1);

        const ftb = t.params[OFF_FTB..][0..H];
        s.acc_s = ftb.*;
        s.acc_n = ftb.*;
        for (s.feats.stm[0..s.feats.n], s.feats.nstm[0..s.feats.n]) |fs, fnn| {
            const ws = t.params[OFF_FTW + @as(usize, fs) * H ..][0..H];
            const wn = t.params[OFF_FTW + @as(usize, fnn) * H ..][0..H];
            for (0..H) |j| {
                s.acc_s[j] += ws[j];
                s.acc_n[j] += wn[j];
            }
        }
        const ow = t.params[OFF_OW + s.bucket * 2 * H ..][0 .. 2 * H];
        var out: f32 = t.params[OFF_OB + s.bucket];
        for (0..H) |j| {
            s.act_s[j] = screlu(s.acc_s[j]);
            s.act_n[j] = screlu(s.acc_n[j]);
            out += ow[j] * s.act_s[j] + ow[H + j] * s.act_n[j];
        }
        s.out = out;

        const white_score: f32 = @floatFromInt(rec.score);
        const stm_score = if (rec.stm == bb.WHITE) white_score else -white_score;
        const white_result = @as(f32, @floatFromInt(rec.result)) / 2.0;
        const stm_result = if (rec.stm == bb.WHITE) white_result else 1.0 - white_result;
        s.target = (1.0 - t.wdl) * sigmoid(stm_score / nnue.SCALE) + t.wdl * stm_result;
    }

    /// Accumulates this sample's gradient into `grad`; returns its loss.
    fn backward(t: *const Trainer, s: *const Sample, grad: []f32) f64 {
        const pred = sigmoid(s.out);
        const err = pred - s.target;
        const g = 2.0 * err * pred * (1.0 - pred);

        grad[OFF_OB + s.bucket] += g;
        const ow = t.params[OFF_OW + s.bucket * 2 * H ..][0 .. 2 * H];
        const gow = grad[OFF_OW + s.bucket * 2 * H ..][0 .. 2 * H];
        var ds: [H]f32 align(64) = undefined;
        var dn: [H]f32 align(64) = undefined;
        for (0..H) |j| {
            gow[j] += g * s.act_s[j];
            gow[H + j] += g * s.act_n[j];
            ds[j] = g * ow[j] * screluGrad(s.acc_s[j]);
            dn[j] = g * ow[H + j] * screluGrad(s.acc_n[j]);
        }
        const gfb = grad[OFF_FTB..][0..H];
        for (0..H) |j| gfb[j] += ds[j] + dn[j];
        for (s.feats.stm[0..s.feats.n], s.feats.nstm[0..s.feats.n]) |fs, fnn| {
            const gs = grad[OFF_FTW + @as(usize, fs) * H ..][0..H];
            const gn = grad[OFF_FTW + @as(usize, fnn) * H ..][0..H];
            for (0..H) |j| {
                gs[j] += ds[j];
                gn[j] += dn[j];
            }
        }
        return err * err;
    }

    fn gradWorker(t: *Trainer, tid: usize, batch: []const u32) void {
        const grad = t.grads[tid];
        @memset(grad, 0);
        const lo = batch.len * tid / t.threads;
        const hi = batch.len * (tid + 1) / t.threads;
        var loss: f64 = 0;
        var s: Sample = undefined;
        for (batch[lo..hi]) |idx| {
            t.forward(&t.data[idx], &s);
            loss += t.backward(&s, grad);
        }
        t.losses[tid] = loss;
    }

    fn lossWorker(t: *Trainer, tid: usize, idxs: []const u32) void {
        const lo = idxs.len * tid / t.threads;
        const hi = idxs.len * (tid + 1) / t.threads;
        var loss: f64 = 0;
        var s: Sample = undefined;
        for (idxs[lo..hi]) |idx| {
            t.forward(&t.data[idx], &s);
            const e = sigmoid(s.out) - s.target;
            loss += e * e;
        }
        t.losses[tid] = loss;
    }

    const Adam = struct { lr: f32, bc1: f32, bc2: f32, inv_batch: f32 };

    fn adamWorker(t: *Trainer, tid: usize, a: Adam) void {
        const beta1: f32 = 0.9;
        const beta2: f32 = 0.999;
        const eps: f32 = 1e-8;
        const decay: f32 = 0.01;
        const lo = P * tid / t.threads;
        const hi = P * (tid + 1) / t.threads;
        for (lo..hi) |i| {
            var g: f32 = 0;
            for (t.grads) |gr| g += gr[i];
            g *= a.inv_batch;
            t.m[i] = beta1 * t.m[i] + (1 - beta1) * g;
            t.v[i] = beta2 * t.v[i] + (1 - beta2) * g * g;
            const mh = t.m[i] / a.bc1;
            const vh = t.v[i] / a.bc2;
            const w = t.params[i] - a.lr * (mh / (@sqrt(vh) + eps) + decay * t.params[i]);
            t.params[i] = std.math.clamp(w, -CLIP, CLIP);
        }
    }

    fn parallel(t: *Trainer, comptime f: anytype, extra: anytype) !void {
        var handles: [256]std.Thread = undefined;
        for (0..t.threads) |i| handles[i] = try std.Thread.spawn(.{}, f, .{ t, i, extra });
        for (handles[0..t.threads]) |h| h.join();
    }

    fn meanLoss(t: *Trainer, n: usize) f64 {
        var sum: f64 = 0;
        for (t.losses) |l| sum += l;
        return sum / @as(f64, @floatFromInt(@max(n, 1)));
    }
};

fn quantize(params: []const f32, net: *nnue.Network) void {
    const q = struct {
        fn f(x: f32, scale: f32) i16 {
            return @intFromFloat(std.math.clamp(@round(x * scale), -32767, 32767));
        }
    }.f;
    for (0..IN * H) |i| net.ft_w[i] = q(params[OFF_FTW + i], nnue.QA);
    for (0..H) |i| net.ft_b[i] = q(params[OFF_FTB + i], nnue.QA);
    for (0..NB) |b| {
        for (0..2 * H) |j| net.out_w[b][j] = q(params[OFF_OW + b * 2 * H + j], nnue.QB);
        net.out_b[b] = q(params[OFF_OB + b], nnue.QA * nnue.QB);
    }
}

fn saveNet(gpa: std.mem.Allocator, io: Io, params: []const f32, path: []const u8) !void {
    const net = try gpa.create(nnue.Network);
    defer gpa.destroy(net);
    quantize(params, net);
    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var w = f.writer(io, &buf);
    try net.writeTo(&w.interface);
    try w.interface.flush();
}

fn saveCheckpoint(io: Io, params: []const f32, path: []const u8) !void {
    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var header: [12]u8 = undefined;
    @memcpy(header[0..4], CKPT_MAGIC);
    std.mem.writeInt(u32, header[4..8], H, .little);
    std.mem.writeInt(u32, header[8..12], P, .little);
    try f.writePositionalAll(io, &header, 0);
    try f.writePositionalAll(io, std.mem.sliceAsBytes(params), header.len);
}

fn loadCheckpoint(gpa: std.mem.Allocator, io: Io, path: []const u8, params: []f32) !void {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(12 + P * 4 + 1));
    defer gpa.free(bytes);
    if (bytes.len != 12 + P * 4 or !std.mem.eql(u8, bytes[0..4], CKPT_MAGIC) or
        std.mem.readInt(u32, bytes[8..12], .little) != P) return error.BadCheckpoint;
    @memcpy(std.mem.sliceAsBytes(params), bytes[12..]);
}

/// Mean absolute difference (centipawns) between the float network and the
/// quantised integer network the engine will actually run.
fn quantisationError(gpa: std.mem.Allocator, t: *const Trainer, idxs: []const u32) !f64 {
    const net = try gpa.create(nnue.Network);
    defer gpa.destroy(net);
    quantize(t.params, net);
    var sum: f64 = 0;
    var s: Trainer.Sample = undefined;
    for (idxs) |i| {
        t.forward(&t.data[i], &s);
        const pos = t.data[i].toPosition();
        const q = nnue.evaluateFresh(net, &pos);
        sum += @abs(@as(f64, s.out * nnue.SCALE) - @as(f64, @floatFromInt(q)));
    }
    return sum / @as(f64, @floatFromInt(@max(idxs.len, 1)));
}

pub fn run(gpa: std.mem.Allocator, io: Io, out: *Output, args: []const [:0]const u8) !void {
    var p = cli.Parser{ .args = args };
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);
    var out_path: []const u8 = "";
    var epochs: usize = 10;
    var batch_size: usize = 16384;
    var lr: f32 = 0.001;
    var wdl: f32 = 0.1;
    var threads: usize = std.Thread.getCpuCount() catch 4;
    var init_path: []const u8 = "";
    var seed: u64 = 1;
    while (p.next()) |a| {
        if (p.flag(a, "--data")) |v| {
            var it = std.mem.tokenizeScalar(u8, v, ',');
            while (it.next()) |path| try paths.append(gpa, path);
        } else if (p.flag(a, "--out")) |v| out_path = v
        else if (p.int(usize, a, "--epochs")) |v| epochs = @max(v, 1)
        else if (p.int(usize, a, "--batch")) |v| batch_size = @max(v, 64)
        else if (p.float(a, "--lr")) |v| lr = v
        else if (p.float(a, "--wdl")) |v| wdl = v
        else if (p.int(usize, a, "--threads")) |v| threads = std.math.clamp(v, 1, 256)
        else if (p.flag(a, "--init")) |v| init_path = v
        else if (p.int(u64, a, "--seed")) |v| seed = v
        else {
            out.print("{s}", .{help});
            return;
        }
    }
    if (paths.items.len == 0 or out_path.len == 0) {
        out.print("{s}", .{help});
        return;
    }

    // Load every data file into one contiguous array.
    var total: usize = 0;
    for (paths.items) |path| {
        const st = try Io.Dir.cwd().statFile(io, path, .{});
        total += st.size / @sizeOf(Record);
    }
    if (total < batch_size * 2) {
        out.print("not enough data: {d} positions\n", .{total});
        return error.NotEnoughData;
    }
    const data = try gpa.alloc(Record, total);
    defer gpa.free(data);
    var filled: usize = 0;
    for (paths.items) |path| {
        const f = try Io.Dir.cwd().openFile(io, path, .{});
        defer f.close(io);
        const n = (try f.length(io)) / @sizeOf(Record);
        const got = try f.readPositionalAll(io, std.mem.sliceAsBytes(data[filled..][0..n]), 0);
        filled += got / @sizeOf(Record);
        out.print("loaded {d} positions from {s}\n", .{ n, path });
    }

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    const idx = try gpa.alloc(u32, filled);
    defer gpa.free(idx);
    for (idx, 0..) |*x, i| x.* = @intCast(i);
    rng.shuffle(u32, idx);
    const val_n = @min(filled / 100, 100_000);
    const train_idx = idx[0 .. filled - val_n];
    const val_idx = idx[filled - val_n ..];

    const params = try gpa.alloc(f32, P);
    defer gpa.free(params);
    const m = try gpa.alloc(f32, P);
    defer gpa.free(m);
    const v = try gpa.alloc(f32, P);
    defer gpa.free(v);
    @memset(m, 0);
    @memset(v, 0);
    if (init_path.len > 0) {
        try loadCheckpoint(gpa, io, init_path, params);
        out.print("initialised from {s}\n", .{init_path});
    } else {
        @memset(params, 0);
        for (params[OFF_FTW..OFF_FTB]) |*x| x.* = (rng.float(f32) * 2 - 1) * 0.1;
        for (params[OFF_OW..OFF_OB]) |*x| x.* = (rng.float(f32) * 2 - 1) * 0.05;
    }

    const grads = try gpa.alloc([]f32, threads);
    defer gpa.free(grads);
    for (grads) |*g| g.* = try gpa.alloc(f32, P);
    defer for (grads) |g| gpa.free(g);
    const losses = try gpa.alloc(f64, threads);
    defer gpa.free(losses);

    var t = Trainer{ .data = data[0..filled], .params = params, .m = m, .v = v, .grads = grads, .losses = losses, .threads = threads, .wdl = wdl };

    const ckpt_path = try std.fmt.allocPrint(gpa, "{s}.ckpt", .{out_path});
    defer gpa.free(ckpt_path);

    const steps_per_epoch = train_idx.len / batch_size;
    const total_steps = steps_per_epoch * epochs;
    out.print("training {d}->{d}x2->1 ({d} buckets) on {d} positions ({d} validation), {d} epochs x {d} batches, {d} threads\n", .{
        IN, H, NB, train_idx.len, val_n, epochs, steps_per_epoch, threads,
    });

    try t.parallel(Trainer.lossWorker, @as([]const u32, val_idx));
    out.print("initial validation loss {d:.6}\n", .{t.meanLoss(val_n)});

    var step: usize = 0;
    const t0 = Io.Clock.awake.now(io);
    for (0..epochs) |epoch| {
        rng.shuffle(u32, train_idx);
        var epoch_loss: f64 = 0;
        for (0..steps_per_epoch) |b| {
            const batch: []const u32 = train_idx[b * batch_size ..][0..batch_size];
            try t.parallel(Trainer.gradWorker, batch);
            var batch_loss: f64 = 0;
            for (losses) |l| batch_loss += l;
            epoch_loss += batch_loss;

            step += 1;
            const progress = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(total_steps));
            const lr_min = lr * 0.02;
            const lr_now = lr_min + 0.5 * (lr - lr_min) * (1 + @cos(std.math.pi * progress));
            const st: f32 = @floatFromInt(step);
            try t.parallel(Trainer.adamWorker, Trainer.Adam{
                .lr = lr_now,
                .bc1 = 1 - std.math.pow(f32, 0.9, st),
                .bc2 = 1 - std.math.pow(f32, 0.999, st),
                .inv_batch = 1.0 / @as(f32, @floatFromInt(batch_size)),
            });

            if (b % 50 == 49 or b + 1 == steps_per_epoch) {
                const ms = @max(t0.durationTo(Io.Clock.awake.now(io)).toMilliseconds(), 1);
                const pps = @divTrunc(@as(i64, @intCast(step * batch_size)) * 1000, ms);
                out.print("\repoch {d}/{d} batch {d}/{d} loss {d:.6} lr {e:.2} {d} pos/s   ", .{
                    epoch + 1, epochs, b + 1, steps_per_epoch, epoch_loss / @as(f64, @floatFromInt((b + 1) * batch_size)), lr_now, pps,
                });
            }
        }
        try t.parallel(Trainer.lossWorker, @as([]const u32, val_idx));
        const val = t.meanLoss(val_n);
        try saveNet(gpa, io, params, out_path);
        try saveCheckpoint(io, params, ckpt_path);
        const diff = try quantisationError(gpa, &t, val_idx[0..@min(val_idx.len, 2000)]);
        out.print("\nepoch {d}: quantised vs float eval: mean |diff| {d:.2} cp\n", .{ epoch + 1, diff });
        out.print("epoch {d}: train loss {d:.6}  validation loss {d:.6}  -> {s}\n", .{
            epoch + 1, epoch_loss / @as(f64, @floatFromInt(steps_per_epoch * batch_size)), val, out_path,
        });
    }
}
