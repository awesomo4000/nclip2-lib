const std = @import("std");
const clipboard = @import("../clipboard.zig");
const windows = std.os.windows;

const user32 = struct {
    extern "user32" fn OpenClipboard(hWndNewOwner: ?windows.HWND) callconv(.winapi) windows.BOOL;
    extern "user32" fn CloseClipboard() callconv(.winapi) windows.BOOL;
    extern "user32" fn EmptyClipboard() callconv(.winapi) windows.BOOL;
    extern "user32" fn GetClipboardData(uFormat: c_uint) callconv(.winapi) ?windows.HANDLE;
    extern "user32" fn SetClipboardData(uFormat: c_uint, hMem: ?windows.HANDLE) callconv(.winapi) ?windows.HANDLE;
    extern "user32" fn IsClipboardFormatAvailable(format: c_uint) callconv(.winapi) windows.BOOL;
    extern "user32" fn EnumClipboardFormats(format: c_uint) callconv(.winapi) c_uint;
    extern "user32" fn GetClipboardFormatNameW(format: c_uint, lpszFormatName: [*]u16, cchMaxCount: c_int) callconv(.winapi) c_int;
    extern "user32" fn RegisterClipboardFormatW(lpszFormat: [*:0]const u16) callconv(.winapi) c_uint;
};

const kernel32 = struct {
    extern "kernel32" fn GlobalAlloc(uFlags: c_uint, dwBytes: usize) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn GlobalFree(hMem: ?windows.HANDLE) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn GlobalLock(hMem: ?windows.HANDLE) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GlobalUnlock(hMem: ?windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GlobalSize(hMem: ?windows.HANDLE) callconv(.winapi) usize;
};

const CF_TEXT = 1;
const CF_BITMAP = 2;
const CF_DIB = 8;
const CF_UNICODETEXT = 13;
const CF_HDROP = 15;

const GMEM_MOVEABLE = 0x0002;
const GMEM_ZEROINIT = 0x0040;

var cf_html: c_uint = 0;
var cf_rtf: c_uint = 0;

pub const PlatformType = enum {
    windows,
};

pub fn detectPlatform() PlatformType {
    return .windows;
}

fn ensureCustomFormats() void {
    if (cf_html == 0) {
        const html_name = std.unicode.utf8ToUtf16LeStringLiteral("HTML Format");
        cf_html = user32.RegisterClipboardFormatW(html_name);
    }
    if (cf_rtf == 0) {
        const rtf_name = std.unicode.utf8ToUtf16LeStringLiteral("Rich Text Format");
        cf_rtf = user32.RegisterClipboardFormatW(rtf_name);
    }
}

pub const ClipboardBackend = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !ClipboardBackend {
        ensureCustomFormats();
        return ClipboardBackend{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ClipboardBackend) void {
        _ = self;
    }

    pub fn read(self: *ClipboardBackend, format: clipboard.ClipboardFormat) !clipboard.ClipboardData {
        if (user32.OpenClipboard(null) == 0) {
            return clipboard.ClipboardError.ReadFailed;
        }
        defer _ = user32.CloseClipboard();

        const cf_format = switch (format) {
            .text => CF_UNICODETEXT,
            .image => CF_DIB,
            .html => cf_html,
            .rtf => cf_rtf,
        };

        if (cf_format == 0) {
            return clipboard.ClipboardError.UnsupportedPlatform;
        }

        const handle = user32.GetClipboardData(cf_format) orelse {
            return clipboard.ClipboardError.NoData;
        };

        const ptr = kernel32.GlobalLock(handle) orelse {
            return clipboard.ClipboardError.ReadFailed;
        };
        defer _ = kernel32.GlobalUnlock(handle);

        const size = kernel32.GlobalSize(handle);
        if (size == 0) {
            return clipboard.ClipboardError.NoData;
        }

        switch (format) {
            .text => {
                const utf16_ptr = @as([*]const u16, @ptrCast(@alignCast(ptr)));
                const utf16_len = std.mem.indexOfScalar(u16, utf16_ptr[0..size/2], 0) orelse size/2;
                const utf16_slice = utf16_ptr[0..utf16_len];

                const utf8_data = std.unicode.utf16LeToUtf8Alloc(self.allocator, utf16_slice) catch {
                    return clipboard.ClipboardError.InvalidData;
                };

                return clipboard.ClipboardData{
                    .data = utf8_data,
                    .format = format,
                    .allocator = self.allocator,
                };
            },
            .image => {
                const data = self.allocator.alloc(u8, size) catch {
                    return clipboard.ClipboardError.OutOfMemory;
                };
                errdefer self.allocator.free(data);

                const src_bytes = @as([*]const u8, @ptrCast(ptr));
                @memcpy(data, src_bytes[0..size]);

                return clipboard.ClipboardData{
                    .data = data,
                    .format = format,
                    .allocator = self.allocator,
                };
            },
            .html, .rtf => {
                const src_ptr = @as([*]const u8, @ptrCast(ptr));
                const actual_size = std.mem.indexOfScalar(u8, src_ptr[0..size], 0) orelse size;

                const data = self.allocator.alloc(u8, actual_size) catch {
                    return clipboard.ClipboardError.OutOfMemory;
                };
                errdefer self.allocator.free(data);

                @memcpy(data, src_ptr[0..actual_size]);

                return clipboard.ClipboardData{
                    .data = data,
                    .format = format,
                    .allocator = self.allocator,
                };
            },
        }
    }

    pub fn write(self: *ClipboardBackend, data: []const u8, format: clipboard.ClipboardFormat) !void {
        _ = self;

        if (user32.OpenClipboard(null) == 0) {
            return clipboard.ClipboardError.WriteFailed;
        }
        defer _ = user32.CloseClipboard();

        if (user32.EmptyClipboard() == 0) {
            return clipboard.ClipboardError.WriteFailed;
        }

        switch (format) {
            .text => {
                const utf16_len = std.unicode.calcUtf16LeLen(data) catch {
                    return clipboard.ClipboardError.InvalidData;
                };

                const handle = kernel32.GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, (utf16_len + 1) * 2) orelse {
                    return clipboard.ClipboardError.OutOfMemory;
                };
                errdefer _ = kernel32.GlobalFree(handle);

                const ptr = kernel32.GlobalLock(handle) orelse {
                    _ = kernel32.GlobalFree(handle);
                    return clipboard.ClipboardError.WriteFailed;
                };
                defer _ = kernel32.GlobalUnlock(handle);

                const utf16_ptr = @as([*]u16, @ptrCast(@alignCast(ptr)));
                _ = std.unicode.utf8ToUtf16Le(utf16_ptr[0..utf16_len], data) catch {
                    return clipboard.ClipboardError.InvalidData;
                };
                utf16_ptr[utf16_len] = 0;

                if (user32.SetClipboardData(CF_UNICODETEXT, handle) == null) {
                    return clipboard.ClipboardError.WriteFailed;
                }
            },
            .image => {
                const handle = kernel32.GlobalAlloc(GMEM_MOVEABLE, data.len) orelse {
                    return clipboard.ClipboardError.OutOfMemory;
                };
                errdefer _ = kernel32.GlobalFree(handle);

                const ptr = kernel32.GlobalLock(handle) orelse {
                    _ = kernel32.GlobalFree(handle);
                    return clipboard.ClipboardError.WriteFailed;
                };
                defer _ = kernel32.GlobalUnlock(handle);

                const dest_ptr = @as([*]u8, @ptrCast(ptr));
                @memcpy(dest_ptr, data);

                if (user32.SetClipboardData(CF_DIB, handle) == null) {
                    return clipboard.ClipboardError.WriteFailed;
                }
            },
            .html => {
                ensureCustomFormats();
                if (cf_html == 0) {
                    return clipboard.ClipboardError.UnsupportedPlatform;
                }

                const handle = kernel32.GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, data.len + 1) orelse {
                    return clipboard.ClipboardError.OutOfMemory;
                };
                errdefer _ = kernel32.GlobalFree(handle);

                const ptr = kernel32.GlobalLock(handle) orelse {
                    _ = kernel32.GlobalFree(handle);
                    return clipboard.ClipboardError.WriteFailed;
                };
                defer _ = kernel32.GlobalUnlock(handle);

                const dest_ptr = @as([*]u8, @ptrCast(ptr));
                @memcpy(dest_ptr, data);
                dest_ptr[data.len] = 0;

                if (user32.SetClipboardData(cf_html, handle) == null) {
                    return clipboard.ClipboardError.WriteFailed;
                }
            },
            .rtf => {
                ensureCustomFormats();
                if (cf_rtf == 0) {
                    return clipboard.ClipboardError.UnsupportedPlatform;
                }

                const handle = kernel32.GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, data.len + 1) orelse {
                    return clipboard.ClipboardError.OutOfMemory;
                };
                errdefer _ = kernel32.GlobalFree(handle);

                const ptr = kernel32.GlobalLock(handle) orelse {
                    _ = kernel32.GlobalFree(handle);
                    return clipboard.ClipboardError.WriteFailed;
                };
                defer _ = kernel32.GlobalUnlock(handle);

                const dest_ptr = @as([*]u8, @ptrCast(ptr));
                @memcpy(dest_ptr, data);
                dest_ptr[data.len] = 0;

                if (user32.SetClipboardData(cf_rtf, handle) == null) {
                    return clipboard.ClipboardError.WriteFailed;
                }
            },
        }
    }

    pub fn clear(self: *ClipboardBackend) !void {
        _ = self;

        if (user32.OpenClipboard(null) == 0) {
            return clipboard.ClipboardError.WriteFailed;
        }
        defer _ = user32.CloseClipboard();

        if (user32.EmptyClipboard() == 0) {
            return clipboard.ClipboardError.WriteFailed;
        }
    }

    pub fn processEvents(self: *ClipboardBackend) void {
        _ = self;
    }
};

pub fn getClipboardDataAuto(allocator: std.mem.Allocator) !clipboard.ClipboardData {
    var backend = try ClipboardBackend.init(allocator);
    defer backend.deinit();

    if (user32.OpenClipboard(null) == 0) {
        return clipboard.ClipboardError.ReadFailed;
    }
    defer _ = user32.CloseClipboard();

    if (user32.IsClipboardFormatAvailable(CF_UNICODETEXT) != 0) {
        return backend.read(.text);
    }

    ensureCustomFormats();
    if (cf_html != 0 and user32.IsClipboardFormatAvailable(cf_html) != 0) {
        return backend.read(.html);
    }

    if (cf_rtf != 0 and user32.IsClipboardFormatAvailable(cf_rtf) != 0) {
        return backend.read(.rtf);
    }

    if (user32.IsClipboardFormatAvailable(CF_DIB) != 0) {
        return backend.read(.image);
    }

    return clipboard.ClipboardError.NoData;
}

pub fn getAvailableClipboardFormats(allocator: std.mem.Allocator) ![]clipboard.ClipboardFormat {
    var formats = std.ArrayList(clipboard.ClipboardFormat).init(allocator);
    defer formats.deinit();

    if (user32.OpenClipboard(null) == 0) {
        return clipboard.ClipboardError.ReadFailed;
    }
    defer _ = user32.CloseClipboard();

    if (user32.IsClipboardFormatAvailable(CF_UNICODETEXT) != 0) {
        try formats.append(.text);
    }

    if (user32.IsClipboardFormatAvailable(CF_DIB) != 0) {
        try formats.append(.image);
    }

    ensureCustomFormats();
    if (cf_html != 0 and user32.IsClipboardFormatAvailable(cf_html) != 0) {
        try formats.append(.html);
    }

    if (cf_rtf != 0 and user32.IsClipboardFormatAvailable(cf_rtf) != 0) {
        try formats.append(.rtf);
    }

    return formats.toOwnedSlice();
}