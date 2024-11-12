// Implements:
// fibers as lightweight concurrency control
//
// Source:
// https://cyp.sh/blog/coroutines-in-c
// https://agraphicsguynotes.com/posts/fiber_in_cpp_understanding_the_basics/
// https://github.com/SuperAuguste/oatz/blob/main/impls/aarch64.zig
// https://raw.githubusercontent.com/wiki/hjl-tools/x86-psABI/x86-64-psABI-1.0.pdf

const std = @import("std");
const builtin = @import("builtin");
const sctx = @import("stackcontent.zig");

const assert = std.debug.assert;
const Fiber = @This();

const InitialStackSize = 2 * 1024; // 2 KB
const MaxStackSize = 1 * 1024 * 1024; // 1 MB

pub const Error = error{
    StackTooSmall,
    StackTooLarge,
    OutOfMemory,
};

pub fn init(allocator: std.mem.Allocator, user_data: usize, comptime func: anytype, args: anytype) Error!*Fiber {
    const stack = try allocator.alloc(u8, InitialStackSize);
    const Args = @TypeOf(args);

    const state = try State.init(stack, user_data, @sizeOf(Args), struct {
        fn entry() callconv(.C) noreturn {
            const state = tls_state orelse unreachable;

            // Call the functions with the args.
            const args_ptr = @as(*align(1) Args, @ptrFromInt(@intFromPtr(state) - @sizeOf(Args)));
            @call(.auto, func, args_ptr.*);

            // Mark the fiber as completed and do one last
            zig_fiber_stack_swap(&state.stack_ctx, &state.caller_ctx);
            unreachable;
        }
    }.entry);

    const args_ptr = @as(*align(1) Args, @ptrFromInt(@intFromPtr(state) - @sizeOf(Args)));
    args_ptr.* = args;

    return @ptrCast(state);
}

threadlocal var tls_state: ?*State = null;

pub inline fn current() ?*Fiber {
    return @ptrCast(tls_state);
}

pub fn getStack(fiber: *Fiber) []u8 {
    const state: *State = @ptrCast(@alignCast(fiber));

    const stack_end = @intFromPtr(state) + @as(u8, @truncate(state.offset));
    const stack_base = stack_end - (state.offset >> @bitSizeOf(u8));
    return @as([*]u8, @ptrCast(stack_base))[0..(stack_end - stack_base)];
}

pub fn getUserDataPtr(fiber: *Fiber) *usize {
    const state: *State = @ptrCast(@alignCast(fiber));
    return &state.user_data;
}

pub fn switchTo(fiber: *Fiber) void {
    const state: *State = @ptrCast(@alignCast(fiber));

    if (state.completed) {
        std.log.warn("Completeed \n", .{});
        return;
    }

    const old_state = tls_state;
    assert(old_state != state);

    tls_state = state;
    defer tls_state = old_state;

    zig_fiber_stack_swap(&state.caller_ctx, &state.stack_ctx);
}

pub fn yield() void {
    const state = tls_state orelse unreachable;
    zig_fiber_stack_swap(&state.stack_ctx, &state.caller_ctx);
}

pub fn done() void {
    if (Fiber.current()) |fiber| {
        const state: *State = @ptrCast(@alignCast(fiber));
        state.completed = true;
    } else {
        return;
    }
}

fn growStack(allocator: std.mem.Allocator, state: *State, new_stack_size: usize) Error!*[]u8 {
    const new_stack = try allocator.alloc(u8, new_stack_size);

    const old_stack_start = state.stack_ptr;
    const old_stack_size = state.stack_end - old_stack_start;
    std.mem.copy(u8, new_stack, old_stack_start, old_stack_size);

    return new_stack;
}

const State = extern struct {
    caller_ctx: *anyopaque,
    stack_ctx: *anyopaque,
    user_data: usize,
    offset: usize,
    stack_size: usize,
    stack_start: ?*u8,
    completed: bool,

    // Each fiber context has a stack associated
    // Fiber's can be suspended, which means we
    // need to be able to store the store in memory
    //
    // [---- Stack ----]
    // [(start)---Stack----(end)----(rest)]
    // [(start)---Stack----(end)----(state_size)--(args size)]
    //
    // The Stack grows downward, so end is at top, start is bottom

    fn init(stack: []u8, user_data: usize, args_size: usize, entry_point: *const fn () callconv(.C) noreturn) Error!*State {
        const stack_base = @intFromPtr(stack.ptr);
        const stack_end = @intFromPtr(stack.ptr + stack.len);
        if (stack.len > (std.math.maxInt(usize) >> @bitSizeOf(u8))) return error.StackTooLarge;

        // Push the State onto the state.
        var stack_ptr = stack_end - @sizeOf(State);
        stack_ptr = std.mem.alignBackward(usize, stack_ptr, @alignOf(State));
        if (stack_ptr < stack_base) return error.StackTooSmall;

        const state: *State = @ptrFromInt(stack_ptr);
        const end_offset = stack_end - stack_ptr;

        // Push enough bytes for the args onto the stack.
        stack_ptr -= args_size;
        if (stack_ptr < stack_base) return error.StackTooSmall;

        // Align the stack for the StackContext.
        stack_ptr = std.mem.alignBackward(usize, stack_ptr, 16);
        if (stack_ptr < stack_base) return error.StackTooSmall;

        // Reserve data for the StackContext.
        stack_ptr -= @sizeOf(usize) * sctx.StackContext.word_count;
        assert(std.mem.isAligned(stack_ptr, @alignOf(usize)));
        if (stack_ptr < stack_base) return error.StackTooSmall;

        // Write the entry point into the StackContext.
        @as([*]@TypeOf(entry_point), @ptrFromInt(stack_ptr))[sctx.StackContext.entry_offset] = entry_point;

        state.* = .{
            .caller_ctx = undefined,
            .stack_ctx = @as(*anyopaque, @ptrFromInt(stack_ptr)),
            .user_data = user_data,
            .offset = (stack.len << @bitSizeOf(u8)) | end_offset,
            .stack_start = @as(*u8, &stack.ptr[0]),
            .stack_size = stack.len,
            .completed = false,
        };

        assert(@as(usize, @intFromPtr(state)) % @alignOf(State) == 0);
        return state;
    }
};

extern fn zig_fiber_stack_swap(
    noalias current_context_ptr: **anyopaque,
    noalias new_context_ptr: **anyopaque,
) void;

test "test fiber initialization" {
    var val: usize = 0;
    const user_data = 42;
    const args = .{&val};
    const func = test_fiber_func;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const fiber = try Fiber.init(allocator, user_data, func, args);

    const user_data_ptr = fiber.getUserDataPtr();
    try std.testing.expect(user_data_ptr.* == 42);

    const state: *State = @ptrCast(@alignCast(fiber));

    try std.testing.expect(state.stack_start != null);
    try std.testing.expect(state.stack_size == InitialStackSize);
}

test "test fiber switching" {
    var arena1 = std.heap.ArenaAllocator.init(std.testing.allocator);
    var arena2 = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena1.deinit();
    defer arena2.deinit();

    const allocator1 = arena1.allocator();
    const allocator2 = arena2.allocator();

    var value1: u8 = 69;
    var value2: u8 = 69;

    // const stack1 = try allocator1.alloc(u8, InitialStackSize);
    // const stack2 = try allocator2.alloc(u8, InitialStackSize);

    const fiber1 = try Fiber.init(allocator1, 0, fiber_func1, .{&value1});
    const fiber2 = try Fiber.init(allocator2, 0, fiber_func2, .{&value2});

    // const state1: *State = @ptrCast(@alignCast(fiber1));
    // const state2: *State = @ptrCast(@alignCast(fiber2));

    std.log.warn("cpu arch {}, tag {}, sc {}\n", .{ builtin.cpu.arch, builtin.os.tag, sctx.StackContext });

    // try std.testing.expect(state1.stack_start != state2.stack_start);

    fiber2.switchTo();
    fiber1.switchTo();

    try std.testing.expect(value1 == 42);
    try std.testing.expect(value2 == 101);

    fiber1.switchTo();
    try std.testing.expect(value1 == 65);

    fiber1.switchTo();
}

fn fiber_func1(value: *u8) void {
    value.* = 42;
    Fiber.yield();

    value.* = value.* + 23;
    Fiber.done();
}

fn fiber_func2(value: *u8) void {
    // std.debug.print("Inside fiber_func2 {}\n", .{args});
    //
    // const typed_args: [*]usize = @ptrCast(args);
    // const value_ptr = typed_args[0];
    //
    value.* = 101;
    Fiber.done();
}

fn test_fiber_func(args: anytype) void {
    std.debug.print("args {}", .{args});
}
