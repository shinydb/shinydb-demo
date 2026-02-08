const std = @import("std");
pub const ProductSubCategory = struct {
    SubCategoryID: u32,
    CategoryID: u32,
    SubCategoryName: []const u8,
};
