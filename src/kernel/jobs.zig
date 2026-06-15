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
    failed: bool = false,

    pub fn update(self: *JobProgress, percent: u8, msg: ?[]const u8) void {
        self.percent = if (percent > 100) 100 else percent;
        self.message = msg;
    }

    pub fn isCancelled(self: *JobProgress) bool {
        return self.cancelled.load(.acquire);
    }

    pub fn markFailed(self: *JobProgress) void {
        self.failed = true;
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

pub const JobResultKind = enum { success, failure, cancelled };

pub const JobSnapshot = struct {
    id: u64,
    name: []u8,
    status: JobStatus,
    progress: u8,
    progress_message: ?[]u8 = null,
    result: ?JobResultKind = null,
    result_output: ?[]u8 = null,
    start_time: i64,
    end_time: ?i64,

    pub fn deinit(self: *JobSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.progress_message) |m| allocator.free(m);
        if (self.result_output) |o| allocator.free(o);
    }
};

pub const JobSummary = struct {
    jobs: []JobSnapshot = &.{},
    total: usize = 0,
    pending: usize = 0,
    running: usize = 0,
    completed: usize = 0,
    failed: usize = 0,
    cancelled: usize = 0,

    pub fn active(self: JobSummary) usize {
        return self.pending + self.running;
    }

    pub fn deinit(self: *JobSummary, allocator: std.mem.Allocator) void {
        for (self.jobs) |*job| job.deinit(allocator);
        allocator.free(self.jobs);
        self.jobs = &.{};
    }
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
        // Allocate everything that can fail BEFORE taking the lock or
        // appending to the job list. That way an OOM here doesn't
        // either deadlock the manager (lock held across error return)
        // or leave a Job in the list whose owned pointers have already
        // been freed by errdefers.
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        const cancelled_ptr = try self.allocator.create(std.atomic.Value(bool));
        errdefer self.allocator.destroy(cancelled_ptr);
        cancelled_ptr.* = std.atomic.Value(bool).init(false);

        const wrapper = try self.allocator.create(JobWrapper);
        errdefer self.allocator.destroy(wrapper);

        self.lock();
        errdefer self.unlock();

        const id = self.next_id;

        wrapper.* = JobWrapper{
            .manager = self,
            .job_id = id,
            .func = func,
            .ctx = ctx,
        };

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

        // Spawn the thread BEFORE incrementing next_id / unlocking, so
        // that if spawn fails we can roll back cleanly: pop the job we
        // just appended and let the errdefer chain free its pointers.
        const thread = std.Thread.spawn(.{}, runJob, .{wrapper}) catch |err| {
            _ = self.jobs.pop();
            return err;
        };
        thread.detach();

        // Ownership of name_copy, cancelled_ptr, and wrapper has now
        // been handed off to the live Job + worker thread. Cancel the
        // earlier errdefers so an error from here on doesn't double-free.
        self.next_id += 1;
        self.unlock();
        return id;
    }

    fn runJob(wrapper: *JobWrapper) void {
        @import("../services/thread_name.zig").set("stem-job");
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
                if (err == error.Cancelled) {
                    break :blk .cancelled;
                }
                // On OOM we can't allocPrint a message; fall back to a duped
                // static so the freeing code is uniform. If even that fails,
                // surface as cancelled (consumer treats it as no-result).
                const err_msg = std.fmt.allocPrint(manager.allocator, "Job failed: {}", .{err}) catch
                    (manager.allocator.dupe(u8, "Unknown error") catch break :blk .cancelled);
                break :blk JobResult{ .failure = err_msg };
            };

            if (progress.failed) {
                break :blk JobResult{ .failure = output };
            }
            break :blk JobResult{ .success = output };
        };

        const progress_message_copy = if (progress.message) |message|
            manager.allocator.dupe(u8, message) catch null
        else
            null;

        manager.lock();
        defer manager.unlock();

        var found_job = false;
        for (manager.jobs.items) |*job| {
            if (job.id == job_id) {
                found_job = true;
                job.end_time = std.Io.Clock.real.now(manager.io).toMilliseconds();
                job.progress = progress.percent;
                if (job.progress_message) |m| manager.allocator.free(m);
                job.progress_message = progress_message_copy;
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
        if (!found_job) {
            if (progress_message_copy) |m| manager.allocator.free(m);
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

    pub fn snapshot(self: *JobManager, allocator: std.mem.Allocator) !JobSummary {
        self.lock();
        defer self.unlock();

        var jobs = std.ArrayListUnmanaged(JobSnapshot).empty;
        errdefer {
            for (jobs.items) |*job| job.deinit(allocator);
            jobs.deinit(allocator);
        }

        var summary = JobSummary{};
        for (self.jobs.items) |job| {
            const status = job.status.load(.acquire);
            summary.total += 1;
            switch (status) {
                .pending => summary.pending += 1,
                .running => summary.running += 1,
                .completed => summary.completed += 1,
                .failed => summary.failed += 1,
                .cancelled => summary.cancelled += 1,
            }

            const name = try allocator.dupe(u8, job.name);
            errdefer allocator.free(name);
            const progress_message = if (job.progress_message) |m|
                try allocator.dupe(u8, m)
            else
                null;
            errdefer if (progress_message) |m| allocator.free(m);

            const result_kind: ?JobResultKind = if (job.result) |r| switch (r) {
                .success => .success,
                .failure => .failure,
                .cancelled => .cancelled,
            } else null;
            const result_output: ?[]u8 = if (job.result) |r| switch (r) {
                .success => |s| try allocator.dupe(u8, s),
                .failure => |f| try allocator.dupe(u8, f),
                .cancelled => null,
            } else null;
            errdefer if (result_output) |o| allocator.free(o);

            try jobs.append(allocator, .{
                .id = job.id,
                .name = name,
                .status = status,
                .progress = job.progress,
                .progress_message = progress_message,
                .result = result_kind,
                .result_output = result_output,
                .start_time = job.start_time,
                .end_time = job.end_time,
            });
        }

        summary.jobs = try jobs.toOwnedSlice(allocator);
        return summary;
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

test "job manager snapshot owns stable job summaries" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var jm = JobManager.init(allocator, io);
    defer jm.deinit();

    try appendSnapshotTestJob(&jm, 1, "Index Workspace", .running, 42);
    try appendSnapshotTestJob(&jm, 2, "Run Tests", .completed, 100);
    jm.jobs.items[1].result = .{ .success = try allocator.dupe(u8, "ok") };

    var summary = try jm.snapshot(allocator);
    defer summary.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), summary.total);
    try std.testing.expectEqual(@as(usize, 1), summary.running);
    try std.testing.expectEqual(@as(usize, 1), summary.completed);
    try std.testing.expectEqual(@as(usize, 1), summary.active());
    try std.testing.expectEqualStrings("Index Workspace", summary.jobs[0].name);
    try std.testing.expectEqual(@as(u8, 42), summary.jobs[0].progress);
    try std.testing.expectEqual(JobResultKind.success, summary.jobs[1].result.?);

    jm.allocator.free(jm.jobs.items[0].name);
    jm.jobs.items[0].name = try allocator.dupe(u8, "mutated");
    try std.testing.expectEqualStrings("Index Workspace", summary.jobs[0].name);
}

test "job progress can mark returned output as failure" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var jm = JobManager.init(allocator, io);
    defer jm.deinit();

    const job_fn = struct {
        fn run(ctx: *anyopaque, progress: *JobProgress, alloc: std.mem.Allocator) anyerror![]const u8 {
            _ = ctx;
            progress.markFailed();
            return try alloc.dupe(u8, "task failed with useful output");
        }
    }.run;

    const id = try jm.spawn("Task: Fail", job_fn, undefined);
    std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};

    try std.testing.expectEqual(JobStatus.failed, jm.getStatus(id).?);
    var summary = try jm.snapshot(allocator);
    defer summary.deinit(allocator);
    try std.testing.expectEqual(JobResultKind.failure, summary.jobs[0].result.?);
    try std.testing.expectEqualStrings("task failed with useful output", summary.jobs[0].result_output.?);
}

test "job manager persists final progress into snapshots" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var jm = JobManager.init(allocator, io);
    defer jm.deinit();

    const job_fn = struct {
        fn run(ctx: *anyopaque, progress: *JobProgress, alloc: std.mem.Allocator) anyerror![]const u8 {
            _ = ctx;
            progress.update(73, "nearly there");
            return try alloc.dupe(u8, "ok");
        }
    }.run;

    const id = try jm.spawn("Progress Job", job_fn, undefined);
    std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};

    try std.testing.expectEqual(JobStatus.completed, jm.getStatus(id).?);
    var summary = try jm.snapshot(allocator);
    defer summary.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 73), summary.jobs[0].progress);
    try std.testing.expectEqualStrings("nearly there", summary.jobs[0].progress_message.?);
}

test "job manager treats cooperative cancellation as cancelled" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var jm = JobManager.init(allocator, io);
    defer jm.deinit();

    const job_fn = struct {
        fn run(ctx: *anyopaque, progress: *JobProgress, alloc: std.mem.Allocator) anyerror![]const u8 {
            _ = ctx;
            _ = progress;
            _ = alloc;
            return error.Cancelled;
        }
    }.run;

    const id = try jm.spawn("Cancelled Job", job_fn, undefined);
    std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};

    try std.testing.expectEqual(JobStatus.cancelled, jm.getStatus(id).?);
    var summary = try jm.snapshot(allocator);
    defer summary.deinit(allocator);
    try std.testing.expectEqual(JobResultKind.cancelled, summary.jobs[0].result.?);
}

fn appendSnapshotTestJob(jm: *JobManager, id: u64, name: []const u8, status: JobStatus, progress: u8) !void {
    const cancelled_ptr = try jm.allocator.create(std.atomic.Value(bool));
    errdefer jm.allocator.destroy(cancelled_ptr);
    cancelled_ptr.* = std.atomic.Value(bool).init(false);

    const name_copy = try jm.allocator.dupe(u8, name);
    errdefer jm.allocator.free(name_copy);

    try jm.jobs.append(jm.allocator, .{
        .id = id,
        .name = name_copy,
        .status = std.atomic.Value(JobStatus).init(status),
        .progress = progress,
        .progress_message = null,
        .result = null,
        .start_time = 1,
        .end_time = if (status.isTerminal()) 2 else null,
        .cancelled = cancelled_ptr,
    });
}
