const std = @import("std");
const TestIo = @import("../test_utils.zig").TestIo;

const log = std.log.scoped(.Jobs);

pub const JobStatus = enum(u8) {
    pending = 0,
    running = 1,
    completed = 2,
    failed = 3,
    cancelled = 4,

    pub fn isTerminal(self: JobStatus) bool {
        return self == .completed or self == .failed or self == .cancelled;
    }
};

pub const JobResult = union(enum) {
    success: []const u8,
    failure: []const u8,
    cancelled: void,

    pub fn isSuccess(self: JobResult) bool {
        return self == .success;
    }
};

pub const JobProgress = struct {
    percent: u8,
    message: ?[]const u8,
    cancelled: *std.atomic.Value(bool),

    pub fn update(self: *JobProgress, percent: u8, msg: ?[]const u8) void {
        self.percent = if (percent > 100) 100 else percent;
        self.message = msg;
    }

    pub fn isCancelled(self: *JobProgress) bool {
        return self.cancelled.load(.acquire);
    }
};

pub const Job = struct {
    id: u64,
    name: []const u8,
    status: std.atomic.Value(JobStatus),
    progress: u8,
    progress_message: ?[]const u8,
    result: ?JobResult,
    start_time: i64,
    end_time: ?i64,
    /// Heap-allocated so that ArrayList resizes don't invalidate the pointer
    /// held by an in-flight JobProgress.
    cancelled: *std.atomic.Value(bool),
};

pub const JobFn = *const fn (ctx: *anyopaque, progress: *JobProgress, allocator: std.mem.Allocator) anyerror![]const u8;

const JobWrapper = struct {
    manager: *JobManager,
    job_id: u64,
    func: JobFn,
    ctx: *anyopaque,
};

pub const JobManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    jobs: std.ArrayListUnmanaged(Job),
    next_id: u64,
    mutex: std.Io.Mutex,
    completed_results: std.ArrayListUnmanaged(struct { id: u64, result: JobResult }),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) JobManager {
        return JobManager{
            .allocator = allocator,
            .io = io,
            .jobs = .empty,
            .next_id = 1,
            .mutex = .init,
            .completed_results = .empty,
        };
    }

    inline fn lock(self: *JobManager) void {
        self.mutex.lockUncancelable(self.io);
    }

    inline fn unlock(self: *JobManager) void {
        self.mutex.unlock(self.io);
    }

    pub fn deinit(self: *JobManager) void {
        self.lock();
        defer self.unlock();

        for (self.jobs.items) |*job| {
            self.allocator.free(job.name);
            if (job.progress_message) |m| self.allocator.free(m);
            if (job.result) |r| {
                switch (r) {
                    .success => |s| self.allocator.free(s),
                    .failure => |f| self.allocator.free(f),
                    .cancelled => {},
                }
            }
            self.allocator.destroy(job.cancelled);
        }
        self.jobs.deinit(self.allocator);

        for (self.completed_results.items) |item| {
            switch (item.result) {
                .success => |s| self.allocator.free(s),
                .failure => |f| self.allocator.free(f),
                .cancelled => {},
            }
        }
        self.completed_results.deinit(self.allocator);
    }

    pub fn spawn(self: *JobManager, name: []const u8, func: JobFn, ctx: *anyopaque) !u64 {
        self.lock();

        const id = self.next_id;
        self.next_id += 1;

        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        const cancelled_ptr = try self.allocator.create(std.atomic.Value(bool));
        errdefer self.allocator.destroy(cancelled_ptr);
        cancelled_ptr.* = std.atomic.Value(bool).init(false);

        const job = Job{
            .id = id,
            .name = name_copy,
            .status = std.atomic.Value(JobStatus).init(.pending),
            .progress = 0,
            .progress_message = null,
            .result = null,
            .start_time = std.Io.Clock.real.now(self.io).toMilliseconds(),
            .end_time = null,
            .cancelled = cancelled_ptr,
        };

        try self.jobs.append(self.allocator, job);

        self.unlock();

        const wrapper = try self.allocator.create(JobWrapper);
        wrapper.* = JobWrapper{
            .manager = self,
            .job_id = id,
            .func = func,
            .ctx = ctx,
        };

        const thread = try std.Thread.spawn(.{}, runJob, .{wrapper});
        thread.detach();

        return id;
    }

    fn runJob(wrapper: *JobWrapper) void {
        const manager = wrapper.manager;
        const job_id = wrapper.job_id;
        const func = wrapper.func;
        const ctx = wrapper.ctx;
        defer manager.allocator.destroy(wrapper);

        manager.lock();
        var job_ptr: ?*Job = null;
        for (manager.jobs.items) |*job| {
            if (job.id == job_id) {
                job_ptr = job;
                job.status.store(.running, .release);
                break;
            }
        }
        manager.unlock();

        if (job_ptr == null) return;

        var progress = JobProgress{
            .percent = 0,
            .message = null,
            .cancelled = job_ptr.?.cancelled,
        };

        const result: JobResult = blk: {
            if (job_ptr.?.cancelled.load(.acquire)) {
                break :blk .cancelled;
            }

            const output = func(ctx, &progress, manager.allocator) catch |err| {
                // On OOM we can't allocPrint a message; fall back to a duped
                // static so the freeing code is uniform. If even that fails,
                // surface as cancelled (consumer treats it as no-result).
                const err_msg = std.fmt.allocPrint(manager.allocator, "Job failed: {}", .{err}) catch
                    (manager.allocator.dupe(u8, "Unknown error") catch break :blk .cancelled);
                break :blk JobResult{ .failure = err_msg };
            };

            break :blk JobResult{ .success = output };
        };

        manager.lock();
        defer manager.unlock();

        for (manager.jobs.items) |*job| {
            if (job.id == job_id) {
                job.end_time = std.Io.Clock.real.now(manager.io).toMilliseconds();
                job.result = result;

                const status: JobStatus = switch (result) {
                    .success => .completed,
                    .failure => .failed,
                    .cancelled => .cancelled,
                };
                job.status.store(status, .release);

                const result_copy: ?JobResult = switch (result) {
                    .success => |s| if (manager.allocator.dupe(u8, s)) |d| JobResult{ .success = d } else |_| null,
                    .failure => |f| if (manager.allocator.dupe(u8, f)) |d| JobResult{ .failure = d } else |_| null,
                    .cancelled => .cancelled,
                };
                if (result_copy) |rc| {
                    manager.completed_results.append(manager.allocator, .{ .id = job_id, .result = rc }) catch |err| {
                        log.warn("Failed to record completion for job {d}: {} (result lost)", .{ job_id, err });
                        switch (rc) {
                            .success => |s| manager.allocator.free(s),
                            .failure => |f| manager.allocator.free(f),
                            .cancelled => {},
                        }
                    };
                } else {
                    log.warn("OOM duping result for completed job {d}", .{job_id});
                }
                break;
            }
        }
    }

    pub fn cancel(self: *JobManager, id: u64) void {
        self.lock();
        defer self.unlock();

        for (self.jobs.items) |job| {
            if (job.id == id) {
                job.cancelled.store(true, .release);
                break;
            }
        }
    }

    pub fn getStatus(self: *JobManager, id: u64) ?JobStatus {
        self.lock();
        defer self.unlock();

        for (self.jobs.items) |job| {
            if (job.id == id) {
                return job.status.load(.acquire);
            }
        }
        return null;
    }

    pub fn getJob(self: *JobManager, id: u64) ?Job {
        self.lock();
        defer self.unlock();

        for (self.jobs.items) |job| {
            if (job.id == id) {
                return job;
            }
        }
        return null;
    }

    pub fn getActiveJobs(self: *JobManager, allocator: std.mem.Allocator) ![]Job {
        self.lock();
        defer self.unlock();

        var active = std.ArrayListUnmanaged(Job).empty;
        errdefer active.deinit(allocator);

        for (self.jobs.items) |job| {
            if (!job.status.load(.acquire).isTerminal()) {
                try active.append(allocator, job);
            }
        }

        return active.toOwnedSlice(allocator);
    }

    pub fn activeCount(self: *JobManager) usize {
        self.lock();
        defer self.unlock();

        var count: usize = 0;
        for (self.jobs.items) |job| {
            if (!job.status.load(.acquire).isTerminal()) {
                count += 1;
            }
        }
        return count;
    }

    pub fn popCompletedResults(self: *JobManager, allocator: std.mem.Allocator) ![]struct { id: u64, result: JobResult } {
        self.lock();
        defer self.unlock();

        const results = try self.completed_results.toOwnedSlice(allocator);
        return results;
    }

    pub fn getActiveJobName(self: *JobManager) ?[]const u8 {
        self.lock();
        defer self.unlock();

        for (self.jobs.items) |job| {
            if (!job.status.load(.acquire).isTerminal()) {
                return job.name;
            }
        }
        return null;
    }

    pub fn pruneCompleted(self: *JobManager, max_age_ms: i64) void {
        self.lock();
        defer self.unlock();

        const now = std.Io.Clock.real.now(self.io).toMilliseconds();
        var i: usize = 0;

        while (i < self.jobs.items.len) {
            const job = self.jobs.items[i];
            if (job.status.load(.acquire).isTerminal()) {
                if (job.end_time) |end| {
                    if (now - end > max_age_ms) {
                        const removed = self.jobs.orderedRemove(i);
                        self.allocator.free(removed.name);
                        if (removed.progress_message) |m| self.allocator.free(m);
                        if (removed.result) |r| {
                            switch (r) {
                                .success => |s| self.allocator.free(s),
                                .failure => |f| self.allocator.free(f),
                                .cancelled => {},
                            }
                        }
                        self.allocator.destroy(removed.cancelled);
                        continue;
                    }
                }
            }
            i += 1;
        }
    }
};

pub const SimpleJob = struct {
    data: *anyopaque,
    callback: *const fn (*anyopaque, *JobProgress, std.mem.Allocator) anyerror![]const u8,

    pub fn run(ctx: *anyopaque, progress: *JobProgress, allocator: std.mem.Allocator) anyerror![]const u8 {
        const self: *SimpleJob = @ptrCast(@alignCast(ctx));
        return self.callback(self.data, progress, allocator);
    }
};

test "job manager basic operations" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var jm = JobManager.init(allocator, io);
    defer jm.deinit();

    const TestContext = struct {
        value: i32,
    };
    var test_ctx = TestContext{ .value = 42 };

    const job_fn = struct {
        fn run(ctx: *anyopaque, progress: *JobProgress, alloc: std.mem.Allocator) anyerror![]const u8 {
            _ = progress;
            const tc: *TestContext = @ptrCast(@alignCast(ctx));
            return try std.fmt.allocPrint(alloc, "Result: {d}", .{tc.value});
        }
    }.run;

    const id = try jm.spawn("Test Job", job_fn, &test_ctx);
    try std.testing.expect(id > 0);

    std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};

    const status = jm.getStatus(id);
    try std.testing.expect(status != null);
}
