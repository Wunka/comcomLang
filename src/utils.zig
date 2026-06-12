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
        for (self.data[loc.line_start .. loc.line_start + loc.column]) |c| {
            if (c == '\t') {
                startLineChars.append(gpa, '\t') catch {};
            } else {
                startLineChars.append(gpa, ' ') catch {};
            }
        }
        self.failed = true;

        std.log.err("{s}:{}:{}: {s}\n{s}\n{s}^", .{ self.filePath, loc.line, loc.column, msg, self.data[loc.line_start..loc.line_end], startLineChars.items });
    }

    pub fn printInfo(self: *const Context, gpa: Allocator, msg: []const u8, loc: std.zig.Ast.Location) void {
        var startLineChars: std.ArrayList(u8) = .empty;
        defer startLineChars.deinit(gpa);
        for (self.data[loc.line_start .. loc.line_start + loc.column]) |c| {
            if (c == '\t') {
                startLineChars.append(gpa, '\t') catch {};
            } else {
                startLineChars.append(gpa, ' ') catch {};
            }
        }

        std.log.info("{s}:{}:{}: {s}\n{s}\n{s}^", .{ self.filePath, loc.line, loc.column, msg, self.data[loc.line_start..loc.line_end], startLineChars.items });
    }

    pub fn getFunctionBody(self: *Context, gpa: Allocator, fn_name: []const u8) error{OutOfMemory}![]const std.zig.Ast.Node.Index {
        const root = self.ast.rootDecls();
        for (root) |index| {
            if (self.ast.nodeTag(index) == .fn_decl) {
                const head = self.ast.nodeData(index).node_and_node.@"0";
                const name = self.ast.tokenSlice(self.ast.nodeMainToken(head) + 1);
                if (!std.mem.eql(u8, name, fn_name)) continue;

                const body = self.ast.nodeData(index).node_and_node.@"1";
                if (self.ast.nodeTag(body) != .block_semicolon and self.ast.nodeTag(body) != .block) {
                    self.printError(gpa, "main is not of right block tag... what did you do?", self.ast.tokenLocation(0, self.ast.nodeMainToken(body)));
                    return &.{};
                }
                const range = self.ast.nodeData(body).extra_range;
                return self.ast.extraDataSlice(range, std.zig.Ast.Node.Index);
            }
        }
        const message = try std.fmt.allocPrint(gpa, "{s} function not defined", .{fn_name});
        defer gpa.free(message);
        self.printError(gpa, message, self.ast.tokenLocation(0, @intCast(self.ast.tokens.len - 1)));
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
            if (self.input) |input| {
                try writer.print("{t} #{x}", .{ self.cmd, input });
            } else {
                switch (self.cmd) {
                    .FSH_B, .FSH_S => try writer.print("FSH", .{}),
                    else => try writer.print("{t}", .{self.cmd}),
                }
            }
        }
    };

    pub const Block = struct {
        pub const Kind = enum {
            if_e,
            if_g,
            while_e,
            while_g,
            without,

            fn getHeadLineCount(self: Kind) usize {
                return switch (self) {
                    else => 0,
                };
            }
        };

        kind: Kind,

        headStack: std.ArrayList(Line) = .empty,
        lines: std.ArrayList(Line) = .empty,
        deferStack: std.ArrayList(Line) = .empty,
        lineStart: builtins.uint,

        pub fn open(kind: Kind, code: *ComComCode) Block {
            const block: Block = .{
                .kind = kind,
                .lineStart = code.currentLine,
            };
            return block;
        }

        pub fn close(self: *Block, gpa: Allocator, code: *ComComCode) error{OutOfMemory}!void {
            for (self.headStack.items) |line| {
                try code.appendAssumeLineCount(gpa, line);
            }
            self.headStack.deinit(gpa);

            switch (self.kind) {
                .if_e, .while_e => try code.appendAssumeLineCount(gpa, .{
                    .cmd = .JMZ,
                    .input = @bitCast(code.currentLine),
                }),
                .if_g, .while_g => try code.appendAssumeLineCount(gpa, .{
                    .cmd = .JMP,
                    .input = @bitCast(code.currentLine),
                }),
                else => {},
            }

            for (self.lines.items) |line| {
                try code.appendAssumeLineCount(gpa, line);
            }
            self.lines.deinit(gpa);

            for (0..self.deferStack.items.len) |i| {
                try code.appendAssumeLineCount(gpa, self.deferStack.items[self.deferStack.items.len - 1 - i]);
            }
            self.deferStack.deinit(gpa);

            switch (self.kind) {
                .while_g, .while_e => try code.append(gpa, .{
                    .cmd = .JMP,
                    .input = @bitCast(self.lineStart),
                }),
                else => {},
            }
        }

        pub fn append(self: *Block, gpa: Allocator, line: Line) error{OutOfMemory}!void {
            try self.lines.append(gpa, line);
        }

        pub fn appendHead(self: *Block, gpa: Allocator, line: Line) error{OutOfMemory}!void {
            try self.headStack.append(gpa, line);
        }
    };

    lines: std.ArrayList(Line) = .empty,
    stack: std.ArrayList(Block) = .empty,
    currentLine: builtins.uint = 0,

    pub fn deinit(self: *@This(), gpa: Allocator) void {
        self.lines.deinit(gpa);
    }

    pub fn openBlock(self: *ComComCode, gpa: Allocator, kind: Block.Kind) error{OutOfMemory}!void {
        try self.stack.append(gpa, .open(kind, self));
    }

    pub fn closeBlock(self: *ComComCode, gpa: Allocator) error{OutOfMemory}!void {
        var block = self.stack.pop() orelse return;
        try block.close(gpa, self);
    }

    pub fn appendHead(self: *ComComCode, gpa: Allocator, line: Line) void {
        var block = self.stack.pop() orelse return;
        block.appendHead(self, gpa, line);
    }

    pub fn append(self: *ComComCode, gpa: Allocator, line: Line) error{OutOfMemory}!void {
        if (self.currentLine == std.math.maxInt(builtins.uint)) @panic("Out of lines");
        self.currentLine += 1;
        if (self.stack.getLastOrNull()) |*body| {
            try body.append(gpa, line);
        }
        try self.lines.append(gpa, line);
    }

    pub fn appendAssumeLineCount(self: *ComComCode, gpa: Allocator, line: Line) error{OutOfMemory}!void {
        if (self.stack.getLastOrNull()) |*body| {
            try body.append(gpa, line);
        }
        try self.lines.append(gpa, line);
    }

    pub fn format(self: *const @This(), writer: *Io.Writer) Io.Writer.Error!void {
        for (self.lines.items, 0..) |line, i| {
            try writer.print("{d} {f}\n", .{ i + 1, line });
        }
    }
};
