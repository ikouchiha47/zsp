// const std = @import("std");
//
// pub const TimerWhen = struct {
//     timer: *Timer,
//     when: i64,
// };
//
// pub const Timer = struct {
//     // mu protects reads and writes to all fields, with exceptions noted below.
//     mu: std.Mutex = .{},
//     astate: std.atomic.Atomic(u8) = .{}, // atomic copy of state bits at last unlock
//     state: u8 = 0, // state bits
//     is_chan: bool = false, // timer has a channel; immutable; can be read without lock
//     blocked: std.atomic.Atomic(u32) = .{}, // number of goroutines blocked on timer's channel
//
//     // Timer wakes up at when, and then at when+period, ... (period > 0 only)
//     // each time calling f(arg, seq, delay) in the timer goroutine, so f must be
//     // a well-behaved function and not block.
//     when: i64 = 0,
//     period: i64 = 0,
//     f: ?*const fn (arg: anyopaque, seq: usize, delay: i64) void,
//     arg: ?anyopaque = null,
//     seq: usize = 0,
//
//     // If non-nil, the timers containing t.
//     ts: ?*Timers = null,
//
//     // sendLock protects sends on the timer's channel.
//     sendLock: std.Mutex = std.Mutex.init(),
//
//     // isSending is used to handle races between running a
//     // channel timer and stopping or resetting the timer.
//     // It is used only for channel timers (t.is_chan == true).
//     // It is not used for tickers.
//     // The value is incremented when about to send a value on the channel,
//     // and decremented after sending the value.
//     // The stop/reset code uses this to detect whether it
//     // stopped the channel send.
//     //
//     // isSending is incremented only when t.mu is held.
//     // isSending is decremented only when t.sendLock is held.
//     // isSending is read only when both t.mu and t.sendLock are held.
//     isSending: std.atomic.Atomic(i32) = .{},
//
//     pub fn init(self: *Timer, timeout: i64, arg: anyopaque, f: *const fn (arg: anyopaque, seq: usize, delay: i64) void) void {
//         self.mu = std.Mutex.init();
//         self.astate = std.atomic.Atomic(u8).init(0);
//         self.blocked = std.atomic.Atomic(u32).init(0);
//         self.isSending = std.atomic.Atomic(i32).init(0);
//         self.when = nanotime() + timeout;
//         self.arg = arg;
//         self.f = f;
//     }
//
//     pub fn maybeRunChan(t: *Timer) void {
//         if (@atomicLoad(u8, &t.astate, .SeqCst) & TimerState.timerHeaped != 0) {
//             // If the timer is in the heap, the ordinary timer code
//             // is in charge of sending when appropriate.
//             return;
//         }
//
//         t.mu.lock();
//         defer t.mu.unlock();
//
//         const now = nanotime();
//         if (t.state & TimerState.timerHeaped != 0 or t.when == 0 or t.when > now) {
//             return;
//         }
//     }
// };
//
// fn nanotime() i64 {
//     return std.time.nanoTimestamp();
// }
//
// pub const Timers = struct {
//     // mu protects timers; timers are per-P, but the scheduler can
//     // access the timers of another P, so we have to lock.
//     mu: std.Mutex = std.Mutex.init(),
//     // heap is the set of timerWhen instances, ordered by heap[i].when.
//     // Must hold lock to access.
//     heap: std.PriorityQueue(TimerWhen, void, timerLess) = .{},
//     // len is an atomic copy of len(heap).
//     len: std.atomic.Atomic(u32) = .{},
//     // zombies is the number of timers in the heap
//     // that are marked for removal.
//     zombies: std.atomic.Atomic(i32) = .{},
//     // raceCtx is the race context used while executing timer functions.
//     raceCtx: usize = 0,
//     // minWhenHeap is the minimum heap[i].when value (= heap[0].when).
//     // The wakeTime method uses minWhenHeap and minWhenModified
//     // to determine the next wake time.
//     // If minWhenHeap = 0, it means there are no timers in the heap.
//     minWhenHeap: std.atomic.Atomic(i64) = .{},
//     // minWhenModified is a lower bound on the minimum
//     // heap[i].when over timers with the timerModified bit set.
//     // If minWhenModified = 0, it means there are no timerModified timers in the heap.
//     minWhenModified: std.atomic.Atomic(i64) = .{},
//
//     pub fn init(self: *Timers) void {
//         self.heap = std.PriorityQueue(TimerWhen).init();
//         self.zombies = std.atomic.Atomic(0);
//         self.minWhenHeap = std.atomic.AtomicI64.init(0);
//         self.minWhenModified = std.atomic.AtomicI64.init(0);
//     }
//
//     pub fn addHeap(self: *Timers, t: *Timer) void {
//         self.mu.lock();
//         defer self.mu.unlock();
//
//         if (t.ts != null) {
//             self.debug.print("ts set in timer");
//         }
//
//         t.ts = self;
//         self.heap.add(TimerWhen{ .timer = t, .when = t.when });
//         self.updateMinWhenHeap();
//     }
//
//     pub fn updateMinWhenHeap(self: *Timers) void {
//         // TODO: expect lock to be held
//         while (true) {
//             if (self.heap.items.len == 0) {
//                 @atomicStore(i64, &self.minWhenHeap, 0, .SeqCst);
//                 return;
//             }
//
//             const when = self.heap.peek().?.when;
//             @atomicStore(i64, &self.minWhenHeap, when, .SeqCst);
//             return;
//         }
//     }
//
//     pub fn updateMinWhenModified(self: *Timers, when: i64) void {
//         while (true) {
//             const old = @atomicLoad(i64, &self.minWhenModified, .SeqCst);
//             if (old != 0 and old < when) {
//                 return;
//             }
//
//             if (@cmpxchgStrong(i64, &self.minWhenModified, old, when, .SeqCst, .SeqCst)) {
//                 return;
//             }
//         }
//     }
// };
//
// pub fn lock(ts: *Timers) void {
//     ts.mu.lock();
// }
//
// pub fn unlock(ts: *Timers) void {
//     // Update atomic copy of len(ts.heap).
//     ts.len.store(@as(u32, @intCast(ts.heap.items.len)));
//     ts.mu.unlock();
// }
//
// // Timer state field.
// pub const TimerState = enum(u8) {
//     // timerHeaped is set when the timer is stored in some P's heap.
//     timerHeaped = 1 << 0,
//     timerModified,
//     timerZombie,
// };
