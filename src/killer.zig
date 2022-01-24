const std = @import("std");
const math = std.math;
const log = std.log;
const fs = std.fs;
const os = std.os;
const proc = @import("./proc.zig");
const match = @import("./glob.zig").globMatch;
const l2 = @import("./missing_syscalls.zig");

// Constants obtained from RF Jakob's earlyoom.
const ram_fill_rate = 6000;
const swap_fill_rate = 800;

// Statistics about memory, in MB.
pub const MemoryStats = struct {
    free_ram: f64,
    free_swap: f64,
    total_ram: f64,
    total_swap: f64,
    free_ram_percent: f64,
    free_swap_percent: f64,

    pub fn fromSysInfo(sysinf: l2.SysInfo) MemoryStats {
        const free_ram = @intToFloat(f64, (sysinf.freeram * @bitCast(c_uint, sysinf.mem_unit)) / (math.pow(u32, 1024, 2)));
        const free_swap = @intToFloat(f64, (sysinf.freeswap * @bitCast(c_uint, sysinf.mem_unit)) / (math.pow(u32, 1024, 2)));
        const total_ram = @intToFloat(f64, (sysinf.totalram * @bitCast(c_uint, sysinf.mem_unit)) / (math.pow(u32, 1024, 2)));
        const total_swap = @intToFloat(f64, (sysinf.totalswap * @bitCast(c_uint, sysinf.mem_unit)) / (math.pow(u32, 1024, 2)));
        return MemoryStats{
            // above
            .free_ram = free_ram,
            .free_swap = free_swap,
            .total_ram = total_ram,
            .total_swap = total_swap,
            // percents
            .free_ram_percent = 100 * free_ram / total_ram,
            .free_swap_percent = 100 * free_swap / total_swap,
        };
    }
};

pub const VictimQueryError = error{ CantReadProc, ProcNotFound };

pub const Killer = struct {
    timer: std.time.Timer,
    terminal_ram_percent: f64,
    terminal_swap_percent: f64,
    terminal_psi: f32,
    do_not_kill: []const u8,
    kill_pgroup: bool,

    // Based on RF Jakob's earlyoom (https://github.com/rfjakob/earlyoom/blob/dea92ae67997fcb1a0664489c13d49d09d472d40/main.c#L365)
    pub fn calculateSleepTime(self: *Killer, mem: MemoryStats) u64 {
        // How much space left until limits are reached (in KiB)
        const ram_headroom_kib = math.max(0, (mem.free_ram_percent - self.terminal_ram_percent) * 10 * mem.total_ram);
        const swap_headroom_kib = math.max(0, (mem.free_swap_percent - self.terminal_swap_percent) * 10 * mem.total_swap);

        // Using those constants, how much we can sleep without missing am OOM
        const time_to_fill = math.min(ram_headroom_kib / ram_fill_rate, swap_headroom_kib / swap_fill_rate);

        return @floatToInt(u64, math.clamp(time_to_fill, 100, 1000));
    }

    pub fn poll(self: *Killer, mem: MemoryStats) bool {
        var i = proc.getMemoryPressure() catch return true;
        return (i.Some.avg10 > self.terminal_psi) and (mem.free_ram_percent < self.terminal_ram_percent);
    }

    pub fn queryVictim(self: *Killer) VictimQueryError!proc.ProcEntry {
        log.info("Querying for victims after {}s.", .{self.timer.lap() / 1000000000});

        // Reopen /proc and iterate on its contents
        var proc_dir = fs.cwd().openDir("/proc", .{ .iterate = true }) catch return error.CantReadProc;
        defer proc_dir.close();
        var proc_it = proc_dir.iterate();

        // Initialize stats monitoring
        var cur_proc: ?proc.ProcEntry = null;

        loop_proc: while (proc_it.next() catch return error.CantReadProc) |proc_entry| {
            if (proc_entry.kind != .Directory) continue;

            // non pid folders can be ignore
            const pid = std.fmt.parseInt(os.pid_t, proc_entry.name, 10) catch continue;

            var this_proc = proc.ProcEntry.init(pid, proc_dir) catch |err| switch (err) {
                error.AccessDenied => {
                    log.warn("Skipping PID {} since it belongs to another user.", .{pid});
                    continue;
                }, // root process we can't kill
                error.FileNotFound => {
                    log.warn("Skipping PID {} (died while were scanning /proc).", .{pid});
                    continue;
                }, // Process died halfway on event loop.
                else => return error.CantReadProc,
            };
            defer this_proc.deinit();

            // The kernel wouldn't kill them either
            if (this_proc.oom_score_adj == -1000) continue;

            var do_not_kill_it = std.mem.tokenize(u8, self.do_not_kill, "|");
            while (do_not_kill_it.next()) |pat| {
                if (match(pat, this_proc.exe[0..])) {
                    log.warn("Skipping PID {} {s} due it matching {s}", .{ this_proc.pid, this_proc.exe, pat });
                    continue :loop_proc;
                }
            }

            if (cur_proc) |previous| {
                if (this_proc.oom_score < previous.oom_score) continue; // less evil
                if (this_proc.vm_rss < previous.vm_rss) continue; // eats less ram
            }

            cur_proc = this_proc;
        }

        if (cur_proc == null) return error.ProcNotFound;
        
        // Found a victim.
        return cur_proc.?;
    }

    pub fn trigger(self: *Killer) !void {
        // Start gentle.
        var cur_proc = try self.queryVictim();

        const pid = if (self.kill_pgroup) -cur_proc.pid else cur_proc.pid;

        try os.kill(pid, os.SIG.TERM);
        log.info("Sent SIGTERM to PID {} (exe: {s} | oom_score {}) in {}ns", .{
            cur_proc.pid,
            cur_proc.exe,
            cur_proc.oom_score,
            self.timer.lap(),
        });

        // sleep for 0.5s
        os.nanosleep(0, 500000000);
        
        // error = killed with success, return
        const new_oom = cur_proc.slurpInt(u16, "oom_score") catch return;
        if (new_oom + 200 < cur_proc.oom_score ) {
            log.info("OOM score dropped from {} to {} (delta > 200), not escalating to SIGKILL.", .{ new_oom, cur_proc.oom_score });
            return;
        }
            
        try os.kill(pid, os.SIG.KILL);
        log.info("Escalated to SIGKILL after {}ns.", .{ self.timer.lap() });
    }

    pub fn dryRun(self: *Killer) VictimQueryError!void {
        const cur_proc = try self.queryVictim();

        log.info("Simulated victim: PID {} (exe {s} | oom_score {}). Spotted in {}s", .{
            cur_proc.pid,
            cur_proc.exe,
            cur_proc.oom_score,
            self.timer.lap(),
        });
    }

};
