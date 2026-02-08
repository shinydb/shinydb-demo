const std = @import("std");
pub const Vendor = struct {
    VendorID: u32,
    VendorName: []const u8,
    AccountNumber: []const u8,
    CreditRating: u8,
    ActiveFlag: u8,
};
