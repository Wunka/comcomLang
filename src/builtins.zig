/// From Readme: https://github.com/alexsuperzocker/comcomcom

const std = @import("std");
const int = i12;

var s:[4096]int = @splat(0);
var f:[4096]bool = @splat(true);
const akk = 0;

/// 0000 'ADD' : adds value at argument adress onto accumulator 
pub fn ADD(value: int) void {
    s[akk] += s[@intCast(value)];
}

/// 0001 'SUB' : subtracts value at argument adress from accumulator 
pub fn SUB(value: int) void {
    s[akk] -= s[@intCast(value)];
}

/// 0010 'MUL' : multiplies value at argument adress with accumulator
pub fn MUL(value: int) void {
    s[akk] *= s[@intCast(value)];
}

/// 0011 'DIV' : divides value at accumulator with value at argument adress 
pub fn DIV(value: int) void {
    s[akk] /= s[@intCast(value)];
}

/// 0100 'LOD' : load value at argument adress into accumulator 
pub fn LOD(value: int) void {
    s[akk] = s[@intCast(value)];
}

/// 0101 'STO' : store value from accumulator into argument adress
pub fn STO(value: int) void {
    s[@intCast(value)] = s[akk];
    f[@intCast(value)] = false;
}

/// 0110 'INP' : put argument into accumulator 
pub fn INP(value: int) void {
    s[akk] = value;
}
 
// 1010 'FSH' : Flush values in special output registers to screen (still in discussion)
pub fn FSH_S() void {
    std.debug.print("value: {}\n", .{s[akk]});
}
pub fn FSH_B() void {
    std.debug.print("value: {b}\n", .{s[akk]});
}

/// 1011 'AWT' : Await 12 bit input from argument input device, block execution until input given. Input is put into accumulator. 
pub fn AWT() void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    var threaded = std.Io.Threaded.init(gpa.allocator(), .{});
    const stdin = std.Io.File.stdin();
    var buff: [10]u8 = undefined;
    var reader = stdin.reader(threaded.io(), &buff);
    const text = std.mem.trim(u8, reader.interface.takeDelimiter('\n') catch @panic("OOM") orelse return, &.{13});
    switch(text[0]) {
        'u' => s[akk] = std.fmt.parseInt(int, text, 12) catch @panic("NOT VALID INPUT"),
        else => s[akk] = std.fmt.parseInt(int, text, 0) catch @panic("NOT VALID INPUT"),
    }
}

/// 1110 'ISF' : Is argument adress free aka not set via STO. Puts 1 into accumulator if adress is free, else 0
pub fn ISF(value: int) void {
    s[akk] = if(f[@intCast(value)]) 1 else 0;
} 

/// 1111 'DEL' : Frees (unsets) argument adress.
pub fn DEL(value: int) void {
    s[@intCast(value)] = true;
}