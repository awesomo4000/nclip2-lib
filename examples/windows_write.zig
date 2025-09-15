const std = @import("std");
const clipboard = @import("clipboard");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_text = "Hello from Windows clipboard! 🪟";

    std.log.info("Windows Clipboard Writer", .{});
    std.log.info("Writing text to clipboard: {s}", .{test_text});

    try clipboard.writeClipboardText(allocator, test_text);

    std.log.info("Success! Text written to clipboard.", .{});

    // Verify by reading it back
    var data = try clipboard.readClipboardData(allocator);
    defer data.deinit();

    if (data.format == .text) {
        const read_text = try data.asText();
        std.log.info("Verification: Read back '{s}'", .{read_text});
        if (std.mem.eql(u8, test_text, read_text)) {
            std.log.info("✓ Write and read verification successful!", .{});
        } else {
            std.log.err("✗ Read text doesn't match written text", .{});
        }
    } else {
        std.log.err("Unexpected format when reading back: {}", .{data.format});
    }
}