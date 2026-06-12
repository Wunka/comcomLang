const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const math = std.math;
const Alignment = std.mem.Alignment;
const builtin = @import("builtin");
const Allocator = @This();

end_index: usize,

pub fn init() Allocator {
    return .{
        .end_index = 0,
    };
}

/// This has false negatives when the last allocation had an
/// adjusted_index. In such case we won't be able to determine what the
/// last allocation was because the alignForward operation done in alloc is
/// not reversible.
fn isLastAllocation(self: *Allocator, buf: []u12) bool {
    return buf.ptr + buf.len == self.buffer.ptr + self.end_index;
}

fn _alloc(self: *Allocator, n: usize, alignment: mem.Alignment, ra: usize) ?[*]u12 {
    _ = ra;
    const ptr_align = alignment.toByteUnits();
    const adjust_off = mem.alignPointerOffset(self.buffer.ptr + self.end_index, ptr_align) orelse return null;
    const adjusted_index = self.end_index + adjust_off;
    const new_end_index = adjusted_index + n;
    if (new_end_index > self.buffer.len) return null;
    self.end_index = new_end_index;
    return self.buffer.ptr + adjusted_index;
}

fn _resize(
    self: *Allocator,
    buf: []u12,
    alignment: mem.Alignment,
    new_size: usize,
    return_address: usize,
) bool {
    _ = alignment;
    _ = return_address;
    assert(@inComptime() or self.ownsSlice(buf));

    if (!self.isLastAllocation(buf)) {
        if (new_size > buf.len) return false;
        return true;
    }

    if (new_size <= buf.len) {
        const sub = buf.len - new_size;
        self.end_index -= sub;
        return true;
    }

    const add = new_size - buf.len;
    if (add + self.end_index > self.buffer.len) return false;

    self.end_index += add;
    return true;
}

fn _remap(
    self: *Allocator,
    memory: []u12,
    alignment: mem.Alignment,
    new_len: usize,
    return_address: usize,
) ?[*]u12 {
    return if (_resize(self, memory, alignment, new_len, return_address)) memory.ptr else null;
}

fn _free(
    self: *Allocator,
    buf: []u12,
    alignment: mem.Alignment,
    return_address: usize,
) void {
    _ = alignment;
    _ = return_address;
    assert(@inComptime() or self.ownsSlice(buf));

    if (self.isLastAllocation(buf)) {
        self.end_index -= buf.len;
    }
}

fn reset(self: *Allocator) void {
    self.end_index = 0;
}

// ALLLOCATOR

pub const Error = error{OutOfMemory};
pub const Log2Align = math.Log2Int(usize);

/// This function is not intended to be called except from within the
/// implementation of an `Allocator`.
pub inline fn rawAlloc(a: *Allocator, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u12 {
    return a._alloc(len, alignment, ret_addr);
}

/// This function is not intended to be called except from within the
/// implementation of an `Allocator`.
pub inline fn rawResize(a: *Allocator, memory: []u12, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    return a._resize(memory, alignment, new_len, ret_addr);
}

/// This function is not intended to be called except from within the
/// implementation of an `Allocator`.
pub inline fn rawRemap(a: *Allocator, memory: []u12, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u12 {
    return a._remap(memory, alignment, new_len, ret_addr);
}

/// This function is not intended to be called except from within the
/// implementation of an `Allocator`.
pub inline fn rawFree(a: *Allocator, memory: []u12, alignment: Alignment, ret_addr: usize) void {
    return a._free(memory, alignment, ret_addr);
}

/// Returns a pointer to undefined memory.
/// Call `destroy` with the result to free the memory.
pub fn create(a: Allocator, comptime T: type) Error!*T {
    if (@sizeOf(T) == 0) {
        const ptr = comptime std.mem.alignBackward(usize, math.maxInt(usize), @alignOf(T));
        return @ptrFromInt(ptr);
    }
    const ptr: *T = @ptrCast(try a.allocBytesWithAlignment(.of(T), @sizeOf(T), @returnAddress()));
    return ptr;
}

/// `ptr` should be the return value of `create`, or otherwise
/// have the same address and alignment property.
pub fn destroy(self: Allocator, ptr: anytype) void {
    const info = @typeInfo(@TypeOf(ptr)).pointer;
    if (info.size != .one) @compileError("ptr must be a single item pointer");
    const T = info.child;
    if (@sizeOf(T) == 0) return;
    const non_const_ptr = @as([*]u12, @ptrCast(@constCast(ptr)));
    self.rawFree(
        non_const_ptr[0..@sizeOf(T)],
        .fromByteUnits(info.alignment orelse @alignOf(T)),
        @returnAddress(),
    );
}

/// Allocates an array of `n` items of type `T` and sets all the
/// items to `undefined`. Depending on the Allocator
/// implementation, it may be required to call `free` once the
/// memory is no longer needed, to avoid a resource leak. If the
/// `Allocator` implementation is unknown, then correct code will
/// call `free` when done.
///
/// For allocating a single item, see `create`.
pub fn alloc(self: *Allocator, comptime T: type, n: usize) Error![]T {
    return self.allocAdvancedWithRetAddr(T, null, n, @returnAddress());
}

pub fn allocWithOptions(
    self: Allocator,
    comptime Elem: type,
    n: usize,
    /// null means naturally aligned
    comptime optional_alignment: ?Alignment,
    comptime optional_sentinel: ?Elem,
) Error!AllocWithOptionsPayload(Elem, optional_alignment, optional_sentinel) {
    return self.allocWithOptionsRetAddr(Elem, n, optional_alignment, optional_sentinel, @returnAddress());
}

pub fn allocWithOptionsRetAddr(
    self: Allocator,
    comptime Elem: type,
    n: usize,
    /// null means naturally aligned
    comptime optional_alignment: ?Alignment,
    comptime optional_sentinel: ?Elem,
    return_address: usize,
) Error!AllocWithOptionsPayload(Elem, optional_alignment, optional_sentinel) {
    if (optional_sentinel) |sentinel| {
        const ptr = try self.allocAdvancedWithRetAddr(Elem, optional_alignment, n + 1, return_address);
        ptr[n] = sentinel;
        return ptr[0..n :sentinel];
    } else {
        return self.allocAdvancedWithRetAddr(Elem, optional_alignment, n, return_address);
    }
}

fn AllocWithOptionsPayload(comptime Elem: type, comptime alignment: ?Alignment, comptime sentinel: ?Elem) type {
    if (sentinel) |s| {
        return [:s]align(if (alignment) |a| a.toByteUnits() else @alignOf(Elem)) Elem;
    } else {
        return []align(if (alignment) |a| a.toByteUnits() else @alignOf(Elem)) Elem;
    }
}

/// Allocates an array of `n + 1` items of type `T` and sets the first `n`
/// items to `undefined` and the last item to `sentinel`. Depending on the
/// Allocator implementation, it may be required to call `free` once the
/// memory is no longer needed, to avoid a resource leak. If the
/// `Allocator` implementation is unknown, then correct code will
/// call `free` when done.
///
/// For allocating a single item, see `create`.
pub fn allocSentinel(
    self: Allocator,
    comptime Elem: type,
    n: usize,
    comptime sentinel: Elem,
) Error![:sentinel]Elem {
    return self.allocWithOptionsRetAddr(Elem, n, null, sentinel, @returnAddress());
}

pub fn alignedAlloc(
    self: Allocator,
    comptime T: type,
    /// null means naturally aligned
    comptime alignment: ?Alignment,
    n: usize,
) Error![]align(if (alignment) |a| a.toByteUnits() else @alignOf(T)) T {
    return self.allocAdvancedWithRetAddr(T, alignment, n, @returnAddress());
}

pub inline fn allocAdvancedWithRetAddr(
    self: *Allocator,
    comptime T: type,
    /// null means naturally aligned
    comptime alignment: ?Alignment,
    n: usize,
    return_address: usize,
) Error![]align(if (alignment) |a| a.toByteUnits() else @alignOf(T)) T {
    const a: Alignment = alignment orelse comptime .of(T);
    const ptr: [*]align(a.toByteUnits()) T = @ptrCast(try self.allocWithSizeAndAlignment(@sizeOf(T), a, n, return_address));
    return ptr[0..n];
}

fn allocWithSizeAndAlignment(
    self: *Allocator,
    comptime size: usize,
    comptime alignment: Alignment,
    n: usize,
    return_address: usize,
) Error![*]align(alignment.toByteUnits()) u12 {
    const byte_count = math.mul(usize, size, n) catch return error.OutOfMemory;
    return self.allocBytesWithAlignment(alignment, byte_count, return_address);
}

fn allocBytesWithAlignment(
    self: *Allocator,
    comptime alignment: Alignment,
    byte_count: usize,
    return_address: usize,
) Error![*]align(alignment.toByteUnits()) u12 {
    if (byte_count == 0) {
        const ptr = comptime alignment.backward(math.maxInt(usize));
        return @as([*]align(alignment.toByteUnits()) u12, @ptrFromInt(ptr));
    }

    const byte_ptr = self.rawAlloc(byte_count, alignment, return_address) orelse return error.OutOfMemory;
    @memset(byte_ptr[0..byte_count], undefined);
    return @alignCast(byte_ptr);
}

/// Request to modify the size of an allocation.
///
/// It is guaranteed to not move the pointer, however the allocator
/// implementation may refuse the resize request by returning `false`.
///
/// `allocation` may be an empty slice, in which case `false` is returned,
/// unless `new_len` is also 0, in which case `true` is returned.
///
/// `new_len` may be zero, in which case the allocation is freed.
pub fn resize(self: *Allocator, allocation: anytype, new_len: usize) bool {
    const slice_info = @typeInfo(@TypeOf(allocation)).pointer;
    comptime assert(slice_info.size == .slice);
    const T = slice_info.child;
    if (new_len == 0) {
        self.free(allocation);
        return true;
    }
    if (allocation.len == 0) {
        return false;
    }
    const old_memory: []u12 = @ptrCast(@constCast(mem.absorbSentinel(allocation)));
    // I would like to use saturating multiplication here, but LLVM cannot lower it
    // on WebAssembly: https://github.com/ziglang/zig/issues/9660
    //const new_len_bytes = new_len *| @sizeOf(T);
    const new_len_bytes = math.mul(usize, @sizeOf(T), new_len) catch return false;
    return self.rawResize(
        old_memory,
        .fromByteUnits(slice_info.alignment orelse @alignOf(T)),
        new_len_bytes,
        @returnAddress(),
    );
}

/// Request to modify the size of an allocation, allowing relocation.
///
/// A non-`null` return value indicates the resize was successful. The
/// allocation may have same address, or may have been relocated. In either
/// case, the allocation now has size of `new_len`. A `null` return value
/// indicates that the resize would be equivalent to allocating new memory,
/// copying the bytes from the old memory, and then freeing the old memory.
/// In such case, it is more efficient for the caller to perform those
/// operations.
///
/// `allocation` may be an empty slice, in which case `null` is returned,
/// unless `new_len` is also 0, in which case `allocation` is returned.
///
/// `new_len` may be zero, in which case the allocation is freed.
///
/// If the allocation's elements' type is zero bytes sized, `allocation.len` is set to `new_len`.
pub fn remap(self: Allocator, allocation: anytype, new_len: usize) ?@TypeOf(allocation) {
    const slice_info = @typeInfo(@TypeOf(allocation)).pointer;
    comptime assert(slice_info.size == .slice);
    const T = slice_info.child;

    if (new_len == 0) {
        self.free(allocation);
        return allocation[0..0];
    }
    if (allocation.len == 0) {
        return null;
    }
    if (@sizeOf(T) == 0) {
        var new_memory = allocation;
        new_memory.len = new_len;
        return new_memory;
    }
    const old_memory: []u12 = @ptrCast(@constCast(mem.absorbSentinel(allocation)));
    // I would like to use saturating multiplication here, but LLVM cannot lower it
    // on WebAssembly: https://github.com/ziglang/zig/issues/9660
    //const new_len_bytes = new_len *| @sizeOf(T);
    const new_len_bytes = math.mul(usize, @sizeOf(T), new_len) catch return null;
    const new_ptr = self.rawRemap(
        old_memory,
        .fromByteUnits(slice_info.alignment orelse @alignOf(T)),
        new_len_bytes,
        @returnAddress(),
    ) orelse return null;
    return @ptrCast(@alignCast(new_ptr[0..new_len_bytes]));
}

/// This function requests a new size for an existing allocation, which
/// can be larger, smaller, or the same size as the old memory allocation.
/// The result is an array of `new_n` items of the same type as the existing
/// allocation.
///
/// If `new_n` is 0, this is the same as `free` and it always succeeds.
///
/// `old_mem` may have length zero, which makes a new allocation.
///
/// This function only fails on out-of-memory conditions, unlike:
/// * `remap` which returns `null` when the `Allocator` implementation cannot
///   do the realloc more efficiently than the caller
/// * `resize` which returns `false` when the `Allocator` implementation cannot
///   change the size without relocating the allocation.
pub fn realloc(self: Allocator, old_mem: anytype, new_n: usize) Error!@TypeOf(old_mem) {
    return self.reallocAdvanced(old_mem, new_n, @returnAddress());
}

pub fn reallocAdvanced(
    self: Allocator,
    old_mem: anytype,
    new_n: usize,
    return_address: usize,
) Error!@TypeOf(old_mem) {
    const slice_info = @typeInfo(@TypeOf(old_mem)).pointer;
    comptime assert(slice_info.size == .slice);
    const T = slice_info.child;
    if (old_mem.len == 0) {
        return self.allocAdvancedWithRetAddr(T, .fromByteUnitsOptional(slice_info.alignment), new_n, return_address);
    }
    if (new_n == 0) {
        self.free(old_mem);
        const alignment = slice_info.alignment orelse @alignOf(T);
        const addr = comptime std.mem.alignBackward(usize, math.maxInt(usize), alignment);
        const ptr: *align(alignment) [0]T = @ptrFromInt(addr);
        return ptr;
    }

    const old_byte_slice: []u12 = @ptrCast(@constCast(mem.absorbSentinel(old_mem)));
    const byte_count = math.mul(usize, @sizeOf(T), new_n) catch return error.OutOfMemory;
    // Note: can't set shrunk memory to undefined as memory shouldn't be modified on realloc failure
    if (self.rawRemap(old_byte_slice, .fromByteUnits(slice_info.alignment orelse @alignOf(T)), byte_count, return_address)) |p| {
        return @ptrCast(@alignCast(p[0..byte_count]));
    }

    const new_mem = self.rawAlloc(byte_count, .fromByteUnits(slice_info.alignment orelse @alignOf(T)), return_address) orelse
        return error.OutOfMemory;
    const copy_len = @min(byte_count, old_byte_slice.len);
    @memcpy(new_mem[0..copy_len], old_byte_slice[0..copy_len]);
    @memset(old_byte_slice, undefined);
    self.rawFree(old_byte_slice, .fromByteUnits(slice_info.alignment orelse @alignOf(T)), return_address);

    return @ptrCast(@alignCast(new_mem[0..byte_count]));
}

/// Free an array allocated with `alloc`.
/// If memory has length 0, free is a no-op.
/// To free a single item, see `destroy`.
pub fn free(self: Allocator, memory: anytype) void {
    const slice_info = @typeInfo(@TypeOf(memory)).pointer;
    comptime assert(slice_info.size == .slice);
    const bytes: []u12 = @ptrCast(@constCast(mem.absorbSentinel(memory)));
    if (bytes.len == 0) return;
    @memset(bytes, undefined);
    self.rawFree(bytes, .fromByteUnits(slice_info.alignment orelse @alignOf(slice_info.child)), @returnAddress());
}

/// Copies `m` to newly allocated memory. Caller owns the memory.
pub fn dupe(allocator: Allocator, comptime T: type, m: []const T) Error![]T {
    const new_buf = try allocator.alloc(T, m.len);
    @memcpy(new_buf, m);
    return new_buf;
}

/// Deprecated in favor of `dupeSentinel`
/// Copies `m` to newly allocated memory, with a null-terminated element. Caller owns the memory.
pub fn dupeZ(allocator: Allocator, comptime T: type, m: []const T) Error![:0]T {
    return allocator.dupeSentinel(T, m, 0);
}

/// Copies `m` to newly allocated memory, with a null-terminated element. Caller owns the memory.
pub fn dupeSentinel(
    allocator: Allocator,
    comptime T: type,
    m: []const T,
    comptime sentinel: T,
) Error![:sentinel]T {
    const new_buf = try allocator.alloc(T, m.len + 1);
    @memcpy(new_buf[0..m.len], m);
    new_buf[m.len] = sentinel;
    return new_buf[0..m.len :sentinel];
}
