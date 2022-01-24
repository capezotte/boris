const std = @import("std");
const testing = std.testing;

// Probably broken version of Russ Cox's Simple Glob at https://research.swtch.com/glob
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    // Current position in the pattern
    var p_x: usize = 0;
    // Current position in the compared text
    var p_n: usize = 0;
    
    // If matching a wildcard fails, p_x and p_n will be reset to
    var next_p_x: usize = 0;
    var next_p_n: usize = 0;
    
    while (p_n < name.len or p_x < pattern.len) {    
        if (p_x < pattern.len) {
            const c = pattern[p_x];
            switch (c) {
                // Successful single character match
                '?' => {
                    if (p_n < name.len) {
                        p_x += 1;
                        p_n += 1;
                        continue;
                    }
                },
                // Wildcard moment
                '*' => {
                    // Set up restat. Attempt assume one more character is subsumed by the *
                    next_p_x = p_x;
                    next_p_n = p_n + 1;
                    p_x += 1;                
                    continue;
                },
                else => {
                    if (p_n < name.len and c == name[p_n]) {
                        p_n += 1;
                        p_x += 1;
                        continue;
                    }
                },
            }
        }

        // No match. Restart time.
        if (next_p_n > 0 and next_p_n <= name.len) {
            p_n = next_p_n;
            p_x = next_p_x;
            continue;
        }

        // No match and no hope of restarting. Failed.
        return false;
    }
    return true;
}

test {
    try testing.expect(globMatch("?", "xx") == false);
    try testing.expect(globMatch("???", "x") == false);
    try testing.expect(globMatch("??", "xx") == true);
    try testing.expect(globMatch("zig ???", "zig fmt") == true);
    try testing.expect(globMatch("*?", "xx") == true);
    try testing.expect(globMatch("*??*", "xx") == true);
    try testing.expect(globMatch("m*x", "mega man") == false);
    try testing.expect(globMatch("*sip*", "mississipi") == true);
    try testing.expect(globMatch("*si*si*si", "mississipi") == false);
}