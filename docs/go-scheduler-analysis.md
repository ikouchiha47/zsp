# Go M:N:P Scheduler Analysis

Analysis of Go's runtime scheduler compared to `runtime.zig` implementation.

## Source Files

| File | Description | Link |
|------|-------------|------|
| `runtime2.go` | G, M, P struct definitions | [runtime2.go](https://github.com/golang/go/blob/master/src/runtime/runtime2.go) |
| `proc.go` | Scheduler logic, work stealing | [proc.go](https://github.com/golang/go/blob/master/src/runtime/proc.go) |
| `stack.go` | Stack management, growth | [stack.go](https://github.com/golang/go/blob/master/src/runtime/stack.go) |
| `chan.go` | Channel implementation | [chan.go](https://github.com/golang/go/blob/master/src/runtime/chan.go) |

---

## G (Goroutine)

**Go**: [runtime2.go#L473-L598](https://github.com/golang/go/blob/master/src/runtime/runtime2.go#L473-L598)

### Go's G struct (key fields)

```go
type g struct {
    stack       stack      // [stack.lo, stack.hi) - actual stack memory
    stackguard0 uintptr    // for stack growth prologue
    stackguard1 uintptr    // for systemstack growth

    _panic    *_panic      // innermost panic
    _defer    *_defer      // innermost defer
    m         *m           // current M running this G
    sched     gobuf        // saved context (SP, PC, BP, etc.)

    atomicstatus atomic.Uint32  // G status (atomic for safe reads)
    goid         uint64         // unique goroutine ID
    schedlink    guintptr       // link for run queues

    waitsince    int64          // when G became blocked
    waitreason   waitReason     // why G is waiting

    preempt       bool          // preemption signal
    preemptStop   bool          // stop on preemption

    lockedm       muintptr      // locked to specific M
    startpc       uintptr       // pc of go statement that created this
}
```

### Comparison

| Field | Go | runtime.zig | Notes |
|-------|-----|-------------|-------|
| Stack | `stack`, `stackguard0/1` | ❌ Missing | Go has growable stacks |
| Context | `sched gobuf` (SP, PC, BP, G, ret) | ❌ Missing | For context switching |
| Status | `atomicstatus` (11 states) | `State` enum (4 states) | Go uses atomic ops |
| M link | `m *m` | ❌ Missing | Which M is running this G |
| Queue link | `schedlink guintptr` | ❌ Missing | For linking in run queues |
| Preemption | `preempt`, `preemptStop` | ❌ Missing | Async preemption support |
| Wait info | `waitsince`, `waitreason` | ❌ Missing | Debugging/profiling |
| ID | `goid uint64` | `id: usize` ✓ | |

### G States

**Go** ([runtime2.go#L15-L116](https://github.com/golang/go/blob/master/src/runtime/runtime2.go#L15-L116)):

```go
const (
    _Gidle = iota      // 0 - just allocated
    _Grunnable         // 1 - on run queue
    _Grunning          // 2 - running on M
    _Gsyscall          // 3 - in syscall
    _Gwaiting          // 4 - blocked (chan, select, etc.)
    _Gdead             // 6 - finished, on free list
    _Gcopystack        // 8 - stack being copied
    _Gpreempted        // 9 - stopped due to preemption
    _Gscan             // combined with above for GC scanning
)
```

**runtime.zig**:
```zig
pub const State = enum {
    Runnable,
    Running,
    Waiting,
    Done,
};
```

---

## M (Machine / OS Thread)

**Go**: [runtime2.go#L618-L728](https://github.com/golang/go/blob/master/src/runtime/runtime2.go#L618-L728)

### Go's M struct (key fields)

```go
type m struct {
    g0       *g           // goroutine with scheduling stack
    curg     *g           // current running goroutine
    p        puintptr     // attached P for running Go code
    nextp    puintptr     // next P to attach
    oldp     puintptr     // P before syscall

    id       int64
    spinning bool         // looking for work
    blocked  bool         // blocked on note

    park     note         // for parking/unparking
    schedlink muintptr    // for M free list
    lockedg   guintptr    // G locked to this M

    // for syscall handling
    syscalltick uint32
}
```

### Comparison

| Field | Go | runtime.zig | Notes |
|-------|-----|-------------|-------|
| g0 | `g0 *g` | ❌ Missing | Scheduler runs on g0 stack |
| Current G | `curg *g` | `current_g: ?*G` ✓ | |
| Current P | `p puintptr` | ❌ Missing | M-P binding |
| Spinning | `spinning bool` | ❌ Missing | Work stealing state |
| Park/Wake | `park note` | ❌ Missing | Thread sleep/wake |
| ID | `id int64` | `id: usize` ✓ | |
| Locked G | `lockedg guintptr` | ❌ Missing | LockOSThread support |

### Key Concept: g0

Every M has a `g0` - a special goroutine used for:
- Running the scheduler
- Handling signals
- Stack that doesn't grow

```go
// In schedule():
mp := getg().m  // get current g, then its M
// Scheduler code runs on g0's stack
```

---

## P (Processor / Scheduling Context)

**Go**: [runtime2.go#L773-L920](https://github.com/golang/go/blob/master/src/runtime/runtime2.go#L773-L920)

### Go's P struct (key fields)

```go
type p struct {
    id          int32
    status      uint32     // pidle/prunning/psyscall/pgcstop/pdead
    m           muintptr   // back-link to associated M

    // Local run queue (lock-free)
    runqhead uint32
    runqtail uint32
    runq     [256]guintptr  // circular buffer, fixed size

    // Fast path for recently ready'd G
    runnext guintptr

    // Free G's for reuse
    gFree gList

    // Timers
    timers timerHeap

    schedtick   uint32     // incremented on every scheduler call
    syscalltick uint32     // incremented on every syscall
}
```

### Comparison

| Field | Go | runtime.zig | Notes |
|-------|-----|-------------|-------|
| Run queue | `runq [256]guintptr` | `run_queue: ArrayList` | Go uses fixed ring buffer |
| Head/Tail | `runqhead/tail uint32` | ❌ (in ArrayList) | Lock-free atomics |
| Runnext | `runnext guintptr` | ❌ Missing | Fast path optimization |
| Status | `status uint32` | ❌ Missing | P lifecycle |
| M link | `m muintptr` | ❌ Missing | P-M binding |
| Free list | `gFree gList` | ❌ Missing | G reuse pool |
| Timers | `timers timerHeap` | ❌ Missing | Per-P timer heap |
| ID | `id int32` | `id: usize` ✓ | |

### P States

```go
const (
    _Pidle = iota
    _Prunning   // M is running Go code with this P
    _Psyscall   // M is in syscall, P may be stolen
    _Pgcstop    // stopped for GC
    _Pdead      // no longer used
)
```

---

## Scheduler Functions

### schedule()

**Go**: [proc.go#L4135-L4240](https://github.com/golang/go/blob/master/src/runtime/proc.go#L4135-L4240)

Main scheduler loop:

```go
func schedule() {
    mp := getg().m

top:
    pp := mp.p.ptr()

    // Find runnable G (may block)
    gp, inheritTime, tryWakeP := findRunnable()

    // Reset spinning state
    if mp.spinning {
        resetspinning()
    }

    // Run the G
    execute(gp, inheritTime)
}
```

### findRunnable()

**Go**: [proc.go#L3389-L3700](https://github.com/golang/go/blob/master/src/runtime/proc.go#L3389-L3700)

Priority order for finding work:

```go
func findRunnable() (gp *g, inheritTime, tryWakeP bool) {
    pp := mp.p.ptr()

    // 1. Check local runnext (fast path)
    // 2. Check local runq
    if gp, inheritTime := runqget(pp); gp != nil {
        return gp, inheritTime, false
    }

    // 3. Check global runq (every 61 ticks for fairness)
    if pp.schedtick%61 == 0 && !sched.runq.empty() {
        gp := globrunqget()
        if gp != nil {
            return gp, false, false
        }
    }

    // 4. Poll network
    if netpollinited() && netpollAnyWaiters() {
        list, _ := netpoll(0)
        if !list.empty() {
            return list.pop(), false, false
        }
    }

    // 5. Steal from other P's
    if mp.spinning || 2*nmspinning < gomaxprocs-npidle {
        gp, inheritTime, _, _, _ := stealWork(now)
        if gp != nil {
            return gp, inheritTime, false
        }
    }

    // 6. Block waiting for work
    // ...
}
```

### Work Stealing

**Go**: [proc.go#L7730-L7747](https://github.com/golang/go/blob/master/src/runtime/proc.go#L7730-L7747)

```go
// Steal half of p2's runqueue
func runqsteal(pp, p2 *p, stealRunNextG bool) *g {
    t := pp.runqtail
    n := runqgrab(p2, &pp.runq, t, stealRunNextG)
    if n == 0 {
        return nil
    }
    n--
    gp := pp.runq[(t+n)%uint32(len(pp.runq))].ptr()
    atomic.StoreRel(&pp.runqtail, t+n)
    return gp
}
```

Key insight: **Steal half** of the victim's queue, not just one G.

### runqgrab()

**Go**: [proc.go#L7694-L7728](https://github.com/golang/go/blob/master/src/runtime/proc.go#L7694-L7728)

Lock-free stealing using atomic compare-and-swap:

```go
func runqgrab(pp *p, batch *[256]guintptr, batchHead uint32, stealRunNextG bool) uint32 {
    for {
        h := atomic.LoadAcq(&pp.runqhead)
        t := atomic.LoadAcq(&pp.runqtail)
        n := t - h
        n = n - n/2  // steal half

        if n == 0 {
            // Try to steal runnext
            if stealRunNextG {
                if next := pp.runnext; next != 0 {
                    if atomic.CasRel(&pp.runnext, next, 0) {
                        batch[batchHead%256] = next
                        return 1
                    }
                }
            }
            return 0
        }

        // Copy G's to batch
        // ...

        // CAS to claim the G's
        if atomic.CasRel(&pp.runqhead, h, h+n) {
            return n
        }
    }
}
```

---

## Spinning M's

**Go**: [proc.go#L3512-L3538](https://github.com/golang/go/blob/master/src/runtime/proc.go#L3512-L3538)

Idle M's enter "spinning" state to look for work:

```go
// Limit spinning to half of busy P's
if mp.spinning || 2*sched.nmspinning.Load() < gomaxprocs-sched.npidle.Load() {
    if !mp.spinning {
        mp.becomeSpinning()
    }
    gp, inheritTime, _, _, _ := stealWork(now)
    // ...
}
```

Why limit spinning?
- Prevents CPU waste when GOMAXPROCS >> actual parallelism
- At most `GOMAXPROCS/2` M's spinning at once

---

## Handoff (Syscall Handling)

**Go**: [proc.go#L2870-L2960](https://github.com/golang/go/blob/master/src/runtime/proc.go#L2870-L2960)

When G enters syscall, P can be handed to another M:

```go
func handoffp(pp *p) {
    // If local work, start M to run it
    if !runqempty(pp) || sched.runq.empty() == false {
        startm(pp, false, false)
        return
    }

    // No work, put P on idle list
    pidleput(pp, 0)
}
```

This is critical for M:N:P - allows other G's to run while one is blocked in syscall.

---

## What runtime.zig Needs

### 1. Context Switching (gobuf equivalent)

```zig
const GoBuf = struct {
    sp: usize,    // stack pointer
    pc: usize,    // program counter
    bp: usize,    // base pointer
    g: *G,        // back pointer
};
```

### 2. Lock-free Run Queue

```zig
const RunQueue = struct {
    head: std.atomic.Value(u32),
    tail: std.atomic.Value(u32),
    buf: [256]*G,

    fn push(self: *RunQueue, g: *G) bool { ... }
    fn pop(self: *RunQueue) ?*G { ... }
    fn steal(self: *RunQueue, victim: *RunQueue) u32 { ... }
};
```

### 3. P-M Binding

```zig
const P = struct {
    id: usize,
    status: std.atomic.Value(PStatus),
    m: ?*M,                    // current M
    runq: RunQueue,            // local run queue
    runnext: std.atomic.Value(?*G),  // fast path
};

const M = struct {
    id: usize,
    g0: *G,                    // scheduler goroutine
    curg: ?*G,                 // current user G
    p: ?*P,                    // attached P
    spinning: bool,
    park: std.Thread.ResetEvent,
};
```

### 4. Global Scheduler State

```zig
const Sched = struct {
    lock: std.Thread.Mutex,

    runq: GlobalRunQueue,      // global run queue
    runqsize: std.atomic.Value(i32),

    midle: ?*M,                // idle M's
    nmidle: std.atomic.Value(i32),

    pidle: ?*P,                // idle P's
    npidle: std.atomic.Value(i32),

    nmspinning: std.atomic.Value(i32),
};
```

---

---

## Acceptance Criteria (Zig Pseudocode)

### AC-1: G (Goroutine) Structure

```zig
const G = struct {
    id: u64,
    status: Status,
    stack: Stack,
    sched: GoBuf,           // saved registers for context switch
    m: ?*M,                 // current M (null if not running)
    sched_link: ?*G,        // intrusive list link for queues
    wait_reason: WaitReason,
    preempt: bool,

    const Status = enum(u8) {
        idle,       // just allocated
        runnable,   // on a run queue, not running
        running,    // running on an M
        syscall,    // in syscall, M may be released
        waiting,    // blocked on channel/select/mutex
        dead,       // finished execution
        preempted,  // stopped for preemption
    };

    const Stack = struct {
        lo: usize,  // low address (stack grows down)
        hi: usize,  // high address
    };

    const WaitReason = enum {
        none,
        chan_receive,
        chan_send,
        select,
        sleep,
        mutex,
    };
};
```

### AC-2: M (Machine) Structure

```zig
const M = struct {
    id: u64,
    g0: *G,                 // scheduler G (never nil)
    curg: ?*G,              // currently running user G
    p: ?*P,                 // attached P (nil = not running user code)
    nextp: ?*P,             // next P to acquire
    spinning: bool,         // actively looking for work
    park: std.Thread.ResetEvent,  // for parking this M
    thread: std.Thread,     // underlying OS thread

    // MUST: Each M has a g0 for running scheduler code
    // MUST: curg is set when running user G, nil otherwise
    // MUST: p is set when running Go code, nil during syscall
};
```

### AC-3: P (Processor) Structure

```zig
const P = struct {
    id: u32,
    status: Status,
    m: ?*M,                 // back-link to M (nil if idle)

    // Local run queue (lock-free, fixed size)
    runq_head: Atomic(u32),
    runq_tail: Atomic(u32),
    runq: [256]?*G,

    // Fast path: G that should run next
    runnext: Atomic(?*G),

    sched_tick: u32,        // incremented each schedule()

    const Status = enum(u8) {
        idle,      // not associated with M
        running,   // associated with M, running user code
        syscall,   // M in syscall, P may be stolen
        stopped,   // stopped for GC or runtime request
    };

    // MUST: runq is lock-free ring buffer
    // MUST: runnext provides O(1) fast path for producer-consumer pattern
};
```

### AC-4: Global Scheduler State

```zig
const Sched = struct {
    lock: Mutex,

    // Global run queue
    runq: GQueue,
    runq_size: Atomic(i32),

    // Idle M's (linked via m.sched_link)
    midle: ?*M,
    nmidle: Atomic(i32),

    // Idle P's (linked via p.link)
    pidle: ?*P,
    npidle: Atomic(i32),

    // Number of spinning M's
    nmspinning: Atomic(i32),

    // All P's (fixed at startup based on GOMAXPROCS)
    allp: []*P,

    // MUST: Access to runq, midle, pidle requires lock
    // MUST: nmspinning is atomic, limits spinning to GOMAXPROCS/2
};

var sched: Sched = undefined;
```

### AC-5: schedule() - Main Loop

```zig
fn schedule() void {
    const mp = getM();

    while (true) {
        const pp = mp.p.?;

        // Find runnable G (may block)
        const gp = findRunnable();

        // Reset spinning if we were
        if (mp.spinning) {
            resetSpinning();
        }

        // Execute the G
        execute(gp);
    }
}

// MUST: schedule() never returns
// MUST: always have a P attached before calling findRunnable()
// MUST: reset spinning before executing to allow another M to spin
```

### AC-6: findRunnable() - Work Finding

```zig
fn findRunnable() *G {
    const mp = getM();
    const pp = mp.p.?;

    while (true) {
        // 1. Check local runnext (fast path)
        if (pp.runnext.swap(null, .acquire)) |gp| {
            return gp;
        }

        // 2. Check local runq
        if (runqGet(pp)) |gp| {
            return gp;
        }

        // 3. Check global runq (every 61 ticks for fairness)
        if (pp.sched_tick % 61 == 0) {
            sched.lock.lock();
            defer sched.lock.unlock();
            if (globRunqGet()) |gp| {
                return gp;
            }
        }

        // 4. Poll network (non-blocking)
        if (netpollReady()) |gp| {
            return gp;
        }

        // 5. Steal from other P's
        if (mp.spinning or canSpin()) {
            if (!mp.spinning) {
                mp.spinning = true;
                sched.nmspinning.fetchAdd(1, .seq_cst);
            }

            if (stealWork()) |gp| {
                return gp;
            }
        }

        // 6. No work found - stop spinning and park
        if (mp.spinning) {
            mp.spinning = false;
            sched.nmspinning.fetchSub(1, .seq_cst);
        }

        // Release P and park M
        releaseP(pp);
        parkM();

        // Woken up - acquire P and retry
        acquireP();
    }
}

fn canSpin() bool {
    // Limit spinning M's to GOMAXPROCS/2
    return 2 * sched.nmspinning.load(.seq_cst) < sched.allp.len - sched.npidle.load(.seq_cst);
}

// MUST: Try local work before global
// MUST: Check global queue periodically for fairness
// MUST: Limit spinning to avoid CPU waste
// MUST: Park when no work found
```

### AC-7: stealWork() - Work Stealing

```zig
fn stealWork() ?*G {
    const pp = getM().p.?;

    // Randomize starting point to avoid contention
    const start = randomOrder(sched.allp.len);

    for (0..sched.allp.len) |i| {
        const p2 = sched.allp[(start + i) % sched.allp.len];

        // Don't steal from self
        if (p2 == pp) continue;

        // Don't steal from idle P's
        if (p2.status.load(.acquire) != .running) continue;

        // Try to steal runnext first
        if (p2.runnext.swap(null, .acquire)) |gp| {
            return gp;
        }

        // Steal half of p2's runq
        if (runqSteal(pp, p2)) |gp| {
            return gp;
        }
    }

    return null;
}

fn runqSteal(pp: *P, p2: *P) ?*G {
    const t = pp.runq_tail.load(.acquire);

    while (true) {
        const h = p2.runq_head.load(.acquire);
        const t2 = p2.runq_tail.load(.acquire);
        var n = t2 - h;
        if (n == 0) return null;

        n = n - n / 2;  // steal half

        // Copy G's from p2 to pp
        for (0..n) |i| {
            const idx = (h + i) % 256;
            pp.runq[(t + i) % 256] = p2.runq[idx];
        }

        // CAS to claim the G's
        if (p2.runq_head.cmpxchgWeak(h, h + n, .acq_rel, .acquire)) |_| {
            continue;  // retry
        }

        // Update our tail
        pp.runq_tail.store(t + n, .release);

        // Return last stolen G
        return pp.runq[(t + n - 1) % 256];
    }
}

// MUST: Steal HALF of victim's queue, not just one
// MUST: Use CAS for lock-free stealing
// MUST: Try runnext before runq
// MUST: Randomize victim selection
```

### AC-8: runqPut() / runqGet() - Local Queue

```zig
fn runqPut(pp: *P, gp: *G, next: bool) void {
    if (next) {
        // Fast path: put in runnext
        const old = pp.runnext.swap(gp, .acq_rel);
        if (old == null) return;
        gp = old;  // put old runnext in runq
    }

    while (true) {
        const h = pp.runq_head.load(.acquire);
        const t = pp.runq_tail.load(.acquire);

        if (t - h < 256) {
            // Space available
            pp.runq[t % 256] = gp;
            pp.runq_tail.store(t + 1, .release);
            return;
        }

        // Queue full - put half in global queue
        runqPutSlow(pp, gp, h, t);
        return;
    }
}

fn runqGet(pp: *P) ?*G {
    while (true) {
        const h = pp.runq_head.load(.acquire);
        const t = pp.runq_tail.load(.acquire);

        if (t == h) return null;

        const gp = pp.runq[h % 256];
        if (pp.runq_head.cmpxchgWeak(h, h + 1, .acq_rel, .acquire)) |_| {
            continue;  // retry
        }
        return gp;
    }
}

// MUST: runnext is fast path for producer-consumer
// MUST: Overflow to global queue when full
// MUST: Lock-free using atomics
```

### AC-9: goready() - Make G Runnable

```zig
fn goready(gp: *G) void {
    // Change status
    gp.status = .runnable;

    // Put on current P's queue
    const pp = getM().p.?;
    runqPut(pp, gp, true);  // next=true for fast path

    // Wake idle M if needed
    if (sched.npidle.load(.acquire) > 0 and sched.nmspinning.load(.acquire) == 0) {
        wakep();
    }
}

fn wakep() void {
    // Try to start a spinning M
    if (sched.nmspinning.fetchAdd(1, .acq_rel) > 0) {
        sched.nmspinning.fetchSub(1, .release);
        return;  // someone already spinning
    }

    // Get idle P
    sched.lock.lock();
    const pp = pidleGet();
    sched.lock.unlock();

    if (pp == null) {
        sched.nmspinning.fetchSub(1, .release);
        return;
    }

    // Start M with this P
    startm(pp, true);
}

// MUST: Wake M when there's idle P and no spinners
// MUST: Only one M starts spinning per wakeup
```

### AC-10: Handoff on Syscall

```zig
fn entersyscall() void {
    const mp = getM();
    const gp = mp.curg.?;
    const pp = mp.p.?;

    // Save state
    gp.status = .syscall;
    gp.sched = saveContext();

    // Release P (another M can take it)
    pp.status.store(.syscall, .release);
    mp.p = null;
}

fn exitsyscall() void {
    const mp = getM();
    const gp = mp.curg.?;

    // Try to reacquire old P
    if (mp.oldp) |pp| {
        if (pp.status.cmpxchgStrong(.syscall, .running, .acq_rel, .acquire) == null) {
            mp.p = pp;
            gp.status = .running;
            return;
        }
    }

    // Old P was taken - need to find a new one
    gp.status = .runnable;
    globRunqPut(gp);

    // Park this M or find work
    schedule();
}

fn handoffp(pp: *P) void {
    // Called by sysmon when P is idle in syscall too long
    if (!runqEmpty(pp) or !sched.runq.empty()) {
        // Work available - start M to run it
        startm(pp, false);
    } else {
        // No work - put P idle
        pidlePut(pp);
    }
}

// MUST: Release P when entering syscall
// MUST: Try to reacquire same P on exit
// MUST: sysmon monitors syscall duration and hands off P
```

---

## Test Scenarios

### T-1: Basic Spawn and Schedule

```zig
test "spawn and run goroutine" {
    const g1 = spawn(task1);
    const g2 = spawn(task2);

    // Both should complete
    wait(g1);
    wait(g2);
}
```

### T-2: Work Stealing

```zig
test "work stealing" {
    // P0 has many G's, P1 is idle
    for (0..100) |_| {
        spawnOnP(task, p0);
    }

    // P1 should steal ~50 G's
    runScheduler();

    expect(p0.runqSize() < 60);
    expect(p1.runqSize() > 40);
}
```

### T-3: Syscall Handoff

```zig
test "syscall handoff" {
    const g1 = spawn(blockingSyscall);  // blocks for 100ms

    // Another G should run while g1 is blocked
    const g2 = spawn(quickTask);

    // g2 completes before g1
    expect(g2.finished_before(g1));
}
```

### T-4: Fairness

```zig
test "global queue fairness" {
    // Spawn 1000 G's
    for (0..1000) |i| {
        spawn(recordOrder, i);
    }

    // All should run, roughly in order
    expect(order_variance < threshold);
}
```

---

## References

- [Go Scheduler Design Doc](https://docs.google.com/document/d/1TTj4T2JO42uD5ID9e89oa0sLKhJYD0Y_kqxDv3I3XMw/edit)
- [Scalable Go Scheduler (2012)](https://docs.google.com/document/d/1TTj4T2JO42uD5ID9e89oa0sLKhJYD0Y_kqxDv3I3XMw)
- [Go source: runtime](https://github.com/golang/go/tree/master/src/runtime)
- [GopherCon 2018: The Scheduler Saga](https://www.youtube.com/watch?v=YHRO5WQGh0k)
