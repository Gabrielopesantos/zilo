const std = @import("std");

const io = std.io;
const linux = std.os.linux;
const ascii = std.ascii;
const mem = std.mem;

const STDIN = io.getStdIn().reader();
const STDOUT = io.getStdOut().writer();
const STDIN_FILENO = linux.STDIN_FILENO;
const STDOUT_FILENO = linux.STDOUT_FILENO;

const Key = enum(u8) { ctrl_q = 17, _ };

const Editor = struct {
    const Self = @This();

    allocator: mem.Allocator,
    c: [1]u8 = undefined,
    orig_termios: linux.termios = undefined,
    num_rows: u16 = 0,
    num_cols: u16 = 0,

    fn init(allocator: mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .c = [_]u8{0},
        };
    }

    fn deinit(self: *Self) void {
        self.disableRawMode();
    }

    fn enableRawMode(self: *Self) !void {
        _ = linux.tcgetattr(STDIN_FILENO, &self.orig_termios);
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
        const VMIN = 5;
        const VTIME = 6;
        // Min number of bytes of input needed before `read()` can return.
        termios.cc[VMIN] = 0;
        // Max amount of time, in tenths of a second, to wait before `read()` returns.
        termios.cc[VTIME] = 1;

        _ = linux.tcsetattr(STDIN_FILENO, .FLUSH, &termios);
    }

    fn disableRawMode(self: *Self) void {
        _ = linux.tcsetattr(STDIN_FILENO, .FLUSH, &self.orig_termios);
    }

    fn readKey(self: *Self) !void {
        while (true) {
            // NOTE: VTIME is not being respected, `read` is hanging;
            _ = linux.read(STDIN_FILENO, &self.c, 1);
            break;
        }
    }

    fn processKeyPress(self: *Self) !void {
        try self.readKey();
        switch (@as(Key, @enumFromInt(self.c[0]))) {
            .ctrl_q => {
                self.disableRawMode();
                linux.exit(0);
            },
            else => {},
        }
    }

    fn refreshScreen(self: *Self) !void {
        // Writting 4 bytes out to the terminal, `\x1b` (27) and `[2J`.
        // Escape sequences always start with `Escape` followed by `[`
        // We are using the J command (Erase In Display) to clear the screen.
        // Escape sequence commands take arguments, which come before the command.
        // In this case the argument is 2, which says to clear the entire screen
        _ = try STDOUT.writeAll("\x1b[2J");
        // H command, which is only 3 bytes long, puts the cursor at a certain position (1, 1) by default;
        _ = linux.write(linux.STDOUT_FILENO, "\x1b[H", 3);

        try self.drawRows();

        _ = linux.write(linux.STDOUT_FILENO, "\x1b[H", 3);
    }

    fn drawRows(self: *Self) !void {
        for (0..self.num_cols) |_| {
            _ = try STDOUT.write("~\r\n");
        }
    }

    fn getWindowSize(self: *Self) !void {
        var winsize: std.posix.winsize = undefined;
        if (linux.ioctl(
            STDOUT_FILENO,
            0x5413, // TIOCGWINSZ
            @intFromPtr(&winsize),
        ) == -1 or winsize.col == 0) {
            const strn = "\x1b[999C\x1b[999B";
            _ = linux.write(STDOUT_FILENO, strn, strn.len);
        } else {
            self.num_rows = winsize.row;
            self.num_cols = winsize.col;
        }
    }
};

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa_impl.allocator();
    defer _ = gpa_impl.deinit();

    var editor = try Editor.init(allocator);
    defer editor.deinit();

    // NOTE: Temporary
    try editor.getWindowSize();

    try editor.enableRawMode();
    while (true) {
        try editor.refreshScreen();
        try editor.processKeyPress();
    }
}
