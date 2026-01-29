const std = @import("std");
const c = @cImport({
    @cInclude("libdill.h");
    @cInclude("dill_zig.h");
});

// ============================================================================
// Types
// ============================================================================

const Job = extern struct {
    id: i32,
    value: i32,
};

const Result = extern struct {
    job_id: i32,
    worker_id: i32,
    output: i32,
};

const WorkerCtx = extern struct {
    job_ch: c_int,
    result_ch: c_int,
    worker_id: i32,
};

const ProducerCtx = extern struct {
    job_ch: c_int,
    num_jobs: i32,
};

// ============================================================================
// Worker coroutine
// ============================================================================

fn worker(arg: ?*anyopaque) callconv(.c) void {
    const ctx: *WorkerCtx = @ptrCast(@alignCast(arg));
    std.debug.print("worker {}: started\n", .{ctx.worker_id});

    while (true) {
        var job: Job = undefined;
        const rc = c.chrecv(ctx.job_ch, &job, @sizeOf(Job), -1);
        if (rc != 0) {
            // EPIPE means channel closed via chdone()
            std.debug.print("worker {}: channel closed, exiting\n", .{ctx.worker_id});
            break;
        }

        // Simulate work
        _ = c.msleep(c.now() + 50);

        const result = Result{
            .job_id = job.id,
            .worker_id = ctx.worker_id,
            .output = job.value * job.value,
        };

        std.debug.print("worker {}: job {} ({}) -> {}\n", .{
            ctx.worker_id,
            job.id,
            job.value,
            result.output,
        });

        _ = c.chsend(ctx.result_ch, &result, @sizeOf(Result), -1);
    }
}

// ============================================================================
// Producer coroutine
// ============================================================================

fn producer(arg: ?*anyopaque) callconv(.c) void {
    const ctx: *ProducerCtx = @ptrCast(@alignCast(arg));

    for (0..@intCast(ctx.num_jobs)) |i| {
        const job = Job{
            .id = @intCast(i),
            .value = @intCast(i + 1),
        };
        _ = c.chsend(ctx.job_ch, &job, @sizeOf(Job), -1);
        std.debug.print("sent job {}\n", .{i});
    }

    // Broadcast: no more jobs
    _ = c.chdone(ctx.job_ch);
    std.debug.print("producer: done, closed channel\n", .{});
}

// ============================================================================
// Fan-out/Fan-in demo
// ============================================================================

fn fanOutFanIn() void {
    std.debug.print("=== Fan-out/Fan-in Demo ===\n\n", .{});

    const num_workers = 3;
    const num_jobs = 10;

    // Create job channel
    var job_ch: [2]c_int = undefined;
    if (c.chmake(&job_ch) != 0) {
        std.debug.print("failed to create job channel\n", .{});
        return;
    }
    defer {
        _ = c.hclose(job_ch[0]);
        _ = c.hclose(job_ch[1]);
    }

    // Create result channel
    var result_ch: [2]c_int = undefined;
    if (c.chmake(&result_ch) != 0) {
        std.debug.print("failed to create result channel\n", .{});
        return;
    }
    defer {
        _ = c.hclose(result_ch[0]);
        _ = c.hclose(result_ch[1]);
    }

    // Worker contexts
    var worker_contexts: [num_workers]WorkerCtx = undefined;

    // Spawn workers
    for (0..num_workers) |i| {
        worker_contexts[i] = WorkerCtx{
            .job_ch = job_ch[1],
            .result_ch = result_ch[0],
            .worker_id = @intCast(i),
        };

        const h = c.dill_zig_go(&worker, &worker_contexts[i]);
        if (h < 0) {
            std.debug.print("failed to spawn worker {}\n", .{i});
            return;
        }
    }

    std.debug.print("spawned {} workers\n\n", .{num_workers});

    // Spawn producer
    var producer_ctx = ProducerCtx{
        .job_ch = job_ch[0],
        .num_jobs = num_jobs,
    };
    if (c.dill_zig_go(&producer, &producer_ctx) < 0) {
        std.debug.print("failed to spawn producer\n", .{});
        return;
    }

    // Collect results
    var sum: i32 = 0;
    for (0..num_jobs) |_| {
        var result: Result = undefined;
        _ = c.chrecv(result_ch[1], &result, @sizeOf(Result), -1);
        std.debug.print("collected: job {} from worker {} = {}\n", .{
            result.job_id,
            result.worker_id,
            result.output,
        });
        sum += result.output;
    }

    std.debug.print("\nsum of squares (1^2 + 2^2 + ... + 10^2): {}\n", .{sum});
}

// ============================================================================
// Main
// ============================================================================

pub fn main() void {
    fanOutFanIn();
    std.debug.print("\ndone\n", .{});
}
