const std = @import("std");
pub const Product = struct {
    ProductID: u32,
    ProductNumber: []const u8,
    ProductName: []const u8,
    ModelName: []const u8,
    MakeFlag: u8,
    StandardCost: f64,
    ListPrice: f64,
    SubCategoryID: u32,
};
