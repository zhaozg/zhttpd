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
    file: ?std.fs.File,
    file_path: []const u8,
    max_size: usize,
    max_backups: usize,
    current_size: usize,
    mutex: std.Thread.Mutex,

    const DEFAULT_MAX_SIZE: usize = 10 * 1024 * 1024; // 10MB
    const DEFAULT_MAX_BACKUPS: usize = 5;

    pub fn init(allocator: std.mem.Allocator, file_path: []const u8) !*FileBackend {
        const self = try allocator.create(FileBackend);
        errdefer allocator.destroy(self);

        const owned_path = try allocator.dupe(u8, file_path);
        errdefer allocator.free(owned_path);

        const file = try std.fs.cwd().createFile(file_path, .{
            .read = false,
            .truncate = false,
        });
        errdefer file.close();

        const stat = try file.stat();
        try file.seekFromEnd(0);

        self.* = .{
            .allocator = allocator,
            .file = file,
            .file_path = owned_path,
            .max_size = DEFAULT_MAX_SIZE,
            .max_backups = DEFAULT_MAX_BACKUPS,
            .current_size = stat.size,
            .mutex = .{},
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
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.file) |file| {
            _ = try file.write(msg);
            self.current_size += msg.len;

            if (self.current_size >= self.max_size) {
                try self.rotateLog();
            }
        }
    }

    fn flush(ptr: *anyopaque) !void {
        const self: *FileBackend = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.file) |file| {
            try file.sync();
        }
    }

    fn deinitBackend(ptr: *anyopaque) void {
        const self: *FileBackend = @ptrCast(@alignCast(ptr));
        if (self.file) |file| {
            file.close();
        }
        self.allocator.free(self.file_path);
        self.allocator.destroy(self);
    }

    fn rotateLog(self: *FileBackend) !void {
        if (self.file) |file| {
            file.close();
            self.file = null;
        }

        // Delete oldest backup
        const oldest = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ self.file_path, self.max_backups });
        defer self.allocator.free(oldest);
        std.fs.cwd().deleteFile(oldest) catch {};

        // Rotate existing backups
        var i: usize = self.max_backups - 1;
        while (i > 0) : (i -= 1) {
            const old_name = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ self.file_path, i });
            defer self.allocator.free(old_name);

            const new_name = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ self.file_path, i + 1 });
            defer self.allocator.free(new_name);

            std.fs.cwd().rename(old_name, new_name) catch {};
        }

        // Rename current to .1
        const backup = try std.fmt.allocPrint(self.allocator, "{s}.1", .{self.file_path});
        defer self.allocator.free(backup);
        std.fs.cwd().rename(self.file_path, backup) catch {};

        // Create new file
        self.file = try std.fs.cwd().createFile(self.file_path, .{
            .read = false,
            .truncate = false,
        });
        self.current_size = 0;
    }
};

/// Console backend writes logs to stderr
pub const ConsoleBackend = struct {
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) !*ConsoleBackend {
        const self = try allocator.create(ConsoleBackend);
        self.* = .{
            .mutex = .{},
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
        const self: *ConsoleBackend = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        // Use debug.print for console output
        std.debug.print("{s}", .{msg});
    }

    fn flush(ptr: *anyopaque) !void {
        _ = ptr;
        // stderr is typically unbuffered
    }

    fn deinitBackend(ptr: *anyopaque) void {
        const self: *ConsoleBackend = @ptrCast(@alignCast(ptr));
        // Store allocator before destroying self
        const allocator = @as(*std.mem.Allocator, @ptrCast(@alignCast(@constCast(&self.mutex)))).*;
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
