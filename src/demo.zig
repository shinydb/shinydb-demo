const std = @import("std");
const shinydb = @import("shinydb-zig-client");
const Query = shinydb.Query;
const ShinyDbClient = shinydb.ShinyDbClient;

// Helper to get current time in milliseconds
fn getTimestamp() i64 {
    // Simple incrementing timestamp for demo purposes
    const base_time: i64 = 1700000000000; // Nov 2023 in milliseconds
    return base_time;
}

// Order structure for our e-commerce system
const Order = struct {
    order_id: u32,
    customer_name: []const u8,
    total_amount: f64,
    status: []const u8, // "pending", "processing", "completed", "cancelled"
    items_count: u32,
    created_at: i64,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║    YADB Query API Demo - E-Commerce Order Management    ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Create Io instance
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Connect to ShinyDb server
    std.debug.print("📡 Connecting to ShinyDb server at 127.0.0.1:23469...\n", .{});
    var client = try ShinyDbClient.init(allocator, io);
    defer client.deinit();

    try client.connect("127.0.0.1", 23469);

    std.debug.print("✅ Connected successfully!\n\n", .{});

    // Run the demo
    try runDemo(client);

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                     Demo Complete!                       ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
}

fn runDemo(client: *ShinyDbClient) !void {
    // 1. CREATE: Insert sample orders
    try demonstrateCreate(client);

    // 1.5. INDEXES: Create secondary indexes
    try demonstrateIndexes(client);

    // 2. QUERY: Read with filters
    try demonstrateQuery(client);

    // 3. UPDATE: Modify orders
    try demonstrateUpdate(client);

    // 4. AGGREGATION: Statistics
    try demonstrateAggregation(client);

    // 5. DELETE: Remove orders
    try demonstrateDelete(client);
}

fn demonstrateCreate(client: *ShinyDbClient) !void {
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("1. CREATE - Inserting Sample Orders\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n\n", .{});

    const orders = [_]Order{
        .{
            .order_id = 1001,
            .customer_name = "Alice Johnson",
            .total_amount = 299.99,
            .status = "completed",
            .items_count = 3,
            .created_at = getTimestamp(),
        },
        .{
            .order_id = 1002,
            .customer_name = "Bob Smith",
            .total_amount = 149.50,
            .status = "pending",
            .items_count = 2,
            .created_at = getTimestamp() - 3600000,
        },
        .{
            .order_id = 1003,
            .customer_name = "Charlie Brown",
            .total_amount = 599.00,
            .status = "processing",
            .items_count = 5,
            .created_at = getTimestamp() - 7200000,
        },
        .{
            .order_id = 1004,
            .customer_name = "Diana Prince",
            .total_amount = 89.99,
            .status = "completed",
            .items_count = 1,
            .created_at = getTimestamp() - 10800000,
        },
        .{
            .order_id = 1005,
            .customer_name = "Eve Wilson",
            .total_amount = 450.00,
            .status = "pending",
            .items_count = 4,
            .created_at = getTimestamp() - 14400000,
        },
    };

    for (orders, 0..) |order, i| {
        var query = Query.init(client);
        defer query.deinit();

        _ = try query.space("ecommerce")
            .store("orders")
            .create(Order, order);

        std.debug.print("  Sending insert for order #{d}...\n", .{order.order_id});
        var response = try query.run();
        defer response.deinit();

        std.debug.print("  ✓ Inserted order #{d}: {s} - ${d:.2} ({s})\n", .{
            order.order_id,
            order.customer_name,
            order.total_amount,
            order.status,
        });

        _ = i; // unused
    }

    std.debug.print("\n✅ Created {d} orders successfully!\n\n", .{orders.len});
}

fn demonstrateIndexes(client: *ShinyDbClient) !void {
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("1.5. INDEXES - Creating Secondary Indexes\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n\n", .{});

    // Create index on 'status' field
    {
        std.debug.print("📑 Creating index on 'status' field...\n", .{});

        try client.create(shinydb.Index{
            .id = 0,
            .store_id = 0,
            .ns = "ecommerce.orders.status_idx",
            .field = "status",
            .field_type = .String,
            .unique = false,
            .description = null,
            .created_at = 0,
        });

        std.debug.print("   ✓ Created index 'status_idx' on field 'status'\n", .{});
    }

    // Create index on 'total_amount' field
    {
        std.debug.print("📑 Creating index on 'total_amount' field...\n", .{});

        try client.create(shinydb.Index{
            .id = 0,
            .store_id = 0,
            .ns = "ecommerce.orders.amount_idx",
            .field = "total_amount",
            .field_type = .F64,
            .unique = false,
            .description = null,
            .created_at = 0,
        });

        std.debug.print("   ✓ Created index 'amount_idx' on field 'total_amount'\n", .{});
    }

    std.debug.print("\n✅ Created 2 secondary indexes successfully!\n\n", .{});
    std.debug.print("   💡 Queries on 'status' and 'total_amount' will now use indexes\n", .{});
    std.debug.print("      instead of full table scans for better performance.\n\n", .{});
}

fn demonstrateQuery(client: *ShinyDbClient) !void {
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("2. QUERY - Reading Orders with Filters\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n\n", .{});

    // Example 1: Simple filter - get pending orders
    {
        std.debug.print("📋 Query 1: Get all pending orders\n", .{});
        std.debug.print("   Query.init(client)\n", .{});
        std.debug.print("      .space(\"ecommerce\")\n", .{});
        std.debug.print("      .store(\"orders\")\n", .{});
        std.debug.print("      .where(\"status\", .eq, .{{.string = \"pending\"}})\n", .{});
        std.debug.print("      .run()\n\n", .{});

        var query = Query.init(client);
        defer query.deinit();

        _ = query.space("ecommerce")
            .store("orders")
            .where("status", .eq, .{ .string = "pending" });

        var response = try query.run();
        defer response.deinit();

        // Print result
        std.debug.print("   Status: {s}\n", .{@tagName(response.status)});
        if (response.asString()) |data| {
            std.debug.print("   Result: {s}\n", .{data});
        }
        std.debug.print("   ✓ Found pending orders\n\n", .{});
    }

    // Example 2: Complex filter with AND
    {
        std.debug.print("📋 Query 2: Get completed orders over $200\n", .{});
        std.debug.print("   Query.init(client)\n", .{});
        std.debug.print("      .space(\"ecommerce\")\n", .{});
        std.debug.print("      .store(\"orders\")\n", .{});
        std.debug.print("      .where(\"status\", .eq, .{{.string = \"completed\"}})\n", .{});
        std.debug.print("      .And(\"total_amount\", .gt, .{{.float = 200.0}})\n", .{});
        std.debug.print("      .orderBy(\"total_amount\", .desc)\n", .{});
        std.debug.print("      .run()\n\n", .{});

        var query = Query.init(client);
        defer query.deinit();

        _ = query.space("ecommerce")
            .store("orders")
            .where("status", .eq, .{ .string = "completed" })
            .And("total_amount", .gt, .{ .float = 200.0 })
            .orderBy("total_amount", .desc);

        var response = try query.run();
        defer response.deinit();

        // Print result
        std.debug.print("   Status: {s}\n", .{@tagName(response.status)});
        if (response.asString()) |data| {
            std.debug.print("   Result: {s}\n", .{data});
        }
        std.debug.print("   ✓ Found high-value completed orders\n\n", .{});
    }

    // Example 3: With limit and skip
    {
        std.debug.print("📋 Query 3: Get top 3 recent orders\n", .{});
        std.debug.print("   Query.init(client)\n", .{});
        std.debug.print("      .space(\"ecommerce\")\n", .{});
        std.debug.print("      .store(\"orders\")\n", .{});
        std.debug.print("      .orderBy(\"created_at\", .desc)\n", .{});
        std.debug.print("      .limit(3)\n", .{});
        std.debug.print("      .run()\n\n", .{});

        var query = Query.init(client);
        defer query.deinit();

        _ = query.space("ecommerce")
            .store("orders")
            .orderBy("created_at", .desc)
            .limit(3);

        var response = try query.run();
        defer response.deinit();

        // Print result
        std.debug.print("   Status: {s}\n", .{@tagName(response.status)});
        if (response.asString()) |data| {
            std.debug.print("   Result: {s}\n", .{data});
        }
        std.debug.print("   ✓ Found top 3 recent orders\n\n", .{});
    }

    // Example 4: Decode BSON array to Zig struct array
    {
        std.debug.print("📋 Query 4: Decode BSON array to []Order\n", .{});
        std.debug.print("   Query.init(client)\\n", .{});
        std.debug.print("      .space(\"ecommerce\")\\n", .{});
        std.debug.print("      .store(\"orders\")\\n", .{});
        std.debug.print("      .limit(3)\\n", .{});
        std.debug.print("      .run()\\n", .{});
        std.debug.print("   response.decodeAlloc([]Order)  // Array decoding\\n\\n", .{});

        var query = Query.init(client);
        defer query.deinit();

        _ = query.space("ecommerce")
            .store("orders")
            .limit(3);

        var response = try query.run();
        defer response.deinit();

        std.debug.print("   Status: {s}\\n", .{@tagName(response.status)});

        // Decode BSON array to Zig struct array
        if (response.status == .ok and response.data != null) {
            if (response.asString()) |data| {
                std.debug.print("   Data length: {} bytes\\n", .{data.len});
                std.debug.print("   BSON Array Structure:\\n", .{});

                // Analyze first byte (BSON framing)
                if (data.len > 0) {
                    const first_byte = data[0];
                    std.debug.print("      First byte: 0x{x:0>2}\\n", .{first_byte});

                    if (first_byte == 0x5b) {
                        std.debug.print("      Format: [doc1,doc2,doc3] (array of BSON documents)\\n", .{});
                    }
                }

                std.debug.print("      First 64 bytes (hex):\\n      ", .{});
                const show_len = @min(64, data.len);
                for (data[0..show_len], 0..) |byte, i| {
                    if (i > 0 and i % 16 == 0) std.debug.print("\\n      ", .{});
                    std.debug.print("{x:0>2} ", .{byte});
                }
                std.debug.print("\\n\\n", .{});
            }

            // Decode BSON array to Zig struct array
            const orders = response.decodeAlloc([]Order) catch |err| {
                std.debug.print("   ⚠️  Decode error: {}\\n", .{err});
                std.debug.print("      (BSON structure may not match []Order)\\n\\n", .{});
                return;
            };
            defer {
                // Free each order's allocated fields
                for (orders) |order| {
                    response.allocator.free(order.customer_name);
                    response.allocator.free(order.status);
                }
                response.allocator.free(orders);
            }

            std.debug.print("   ✅ Successfully decoded {d} orders:\\n", .{orders.len});
            for (orders, 0..) |order, i| {
                std.debug.print("      [{d}] Order #{d}: {s} - ${d:.2} ({s})\\n", .{
                    i,
                    order.order_id,
                    order.customer_name,
                    order.total_amount,
                    order.status,
                });
            }
            std.debug.print("\\n", .{});
        }
    }

    std.debug.print("✅ Query demonstrations complete!\n\n", .{});
}

fn demonstrateUpdate(client: *ShinyDbClient) !void {
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("3. UPDATE - Modifying Orders\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n\n", .{});

    std.debug.print("🔄 Updating all pending orders to 'processing'\n", .{});
    std.debug.print("   Query.init(client)\n", .{});
    std.debug.print("      .space(\"ecommerce\")\n", .{});
    std.debug.print("      .store(\"orders\")\n", .{});
    std.debug.print("      .where(\"status\", .eq, .{{.string = \"pending\"}})\n", .{});
    std.debug.print("      .update(.{{.status = \"processing\"}})\n", .{});
    std.debug.print("      .run()\n\n", .{});

    const UpdateData = struct {
        status: []const u8,
    };

    var query = Query.init(client);
    defer query.deinit();

    _ = query.space("ecommerce")
        .store("orders")
        .where("status", .eq, .{ .string = "pending" });

    _ = try query.update(UpdateData, .{ .status = "processing" });

    var response = try query.run();
    defer response.deinit();

    // Print result
    std.debug.print("   Status: {s}\n", .{@tagName(response.status)});
    if (response.asString()) |data| {
        std.debug.print("   Result: {s}\n", .{data});
    }
    std.debug.print("   ✓ Updated pending orders to processing\n\n", .{});
    std.debug.print("✅ Update complete!\n\n", .{});
}

fn demonstrateAggregation(client: *ShinyDbClient) !void {
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("4. AGGREGATION - Order Statistics\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n\n", .{});

    // Count total orders
    {
        std.debug.print("📊 Aggregation 1: Count total orders\n", .{});
        std.debug.print("   Query.init(client)\n", .{});
        std.debug.print("      .space(\"ecommerce\")\n", .{});
        std.debug.print("      .store(\"orders\")\n", .{});
        std.debug.print("      .count(\"total_orders\")\n", .{});
        std.debug.print("      .run()\n\n", .{});

        var query = Query.init(client);
        defer query.deinit();

        _ = query.space("ecommerce")
            .store("orders")
            .count("total_orders");

        var response = try query.run();
        defer response.deinit();

        // Print result
        std.debug.print("   Status: {s}\n", .{@tagName(response.status)});
        if (response.asString()) |data| {
            std.debug.print("   Result: {s}\n", .{data});
        }
        std.debug.print("   ✓ Counted total orders\n\n", .{});
    }

    // Sum and average
    {
        std.debug.print("📊 Aggregation 2: Revenue statistics\n", .{});
        std.debug.print("   Query.init(client)\n", .{});
        std.debug.print("      .space(\"ecommerce\")\n", .{});
        std.debug.print("      .store(\"orders\")\n", .{});
        std.debug.print("      .where(\"status\", .eq, .{{.string = \"completed\"}})\n", .{});
        std.debug.print("      .sum(\"total_revenue\", \"total_amount\")\n", .{});
        std.debug.print("      .avg(\"avg_order_value\", \"total_amount\")\n", .{});
        std.debug.print("      .count(\"completed_orders\")\n", .{});
        std.debug.print("      .run()\n\n", .{});

        var query = Query.init(client);
        defer query.deinit();

        _ = query.space("ecommerce")
            .store("orders")
            .where("status", .eq, .{ .string = "completed" })
            .sum("total_revenue", "total_amount")
            .avg("avg_order_value", "total_amount")
            .count("completed_orders");

        var response = try query.run();
        defer response.deinit();

        // Print result
        std.debug.print("   Status: {s}\n", .{@tagName(response.status)});
        if (response.asString()) |data| {
            std.debug.print("   Result: {s}\n", .{data});
        }
        std.debug.print("   ✓ Calculated revenue statistics\n\n", .{});
    }

    // Group by status
    {
        std.debug.print("📊 Aggregation 3: Orders by status\n", .{});
        std.debug.print("   Query.init(client)\n", .{});
        std.debug.print("      .space(\"ecommerce\")\n", .{});
        std.debug.print("      .store(\"orders\")\n", .{});
        std.debug.print("      .groupBy(\"status\")\n", .{});
        std.debug.print("      .count(\"order_count\")\n", .{});
        std.debug.print("      .sum(\"total_value\", \"total_amount\")\n", .{});
        std.debug.print("      .run()\n\n", .{});

        var query = Query.init(client);
        defer query.deinit();

        _ = query.space("ecommerce")
            .store("orders")
            .groupBy("status")
            .count("order_count")
            .sum("total_value", "total_amount");

        var response = try query.run();
        defer response.deinit();

        // Print result
        std.debug.print("   Status: {s}\n", .{@tagName(response.status)});
        if (response.asString()) |data| {
            std.debug.print("   Result: {s}\n", .{data});
        }
        std.debug.print("   ✓ Grouped orders by status\n\n", .{});
    }

    std.debug.print("✅ Aggregation demonstrations complete!\n\n", .{});
}

fn demonstrateDelete(client: *ShinyDbClient) !void {
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("5. DELETE - Removing Orders\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n\n", .{});

    std.debug.print("🗑️  Deleting orders with amount less than $100\n", .{});
    std.debug.print("   Query.init(client)\n", .{});
    std.debug.print("      .space(\"ecommerce\")\n", .{});
    std.debug.print("      .store(\"orders\")\n", .{});
    std.debug.print("      .where(\"total_amount\", .lt, .{{.float = 100.0}})\n", .{});
    std.debug.print("      .delete()\n", .{});
    std.debug.print("      .run()\n\n", .{});

    var query = Query.init(client);
    defer query.deinit();

    _ = query.space("ecommerce")
        .store("orders")
        .where("total_amount", .lt, .{ .float = 100.0 })
        .delete();

    var response = try query.run();
    defer response.deinit();

    // Print result
    std.debug.print("   Status: {s}\n", .{@tagName(response.status)});
    if (response.asString()) |data| {
        std.debug.print("   Result: {s}\n", .{data});
    }
    std.debug.print("   ✓ Deleted low-value orders\n\n", .{});
    std.debug.print("✅ Delete complete!\n\n", .{});
}


