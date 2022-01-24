const std = @import("std");
const log = std.log;
const os = std.os;
const process = std.process;

const l2 = @import("./missing_syscalls.zig");

const kill = @import("./killer.zig");
const Killer = kill.Killer;
const MemoryStats = kill.MemoryStats;

const proc = @import("./proc.zig");

fn usage(exit_code: u8) void {
    log.info("usage: boris [ -h ] [ -g ] [ -r Terminal RAM ] [ -s Terminal Swap ] [ -p Terminal PSI ] [ -u glob1|glob2 ]", .{});
    log.info("-r and -s accept percentages. -u is a pipe-separated list of glob patterns that will be avoided by the killer.", .{});
    os.exit(exit_code);
}

pub fn main() anyerror!void {
    // lock mempages
    if (l2.mlockall(l2.MCL.CURRENT | l2.MCL.FUTURE | l2.MCL.ONFAULT) catch null) |_| {
        log.info("Pages locked.", .{});
    } else {
        log.warn("Pages unlocked. Process might be susceptible to being sent to swap.", .{});
    }

    var terminal_ram: f64 = 15;
    var terminal_swap: f64 = 30;
    var terminal_psi: f32 = 10;
    var do_not_kill: []const u8 = "";
    var arg_it = process.ArgIterator.init();
    var dryrun = false;
    var pgroup = false;

    // skip program name. More args = options
    if (arg_it.skip()) {
        option_loop: while (arg_it.nextPosix()) |arg| {
            if (arg.len < 2 or arg[0] != '-') break;

            var opt_cluster = arg[1..];
            // options without optarg first
            while (opt_cluster.len > 0) {
                const opt = opt_cluster[0];
                switch (opt) {
                    '-' => {
                        if (std.mem.eql(u8, "-help", opt_cluster)) usage(0);
                        if (opt_cluster.len > 1) {
                            log.err("Long options are not supported.", .{});
                            usage(100);
                        }
                        break :option_loop;
                    },
                    'h' => {
                        usage(0);
                    },
                    'n' => {
                        dryrun = true;
                    },
                    'g' => {
                        pgroup = true;
                    },
                    // options with arguments, next block
                    'u', 'r', 'p', 's' => {
                        const optarg = if (opt_cluster.len > 1) opt_cluster[1..] else arg_it.nextPosix() orelse {
                            log.err("No argument provided for option -{c}.", .{opt});
                            usage(100);
                            return;
                        };
                        switch (opt) {
                            'u' => {
                                do_not_kill = optarg[0..];
                            },
                            'p' => {
                                terminal_psi = try std.fmt.parseFloat(f32, optarg);
                            },
                            'r' => {
                                terminal_ram = try std.fmt.parseFloat(f64, optarg);
                            },
                            's' => {
                                terminal_swap = try std.fmt.parseFloat(f64, optarg);
                            },
                            else => unreachable,
                        }
                        break;
                    },
                    else => {
                        log.err("Unrecognized option -{c}.", .{opt});
                        usage(100);
                    },
                }
                opt_cluster = opt_cluster[1..];
            }
        }
    }

    log.info("Avoiding killing {s}", .{do_not_kill});

    var k = Killer{
        // Killer Initals
        .timer = try std.time.Timer.start(),
        .terminal_ram_percent = terminal_ram,
        .terminal_swap_percent = terminal_swap,
        .terminal_psi = terminal_psi,
        .do_not_kill = do_not_kill,
        .kill_pgroup = pgroup,
    };

    if (dryrun) {
        try k.dryRun();
    } else {
        while (true) {
            const mem = MemoryStats.fromSysInfo(try l2.sysinfo());
            if (k.poll(mem)) {
                try k.trigger();
            }

            const slp = k.calculateSleepTime(mem);
            std.debug.print("Adaptive sleep: {}ms\n", .{slp});
            std.os.nanosleep(0, slp * 1000000 - 1);
        }
    }
}
