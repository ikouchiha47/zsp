const std = @import("std");
const timer = @import("timer.zig");
const Fiber = @import("fiber.zig");

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    var arena1 = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var arena2 = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    defer arena1.deinit();
    defer arena2.deinit();

    const allocator1 = arena1.allocator();
    const allocator2 = arena2.allocator();

    var value1: u8 = 69;
    var value2: u8 = 69;

    const fiber1 = try Fiber.init(allocator1, 0, fiber_func1, .{&value1});
    const fiber2 = try Fiber.init(allocator2, 0, fiber_func1, .{&value2});

    // try std.testing.expect(state1.stack_start != state2.stack_start);
    // _ = fiber2;
    _ = fiber2;

    fiber1.switchTo();
    Fiber.yield();

    // Fiber.switchTo(fiber2);
    // Fiber.switchTo(fiber1);

    // try std.testing.expect(state1.stack_start != null);
    // try std.testing.expect(state2.stack_start != null);
}

fn fiber_func1(value: *u8) void {
    // std.debug.print("Inside fiber_func1 {}\n", .{value});
    //
    // const typed_args: [*]usize = @ptrCast(args);
    // const value_ptr = &typed_args[0];
    //
    // std.debug.print("typed_args {}\n", .{value_ptr});
    //
    // value_ptr.* = 42;
    // // Fiber.yield();
    // std.log.err("Resuming fiber_func1\n", .{});
    // std.debug.print("fiber_func1 running with args: {}\n", .{value});
    // Fiber.yield();
    _ = value;
}

fn fiber_func2(args: anytype) void {
    // std.debug.print("Inside fiber_func2 {}\n", .{args});
    //
    // const typed_args: [*]usize = @ptrCast(args);
    // const value_ptr = typed_args[0];
    //
    // std.debug.print("typed_args {}\n", .{value_ptr});
    //
    // // value_ptr = 102;
    // // Fiber.yield();
    //
    // std.log.err("Resuming fiber_func2\n", .{});
    std.debug.print("fiber_func2 running with args: {}\n", .{args});
    // Fiber.yield();
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
