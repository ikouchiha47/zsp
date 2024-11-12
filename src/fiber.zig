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

const Fiber = @This();

const assert = std.debug.assert;
pub const log_level: std.log.Level = .debug;

pub const Error = error{ StackTooSmall, StackTooLarge, OutOfMemory };

threadlocal var tls_state: ?*State = null;

const InitialStackSize = 2 * 1024; // 2 KB
const MaxStackSize = 1 * 1024 * 1024; // 1 MB

pub fn init(allocator: std.mem.Allocator, user_data: usize, comptime func: anytype, args: anytype) Error!*Fiber {
    const stack = try allocator.alloc(u8, InitialStackSize);

    const Args = @TypeOf(args);

    const state = try State.init(stack, user_data, @sizeOf(Args), struct {
        fn entry() callconv(.C) noreturn {
            const state = tls_state orelse unreachable;

            // Call the functions with the args.
            const args_ptr: *align(1) Args = @ptrFromInt(@intFromPtr(state) - @sizeOf(Args));
            @call(.auto, func, args_ptr.*);

            // if (state.stack_start + 128 > state.stack_end) {
            //     std.debug.print("growing out of stack space", .{});
            // }
            std.debug.print("\nStack {}, Caller {}\n", .{ state.stack_ctx, state.caller_ctx });

            zig_fiber_stack_swap(&state.stack_ctx, &state.caller_ctx);
            unreachable;
        }
    }.entry);

    const args_ptr: *align(1) Args = @ptrFromInt(@intFromPtr(state) - @sizeOf(Args));
    args_ptr.* = args;

    return @ptrCast(state);
}

pub inline fn current() ?*Fiber {
    return @ptrCast(tls_state);
}

inline fn checkAlignment(ptr: usize, alignment: usize) void {
    assert(ptr % alignment == 0);
}

pub fn getStack(fiber: *Fiber) []u8 {
    const state: *State = @ptrCast(@alignCast(fiber));

    const offset: u8 = @truncate(state.offset);
    const stack_end = @intFromPtr(state) + offset;
    const stack_base = stack_end - (state.offset >> @bitSizeOf(u8));

    const addrs: [*]u8 = @ptrCast(stack_base);
    return addrs[0..(stack_end - stack_base)];
}

pub fn getUserDataPtr(fiber: *Fiber) *usize {
    const state: *State = @ptrCast(@alignCast(fiber));
    return &state.user_data;
}

pub fn switchTo(fiber: *Fiber) void {
    const state: *State = @ptrCast(@alignCast(fiber));

    const old_state = tls_state;
    assert(old_state != state);

    const start: usize = @intFromPtr(state.stack_ctx);

    std.debug.print("\nswitchTo Stack {}, Ptr {?}, Caller {}. {?}\n", .{ state.stack_ctx, state.stack_start, state.caller_ctx, start });

    // checkAlignment(stack_ptr, 16);

    tls_state = state;
    defer tls_state = old_state;

    std.debug.print("\nSwitching stack \n", .{});

    zig_fiber_stack_swap(&state.caller_ctx, &state.stack_ctx);
}

/// Switches the current thread's execution back to the most recent switchTo() called on the currently running fiber.
/// Calling yield from outside a fiber context (`current() == null`) is illegal behavior.
/// Once execution is yielded back, switchTo() on the (now previous) current fiber can be called again
/// to continue the fiber from this yield point.
pub fn yield() void {
    const state = tls_state orelse unreachable;
    std.debug.print("state {}", .{state});

    zig_fiber_stack_swap(&state.stack_ctx, &state.caller_ctx);
}

fn grow_stack(state: *State, new_stack_size: usize) Error!*[]u8 {
    const allocator = std.heap.page_allocator;

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
    stack_start: ?*u8,
    stack_size: usize,

    // Each fiber context has a stack associated
    // Fiber's can be suspended, which means we
    // need to be able to store the store in memory
    //
    // [---- Stack ----]
    // [(start)---Stack----(end)----(rest)]
    // [(start)---Stack----(end)----(state_size)--(args size)]
    //
    // The Stack grows downward, so end is at top, start is bottom

    fn init(stack: []u8, user_data: usize, args_size: usize, entry: *const fn () callconv(.C) noreturn) Error!*State {
        const stack_start = @intFromPtr(stack.ptr);
        const stack_end = @intFromPtr(stack.ptr + stack.len);

        std.debug.print("\nState init: Stack start end {} {} {}\n", .{ stack_end, stack_start, stack_end - stack_start });

        if (stack.len > (std.math.maxInt(usize) >> @bitSizeOf(u8))) {
            return Error.StackTooLarge;
        }

        var sp = stack_end - @sizeOf(State);
        sp = std.mem.alignBackward(usize, sp, @alignOf(State));
        if (sp < stack_start) {
            return Error.StackTooSmall;
        }

        const state: *State = @ptrFromInt(sp);
        const end = stack_end - sp;

        sp = sp - args_size;
        if (sp < stack_start) {
            return Error.StackTooSmall;
        }

        sp = std.mem.alignBackward(usize, sp, 16);
        if (sp < stack_start) {
            return Error.StackTooSmall;
        }

        sp = sp - (@sizeOf(usize) * sctx.StackContext.word_count);
        assert(std.mem.isAligned(sp, @alignOf(usize)));

        if (sp < stack_start) {
            return Error.StackTooSmall;
        }

        const entry_ptr: [*]@TypeOf(entry) = @ptrFromInt(sp);
        entry_ptr[sctx.StackContext.entry_offset] = entry;

        const stack_pointer: *u8 = &stack.ptr[0];

        assert(sp >= stack_start and sp <= stack_end);

        const xx: *anyopaque = @ptrFromInt(sp);
        std.debug.print("State:init {} {}\n", .{ sp, xx });

        state.* = .{
            .caller_ctx = undefined,
            .stack_ctx = @ptrFromInt(sp),
            .user_data = user_data,
            .stack_start = stack_pointer,
            .stack_size = stack.len,
            .offset = (stack.len << @bitSizeOf(u8) | end),
        };

        assert(@as(usize, @intFromPtr(state)) % @alignOf(State) == 0);
        std.debug.print("Align {}, {}", .{ @as(usize, @intFromPtr(state)), @alignOf(State) });

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

    var value1: usize = 69;
    var value2: usize = 69;

    const fiber1 = try Fiber.init(allocator1, 0, fiber_func1, .{&value1});
    const fiber2 = try Fiber.init(allocator2, 0, fiber_func1, .{&value2});

    const state1: *State = @ptrCast(@alignCast(fiber1));
    const state2: *State = @ptrCast(@alignCast(fiber2));

    std.log.warn("cpu arch {}, tag {}, sc {}\n", .{ builtin.cpu.arch, builtin.os.tag, sctx.StackContext });

    try std.testing.expect(state1.stack_start != state2.stack_start);

    fiber1.switchTo();

    // Fiber.switchTo(fiber2);
    // Fiber.switchTo(fiber1);

    // try std.testing.expect(state1.stack_start != null);
    // try std.testing.expect(state2.stack_start != null);
    //
    try std.testing.expect(value1 == 42);
    try std.testing.expect(value2 == 101);
}

fn fiber_func1(value: *usize) void {
    // std.debug.print("Inside fiber_func1 {}\n", .{args});
    //
    // const typed_args: [*]usize = @ptrCast(args);
    // const value_ptr = &typed_args[0];
    //
    // std.debug.print("typed_args {}\n", .{value_ptr});
    //
    value.* = 42;
    Fiber.yield();
    // std.log.err("Resuming fiber_func1\n", .{});
    // std.debug.print("fiber_func1 running with args: {}\n", .{value});
    // _ = value;
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
    Fiber.yield();
}

fn test_fiber_func(args: anytype) void {
    std.debug.print("args {}", .{args});
}
