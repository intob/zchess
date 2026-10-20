//! NNUE trainer in plain Zig. Float32 forward/backward passes, AdamW,
//! data-parallel over all cores, cosine learning-rate decay, and quantised
//! export in the format `nnue.zig` loads.
//!
//! Loss: |sigmoid(out) - target|^power (power 2 by default) with
//!   target = (1 - wdl) * sigmoid(score / SCALE) + wdl * game_result
//! both from the side to move's point of view.

const std = @import("std");
const Io = std.Io;
const bb = @import("bitboard.zig");
const nnue = @import("nnue.zig");
const cli = @import("cli.zig");
const Record = @import("data.zig").Record;
const movegen = @import("movegen.zig");
const search = @import("search.zig");
const Output = @import("output.zig").Output;

const IN = nnue.INPUTS;
const H = nnue.HIDDEN;
const NB = nnue.BUCKETS;

const OFF_FTW = 0;
const OFF_FTB = OFF_FTW + IN * H;
const OFF_OW = OFF_FTB + H;
const OFF_OB = OFF_OW + NB * 2 * H;
const P = OFF_OB + NB;

/// Factoriser, in builds with more than one king bucket: one more 768 x H
/// block of feature weights that every bucket shares. A bucket's weight is its
/// own plus the shared one, so the shared part learns from every position and
/// each bucket only learns how its king squares differ (8 buckets without it
/// memorised gen7w's data). The passes run on the merged weights, and the
/// shared block's gradient is the sum of the buckets'. Nets are exported
/// merged, so the engine never sees it; checkpoints keep it.
const FACTOR = nnue.KING_BUCKETS > 1;
const FAC_N = if (FACTOR) 768 * H else 0;
const OFF_FAC = P;
const P_ALL = P + FAC_N;

const CLIP = 1.98;
/// Int8 feature weights (-Dft8) hold at most 127 / QA.
const FT_CLIP: f32 = if (nnue.FT8) 127.0 / @as(f32, nnue.QA) else CLIP;
const CKPT_MAGIC = "ZCCK";

const help =
    \\usage: zchess train --data <file>[,<file>...] --out <net.nnue> [options]
    \\
    \\  --data <files>     comma-separated datagen files (may repeat)
    \\  --out <file>       quantised network output (a .ckpt float checkpoint is written next to it)
    \\  --epochs <n>       passes over the data (default 10); 0 with --init just
    \\                     quantises that checkpoint into this build's net format
    \\  --batch <n>        positions per batch (default 16384)
    \\  --lr <x>           initial learning rate, cosine-decayed to 2% (default 0.001)
    \\  --wdl <x>          weight of game result vs. search score in the target (default 0.1)
    \\  --power <x>        loss exponent: |prediction - target|^x (default 2)
    \\  --threads <n>      worker threads (default: all cores)
    \\  --test <files>     comma-separated held-out positions, scored after every epoch
    \\                     and never trained on (e.g. a later generation's games)
    \\  --init <ckpt>      start from a float checkpoint instead of random weights
    \\  --seed <n>         shuffle/initialisation seed (default 1)
    \\  --quiet-only       train on quiet positions only: not in check, and no capture
    \\                     winning material for the side to move (their static eval
    \\                     is what the search score says; noisy ones it isn't)
    \\
;

/// Whether a training position is quiet: the side to move isn't in check
/// and has no capture that wins material (static exchange > 0).
fn isQuiet(r: *const Record) bool {
    const pos = r.toPosition();
    if (pos.inCheck()) return false;
    var list = movegen.MoveList{};
    movegen.generate(&pos, &list, .noisy);
    for (list.slice()) |m| if (m.isCapture() and search.see(&pos, m, 1)) return false;
    return true;
}

/// --quiet-only: drops the positions that aren't quiet, in place and in
/// order (so games stay contiguous for the validation split). Returns how
/// many are left.
fn keepQuiet(gpa: std.mem.Allocator, data: []Record, threads: usize) !usize {
    const keep = try gpa.alloc(bool, data.len);
    defer gpa.free(keep);
    const Work = struct {
        fn run(d: []const Record, k: []bool) void {
            for (d, k) |*r, *x| x.* = isQuiet(r);
        }
    };
    const n_threads = @max(threads, 1);
    const chunk = (data.len + n_threads - 1) / n_threads;
    var handles: [256]?std.Thread = .{null} ** 256;
    for (0..n_threads) |t| {
        const lo = @min(t * chunk, data.len);
        const hi = @min(lo + chunk, data.len);
        if (lo == hi) continue;
        handles[t] = std.Thread.spawn(.{}, Work.run, .{ data[lo..hi], keep[lo..hi] }) catch blk: {
            Work.run(data[lo..hi], keep[lo..hi]);
            break :blk null;
        };
    }
    for (handles[0..n_threads]) |h| if (h) |t| t.join();
    var n: usize = 0;
    for (data, keep) |r, k| {
        if (!k) continue;
        data[n] = r;
        n += 1;
    }
    return n;
}

const Feats = struct {
    stm: [32]u16 = undefined,
    nstm: [32]u16 = undefined,
    n: usize = 0,
    side: bb.Color = 0,
    pcs: [32]bb.Piece = undefined,
    sqs: [32]bb.Square = undefined,
    ksq: [2]bb.Square = .{ 0, 0 },

    fn collect(f: *Feats, pc: bb.Piece, sq: bb.Square) void {
        f.pcs[f.n] = pc;
        f.sqs[f.n] = sq;
        if (bb.pieceType(pc) == bb.KING) f.ksq[bb.pieceColor(pc)] = sq;
        f.n += 1;
    }

    fn fromRecord(rec: *const Record) Feats {
        var f = Feats{ .side = @intCast(rec.stm) };
        rec.forEachPiece(&f, collect);
        const vs = nnue.kingView(f.side, f.ksq[f.side]);
        const vn = nnue.kingView(f.side ^ 1, f.ksq[f.side ^ 1]);
        for (0..f.n) |i| {
            f.stm[i] = @intCast(nnue.featureIndex(f.side, vs, f.pcs[i], f.sqs[i]));
            f.nstm[i] = @intCast(nnue.featureIndex(f.side ^ 1, vn, f.pcs[i], f.sqs[i]));
        }
        return f;
    }
};

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
    /// The feature weights the passes use: the merged ones with the
    /// factoriser, otherwise params' own.
    ftw: []f32,
    m: []f32,
    v: []f32,
    grads: [][]f32,
    losses: []f64,
    threads: usize,
    wdl: f32,
    power: f32,

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
        s.feats = Feats.fromRecord(rec);
        s.bucket = @min((s.feats.n -| 2) / 4, NB - 1);

        const ftb = t.params[OFF_FTB..][0..H];
        s.acc_s = ftb.*;
        s.acc_n = ftb.*;
        for (s.feats.stm[0..s.feats.n], s.feats.nstm[0..s.feats.n]) |fs, fnn| {
            const ws = t.ftw[@as(usize, fs) * H ..][0..H];
            const wn = t.ftw[@as(usize, fnn) * H ..][0..H];
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
        const g = t.power * std.math.sign(err) * std.math.pow(f32, @abs(err), t.power - 1) * pred * (1.0 - pred);

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
        return t.lossOf(err);
    }

    inline fn lossOf(t: *const Trainer, err: f32) f64 {
        return if (t.power == 2.0) err * err else std.math.pow(f32, @abs(err), t.power);
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
            loss += t.lossOf(sigmoid(s.out) - s.target);
        }
        t.losses[tid] = loss;
    }

    const Adam = struct { lr: f32, bc1: f32, bc2: f32, inv_batch: f32 };

    fn adamWorker(t: *Trainer, tid: usize, a: Adam) void {
        const beta1: f32 = 0.9;
        const beta2: f32 = 0.999;
        const eps: f32 = 1e-8;
        const decay: f32 = 0.01;
        const lo = P_ALL * tid / t.threads;
        const hi = P_ALL * (tid + 1) / t.threads;
        for (lo..hi) |i| {
            var g: f32 = 0;
            if (i < P) {
                for (t.grads) |gr| g += gr[i];
            } else {
                // A shared weight: every bucket's gradient for its feature.
                const f = i - OFF_FAC;
                for (t.grads) |gr| for (0..nnue.KING_BUCKETS) |b| {
                    g += gr[OFF_FTW + b * FAC_N + f];
                };
            }
            g *= a.inv_batch;
            t.m[i] = beta1 * t.m[i] + (1 - beta1) * g;
            t.v[i] = beta2 * t.v[i] + (1 - beta2) * g * g;
            const mh = t.m[i] / a.bc1;
            const vh = t.v[i] / a.bc2;
            const w = t.params[i] - a.lr * (mh / (@sqrt(vh) + eps) + decay * t.params[i]);
            if (FACTOR and i < OFF_FTB) {
                t.params[i] = w; // mergeWorker keeps the merged weight in range
            } else {
                const clip = if (i < OFF_FTB or i >= OFF_FAC) FT_CLIP else CLIP;
                t.params[i] = std.math.clamp(w, -clip, clip);
            }
        }
    }

    /// Factoriser: ftw = bucket + shared weights, each bucket weight clamped
    /// so that the merged one, which the export quantises, stays in range.
    fn mergeWorker(t: *Trainer, tid: usize, _: void) void {
        const lo = IN * H * tid / t.threads;
        const hi = IN * H * (tid + 1) / t.threads;
        for (lo..hi) |i| {
            const s = t.params[OFF_FAC + i % FAC_N];
            const b = std.math.clamp(t.params[OFF_FTW + i], -FT_CLIP - s, FT_CLIP - s);
            t.params[OFF_FTW + i] = b;
            t.ftw[i] = b + s;
        }
    }

    /// Brings ftw up to date with params (after a step or a load).
    fn merge(t: *Trainer) !void {
        if (FACTOR) try t.parallel(Trainer.mergeWorker, {});
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

/// `ftw` is the (merged) feature weights, Trainer.ftw.
fn quantize(ftw: []const f32, params: []const f32, net: *nnue.Network) void {
    const q = struct {
        fn f(comptime T: type, x: f32, scale: f32) T {
            const lim: f32 = std.math.maxInt(T);
            return @intFromFloat(std.math.clamp(@round(x * scale), -lim, lim));
        }
    }.f;
    for (0..IN * H) |i| net.ft_w[i] = q(nnue.FtW, ftw[i], nnue.QA);
    for (0..H) |i| net.ft_b[i] = q(i16, params[OFF_FTB + i], nnue.QA);
    for (0..NB) |b| {
        for (0..2 * H) |j| net.out_w[b][j] = q(i16, params[OFF_OW + b * 2 * H + j], nnue.QB);
        net.out_b[b] = q(i16, params[OFF_OB + b], nnue.QA * nnue.QB);
    }
}

fn saveNet(gpa: std.mem.Allocator, io: Io, t: *const Trainer, path: []const u8) !void {
    const net = try gpa.create(nnue.Network);
    defer gpa.destroy(net);
    quantize(t.ftw, t.params, net);
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
    std.mem.writeInt(u32, header[8..12], P_ALL, .little);
    try f.writePositionalAll(io, &header, 0);
    try f.writePositionalAll(io, std.mem.sliceAsBytes(params), header.len);
}

fn loadCheckpoint(gpa: std.mem.Allocator, io: Io, path: []const u8, params: []f32) !void {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(12 + P_ALL * 4 + 1));
    defer gpa.free(bytes);
    if (bytes.len != 12 + P_ALL * 4 or !std.mem.eql(u8, bytes[0..4], CKPT_MAGIC) or
        std.mem.readInt(u32, bytes[8..12], .little) != P_ALL) return error.BadCheckpoint;
    @memcpy(std.mem.sliceAsBytes(params), bytes[12..]);
}

/// Reads a datagen file into the start of `dst`; returns the positions read.
fn readRecords(io: Io, path: []const u8, dst: []Record) !usize {
    const f = try Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const n = (try f.length(io)) / @sizeOf(Record);
    // In chunks: macOS rejects a single read of 2 GiB or more.
    const bytes = std.mem.sliceAsBytes(dst[0..n]);
    var off: usize = 0;
    while (off < bytes.len) {
        const want = @min(bytes.len - off, 1 << 30);
        const got = try f.readPositionalAll(io, bytes[off..][0..want], off);
        off += got;
        if (got < want) break;
    }
    return off / @sizeOf(Record);
}

fn positionsIn(io: Io, paths: []const []const u8) !usize {
    var total: usize = 0;
    for (paths) |path| {
        const st = try Io.Dir.cwd().statFile(io, path, .{});
        total += st.size / @sizeOf(Record);
    }
    return total;
}

/// Mean absolute difference (centipawns) between the float network and the
/// quantised integer network the engine will actually run.
fn quantisationError(gpa: std.mem.Allocator, t: *const Trainer, idxs: []const u32) !f64 {
    const net = try gpa.create(nnue.Network);
    defer gpa.destroy(net);
    quantize(t.ftw, t.params, net);
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
    var test_paths: std.ArrayList([]const u8) = .empty;
    defer test_paths.deinit(gpa);
    var out_path: []const u8 = "";
    var epochs: usize = 10;
    var batch_size: usize = 16384;
    var lr: f32 = 0.001;
    var wdl: f32 = 0.1;
    var power: f32 = 2.0;
    var threads: usize = std.Thread.getCpuCount() catch 4;
    var init_path: []const u8 = "";
    var seed: u64 = 1;
    var quiet_only = false;
    while (p.next()) |a| {
        if (std.mem.eql(u8, a, "--quiet-only")) {
            quiet_only = true;
            continue;
        }
        if (p.flag(a, "--data")) |v| {
            var it = std.mem.tokenizeScalar(u8, v, ',');
            while (it.next()) |path| try paths.append(gpa, path);
        } else if (p.flag(a, "--test")) |v| {
            var it = std.mem.tokenizeScalar(u8, v, ',');
            while (it.next()) |path| try test_paths.append(gpa, path);
        } else if (p.flag(a, "--out")) |v| out_path = v
        else if (p.int(usize, a, "--epochs")) |v| epochs = v
        else if (p.int(usize, a, "--batch")) |v| batch_size = @max(v, 64)
        else if (p.float(a, "--lr")) |v| lr = v
        else if (p.float(a, "--wdl")) |v| wdl = v
        else if (p.float(a, "--power")) |v| power = std.math.clamp(v, 1.0, 4.0)
        else if (p.int(usize, a, "--threads")) |v| threads = std.math.clamp(v, 1, 256)
        else if (p.flag(a, "--init")) |v| init_path = v
        else if (p.int(u64, a, "--seed")) |v| seed = v
        else {
            out.print("{s}", .{help});
            return;
        }
    }
    if (paths.items.len == 0 or out_path.len == 0 or (epochs == 0 and init_path.len == 0)) {
        out.print("{s}", .{help});
        return;
    }

    // Load every data file into one contiguous array, the test positions last.
    const total = try positionsIn(io, paths.items);
    if (total < batch_size * 2) {
        out.print("not enough data: {d} positions\n", .{total});
        return error.NotEnoughData;
    }
    const total_test = try positionsIn(io, test_paths.items);
    // Mapped directly rather than through gpa: Zig 0.16's PageAllocator hints
    // each mapping just below the previous one, and for a buffer larger than
    // that address (> 4 GiB on macOS) the hint wraps and mmap fails.
    const mapped = try std.posix.mmap(null, (total + total_test) * @sizeOf(Record), .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    defer std.posix.munmap(mapped);
    const data = std.mem.bytesAsSlice(Record, mapped);
    var filled: usize = 0;
    for (paths.items) |path| {
        const n = try readRecords(io, path, data[filled..]);
        filled += n;
        out.print("loaded {d} positions from {s}\n", .{ n, path });
    }

    if (quiet_only) {
        const before = filled;
        filled = try keepQuiet(gpa, data[0..filled], threads);
        out.print("quiet only: kept {d} of {d} positions ({d:.1}%)\n", .{ filled, before, 100 * @as(f64, @floatFromInt(filled)) / @as(f64, @floatFromInt(@max(before, 1))) });
    }

    // Test positions: after the training ones, outside the training and
    // validation split, scored with the same loss.
    var n_test: usize = 0;
    for (test_paths.items) |path| {
        const n = try readRecords(io, path, data[filled + n_test ..]);
        n_test += n;
        out.print("loaded {d} test positions from {s}\n", .{ n, path });
    }
    const test_idx = try gpa.alloc(u32, n_test);
    defer gpa.free(test_idx);
    for (test_idx, 0..) |*x, i| x.* = @intCast(filled + i);

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    // Validation: whole games, so no validation position shares a game with
    // the training positions (neighbouring positions of one game are nearly
    // the same, and a net that memorises games would look good). A game's
    // positions are contiguous; the next game starts where the ply count
    // stops increasing or the result changes.
    var starts: std.ArrayList(u32) = .empty;
    defer starts.deinit(gpa);
    for (0..filled) |i| {
        if (i == 0 or data[i].ply <= data[i - 1].ply or data[i].result != data[i - 1].result) try starts.append(gpa, @intCast(i));
    }
    try starts.append(gpa, @intCast(filled));
    const n_games = starts.items.len - 1;
    const order = try gpa.alloc(u32, n_games);
    defer gpa.free(order);
    for (order, 0..) |*x, i| x.* = @intCast(i);
    rng.shuffle(u32, order);
    var is_val = try std.DynamicBitSetUnmanaged.initEmpty(gpa, filled);
    defer is_val.deinit(gpa);
    const val_target = @min(filled / 100, 100_000);
    var val_n: usize = 0;
    var val_games: usize = 0;
    for (order) |g| {
        if (val_n >= val_target) break;
        const lo = starts.items[g];
        const hi = starts.items[g + 1];
        is_val.setRangeValue(.{ .start = lo, .end = hi }, true);
        val_n += hi - lo;
        val_games += 1;
    }
    const idx = try gpa.alloc(u32, filled);
    defer gpa.free(idx);
    var n_train: usize = 0;
    var n_v: usize = filled - val_n;
    for (0..filled) |i| {
        if (is_val.isSet(i)) {
            idx[n_v] = @intCast(i);
            n_v += 1;
        } else {
            idx[n_train] = @intCast(i);
            n_train += 1;
        }
    }
    const train_idx = idx[0..n_train];
    const val_idx = idx[n_train..];
    rng.shuffle(u32, train_idx);
    rng.shuffle(u32, val_idx);
    out.print("validation: {d} positions from {d} whole games (of {d})\n", .{ val_n, val_games, n_games });

    const params = try gpa.alloc(f32, P_ALL);
    defer gpa.free(params);
    const m = try gpa.alloc(f32, P_ALL);
    defer gpa.free(m);
    const v = try gpa.alloc(f32, P_ALL);
    defer gpa.free(v);
    @memset(m, 0);
    @memset(v, 0);
    if (init_path.len > 0) {
        try loadCheckpoint(gpa, io, init_path, params);
        out.print("initialised from {s}\n", .{init_path});
    } else {
        @memset(params, 0);
        // With the factoriser the buckets start equal (at zero) and the shared
        // block takes the random start.
        const ft_init = if (FACTOR) params[OFF_FAC..P_ALL] else params[OFF_FTW..OFF_FTB];
        for (ft_init) |*x| x.* = (rng.float(f32) * 2 - 1) * 0.1;
        for (params[OFF_OW..OFF_OB]) |*x| x.* = (rng.float(f32) * 2 - 1) * 0.05;
    }
    const ftw = if (FACTOR) try gpa.alloc(f32, IN * H) else params[OFF_FTW..OFF_FTB];
    defer if (FACTOR) gpa.free(ftw);

    const grads = try gpa.alloc([]f32, threads);
    defer gpa.free(grads);
    for (grads) |*g| g.* = try gpa.alloc(f32, P);
    defer for (grads) |g| gpa.free(g);
    const losses = try gpa.alloc(f64, threads);
    defer gpa.free(losses);

    var t = Trainer{ .data = data[0 .. filled + n_test], .params = params, .ftw = ftw, .m = m, .v = v, .grads = grads, .losses = losses, .threads = threads, .wdl = wdl, .power = power };
    try t.merge();

    const ckpt_path = try std.fmt.allocPrint(gpa, "{s}.ckpt", .{out_path});
    defer gpa.free(ckpt_path);

    const steps_per_epoch = train_idx.len / batch_size;
    const total_steps = steps_per_epoch * epochs;
    out.print("training {d}->{d}x2->1 ({d} king buckets{s}, {d} output buckets, loss power {d}) on {d} positions ({d} validation, {d} test), {d} epochs x {d} batches, {d} threads\n", .{
        IN, H, nnue.KING_BUCKETS, if (FACTOR) " factorised" else "", NB, power, train_idx.len, val_n, n_test, epochs, steps_per_epoch, threads,
    });

    try t.parallel(Trainer.lossWorker, @as([]const u32, val_idx));
    out.print("initial validation loss {d:.6}\n", .{t.meanLoss(val_n)});
    if (n_test > 0) out.print("initial test loss {d:.6}\n", .{try testLoss(&t, test_idx)});
    if (epochs == 0) {
        try saveNet(gpa, io, &t, out_path);
        const diff = try quantisationError(gpa, &t, val_idx[0..@min(val_idx.len, 2000)]);
        out.print("quantised {s} -> {s}: vs float eval mean |diff| {d:.2} cp\n", .{ init_path, out_path, diff });
        return;
    }

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
            try t.merge();

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
        try saveNet(gpa, io, &t, out_path);
        try saveCheckpoint(io, params, ckpt_path);
        const diff = try quantisationError(gpa, &t, val_idx[0..@min(val_idx.len, 2000)]);
        out.print("\nepoch {d}: quantised vs float eval: mean |diff| {d:.2} cp\n", .{ epoch + 1, diff });
        out.print("epoch {d}: train loss {d:.6}  validation loss {d:.6}  -> {s}\n", .{
            epoch + 1, epoch_loss / @as(f64, @floatFromInt(steps_per_epoch * batch_size)), val, out_path,
        });
        if (n_test > 0) out.print("epoch {d}: test loss {d:.6}\n", .{ epoch + 1, try testLoss(&t, test_idx) });
    }
}

fn testLoss(t: *Trainer, test_idx: []const u32) !f64 {
    try t.parallel(Trainer.lossWorker, test_idx);
    return t.meanLoss(test_idx.len);
}
