const std = @import("std");

const G = struct {
    id: usize,
    task_fn: fn () void,
    state: State,

    pub const State = enum {
        Runnable,
        Running,
        Waiting,
        Done,
    };
};

const M = struct {
    id: usize,
    current_g: ?*G, // Currently running goroutine
};

const P = struct {
    id: usize,
    run_queue: std.ArrayList(*G), // Queue of runnable goroutines
};

const Scheduler = struct {
    ps: []P,
    ms: []M,
    gs: []G,

    pub fn init(num_ps: usize, num_ms: usize) Scheduler {
        return Scheduler{
            .ps = allocateProcessors(num_ps),
            .ms = allocateMachines(num_ms),
            .gs = allocateGoroutines(),
        };
    }

    fn allocateProcessors(num: usize) []P {
        var allocator = std.heap.page_allocator;
        const processors = try allocator.alloc(P, num);
        for (0.., processors) |i, *p| {
            p.* = P{ .id = i, .run_queue = std.ArrayList(*G).init(allocator) };
        }
        return processors;
    }

    fn allocateMachines(num: usize) []M {
        var allocator = std.heap.page_allocator;
        const machines = try allocator.alloc(M, num);
        for (0.., machines) |i, *m| {
            m.* = M{ .id = i, .current_g = null };
        }
        return machines;
    }

    fn allocateGoroutines() []G {
        // Allocate initial goroutines (tasks), may vary based on requirements
        var allocator = std.heap.page_allocator;
        const num_gs = 10; // Example: 10 initial goroutines
        const goroutines = try allocator.alloc(G, num_gs);
        for (0.., goroutines) |i, *g| {
            g.* = G{ .id = i, .task_fn = null, .state = .Runnable };
        }
        return goroutines;
    }
};
