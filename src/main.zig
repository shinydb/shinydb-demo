const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const shinydb = @import("shinydb_zig_client");
const ShinyDbClient = shinydb.ShinyDbClient;
const Query = shinydb.Query;
const proto = shinydb.proto;
const DocType = proto.DocType;

// Import model types
const Order = @import("./model/Order.zig").Order;
const Customer = @import("./model/Customer.zig").Customer;
const Product = @import("./model/Product.zig").Product;
const Employee = @import("./model/Employee.zig").Employee;
const ProductCategory = @import("./model/ProductCategory.zig").ProductCategory;
const ProductSubCategory = @import("./model/ProductSubCategory.zig").ProductSubCategory;
const Vendor = @import("./model/Vendor.zig").Vendor;
const VendorProduct = @import("./model/VendorProduct.zig").VendorProduct;
const Address = @import("./model/Address.zig").Address;

const json_dir = "./src/json/"; // Relative to project root

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse command line args
    var host: []const u8 = "127.0.0.1";
    var port: u16 = 23469;
    var command: []const u8 = "help";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--host") and i + 1 < args.len) {
            host = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            port = std.fmt.parseInt(u16, args[i + 1], 10) catch 23469;
            i += 1;
        } else {
            command = args[i];
        }
    }

    if (std.mem.eql(u8, command, "help")) {
        printHelp();
        return;
    }

    // Setup I/O
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Connect to ShinyDb
    const client = try ShinyDbClient.init(allocator, io);
    defer client.deinit();

    try client.connect(host, port);
    defer client.disconnect();

    std.debug.print("Connected to ShinyDb at {s}:{d}\n", .{ host, port });

    // Authenticate as admin
    if (client.authenticate("admin", "admin")) |result| {
        var auth = result;
        defer auth.deinit();
        std.debug.print("Authenticated as admin (role: {s})\n", .{auth.role.toString()});
    } else |err| {
        std.debug.print("Authentication failed: {}. Some operations may not work.\n", .{err});
    }

    if (std.mem.eql(u8, command, "setup")) {
        try setupSchema(client);
    } else if (std.mem.eql(u8, command, "load")) {
        try loadAllData(allocator, client, io);
        try flushData(client);
    } else if (std.mem.eql(u8, command, "load-small")) {
        try loadSmallDataset(allocator, client, io);
        try flushData(client);
    } else if (std.mem.eql(u8, command, "cleanup")) {
        try cleanup(client);
    } else if (std.mem.eql(u8, command, "all")) {
        try setupSchema(client);
        try loadAllData(allocator, client, io);
        try flushData(client);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printHelp();
    }
}

fn printHelp() void {
    const help =
        \\salesdb-loader - Load AdventureWorks sales data into ShinyDb
        \\
        \\USAGE:
        \\    salesdb-loader [OPTIONS] <COMMAND>
        \\
        \\OPTIONS:
        \\    --host <HOST>    Server host (default: 127.0.0.1)
        \\    --port <PORT>    Server port (default: 23469)
        \\
        \\COMMANDS:
        \\    setup            Create sales space and stores (orders, customers,
        \\                     employees, products, productcategories,
        \\                     productsubcategories, vendors, vendorproducts)
        \\    load             Load all data from JSON files
        \\    load-small       Load a small subset (100 orders) for quick testing
        \\    cleanup          Drop the sales space
        \\    all              Setup + load all data
        \\    help             Show this help
        \\
        \\EXAMPLES:
        \\    salesdb-loader setup
        \\    salesdb-loader load
        \\    salesdb-loader all
        \\
        \\After loading, test with:
        \\    shinydb-cli aggregate sales.orders --count
        \\    shinydb-cli aggregate sales.orders --sum TotalDue --avg SubTotal
        \\    shinydb-cli aggregate sales.orders --count --sum TotalDue --group-by EmployeeID
        \\
    ;
    std.debug.print("{s}", .{help});
}

fn setupSchema(client: *ShinyDbClient) !void {
    std.debug.print("\n=== Setting up schema ===\n", .{});

    // Create space
    std.debug.print("Creating space 'sales'...\n", .{});
    client.create(proto.Space{
        .id = 0,
        .ns = "sales",
        .description = "Sales data space",
    }) catch |err| {
        std.debug.print("  Space may already exist ({}), continuing...\n", .{err});
    };

    // Create stores
    const stores = [_][]const u8{
        "orders",
        "customers",
        "employees",
        "products",
        "productcategories",
        "productsubcategories",
        "vendors",
        "vendorproducts",
        "addresses",
    };

    for (stores) |store_name| {
        std.debug.print("Creating store '{s}'...\n", .{store_name});
        const ns = try std.fmt.allocPrint(client.allocator, "sales.{s}", .{store_name});
        defer client.allocator.free(ns);

        client.create(proto.Store{
            .id = 0,
            .store_id = 0,
            .ns = ns,
            .description = "Store",
        }) catch |err| {
            std.debug.print("  Store may already exist ({}), continuing...\n", .{err});
        };
    }

    std.debug.print("Schema setup complete!\n", .{});
}

fn loadAllData(allocator: std.mem.Allocator, client: *ShinyDbClient, io: Io) !void {
    std.debug.print("\n=== Loading data ===\n", .{});

    // Load each dataset with appropriate struct type
    try loadJsonFile(Customer, allocator, client, "customers", json_dir ++ "customers.json", io);
    try loadJsonFile(Employee, allocator, client, "employees", json_dir ++ "employees.json", io);
    try loadJsonFile(Product, allocator, client, "products", json_dir ++ "products.json", io);
    try loadJsonFile(ProductCategory, allocator, client, "productcategories", json_dir ++ "productcategories.json", io);
    try loadJsonFile(ProductSubCategory, allocator, client, "productsubcategories", json_dir ++ "productsubcategories.json", io);
    try loadJsonFile(Vendor, allocator, client, "vendors", json_dir ++ "vendors.json", io);
    try loadJsonFile(VendorProduct, allocator, client, "vendorproducts", json_dir ++ "vendorproduct.json", io);
    try loadJsonFile(Address, allocator, client, "addresses", json_dir ++ "addresses.json", io);
    try loadJsonFile(Order, allocator, client, "orders", json_dir ++ "orders.json", io);

    std.debug.print("\nData loading complete!\n", .{});
}

fn loadSmallDataset(allocator: std.mem.Allocator, client: *ShinyDbClient, io: Io) !void {
    std.debug.print("\n=== Loading small dataset ===\n", .{});

    // Load smaller files fully with appropriate struct types
    try loadJsonFile(Customer, allocator, client, "customers", json_dir ++ "customers.json", io);
    try loadJsonFile(Employee, allocator, client, "employees", json_dir ++ "employees.json", io);
    try loadJsonFile(Product, allocator, client, "products", json_dir ++ "products.json", io);
    try loadJsonFile(ProductCategory, allocator, client, "productcategories", json_dir ++ "productcategories.json", io);
    try loadJsonFile(ProductSubCategory, allocator, client, "productsubcategories", json_dir ++ "productsubcategories.json", io);
    try loadJsonFile(Vendor, allocator, client, "vendors", json_dir ++ "vendors.json", io);
    try loadJsonFile(VendorProduct, allocator, client, "vendorproducts", json_dir ++ "vendorproduct.json", io);
    try loadJsonFile(Address, allocator, client, "addresses", json_dir ++ "addresses.json", io);

    // Load only first 100 orders
    try loadJsonFileLimit(Order, allocator, client, "orders", json_dir ++ "orders.json", 100, io);

    std.debug.print("\nSmall dataset loading complete!\n", .{});
}

fn loadJsonFile(comptime T: type, allocator: std.mem.Allocator, client: *ShinyDbClient, store_name: []const u8, file_path: []const u8, io: Io) !void {
    return loadJsonFileLimit(T, allocator, client, store_name, file_path, null, io);
}

fn loadJsonFileLimit(comptime T: type, allocator: std.mem.Allocator, client: *ShinyDbClient, store_name: []const u8, file_path: []const u8, limit: ?usize, io: Io) !void {
    std.debug.print("Loading {s}...", .{store_name});

    // Read file
    const content = Dir.readFileAlloc(.cwd(), io, file_path, allocator, @enumFromInt(100 * 1024 * 1024)) catch |err| {
        std.debug.print(" Error reading file: {} from {s}\n", .{ err, file_path });
        return;
    };
    defer allocator.free(content);

    // Parse JSON directly as array of specific struct type T
    const parsed = std.json.parseFromSlice([]T, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print(" Error parsing JSON: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    const items = parsed.value;
    const max_items = if (limit) |l| @min(l, items.len) else items.len;

    var loaded: usize = 0;
    var errors: usize = 0;

    for (items[0..max_items]) |item| {
        // Create query for this document
        var query = Query.init(client);
        defer query.deinit();

        // Try to create the document using Query builder with typed struct
        if (query.space("sales").store(store_name).create(item)) |q| {
            if (q.run()) |response| {
                defer @constCast(&response).deinit();
                loaded += 1;
            } else |_| {
                errors += 1;
            }
        } else |_| {
            errors += 1;
        }

        // Progress indicator
        if (loaded % 1000 == 0) {
            std.debug.print(".", .{});
        }
    }

    std.debug.print(" {d} loaded", .{loaded});
    if (errors > 0) {
        std.debug.print(" ({d} errors)", .{errors});
    }
    std.debug.print("\n", .{});
}

fn cleanup(client: *ShinyDbClient) !void {
    std.debug.print("\n=== Cleaning up ===\n", .{});

    std.debug.print("Dropping space 'sales'...\n", .{});
    client.drop(DocType.Space, "sales") catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return;
    };

    std.debug.print("Cleanup complete!\n", .{});
}

fn flushData(client: *ShinyDbClient) !void {
    std.debug.print("\nFlushing data to disk...\n", .{});
    client.flush() catch |err| {
        std.debug.print("Flush failed: {} (data is still in memory and queryable)\n", .{err});
        return;
    };
    std.debug.print("Data flushed successfully!\n", .{});
}
