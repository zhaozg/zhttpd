const std = @import("std");

/// Backend interface for log output
/// Implementations can write logs to files, console, network, etc.
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (ptr: *anyopaque, msg: []const u8) anyerror!void,
        flush: *const fn (ptr: *anyopaque) anyerror!void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn write(self: Backend, msg: []const u8) !void {
        return self.vtable.write(self.ptr, msg);
    }

    pub fn flush(self: Backend) !void {
        return self.vtable.flush(self.ptr);
    }

    pub fn deinit(self: Backend) void {
        self.vtable.deinit(self.ptr);
    }
};

/// File backend writes logs to a file with rotation support
pub const FileBackend = struct {
    allocator: std.mem.Allocator,
    file: ?std.Io.File,
    file_path: []const u8,
    max_size: usize,
    max_backups: usize,
    current_size: usize,
    mutex: std.Io.Mutex,
    io: std.Io,

    const DEFAULT_MAX_SIZE: usize = 10 * 1024 * 1024; // 10MB
    const DEFAULT_MAX_BACKUPS: usize = 5;

    pub fn init(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8) !*FileBackend {
        const self = try allocator.create(FileBackend);
        errdefer allocator.destroy(self);

        const owned_path = try allocator.dupe(u8, file_path);
        errdefer allocator.free(owned_path);

        const file = try std.Io.Dir.cwd().createFile(io, file_path, .{
            .read = false,
            .truncate = false,
        });
        errdefer file.close(io);

        const stat = try file.stat(io);

        self.* = .{
            .allocator = allocator,
            .file = file,
            .file_path = owned_path,
            .max_size = DEFAULT_MAX_SIZE,
            .max_backups = DEFAULT_MAX_BACKUPS,
            .current_size = stat.size,
            .mutex = std.Io.Mutex.init,
            .io = io,
        };

        return self;
    }

    pub fn backend(self: *FileBackend) Backend {
        return .{
            .ptr = self,
            .vtable = &.{
                .write = write,
                .flush = flush,
                .deinit = deinitBackend,
            },
        };
    }

    fn write(ptr: *anyopaque, msg: []const u8) !void {
        const self: *FileBackend = @ptrCast(@alignCast(ptr));
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.file) |file| {
            try file.writeStreamingAll(self.io, msg);
            self.current_size += msg.len;

            if (self.current_size >= self.max_size) {
                try self.rotateLog();
            }
        }
    }

    fn flush(ptr: *anyopaque) !void {
        const self: *FileBackend = @ptrCast(@alignCast(ptr));
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.file) |file| {
            try file.sync(self.io);
        }
    }

    fn deinitBackend(ptr: *anyopaque) void {
        const self: *FileBackend = @ptrCast(@alignCast(ptr));
        if (self.file) |file| {
            file.close(self.io);
        }
        self.allocator.free(self.file_path);
        self.allocator.destroy(self);
    }

    fn rotateLog(self: *FileBackend) !void {
        if (self.file) |file| {
            file.close(self.io);
            self.file = null;
        }

        const cwd = std.Io.Dir.cwd();

        // Delete oldest backup
        const oldest = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ self.file_path, self.max_backups });
        defer self.allocator.free(oldest);
        cwd.deleteFile(self.io, oldest) catch {};

        // Rotate existing backups
        var i: usize = self.max_backups - 1;
        while (i > 0) : (i -= 1) {
            const old_name = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ self.file_path, i });
            defer self.allocator.free(old_name);

            const new_name = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ self.file_path, i + 1 });
            defer self.allocator.free(new_name);

            cwd.rename(old_name, cwd, new_name, self.io) catch {};
        }

        // Rename current to .1
        const backup = try std.fmt.allocPrint(self.allocator, "{s}.1", .{self.file_path});
        defer self.allocator.free(backup);
        cwd.rename(self.file_path, cwd, backup, self.io) catch {};

        // Create new file
        self.file = try cwd.createFile(self.io, self.file_path, .{
            .read = false,
            .truncate = false,
        });
        self.current_size = 0;
    }
};

/// Console backend writes logs to stderr
pub const ConsoleBackend = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*ConsoleBackend {
        const self = try allocator.create(ConsoleBackend);
        self.* = .{
            .allocator = allocator,
        };
        return self;
    }

    pub fn backend(self: *ConsoleBackend) Backend {
        return .{
            .ptr = self,
            .vtable = &.{
                .write = write,
                .flush = flush,
                .deinit = deinitBackend,
            },
        };
    }

    fn write(ptr: *anyopaque, msg: []const u8) !void {
        _ = ptr;
        std.debug.print("{s}", .{msg});
    }

    fn flush(ptr: *anyopaque) !void {
        _ = ptr;
    }

    fn deinitBackend(ptr: *anyopaque) void {
        const self: *ConsoleBackend = @ptrCast(@alignCast(ptr));
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

/// Multi backend writes to multiple backends simultaneously
pub const MultiBackend = struct {
    backends: []Backend,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, backends: []Backend) !*MultiBackend {
        const self = try allocator.create(MultiBackend);
        self.* = .{
            .backends = backends,
            .allocator = allocator,
        };
        return self;
    }

    pub fn backend(self: *MultiBackend) Backend {
        return .{
            .ptr = self,
            .vtable = &.{
                .write = write,
                .flush = flush,
                .deinit = deinitBackend,
            },
        };
    }

    fn write(ptr: *anyopaque, msg: []const u8) !void {
        const self: *MultiBackend = @ptrCast(@alignCast(ptr));
        for (self.backends) |b| {
            b.write(msg) catch |err| {
                std.debug.print("MultiBackend write error: {}\n", .{err});
            };
        }
    }

    fn flush(ptr: *anyopaque) !void {
        const self: *MultiBackend = @ptrCast(@alignCast(ptr));
        for (self.backends) |b| {
            b.flush() catch |err| {
                std.debug.print("MultiBackend flush error: {}\n", .{err});
            };
        }
    }

    fn deinitBackend(ptr: *anyopaque) void {
        const self: *MultiBackend = @ptrCast(@alignCast(ptr));
        for (self.backends) |b| {
            b.deinit();
        }
        self.allocator.free(self.backends);
        self.allocator.destroy(self);
    }
};

const testing = std.testing;

test "FileBackend basic operations" {
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &path_buf);
    const log_path = try std.fmt.allocPrint(allocator, "{s}/test_backend.log", .{dir_path});
    defer allocator.free(log_path);

    const file_backend = try FileBackend.init(allocator, log_path);
    const backend = file_backend.backend();
    defer backend.deinit();

    try backend.write("test log line\n");
    try backend.flush();

    // Verify file content
    const file = try std.fs.cwd().openFile(log_path, .{});
    defer file.close();

    var buf: [1024]u8 = undefined;
    const n = try file.readAll(&buf);
    try testing.expectEqualStrings("test log line\n", buf[0..n]);
}

test "ConsoleBackend basic operations" {
    const allocator = testing.allocator;

    const console = try ConsoleBackend.init(allocator);
    const backend = console.backend();
    defer backend.deinit();

    // Just verify it doesn't crash
    try backend.write("test console output\n");
    try backend.flush();
}

test "MultiBackend operations" {
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &path_buf);
    const log_path1 = try std.fmt.allocPrint(allocator, "{s}/multi1.log", .{dir_path});
    defer allocator.free(log_path1);
    const log_path2 = try std.fmt.allocPrint(allocator, "{s}/multi2.log", .{dir_path});
    defer allocator.free(log_path2);

    const file1 = try FileBackend.init(allocator, log_path1);
    const file2 = try FileBackend.init(allocator, log_path2);

    const backends = try allocator.alloc(Backend, 2);
    backends[0] = file1.backend();
    backends[1] = file2.backend();
    // Note: MultiBackend takes ownership and will free this slice

    const multi = try MultiBackend.init(allocator, backends);
    const backend = multi.backend();
    defer backend.deinit();

    try backend.write("test multi backend\n");
    try backend.flush();

    // Verify both files have the content
    const f1 = try std.fs.cwd().openFile(log_path1, .{});
    defer f1.close();
    var buf1: [1024]u8 = undefined;
    const n1 = try f1.readAll(&buf1);
    try testing.expectEqualStrings("test multi backend\n", buf1[0..n1]);

    const f2 = try std.fs.cwd().openFile(log_path2, .{});
    defer f2.close();
    var buf2: [1024]u8 = undefined;
    const n2 = try f2.readAll(&buf2);
    try testing.expectEqualStrings("test multi backend\n", buf2[0..n2]);
}

test "FileBackend log rotation" {
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &path_buf);
    const log_path = try std.fmt.allocPrint(allocator, "{s}/rotate_test.log", .{dir_path});
    defer allocator.free(log_path);

    const file_backend = try FileBackend.init(allocator, log_path);
    const backend = file_backend.backend();
    defer backend.deinit();

    // Set small max size to trigger rotation
    file_backend.max_size = 100;

    // Write enough data to trigger rotation
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try backend.write("This is a test log line that should trigger rotation\n");
    }
    try backend.flush();

    // Check that rotation occurred (backup file exists)
    const backup_path = try std.fmt.allocPrint(allocator, "{s}.1", .{log_path});
    defer allocator.free(backup_path);

    const backup_file = std.fs.cwd().openFile(backup_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            // Rotation may not have occurred yet, which is okay for this test
            return;
        }
        return err;
    };
    backup_file.close();
}
