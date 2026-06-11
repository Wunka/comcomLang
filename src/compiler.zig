const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const Context = utils.Context;

pub fn run(ctx: *Context, gpa: Allocator) error{OutOfMemory}!void {
    const decl = try ctx.getFunctionBody(gpa, "main");
    for(decl) |index| {
        std.debug.print("{s}\n", .{ctx.ast.getNodeSource(index)});
    }
}
