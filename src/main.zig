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
    ctrl_q = 17,
    esc = 27,
    arrow_up = 128,
    arrow_down,
    arrow_right,
    arrow_left,
    _,
};

const Editor = struct {
    const Self = @This();

    allocator: mem.Allocator,
    c: [4]u8 = undefined,
    orig_termios: linux.termios = undefined,
    screenrows: u16 = 0,
    screencols: u16 = 0,
    cx: u16 = 0, // Horizontal coordinate of the cursor (the column)
    cy: u16 = 0, // Vertical coordinate of the cursor (the row)

    fn init(allocator: mem.Allocator) !Self {
        return Self{ .allocator = allocator, .c = [_]u8{0} ** 4 };
    }

    fn deinit(self: *Self) void {
        self.disableRawMode();
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

    fn readKey(self: *Self) !u8 {
        _ = linux.read(linux.STDIN_FILENO, self.c[0..1], 1);
        defer {
            self.c = [_]u8{0} ** 4;
        }
        switch (@as(Key, @enumFromInt(self.c[0]))) {
            .esc => {
                _ = linux.read(linux.STDIN_FILENO, self.c[1..3], 2);
                switch (self.c[1]) {
                    // 91
                    '[' => {
                        switch (self.c[2]) {
                            // 65
                            'A' => return @intFromEnum(Key.arrow_up),
                            // 66
                            'B' => return @intFromEnum(Key.arrow_down),
                            // 67
                            'C' => return @intFromEnum(Key.arrow_right),
                            // 68
                            'D' => return @intFromEnum(Key.arrow_left),
                            else => {},
                        }
                    },
                    else => {},
                }
            },
            else => {
                return self.c[0];
            },
        }

        return self.c[0];
    }

    fn processKeyPress(self: *Self) !void {
        const k = try self.readKey();
        switch (@as(Key, @enumFromInt(k))) {
            .ctrl_q => {
                self.disableRawMode();
                linux.exit(0);
            },
            .arrow_up, .arrow_down, .arrow_left, .arrow_right => {
                try self.moveCursor(@as(Key, @enumFromInt(k)));
            },
            else => {},
        }
    }

    fn refreshScreen(self: *Self) !void {
        var ab = ArrayList(u8).init(self.allocator);
        defer ab.deinit();
        // Hide the cursor when repainting
        try ab.appendSlice("\x1b[?25l");
        // Escape sequences always start with `Escape` (\x1b or 27) followed by `[`
        // H command, which is only 3 bytes long, puts the cursor at a certain position (1, 1) by default;
        try ab.appendSlice("\x1b[H");
        try self.drawRows(&ab);

        // Draw cursor on (`cx`, `cy`) position
        var buf: [32]u8 = undefined;
        _ = try std.fmt.bufPrint(&buf, "\x1b[{};{}H", .{ self.cx + 1, self.cy + 1 });
        try ab.appendSlice(&buf);

        try ab.appendSlice("\x1b[?25h");
        _ = linux.write(linux.STDOUT_FILENO, ab.items.ptr, ab.items.len);
    }

    fn drawRows(self: *Self, ab: *ArrayList(u8)) !void {
        for (0..self.screenrows) |y| {
            if (y == self.screencols / 3) {
                var buf: [64]u8 = undefined;
                const welcome = try std.fmt.bufPrint(&buf, "Zilo editor -- version {s}", .{ZILO_VERSION});
                var padding = if (welcome.len > self.screencols) 0 else (self.screencols - welcome.len) / 2;
                if (padding > 0) {
                    try ab.appendSlice("~");
                    padding -= 1;
                }
                for (0..padding) |_| try ab.appendSlice(" ");
                try ab.appendSlice(welcome);
            } else {
                try ab.appendSlice("~");
            }
            try ab.appendSlice("\x1b[K");
            if (y < self.screenrows - 1) {
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
            self.screenrows = winsize.row;
            self.screencols = winsize.col;
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
        self.screenrows = try std.fmt.parseInt(u16, buf_iter.next() orelse return error.InvalidFormat, 10);
        self.screencols = try std.fmt.parseInt(u16, buf_iter.next() orelse return error.InvalidFormat, 10);
    }

    fn moveCursor(self: *Self, key: Key) !void {
        switch (key) {
            .arrow_up => {
                self.cx -= 1;
            },
            .arrow_down => {
                self.cx += 1;
            },
            .arrow_right => {
                self.cy += 1;
            },
            .arrow_left => {
                self.cy -= 1;
            },
            else => unreachable,
        }
    }
};

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa_impl.allocator();
    defer _ = gpa_impl.deinit();

    var editor = try Editor.init(allocator);
    defer editor.deinit();

    try editor.enableRawMode();
    // NOTE: Temporary
    try editor.getWindowSize();
    while (true) {
        try editor.refreshScreen();
        try editor.processKeyPress();
    }
}
