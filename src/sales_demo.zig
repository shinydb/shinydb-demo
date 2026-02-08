const std = @import("std");
const shinydb = @import("shinydb_zig_client");
const Query = shinydb.Query;
const ShinyDbClient = shinydb.ShinyDbClient;

// Import models from model folder
const Order = @import("./model/Order.zig").Order;
const Customer = @import("./model/Customer.zig").Customer;
const Product = @import("./model/Product.zig").Product;
const Employee = @import("./model/Employee.zig").Employee;
const ProductCategory = @import("./model/ProductCategory.zig").ProductCategory;
const ProductSubCategory = @import("./model/ProductSubCategory.zig").ProductSubCategory;
const Vendor = @import("./model/Vendor.zig").Vendor;
const VendorProduct = @import("./model/VendorProduct.zig").VendorProduct;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║   ShinyDb Query API Demo - AdventureWorks Sales Data    ║\n", .{});
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

    // Run sales data demos
    try runSalesDemo(client);

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                     Demo Complete!                       ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
}

fn runSalesDemo(client: *ShinyDbClient) !void {
    // 1. QUERY: Simple reads from different stores
    try queryOrders(client);

    // 2. QUERY: Customer information
    try queryCustomers(client);

    // 3. QUERY: Product catalog
    try queryProducts(client);

    // 4. QUERY: Employee data
    try queryEmployees(client);

    // 5. QUERY: Vendors and products
    try queryVendors(client);

    // 6. QUERY: Advanced filtering
    try advancedQueries(client);
}

fn queryOrders(client: *ShinyDbClient) !void {
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("1. ORDERS - Querying Sales Orders\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n\n", .{});

    // Count total orders
    {
        std.debug.print("📊 Query 1: Count total orders\n", .{});
        std.debug.print("   Query.init(client)\n", .{});
        std.debug.print("      .space(\"sales\")\n", .{});
        std.debug.print("      .store(\"orders\")\n", .{});
        std.debug.print("      .count()\n", .{});
        std.debug.print("      .run()\n\n", .{});

        var query = Query.init(client);
        defer query.deinit();

        _ = query.space("sales")
            .store("orders")
            .count("total");

        if (query.run()) |response| {
            defer @constCast(&response).deinit();
            std.debug.print("   ✓ Query executed successfully\n", .{});
            if (response.data) |data| {
                std.debug.print("   Result: {s}\n\n", .{data});
            }
        } else |err| {
            std.debug.print("   ⚠ Query failed: {}\n\n", .{err});
        }
    }

    // Sum total due amounts
    {
        std.debug.print("📊 Query 2: Sum of all order totals (TotalDue)\n", .{});
        std.debug.print("   Query.init(client)\n", .{});
        std.debug.print("      .space(\"sales\")\n", .{});
        std.debug.print("      .store(\"orders\")\n", .{});
        std.debug.print("      .sum(\"TotalDue\")\n", .{});
        std.debug.print("      .run()\n\n", .{});

        var query = Query.init(client);
        defer query.deinit();

        _ = query.space("sales")
            .store("orders")
            .sum("total", "TotalDue");

        if (query.run()) |response| {
            defer @constCast(&response).deinit();
            std.debug.print("   ✓ Query executed successfully\n", .{});
            if (response.data) |data| {
                std.debug.print("   Result: {s}\n\n", .{data});
            }
        } else |err| {
            std.debug.print("   ⚠ Query failed: {}\n\n", .{err});
        }
    }

    // Get orders with filters
    {
        std.debug.print("📋 Query 3: Orders with high total (TotalDue > 1000)\n", .{});
        std.debug.print("   Query.init(client)\n", .{});
        std.debug.print("      .space(\"sales\")\n", .{});
        std.debug.print("      .store(\"orders\")\n", .{});
        std.debug.print("      .where(\"TotalDue\", .gt, {{.float = 1000.0}})\n", .{});
        std.debug.print("      .limit(5)\n", .{});
        std.debug.print("      .run()\n\n", .{});

        var query = Query.init(client);
        defer query.deinit();

        _ = query.space("sales")
            .store("orders")
            .where("TotalDue", .gt, .{ .float = 1000.0 })
            .limit(5);

        if (query.run()) |response| {
            defer @constCast(&response).deinit();
            std.debug.print("   ✓ Query executed successfully\n", .{});
            if (response.data) |data| {
                std.debug.print("   Result (showing first 5): {s}\n\n", .{data});
            }
        } else |err| {
            std.debug.print("   ⚠ Query failed: {}\n\n", .{err});
        }
    }

    std.debug.print("✅ Orders queries complete!\n\n", .{});
}

fn queryCustomers(client: *ShinyDbClient) !void {
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("2. CUSTOMERS - Querying Customer Data\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n\n", .{});

    // Count customers
    {
        std.debug.print("👥 Query 1: Count total customers\n", .{});
        std.debug.print("   Query.init(client)\n", .{});
        std.debug.print("      .space(\"sales\")\n", .{});
        std.debug.print("      .store(\"customers\")\n", .{});
        std.debug.print("      .count()\n", .{});
        std.debug.print("      .run()\n\n", .{});

        var query = Query.init(client);
        defer query.deinit();

        _ = query.space("sales")
            .store("customers")
            .count("total");

        if (query.run()) |response| {
            defer @constCast(&response).deinit();
            std.debug.print("   ✓ Query executed successfully\n", .{});
            if (response.data) |data| {
                std.debug.print("   Result: {s}\n\n", .{data});
            }
        } else |err| {
            std.debug.print("   ⚠ Query failed: {}\n\n", .{err});
        }
    }

    // Get sample customers
    {
        std.debug.print("👥 Query 2: Get sample customers\n", .{});
        std.debug.print("   Query.init(client)\n", .{});
        std.debug.print("      .space(\"sales\")\n", .{});
        std.debug.print("      .store(\"customers\")\n", .{});
        std.debug.print("      .limit(10)\n", .{});
        std.debug.print("      .run()\n\n", .{});

        var query = Query.init(client);
        defer query.deinit();

        _ = query.space("sales")
            .store("customers")
            .limit(10);

        if (query.run()) |response| {
            defer @constCast(&response).deinit();
            std.debug.print("   ✓ Query executed successfully\n", .{});
            if (response.data) |data| {
                std.debug.print("   Result (showing first 10): {s}\n\n", .{data});
            }
        } else |err| {
            std.debug.print("   ⚠ Query failed: {}\n\n", .{err});
        }
    }

    std.debug.print("✅ Customers queries complete!\n\n", .{});
}

fn queryProducts(client: *ShinyDbClient) !void {
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("3. PRODUCTS - Querying Product Catalog\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n\n", .{});

    // Count products
    {
        std.debug.print("📦 Query 1: Count total products\n", .{});
        std.debug.print("   Query.init(client)\n", .{});
        std.debug.print("      .space(\"sales\")\n", .{});
        std.debug.print("      .store(\"products\")\n", .{});
        std.debug.print("      .count()\n", .{});
        std.debug.print("      .run()\n\n", .{});

        var query = Query.init(client);
        defer query.deinit();

        _ = query.space("sales")
            .store("products")
            .count("total");

        if (query.run()) |response| {
            defer @constCast(&response).deinit();
            std.debug.print("   ✓ Query executed successfully\n", .{});
            if (response.data) |data| {
                std.debug.print("   Result: {s}\n\n", .{data});
            }
        } else |err| {
            std.debug.print("   ⚠ Query failed: {}\n\n", .{err});
        }
    }

    // Count product categories
    {
        std.debug.print("📂 Query 2: Count product categories\n", .{});
        std.debug.print("   Query.init(client)\n", .{});
        std.debug.print("      .space(\"sales\")\n", .{});
        std.debug.print("      .store(\"productcategories\")\n", .{});
        std.debug.print("      .count()\n", .{});
        std.debug.print("      .run()\n\n", .{});

        var query = Query.init(client);
        defer query.deinit();

        _ = query.space("sales")
            .store("productcategories")
            .count("total");

        if (query.run()) |response| {
            defer @constCast(&response).deinit();
            std.debug.print("   ✓ Query executed successfully\n", .{});
            if (response.data) |data| {
                std.debug.print("   Result: {s}\n\n", .{data});
            }
        } else |err| {
            std.debug.print("   ⚠ Query failed: {}\n\n", .{err});
        }
    }

    // Get sample products
    {
        std.debug.print("📦 Query 3: Get sample products (first 5)\n", .{});
        std.debug.print("   Query.init(client)\n", .{});
        std.debug.print("      .space(\"sales\")\n", .{});
        std.debug.print("      .store(\"products\")\n", .{});
        std.debug.print("      .limit(5)\n", .{});
        std.debug.print("      .run()\n\n", .{});

        var query = Query.init(client);
        defer query.deinit();

        _ = query.space("sales")
            .store("products")
            .limit(5);

        if (query.run()) |response| {
            defer @constCast(&response).deinit();
            std.debug.print("   ✓ Query executed successfully\n\n", .{});
            if (response.data) |data| {
                std.debug.print("   Result: {s}\n\n", .{data});
            }
        } else |err| {
            std.debug.print("   ⚠ Query failed: {}\n\n", .{err});
        }
    }

    std.debug.print("✅ Products queries complete!\n\n", .{});
}

fn queryEmployees(client: *ShinyDbClient) !void {
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("4. EMPLOYEES - Querying Employee Data\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n\n", .{});

    // Count employees
    {
        std.debug.print("👔 Query 1: Count total employees\n", .{});
        std.debug.print("   Query.init(client)\n", .{});
        std.debug.print("      .space(\"sales\")\n", .{});
        std.debug.print("      .store(\"employees\")\n", .{});
        std.debug.print("      .count()\n", .{});
        std.debug.print("      .run()\n\n", .{});

        var query = Query.init(client);
        defer query.deinit();

        _ = query.space("sales")
            .store("employees")
            .count("total");

        if (query.run()) |response| {
            defer @constCast(&response).deinit();
            std.debug.print("   ✓ Query executed successfully\n", .{});
            if (response.data) |data| {
                std.debug.print("   Result: {s}\n\n", .{data});
            }
        } else |err| {
            std.debug.print("   ⚠ Query failed: {}\n\n", .{err});
        }
    }

    // Get sample employees
    {
        std.debug.print("👔 Query 2: Get sample employees\n", .{});
        std.debug.print("   Query.init(client)\n", .{});
        std.debug.print("      .space(\"sales\")\n", .{});
        std.debug.print("      .store(\"employees\")\n", .{});
        std.debug.print("      .limit(10)\n", .{});
        std.debug.print("      .run()\n\n", .{});

        var query = Query.init(client);
        defer query.deinit();

        _ = query.space("sales")
            .store("employees")
            .limit(10);

        if (query.run()) |response| {
            defer @constCast(&response).deinit();
            std.debug.print("   ✓ Query executed successfully\n", .{});
            if (response.data) |data| {
                std.debug.print("   Result: {s}\n\n", .{data});
            }
        } else |err| {
            std.debug.print("   ⚠ Query failed: {}\n\n", .{err});
        }
    }

    std.debug.print("✅ Employees queries complete!\n\n", .{});
}

fn queryVendors(client: *ShinyDbClient) !void {
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("5. VENDORS - Querying Vendor and Supplier Data\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n\n", .{});

    // Count vendors
    {
        std.debug.print("🏢 Query 1: Count total vendors\n", .{});
        std.debug.print("   Query.init(client)\n", .{});
        std.debug.print("      .space(\"sales\")\n", .{});
        std.debug.print("      .store(\"vendors\")\n", .{});
        std.debug.print("      .count()\n", .{});
        std.debug.print("      .run()\n\n", .{});

        var query = Query.init(client);
        defer query.deinit();

        _ = query.space("sales")
            .store("vendors")
            .count("total");

        if (query.run()) |response| {
            defer @constCast(&response).deinit();
            std.debug.print("   ✓ Query executed successfully\n", .{});
            if (response.data) |data| {
                std.debug.print("   Result: {s}\n\n", .{data});
            }
        } else |err| {
            std.debug.print("   ⚠ Query failed: {}\n\n", .{err});
        }
    }

    // Count vendor products
    {
        std.debug.print("🔗 Query 2: Count vendor-product relationships\n", .{});
        std.debug.print("   Query.init(client)\n", .{});
        std.debug.print("      .space(\"sales\")\n", .{});
        std.debug.print("      .store(\"vendorproducts\")\n", .{});
        std.debug.print("      .count()\n", .{});
        std.debug.print("      .run()\n\n", .{});

        var query = Query.init(client);
        defer query.deinit();

        _ = query.space("sales")
            .store("vendorproducts")
            .count("total");

        if (query.run()) |response| {
            defer @constCast(&response).deinit();
            std.debug.print("   ✓ Query executed successfully\n", .{});
            if (response.data) |data| {
                std.debug.print("   Result: {s}\n\n", .{data});
            }
        } else |err| {
            std.debug.print("   ⚠ Query failed: {}\n\n", .{err});
        }
    }

    std.debug.print("✅ Vendors queries complete!\n\n", .{});
}

fn advancedQueries(client: *ShinyDbClient) !void {
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("6. ADVANCED QUERIES - Complex Data Operations\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n\n", .{});

    // High-value orders
    {
        std.debug.print("💰 Query 1: High-value orders (TotalDue >= 5000, limit 20)\n", .{});
        std.debug.print("   Query.init(client)\n", .{});
        std.debug.print("      .space(\"sales\")\n", .{});
        std.debug.print("      .store(\"orders\")\n", .{});
        std.debug.print("      .where(\"TotalDue\", .gte, {{.float = 5000.0}})\n", .{});
        std.debug.print("      .orderBy(\"TotalDue\", .desc)\n", .{});
        std.debug.print("      .limit(20)\n", .{});
        std.debug.print("      .run()\n\n", .{});

        var query = Query.init(client);
        defer query.deinit();

        _ = query.space("sales")
            .store("orders")
            .where("TotalDue", .gte, .{ .float = 5000.0 })
            .orderBy("TotalDue", .desc)
            .limit(20);

        if (query.run()) |response| {
            defer @constCast(&response).deinit();
            std.debug.print("   ✓ Query executed successfully\n", .{});
            if (response.data) |data| {
                std.debug.print("   Result: {s}\n\n", .{data});
            }
        } else |err| {
            std.debug.print("   ⚠ Query failed: {}\n\n", .{err});
        }
    }

    // Orders with pagination
    {
        std.debug.print("📄 Query 2: Orders with pagination (offset 10, limit 15)\n", .{});
        std.debug.print("   Query.init(client)\n", .{});
        std.debug.print("      .space(\"sales\")\n", .{});
        std.debug.print("      .store(\"orders\")\n", .{});
        std.debug.print("      .skip(10)\n", .{});
        std.debug.print("      .limit(15)\n", .{});
        std.debug.print("      .run()\n\n", .{});

        var query = Query.init(client);
        defer query.deinit();

        _ = query.space("sales")
            .store("orders")
            .skip(10)
            .limit(15);

        if (query.run()) |response| {
            defer @constCast(&response).deinit();
            std.debug.print("   ✓ Query executed successfully\n", .{});
            if (response.data) |data| {
                std.debug.print("   Result: {s}\n\n", .{data});
            }
        } else |err| {
            std.debug.print("   ⚠ Query failed: {}\n\n", .{err});
        }
    }

    // Average order value
    {
        std.debug.print("📊 Query 3: Average order value across all orders\n", .{});
        std.debug.print("   Query.init(client)\n", .{});
        std.debug.print("      .space(\"sales\")\n", .{});
        std.debug.print("      .store(\"orders\")\n", .{});
        std.debug.print("      .avg(\"TotalDue\")\n", .{});
        std.debug.print("      .run()\n\n", .{});

        var query = Query.init(client);
        defer query.deinit();

        _ = query.space("sales")
            .store("orders")
            .avg("average", "TotalDue");

        if (query.run()) |response| {
            defer @constCast(&response).deinit();
            std.debug.print("   ✓ Query executed successfully\n", .{});
            if (response.data) |data| {
                std.debug.print("   Result: {s}\n\n", .{data});
            }
        } else |err| {
            std.debug.print("   ⚠ Query failed: {}\n\n", .{err});
        }
    }

    std.debug.print("✅ Advanced queries complete!\n\n", .{});
}

