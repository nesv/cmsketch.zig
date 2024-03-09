const std = @import("std");
const assert = std.debug.assert;
const maxInt = std.math.maxInt;
const XxHash64 = std.hash.XxHash64;
const testing = std.testing;

/// Estimator is a [count-min sketch](https://en.wikipedia.org/wiki/Count%E2%80%93min_sketch) data structure.
/// It is lock-free, and safe to use from multiple threads.
pub const Estimator = struct {
    seeds: [4]u64,
    slots: [4][8192]i64,

    /// Initialize a new `Estimator`.
    pub fn init() Estimator {
        return .{
            .seeds = [4]u64{
                std.Random.int(std.crypto.random, u64),
                std.Random.int(std.crypto.random, u64),
                std.Random.int(std.crypto.random, u64),
                std.Random.int(std.crypto.random, u64),
            },
            .slots = [4][8192]i64{
                [_]i64{0} ** 8192,
                [_]i64{0} ** 8192,
                [_]i64{0} ** 8192,
                [_]i64{0} ** 8192,
            },
        };
    }

    /// Get the estimated count for `key`.
    pub fn get(self: Estimator, key: []const u8) i64 {
        var min: i64 = maxInt(i64);
        for (self.slots, 0..) |slot, i| {
            const hash = XxHash64.hash(self.seeds[i], key);
            const idx = hash % 8192;
            const count = @atomicLoad(i64, &slot[idx], .Monotonic);
            min = @min(min, count);
        }
        return min;
    }

    /// Increment `key` by 1 (one), and return the new, estimated total count.
    pub fn increment(self: *Estimator, key: []const u8) i64 {
        return self.incrementBy(key, 1);
    }

    /// Increment the count of `key` by the specified number, and return the
    /// new, estimated total count. Keys can be decremented by providing a
    /// negative number.
    pub fn incrementBy(self: *Estimator, key: []const u8, by: i64) i64 {
        var min: i64 = maxInt(i64);
        for (&self.slots, 0..) |*slot, i| {
            const hash = XxHash64.hash(self.seeds[i], key);
            const idx = hash % 8192;
            const count = @atomicRmw(i64, @constCast(&slot[idx]), .Add, by, .Monotonic) + by;
            min = @min(min, count);
        }
        return min;
    }

    /// Reset all estimated counts to zero.
    pub fn reset(self: *Estimator) void {
        self.slots = [4][8192]i64{
            [_]i64{0} ** 8192,
            [_]i64{0} ** 8192,
            [_]i64{0} ** 8192,
            [_]i64{0} ** 8192,
        };
    }
};

test Estimator {
    var est = Estimator.init();
    try testing.expectEqual(0, est.get("foo"));

    try testing.expectEqual(1, est.increment("foo"));
    try testing.expectEqual(1, est.get("foo"));

    try testing.expectEqual(5, est.incrementBy("foo", 4));
    try testing.expectEqual(5, est.get("foo"));

    est.reset();
    for (est.slots) |slot| {
        for (slot) |v| {
            try testing.expect(v == 0);
        }
    }
}

/// Rate is a probabilistic rate estimator, over a given time interval.
pub const Rate = struct {
    red: Estimator,
    blue: Estimator,
    is_red: bool,
    start: i64, // Start timestamp in milliseconds, since the epoch
    reset_interval_ms: i64,
    last_reset: i64, // Milliseconds since the epoch

    /// Initialize a new `Rate` with the given reset `interval` in milliseconds.
    /// The `interval` must be greater than 0 (zero).
    pub fn init(interval: i64) Rate {
        assert(interval > 0);
        const now = std.time.milliTimestamp();
        return Rate{
            .red = Estimator.init(),
            .blue = Estimator.init(),
            .is_red = false,
            .start = now,
            .reset_interval_ms = interval,
            .last_reset = now,
        };
    }

    /// Get the total estimated number of observed events for `key`, within the
    /// last reset interval.
    pub fn get(self: *Rate, key: []const u8) i64 {
        const elapsed = self.maybeReset();
        if (elapsed >= 2 * self.reset_interval_ms) return 0;
        if (@atomicLoad(bool, &self.is_red, .Monotonic)) return self.red.get(key);
        return self.blue.get(key);
    }

    /// Observe `n` events for the given `key`, and return the total, estimated
    /// number of events in the current interval.
    pub fn observe(self: *Rate, key: []const u8, n: i64) i64 {
        _ = self.maybeReset();
        if (@atomicLoad(bool, &self.is_red, .Monotonic)) return self.red.incrementBy(key, n);
        return self.blue.incrementBy(key, n);
    }

    fn maybeReset(self: *Rate) i64 {
        const last_reset = @atomicLoad(i64, &self.last_reset, .Monotonic);
        const ms_since_start = std.time.milliTimestamp() - @atomicLoad(i64, &self.start, .Monotonic);
        const elapsed = last_reset - ms_since_start;

        if (elapsed < self.reset_interval_ms) return elapsed;

        if (compareAndSwap(i64, &self.last_reset, last_reset, ms_since_start)) {
            const is_red = @atomicLoad(bool, &self.is_red, .Acquire);
            if (is_red) {
                self.red.reset();
            } else {
                self.blue.reset();
            }
            @atomicStore(bool, &self.is_red, !is_red, .Release);

            // Reset the other estimator as well, if our current time is
            // greater than two reset intervals.
            if (elapsed >= 2 * self.reset_interval_ms) {
                if (is_red) {
                    self.blue.reset();
                } else {
                    self.red.reset();
                }
            }
        }

        return elapsed;
    }
};

test Rate {
    var rate = Rate.init(100);
    try testing.expectEqual(100, rate.observe("foo", 100));
    try testing.expectEqual(0, rate.get("bar"));
}

/// Perform an atomic compare and swap.
/// If the value at `ptr` is equal to `old`, replace it with `new`.
/// Returns a boolean value indicating whether or not the value was swapped.
fn compareAndSwap(comptime T: type, ptr: *T, old: T, new: T) bool {
    const value = @atomicLoad(T, ptr, .Acquire);
    if (value != old) {
        @atomicStore(T, ptr, value, .Release);
        return false;
    }

    @atomicStore(T, ptr, new, .Release);
    return true;
}

test compareAndSwap {
    var v: usize = 53;
    try testing.expect(compareAndSwap(usize, &v, 53, 12));
    try testing.expect(!compareAndSwap(usize, &v, 53, 12));
    try testing.expect(compareAndSwap(usize, &v, 12, 42));
}
