const std = @import("std");
const shinydb = @import("shinydb_zig_client");
const ShinyDbClient = shinydb.ShinyDbClient;
const Query = shinydb.Query;
const yql = shinydb.yql;

// ─── Minimal inline BSON parser (avoids build dependency conflicts) ─────────

const BsonType = enum(u8) {
    double = 0x01,
    string = 0x02,
    document = 0x03,
    array = 0x04,
    binary = 0x05,
    object_id = 0x07,
    boolean = 0x08,
    datetime = 0x09,
    null_type = 0x0A,
    regex = 0x0B,
    int32 = 0x10,
    timestamp = 0x11,
    int64 = 0x12,
    _,
};

const BsonFieldValue = union(enum) {
    double: f64,
    int32: i32,
    int64: i64,
    string: []const u8,
    not_found,
};

/// Read a C-string (null-terminated) starting at pos, advance pos past the null
fn readCString(data: []const u8, pos: *usize) []const u8 {
    const start = pos.*;
    while (pos.* < data.len and data[pos.*] != 0) : (pos.* += 1) {}
    const s = data[start..pos.*];
    if (pos.* < data.len) pos.* += 1; // skip null terminator
    return s;
}

/// Skip a BSON value of the given type, advancing pos
fn skipBsonValue(data: []const u8, tag: u8, pos: *usize) void {
    const t: BsonType = @enumFromInt(tag);
    switch (t) {
        .double => pos.* += 8,
        .string => {
            if (pos.* + 4 > data.len) return;
            const slen = std.mem.readInt(i32, data[pos.*..][0..4], .little);
            pos.* += 4 + @as(usize, @intCast(slen));
        },
        .document, .array => {
            if (pos.* + 4 > data.len) return;
            const dlen = std.mem.readInt(i32, data[pos.*..][0..4], .little);
            pos.* += @as(usize, @intCast(dlen));
        },
        .binary => {
            if (pos.* + 4 > data.len) return;
            const blen = std.mem.readInt(i32, data[pos.*..][0..4], .little);
            pos.* += 4 + 1 + @as(usize, @intCast(blen)); // size + subtype + data
        },
        .object_id => pos.* += 12,
        .boolean => pos.* += 1,
        .datetime => pos.* += 8,
        .null_type => {},
        .regex => {
            // two C-strings
            while (pos.* < data.len and data[pos.*] != 0) : (pos.* += 1) {}
            if (pos.* < data.len) pos.* += 1;
            while (pos.* < data.len and data[pos.*] != 0) : (pos.* += 1) {}
            if (pos.* < data.len) pos.* += 1;
        },
        .int32 => pos.* += 4,
        .timestamp => pos.* += 8,
        .int64 => pos.* += 8,
        _ => {},
    }
}

/// Get a named field from a BSON document (data starts at doc beginning)
fn bsonGetField(data: []const u8, field_name: []const u8) BsonFieldValue {
    if (data.len < 5) return .not_found;
    const doc_size = std.mem.readInt(i32, data[0..4], .little);
    const doc_end = @as(usize, @intCast(doc_size));
    var pos: usize = 4;

    while (pos < doc_end -| 1 and pos < data.len) {
        const tag = data[pos];
        if (tag == 0) break;
        pos += 1;
        const name = readCString(data, &pos);

        if (std.mem.eql(u8, name, field_name)) {
            const t: BsonType = @enumFromInt(tag);
            return switch (t) {
                .double => blk: {
                    if (pos + 8 > data.len) break :blk .not_found;
                    const bits = std.mem.readInt(u64, data[pos..][0..8], .little);
                    break :blk .{ .double = @bitCast(bits) };
                },
                .int32 => blk: {
                    if (pos + 4 > data.len) break :blk .not_found;
                    break :blk .{ .int32 = std.mem.readInt(i32, data[pos..][0..4], .little) };
                },
                .int64 => blk: {
                    if (pos + 8 > data.len) break :blk .not_found;
                    break :blk .{ .int64 = std.mem.readInt(i64, data[pos..][0..8], .little) };
                },
                .string => blk: {
                    if (pos + 4 > data.len) break :blk .not_found;
                    const slen = std.mem.readInt(i32, data[pos..][0..4], .little);
                    const str_start = pos + 4;
                    const str_len = @as(usize, @intCast(slen)) -| 1; // minus null
                    if (str_start + str_len > data.len) break :blk .not_found;
                    break :blk .{ .string = data[str_start .. str_start + str_len] };
                },
                else => .not_found,
            };
        } else {
            skipBsonValue(data, tag, &pos);
        }
    }
    return .not_found;
}

/// Get the raw bytes of a sub-document or array field within a BSON document
fn bsonGetSubDoc(data: []const u8, field_name: []const u8) ?[]const u8 {
    if (data.len < 5) return null;
    const doc_size = std.mem.readInt(i32, data[0..4], .little);
    const doc_end = @as(usize, @intCast(doc_size));
    var pos: usize = 4;

    while (pos < doc_end -| 1 and pos < data.len) {
        const tag = data[pos];
        if (tag == 0) break;
        pos += 1;
        const name = readCString(data, &pos);

        if (std.mem.eql(u8, name, field_name)) {
            const t: BsonType = @enumFromInt(tag);
            switch (t) {
                .document, .array => {
                    if (pos + 4 > data.len) return null;
                    const sub_size = std.mem.readInt(i32, data[pos..][0..4], .little);
                    if (sub_size < 5 or pos + @as(usize, @intCast(sub_size)) > data.len) return null;
                    return data[pos .. pos + @as(usize, @intCast(sub_size))];
                },
                else => return null,
            }
        } else {
            skipBsonValue(data, tag, &pos);
        }
    }
    return null;
}

/// Navigate aggregation response: root -> groups[0] -> values -> field
/// Server format: { "groups": [{"key": ..., "values": {field: value}}], "total_groups": N }
fn getAggFieldFromResponse(data: []const u8, field_name: []const u8) BsonFieldValue {
    const groups = bsonGetSubDoc(data, "groups") orelse return .not_found;
    const group0 = bsonGetSubDoc(groups, "0") orelse return .not_found;
    const values = bsonGetSubDoc(group0, "values") orelse return .not_found;
    return bsonGetField(values, field_name);
}

/// Get total_groups count from aggregation response
fn getGroupCountFromResponse(data: []const u8) !usize {
    const val = bsonGetField(data, "total_groups");
    return switch (val) {
        .int32 => |v| @as(usize, @intCast(v)),
        .int64 => |v| @as(usize, @intCast(v)),
        else => error.FieldNotFound,
    };
}

/// Get a named field from the Nth BSON document in concatenated data
fn bsonGetFieldFromNth(data: []const u8, n: usize, field_name: []const u8) BsonFieldValue {
    var pos: usize = 0;
    var idx: usize = 0;
    while (pos + 4 <= data.len) {
        const doc_size = std.mem.readInt(i32, data[pos..][0..4], .little);
        if (doc_size < 5 or pos + @as(usize, @intCast(doc_size)) > data.len) break;
        if (idx == n) {
            return bsonGetField(data[pos .. pos + @as(usize, @intCast(doc_size))], field_name);
        }
        pos += @as(usize, @intCast(doc_size));
        idx += 1;
    }
    return .not_found;
}

// ─── Test Infrastructure ────────────────────────────────────────────────────

const TestResult = struct {
    id: []const u8,
    query: []const u8,
    passed: bool,
    detail: []const u8,
};

var pass_count: usize = 0;
var fail_count: usize = 0;
var results: std.ArrayList(TestResult) = undefined;
var test_allocator: std.mem.Allocator = undefined;

fn reportPass(id: []const u8, query: []const u8) void {
    pass_count += 1;
    std.debug.print("  \x1b[92mPASS\x1b[0m {s}: {s}\n", .{ id, query });
}

fn reportFail(id: []const u8, query: []const u8, detail: []const u8) void {
    fail_count += 1;
    std.debug.print("  \x1b[91mFAIL\x1b[0m {s}: {s}\n", .{ id, query });
    std.debug.print("       {s}\n", .{detail});
}

// ─── YQL Helper: mirrors shinydb-shell executeQuery ─────────────────────────

fn executeYql(allocator: std.mem.Allocator, client: *ShinyDbClient, input: []const u8) !QueryResponse {
    var query_ast = try yql.parse(allocator, input);
    defer query_ast.deinit();

    const space_name = query_ast.space orelse return error.NoSpaceSpecified;
    const store_name = query_ast.store orelse return error.NoStoreSpecified;

    var query = Query.init(client);
    defer query.deinit();

    _ = query.space(space_name).store(store_name);

    for (query_ast.filters.items, 0..) |filter, i| {
        if (i == 0) {
            _ = query.where(filter.field, filter.op, filter.value);
        } else {
            const prev_logic = query_ast.filters.items[i - 1].logic;
            if (prev_logic == .@"or") {
                _ = query.@"or"(filter.field, filter.op, filter.value);
            } else {
                _ = query.@"and"(filter.field, filter.op, filter.value);
            }
        }
    }

    if (query_ast.limit_val) |lim| _ = query.limit(lim);
    if (query_ast.skip_val) |sk| _ = query.skip(sk);
    if (query_ast.order_by) |ob| _ = query.orderBy(ob.field, ob.direction);

    if (query_ast.group_by) |gb| {
        for (gb.items) |field| _ = query.groupBy(field);
    }

    if (query_ast.aggregations) |aggs| {
        for (aggs.items) |agg| {
            switch (agg.func) {
                .count => _ = query.count(agg.name),
                .sum => if (agg.field) |f| {
                    _ = query.sum(agg.name, f);
                },
                .avg => if (agg.field) |f| {
                    _ = query.avg(agg.name, f);
                },
                .min => if (agg.field) |f| {
                    _ = query.min(agg.name, f);
                },
                .max => if (agg.field) |f| {
                    _ = query.max(agg.name, f);
                },
            }
        }
    }

    if (query_ast.query_type == .count) _ = query.countOnly();

    const response = try query.run();
    return response;
}

const QueryResponse = shinydb.QueryResponse;

// ─── Response Parsers ───────────────────────────────────────────────────────

fn getCountFromResponse(data: []const u8) !i64 {
    const val = bsonGetField(data, "count");
    return switch (val) {
        .int32 => |v| @as(i64, @intCast(v)),
        .int64 => |v| v,
        .double => |v| @as(i64, @intFromFloat(v)),
        else => error.CountNotFound,
    };
}

fn countBsonDocs(data: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (pos + 4 <= data.len) {
        const doc_size = std.mem.readInt(i32, data[pos..][0..4], .little);
        if (doc_size < 5 or pos + @as(usize, @intCast(doc_size)) > data.len) break;
        pos += @as(usize, @intCast(doc_size));
        count += 1;
    }
    return count;
}

fn getDoubleFromDoc(data: []const u8, field: []const u8) !f64 {
    const val = bsonGetField(data, field);
    return switch (val) {
        .double => |v| v,
        .int32 => |v| @as(f64, @floatFromInt(v)),
        .int64 => |v| @as(f64, @floatFromInt(v)),
        else => error.FieldNotFound,
    };
}

fn getIntFromDoc(data: []const u8, field: []const u8) !i64 {
    const val = bsonGetField(data, field);
    return switch (val) {
        .int32 => |v| @as(i64, @intCast(v)),
        .int64 => |v| v,
        .double => |v| @as(i64, @intFromFloat(v)),
        else => error.FieldNotFound,
    };
}

fn floatEq(a: f64, b: f64, tolerance: f64) bool {
    if (a == b) return true;
    const diff = @abs(a - b);
    if (diff <= tolerance) return true;
    const max_val = @max(@abs(a), @abs(b));
    if (max_val == 0) return true;
    return diff / max_val <= 0.0001;
}

// ─── Count Test (Categories 1, 3, 4, 5 - .count() queries) ─────────────────

fn testCount(allocator: std.mem.Allocator, client: *ShinyDbClient, id: []const u8, yql_text: []const u8, expected: i64) void {
    var response = executeYql(allocator, client, yql_text) catch |err| {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "Query failed: {}", .{err}) catch "Query failed";
        reportFail(id, yql_text, detail);
        return;
    };
    defer response.deinit();

    const data = response.data orelse {
        reportFail(id, yql_text, "No data in response");
        return;
    };

    const actual = getCountFromResponse(data) catch |err| {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "Parse error: {}", .{err}) catch "Parse error";
        reportFail(id, yql_text, detail);
        return;
    };

    if (actual == expected) {
        reportPass(id, yql_text);
    } else {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "expected={d}, got={d}", .{ expected, actual }) catch "mismatch";
        reportFail(id, yql_text, detail);
    }
}

// ─── Doc Count Test (Category 2 - filter queries, check doc count) ──────────

fn testDocCount(allocator: std.mem.Allocator, client: *ShinyDbClient, id: []const u8, yql_text: []const u8, expected: usize) void {
    var response = executeYql(allocator, client, yql_text) catch |err| {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "Query failed: {}", .{err}) catch "Query failed";
        reportFail(id, yql_text, detail);
        return;
    };
    defer response.deinit();

    const data = response.data orelse {
        if (expected == 0) {
            reportPass(id, yql_text);
        } else {
            reportFail(id, yql_text, "No data in response");
        }
        return;
    };

    const actual = getCountFromResponse(data) catch blk: {
        break :blk @as(i64, @intCast(countBsonDocs(data)));
    };

    if (actual == @as(i64, @intCast(expected))) {
        reportPass(id, yql_text);
    } else {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "expected={d} docs, got={d}", .{ expected, actual }) catch "mismatch";
        reportFail(id, yql_text, detail);
    }
}

// ─── OrderBy Test (Category 6) ─────────────────────────────────────────────

fn testOrderInt(allocator: std.mem.Allocator, client: *ShinyDbClient, id: []const u8, yql_text: []const u8, field: []const u8, expected_values: []const i64) void {
    var response = executeYql(allocator, client, yql_text) catch |err| {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "Query failed: {}", .{err}) catch "Query failed";
        reportFail(id, yql_text, detail);
        return;
    };
    defer response.deinit();

    const data = response.data orelse {
        reportFail(id, yql_text, "No data in response");
        return;
    };

    const num_docs = countBsonDocs(data);
    var ok = true;
    for (expected_values, 0..) |exp, i| {
        const val = bsonGetFieldFromNth(data, i, field);
        const actual: i64 = switch (val) {
            .int32 => |v| @as(i64, @intCast(v)),
            .int64 => |v| v,
            else => blk: {
                ok = false;
                var buf: [256]u8 = undefined;
                const detail = std.fmt.bufPrint(&buf, "Doc[{d}] field '{s}' not found (type={s}), {d} docs total", .{ i, field, @tagName(val), num_docs }) catch "field not found";
                reportFail(id, yql_text, detail);
                break :blk @as(i64, 0);
            },
        };
        if (!ok) return;
        if (actual != exp) {
            ok = false;
            var buf: [256]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "Doc[{d}] {s}: expected={d}, got={d}", .{ i, field, exp, actual }) catch "mismatch";
            reportFail(id, yql_text, detail);
            return;
        }
    }

    if (ok) {
        reportPass(id, yql_text);
    }
}

fn testOrderFloat(allocator: std.mem.Allocator, client: *ShinyDbClient, id: []const u8, yql_text: []const u8, field: []const u8, expected_values: []const f64) void {
    var response = executeYql(allocator, client, yql_text) catch |err| {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "Query failed: {}", .{err}) catch "Query failed";
        reportFail(id, yql_text, detail);
        return;
    };
    defer response.deinit();

    const data = response.data orelse {
        reportFail(id, yql_text, "No data in response");
        return;
    };

    const num_docs = countBsonDocs(data);
    var ok = true;
    for (expected_values, 0..) |exp, i| {
        const val = bsonGetFieldFromNth(data, i, field);
        const actual: f64 = switch (val) {
            .double => |v| v,
            .int32 => |v| @as(f64, @floatFromInt(v)),
            .int64 => |v| @as(f64, @floatFromInt(v)),
            else => blk: {
                ok = false;
                var buf: [256]u8 = undefined;
                const detail = std.fmt.bufPrint(&buf, "Doc[{d}] field '{s}' not found (type={s}), {d} docs total", .{ i, field, @tagName(val), num_docs }) catch "field not found";
                reportFail(id, yql_text, detail);
                break :blk 0.0;
            },
        };
        if (!ok) return;
        if (!floatEq(actual, exp, 0.01)) {
            ok = false;
            var buf: [256]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "Doc[{d}] {s}: expected={d:.4}, got={d:.4}", .{ i, field, exp, actual }) catch "mismatch";
            reportFail(id, yql_text, detail);
            return;
        }
    }

    if (ok) {
        reportPass(id, yql_text);
    }
}

// ─── Aggregate Test (Categories 7, 8) ──────────────────────────────────────

fn testAggInt(allocator: std.mem.Allocator, client: *ShinyDbClient, id: []const u8, yql_text: []const u8, field: []const u8, expected: i64) void {
    var response = executeYql(allocator, client, yql_text) catch |err| {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "Query failed: {}", .{err}) catch "Query failed";
        reportFail(id, yql_text, detail);
        return;
    };
    defer response.deinit();

    const data = response.data orelse {
        reportFail(id, yql_text, "No data in response");
        return;
    };

    const val = getAggFieldFromResponse(data, field);
    const actual: i64 = switch (val) {
        .int32 => |v| @as(i64, @intCast(v)),
        .int64 => |v| v,
        .double => |v| @as(i64, @intFromFloat(v)),
        else => {
            var buf: [256]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "Parse agg field '{s}' not found in groups[0].values", .{field}) catch "Parse error";
            reportFail(id, yql_text, detail);
            return;
        },
    };

    if (actual == expected) {
        reportPass(id, yql_text);
    } else {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "{s}: expected={d}, got={d}", .{ field, expected, actual }) catch "mismatch";
        reportFail(id, yql_text, detail);
    }
}

fn testAggFloat(allocator: std.mem.Allocator, client: *ShinyDbClient, id: []const u8, yql_text: []const u8, field: []const u8, expected: f64) void {
    var response = executeYql(allocator, client, yql_text) catch |err| {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "Query failed: {}", .{err}) catch "Query failed";
        reportFail(id, yql_text, detail);
        return;
    };
    defer response.deinit();

    const data = response.data orelse {
        reportFail(id, yql_text, "No data in response");
        return;
    };

    const val = getAggFieldFromResponse(data, field);
    const actual: f64 = switch (val) {
        .double => |v| v,
        .int32 => |v| @as(f64, @floatFromInt(v)),
        .int64 => |v| @as(f64, @floatFromInt(v)),
        else => {
            var buf: [256]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "Parse agg field '{s}' not found in groups[0].values", .{field}) catch "Parse error";
            reportFail(id, yql_text, detail);
            return;
        },
    };

    if (floatEq(actual, expected, 0.01)) {
        reportPass(id, yql_text);
    } else {
        var buf: [512]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "{s}: expected={d:.4}, got={d:.4}", .{ field, expected, actual }) catch "mismatch";
        reportFail(id, yql_text, detail);
    }
}

// ─── GroupBy Test (Categories 9, 10) ───────────────────────────────────────

fn testGroupCount(allocator: std.mem.Allocator, client: *ShinyDbClient, id: []const u8, yql_text: []const u8, expected_groups: usize) void {
    var response = executeYql(allocator, client, yql_text) catch |err| {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "Query failed: {}", .{err}) catch "Query failed";
        reportFail(id, yql_text, detail);
        return;
    };
    defer response.deinit();

    const data = response.data orelse {
        reportFail(id, yql_text, "No data in response");
        return;
    };

    const actual_groups = getGroupCountFromResponse(data) catch {
        reportFail(id, yql_text, "Could not read total_groups");
        return;
    };
    if (actual_groups == expected_groups) {
        reportPass(id, yql_text);
    } else {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "expected {d} groups, got {d}", .{ expected_groups, actual_groups }) catch "mismatch";
        reportFail(id, yql_text, detail);
    }
}

// ─── Builder Tests (Categories 11–20, mirror YQL tests) ────────────────────

fn testBuilderCount(client: *ShinyDbClient, id: []const u8, desc: []const u8, build_fn: *const fn (client: *ShinyDbClient) QueryBuildResult, expected: i64) void {
    const build_result = build_fn(client);
    var query = build_result.query;

    var response = query.run() catch |err| {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "Query failed: {}", .{err}) catch "Query failed";
        reportFail(id, desc, detail);
        query.deinit();
        return;
    };
    defer response.deinit();
    query.deinit();

    const data = response.data orelse {
        reportFail(id, desc, "No data in response");
        return;
    };

    const actual = getCountFromResponse(data) catch {
        reportFail(id, desc, "Parse count error");
        return;
    };

    if (actual == expected) {
        reportPass(id, desc);
    } else {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "expected={d}, got={d}", .{ expected, actual }) catch "mismatch";
        reportFail(id, desc, detail);
    }
}

const QueryBuildResult = struct {
    query: Query,
};

fn testBuilderAggInt(client: *ShinyDbClient, id: []const u8, desc: []const u8, build_fn: *const fn (client: *ShinyDbClient) QueryBuildResult, field: []const u8, expected: i64) void {
    const build_result = build_fn(client);
    var query = build_result.query;

    var response = query.run() catch |err| {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "Query failed: {}", .{err}) catch "Query failed";
        reportFail(id, desc, detail);
        query.deinit();
        return;
    };
    defer response.deinit();
    query.deinit();

    const data = response.data orelse {
        reportFail(id, desc, "No data in response");
        return;
    };

    const val = getAggFieldFromResponse(data, field);
    const actual: i64 = switch (val) {
        .int32 => |v| @as(i64, @intCast(v)),
        .int64 => |v| v,
        .double => |v| @as(i64, @intFromFloat(v)),
        else => {
            reportFail(id, desc, "Parse agg field error");
            return;
        },
    };

    if (actual == expected) {
        reportPass(id, desc);
    } else {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "{s}: expected={d}, got={d}", .{ field, expected, actual }) catch "mismatch";
        reportFail(id, desc, detail);
    }
}

fn testBuilderAggFloat(client: *ShinyDbClient, id: []const u8, desc: []const u8, build_fn: *const fn (client: *ShinyDbClient) QueryBuildResult, field: []const u8, expected: f64) void {
    const build_result = build_fn(client);
    var query = build_result.query;

    var response = query.run() catch |err| {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "Query failed: {}", .{err}) catch "Query failed";
        reportFail(id, desc, detail);
        query.deinit();
        return;
    };
    defer response.deinit();
    query.deinit();

    const data = response.data orelse {
        reportFail(id, desc, "No data in response");
        return;
    };

    const val = getAggFieldFromResponse(data, field);
    const actual: f64 = switch (val) {
        .double => |v| v,
        .int32 => |v| @as(f64, @floatFromInt(v)),
        .int64 => |v| @as(f64, @floatFromInt(v)),
        else => {
            reportFail(id, desc, "Parse agg field error");
            return;
        },
    };

    if (floatEq(actual, expected, 0.01)) {
        reportPass(id, desc);
    } else {
        var buf: [512]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "{s}: expected={d:.4}, got={d:.4}", .{ field, expected, actual }) catch "mismatch";
        reportFail(id, desc, detail);
    }
}

fn testBuilderGroupCount(client: *ShinyDbClient, id: []const u8, desc: []const u8, build_fn: *const fn (client: *ShinyDbClient) QueryBuildResult, expected_groups: usize) void {
    const build_result = build_fn(client);
    var query = build_result.query;

    var response = query.run() catch |err| {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "Query failed: {}", .{err}) catch "Query failed";
        reportFail(id, desc, detail);
        query.deinit();
        return;
    };
    defer response.deinit();
    query.deinit();

    const data = response.data orelse {
        reportFail(id, desc, "No data in response");
        return;
    };

    const actual_groups = getGroupCountFromResponse(data) catch {
        reportFail(id, desc, "Could not read total_groups");
        return;
    };
    if (actual_groups == expected_groups) {
        reportPass(id, desc);
    } else {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "expected {d} groups, got {d}", .{ expected_groups, actual_groups }) catch "mismatch";
        reportFail(id, desc, detail);
    }
}

fn testBuilderDocCount(client: *ShinyDbClient, id: []const u8, desc: []const u8, build_fn: *const fn (client: *ShinyDbClient) QueryBuildResult, expected: usize) void {
    const build_result = build_fn(client);
    var query = build_result.query;

    var response = query.run() catch |err| {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "Query failed: {}", .{err}) catch "Query failed";
        reportFail(id, desc, detail);
        query.deinit();
        return;
    };
    defer response.deinit();
    query.deinit();

    const data = response.data orelse {
        if (expected == 0) {
            reportPass(id, desc);
        } else {
            reportFail(id, desc, "No data in response");
        }
        return;
    };

    const actual = countBsonDocs(data);
    if (actual == expected) {
        reportPass(id, desc);
    } else {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "expected {d} docs, got {d}", .{ expected, actual }) catch "mismatch";
        reportFail(id, desc, detail);
    }
}

fn testBuilderOrderInt(client: *ShinyDbClient, id: []const u8, desc: []const u8, build_fn: *const fn (client: *ShinyDbClient) QueryBuildResult, field: []const u8, expected_values: []const i64) void {
    const build_result = build_fn(client);
    var query = build_result.query;

    var response = query.run() catch |err| {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "Query failed: {}", .{err}) catch "Query failed";
        reportFail(id, desc, detail);
        query.deinit();
        return;
    };
    defer response.deinit();
    query.deinit();

    const data = response.data orelse {
        reportFail(id, desc, "No data in response");
        return;
    };

    const num_docs = countBsonDocs(data);
    var ok = true;
    for (expected_values, 0..) |exp, i| {
        const val = bsonGetFieldFromNth(data, i, field);
        const actual: i64 = switch (val) {
            .int32 => |v| @as(i64, @intCast(v)),
            .int64 => |v| v,
            else => blk: {
                ok = false;
                var buf: [256]u8 = undefined;
                const detail = std.fmt.bufPrint(&buf, "Doc[{d}] field '{s}' not found (type={s}), {d} docs total", .{ i, field, @tagName(val), num_docs }) catch "field not found";
                reportFail(id, desc, detail);
                break :blk @as(i64, 0);
            },
        };
        if (!ok) return;
        if (actual != exp) {
            ok = false;
            var buf: [256]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "Doc[{d}] {s}: expected={d}, got={d}", .{ i, field, exp, actual }) catch "mismatch";
            reportFail(id, desc, detail);
            return;
        }
    }

    if (ok) {
        reportPass(id, desc);
    }
}

fn testBuilderOrderFloat(client: *ShinyDbClient, id: []const u8, desc: []const u8, build_fn: *const fn (client: *ShinyDbClient) QueryBuildResult, field: []const u8, expected_values: []const f64) void {
    const build_result = build_fn(client);
    var query = build_result.query;

    var response = query.run() catch |err| {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "Query failed: {}", .{err}) catch "Query failed";
        reportFail(id, desc, detail);
        query.deinit();
        return;
    };
    defer response.deinit();
    query.deinit();

    const data = response.data orelse {
        reportFail(id, desc, "No data in response");
        return;
    };

    const num_docs = countBsonDocs(data);
    var ok = true;
    for (expected_values, 0..) |exp, i| {
        const val = bsonGetFieldFromNth(data, i, field);
        const actual: f64 = switch (val) {
            .double => |v| v,
            .int32 => |v| @as(f64, @floatFromInt(v)),
            .int64 => |v| @as(f64, @floatFromInt(v)),
            else => blk: {
                ok = false;
                var buf: [256]u8 = undefined;
                const detail = std.fmt.bufPrint(&buf, "Doc[{d}] field '{s}' not found (type={s}), {d} docs total", .{ i, field, @tagName(val), num_docs }) catch "field not found";
                reportFail(id, desc, detail);
                break :blk 0.0;
            },
        };
        if (!ok) return;
        if (!floatEq(actual, exp, 0.01)) {
            ok = false;
            var buf: [256]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "Doc[{d}] {s}: expected={d:.4}, got={d:.4}", .{ i, field, exp, actual }) catch "mismatch";
            reportFail(id, desc, detail);
            return;
        }
    }

    if (ok) {
        reportPass(id, desc);
    }
}

// ─── Builder Query Constructors (Categories 11–20) ─────────────────────────

// 11.x — Count queries
fn b11_1(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").countOnly();
    return .{ .query = q };
}
fn b11_2(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("customers").countOnly();
    return .{ .query = q };
}
fn b11_3(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("employees").countOnly();
    return .{ .query = q };
}
fn b11_4(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("EmployeeID", .eq, .{ .int = 289 }).countOnly();
    return .{ .query = q };
}
fn b11_5(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("EmployeeID", .eq, .{ .int = 288 }).countOnly();
    return .{ .query = q };
}
fn b11_6(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("vendors").where("ActiveFlag", .eq, .{ .int = 1 }).countOnly();
    return .{ .query = q };
}
fn b11_7(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").where("MakeFlag", .eq, .{ .int = 1 }).countOnly();
    return .{ .query = q };
}
fn b11_8(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("CustomerID", .eq, .{ .int = 1045 }).countOnly();
    return .{ .query = q };
}

// 12.x — Filter equality (doc count via counting response BSON docs)
fn b12_1(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("employees").where("Gender", .eq, .{ .string = "M" });
    return .{ .query = q };
}
fn b12_2(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("employees").where("Gender", .eq, .{ .string = "F" });
    return .{ .query = q };
}
fn b12_3(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("employees").where("EmployeeID", .eq, .{ .int = 274 });
    return .{ .query = q };
}
fn b12_4(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").where("SubCategoryID", .eq, .{ .int = 14 });
    return .{ .query = q };
}
fn b12_5(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("productcategories").where("CategoryName", .eq, .{ .string = "Bikes" });
    return .{ .query = q };
}

// 13.x — Filter comparison (count)
fn b13_1(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("TotalDue", .gt, .{ .float = 50000 }).countOnly();
    return .{ .query = q };
}
fn b13_2(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("TotalDue", .lt, .{ .float = 100 }).countOnly();
    return .{ .query = q };
}
fn b13_3(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("TotalDue", .gte, .{ .float = 100000 }).countOnly();
    return .{ .query = q };
}
fn b13_4(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").where("ListPrice", .gt, .{ .float = 1000 }).countOnly();
    return .{ .query = q };
}
fn b13_5(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").where("ListPrice", .lte, .{ .float = 0 }).countOnly();
    return .{ .query = q };
}
fn b13_6(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("vendors").where("CreditRating", .gt, .{ .int = 3 }).countOnly();
    return .{ .query = q };
}
fn b13_7(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("vendors").where("CreditRating", .ne, .{ .int = 1 }).countOnly();
    return .{ .query = q };
}
fn b13_8(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("EmployeeID", .gte, .{ .int = 285 }).@"and"("EmployeeID", .lte, .{ .int = 287 }).countOnly();
    return .{ .query = q };
}

// 14.x — Compound filters (count)
fn b14_1(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("EmployeeID", .eq, .{ .int = 289 }).@"and"("CustomerID", .eq, .{ .int = 1045 }).countOnly();
    return .{ .query = q };
}
fn b14_2(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("employees").where("Gender", .eq, .{ .string = "M" }).@"and"("MaritalStatus", .eq, .{ .string = "M" }).countOnly();
    return .{ .query = q };
}
fn b14_3(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("employees").where("Gender", .eq, .{ .string = "M" }).@"and"("MaritalStatus", .eq, .{ .string = "S" }).countOnly();
    return .{ .query = q };
}

// 15.x — Limit & Skip (count)
fn b15_1(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").limit(10).countOnly();
    return .{ .query = q };
}
fn b15_2(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").limit(5).countOnly();
    return .{ .query = q };
}
fn b15_3(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").skip(3800).countOnly();
    return .{ .query = q };
}
fn b15_4(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("customers").limit(100).countOnly();
    return .{ .query = q };
}

// 16.x — OrderBy
fn b16_1(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").orderBy("ListPrice", .desc).limit(5);
    return .{ .query = q };
}
fn b16_2(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").orderBy("ListPrice", .asc).limit(5);
    return .{ .query = q };
}
fn b16_3(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("employees").orderBy("EmployeeID", .asc).limit(3);
    return .{ .query = q };
}
fn b16_4(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("employees").orderBy("EmployeeID", .desc).limit(3);
    return .{ .query = q };
}

// 17.x — Aggregation count
fn b17_1(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").count("total");
    return .{ .query = q };
}
fn b17_2(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("EmployeeID", .eq, .{ .int = 289 }).count("total");
    return .{ .query = q };
}
fn b17_3(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("customers").count("total");
    return .{ .query = q };
}
fn b17_4(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").where("MakeFlag", .eq, .{ .int = 1 }).count("n");
    return .{ .query = q };
}

// 18.x — Aggregation sum/avg/min/max
fn b18_1(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").sum("total", "TotalDue");
    return .{ .query = q };
}
fn b18_2(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").avg("avg_total", "TotalDue");
    return .{ .query = q };
}
fn b18_3(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").min("min_total", "TotalDue");
    return .{ .query = q };
}
fn b18_4(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").max("max_total", "TotalDue");
    return .{ .query = q };
}
fn b18_5(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("EmployeeID", .eq, .{ .int = 289 }).sum("revenue", "TotalDue");
    return .{ .query = q };
}
fn b18_6_avg(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").avg("avg_price", "ListPrice");
    return .{ .query = q };
}
fn b18_6_max(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").max("max_price", "ListPrice");
    return .{ .query = q };
}
fn b18_6_min(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").min("min_price", "ListPrice");
    return .{ .query = q };
}

// 19.x — GroupBy
fn b19_1(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").groupBy("EmployeeID").count("n");
    return .{ .query = q };
}
fn b19_2(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("employees").groupBy("Gender").count("n");
    return .{ .query = q };
}
fn b19_3(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("employees").groupBy("Gender").groupBy("MaritalStatus").count("n");
    return .{ .query = q };
}
fn b19_4(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").groupBy("EmployeeID").count("n").sum("total", "TotalDue");
    return .{ .query = q };
}
fn b19_5(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("vendors").groupBy("CreditRating").count("n");
    return .{ .query = q };
}
fn b19_6(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("EmployeeID", .eq, .{ .int = 289 }).groupBy("CustomerID").count("n").sum("total", "TotalDue");
    return .{ .query = q };
}

// 20.x — Filter + GroupBy
fn b20_1(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("TotalDue", .gt, .{ .float = 10000 }).groupBy("EmployeeID").count("n");
    return .{ .query = q };
}
fn b20_2(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").where("ListPrice", .gt, .{ .float = 0 }).groupBy("SubCategoryID").count("n").avg("avg_price", "ListPrice");
    return .{ .query = q };
}

// ─── Main ──────────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    test_allocator = allocator;

    // Connect to server (same pattern as sales_demo.zig)
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client = try ShinyDbClient.init(allocator, io);
    defer client.deinit();

    std.debug.print("Connecting to shinydb at 127.0.0.1:23469...\n", .{});
    try client.connect("127.0.0.1", 23469);
    std.debug.print("Connected!\n\n", .{});

    pass_count = 0;
    fail_count = 0;

    // ════════════════════════════════════════════════════════════════
    // YQL Text Tests (Categories 1–10, 50 tests)
    // ════════════════════════════════════════════════════════════════
    std.debug.print("═══ YQL Text Tests ═══\n\n", .{});

    // ── Category 1: Count ──
    std.debug.print("── Category 1: Count ──\n", .{});
    testCount(allocator, client, "1.1", "sales.orders.count()", 3806);
    testCount(allocator, client, "1.2", "sales.customers.count()", 635);
    testCount(allocator, client, "1.3", "sales.employees.count()", 17);
    testCount(allocator, client, "1.4", "sales.orders.filter(EmployeeID = 289).count()", 348);
    testCount(allocator, client, "1.5", "sales.orders.filter(EmployeeID = 288).count()", 130);
    testCount(allocator, client, "1.6", "sales.vendors.filter(ActiveFlag = 1).count()", 100);
    testCount(allocator, client, "1.7", "sales.products.filter(MakeFlag = 1).count()", 212);
    testCount(allocator, client, "1.8", "sales.orders.filter(CustomerID = 1045).count()", 12);

    // ── Category 2: Filter equality (doc count) ──
    // Use .count() on YQL for consistency (these return count, not raw docs)
    std.debug.print("── Category 2: Filter Equality ──\n", .{});
    testDocCount(allocator, client, "2.1", "sales.employees.filter(Gender = \"M\").count()", 10);
    testDocCount(allocator, client, "2.2", "sales.employees.filter(Gender = \"F\").count()", 7);
    testDocCount(allocator, client, "2.3", "sales.employees.filter(EmployeeID = 274).count()", 1);
    testDocCount(allocator, client, "2.4", "sales.products.filter(SubCategoryID = 14).count()", 33);
    testDocCount(allocator, client, "2.5",
        \\sales.productcategories.filter(CategoryName = "Bikes").count()
    , 1);

    // ── Category 3: Filter comparison ──
    std.debug.print("── Category 3: Filter Comparison ──\n", .{});
    testCount(allocator, client, "3.1", "sales.orders.filter(TotalDue > 50000).count()", 621);
    testCount(allocator, client, "3.2", "sales.orders.filter(TotalDue < 100).count()", 155);
    testCount(allocator, client, "3.3", "sales.orders.filter(TotalDue >= 100000).count()", 108);
    testCount(allocator, client, "3.4", "sales.products.filter(ListPrice > 1000).count()", 86);
    testCount(allocator, client, "3.5", "sales.products.filter(ListPrice <= 0).count()", 0);
    testCount(allocator, client, "3.6", "sales.vendors.filter(CreditRating > 3).count()", 4);
    testCount(allocator, client, "3.7", "sales.vendors.filter(CreditRating != 1).count()", 20);
    testCount(allocator, client, "3.8", "sales.orders.filter(EmployeeID >= 285 and EmployeeID <= 287).count()", 164);

    // ── Category 4: Compound filters ──
    std.debug.print("── Category 4: Compound Filters ──\n", .{});
    testCount(allocator, client, "4.1", "sales.orders.filter(EmployeeID = 289 and CustomerID = 1045).count()", 0);
    testCount(allocator, client, "4.2",
        \\sales.employees.filter(Gender = "M" and MaritalStatus = "M").count()
    , 7);
    testCount(allocator, client, "4.3",
        \\sales.employees.filter(Gender = "M" and MaritalStatus = "S").count()
    , 3);

    // ── Category 5: Limit & Skip ──
    std.debug.print("── Category 5: Limit & Skip ──\n", .{});
    testCount(allocator, client, "5.1", "sales.orders.limit(10).count()", 10);
    testCount(allocator, client, "5.2", "sales.orders.limit(5).count()", 5);
    testCount(allocator, client, "5.3", "sales.orders.skip(3800).count()", 6);
    testCount(allocator, client, "5.4", "sales.customers.limit(100).count()", 100);

    // ── Category 6: OrderBy ──
    std.debug.print("── Category 6: OrderBy ──\n", .{});
    testOrderFloat(allocator, client, "6.1", "sales.products.orderBy(ListPrice, desc).limit(5)", "ListPrice", &[_]f64{ 3578.27, 3578.27, 3578.27, 3578.27, 3578.27 });
    testOrderFloat(allocator, client, "6.2", "sales.products.orderBy(ListPrice, asc).limit(5)", "ListPrice", &[_]f64{ 2.29, 3.99, 4.99, 4.99, 4.99 });
    testOrderInt(allocator, client, "6.3", "sales.employees.orderBy(EmployeeID, asc).limit(3)", "EmployeeID", &[_]i64{ 274, 275, 276 });
    testOrderInt(allocator, client, "6.4", "sales.employees.orderBy(EmployeeID, desc).limit(3)", "EmployeeID", &[_]i64{ 290, 289, 288 });

    // ── Category 7: Aggregation Count ──
    std.debug.print("── Category 7: Aggregation Count ──\n", .{});
    testAggInt(allocator, client, "7.1", "sales.orders.aggregate(total: count)", "total", 3806);
    testAggInt(allocator, client, "7.2", "sales.orders.filter(EmployeeID = 289).aggregate(total: count)", "total", 348);
    testAggInt(allocator, client, "7.3", "sales.customers.aggregate(total: count)", "total", 635);
    testAggInt(allocator, client, "7.4", "sales.products.filter(MakeFlag = 1).aggregate(n: count)", "n", 212);

    // ── Category 8: Aggregation Sum/Avg/Min/Max ──
    std.debug.print("── Category 8: Aggregation Sum/Avg/Min/Max ──\n", .{});
    testAggFloat(allocator, client, "8.1", "sales.orders.aggregate(total: sum(TotalDue))", "total", 90775446.9931);
    testAggFloat(allocator, client, "8.2", "sales.orders.aggregate(avg_total: avg(TotalDue))", "avg_total", 23850.6167);
    testAggFloat(allocator, client, "8.3", "sales.orders.aggregate(min_total: min(TotalDue))", "min_total", 1.5183);
    testAggFloat(allocator, client, "8.4", "sales.orders.aggregate(max_total: max(TotalDue))", "max_total", 187487.825);
    testAggFloat(allocator, client, "8.5", "sales.orders.filter(EmployeeID = 289).aggregate(revenue: sum(TotalDue))", "revenue", 9585124.9477);
    testAggFloat(allocator, client, "8.6a", "sales.products.aggregate(avg_price: avg(ListPrice))", "avg_price", 744.5952);
    testAggFloat(allocator, client, "8.6b", "sales.products.aggregate(max_price: max(ListPrice))", "max_price", 3578.27);
    testAggFloat(allocator, client, "8.6c", "sales.products.aggregate(min_price: min(ListPrice))", "min_price", 2.29);

    // ── Category 9: GroupBy ──
    std.debug.print("── Category 9: GroupBy ──\n", .{});
    testGroupCount(allocator, client, "9.1", "sales.orders.groupBy(EmployeeID).aggregate(n: count)", 17);
    testGroupCount(allocator, client, "9.2", "sales.employees.groupBy(Gender).aggregate(n: count)", 2);
    testGroupCount(allocator, client, "9.3", "sales.employees.groupBy(Gender, MaritalStatus).aggregate(n: count)", 4);
    testGroupCount(allocator, client, "9.4", "sales.orders.groupBy(EmployeeID).aggregate(n: count, total: sum(TotalDue))", 17);
    testGroupCount(allocator, client, "9.5", "sales.vendors.groupBy(CreditRating).aggregate(n: count)", 5);
    testGroupCount(allocator, client, "9.6", "sales.orders.filter(EmployeeID = 289).groupBy(CustomerID).aggregate(n: count, total: sum(TotalDue))", 62);

    // ── Category 10: Filter + GroupBy ──
    std.debug.print("── Category 10: Filter + GroupBy ──\n", .{});
    testGroupCount(allocator, client, "10.1", "sales.orders.filter(TotalDue > 10000).groupBy(EmployeeID).aggregate(n: count)", 17);
    testGroupCount(allocator, client, "10.2", "sales.products.filter(ListPrice > 0).groupBy(SubCategoryID).aggregate(n: count, avg_price: avg(ListPrice))", 37);

    const yql_pass = pass_count;
    const yql_fail = fail_count;

    // ════════════════════════════════════════════════════════════════
    // Builder API Tests (Categories 11–20, 50 tests)
    // ════════════════════════════════════════════════════════════════
    std.debug.print("\n═══ Builder API Tests ═══\n\n", .{});

    // Reset counters for builder section (track separately)
    const builder_start_pass = pass_count;
    const builder_start_fail = fail_count;

    // ── Category 11: Builder Count ──
    std.debug.print("── Category 11: Builder Count ──\n", .{});
    testBuilderCount(client, "11.1", "orders.countOnly()", &b11_1, 3806);
    testBuilderCount(client, "11.2", "customers.countOnly()", &b11_2, 635);
    testBuilderCount(client, "11.3", "employees.countOnly()", &b11_3, 17);
    testBuilderCount(client, "11.4", "orders.where(EmpID=289).countOnly()", &b11_4, 348);
    testBuilderCount(client, "11.5", "orders.where(EmpID=288).countOnly()", &b11_5, 130);
    testBuilderCount(client, "11.6", "vendors.where(ActiveFlag=1).countOnly()", &b11_6, 100);
    testBuilderCount(client, "11.7", "products.where(MakeFlag=1).countOnly()", &b11_7, 212);
    testBuilderCount(client, "11.8", "orders.where(CustID=1045).countOnly()", &b11_8, 12);

    // ── Category 12: Builder Filter Equality (doc count) ──
    std.debug.print("── Category 12: Builder Filter Equality ──\n", .{});
    testBuilderDocCount(client, "12.1", "employees.where(Gender=M)", &b12_1, 10);
    testBuilderDocCount(client, "12.2", "employees.where(Gender=F)", &b12_2, 7);
    testBuilderDocCount(client, "12.3", "employees.where(EmpID=274)", &b12_3, 1);
    testBuilderDocCount(client, "12.4", "products.where(SubCatID=14)", &b12_4, 33);
    testBuilderDocCount(client, "12.5", "prodcats.where(CatName=Bikes)", &b12_5, 1);

    // ── Category 13: Builder Filter Comparison ──
    std.debug.print("── Category 13: Builder Filter Comparison ──\n", .{});
    testBuilderCount(client, "13.1", "orders.where(TotalDue>50000).countOnly()", &b13_1, 621);
    testBuilderCount(client, "13.2", "orders.where(TotalDue<100).countOnly()", &b13_2, 155);
    testBuilderCount(client, "13.3", "orders.where(TotalDue>=100000).countOnly()", &b13_3, 108);
    testBuilderCount(client, "13.4", "products.where(ListPrice>1000).countOnly()", &b13_4, 86);
    testBuilderCount(client, "13.5", "products.where(ListPrice<=0).countOnly()", &b13_5, 0);
    testBuilderCount(client, "13.6", "vendors.where(CreditRating>3).countOnly()", &b13_6, 4);
    testBuilderCount(client, "13.7", "vendors.where(CreditRating!=1).countOnly()", &b13_7, 20);
    testBuilderCount(client, "13.8", "orders.where(EmpID>=285,<=287).countOnly()", &b13_8, 164);

    // ── Category 14: Builder Compound Filters ──
    std.debug.print("── Category 14: Builder Compound Filters ──\n", .{});
    testBuilderCount(client, "14.1", "orders.where(EmpID=289).and(CustID=1045).countOnly()", &b14_1, 0);
    testBuilderCount(client, "14.2", "employees.where(Gender=M).and(Marital=M).countOnly()", &b14_2, 7);
    testBuilderCount(client, "14.3", "employees.where(Gender=M).and(Marital=S).countOnly()", &b14_3, 3);

    // ── Category 15: Builder Limit & Skip ──
    std.debug.print("── Category 15: Builder Limit & Skip ──\n", .{});
    testBuilderCount(client, "15.1", "orders.limit(10).countOnly()", &b15_1, 10);
    testBuilderCount(client, "15.2", "orders.limit(5).countOnly()", &b15_2, 5);
    testBuilderCount(client, "15.3", "orders.skip(3800).countOnly()", &b15_3, 6);
    testBuilderCount(client, "15.4", "customers.limit(100).countOnly()", &b15_4, 100);

    // ── Category 16: Builder OrderBy ──
    std.debug.print("── Category 16: Builder OrderBy ──\n", .{});
    testBuilderOrderFloat(client, "16.1", "products.orderBy(ListPrice,desc).limit(5)", &b16_1, "ListPrice", &[_]f64{ 3578.27, 3578.27, 3578.27, 3578.27, 3578.27 });
    testBuilderOrderFloat(client, "16.2", "products.orderBy(ListPrice,asc).limit(5)", &b16_2, "ListPrice", &[_]f64{ 2.29, 3.99, 4.99, 4.99, 4.99 });
    testBuilderOrderInt(client, "16.3", "employees.orderBy(EmpID,asc).limit(3)", &b16_3, "EmployeeID", &[_]i64{ 274, 275, 276 });
    testBuilderOrderInt(client, "16.4", "employees.orderBy(EmpID,desc).limit(3)", &b16_4, "EmployeeID", &[_]i64{ 290, 289, 288 });

    // ── Category 17: Builder Aggregation Count ──
    std.debug.print("── Category 17: Builder Aggregation Count ──\n", .{});
    testBuilderAggInt(client, "17.1", "orders.count(total)", &b17_1, "total", 3806);
    testBuilderAggInt(client, "17.2", "orders.where(EmpID=289).count(total)", &b17_2, "total", 348);
    testBuilderAggInt(client, "17.3", "customers.count(total)", &b17_3, "total", 635);
    testBuilderAggInt(client, "17.4", "products.where(MakeFlag=1).count(n)", &b17_4, "n", 212);

    // ── Category 18: Builder Aggregation Sum/Avg/Min/Max ──
    std.debug.print("── Category 18: Builder Aggregation Sum/Avg/Min/Max ──\n", .{});
    testBuilderAggFloat(client, "18.1", "orders.sum(total,TotalDue)", &b18_1, "total", 90775446.9931);
    testBuilderAggFloat(client, "18.2", "orders.avg(avg_total,TotalDue)", &b18_2, "avg_total", 23850.6167);
    testBuilderAggFloat(client, "18.3", "orders.min(min_total,TotalDue)", &b18_3, "min_total", 1.5183);
    testBuilderAggFloat(client, "18.4", "orders.max(max_total,TotalDue)", &b18_4, "max_total", 187487.825);
    testBuilderAggFloat(client, "18.5", "orders.where(EmpID=289).sum(revenue,TotalDue)", &b18_5, "revenue", 9585124.9477);
    testBuilderAggFloat(client, "18.6a", "products.avg(avg_price,ListPrice)", &b18_6_avg, "avg_price", 744.5952);
    testBuilderAggFloat(client, "18.6b", "products.max(max_price,ListPrice)", &b18_6_max, "max_price", 3578.27);
    testBuilderAggFloat(client, "18.6c", "products.min(min_price,ListPrice)", &b18_6_min, "min_price", 2.29);

    // ── Category 19: Builder GroupBy ──
    std.debug.print("── Category 19: Builder GroupBy ──\n", .{});
    testBuilderGroupCount(client, "19.1", "orders.groupBy(EmpID).count(n)", &b19_1, 17);
    testBuilderGroupCount(client, "19.2", "employees.groupBy(Gender).count(n)", &b19_2, 2);
    testBuilderGroupCount(client, "19.3", "employees.groupBy(Gender,Marital).count(n)", &b19_3, 4);
    testBuilderGroupCount(client, "19.4", "orders.groupBy(EmpID).count+sum", &b19_4, 17);
    testBuilderGroupCount(client, "19.5", "vendors.groupBy(CreditRating).count(n)", &b19_5, 5);
    testBuilderGroupCount(client, "19.6", "orders.where(EmpID=289).groupBy(CustID).count+sum", &b19_6, 62);

    // ── Category 20: Builder Filter + GroupBy ──
    std.debug.print("── Category 20: Builder Filter + GroupBy ──\n", .{});
    testBuilderGroupCount(client, "20.1", "orders.where(TotalDue>10000).groupBy(EmpID).count(n)", &b20_1, 17);
    testBuilderGroupCount(client, "20.2", "products.where(ListPrice>0).groupBy(SubCatID).count+avg", &b20_2, 37);

    const builder_pass = pass_count - builder_start_pass;
    const builder_fail = fail_count - builder_start_fail;

    // ════════════════════════════════════════════════════════════════
    // Final Summary
    // ════════════════════════════════════════════════════════════════
    std.debug.print("\n╔══════════════════════════════════════════╗\n", .{});
    std.debug.print("║         TEST RESULTS SUMMARY             ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════╣\n", .{});
    std.debug.print("║  YQL Text:  {d:>3} passed, {d:>3} failed       ║\n", .{ yql_pass, yql_fail });
    std.debug.print("║  Builder:   {d:>3} passed, {d:>3} failed       ║\n", .{ builder_pass, builder_fail });
    std.debug.print("║  Total:     {d:>3} passed, {d:>3} failed       ║\n", .{ pass_count, fail_count });
    std.debug.print("╚══════════════════════════════════════════╝\n", .{});

    if (fail_count > 0) {
        std.process.exit(1);
    }
}
