// File that wraps access to /proc/+([0-9])/ and /proc/pressure/memory

const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const os = std.os;

pub const ProcEntry = struct {
    pid: os.pid_t,
    dir: fs.Dir,
    oom_score: u16 = undefined,
    oom_score_adj: i16 = undefined,
    exe: [os.PATH_MAX-1:0]u8 = undefined,
    vm_rss: u32 = undefined,

    pub fn init(pid: os.pid_t, parent_dir: fs.Dir) !ProcEntry {
        var pid_buf: [16]u8 = undefined;
        var pid_str = try fmt.bufPrint(&pid_buf, "{}", .{pid});
        
        var ret = ProcEntry{ .pid = pid, .dir = try parent_dir.openDir(pid_str, .{}) };

        var statm = try ret.slurpIntArray(u32, 3, "statm");
        ret.vm_rss = statm[1];
        ret.oom_score = try ret.slurpInt(u16, "oom_score");
        ret.oom_score_adj = try ret.slurpInt(i16,"oom_score_adj");
        
        const path = try ret.readLink(ret.exe[0..], "exe");
        ret.exe[path.len] = 0;
        
        return ret;
    }

    pub fn slurpString(self: *ProcEntry, buf: []u8, basename: []const u8) ![]u8 {
        var file = try self.dir.openFile(basename, .{});
        defer file.close();

        var reader = file.reader();
        var pos = try reader.readAll(buf);

        return buf[0..pos];
    }

    pub fn slurpIntArray(self: *ProcEntry, comptime T: type, comptime N: comptime_int, basename: []const u8) ![N]T {
        var tmp_buf: [24 * N]u8 = undefined;
        var index: usize = 0;
        var ret: [N]T = undefined;

        var slurped = try self.slurpString(tmp_buf[0..], basename);
        var slurped_it = std.mem.tokenize(u8, slurped, " \n\t");

        while (index < N) : (index += 1) {
            ret[index] = try std.fmt.parseInt(T, slurped_it.next().?, 10);
        }

        return ret;
    }

    pub fn slurpInt(self: *ProcEntry, comptime T: type, basename: []const u8) !T {
        // free trimming!
        return (try self.slurpIntArray(T, 1, basename))[0];
    }

    pub fn deinit(self: *ProcEntry) void {
        self.dir.close();
    }

    pub fn readLink(self: *ProcEntry, buf: []u8, basename: []const u8) ![]u8 {
        return self.dir.readLink(basename, buf);
    }
};

// Read /proc/pressure/memory.
pub const Pressure = struct { avg10: f32, avg60: f32, avg300: f32, total: u64 };

pub const MemoryPressure = struct {
    Some: Pressure,
    Full: Pressure,
};

// For this to work, reader must be at the beginning of a line.

pub fn readPressure(reader: anytype) !Pressure {
    // buffer for chars
    var tmp_buf: [32]u8 = undefined;

    // floats we'll initialize
    var press_floats: [3]f32 = undefined;
    var total: usize = 0;

    try reader.skipUntilDelimiterOrEof(' ');
    for (press_floats) |_, i| {
        try reader.skipUntilDelimiterOrEof('=');
        var float_str = try reader.readUntilDelimiter(&tmp_buf, ' ');
        press_floats[i] = try fmt.parseFloat(f32, float_str);
    }
    try reader.skipUntilDelimiterOrEof('=');
    var int_str = try reader.readUntilDelimiter(&tmp_buf, '\n');
    total = try fmt.parseUnsigned(u64, int_str, 10);

    return Pressure{ .avg10 = press_floats[0], .avg60 = press_floats[1], .avg300 = press_floats[2], .total = total };
}

pub fn getMemoryPressure() !MemoryPressure {
    var press_file = try fs.cwd().openFile("/proc/pressure/memory", .{});
    defer press_file.close();

    var reader = press_file.reader();

    var some = try readPressure(&reader);
    var full = try readPressure(&reader);

    return MemoryPressure{ .Some = some, .Full = full };
}
