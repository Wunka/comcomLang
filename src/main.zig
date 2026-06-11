const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

var failed: bool = false;

pub const Context = struct {
	data: [:0]const u8,
	ast: std.zig.Ast,
	filePath: []const u8,

	fn init(gpa: Allocator, data: [:0]const u8, filePath: []const u8) !Context {
		const ast = try std.zig.Ast.parse(gpa, data, .zig);
		return .{
			.data = data,
			.ast = ast,
			.filePath = filePath,
		};
	}

	fn initFromFile(gpa: Allocator, io: Io, dir: std.Io.Dir, filePath: []const u8) !Context {
		const data = try dir.readFileAllocOptions(io, filePath, gpa, .unlimited, .@"1", 0);
		errdefer gpa.free(data);
		return try .init(gpa, data, filePath);
	}

	fn initFromStdin(gpa: Allocator, io: Io) !Context {
		const stdin: std.Io.File = .stdin();
		var reader = stdin.reader(io, &.{});

		const data = try reader.interface.allocRemainingAlignedSentinel(gpa, .unlimited, .@"1", 0);
		errdefer gpa.free(data);
		return try .init(gpa, data, "<stdin>");
	}

	fn deinit(self: *Context, gpa: Allocator) void {
		gpa.free(self.data);
		self.ast.deinit(gpa);
	}

	pub fn printError(self: *Context, gpa: Allocator, msg: []const u8, loc: std.zig.Ast.Location) void {
		var startLineChars: std.ArrayList(u8) = .empty;
		defer startLineChars.deinit(gpa);
		for (self.data[loc.line_start..loc.line_start+loc.column]) |c| {
			if (c == '\t') {
				startLineChars.append(gpa, '\t') catch {};
			} else {
				startLineChars.append(gpa, ' ') catch {};
			}
		}
        failed = true;

		std.log.err("{s}:{}:{}: {s}\n{s}\n{s}^", .{self.filePath, loc.line, loc.column, msg, self.data[loc.line_start..loc.line_end], startLineChars.items});
	}

	pub fn printInfo(self: *Context, gpa: Allocator, msg: []const u8, loc: std.zig.Ast.Location) void {
        var startLineChars: std.ArrayList(u8) = .empty;
		defer startLineChars.deinit(gpa);
		for (self.data[loc.line_start..loc.line_start+loc.column]) |c| {
			if (c == '\t') {
				startLineChars.append(gpa, '\t') catch {};
			} else {
				startLineChars.append(gpa, ' ') catch {};
			}
		}
        failed = true;

		std.log.info("{s}:{}:{}: {s}\n{s}\n{s}^", .{self.filePath, loc.line, loc.column, msg, self.data[loc.line_start..loc.line_end], startLineChars.items});
	}

    fn getBody(self: *Context, gpa: Allocator) []const std.zig.Ast.Node.Index {
        const root = self.ast.rootDecls();
        for(root) |index| {
            if(self.ast.nodeTag(index) == .fn_decl) {
                const head = self.ast.nodeData(index).node_and_node.@"0";
                const name = self.ast.tokenSlice(self.ast.nodeMainToken(head) + 1);
                if(!std.mem.eql(u8, name, "main")) continue;

                const body = self.ast.nodeData(index).node_and_node.@"1";
                if(self.ast.nodeTag(body) != .block_semicolon and self.ast.nodeTag(body) != .block) {
                    self.printError(gpa, "main is not of right block tag... what did you do?",self.ast.tokenLocation(0, self.ast.nodeMainToken(body)));
                    return &.{};
                }
                const range = self.ast.nodeData(body).extra_range;
                return self.ast.extraDataSlice(range, std.zig.Ast.Node.Index);
            }
        }
        self.printError(gpa, "Could not find main method.", self.ast.tokenLocation(0, @intCast(self.ast.tokens.len-1)));
        return &.{};
    }

    fn compile(self: *Context, gpa: Allocator) void {
        const decl = self.getBody(gpa);
        for(decl) |index| {
            std.debug.print("{s}\n", .{self.ast.getNodeSource(index)});
        }
    }
};

fn compileStdin(gpa: Allocator, io: Io) !void {
	var ctx: Context = try .initFromStdin(gpa, io);
	defer ctx.deinit(gpa);
    ctx.compile(gpa);
}

fn compileFile(gpa: Allocator, io: Io, dir: std.Io.Dir, filePath: []const u8) !void {
	var ctx: Context = try .initFromFile(gpa, io, dir, filePath);
	defer ctx.deinit(gpa);
    ctx.compile(gpa);
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