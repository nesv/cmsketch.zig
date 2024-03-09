# cmsketch.zig

An implementation of the [count-min sketch][count-min-sketch] data structures.

## Estimator

An `Estimator` can be used to count the occurrences of different keys:

```zig
const testing = @import("std").testing;

test {
  var est = Estimator.init();
  try testing.expect(est.increment("foo", 1) == 1);
  try testing.expect(est.incrementBy("bar", 17) == 17);

  try testing.expect(est.get("foo") == 1);
  try testing.expect(est.get("bar") == 17);
}
```

## Rate

A `Rate` can be used to count the estimated occurrences of keys within a given
time interval.

```zig
const testing = @import("std").testing;

test {
  // Initialize a new Rate, with the given time interval in milliseconds.
  // Here, we are using a 1h interval.
  var rate = Rate.init(3600000);

  // You can observe the number of events for a given key.
  try testing.expect(rate.observe("foo", 70) == 70);
  try testing.expect(rate.observe("foo", 70) == 140);

  // ...after an hour, the time window for the observed events will
  // have elapsed, and the number of observations would be reset.
  try testing.expect(rate.get("foo") == 0);
}
```

## Shout-outs

The code in this package was ported from/inspired by [ryanfowler/limits][limits].

[count-min-sketch]: https://en.wikipedia.org/wiki/Count%E2%80%93min_sketch
[limits]: https://github.com/ryanfowler/limits
