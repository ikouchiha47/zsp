const std = @import("std");
const Fiber = @import("fiber.zig");

const PromiseState = enum {
    Pending,
    Complete,
};

pub const FiberPromise = struct {
    fiber: *Fiber,
    allocator: std.heap.ArenaAllocator,
    state: PromiseState = .Pending,

    pub fn join(self: *FiberPromise) void {
        while (self.state == .Pending) {
            self.fiber.switchTo();

            if (self.fiber.isDone()) {
                self.state = .Complete;
            }
        }

        self.allocator.deinit();
    }
};

pub fn fork(base_allocator: std.mem.Allocator, comptime func: anytype, args: anytype) !*FiberPromise {
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    const allocator = arena.allocator();

    const fiber = try Fiber.init(allocator, 0, func, args);

    const promise = try allocator.create(FiberPromise);

    promise.* = FiberPromise{
        .fiber = fiber,
        .allocator = arena,
        .state = .Pending,
    };

    return promise;
}

test "async await syntax" {
    var value: u8 = 0;

    const promise = try fork(std.testing.allocator, fiber_func1, .{&value});

    promise.join();

    try std.testing.expect(value == 23);
}

fn fiber_func1(value: *u8) void {
    value.* = 42;
    Fiber.yield();

    value.* = 23;
    Fiber.done();
}
