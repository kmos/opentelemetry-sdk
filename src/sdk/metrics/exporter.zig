const std = @import("std");

const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const pbmetrics = @import("../../opentelemetry/proto/metrics/v1.pb.zig");
const pbcommon = @import("../../opentelemetry/proto/common/v1.pb.zig");
const spec = @import("../../api/metrics/spec.zig");

const MeterProvider = @import("../../api/metrics/meter.zig").MeterProvider;
const MetricReadError = @import("reader.zig").MetricReadError;
const MetricReader = @import("reader.zig").MetricReader;

const DataPoint = @import("../../api/metrics/measurement.zig").DataPoint;
const MeasurementsData = @import("../../api/metrics/measurement.zig").MeasurementsData;
const Measurements = @import("../../api/metrics/measurement.zig").Measurements;

const Attributes = @import("../../attributes.zig").Attributes;

pub const ExportResult = enum {
    Success,
    Failure,
};

pub const MetricExporter = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    exporter: *ExporterIface,

    // Lock helper to signal shutdown and/or export is in progress
    hasShutDown: bool = false,
    exportCompleted: std.Thread.Mutex = std.Thread.Mutex{},

    pub fn new(allocator: std.mem.Allocator, exporter: *ExporterIface) !*Self {
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = allocator,
            .exporter = exporter,
        };
        return s;
    }

    /// ExportBatch exports a batch of metrics data by calling the exporter implementation.
    /// The passed metrics data will be owned by the exporter implementation.
    pub fn exportBatch(self: *Self, metrics: []Measurements) ExportResult {
        if (@atomicLoad(bool, &self.hasShutDown, .acquire)) {
            // When shutdown has already been called, calling export should be a failure.
            // https://opentelemetry.io/docs/specs/otel/metrics/sdk/#shutdown-2
            return ExportResult.Failure;
        }
        // Acquire the lock to signal to forceFlush to wait for export to complete.
        self.exportCompleted.lock();
        defer self.exportCompleted.unlock();

        // Call the exporter function to process metrics data.
        self.exporter.exportBatch(metrics) catch |e| {
            std.debug.print("MetricExporter exportBatch failed: {?}\n", .{e});
            return ExportResult.Failure;
        };
        return ExportResult.Success;
    }

    // Ensure that all the data is flushed to the destination.
    pub fn forceFlush(self: *Self, timeout_ms: u64) !void {
        const start = std.time.milliTimestamp(); // Milliseconds
        const timeout: i64 = @intCast(timeout_ms);
        while (std.time.milliTimestamp() < start + timeout) {
            if (self.exportCompleted.tryLock()) {
                self.exportCompleted.unlock();
                return;
            } else {
                std.time.sleep(std.time.ns_per_ms);
            }
        }
        return MetricReadError.ForceFlushTimedOut;
    }

    pub fn shutdown(self: *Self) void {
        if (@atomicRmw(bool, &self.hasShutDown, .Xchg, true, .acq_rel)) {
            return;
        }
        self.allocator.destroy(self);
    }
};

// test harness to build a noop exporter.
// marked as pub only for testing purposes.
pub fn noopExporter(_: *ExporterIface, _: []Measurements) MetricReadError!void {
    return;
}
// mocked metric exporter to assert metrics data are read once exported.
fn mockExporter(_: *ExporterIface, metrics: []Measurements) MetricReadError!void {
    defer {
        for (metrics) |m| {
            var d = m;
            d.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(metrics);
    }
    if (metrics.len != 1) {
        std.debug.print("expectd just one metric, got {d}\n{any}\n", .{ metrics.len, metrics });
        return MetricReadError.ExportFailed;
    } // only one instrument from a single meter is expected in this mock
}

// test harness to build an exporter that times out.
fn waiterExporter(_: *ExporterIface, _: []Measurements) MetricReadError!void {
    // Sleep for 1 second to simulate a slow exporter.
    std.time.sleep(std.time.ns_per_ms * 1000);
    return;
}

test "metric exporter no-op" {
    var noop = ExporterIface{ .exportFn = noopExporter };
    var me = try MetricExporter.new(std.testing.allocator, &noop);
    defer me.shutdown();

    var measure = [1]DataPoint(i64){.{ .value = 42 }};
    const measurement: []DataPoint(i64) = measure[0..];
    var metrics = [1]Measurements{.{
        .meterName = "my-meter",
        .instrumentKind = .Counter,
        .instrumentOptions = .{ .name = "my-counter" },
        .data = .{ .int = measurement },
    }};

    const result = me.exportBatch(&metrics);
    try std.testing.expectEqual(ExportResult.Success, result);
}

test "metric exporter is called by metric reader" {
    var mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    var mock = ExporterIface{ .exportFn = mockExporter };

    var rdr = try MetricReader.init(std.testing.allocator, &mock);
    defer rdr.shutdown();

    try mp.addReader(rdr);

    const m = try mp.getMeter(.{ .name = "my-meter" });

    // only 1 metric should be in metrics data when we use the mock exporter
    var counter = try m.createCounter(u32, .{ .name = "my-counter" });
    try counter.add(1, .{});

    try rdr.collect();
}

test "metric exporter force flush succeeds" {
    var noop = ExporterIface{ .exportFn = noopExporter };
    var me = try MetricExporter.new(std.testing.allocator, &noop);
    defer me.shutdown();

    var measure = [1]DataPoint(i64){.{ .value = 42 }};
    const dataPoints: []DataPoint(i64) = measure[0..];
    var metrics = [1]Measurements{Measurements{
        .meterName = "my-meter",
        .instrumentKind = .Counter,
        .instrumentOptions = .{ .name = "my-counter" },
        .data = .{ .int = dataPoints },
    }};

    const result = me.exportBatch(&metrics);
    try std.testing.expectEqual(ExportResult.Success, result);

    try me.forceFlush(1000);
}

fn backgroundRunner(me: *MetricExporter, metrics: []Measurements) !void {
    _ = me.exportBatch(metrics);
}

test "metric exporter force flush fails" {
    var wait = ExporterIface{ .exportFn = waiterExporter };
    var me = try MetricExporter.new(std.testing.allocator, &wait);
    defer me.shutdown();

    var measure = [1]DataPoint(i64){.{ .value = 42 }};
    const dataPoints: []DataPoint(i64) = measure[0..];
    var metrics = [1]Measurements{Measurements{
        .meterName = "my-meter",
        .instrumentKind = .Counter,
        .instrumentOptions = .{ .name = "my-counter" },
        .data = .{ .int = dataPoints },
    }};

    var bg = try std.Thread.spawn(
        .{},
        backgroundRunner,
        .{ me, &metrics },
    );
    bg.join();

    const e = me.forceFlush(0);
    try std.testing.expectError(MetricReadError.ForceFlushTimedOut, e);
}

/// ExporterIface is the interface for exporting metrics.
/// Implementations can be satisfied by any type by having a member field of type
/// ExporterIface and a member function exportBatch with the correct signature.
pub const ExporterIface = struct {
    exportFn: *const fn (*ExporterIface, []Measurements) MetricReadError!void,

    /// ExportBatch defines the behavior that metric exporters will implement.
    /// Each metric exporter owns the metrics data passed to it.
    pub fn exportBatch(self: *ExporterIface, data: []Measurements) MetricReadError!void {
        return self.exportFn(self, data);
    }
};

/// InMemoryExporter stores in memory the metrics data to be exported.
/// The metics' representation in memory uses the types defined in the library.
pub const InMemoryExporter = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    data: std.ArrayListUnmanaged(Measurements) = undefined,
    // Implement the interface via @fieldParentPtr
    exporter: ExporterIface,

    mx: std.Thread.Mutex = std.Thread.Mutex{},

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = allocator,
            .data = .empty,
            .exporter = ExporterIface{
                .exportFn = exportBatch,
            },
        };
        return s;
    }
    pub fn deinit(self: *Self) void {
        self.mx.lock();
        for (self.data.items) |*d| {
            d.*.deinit(self.allocator);
        }
        self.data.deinit(self.allocator);
        self.mx.unlock();

        self.allocator.destroy(self);
    }

    // Implements the ExportIFace interface only method.
    fn exportBatch(iface: *ExporterIface, metrics: []Measurements) MetricReadError!void {
        // Get a pointer to the instance of the struct that implements the interface.
        const self: *Self = @fieldParentPtr("exporter", iface);
        self.mx.lock();
        defer self.mx.unlock();

        // Free up the allocated data points from the previous export.
        for (self.data.items) |*d| {
            d.*.deinit(self.allocator);
        }
        self.data.clearAndFree(self.allocator);
        self.data = std.ArrayListUnmanaged(Measurements).fromOwnedSlice(metrics);
    }

    /// Read the metrics from the in memory exporter.
    pub fn fetch(self: *Self) ![]Measurements {
        self.mx.lock();
        defer self.mx.unlock();
        return self.data.items;
    }
};

test "in memory exporter stores data" {
    const allocator = std.testing.allocator;

    var inMemExporter = try InMemoryExporter.init(allocator);
    defer inMemExporter.deinit();

    const exporter = try MetricExporter.new(allocator, &inMemExporter.exporter);
    defer exporter.shutdown();

    const val = @as(u64, 42);

    const counter_dp = try DataPoint(i64).new(allocator, 1, .{ "key", val });
    var counter_measures = try allocator.alloc(DataPoint(i64), 1);
    counter_measures[0] = counter_dp;

    const hist_dp = try DataPoint(f64).new(allocator, 2.0, .{ "key", val });
    var hist_measures = try allocator.alloc(DataPoint(f64), 1);
    hist_measures[0] = hist_dp;

    var underTest: std.ArrayListUnmanaged(Measurements) = .empty;

    try underTest.append(allocator, Measurements{
        .meterName = "first-meter",
        .meterAttributes = null,
        .instrumentKind = .Counter,
        .instrumentOptions = .{ .name = "counter-abc" },
        .data = .{ .int = counter_measures },
    });
    try underTest.append(allocator, Measurements{
        .meterName = "another-meter",
        .meterAttributes = null,
        .instrumentKind = .Histogram,
        .instrumentOptions = .{ .name = "histogram-abc" },
        .data = .{ .double = hist_measures },
    });

    const result = exporter.exportBatch(try underTest.toOwnedSlice(allocator));
    try std.testing.expect(result == .Success);

    const data = try inMemExporter.fetch();

    try std.testing.expect(data.len == 2);
    try std.testing.expectEqualDeep(counter_dp, data[0].data.int[0]);
}

const ReaderShared = struct {
    shuttingDown: bool = false,
    cond: std.Thread.Condition = .{},
    lock: std.Thread.Mutex = .{},
};

/// A periodic exporting reader is a specialization of MetricReader
/// that periodically exports metrics data to a destination.
/// The exporter configured in init() should be a push-based exporter.
/// See https://opentelemetry.io/docs/specs/otel/metrics/sdk/#periodic-exporting-metricreader
pub const PeriodicExportingReader = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    exportIntervalMillis: u64,
    exportTimeoutMillis: u64,

    shared: ReaderShared = .{},
    collectThread: std.Thread = undefined,

    // This reader will collect metrics data from the MeterProvider.
    reader: *MetricReader,

    // The intervals at which the reader should export metrics data
    // and wait for each operation to complete.
    // Default values are dicated by the OpenTelemetry specification.
    const defaultExportIntervalMillis: u64 = 60000;
    const defaultExportTimeoutMillis: u64 = 30000;

    pub fn init(
        allocator: std.mem.Allocator,
        mp: *MeterProvider,
        exporter: *ExporterIface,
        exportIntervalMs: ?u64,
        exportTimeoutMs: ?u64,
    ) !*Self {
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = allocator,
            .reader = try MetricReader.init(
                std.testing.allocator,
                exporter,
            ),
            .exportIntervalMillis = exportIntervalMs orelse defaultExportIntervalMillis,
            .exportTimeoutMillis = exportTimeoutMs orelse defaultExportTimeoutMillis,
        };
        try mp.addReader(s.reader);

        s.collectThread = try std.Thread.spawn(
            .{},
            collectAndExport,
            .{ s.reader, &s.shared, s.exportIntervalMillis, s.exportTimeoutMillis },
        );
        return s;
    }

    pub fn shutdown(self: *Self) void {
        self.shared.lock.lock();
        self.shared.shuttingDown = true;
        self.shared.lock.unlock();
        self.shared.cond.signal();
        self.collectThread.join();

        self.reader.shutdown();

        // Only when the background collector has stopped we can destroy.
        self.allocator.destroy(self);
    }
};

// Function that collects metrics from the reader and exports it to the destination.
// FIXME there is not a timeout for the collect operation.
fn collectAndExport(
    reader: *MetricReader,
    shared: *ReaderShared,
    exportIntervalMillis: u64,
    // TODO: add a timeout for the export operation
    _: u64,
) void {
    shared.lock.lock();
    defer shared.lock.unlock();
    // The execution should continue until the reader is shutting down
    while (!shared.shuttingDown) {
        if (reader.meterProvider) |_| {
            // This will also call exporter.exportBatch() every interval.
            reader.collect() catch |e| {
                std.debug.print("PeriodicExportingReader: collecting failed on reader: {?}\n", .{e});
            };
        } else {
            std.debug.print("PeriodicExportingReader: no meter provider is registered with this MetricReader {any}\n", .{reader});
        }

        shared.cond.timedWait(&shared.lock, exportIntervalMillis * std.time.ns_per_ms) catch continue;
    }
}

test "e2e periodic exporting metric reader" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const waiting: u64 = 100;

    var inMem = try InMemoryExporter.init(std.testing.allocator);
    defer inMem.deinit();

    var per = try PeriodicExportingReader.init(
        std.testing.allocator,
        mp,
        &inMem.exporter,
        waiting,
        null,
    );
    defer per.shutdown();

    var meter = try mp.getMeter(.{ .name = "test-reader" });
    var counter = try meter.createCounter(u64, .{
        .name = "requests",
        .description = "a test counter",
    });
    try counter.add(10, .{});

    var histogram = try meter.createHistogram(f64, .{
        .name = "latency",
        .description = "a test histogram",
        .histogramOpts = .{ .explicitBuckets = &.{
            1.0,
            10.0,
            100.0,
        } },
    });
    try histogram.record(1.4, .{});
    try histogram.record(10.4, .{});

    std.time.sleep(waiting * 4 * std.time.ns_per_ms);

    const data = try inMem.fetch();

    try std.testing.expect(data.len == 2);
    //TODO add more assertions
}
