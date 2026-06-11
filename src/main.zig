const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const Context = utils.Context;

const compiler = @import("compiler.zig");

var failed: bool = false;

fn compileStdin(gpa: Allocator, io: Io) !void {
	var ctx: Context = try .initFromStdin(gpa, io);
	defer ctx.deinit(gpa);
    try compiler.run(&ctx, gpa);
	failed = ctx.failed;
}

fn compileFile(gpa: Allocator, io: Io, dir: std.Io.Dir, filePath: []const u8) !void {
	var ctx: Context = try .initFromFile(gpa, io, dir, filePath);
	defer ctx.deinit(gpa);
    try compiler.run(&ctx, gpa);
	failed = ctx.failed;
}

pub fn main(init: std.process.Init) !void {
	const gpa = init.gpa;
	const io = init.io;

	const arena: std.mem.Allocator = init.arena.allocator();
	const args = try init.minimal.args.toSlice(arena);

	if (args.len <= 1) {
		try compileStdin(gpa, io);
	}

	for (args[1..]) |arg| {
		try compileFile(gpa, io, std.Io.Dir.cwd(), arg);
	}

    if (failed) std.process.exit(1);
}