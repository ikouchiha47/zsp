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

## GoBuf (Context Save/Restore)

**Go**: [runtime2.go#L303-L322](https://github.com/golang/go/blob/master/src/runtime/runtime2.go#L303-L322)

```go
type gobuf struct {
    sp   uintptr        // stack pointer
    pc   uintptr        // program counter
    g    guintptr       // back pointer to G
    ctxt unsafe.Pointer // closure context
    lr   uintptr        // link register (ARM)
    bp   uintptr        // base pointer (x86)
}
```

This is the minimal state needed to suspend and resume a goroutine.

---

## sysmon (System Monitor)

**Go**: [proc.go#L6486-L6620](https://github.com/golang/go/blob/master/src/runtime/proc.go#L6486-L6620)

Dedicated goroutine that runs without a P, handling:

1. **Network polling** - if not polled for >10ms
2. **Retake P's** - from G's stuck in syscalls
3. **Preemption** - of long-running G's (>10ms)
4. **GC triggering** - force GC if needed
5. **Scavenger wake** - return memory to OS

```go
func sysmon() {
    idle := 0
    delay := uint32(20) // start with 20µs

    for {
        usleep(delay)

        // Adaptive sleep: 20µs → 10ms based on idle cycles
        if idle > 50 {
            delay *= 2
        }
        if delay > 10*1000 {
            delay = 10 * 1000
        }

        // Poll network if stale
        if lastpoll+10ms < now {
            netpoll(0)
        }

        // Retake P's and preempt long-running G's
        if retake(now) != 0 {
            idle = 0
        } else {
            idle++
        }

        // Force GC if needed
        if gcTrigger.test() {
            forcegc()
        }
    }
}
```

---

## retake() - P Recovery

**Go**: [proc.go#L6630-L6730](https://github.com/golang/go/blob/master/src/runtime/proc.go#L6630-L6730)

Called by sysmon to reclaim P's from:
- G's running too long (>10ms) → preempt
- G's stuck in syscall (>10-20ms) → steal P

```go
func retake(now int64) uint32 {
    for _, pp := range allp {
        if pp.status != _Prunning {
            continue
        }

        // Preempt if running too long (10ms)
        if pd.schedwhen+forcePreemptNS <= now {
            preemptone(pp)
        }

        // Retake P if in syscall too long
        if pd.syscallwhen+10ms <= now {
            handoffp(pp)  // give P to another M
        }
    }
}
```

Key constant: `forcePreemptNS = 10ms`

---

## preemptone() - Cooperative Preemption

**Go**: [proc.go#L6866-L6895](https://github.com/golang/go/blob/master/src/runtime/proc.go#L6866-L6895)

```go
func preemptone(pp *p) bool {
    gp := pp.m.ptr().curg

    // Set preemption flag
    gp.preempt = true

    // Trick: set stackguard0 to trigger "stack overflow"
    // Next function call will check and yield
    gp.stackguard0 = stackPreempt

    // Async preemption via signal (Go 1.14+)
    if preemptMSupported {
        pp.preempt = true
        preemptM(mp)  // send signal to thread
    }

    return true
}
```

**Two mechanisms:**
1. **Cooperative** - stackguard0 trick, checked at function entry
2. **Async** (Go 1.14+) - SIGURG signal to thread, can preempt tight loops

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

# Pony Actor Model Comparison

## Source Files

| File | Description | Link |
|------|-------------|------|
| `scheduler.h` | Scheduler + context definitions | [scheduler.h](https://github.com/ponylang/ponyc/blob/main/src/libponyrt/sched/scheduler.h) |
| `scheduler.c` | Work stealing scheduler | [scheduler.c](https://github.com/ponylang/ponyc/blob/main/src/libponyrt/sched/scheduler.c) |
| `actor.h` | Actor structure | [actor.h](https://github.com/ponylang/ponyc/blob/main/src/libponyrt/actor/actor.h) |
| `mpmcq.h/c` | Multi-producer multi-consumer queue | [mpmcq.h](https://github.com/ponylang/ponyc/blob/main/src/libponyrt/sched/mpmcq.h) |

---

## Actor vs Goroutine vs Thread

| Aspect | Thread | Goroutine (Go) | Actor (Pony) |
|--------|--------|----------------|--------------|
| **Memory** | ~1MB stack | ~2KB (growable) | ~256 bytes |
| **Creation** | OS syscall | Runtime alloc | Runtime alloc |
| **Communication** | Shared memory + locks | Channels | Message passing |
| **State** | Shared (needs sync) | Shared (needs sync) | **Isolated** (no sharing) |
| **Scheduling** | OS preemptive | Runtime M:N:P | Runtime work-stealing |
| **Safety** | Manual | Runtime checks | **Type system (caps)** |

---

## Pony Actor Structure

[actor.h#L83-L100](https://github.com/ponylang/ponyc/blob/main/src/libponyrt/actor/actor.h#L83-L100)

```c
typedef struct pony_actor_t
{
  pony_type_t* type;
  messageq_t q;           // per-actor message queue
  PONY_ATOMIC(uint8_t) sync_flags;

  // Separate cache line for local access
  alignas(64) heap_t heap; // per-actor heap!
  size_t muted;
  uint8_t internal_flags;
  gc_t gc;                 // per-actor GC state
} pony_actor_t;
```

**Key insight**: Each actor has its own **heap** and **GC**. No global stop-the-world!

---

## Pony Scheduler Structure

[scheduler.h#L101-L125](https://github.com/ponylang/ponyc/blob/main/src/libponyrt/sched/scheduler.h#L101-L125)

```c
struct scheduler_t
{
  pony_thread_id_t tid;
  int32_t index;
  bool terminate;

  // Per-scheduler context
  pony_ctx_t ctx;

  // Work stealing target
  alignas(64) struct scheduler_t* last_victim;

  // Local queue (MPMC for stealing)
  mpmcq_t q;

  // Internal message queue
  messageq_t mq;
};
```

---

## Pony's Work Stealing

[scheduler.c#L909-L1030](https://github.com/ponylang/ponyc/blob/main/src/libponyrt/sched/scheduler.c#L909-L1030)

```c
static pony_actor_t* steal(scheduler_t* sched)
{
  uint32_t steal_attempts = 0;
  uint64_t tsc = ponyint_cpu_tick();

  while(true)
  {
    // 1. Choose victim (round-robin from last_victim)
    scheduler_t* victim = choose_victim(sched);

    // 2. Try global queue first, then victim's queue
    pony_actor_t* actor = pop_global(victim);
    if(actor != NULL)
      return actor;

    // 3. Check for messages (unmuted actors)
    if(read_msg(sched, actor)) {
      actor = pop_global(sched);
      if(actor != NULL)
        return actor;
    }

    // 4. Check quiescence (all done?)
    if(quiescent(sched, tsc, tsc2))
      return NULL;

    // 5. After N attempts + threshold, consider blocking
    if (steal_attempts >= active_scheduler_count &&
        clocks_elapsed > PONY_SCHED_BLOCK_THRESHOLD) {
      send_msg(SCHED_BLOCK);

      // Try to suspend this scheduler
      actor = perhaps_suspend_scheduler(sched);
      if (actor != NULL)
        return actor;
    }

    steal_attempts++;
  }
}
```

**Key differences from Go:**
- Steals **one actor** at a time (not half the queue)
- Uses **MPMC queue** (Go uses lock-free SPMC)
- **Adaptive scheduler count** - suspends idle schedulers
- **Block/unblock protocol** for termination detection

---

## Behaviours (Async Methods)

In Pony, actors receive messages via **behaviours**:

```pony
actor Counter
  var _count: U64 = 0

  // Behaviour: async, returns immediately
  be increment() =>
    _count = _count + 1

  // Behaviour: async message passing
  be get_count(main: Main) =>
    main.receive_count(_count)
```

This is fundamentally different from Go's channels:

| Pony Behaviours | Go Channels |
|-----------------|-------------|
| Method call syntax | Explicit send/receive |
| One receiver (the actor) | Multiple receivers possible |
| Always async | Can be sync (unbuffered) |
| No blocking | Can block sender/receiver |

---

## Reference Capabilities (Pony's Secret Sauce)

Pony guarantees data-race freedom at **compile time** via reference capabilities:

| Capability | Alias? | Read? | Write? | Use Case |
|------------|--------|-------|--------|----------|
| `iso` | No | Yes | Yes | Transfer ownership |
| `val` | Yes | Yes | No | Immutable shared data |
| `ref` | No | Yes | Yes | Mutable, single owner |
| `box` | Yes | Yes | No | Read-only alias |
| `tag` | Yes | No | No | Identity only |
| `trn` | No | Yes | Yes | Transition to `val` |

**Rule**: You can only **send** `iso`, `val`, or `tag` between actors.

This eliminates the need for:
- Locks
- Atomic operations for data
- Runtime race detection

---

## Comparison: Go M:N:P vs Pony Actors

| Aspect | Go M:N:P | Pony Actors |
|--------|----------|-------------|
| **Unit of work** | G (goroutine) | Actor |
| **Scheduling entity** | P (processor context) | Scheduler thread |
| **Work queue** | Per-P local + global | Per-scheduler + global inject |
| **Stealing** | Half of victim's queue | One actor at a time |
| **Preemption** | Yes (signal + stackguard) | No (run to completion) |
| **GC** | Global STW | Per-actor (no STW!) |
| **Memory model** | Shared memory + sync | Isolated heaps + messages |
| **Safety** | Runtime (race detector) | Compile time (caps) |

---

## Acceptance Criteria: Pony-style Actor (Zig)

### AC-P1: Actor Structure

```zig
const Actor = struct {
    type_info: *const TypeInfo,

    // Per-actor message queue (MPSC)
    mailbox: MessageQueue,

    // Per-actor heap (no shared GC!)
    heap: Heap,

    // Actor state
    flags: Flags,

    // Muting for backpressure
    muted: usize,

    const Flags = packed struct {
        blocked: bool = false,
        unscheduled: bool = false,
        pending_destroy: bool = false,
        overloaded: bool = false,
        muted: bool = false,
    };
};
```

### AC-P2: Message Structure

```zig
const Message = struct {
    // Message type ID
    id: u32,

    // Intrusive linked list
    next: ?*Message,

    // Payload follows (variable size)

    fn payload(self: *Message, comptime T: type) *T {
        return @ptrCast(@alignCast(@as([*]u8, @ptrCast(self)) + @sizeOf(Message)));
    }
};

const MessageQueue = struct {
    head: Atomic(?*Message),
    tail: *Atomic(?*Message),  // points to last node's next field

    // MPSC: multiple producers, single consumer
    fn push(self: *MessageQueue, msg: *Message) void { ... }
    fn pop(self: *MessageQueue) ?*Message { ... }
};
```

### AC-P3: Scheduler with Actor Stealing

```zig
const Scheduler = struct {
    tid: std.Thread.Id,
    index: u32,

    // Context for current execution
    ctx: Context,

    // Local work queue (MPMC for stealing)
    queue: MPMCQueue(*Actor),

    // Last victim for locality
    last_victim: ?*Scheduler,

    // Stats
    steal_attempts: u32,
};

const Context = struct {
    scheduler: *Scheduler,
    current: ?*Actor,  // actor being executed
};

// Global state
var schedulers: []Scheduler = undefined;
var inject_queue: MPMCQueue(*Actor) = .{};  // global inject
var active_count: Atomic(u32) = .{ .value = 0 };
```

### AC-P4: Actor Execution Loop

```zig
fn run(sched: *Scheduler) void {
    while (!sched.terminate) {
        // 1. Get actor from local queue
        var actor = sched.queue.pop();

        // 2. If empty, try global inject
        if (actor == null) {
            actor = inject_queue.pop();
        }

        // 3. If still empty, steal
        if (actor == null) {
            actor = steal(sched);
        }

        // 4. If nothing, maybe suspend
        if (actor == null) {
            maybeSuspend(sched);
            continue;
        }

        // 5. Run the actor (process messages)
        runActor(sched, actor.?);
    }
}

fn runActor(sched: *Scheduler, actor: *Actor) void {
    sched.ctx.current = actor;
    defer sched.ctx.current = null;

    // Process messages until empty or batch limit
    var batch: u32 = 0;
    while (actor.mailbox.pop()) |msg| {
        // Dispatch to behaviour handler
        actor.type_info.dispatch(actor, msg);

        batch += 1;
        if (batch >= MAX_BATCH) break;
    }

    // Reschedule if more messages
    if (!actor.mailbox.empty()) {
        sched.queue.push(actor);
    }
}
```

### AC-P5: Work Stealing (Pony-style)

```zig
fn steal(sched: *Scheduler) ?*Actor {
    const start_tsc = rdtsc();
    var attempts: u32 = 0;

    while (true) {
        // Choose victim (round-robin from last_victim)
        const victim = chooseVictim(sched);
        sched.last_victim = victim;

        // Try victim's queue
        if (victim.queue.pop()) |actor| {
            return actor;
        }

        // Try global inject
        if (inject_queue.pop()) |actor| {
            return actor;
        }

        // Check elapsed time
        const elapsed = rdtsc() - start_tsc;
        attempts += 1;

        // After trying all schedulers + threshold, consider blocking
        if (attempts >= active_count.load(.acquire) and
            elapsed > BLOCK_THRESHOLD) {

            if (maybeSuspend(sched)) {
                return null;  // suspended, will be woken later
            }
        }

        // Yield to avoid spinning
        std.Thread.yield();
    }
}

fn chooseVictim(sched: *Scheduler) *Scheduler {
    // Start from last victim for cache locality
    var idx = if (sched.last_victim) |v| v.index else 0;

    for (0..schedulers.len) |_| {
        idx = (idx + 1) % @intCast(schedulers.len);
        if (idx != sched.index) {
            return &schedulers[idx];
        }
    }

    return &schedulers[0];
}
```

### AC-P6: Backpressure (Muting)

```zig
fn send(sender: *Actor, receiver: *Actor, msg: *Message) void {
    receiver.mailbox.push(msg);

    // Check if receiver is overloaded
    if (receiver.flags.overloaded) {
        // Mute the sender (stop it from sending more)
        sender.muted += 1;
        receiver.muted_senders.push(sender);
    }

    // Schedule receiver if not already scheduled
    if (receiver.flags.unscheduled) {
        receiver.flags.unscheduled = false;
        scheduleActor(receiver);
    }
}

fn unmuteSenders(actor: *Actor) void {
    while (actor.muted_senders.pop()) |sender| {
        sender.muted -= 1;
        if (sender.muted == 0) {
            // Sender can run again
            scheduleActor(sender);
        }
    }
}
```

---

## Hybrid Approach: Best of Both?

For runtime.zig, consider a hybrid:

| Feature | From Go | From Pony |
|---------|---------|-----------|
| M:N:P structure | ✓ P contexts | |
| Work stealing | ✓ Steal half | |
| Preemption | ✓ Signal-based | |
| Per-actor heap | | ✓ No global GC pause |
| Message queues | | ✓ MPSC per actor |
| Backpressure | | ✓ Muting |
| Run-to-completion | | ✓ For short tasks |

---

# Erlang/BEAM Comparison

## Source Files & References

| Resource | Description | Link |
|----------|-------------|------|
| The BEAM Book | Deep dive into Erlang runtime | [theBeamBook](http://blog.stenmans.org/theBeamBook/) |
| BEAM Scheduling | Scheduling chapter | [scheduling.asciidoc](https://github.com/happi/theBeamBook/blob/master/chapters/scheduling.asciidoc) |
| Erlang Processes | Efficiency guide | [Erlang Docs](https://www.erlang.org/docs/22/efficiency_guide/processes) |
| Erlang Scheduler Deep Dive | 2024 article | [AppSignal Blog](https://blog.appsignal.com/2024/04/23/deep-diving-into-the-erlang-scheduler.html) |

---

## Erlang vs Pony vs Go

| Aspect | Erlang/BEAM | Pony | Go |
|--------|-------------|------|-----|
| **Typing** | Dynamic | Static + Caps | Static |
| **Execution** | Interpreted (BEAM) | Compiled (native) | Compiled (native) |
| **Unit** | Process | Actor | Goroutine |
| **Memory** | Per-process heap | Per-actor heap | Shared heap |
| **GC** | Per-process copying | Per-actor (ORCA) | Global STW |
| **Scheduling** | Preemptive (reductions) | Run-to-completion | Preemptive (signals) |
| **Hot reload** | Yes! | No | No |
| **Fault tolerance** | Supervisors, "let it crash" | Limited | Manual |

---

## Erlang Process Model

Each Erlang process has:
- **Own heap** - starts at 233 words, grows/shrinks as needed
- **Own stack** - no fixed size limits
- **Own GC** - no global stop-the-world!
- **Mailbox** - message queue

```erlang
% Spawn a new process
Pid = spawn(fun() -> loop(0) end),

% Send a message
Pid ! {increment, 5},

% Receive (blocks)
receive
    {result, Value} -> Value
end.
```

---

## BEAM Scheduler Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    BEAM VM                              │
├─────────────┬─────────────┬─────────────┬──────────────┤
│ Scheduler 1 │ Scheduler 2 │ Scheduler 3 │ Scheduler N  │
│   (core 0)  │   (core 1)  │   (core 2)  │   (core N)   │
├─────────────┼─────────────┼─────────────┼──────────────┤
│  Run Queue  │  Run Queue  │  Run Queue  │  Run Queue   │
│    ├─P1     │    ├─P4     │    ├─P7     │    ├─P10     │
│    ├─P2     │    ├─P5     │    ├─P8     │    ├─P11     │
│    └─P3     │    └─P6     │    └─P9     │    └─P12     │
└─────────────┴─────────────┴─────────────┴──────────────┘
```

**Key features:**
- One scheduler thread per CPU core (typically)
- Each scheduler has its own run queue
- Work stealing between schedulers
- Process migration for load balancing

---

## Reductions: Preemptive Scheduling

Erlang uses **reductions** for preemption - a counter that decrements with each operation:

| Operation | Reductions |
|-----------|------------|
| Function call | 1 |
| BIF (built-in function) | 1-many |
| Message send | ~8 |
| GC | varies |

**Default reduction limit**: ~4000 reductions per process before preemption

```erlang
% Process runs until:
% 1. Reduction count exhausted (preempted)
% 2. Waiting for message (yield)
% 3. Process exits
```

This is different from Go (signal-based) and Pony (run-to-completion).

---

## Erlang GC: Per-Process Generational

```
Process Heap (per-process):
┌─────────────────────────────────────┐
│         Young Generation            │
│  (frequently collected, short-lived)│
├─────────────────────────────────────┤
│          Old Generation             │
│ (infrequently collected, long-lived)│
└─────────────────────────────────────┘

Shared Binary Heap (global):
┌─────────────────────────────────────┐
│  Large binaries (>64 bytes)         │
│  Reference counted                  │
└─────────────────────────────────────┘
```

**GC characteristics:**
- Generational semi-space copying (Cheney's algorithm)
- Young gen: collected frequently
- Old gen: collected rarely (survived multiple GCs)
- No global STW! Only affects the running process
- Large binaries shared (reference counted)

---

## Message Passing: Copy vs Reference

| Data Type | Erlang | Pony | Go |
|-----------|--------|------|-----|
| Small data | **Copy** to receiver heap | Copy (via caps) | Pointer (shared) |
| Large binary | **Reference** (shared) | Copy or `iso` transfer | Pointer (shared) |
| Mutable | N/A (immutable!) | `iso` transfer | Mutex/channel |

Erlang's model is simpler because **everything is immutable** - copying is always safe.

---

## Fault Tolerance: Supervisors

Erlang's "let it crash" philosophy:

```erlang
% Supervisor tree
-module(my_sup).
-behaviour(supervisor).

init([]) ->
    {ok, {{one_for_one, 5, 10},  % restart strategy
          [{worker1, {my_worker, start_link, []},
            permanent, 5000, worker, [my_worker]}]}}.

% If worker crashes, supervisor restarts it
% "one_for_one": only restart the crashed child
% "one_for_all": restart all children
% "rest_for_one": restart crashed + children started after it
```

Neither Go nor Pony have built-in supervisor trees.

---

## Comparison: Scheduling Strategies

### Erlang: Reduction-Based Preemption

```
Process A runs → 4000 reductions → PREEMPT → Process B runs
                                     ↑
                               Scheduler decides
```

**Pros**: Fair, predictable, no infinite loops
**Cons**: Reduction counting overhead

### Pony: Run-to-Completion

```
Actor A runs → processes ALL messages (or batch) → yields → Actor B runs
                          ↑
                    Actor decides when done
```

**Pros**: No preemption overhead, better cache locality
**Cons**: Long-running behaviour can starve others

### Go: Signal-Based Preemption

```
G runs → 10ms timeout → SIGURG → G preempted → another G runs
                           ↑
                      sysmon sends signal
```

**Pros**: True preemption, handles tight loops
**Cons**: Signal handling complexity, platform-specific

---

## Acceptance Criteria: Erlang-style Features (Zig)

### AC-E1: Reduction-Based Scheduling

```zig
const Process = struct {
    // ...existing fields...
    reductions: u32 = 0,

    const REDUCTION_LIMIT = 4000;

    fn executeReduction(self: *Process) void {
        self.reductions += 1;
    }

    fn shouldYield(self: *Process) bool {
        return self.reductions >= REDUCTION_LIMIT;
    }

    fn resetReductions(self: *Process) void {
        self.reductions = 0;
    }
};

fn runProcess(sched: *Scheduler, proc: *Process) void {
    proc.resetReductions();

    while (proc.mailbox.pop()) |msg| {
        proc.dispatch(msg);

        // Check reduction count
        if (proc.shouldYield()) {
            // Reschedule, let others run
            sched.queue.push(proc);
            return;
        }
    }
}
```

### AC-E2: Per-Process Heap

```zig
const Process = struct {
    // Per-process heap (like Erlang)
    heap: ProcessHeap,

    // Per-process GC state
    gc: ProcessGC,

    const ProcessHeap = struct {
        young: []u8,      // young generation
        old: []u8,        // old generation
        young_ptr: usize, // allocation pointer
        old_ptr: usize,

        fn alloc(self: *ProcessHeap, size: usize) ?*anyopaque {
            // Allocate from young generation
            if (self.young_ptr + size <= self.young.len) {
                const ptr = self.young.ptr + self.young_ptr;
                self.young_ptr += size;
                return @ptrCast(ptr);
            }
            // Need GC
            return null;
        }
    };

    const ProcessGC = struct {
        generation: u8 = 0,
        collections: u32 = 0,

        fn collect(self: *ProcessGC, heap: *ProcessHeap) void {
            // Cheney's copying collection
            // Copy live data from young to new young (or old if survived)
            self.collections += 1;
        }
    };
};
```

### AC-E3: Shared Binary Heap

```zig
// Global shared heap for large binaries (like Erlang's refc binaries)
const SharedBinaryHeap = struct {
    lock: std.Thread.Mutex = .{},
    binaries: std.ArrayList(RefCountedBinary),

    const RefCountedBinary = struct {
        data: []u8,
        refcount: Atomic(u32),

        fn retain(self: *RefCountedBinary) void {
            _ = self.refcount.fetchAdd(1, .acq_rel);
        }

        fn release(self: *RefCountedBinary, heap: *SharedBinaryHeap) void {
            if (self.refcount.fetchSub(1, .acq_rel) == 1) {
                heap.free(self);
            }
        }
    };
};

// Threshold for shared vs copied
const BINARY_SHARE_THRESHOLD = 64;

fn sendBinary(sender: *Process, receiver: *Process, data: []const u8) void {
    if (data.len > BINARY_SHARE_THRESHOLD) {
        // Share via reference
        const shared = shared_heap.alloc(data);
        shared.retain(); // receiver's reference
        receiver.mailbox.push(.{ .shared_binary = shared });
    } else {
        // Copy to receiver's heap
        const copy = receiver.heap.alloc(data.len);
        @memcpy(copy, data);
        receiver.mailbox.push(.{ .binary = copy });
    }
}
```

### AC-E4: Supervisor Tree (Optional)

```zig
const Supervisor = struct {
    strategy: Strategy,
    max_restarts: u32,
    max_time: u64,  // in ms
    children: []ChildSpec,
    restart_history: RingBuffer(u64),

    const Strategy = enum {
        one_for_one,   // restart only crashed child
        one_for_all,   // restart all children
        rest_for_one,  // restart crashed + later children
    };

    const ChildSpec = struct {
        id: []const u8,
        start_fn: *const fn () *Process,
        restart: RestartType,
        process: ?*Process,
    };

    const RestartType = enum {
        permanent,  // always restart
        temporary,  // never restart
        transient,  // restart only if abnormal exit
    };

    fn handleChildExit(self: *Supervisor, child: *ChildSpec, reason: ExitReason) void {
        // Check restart limits
        const now = std.time.milliTimestamp();
        self.restart_history.push(now);

        if (self.tooManyRestarts()) {
            // Supervisor itself should crash
            @panic("supervisor max restarts exceeded");
        }

        switch (self.strategy) {
            .one_for_one => self.restartChild(child),
            .one_for_all => self.restartAllChildren(),
            .rest_for_one => self.restartChildrenAfter(child),
        }
    }
};
```

---

## Summary: Three Models

| Feature | Erlang | Pony | Go |
|---------|--------|------|-----|
| **Best for** | Fault-tolerant systems, telecom | High-performance, data races impossible | General purpose, simple concurrency |
| **Preemption** | Reductions (~4000) | None (run-to-completion) | Signals (~10ms) |
| **GC** | Per-process, no global pause | Per-actor (ORCA) | Global STW |
| **Memory** | Copy everything (immutable) | Caps control aliasing | Shared + sync |
| **Fault handling** | Supervisors, "let it crash" | Manual | Manual |
| **Hot code reload** | Yes | No | No |

---

# Zig Implementation Reality Check

## Native Code Constraints

Zig compiles to native machine code via LLVM. No VM, no bytecode, no interpreter.

| Feature | Erlang (BEAM) | Go | Pony | Zig |
|---------|---------------|-----|------|-----|
| Execution | Bytecode interpreter | Native | Native | Native |
| Hot reload | ✅ Yes | ❌ No | ❌ No | ❌ No |
| Reduction preemption | ✅ Yes | ❌ No | ❌ No | ❌ No |
| Signal preemption | N/A | ✅ Yes | ❌ No | ✅ Yes |
| Compiler-inserted checks | ✅ Yes | ✅ Yes | ❌ No | ❌ No |

---

## Why Hot Reload is Impossible

```
Erlang:
  Code → Bytecode → BEAM VM loads/swaps modules at runtime
                    ↓
  Functions referenced by name in module table
                    ↓
  Can swap module while processes run

Zig/Go/Pony:
  Code → LLVM → Native machine code
                    ↓
  Functions are memory addresses baked into binary
                    ↓
  No indirection layer to swap
```

**Workarounds (all have drawbacks):**
- `dlopen`/`dlsym` - complex state management
- Recompile + restart - loses in-flight state
- Build interpreter in Zig - defeats purpose

---

## Why Reduction Preemption is Impossible

Erlang's compiler inserts reduction checks everywhere:

```erlang
% Erlang compiler transforms this:
my_function(X) -> do_work(X).

% Into something like:
my_function(X) ->
    decrement_reductions(),      % ← compiler inserted
    check_should_yield(),        % ← compiler inserted
    do_work(X).
```

In Zig, we don't control the compiler. We can't inject checks at:
- Every function entry
- Every loop back-edge
- Every BIF call

**Go cheats** by controlling its own compiler - inserts `stackguard0` checks.

---

## What Zig CAN Do

### 1. Signal-Based Preemption (like Go 1.14+)

```zig
const SignalPreemption = struct {
    /// sysmon calls this for stuck G's
    pub fn preemptM(m: *M) void {
        // Send SIGURG to M's OS thread
        _ = std.os.linux.tgkill(
            std.os.linux.getpid(),
            m.tid,
            std.os.SIG.URG
        );
    }

    /// Runs on M's thread when signal received
    pub fn handler(
        _: i32,
        _: *std.os.siginfo_t,
        ctx_ptr: ?*anyopaque
    ) callconv(.C) void {
        const ctx: *std.os.ucontext_t = @ptrCast(@alignCast(ctx_ptr));
        const g = tls_current_g orelse return;

        // Save CPU registers from signal context
        g.saved_regs = SavedRegs.fromContext(ctx);
        g.status = .preempted;

        // Redirect execution to scheduler
        ctx.uc_mcontext.gregs[std.os.REG.RIP] = @intFromPtr(&schedule);
    }

    pub fn install() void {
        var sa = std.os.Sigaction{
            .handler = .{ .sigaction = handler },
            .mask = std.os.empty_sigset,
            .flags = std.os.SA.SIGINFO,
        };
        std.os.sigaction(std.os.SIG.URG, &sa, null);
    }
};
```

**Pros:** True preemption, handles infinite loops
**Cons:** Platform-specific, signal safety complexity, only works at interruptible points

### 2. Cooperative Preemption (flag checks)

```zig
/// G checks this at known safe points
pub fn checkPreempt() void {
    const g = getCurrentG() orelse return;
    if (g.preempt.load(.acquire)) {
        g.preempt.store(false, .release);
        yieldToScheduler();
    }
}

// Insert at: channel ops, mutex, I/O, sleep...
pub fn channelRecv(ch: *Channel, comptime T: type) ?T {
    checkPreempt();  // ← manual insertion
    // ... actual receive logic
}
```

**Pros:** Simple, portable, safe
**Cons:** Tight loops without checks run forever

### 3. Run-to-Completion (Pony-style actors)

```zig
/// Actor processes messages then yields - no preemption
pub fn runActor(actor: *Actor) void {
    var batch: u32 = 0;

    while (actor.mailbox.pop()) |msg| {
        actor.dispatch(msg);  // runs to completion

        batch += 1;
        if (batch >= MAX_BATCH) break;  // batch limit only
    }
    // Natural yield point - no preemption needed
}
```

**Pros:** Simplest, fastest (no checks)
**Cons:** Bad behaviour = system hang

---

## Recommended: Hybrid Approach

```zig
pub fn sysmon(sched: *GlobalSched) void {
    while (!sched.shutdown.load(.acquire)) {
        std.time.sleep(SYSMON_INTERVAL);

        for (sched.all_ps) |p| {
            const g = p.current_g orelse continue;
            const runtime = now() - g.start_time;

            if (runtime > PREEMPT_THRESHOLD_NS) {
                // Step 1: Set cooperative flag
                g.preempt.store(true, .release);

                // Step 2: If still running after grace period, force via signal
                std.time.sleep(GRACE_PERIOD_NS);
                if (p.current_g == g) {
                    SignalPreemption.preemptM(p.m);
                }
            }
        }
    }
}
```

---

## M:N:P Scheduler in Zig: Feasibility Matrix

| Component | Feasible | Implementation |
|-----------|----------|----------------|
| G (goroutine) | ✅ Yes | Struct with saved context |
| M (OS thread) | ✅ Yes | `std.Thread` |
| P (processor) | ✅ Yes | Struct with run queue |
| Context switch | ✅ Yes | `ucontext` or inline asm |
| Work stealing | ✅ Yes | Lock-free SPMC queue |
| Global run queue | ✅ Yes | MPMC queue with lock |
| Cooperative preemption | ✅ Yes | Flag checks at safe points |
| Signal preemption | ✅ Yes | SIGURG handler |
| Syscall handoff | ✅ Yes | Release P on enter, reacquire on exit |
| Netpoller | ✅ Yes | epoll/kqueue integration |
| **Reduction preemption** | ❌ No | Need compiler support |
| **Hot reload** | ❌ No | Need interpreter/VM |

---

## Actor Model in Zig: Feasibility Matrix

| Component | Feasible | Implementation |
|-----------|----------|----------------|
| Actor struct | ✅ Yes | Struct with mailbox + state |
| Per-actor heap | ✅ Yes | `ArenaAllocator` per actor |
| Per-actor GC | ✅ Yes | Free arena on actor death |
| MPSC mailbox | ✅ Yes | Lock-free queue |
| Work stealing (actors) | ✅ Yes | MPMC scheduler queue |
| Run-to-completion | ✅ Yes | Natural, no preemption |
| Batch limits | ✅ Yes | Counter in run loop |
| Backpressure/muting | ✅ Yes | Track mailbox depth |
| Supervisor trees | ✅ Yes | Pattern, not runtime magic |
| Reference capabilities | ⚠️ Partial | Comptime checks, not as rich as Pony |
| **Reduction preemption** | ❌ No | Need compiler |
| **Hot reload** | ❌ No | Need VM |

---

## Acceptance Criteria: Zig Actor Runtime

### AC-Z1: Actor Structure

```zig
pub const Actor = struct {
    id: u64,
    status: Status,

    // Per-actor memory (no shared GC!)
    heap: std.heap.ArenaAllocator,

    // MPSC mailbox
    mailbox: MPSCQueue(Message),

    // Behaviour dispatch table
    vtable: *const VTable,

    // Backpressure
    muted_senders: std.ArrayList(*Actor),
    overloaded: bool = false,

    pub const Status = enum {
        idle,       // no messages, not scheduled
        scheduled,  // on a scheduler queue
        running,    // currently executing
        blocked,    // waiting for something
        dead,       // terminated
    };

    pub const VTable = struct {
        dispatch: *const fn (*Actor, Message) void,
        destroy: *const fn (*Actor) void,
    };
};
```

### AC-Z2: Message Structure

```zig
pub const Message = struct {
    id: u32,                    // behaviour ID
    sender: ?*Actor,            // for replies
    next: ?*Message = null,     // intrusive list

    // Payload follows in memory
    pub fn payload(self: *Message, comptime T: type) *T {
        const ptr = @as([*]u8, @ptrCast(self)) + @sizeOf(Message);
        return @ptrCast(@alignCast(ptr));
    }

    pub fn create(allocator: Allocator, comptime T: type, id: u32, data: T) !*Message {
        const mem = try allocator.alignedAlloc(u8, @alignOf(Message), @sizeOf(Message) + @sizeOf(T));
        const msg: *Message = @ptrCast(mem.ptr);
        msg.* = .{ .id = id, .sender = null };
        msg.payload(T).* = data;
        return msg;
    }
};
```

### AC-Z3: MPSC Queue (Lock-Free)

```zig
pub fn MPSCQueue(comptime T: type) type {
    return struct {
        head: Atomic(?*Node) = .{ .raw = null },
        tail: *Atomic(?*Node),
        stub: Node = .{ .value = undefined, .next = .{ .raw = null } },

        const Node = struct {
            value: T,
            next: Atomic(?*Node),
        };

        const Self = @This();

        pub fn init(self: *Self) void {
            self.tail = &self.stub.next;
            self.head.store(&self.stub, .seq_cst);
        }

        /// Multiple producers can call this concurrently
        pub fn push(self: *Self, node: *Node) void {
            node.next.store(null, .release);
            const prev = self.head.swap(node, .acq_rel);
            prev.next.store(node, .release);
        }

        /// Single consumer only
        pub fn pop(self: *Self) ?T {
            var tail = self.tail;
            var next = tail.load(.acquire);

            if (tail == &self.stub.next) {
                if (next == null) return null;
                self.tail = &next.?.next;
                tail = &next.?.next;
                next = tail.load(.acquire);
            }

            if (next) |n| {
                self.tail = &n.next;
                return tail.*.?.value;
            }
            return null;
        }
    };
}
```

### AC-Z4: Scheduler (Work-Stealing)

```zig
pub const Scheduler = struct {
    id: u32,
    thread: std.Thread,

    // Local queue of actors (MPMC for stealing)
    local_queue: MPMCQueue(*Actor),

    // Last steal victim (locality)
    last_victim: ?*Scheduler = null,

    // Park/wake mechanism
    parked: Atomic(bool) = .{ .raw = false },
    wake_signal: std.Thread.ResetEvent = .{},

    pub fn run(self: *Scheduler) void {
        while (!global.shutdown.load(.acquire)) {
            const actor = self.getWork() orelse {
                self.park();
                continue;
            };

            self.runActor(actor);
        }
    }

    fn getWork(self: *Scheduler) ?*Actor {
        // 1. Try local queue
        if (self.local_queue.pop()) |a| return a;

        // 2. Try global inject queue
        if (global.inject_queue.pop()) |a| return a;

        // 3. Steal from others
        return self.steal();
    }

    fn runActor(self: *Scheduler, actor: *Actor) void {
        actor.status = .running;
        defer actor.status = .idle;

        var batch: u32 = 0;
        while (actor.mailbox.pop()) |msg| {
            actor.vtable.dispatch(actor, msg);

            batch += 1;
            if (batch >= MAX_BATCH) break;
        }

        // Reschedule if more messages
        if (!actor.mailbox.isEmpty()) {
            actor.status = .scheduled;
            self.local_queue.push(actor);
        }
    }

    fn steal(self: *Scheduler) ?*Actor {
        const start = if (self.last_victim) |v| v.id else 0;

        for (0..global.schedulers.len) |i| {
            const idx = (start + i + 1) % global.schedulers.len;
            if (idx == self.id) continue;

            const victim = &global.schedulers[idx];
            if (victim.local_queue.pop()) |actor| {
                self.last_victim = victim;
                return actor;
            }
        }
        return null;
    }
};
```

### AC-Z5: Backpressure (Muting)

```zig
pub fn send(sender: *Actor, receiver: *Actor, msg: *Message) void {
    msg.sender = sender;
    receiver.mailbox.push(msg);

    // Check overload
    if (receiver.mailbox.len() > HIGH_WATERMARK) {
        receiver.overloaded = true;
    }

    // Mute sender if receiver overloaded
    if (receiver.overloaded) {
        sender.status = .blocked;
        receiver.muted_senders.append(sender) catch {};
    }

    // Schedule receiver
    scheduleActor(receiver);
}

pub fn unmuteSenders(actor: *Actor) void {
    if (actor.mailbox.len() < LOW_WATERMARK) {
        actor.overloaded = false;

        for (actor.muted_senders.items) |sender| {
            sender.status = .scheduled;
            scheduleActor(sender);
        }
        actor.muted_senders.clearRetainingCapacity();
    }
}
```

---

## Trade-off Summary

| What You Want | What You Need | Zig Can Do It? |
|---------------|---------------|----------------|
| Fair scheduling | Preemption | ⚠️ Cooperative + signals |
| Memory isolation | Per-actor heap | ✅ Yes |
| No global GC pause | Per-actor GC | ✅ Yes |
| Infinite loop protection | Reduction counting | ❌ No (use batch limits) |
| Live code updates | Hot reload | ❌ No |
| Type-safe concurrency | Reference caps | ⚠️ Partial (comptime) |

---

## The Honest Answer

**For M:N:P (Go-style):** Zig can build a production-quality scheduler. Signal preemption handles pathological cases. You won't have Go's compiler-inserted checks, but signals + cooperative yields cover 99% of cases.

**For Actors (Pony/Erlang-style):** Zig can build a solid actor runtime. Run-to-completion is natural. Per-actor heaps are easy. You lose hot reload and reduction preemption, but Pony doesn't have those either and it works fine.

**What you must accept:**
1. Infinite loops in user code can hang the system (document this)
2. No hot reload (restart to update)
3. Preemption is best-effort, not guaranteed

---

## References

- [Go Scheduler Design Doc](https://docs.google.com/document/d/1TTj4T2JO42uD5ID9e89oa0sLKhJYD0Y_kqxDv3I3XMw/edit)
- [Scalable Go Scheduler (2012)](https://docs.google.com/document/d/1TTj4T2JO42uD5ID9e89oa0sLKhJYD0Y_kqxDv3I3XMw)
- [Go source: runtime](https://github.com/golang/go/tree/master/src/runtime)
- [GopherCon 2018: The Scheduler Saga](https://www.youtube.com/watch?v=YHRO5WQGh0k)
- [Pony Tutorial: Actors](https://tutorial.ponylang.io/types/actors)
- [Pony Runtime Source](https://github.com/ponylang/ponyc/tree/main/src/libponyrt)
- [Pony Reference Capabilities](https://tutorial.ponylang.io/reference-capabilities/)
- [ORCA: GC for Actors (Pony's GC)](https://www.ponylang.io/media/papers/orca_gc_and_type_system_co-design_for_actor_languages.pdf)
