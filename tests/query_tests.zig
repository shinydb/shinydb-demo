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

/// Get a field value from a BSON document using a dotted path like "address.city"
/// Uses bsonGetSubDoc to navigate into sub-documents, then bsonGetField for leaf
fn bsonGetNestedField(data: []const u8, field_path: []const u8) BsonFieldValue {
    // Find the first dot
    var dot_pos: ?usize = null;
    for (field_path, 0..) |c, i| {
        if (c == '.') {
            dot_pos = i;
            break;
        }
    }

    if (dot_pos) |dp| {
        // Split into parent and rest
        const parent = field_path[0..dp];
        const rest = field_path[dp + 1 ..];
        // Navigate into the sub-document
        const sub_doc = bsonGetSubDoc(data, parent) orelse return .not_found;
        return bsonGetNestedField(sub_doc, rest);
    } else {
        // No dot — leaf field
        return bsonGetField(data, field_path);
    }
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

/// Get a nested field from the Nth BSON document in concatenated data (dotted path)
fn bsonGetNestedFieldFromNth(data: []const u8, n: usize, field_path: []const u8) BsonFieldValue {
    var pos: usize = 0;
    var idx: usize = 0;
    while (pos + 4 <= data.len) {
        const doc_size = std.mem.readInt(i32, data[pos..][0..4], .little);
        if (doc_size < 5 or pos + @as(usize, @intCast(doc_size)) > data.len) break;
        if (idx == n) {
            return bsonGetNestedField(data[pos .. pos + @as(usize, @intCast(doc_size))], field_path);
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
    if (query_ast.order_by) |ob| {
        for (ob.items) |spec| _ = query.orderBy(spec.field, spec.direction);
    }

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

    // Pass projection if present
    if (query_ast.projection) |proj| {
        _ = query.select(proj.items);
    }

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

// ─── Projection Test Helpers ────────────────────────────────────────────────

/// Test that a YQL projection query returns docs with only the specified fields
/// present_fields: fields that MUST exist in the result
/// absent_fields: fields that MUST NOT exist in the result
fn testProjection(allocator: std.mem.Allocator, client: *ShinyDbClient, id: []const u8, yql_text: []const u8, present_fields: []const []const u8, absent_fields: []const []const u8) void {
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

    // Parse the first BSON document from the response
    if (data.len < 4) {
        reportFail(id, yql_text, "Response too short");
        return;
    }
    const doc_size = std.mem.readInt(i32, data[0..4], .little);
    if (doc_size < 5 or doc_size > data.len) {
        reportFail(id, yql_text, "Invalid BSON doc size");
        return;
    }
    const doc_bytes = data[0..@intCast(doc_size)];

    // Check that present_fields exist
    for (present_fields) |field| {
        const val = bsonGetField(doc_bytes, field);
        if (val == .not_found) {
            var buf: [256]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "expected field '{s}' not found in projected doc", .{field}) catch "missing field";
            reportFail(id, yql_text, detail);
            return;
        }
    }

    // Check that absent_fields do NOT exist
    for (absent_fields) |field| {
        const val = bsonGetField(doc_bytes, field);
        if (val != .not_found) {
            var buf: [256]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "field '{s}' should NOT be in projected doc", .{field}) catch "extra field";
            reportFail(id, yql_text, detail);
            return;
        }
    }

    reportPass(id, yql_text);
}

/// Test that a Builder projection query returns docs with only the specified fields
fn testBuilderProjection(client: *ShinyDbClient, id: []const u8, desc: []const u8, build_fn: *const fn (client: *ShinyDbClient) QueryBuildResult, present_fields: []const []const u8, absent_fields: []const []const u8) void {
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

    // Parse the first BSON document from the response
    if (data.len < 4) {
        reportFail(id, desc, "Response too short");
        return;
    }
    const doc_size = std.mem.readInt(i32, data[0..4], .little);
    if (doc_size < 5 or doc_size > data.len) {
        reportFail(id, desc, "Invalid BSON doc size");
        return;
    }
    const doc_bytes = data[0..@intCast(doc_size)];

    // Check that present_fields exist
    for (present_fields) |field| {
        const val = bsonGetField(doc_bytes, field);
        if (val == .not_found) {
            var buf: [256]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "expected field '{s}' not found in projected doc", .{field}) catch "missing field";
            reportFail(id, desc, detail);
            return;
        }
    }

    // Check that absent_fields do NOT exist
    for (absent_fields) |field| {
        const val = bsonGetField(doc_bytes, field);
        if (val != .not_found) {
            var buf: [256]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "field '{s}' should NOT be in projected doc", .{field}) catch "extra field";
            reportFail(id, desc, detail);
            return;
        }
    }

    reportPass(id, desc);
}

// ─── Multi-Sort Test Helpers ────────────────────────────────────────────────

const SortDir = enum { asc, desc };
const SortField = struct { name: []const u8, dir: SortDir };

/// Convert a BsonFieldValue to f64 for numeric comparison (returns null for non-numeric)
fn bsonValToF64(val: BsonFieldValue) ?f64 {
    return switch (val) {
        .int32 => |v| @as(f64, @floatFromInt(v)),
        .int64 => |v| @as(f64, @floatFromInt(v)),
        .double => |v| v,
        else => null,
    };
}

/// Compare two BsonFieldValues, returns .lt, .gt, or .eq
fn compareBsonFieldValues(a: BsonFieldValue, b: BsonFieldValue) std.math.Order {
    // Numeric comparison (cross-type)
    const a_num = bsonValToF64(a);
    const b_num = bsonValToF64(b);
    if (a_num != null and b_num != null) {
        return std.math.order(a_num.?, b_num.?);
    }
    // String comparison
    if (a == .string and b == .string) {
        return std.mem.order(u8, a.string, b.string);
    }
    return .eq;
}

/// Test that a YQL multi-sort query returns docs in correct multi-field order
fn testMultiSortOrder(allocator: std.mem.Allocator, client: *ShinyDbClient, id: []const u8, yql_text: []const u8, sort_fields: []const SortField, min_docs: usize) void {
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
    if (num_docs < min_docs) {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "expected >= {d} docs, got {d}", .{ min_docs, num_docs }) catch "too few docs";
        reportFail(id, yql_text, detail);
        return;
    }

    // Validate ordering: for each adjacent pair, the multi-sort order must hold
    var i: usize = 0;
    while (i + 1 < num_docs) : (i += 1) {
        for (sort_fields) |sf| {
            const a_val = bsonGetFieldFromNth(data, i, sf.name);
            const b_val = bsonGetFieldFromNth(data, i + 1, sf.name);
            const cmp = compareBsonFieldValues(a_val, b_val);
            if (cmp == .eq) continue; // tie → check next sort field
            // Not a tie: must be in the right direction
            const expected: std.math.Order = if (sf.dir == .asc) .lt else .gt;
            if (cmp != expected) {
                var buf: [256]u8 = undefined;
                const detail = std.fmt.bufPrint(&buf, "Doc[{d}] vs Doc[{d}]: field '{s}' out of order", .{ i, i + 1, sf.name }) catch "sort order violation";
                reportFail(id, yql_text, detail);
                return;
            }
            break; // primary field resolved the order, don't check secondary
        }
    }

    reportPass(id, yql_text);
}

/// Test that a Builder multi-sort query returns docs in correct multi-field order
fn testBuilderMultiSortOrder(client: *ShinyDbClient, id: []const u8, desc_text: []const u8, build_fn: *const fn (client: *ShinyDbClient) QueryBuildResult, sort_fields: []const SortField, min_docs: usize) void {
    const build_result = build_fn(client);
    var query = build_result.query;
    var response = query.run() catch |err| {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "Query failed: {}", .{err}) catch "Query failed";
        reportFail(id, desc_text, detail);
        query.deinit();
        return;
    };
    defer response.deinit();
    query.deinit();

    const data = response.data orelse {
        reportFail(id, desc_text, "No data in response");
        return;
    };

    const num_docs = countBsonDocs(data);
    if (num_docs < min_docs) {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "expected >= {d} docs, got {d}", .{ min_docs, num_docs }) catch "too few docs";
        reportFail(id, desc_text, detail);
        return;
    }

    // Validate ordering: for each adjacent pair, the multi-sort order must hold
    var i: usize = 0;
    while (i + 1 < num_docs) : (i += 1) {
        for (sort_fields) |sf| {
            const a_val = bsonGetFieldFromNth(data, i, sf.name);
            const b_val = bsonGetFieldFromNth(data, i + 1, sf.name);
            const cmp = compareBsonFieldValues(a_val, b_val);
            if (cmp == .eq) continue; // tie → check next sort field
            // Not a tie: must be in the right direction
            const expected: std.math.Order = if (sf.dir == .asc) .lt else .gt;
            if (cmp != expected) {
                var buf: [256]u8 = undefined;
                const detail = std.fmt.bufPrint(&buf, "Doc[{d}] vs Doc[{d}]: field '{s}' out of order", .{ i, i + 1, sf.name }) catch "sort order violation";
                reportFail(id, desc_text, detail);
                return;
            }
            break; // primary field resolved the order, don't check secondary
        }
    }

    reportPass(id, desc_text);
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

// ─── Phase 1 Builder Query Constructors ────────────────────────────────────

const Value = shinydb.yql.Value;

// 21.x — $in operator
fn b21_1(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("EmployeeID", .in, .{ .array = @constCast(&[_]Value{ .{ .int = 289 }, .{ .int = 288 } }) }).countOnly();
    return .{ .query = q };
}
fn b21_2(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("EmployeeID", .in, .{ .array = @constCast(&[_]Value{ .{ .int = 289 }, .{ .int = 287 }, .{ .int = 285 } }) }).countOnly();
    return .{ .query = q };
}
fn b21_3(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").where("SubCategoryID", .in, .{ .array = @constCast(&[_]Value{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 14 } }) }).countOnly();
    return .{ .query = q };
}
fn b21_4(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("employees").where("Gender", .in, .{ .array = @constCast(&[_]Value{.{ .string = "M" }}) }).countOnly();
    return .{ .query = q };
}
fn b21_5(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("employees").where("MaritalStatus", .in, .{ .array = @constCast(&[_]Value{ .{ .string = "S" }, .{ .string = "M" } }) }).countOnly();
    return .{ .query = q };
}

// 22.x — $contains
fn b22_1(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").where("ProductName", .contains, .{ .string = "Road" }).countOnly();
    return .{ .query = q };
}
fn b22_2(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").where("ProductName", .contains, .{ .string = "Mountain" }).countOnly();
    return .{ .query = q };
}
fn b22_3(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").where("ProductName", .contains, .{ .string = "Frame" }).countOnly();
    return .{ .query = q };
}
fn b22_4(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("vendors").where("VendorName", .contains, .{ .string = "Bike" }).countOnly();
    return .{ .query = q };
}

// 23.x — $startsWith
fn b23_1(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").where("ProductName", .starts_with, .{ .string = "HL" }).countOnly();
    return .{ .query = q };
}
fn b23_2(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").where("ProductName", .starts_with, .{ .string = "Mountain" }).countOnly();
    return .{ .query = q };
}
fn b23_3(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("employees").where("FirstName", .starts_with, .{ .string = "S" }).countOnly();
    return .{ .query = q };
}

// 24.x — $exists
fn b24_1(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").where("ProductName", .exists, .{ .bool = true }).countOnly();
    return .{ .query = q };
}
fn b24_2(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("employees").where("Gender", .exists, .{ .bool = true }).countOnly();
    return .{ .query = q };
}
fn b24_3(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").where("Color", .exists, .{ .bool = true }).countOnly();
    return .{ .query = q };
}
fn b24_4(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("employees").where("Salary", .exists, .{ .bool = true }).countOnly();
    return .{ .query = q };
}

// 25.x — $regex
fn b25_1(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").where("ProductName", .regex, .{ .string = "^HL" }).countOnly();
    return .{ .query = q };
}
fn b25_2(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").where("ProductName", .regex, .{ .string = "Frame" }).countOnly();
    return .{ .query = q };
}
fn b25_3(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").where("ProductName", .regex, .{ .string = "58$" }).countOnly();
    return .{ .query = q };
}
fn b25_4(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").where("ProductName", .regex, .{ .string = "^AWC Logo Cap$" }).countOnly();
    return .{ .query = q };
}

// ─── Phase 2: Builder OR functions ──────────────────────────────────

fn b31_1(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("employees").where("Gender", .eq, .{ .string = "M" }).@"or"("MaritalStatus", .eq, .{ .string = "S" }).countOnly();
    return .{ .query = q };
}

fn b31_2(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").where("ProductName", .contains, .{ .string = "Road" }).@"or"("ProductName", .contains, .{ .string = "Mountain" }).countOnly();
    return .{ .query = q };
}

fn b31_3(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").where("SubCategoryID", .eq, .{ .int = 1 }).@"or"("SubCategoryID", .eq, .{ .int = 2 }).countOnly();
    return .{ .query = q };
}

fn b31_4(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("TotalDue", .gt, .{ .float = 100000 }).@"or"("TotalDue", .lt, .{ .float = 100 }).countOnly();
    return .{ .query = q };
}

fn b31_5(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("EmployeeID", .eq, .{ .int = 289 }).@"or"("EmployeeID", .eq, .{ .int = 288 }).countOnly();
    return .{ .query = q };
}

// ─── Phase 3: Builder Range Index Scan functions ───────────────────────

// 40.1: EmployeeID >= 285 and <= 287 (closed range, indexed) — same as 3.8 but via builder
fn b40_1(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("EmployeeID", .gte, .{ .int = 285 }).@"and"("EmployeeID", .lte, .{ .int = 287 }).countOnly();
    return .{ .query = q };
}

// 40.2: EmployeeID >= 288 and <= 289 (should equal sum of 288+289 = 478)
fn b40_2(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("EmployeeID", .gte, .{ .int = 288 }).@"and"("EmployeeID", .lte, .{ .int = 289 }).countOnly();
    return .{ .query = q };
}

// 40.3: EmployeeID > 288 (exclusive lower bound)
fn b40_3(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("EmployeeID", .gt, .{ .int = 288 }).countOnly();
    return .{ .query = q };
}

// 40.4: EmployeeID < 285 (upper bound only, no lower bound)
fn b40_4(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("EmployeeID", .lt, .{ .int = 285 }).countOnly();
    return .{ .query = q };
}

// 40.5: EmployeeID >= 289 and <= 289 (range that equals equality)
fn b40_5(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("EmployeeID", .gte, .{ .int = 289 }).@"and"("EmployeeID", .lte, .{ .int = 289 }).countOnly();
    return .{ .query = q };
}

// 40.6: EmployeeID > 285 and < 289 (exclusive both bounds)
fn b40_6(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("EmployeeID", .gt, .{ .int = 285 }).@"and"("EmployeeID", .lt, .{ .int = 289 }).countOnly();
    return .{ .query = q };
}

// ─── Phase 4: Builder Projection functions ─────────────────────────────────

// 50.1: Select only EmployeeID and FullName from employees
fn b50_1(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("employees").where("EmployeeID", .eq, .{ .int = 274 }).select(&.{ "EmployeeID", "FullName" });
    return .{ .query = q };
}

// 50.2: Select only ProductName and ListPrice from products
fn b50_2(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").where("SubCategoryID", .eq, .{ .int = 14 }).limit(1).select(&.{ "ProductName", "ListPrice" });
    return .{ .query = q };
}

// 50.3: Select single field (EmployeeID only)
fn b50_3(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("employees").limit(1).select(&.{"EmployeeID"});
    return .{ .query = q };
}

// 50.4: Select with filter + sort
fn b50_4(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("EmployeeID", .eq, .{ .int = 289 }).orderBy("TotalDue", .desc).limit(1).select(&.{ "EmployeeID", "TotalDue" });
    return .{ .query = q };
}

// ─── Phase 5: Builder Multi-Sort functions ─────────────────────────────────

// 60.1: Orders sorted by EmployeeID asc, TotalDue desc — limit 10
fn b60_1(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").orderBy("EmployeeID", .asc).orderBy("TotalDue", .desc).limit(10);
    return .{ .query = q };
}

// 60.2: Employees sorted by Gender asc, EmployeeID desc — limit 10
fn b60_2(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("employees").orderBy("Gender", .asc).orderBy("EmployeeID", .desc).limit(10);
    return .{ .query = q };
}

// 60.3: Products sorted by SubCategoryID asc, ListPrice desc — limit 10
fn b60_3(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("products").orderBy("SubCategoryID", .asc).orderBy("ListPrice", .desc).limit(10);
    return .{ .query = q };
}

// 60.4: Orders filtered by EmployeeID >= 285, sorted by EmployeeID asc, TotalDue asc — limit 20
fn b60_4(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("orders").where("EmployeeID", .gte, .{ .int = 285 }).orderBy("EmployeeID", .asc).orderBy("TotalDue", .asc).limit(20);
    return .{ .query = q };
}

// ─── Phase 6: Nested Field Tests use sales.customers with Address sub-document ──

// ─── Phase 6: Builder Functions ────────────────────────────────────────────

/// Test that a builder query returns docs with nested field values in expected order
fn testBuilderNestedStrOrder(
    client: *ShinyDbClient,
    id: []const u8,
    desc: []const u8,
    build_fn: *const fn (client: *ShinyDbClient) QueryBuildResult,
    nested_field: []const u8,
    expected_values: []const []const u8,
) void {
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

    for (expected_values, 0..) |exp, i| {
        const val = bsonGetNestedFieldFromNth(data, i, nested_field);
        switch (val) {
            .string => |s| {
                if (!std.mem.eql(u8, s, exp)) {
                    var buf: [256]u8 = undefined;
                    const detail = std.fmt.bufPrint(&buf, "Doc[{d}] {s}: expected=\"{s}\", got=\"{s}\"", .{ i, nested_field, exp, s }) catch "mismatch";
                    reportFail(id, desc, detail);
                    return;
                }
            },
            else => {
                var buf: [256]u8 = undefined;
                const detail = std.fmt.bufPrint(&buf, "Doc[{d}] nested field '{s}' not found", .{ i, nested_field }) catch "not found";
                reportFail(id, desc, detail);
                return;
            },
        }
    }
    reportPass(id, desc);
}

/// Test that a builder query returns docs with nested int field values in expected order
fn testBuilderNestedIntOrder(
    client: *ShinyDbClient,
    id: []const u8,
    desc: []const u8,
    build_fn: *const fn (client: *ShinyDbClient) QueryBuildResult,
    nested_field: []const u8,
    expected_values: []const i32,
) void {
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

    for (expected_values, 0..) |exp, i| {
        const val = bsonGetNestedFieldFromNth(data, i, nested_field);
        const actual: i32 = switch (val) {
            .int32 => |v| v,
            else => {
                var buf: [256]u8 = undefined;
                const detail = std.fmt.bufPrint(&buf, "Doc[{d}] nested field '{s}' not found/wrong type", .{ i, nested_field }) catch "not found";
                reportFail(id, desc, detail);
                return;
            },
        };
        if (actual != exp) {
            var buf: [256]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "Doc[{d}] {s}: expected={d}, got={d}", .{ i, nested_field, exp, actual }) catch "mismatch";
            reportFail(id, desc, detail);
            return;
        }
    }
    reportPass(id, desc);
}

// 70.1: Filter by nested string — Address.City = "New York" → 46 customers
fn b70_1(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("customers").where("Address.City", .eq, .{ .string = "New York" }).countOnly();
    return .{ .query = q };
}

// 70.2: Filter by nested string — Address.State = "CA" → 111 customers
fn b70_2(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("customers").where("Address.State", .eq, .{ .string = "CA" }).countOnly();
    return .{ .query = q };
}

// 70.3: Filter by nested string — Address.City = "Chicago" → 49 customers
fn b70_3(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("customers").where("Address.City", .eq, .{ .string = "Chicago" }).countOnly();
    return .{ .query = q };
}

// 70.4: Filter by nested string — Address.State = "TX" → 84 customers
fn b70_4(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("customers").where("Address.State", .eq, .{ .string = "TX" }).countOnly();
    return .{ .query = q };
}

// 70.5: Filter by nested string — Address.Country = "US" → 635 (all customers)
fn b70_5(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("customers").where("Address.Country", .eq, .{ .string = "US" }).countOnly();
    return .{ .query = q };
}

// 70.6: Filter by nested string — Address.State = "FL" → 53 customers
fn b70_6(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("customers").where("Address.State", .eq, .{ .string = "FL" }).countOnly();
    return .{ .query = q };
}

// 70.7: Sort by nested field — orderBy(Address.City, asc).limit(5) → first 5 alphabetical cities
fn b70_7(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("customers").orderBy("Address.City", .asc).limit(5);
    return .{ .query = q };
}

// 70.8: Filter + sort — Address.State = "NY" sorted by Address.ZipCode asc, limit 5
fn b70_8(client: *ShinyDbClient) QueryBuildResult {
    var q = Query.init(client);
    _ = q.space("sales").store("customers").where("Address.State", .eq, .{ .string = "NY" }).orderBy("Address.ZipCode", .asc).limit(5);
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

    // Phase 6 uses sales.customers with nested Address sub-document (no extra setup needed)

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

    var yql_pass: usize = pass_count;
    var yql_fail: usize = fail_count;

    // ════════════════════════════════════════════════════════════════
    // Phase 1 — YQL Tests for new operators (Categories 21–25)
    // ════════════════════════════════════════════════════════════════
    std.debug.print("\n═══ Phase 1: YQL Operator Tests ═══\n\n", .{});

    // ── Category 21: YQL $in ──
    std.debug.print("── Category 21: YQL $in ──\n", .{});
    testCount(allocator, client, "21.1", "sales.orders.filter(EmployeeID in [289, 288]).count()", 478);
    testCount(allocator, client, "21.2", "sales.orders.filter(EmployeeID in [289, 287, 285]).count()", 403);
    testCount(allocator, client, "21.3", "sales.products.filter(SubCategoryID in [1, 2, 14]).count()", 108);
    testCount(allocator, client, "21.4",
        \\sales.employees.filter(Gender in ["M"]).count()
    , 10);
    testCount(allocator, client, "21.5",
        \\sales.employees.filter(MaritalStatus in ["S", "M"]).count()
    , 17);

    // ── Category 22: YQL $contains ──
    std.debug.print("── Category 22: YQL $contains ──\n", .{});
    testCount(allocator, client, "22.1",
        \\sales.products.filter(ProductName contains "Road").count()
    , 96);
    testCount(allocator, client, "22.2",
        \\sales.products.filter(ProductName contains "Mountain").count()
    , 87);
    testCount(allocator, client, "22.3",
        \\sales.products.filter(ProductName contains "Frame").count()
    , 79);
    testCount(allocator, client, "22.4",
        \\sales.vendors.filter(VendorName contains "Bike").count()
    , 22);

    // ── Category 23: YQL $startsWith ──
    std.debug.print("── Category 23: YQL $startsWith ──\n", .{});
    testCount(allocator, client, "23.1",
        \\sales.products.filter(ProductName startsWith "HL").count()
    , 47);
    testCount(allocator, client, "23.2",
        \\sales.products.filter(ProductName startsWith "Mountain").count()
    , 37);
    testCount(allocator, client, "23.3",
        \\sales.employees.filter(FirstName startsWith "S").count()
    , 3);

    // ── Category 24: YQL $exists ──
    std.debug.print("── Category 24: YQL $exists ──\n", .{});
    testCount(allocator, client, "24.1", "sales.products.filter(ProductName exists true).count()", 295);
    testCount(allocator, client, "24.2", "sales.employees.filter(Gender exists true).count()", 17);
    testCount(allocator, client, "24.3", "sales.products.filter(Color exists true).count()", 0);
    testCount(allocator, client, "24.4", "sales.employees.filter(Salary exists true).count()", 0);

    // ── Category 25: YQL $regex ──
    std.debug.print("── Category 25: YQL $regex ──\n", .{});
    testCount(allocator, client, "25.1",
        \\sales.products.filter(ProductName ~ "^HL").count()
    , 47);
    testCount(allocator, client, "25.2",
        \\sales.products.filter(ProductName ~ "Frame").count()
    , 79);
    testCount(allocator, client, "25.3",
        \\sales.products.filter(ProductName ~ "58$").count()
    , 15);
    testCount(allocator, client, "25.4",
        \\sales.products.filter(ProductName ~ "^AWC Logo Cap$").count()
    , 1);

    yql_pass = pass_count;
    yql_fail = fail_count;

    // ════════════════════════════════════════════════════════════════
    // Builder API Tests (Categories 11–20)
    // ════════════════════════════════════════════════════════════════
    std.debug.print("\n═══ Builder API Tests ═══\n\n", .{});

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

    // ════════════════════════════════════════════════════════════════
    // Phase 1 — Builder Tests for new operators (Categories 21–25)
    // ════════════════════════════════════════════════════════════════
    std.debug.print("\n═══ Phase 1: Builder Operator Tests ═══\n\n", .{});

    // ── Category 21: Builder $in ──
    std.debug.print("── Category 21: Builder $in ──\n", .{});
    testBuilderCount(client, "21.1", "orders.where(EmpID in [289,288]).countOnly()", &b21_1, 478);
    testBuilderCount(client, "21.2", "orders.where(EmpID in [289,287,285]).countOnly()", &b21_2, 403);
    testBuilderCount(client, "21.3", "products.where(SubCatID in [1,2,14]).countOnly()", &b21_3, 108);
    testBuilderCount(client, "21.4", "employees.where(Gender in ['M']).countOnly()", &b21_4, 10);
    testBuilderCount(client, "21.5", "employees.where(Marital in ['S','M']).countOnly()", &b21_5, 17);

    // ── Category 22b: Builder $contains ──
    std.debug.print("── Category 22b: Builder $contains ──\n", .{});
    testBuilderCount(client, "22b.1", "products.where(ProdName contains Road).countOnly()", &b22_1, 96);
    testBuilderCount(client, "22b.2", "products.where(ProdName contains Mountain).countOnly()", &b22_2, 87);
    testBuilderCount(client, "22b.3", "products.where(ProdName contains Frame).countOnly()", &b22_3, 79);
    testBuilderCount(client, "22b.4", "vendors.where(VendorName contains Bike).countOnly()", &b22_4, 22);

    // ── Category 23: Builder $startsWith ──
    std.debug.print("── Category 23: Builder $startsWith ──\n", .{});
    testBuilderCount(client, "23.1", "products.where(ProdName startsWith HL).countOnly()", &b23_1, 47);
    testBuilderCount(client, "23.2", "products.where(ProdName startsWith Mountain).countOnly()", &b23_2, 37);
    testBuilderCount(client, "23.3", "employees.where(FirstName startsWith S).countOnly()", &b23_3, 3);

    // ── Category 24b: Builder $exists ──
    std.debug.print("── Category 24b: Builder $exists ──\n", .{});
    testBuilderCount(client, "24b.1", "products.where(ProductName exists true).countOnly()", &b24_1, 295);
    testBuilderCount(client, "24b.2", "employees.where(Gender exists true).countOnly()", &b24_2, 17);
    testBuilderCount(client, "24b.3", "products.where(Color exists true).countOnly()", &b24_3, 0);
    testBuilderCount(client, "24b.4", "employees.where(Salary exists true).countOnly()", &b24_4, 0);

    // ── Category 25b: Builder $regex ──
    std.debug.print("── Category 25b: Builder $regex ──\n", .{});
    testBuilderCount(client, "25b.1", "products.where(ProdName ~ ^HL).countOnly()", &b25_1, 47);
    testBuilderCount(client, "25b.2", "products.where(ProdName ~ Frame).countOnly()", &b25_2, 79);
    testBuilderCount(client, "25b.3", "products.where(ProdName ~ 58$).countOnly()", &b25_3, 15);
    testBuilderCount(client, "25b.4", "products.where(ProdName ~ ^AWC Logo Cap$).countOnly()", &b25_4, 1);

    const p2_yql_start = pass_count;
    const p2_yql_fail_start = fail_count;

    // ═══ Phase 2: YQL OR Tests ═══
    std.debug.print("\n═══ Phase 2: YQL OR Tests ═══\n\n", .{});

    // ── Category 30: YQL OR ──
    std.debug.print("── Category 30: YQL OR ──\n", .{});
    testCount(allocator, client, "30.1",
        \\sales.employees.filter(Gender = "M" or MaritalStatus = "S").count()
    , 14);
    testCount(allocator, client, "30.2",
        \\sales.products.filter(ProductName contains "Road" or ProductName contains "Mountain").count()
    , 183);
    testCount(allocator, client, "30.3", "sales.products.filter(SubCategoryID = 1 or SubCategoryID = 2).count()", 75);
    testCount(allocator, client, "30.4", "sales.orders.filter(TotalDue > 100000 or TotalDue < 100).count()", 263);
    testCount(allocator, client, "30.5", "sales.orders.filter(EmployeeID = 289 or EmployeeID = 288).count()", 478);

    yql_pass += pass_count - p2_yql_start;
    yql_fail += fail_count - p2_yql_fail_start;

    // ═══ Phase 2: Builder OR Tests ═══
    std.debug.print("\n═══ Phase 2: Builder OR Tests ═══\n\n", .{});

    // ── Category 31: Builder OR ──
    std.debug.print("── Category 31: Builder OR ──\n", .{});
    testBuilderCount(client, "31.1", "employees.where(Gender=M).or(MaritalStatus=S).countOnly()", &b31_1, 14);
    testBuilderCount(client, "31.2", "products.where(contains Road).or(contains Mountain).countOnly()", &b31_2, 183);
    testBuilderCount(client, "31.3", "products.where(SubCatID=1).or(SubCatID=2).countOnly()", &b31_3, 75);
    testBuilderCount(client, "31.4", "orders.where(TotalDue>100000).or(TotalDue<100).countOnly()", &b31_4, 263);
    testBuilderCount(client, "31.5", "orders.where(EmpID=289).or(EmpID=288).countOnly()", &b31_5, 478);

    const p3_yql_start = pass_count;
    const p3_yql_fail_start = fail_count;

    // ═══ Phase 3: Range Index Scan Tests ═══
    std.debug.print("\n═══ Phase 3: YQL Range Index Scan Tests ═══\n\n", .{});

    // ── Category 40: YQL Range on indexed EmployeeID ──
    std.debug.print("── Category 40: YQL Range Index Scan ──\n", .{});
    testCount(allocator, client, "40.1", "sales.orders.filter(EmployeeID >= 285 and EmployeeID <= 287).count()", 164);
    testCount(allocator, client, "40.2", "sales.orders.filter(EmployeeID >= 288 and EmployeeID <= 289).count()", 478);
    testCount(allocator, client, "40.3", "sales.orders.filter(EmployeeID >= 289 and EmployeeID <= 289).count()", 348);
    testCount(allocator, client, "40.4", "sales.orders.filter(EmployeeID > 285 and EmployeeID < 289).count()", 278);
    testCount(allocator, client, "40.5", "sales.orders.filter(EmployeeID > 288).count()", 523);
    testCount(allocator, client, "40.6", "sales.orders.filter(EmployeeID < 285).count()", 2989);

    yql_pass += pass_count - p3_yql_start;
    yql_fail += fail_count - p3_yql_fail_start;

    std.debug.print("\n═══ Phase 3: Builder Range Index Scan Tests ═══\n\n", .{});

    // ── Category 41: Builder Range on indexed EmployeeID ──
    std.debug.print("── Category 41: Builder Range Index Scan ──\n", .{});
    testBuilderCount(client, "41.1", "orders.where(EmpID>=285).and(EmpID<=287).countOnly()", &b40_1, 164);
    testBuilderCount(client, "41.2", "orders.where(EmpID>=288).and(EmpID<=289).countOnly()", &b40_2, 478);
    testBuilderCount(client, "41.3", "orders.where(EmpID>288).countOnly()", &b40_3, 523);
    testBuilderCount(client, "41.4", "orders.where(EmpID<285).countOnly()", &b40_4, 2989);
    testBuilderCount(client, "41.5", "orders.where(EmpID>=289).and(EmpID<=289).countOnly()", &b40_5, 348);
    testBuilderCount(client, "41.6", "orders.where(EmpID>285).and(EmpID<289).countOnly()", &b40_6, 278);

    const p4_yql_start = pass_count;
    const p4_yql_fail_start = fail_count;

    // ═══ Phase 4: Projection Tests ═══
    std.debug.print("\n═══ Phase 4: YQL Projection Tests ═══\n\n", .{});

    // ── Category 50: YQL Projection ──
    std.debug.print("── Category 50: YQL Projection ──\n", .{});
    testProjection(
        allocator,
        client,
        "50.1",
        "sales.employees.filter(EmployeeID = 274).pluck(EmployeeID, FullName)",
        &.{ "EmployeeID", "FullName" },
        &.{ "Gender", "JobTitle", "MaritalStatus", "Territory" },
    );
    testProjection(
        allocator,
        client,
        "50.2",
        "sales.products.filter(SubCategoryID = 14).limit(1).pluck(ProductName, ListPrice)",
        &.{ "ProductName", "ListPrice" },
        &.{ "SubCategoryID", "MakeFlag", "StandardCost", "ModelName" },
    );
    testProjection(
        allocator,
        client,
        "50.3",
        "sales.employees.limit(1).pluck(EmployeeID)",
        &.{"EmployeeID"},
        &.{ "FullName", "Gender", "JobTitle" },
    );
    testProjection(
        allocator,
        client,
        "50.4",
        "sales.orders.filter(EmployeeID = 289).orderBy(TotalDue, desc).limit(1).pluck(EmployeeID, TotalDue)",
        &.{ "EmployeeID", "TotalDue" },
        &.{ "CustomerID", "SubTotal", "Freight" },
    );

    yql_pass += pass_count - p4_yql_start;
    yql_fail += fail_count - p4_yql_fail_start;

    std.debug.print("\n═══ Phase 4: Builder Projection Tests ═══\n\n", .{});

    // ── Category 51: Builder Projection ──
    std.debug.print("── Category 51: Builder Projection ──\n", .{});
    testBuilderProjection(
        client,
        "51.1",
        "employees.where(EmpID=274).select(EmployeeID, FullName)",
        &b50_1,
        &.{ "EmployeeID", "FullName" },
        &.{ "Gender", "JobTitle", "MaritalStatus", "Territory" },
    );
    testBuilderProjection(
        client,
        "51.2",
        "products.where(SubCat=14).limit(1).select(ProductName, ListPrice)",
        &b50_2,
        &.{ "ProductName", "ListPrice" },
        &.{ "SubCategoryID", "MakeFlag", "StandardCost", "ModelName" },
    );
    testBuilderProjection(
        client,
        "51.3",
        "employees.limit(1).select(EmployeeID)",
        &b50_3,
        &.{"EmployeeID"},
        &.{ "FullName", "Gender", "JobTitle" },
    );
    testBuilderProjection(
        client,
        "51.4",
        "orders.where(EmpID=289).orderBy(TotalDue desc).limit(1).select(EmployeeID, TotalDue)",
        &b50_4,
        &.{ "EmployeeID", "TotalDue" },
        &.{ "CustomerID", "SubTotal", "Freight" },
    );

    const p5_yql_start = pass_count;
    const p5_yql_fail_start = fail_count;

    // ═══ Phase 5: Multi-Sort Tests ═══
    std.debug.print("\n═══ Phase 5: YQL Multi-Sort Tests ═══\n\n", .{});

    // ── Category 60: YQL Multi-Sort ──
    std.debug.print("── Category 60: YQL Multi-Sort ──\n", .{});
    testMultiSortOrder(
        allocator,
        client,
        "60.1",
        "sales.orders.orderBy(EmployeeID, asc).orderBy(TotalDue, desc).limit(10)",
        &.{ .{ .name = "EmployeeID", .dir = .asc }, .{ .name = "TotalDue", .dir = .desc } },
        10,
    );
    testMultiSortOrder(
        allocator,
        client,
        "60.2",
        "sales.employees.orderBy(Gender, asc).orderBy(EmployeeID, desc).limit(10)",
        &.{ .{ .name = "Gender", .dir = .asc }, .{ .name = "EmployeeID", .dir = .desc } },
        10,
    );
    testMultiSortOrder(
        allocator,
        client,
        "60.3",
        "sales.products.orderBy(SubCategoryID, asc).orderBy(ListPrice, desc).limit(10)",
        &.{ .{ .name = "SubCategoryID", .dir = .asc }, .{ .name = "ListPrice", .dir = .desc } },
        10,
    );
    testMultiSortOrder(
        allocator,
        client,
        "60.4",
        "sales.orders.filter(EmployeeID >= 285).orderBy(EmployeeID, asc).orderBy(TotalDue, asc).limit(20)",
        &.{ .{ .name = "EmployeeID", .dir = .asc }, .{ .name = "TotalDue", .dir = .asc } },
        20,
    );

    yql_pass += pass_count - p5_yql_start;
    yql_fail += fail_count - p5_yql_fail_start;

    std.debug.print("\n═══ Phase 5: Builder Multi-Sort Tests ═══\n\n", .{});

    // ── Category 61: Builder Multi-Sort ──
    std.debug.print("── Category 61: Builder Multi-Sort ──\n", .{});
    testBuilderMultiSortOrder(
        client,
        "61.1",
        "orders.orderBy(EmpID,asc).orderBy(TotalDue,desc).limit(10)",
        &b60_1,
        &.{ .{ .name = "EmployeeID", .dir = .asc }, .{ .name = "TotalDue", .dir = .desc } },
        10,
    );
    testBuilderMultiSortOrder(
        client,
        "61.2",
        "employees.orderBy(Gender,asc).orderBy(EmpID,desc).limit(10)",
        &b60_2,
        &.{ .{ .name = "Gender", .dir = .asc }, .{ .name = "EmployeeID", .dir = .desc } },
        10,
    );
    testBuilderMultiSortOrder(
        client,
        "61.3",
        "products.orderBy(SubCatID,asc).orderBy(ListPrice,desc).limit(10)",
        &b60_3,
        &.{ .{ .name = "SubCategoryID", .dir = .asc }, .{ .name = "ListPrice", .dir = .desc } },
        10,
    );
    testBuilderMultiSortOrder(
        client,
        "61.4",
        "orders.where(EmpID>=285).orderBy(EmpID,asc).orderBy(TotalDue,asc).limit(20)",
        &b60_4,
        &.{ .{ .name = "EmployeeID", .dir = .asc }, .{ .name = "TotalDue", .dir = .asc } },
        20,
    );

    const p6_yql_start = pass_count;
    const p6_yql_fail_start = fail_count;

    // ═══ Phase 6: Nested Field Access Tests (using sales.customers with Address) ═══
    std.debug.print("\n═══ Phase 6: YQL Nested Field Tests ═══\n\n", .{});

    // ── Category 70: YQL Nested Field ──
    std.debug.print("── Category 70: YQL Nested Field ──\n", .{});

    // 70.1: Filter by nested string — Address.City = "New York" → 46
    testCount(allocator, client, "70.1",
        \\sales.customers.filter(Address.City = "New York").count()
    , 46);

    // 70.2: Filter by nested string — Address.State = "CA" → 111
    testCount(allocator, client, "70.2",
        \\sales.customers.filter(Address.State = "CA").count()
    , 111);

    // 70.3: Filter by nested string — Address.City = "Chicago" → 49
    testCount(allocator, client, "70.3",
        \\sales.customers.filter(Address.City = "Chicago").count()
    , 49);

    // 70.4: Filter by nested string — Address.State = "TX" → 84
    testCount(allocator, client, "70.4",
        \\sales.customers.filter(Address.State = "TX").count()
    , 84);

    // 70.5: Filter by nested string — Address.Country = "US" → 635 (all)
    testCount(allocator, client, "70.5",
        \\sales.customers.filter(Address.Country = "US").count()
    , 635);

    // 70.6: Filter by nested string — Address.State = "FL" → 53
    testCount(allocator, client, "70.6",
        \\sales.customers.filter(Address.State = "FL").count()
    , 53);

    // 70.7: Filter by nested string — Address.City = "Seattle" → 50
    testCount(allocator, client, "70.7",
        \\sales.customers.filter(Address.City = "Seattle").count()
    , 50);

    // 70.8: Filter by nested string — Address.City = "Boston" → 31
    testCount(allocator, client, "70.8",
        \\sales.customers.filter(Address.City = "Boston").count()
    , 31);

    yql_pass += pass_count - p6_yql_start;
    yql_fail += fail_count - p6_yql_fail_start;

    std.debug.print("\n═══ Phase 6: Builder Nested Field Tests ═══\n\n", .{});

    // ── Category 71: Builder Nested Field ──
    std.debug.print("── Category 71: Builder Nested Field ──\n", .{});

    // 71.1: Address.City = "New York" → 46
    testBuilderCount(client, "71.1", "customers.where(Address.City=New York).count()", &b70_1, 46);

    // 71.2: Address.State = "CA" → 111
    testBuilderCount(client, "71.2", "customers.where(Address.State=CA).count()", &b70_2, 111);

    // 71.3: Address.City = "Chicago" → 49
    testBuilderCount(client, "71.3", "customers.where(Address.City=Chicago).count()", &b70_3, 49);

    // 71.4: Address.State = "TX" → 84
    testBuilderCount(client, "71.4", "customers.where(Address.State=TX).count()", &b70_4, 84);

    // 71.5: Address.Country = "US" → 635
    testBuilderCount(client, "71.5", "customers.where(Address.Country=US).count()", &b70_5, 635);

    // 71.6: Address.State = "FL" → 53
    testBuilderCount(client, "71.6", "customers.where(Address.State=FL).count()", &b70_6, 53);

    // 71.7: Sort by nested field — orderBy(Address.City, asc).limit(5) → all Atlanta
    testBuilderNestedStrOrder(
        client,
        "71.7",
        "customers.orderBy(Address.City,asc).limit(5)",
        &b70_7,
        "Address.City",
        &.{ "Atlanta", "Atlanta", "Atlanta", "Atlanta", "Atlanta" },
    );

    // 71.8: Filter+Sort — Address.State=NY, orderBy(Address.ZipCode,asc).limit(5)
    testBuilderNestedStrOrder(
        client,
        "71.8",
        "customers.where(State=NY).orderBy(ZipCode,asc).limit(5)",
        &b70_8,
        "Address.State",
        &.{ "NY", "NY", "NY", "NY", "NY" },
    );

    const builder_pass = pass_count - yql_pass;
    const builder_fail = fail_count - yql_fail;

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
