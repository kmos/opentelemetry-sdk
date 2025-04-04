const std = @import("std");
const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const pbcommon = @import("../../opentelemetry/proto/common/v1.pb.zig");
const pbresource = @import("../../opentelemetry/proto/resource/v1.pb.zig");
const pbmetrics = @import("../../opentelemetry/proto/metrics/v1.pb.zig");
const pbutils = @import("../../pbutils.zig");
const instrument = @import("../../api/metrics/instrument.zig");
const Instrument = instrument.Instrument;
const Kind = instrument.Kind;
const MeterProvider = @import("../../api/metrics/meter.zig").MeterProvider;
const AggregatedMetrics = @import("../../api/metrics/meter.zig").AggregatedMetrics;

const Attribute = @import("../../attributes.zig").Attribute;
const Attributes = @import("../../attributes.zig").Attributes;
const Measurements = @import("../../api/metrics/measurement.zig").Measurements;
const MeasurementsData = @import("../../api/metrics/measurement.zig").MeasurementsData;

const view = @import("view.zig");
const TemporalitySelector = view.TemporalitySelector;
const AggregationSelector = view.AggregationSelector;

const exporter = @import("exporter.zig");
const MetricExporter = exporter.MetricExporter;
const ExporterIface = exporter.ExporterIface;
const ExportResult = exporter.ExportResult;
const InMemoryExporter = exporter.InMemoryExporter;

/// ExportError represents the failure to export data points
/// to a destination.
pub const MetricReadError = error{
    CollectFailedOnMissingMeterProvider,
    ExportFailed,
    ForceFlushTimedOut,
    ConcurrentCollectNotAllowed,
};

/// MetricReader reads metrics' data from a MeterProvider.
/// See https://opentelemetry.io/docs/specs/otel/metrics/sdk/#metricreader
pub const MetricReader = struct {
    allocator: std.mem.Allocator,
    // Exporter is the destination of the metrics data.
    // It takes ownership of the collected metrics.
    exporter: *MetricExporter = undefined,
    // We can read the instruments' data points from the meters
    // stored in meterProvider.
    meterProvider: ?*MeterProvider = null,

    temporality: TemporalitySelector = view.DefaultTemporalityFor,
    aggregation: AggregationSelector = view.DefaultAggregationFor,
    // Signal that shutdown has been called.
    hasShutDown: bool = false,
    mx: std.Thread.Mutex = std.Thread.Mutex{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, exporterImpl: *ExporterIface) !*Self {
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = allocator,
            .exporter = try MetricExporter.new(allocator, exporterImpl),
        };
        return s;
    }

    pub fn withTemporality(self: *Self, temporality: *const fn (Kind) view.Temporality) *Self {
        self.temporality = temporality;
        return self;
    }

    pub fn withAggregation(self: *Self, aggregation: *const fn (Kind) view.Aggregation) *Self {
        self.aggregation = aggregation;
        return self;
    }

    pub fn collect(self: *Self) !void {
        if (@atomicLoad(bool, &self.hasShutDown, .acquire)) {
            // When shutdown has already been called, collect is a no-op.
            return;
        }
        if (!self.mx.tryLock()) {
            return MetricReadError.ConcurrentCollectNotAllowed;
        }
        defer self.mx.unlock();
        var toBeExported = std.ArrayList(Measurements).init(self.allocator);
        defer toBeExported.deinit();

        if (self.meterProvider) |mp| {
            // Collect the data from each meter provider.
            // Measurements can be ported to protobuf structs during OTLP export.
            var meters = mp.meters.valueIterator();
            while (meters.next()) |meter| {
                const measurements: []Measurements = AggregatedMetrics.fetch(self.allocator, meter, self.aggregation) catch |err| {
                    std.debug.print("MetricReader: error aggregating data points from meter {s}: {?}", .{ meter.name, err });
                    continue;
                };
                // this makes a copy of the measurements to the array list
                try toBeExported.appendSlice(measurements);
                self.allocator.free(measurements);
            }

            //TODO: apply temporality before exporting, optionally keeping state in the reader.
            // When .Delta temporality is used, it will report the difference between the value
            // previsouly collected and the currently collected value.
            // This requires keeping state in the reader to store the previous value.

            // Export the metrics data through the exporter.
            // The exporter will own the metrics and should free it
            // by calling deinit() on the Measurements once done.
            // MetricExporter must be built with the same allocator as MetricReader
            // to ensure that the memory is managed correctly.
            const owned = try toBeExported.toOwnedSlice();
            switch (self.exporter.exportBatch(owned)) {
                ExportResult.Success => return,
                ExportResult.Failure => return MetricReadError.ExportFailed,
            }
        } else {
            // No meter provider to collect from.
            return MetricReadError.CollectFailedOnMissingMeterProvider;
        }
    }

    pub fn shutdown(self: *Self) void {
        @atomicStore(bool, &self.hasShutDown, true, .release);
        self.collect() catch |e| {
            std.debug.print("MetricReader shutdown: error while collecting metrics: {?}\n", .{e});
        };
        self.exporter.shutdown();
        self.allocator.destroy(self);
    }
};

test "metric reader shutdown prevents collect() to execute" {
    var noop = exporter.ExporterIface{ .exportFn = exporter.noopExporter };
    var reader = try MetricReader.init(std.testing.allocator, &noop);
    const e = reader.collect();
    try std.testing.expectEqual(MetricReadError.CollectFailedOnMissingMeterProvider, e);
    reader.shutdown();
}

test "metric reader collects data from meter provider" {
    var mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    var inMem = try InMemoryExporter.init(std.testing.allocator);
    defer inMem.deinit();

    var reader = try MetricReader.init(std.testing.allocator, &inMem.exporter);
    defer reader.shutdown();

    try mp.addReader(reader);

    const m = try mp.getMeter(.{ .name = "my-meter" });

    var counter = try m.createCounter(u32, .{ .name = "my-counter" });
    try counter.add(1, .{});

    var hist = try m.createHistogram(u16, .{ .name = "my-histogram" });
    const v: []const u8 = "success";

    try hist.record(10, .{ "amazing", v });

    var histFloat = try m.createHistogram(f64, .{ .name = "my-histogram-float" });
    try histFloat.record(10.0, .{ "wonderful", v });

    try reader.collect();

    _ = try inMem.fetch();
}

fn deltaTemporality(_: Kind) view.Temporality {
    return view.Temporality.Delta;
}

test "metric reader custom temporality" {
    var mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    var inMem = try InMemoryExporter.init(std.testing.allocator);
    defer inMem.deinit();

    var reader = try MetricReader.init(std.testing.allocator, &inMem.exporter);
    reader = reader.withTemporality(deltaTemporality);

    defer reader.shutdown();

    try mp.addReader(reader);

    const m = try mp.getMeter(.{ .name = "my-meter" });

    var counter = try m.createCounter(u32, .{ .name = "my-counter" });
    try counter.add(1, .{});

    try reader.collect();

    const data = try inMem.fetch();

    std.debug.assert(data.len == 1);
}
