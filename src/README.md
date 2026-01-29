# fiber

These are light weight thread, like coroutines. This basically works by
replacing function pointers on registers.

Replacing the current stack pointer with the stack pointer of the fiber.

The assembly code takes over to do the needful, according to the specs on different machines.

## usage

```zig
var arena1 = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena1.deinit();

const allocator1 = arena1.allocator();

// Create the fiber context with args and a function to execute
var value1: u8 = 69;
const fiber1 = try Fiber.init(allocator1, 0, fiber_func1, .{&value1});

fiber1.switchTo();
print("Fiber Complete: {}", .{fiber1.isDone()}); // false

fiber1.switchTo();
print("Fiber Complete: {}", .{fiber1.isDone()}); // true

// Marking the fiber as done is important, to help
// prevent extra calls to not be executed.

fiber1.switchTo(); // Does nothing

fn fiber_func1(value: *u8) void {
    value.* = 42;
    Fiber.yield(); // we can resume from here

    value.* = value.* + 23; // the previously value should 42

    // IMPORTANT: mark it as done
    Fiber.done();
}
```

## promise

a better model for accessing:

```zig
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
    Fiber.done(); // Important
}
```

---

## leveraging exsisting libraries

- libdill, for simple coroutines
- , for csp
- , for actor modelling
