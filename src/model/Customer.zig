const std = @import("std");
pub const Customer = struct {
    CustomerID: u32,
    FirstName: []const u8,
    LastName: []const u8,
    FullName: []const u8,
};
