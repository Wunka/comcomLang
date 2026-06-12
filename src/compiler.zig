const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const Context = utils.Context;
const ComComCode = utils.ComComCode;
const builtins = @import("builtins");

fn handleCall(ctx: *Context, gpa: Allocator, code: *ComComCode, index: std.zig.Ast.Node.Index) error{OutOfMemory}!void {
    const data = ctx.ast.nodeData(index).node_and_opt_node;
    const fn_name = ctx.ast.getNodeSource(data[0]);

    if (std.mem.startsWith(u8, fn_name, "builtins")) {
        var split = std.mem.splitScalar(u8, fn_name, '.');
        _ = split.first();
        try code.lines.append(gpa, .{
            .cmd = std.meta.stringToEnum(ComComCode.Instruction, split.rest()) orelse {
                ctx.printError(gpa, "Unknown builtin function", ctx.ast.tokenLocation(0, ctx.ast.nodeMainToken(data[0])));
                return;
            },
            .input = blk: {
                const input = data[1].unwrap() orelse break :blk null;
                break :blk std.fmt.parseInt(builtins.int, ctx.ast.getNodeSource(input), 0) catch {
                    ctx.printError(gpa, "Other inputs than numbers currently not allowd", ctx.ast.tokenLocation(0, ctx.ast.nodeMainToken(input)));
                    return;
                };
            },
        });
        return;
    }
}

fn handleSimpleIf(ctx: *Context, gpa: Allocator, code: *ComComCode, index: std.zig.Ast.Node.Index) error{OutOfMemory}!void {
    const cond_expr, const then_expr = ctx.ast.nodeData(index).node_and_node;

    switch (ctx.ast.nodeTag(cond_expr)) {
        .less_than => {
            try code.openBlock(gpa, .if_g);
        },
        .equal_equal => {
            try code.openBlock(gpa, .if_e);
        },
        else => {
            ctx.printError(gpa, "Only < and == are currently supported in if conditions", ctx.ast.tokenLocation(0, ctx.ast.nodeMainToken(cond_expr)));
            return;
        },
    }

    const left = ctx.ast.nodeData(cond_expr).node_and_node.@"0";
    const right = ctx.ast.nodeData(cond_expr).node_and_node.@"1";

    // TODO handle loading of varibles inside conditions
    _ = left;
    _ = right;

    if (ctx.ast.nodeTag(then_expr) != .block_semicolon and ctx.ast.nodeTag(then_expr) != .block) return;
    const range = ctx.ast.nodeData(then_expr).extra_range;
    const decl = ctx.ast.extraDataSlice(range, std.zig.Ast.Node.Index);
    try interpretBlock(ctx, gpa, code, decl);
    try code.closeBlock(gpa);
}

pub fn interpretBlock(ctx: *Context, gpa: Allocator, code: *ComComCode, decl: []const std.zig.Ast.Node.Index) error{OutOfMemory}!void {
    for (decl) |index| {
        // std.debug.print("TAG: {t} LINE: {s} \n", .{ctx.ast.nodeTag(index), ctx.ast.getNodeSource(index)});
        try switch (ctx.ast.nodeTag(index)) {
            .call_one, .call_one_comma => handleCall(ctx, gpa, code, index),
            .if_simple => handleSimpleIf(ctx, gpa, code, index),
            else => {},
        };
    }
}

pub fn run(ctx: *Context, gpa: Allocator) error{OutOfMemory}!void {
    var code: ComComCode = .{};
    defer code.deinit(gpa);

    const decl = try ctx.getFunctionBody(gpa, "main");
    try interpretBlock(ctx, gpa, &code, decl);

    std.debug.print("{f}", .{code});
}
