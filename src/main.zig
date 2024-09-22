const std = @import("std");

const io = std.io;
const linux = std.os.linux;
const ascii = std.ascii;

const STDIN = io.getStdIn().reader();
const STDOUT = io.getStdOut().writer();
const STDIN_FILENO = linux.STDIN_FILENO;

const Editor = struct {
    const Self = @This();

    orig_termios: linux.termios = undefined,

    fn init() !Self {
        return Self{};
    }

    fn deinit(self: *Self) void {
        _ = linux.tcsetattr(STDIN_FILENO, .FLUSH, &self.orig_termios);
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
};

pub fn main() !void {
    var editor = try Editor.init();
    defer editor.deinit();

    try editor.enableRawMode();

    var c = [_]u8{0};
    while (true) {
        // NOTE: VTIME is not being respected, `read` is hanging;
        _ = linux.read(STDIN_FILENO, &c, 1);
        if (ascii.isControl(c[0])) {
            try STDOUT.print("{}\r\n", .{c[0]});
        } else {
            try STDOUT.print("{} {c}\r\n", .{ c[0], c[0] });
        }
        if (c[0] == 'q') break;
    }
}
