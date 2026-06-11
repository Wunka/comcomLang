const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtins = @import("builtins");

pub const Context = struct {
	data: [:0]const u8,
	ast: std.zig.Ast,
	filePath: []const u8,
    failed: bool = false,

	fn init(gpa: Allocator, data: [:0]const u8, filePath: []const u8) !Context {
		const ast = try std.zig.Ast.parse(gpa, data, .zig);
		return .{
			.data = data,
			.ast = ast,
			.filePath = filePath,
		};
	}

	pub fn initFromFile(gpa: Allocator, io: Io, dir: std.Io.Dir, filePath: []const u8) !Context {
		const data = try dir.readFileAllocOptions(io, filePath, gpa, .unlimited, .@"1", 0);
		errdefer gpa.free(data);
		return try .init(gpa, data, filePath);
	}

	pub fn initFromStdin(gpa: Allocator, io: Io) !Context {
		const stdin: std.Io.File = .stdin();
		var reader = stdin.reader(io, &.{});

		const data = try reader.interface.allocRemainingAlignedSentinel(gpa, .unlimited, .@"1", 0);
		errdefer gpa.free(data);
		return try .init(gpa, data, "<stdin>");
	}

	pub fn deinit(self: *Context, gpa: Allocator) void {
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
        self.failed = true;

		std.log.err("{s}:{}:{}: {s}\n{s}\n{s}^", .{self.filePath, loc.line, loc.column, msg, self.data[loc.line_start..loc.line_end], startLineChars.items});
	}

	pub fn printInfo(self: *const Context, gpa: Allocator, msg: []const u8, loc: std.zig.Ast.Location) void {
        var startLineChars: std.ArrayList(u8) = .empty;
		defer startLineChars.deinit(gpa);
		for (self.data[loc.line_start..loc.line_start+loc.column]) |c| {
			if (c == '\t') {
				startLineChars.append(gpa, '\t') catch {};
			} else {
				startLineChars.append(gpa, ' ') catch {};
			}
		}

		std.log.info("{s}:{}:{}: {s}\n{s}\n{s}^", .{self.filePath, loc.line, loc.column, msg, self.data[loc.line_start..loc.line_end], startLineChars.items});
	}

    pub fn getFunctionBody(self: *Context, gpa: Allocator, fn_name: []const u8) error{OutOfMemory}![]const std.zig.Ast.Node.Index {
        const root = self.ast.rootDecls();
        for(root) |index| {
            if(self.ast.nodeTag(index) == .fn_decl) {
                const head = self.ast.nodeData(index).node_and_node.@"0";
                const name = self.ast.tokenSlice(self.ast.nodeMainToken(head) + 1);
                if(!std.mem.eql(u8, name, fn_name)) continue;

                const body = self.ast.nodeData(index).node_and_node.@"1";
                if(self.ast.nodeTag(body) != .block_semicolon and self.ast.nodeTag(body) != .block) {
                    self.printError(gpa, "main is not of right block tag... what did you do?",self.ast.tokenLocation(0, self.ast.nodeMainToken(body)));
                    return &.{};
                }
                const range = self.ast.nodeData(body).extra_range;
                return self.ast.extraDataSlice(range, std.zig.Ast.Node.Index);
            }
        }
        const message = try std.fmt.allocPrint(gpa, "{s} function not defined", .{fn_name});
        defer gpa.free(message);
        self.printError(gpa, message, self.ast.tokenLocation(0, @intCast(self.ast.tokens.len-1)));
        return &.{};
    }
};

pub const ComComCode = struct {
	pub const Instruction = enum {
		ADD,
		SUB,
		MUL,
		DIV,
		LOD,
		STO,
		INP,
		JMP,
		JMZ,
		JGZ,
		FSH_S,
		FSH_B,
		AWT,
		HLT,
		FNC,
		ISF,
		DEL,
	};

	pub const Line = struct {
		cmd: Instruction,
		input: ?builtins.int,

		pub fn format(self: *const @This(), writer: *Io.Writer) Io.Writer.Error!void {
			if(self.input) |input| {
				try writer.print("{t} #{x}", .{self.cmd, input});
			} else {
				switch(self.cmd) {
					.FSH_B, .FSH_S => try writer.print("FSH", .{}),
					else => try writer.print("{t}", .{self.cmd}),
				}
			}
		}
	};

	lines: std.ArrayList(Line) = .empty,

	pub fn deinit(self: *@This(), gpa: Allocator) void {
		self.lines.deinit(gpa);
	}

	pub fn format(self: *const @This(), writer: *Io.Writer) Io.Writer.Error!void {
		for(self.lines.items, 0..) |line, i| {
			try writer.print("{d} {f}\n", .{i+1, line});
		}
	}
};