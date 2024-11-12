const builtin = @import("builtin");
const std = @import("std");

pub const StackContext = switch (builtin.cpu.arch) {
    .aarch64 => Arm_64,
    .x86_64 => switch (builtin.os.tag) {
        .windows => Intel_Microsoft,
        else => Intel_SysV,
    },
    else => @compileError("cpu architecture not supported"),
};

const Intel_Microsoft = struct {
    pub const word_count = 31;

    pub const entry_offset = word_count - 1;

    comptime {
        asm (
            \\.global zig_fiber_stack_swap
            \\zig_fiber_stack_swap:
            \\  pushq %gs:0x10
            \\  pushq %gs:0x08
            \\
            \\  pushq %rbx
            \\  pushq %rbp
            \\  pushq %rdi
            \\  pushq %rsi
            \\  pushq %r12
            \\  pushq %r13
            \\  pushq %r14
            \\  pushq %r15
            \\
            \\  subq $160, %rsp
            \\  movups %xmm6, 0x00(%rsp)
            \\  movups %xmm7, 0x10(%rsp)
            \\  movups %xmm8, 0x20(%rsp)
            \\  movups %xmm9, 0x30(%rsp)
            \\  movups %xmm10, 0x40(%rsp)
            \\  movups %xmm11, 0x50(%rsp)
            \\  movups %xmm12, 0x60(%rsp)
            \\  movups %xmm13, 0x70(%rsp)
            \\  movups %xmm14, 0x80(%rsp)
            \\  movups %xmm15, 0x90(%rsp)
            \\
            \\  movq %rsp, (%rcx)
            \\  movq (%rdx), %rsp
            \\
            \\  movups 0x00(%rsp), %xmm6
            \\  movups 0x10(%rsp), %xmm7
            \\  movups 0x20(%rsp), %xmm8
            \\  movups 0x30(%rsp), %xmm9
            \\  movups 0x40(%rsp), %xmm10
            \\  movups 0x50(%rsp), %xmm11
            \\  movups 0x60(%rsp), %xmm12
            \\  movups 0x70(%rsp), %xmm13
            \\  movups 0x80(%rsp), %xmm14
            \\  movups 0x90(%rsp), %xmm15
            \\  addq $160, %rsp
            \\
            \\  popq %r15
            \\  popq %r14
            \\  popq %r13
            \\  popq %r12
            \\  popq %rsi
            \\  popq %rdi
            \\  popq %rbp
            \\  popq %rbx
            \\
            \\  popq %gs:0x08
            \\  popq %gs:0x10
            \\  
            \\  retq
        );
    }
};

const Intel_SysV = struct {
    pub const word_count = 7;

    pub const entry_offset = word_count - 1;

    comptime {
        asm (
            \\.global zig_fiber_stack_swap
            \\.type zig_fiber_stack_swap, @function
            \\zig_fiber_stack_swap:
            \\  pushq %rbx
            \\  pushq %rbp
            \\  pushq %r12
            \\  pushq %r13
            \\  pushq %r14
            \\  pushq %r15
            \\
            \\  movq %rsp, (%rdi)
            \\  movq (%rsi), %rsp
            \\
            \\  popq %r15
            \\  popq %r14
            \\  popq %r13
            \\  popq %r12
            \\  popq %rbp
            \\  popq %rbx
            \\
            \\  retq
        );
    }
};

// rsi            0x7ffff7ff77d8      140737354102744
// rdi            0x7ffff7ff87e0      140737354106848
// rsp            0x7fffffffd770      0x7fffffffd770
//
// rsi            0x7ffff7ff87e8      140737354106856
// rdi            0x7ffff7ff87e0      140737354106848
// rsp            0x7fffffffd768      0x7fffffffd768

const Arm_64 = struct {
    pub const word_count = 20;

    pub const entry_offset = 0;

    comptime {
        asm (
            \\.global _zig_fiber_stack_swap
            \\_zig_fiber_stack_swap:
            \\  stp lr, fp, [sp, #-20*8]!
            \\  stp d8, d9, [sp, #2*8]
            \\  stp d10, d11, [sp, #4*8]
            \\  stp d12, d13, [sp, #6*8]
            \\  stp d14, d15, [sp, #8*8]
            \\  stp x19, x20, [sp, #10*8]
            \\  stp x21, x22, [sp, #12*8]
            \\  stp x23, x24, [sp, #14*8]
            \\  stp x25, x26, [sp, #16*8]
            \\  stp x27, x28, [sp, #18*8]
            \\
            \\  mov x9, sp
            \\  str x9, [x0]
            \\  ldr x9, [x1]
            \\  mov sp, x9
            \\
            \\  ldp x27, x28, [sp, #18*8]
            \\  ldp x25, x26, [sp, #16*8]
            \\  ldp x23, x24, [sp, #14*8]
            \\  ldp x21, x22, [sp, #12*8]
            \\  ldp x19, x20, [sp, #10*8]
            \\  ldp d14, d15, [sp, #8*8]
            \\  ldp d12, d13, [sp, #6*8]
            \\  ldp d10, d11, [sp, #4*8]
            \\  ldp d8, d9, [sp, #2*8]
            \\  ldp lr, fp, [sp], #20*8
            \\  
            \\  ret
        );
    }
};
