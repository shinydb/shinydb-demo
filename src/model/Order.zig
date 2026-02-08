const std = @import("std");

pub const SalesOrderDetail = struct {
    SalesOrderDetailID: u32,
    ProductID: u32,
    OrderQty: u32,
    UnitPrice: f64,
    UnitPriceDiscount: f64,
    LineTotal: f64,
};

pub const Order = struct {
    SalesOrderID: u32,
    OrderDate: []const u8,
    DueDate: []const u8,
    ShipDate: []const u8,
    EmployeeID: u32,
    CustomerID: u32,
    SubTotal: f64,
    TaxAmt: f64,
    Freight: f64,
    TotalDue: f64,
    SalesOrderDetails: []SalesOrderDetail,
};
