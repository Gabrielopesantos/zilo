const std = @import("std");

const io = std.io;
const linux = std.os.linux;
const ascii = std.ascii;
const mem = std.mem;
const ArrayList = std.ArrayList;

const STDIN = io.getStdIn().reader();
const STDOUT = io.getStdOut().writer();

const ZILO_VERSION = "0.0.1";

const Key = enum(u8) {
    CTRL_Q = 17,
    ESC = 27,
    ARROW_UP = 128,
    ARROW_DOWN,
    ARROW_RIGHT,
    ARROW_LEFT,
    HOME,
    END,
    DEL,
    PAGE_UP,
    PAGE_DOWN,
    _,
};

const Editor = struct {
    const Self = @This();

    alloc: mem.Allocator,
    orig_termios: linux.termios = undefined,
    screen_rows: u16 = 0,
    screen_cols: u16 = 0,
    cx: u16 = 0, // Horizontal coordinate of the cursor (the column)
    cy: u16 = 0, // Vertical coordinate of the cursor (the row)
    row_offset: u16 = 0, // Row of the file the user is currently scrolled to
    col_offset: u16 = 0, // Column of the file the user is currently on
    rows: ArrayList([]u8), // Editor row of texts;

    fn init(alloc: mem.Allocator) !Self {
        return Self{ .alloc = alloc, .rows = ArrayList([]u8).init(alloc) };
    }

    fn deinit(self: *Self) void {
        self.disableRawMode();
        for (self.rows.items) |row| {
            self.alloc.free(row);
        }
        self.rows.deinit();
    }

    fn enableRawMode(self: *Self) !void {
        _ = linux.tcgetattr(linux.STDIN_FILENO, &self.orig_termios);
        var termios = self.orig_termios;

        // Terminal local flags disabled;
        // ECHO - Keys pressed aren't printed in the terminal
        termios.lflag.ECHO = false;
        // Both of the following flags start with a I but are still in local
        // flags, not input flags
        // ICANON - Canonical mode, allows reading byte-by-byte, instead of
        // line-by-line (With this, program will quit as soon as `q` is pressed)
        termios.lflag.ICANON = false;
        // ISIG - Disable Ctrl-C/Ctrl-Z signals (interrupt, suspend)
        termios.lflag.ISIG = false;
        // IEXTEN - Disable Ctrl-V
        termios.lflag.IEXTEN = false;

        // IXON - Disable Ctrl-S/Ctrl-Q signals (Stop and resume data from being
        // transmitted to the terminal)
        termios.iflag.IXON = false;
        // ICRNL - Fix Ctrl-M (Read as 10, by default, when 13 is expected)
        // Happens because terminal translates carriage return, \r, into new lines, \n.
        termios.iflag.ICRNL = false;
        // BRKINT - Already turned off or doesn't apply to modern terminal emulators.
        // When turned on, a break condition will cause SIGINT signal to be sent to the program, like pressing Ctrl-C
        termios.iflag.BRKINT = false;
        // INPCK - Already turned off or doesn't apply to modern terminal emulators.
        //  Enables parity checking, which doesn't seem to apply to modern terminal emulators.
        termios.iflag.INPCK = false;
        // ISTRIP - Already turned off or doesn't apply to modern terminal emulators.
        // Causes the 8th bit of each input byte to be stripped, meaning it iwll set it to 0.
        termios.iflag.ISTRIP = false;

        // OPOST - Turn off output processing, terminal translates each newline,
        // \n, into a carriage return followed by a newline, \r\n
        termios.oflag.OPOST = false;

        // CS8 - Already turned off or doesn't apply to modern terminal emulators.
        // It sets the character size (CS) to 8 bits per byte.
        termios.cflag.CSIZE = .CS8;

        // Set read timeout
        // VMIN and VTIME are indices into the cc_field, which stands for `control characters`,
        // an array of bytes that control various terminal settings.
        // #define VTIME 5
        // #define VMIN 6
        const VTIME = 5;
        const VMIN = 6;
        // Min number of bytes of input needed before `read()` can return.
        termios.cc[VMIN] = 0;
        // Max amount of time, in tenths of a second, to wait before `read()` returns.
        termios.cc[VTIME] = 1;

        _ = linux.tcsetattr(linux.STDIN_FILENO, .FLUSH, &termios);
    }

    fn disableRawMode(self: *Self) void {
        _ = linux.tcsetattr(linux.STDIN_FILENO, .FLUSH, &self.orig_termios);
    }

    fn readKey(_: *Self) !u8 {
        // var seq = try self.alloc.alloc(u8, 3);
        // defer self.alloc.free(seq);
        var seq = [_]u8{0} ** 4;
        _ = linux.read(linux.STDIN_FILENO, seq[0..1], 1);
        switch (@as(Key, @enumFromInt(seq[0]))) {
            .ESC => {
                _ = linux.read(linux.STDIN_FILENO, seq[1..2], 1);
                switch (seq[1]) {
                    // 91
                    '[' => {
                        _ = linux.read(linux.STDIN_FILENO, seq[2..3], 1);
                        switch (seq[2]) {
                            // 65
                            'A' => return @intFromEnum(Key.ARROW_UP),
                            // 66
                            'B' => return @intFromEnum(Key.ARROW_DOWN),
                            // 67
                            'C' => return @intFromEnum(Key.ARROW_RIGHT),
                            // 68
                            'D' => return @intFromEnum(Key.ARROW_LEFT),
                            'H' => return @intFromEnum(Key.HOME),
                            'F' => return @intFromEnum(Key.END),
                            '0'...'9' => {
                                _ = linux.read(linux.STDIN_FILENO, seq[3..4], 1);
                                if (seq[3] == '~') {
                                    switch (seq[2]) {
                                        '1' => return @intFromEnum(Key.HOME),
                                        '3' => return @intFromEnum(Key.DEL),
                                        '4' => return @intFromEnum(Key.END),
                                        '5' => return @intFromEnum(Key.PAGE_UP),
                                        '6' => return @intFromEnum(Key.PAGE_DOWN),
                                        '7' => return @intFromEnum(Key.HOME),
                                        '8' => return @intFromEnum(Key.END),
                                        else => {},
                                    }
                                }
                            },
                            else => {},
                        }
                    },
                    'O' => {
                        switch (seq[2]) {
                            'H' => return @intFromEnum(Key.HOME),
                            'F' => return @intFromEnum(Key.END),
                            else => {},
                        }
                    },
                    else => {},
                }
            },
            else => {
                return seq[0];
            },
        }

        return seq[0];
    }

    fn processKeyPress(self: *Self) !void {
        const k = try self.readKey();
        switch (@as(Key, @enumFromInt(k))) {
            .CTRL_Q => {
                self.disableRawMode();
                linux.exit(0);
            },
            .ARROW_UP, .ARROW_DOWN, .ARROW_LEFT, .ARROW_RIGHT => {
                try self.moveCursor(@as(Key, @enumFromInt(k)));
            },
            .HOME => {
                self.cx = 0;
            },
            .END => {
                self.cx = self.screen_cols - 1;
            },
            .PAGE_UP, .PAGE_DOWN => {
                for (0..self.screen_rows) |_| {
                    try self.moveCursor(if (k == @intFromEnum(Key.PAGE_UP)) Key.ARROW_UP else Key.ARROW_DOWN);
                }
            },
            else => {},
        }
    }

    fn refreshScreen(self: *Self) !void {
        self.scroll();
        var ab = ArrayList(u8).init(self.alloc);
        defer ab.deinit();
        // Hide the cursor when repainting
        try ab.appendSlice("\x1b[?25l");
        // Escape sequences always start with `Escape` (\x1b or 27) followed by `[`
        // H command, which is only 3 bytes long, puts the cursor at a certain position (1, 1) by default;
        try ab.appendSlice("\x1b[H");
        try self.drawRows(&ab);

        // Draw cursor on (`cx`, `cy`) position
        var buf: [32]u8 = undefined;
        _ = try std.fmt.bufPrint(&buf, "\x1b[{};{}H", .{ (self.cy - self.row_offset) + 1, (self.cx - self.col_offset) + 1 });
        try ab.appendSlice(&buf);

        try ab.appendSlice("\x1b[?25h");
        _ = linux.write(linux.STDOUT_FILENO, ab.items.ptr, ab.items.len);
    }

    fn drawRows(self: *Self, ab: *ArrayList(u8)) !void {
        // number of text rows to draw
        const num_text_rows = self.rows.items.len;
        // iterate over screen rows
        for (0..self.screen_rows) |y| {
            const file_row = y + self.row_offset;
            // check if there are text rows to be drawn
            if (file_row >= num_text_rows) {
                if (num_text_rows == 0 and y == self.screen_cols / 3) {
                    var buf: [64]u8 = undefined;
                    const welcome = try std.fmt.bufPrint(&buf, "Zilo editor -- version {s}", .{ZILO_VERSION});
                    var padding = if (welcome.len > self.screen_cols) 0 else (self.screen_cols - welcome.len) / 2;
                    if (padding > 0) {
                        try ab.appendSlice("~");
                        padding -= 1;
                    }
                    for (0..padding) |_| try ab.appendSlice(" ");
                    try ab.appendSlice(welcome);
                } else {
                    try ab.appendSlice("~");
                }
            } else {
                // draw text row
                var line_len = self.rows.items[file_row].len - self.col_offset;
                line_len = @min(@max(line_len, 0), self.screen_cols);
                try ab.appendSlice(self.rows.items[file_row][0..line_len]);
            }

            try ab.appendSlice("\x1b[K");
            if (y < self.screen_rows - 1) {
                try ab.appendSlice("\r\n");
            }
        }
    }

    fn getWindowSize(self: *Self) !void {
        var winsize: std.posix.winsize = undefined;
        if (linux.ioctl(
            linux.STDOUT_FILENO,
            0x5413, // TIOCGWINSZ
            @intFromPtr(&winsize),
        ) == -1 or winsize.col == 0) {
            const strn = "\x1b[999C\x1b[999B";
            _ = linux.write(linux.STDOUT_FILENO, strn, strn.len);
            return try self.getCursorPosition();
        } else {
            self.screen_rows = winsize.row;
            self.screen_cols = winsize.col;
        }
    }

    fn getCursorPosition(self: *Self) !void {
        var buf: [32]u8 = undefined;
        var i: usize = 0;

        const tmp = "\x1b[6n";
        _ = linux.write(linux.STDOUT_FILENO, tmp, tmp.len);
        while (i < buf.len - 1) {
            _ = linux.read(linux.STDIN_FILENO, @as([*]u8, @ptrCast(&buf[i])), 1);
            if (buf[i] == 'R') break;
            i += 1;
        }
        if (buf[0] != '\x1b' or buf[1] != '[') return error.CursorError;
        // Format follows \x1b[24;98R
        var buf_iter = std.mem.tokenizeAny(u8, buf[2..i], ";");
        self.screen_rows = try std.fmt.parseInt(u16, buf_iter.next() orelse return error.InvalidFormat, 10);
        self.screen_cols = try std.fmt.parseInt(u16, buf_iter.next() orelse return error.InvalidFormat, 10);
    }

    fn moveCursor(self: *Self, key: Key) !void {
        const num_text_rows = self.rows.items.len;
        var curr_row = if (self.cy < num_text_rows) self.rows.items[self.cy] else null;
        switch (key) {
            .ARROW_UP => {
                if (self.cy != 0) self.cy -= 1;
            },
            .ARROW_DOWN => {
                if (self.cy < num_text_rows) self.cy += 1;
            },
            .ARROW_RIGHT => {
                if (curr_row != null and self.cx < curr_row.?.len) {
                    self.cx += 1;
                } else if (curr_row != null and self.cx == curr_row.?.len) {
                    // move right at the end of a line
                    self.cy += 1;
                    self.cx = 0;
                }
            },
            .ARROW_LEFT => {
                if (self.cx != 0) {
                    self.cx -= 1;
                } else if (self.cy > 0) {
                    // move left at the start of a line
                    self.cy -= 1;
                    self.cx = @as(u16, @intCast(self.rows.items[self.cy].len));
                }
            },
            else => unreachable,
        }

        // snap cursor to the end of line
        curr_row = if (self.cy < num_text_rows) self.rows.items[self.cy] else null;
        if (curr_row) |value| {
            self.cx = @min(self.cx, value.len);
        }
    }

    fn open(self: *Self, filename: []const u8) !void {
        var file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();

        var file_reader = file.reader();
        while (true) {
            const line_bytes = file_reader.readUntilDelimiterOrEofAlloc(self.alloc, '\n', std.math.maxInt(usize)) catch |err| {
                std.log.err("error reading file bytes: {}", .{err});
                return;
            };
            if (line_bytes == null) {
                break;
            }
            try self.appendRow(line_bytes.?);
        }
    }

    fn appendRow(self: *Self, line: []u8) !void {
        try self.rows.append(line);
    }

    fn scroll(self: *Self) void {
        if (self.cy < self.row_offset) {
            self.row_offset = self.cy;
        }

        if (self.cy >= self.row_offset + self.screen_rows) {
            self.row_offset = self.cy - self.screen_rows + 1;
        }

        if (self.cx < self.col_offset) {
            self.col_offset = self.cx;
        }

        if (self.cx >= self.col_offset + self.screen_cols) {
            self.col_offset = self.cx - self.screen_cols + 1;
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var editor = try Editor.init(alloc);
    defer editor.deinit();
    errdefer editor.deinit();

    if (args.len >= 2) {
        const filename = args[1];
        try editor.open(filename);
    }

    try editor.enableRawMode();
    while (true) {
        try editor.getWindowSize();
        try editor.refreshScreen();
        try editor.processKeyPress();
    }
}
