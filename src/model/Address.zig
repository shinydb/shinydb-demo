const std = @import("std");
pub const Address = struct {
    Street: []const u8,
    City: []const u8,
    State: []const u8,
    ZipCode: []const u8,
    Country: []const u8,
};
