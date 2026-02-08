const std = @import("std");
pub const Employee = struct {
    EmployeeID: u32,
    ManagerID: ?u32,
    FirstName: []const u8,
    LastName: []const u8,
    FullName: []const u8,
    JobTitle: []const u8,
    OrganizationLevel: u8,
    MaritalStatus: []const u8,
    Gender: []const u8,
    Territory: ?[]const u8,
    Country: ?[]const u8,
    Group: ?[]const u8,
};
