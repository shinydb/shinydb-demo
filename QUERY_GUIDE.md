# ShinyDb Query Guide — YQL & Builder API

This guide covers both ways to query ShinyDb: the **YQL** text query language (used from the shell or as text strings) and the **Zig Builder API** (used programmatically from Zig applications).

All examples use the **AdventureWorks sales** dataset with these stores:

| Store                     | Description        | Key Fields                                                                            |
| ------------------------- | ------------------ | ------------------------------------------------------------------------------------- |
| `sales.orders`            | Sales orders       | `EmployeeID` (int), `CustomerID` (int), `TotalDue` (float)                            |
| `sales.employees`         | Employees          | `EmployeeID` (int), `Gender` (string), `MaritalStatus` (string), `FirstName` (string) |
| `sales.products`          | Products           | `ProductName` (string), `ListPrice` (float), `SubCategoryID` (int), `MakeFlag` (int)  |
| `sales.customers`         | Customers          | `CustomerID` (int), `Address.City` (string), `Address.State` (string)                 |
| `sales.vendors`           | Vendors            | `VendorName` (string), `ActiveFlag` (int), `CreditRating` (int)                       |
| `sales.productcategories` | Product categories | `CategoryName` (string)                                                               |

---

## Table of Contents

- [1. Count Queries](#1-count-queries)
- [2. Filter — Equality](#2-filter--equality)
- [3. Filter — Comparison Operators](#3-filter--comparison-operators)
- [4. Compound Filters (AND)](#4-compound-filters-and)
- [5. Limit & Skip](#5-limit--skip)
- [6. OrderBy (Sorting)](#6-orderby-sorting)
- [7. Multi-Sort](#7-multi-sort)
- [8. Projection (Select Fields)](#8-projection-select-fields)
- [9. Aggregation — Count](#9-aggregation--count)
- [10. Aggregation — Sum, Avg, Min, Max](#10-aggregation--sum-avg-min-max)
- [11. GroupBy](#11-groupby)
- [12. Filter + GroupBy](#12-filter--groupby)
- [13. $in Operator](#13-in-operator)
- [14. $contains Operator](#14-contains-operator)
- [15. $startsWith Operator](#15-startswith-operator)
- [16. $exists Operator](#16-exists-operator)
- [17. $regex Operator](#17-regex-operator)
- [18. OR Filters](#18-or-filters)
- [19. Range Scans](#19-range-scans)
- [20. Nested Field Access](#20-nested-field-access)
- [Operator Reference](#operator-reference)

---

## 1. Count Queries

Get the number of documents in a store, optionally with a filter.

### YQL

```
space.store.count()
space.store.filter(field = value).count()
```

**Examples:**

```
sales.orders.count()                              → 3806
sales.customers.count()                           → 635
sales.employees.count()                           → 17
sales.orders.filter(EmployeeID = 289).count()     → 348
sales.orders.filter(EmployeeID = 288).count()     → 130
sales.vendors.filter(ActiveFlag = 1).count()      → 100
sales.products.filter(MakeFlag = 1).count()       → 212
sales.orders.filter(CustomerID = 1045).count()    → 12
```

### Builder API (Zig)

Use `.countOnly()` to return only the count (no documents).

```zig
var q = Query.init(client);
_ = q.space("sales").store("orders").countOnly();

// With filter
var q = Query.init(client);
_ = q.space("sales").store("orders")
    .where("EmployeeID", .eq, .{ .int = 289 })
    .countOnly();
```

---

## 2. Filter — Equality

Match documents where a field equals a specific value.

### YQL

```
space.store.filter(field = value).count()
space.store.filter(field = "string_value").count()
```

**Examples:**

```
sales.employees.filter(Gender = "M").count()            → 10
sales.employees.filter(Gender = "F").count()            → 7
sales.employees.filter(EmployeeID = 274).count()        → 1
sales.products.filter(SubCategoryID = 14).count()       → 33
sales.productcategories.filter(CategoryName = "Bikes").count() → 1
```

### Builder API

```zig
// String equality
var q = Query.init(client);
_ = q.space("sales").store("employees")
    .where("Gender", .eq, .{ .string = "M" });

// Integer equality
var q = Query.init(client);
_ = q.space("sales").store("employees")
    .where("EmployeeID", .eq, .{ .int = 274 });
```

---

## 3. Filter — Comparison Operators

Supported operators: `>` (gt), `<` (lt), `>=` (gte), `<=` (lte), `!=` (ne).

### YQL

```
space.store.filter(field > value).count()
space.store.filter(field >= value).count()
space.store.filter(field < value).count()
space.store.filter(field <= value).count()
space.store.filter(field != value).count()
```

**Examples:**

```
sales.orders.filter(TotalDue > 50000).count()      → 621
sales.orders.filter(TotalDue < 100).count()         → 155
sales.orders.filter(TotalDue >= 100000).count()     → 108
sales.products.filter(ListPrice > 1000).count()     → 86
sales.products.filter(ListPrice <= 0).count()       → 0
sales.vendors.filter(CreditRating > 3).count()      → 4
sales.vendors.filter(CreditRating != 1).count()     → 20
```

### Builder API

```zig
// Greater than (float)
_ = q.space("sales").store("orders")
    .where("TotalDue", .gt, .{ .float = 50000 })
    .countOnly();

// Less than or equal (float)
_ = q.space("sales").store("products")
    .where("ListPrice", .lte, .{ .float = 0 })
    .countOnly();

// Not equal (int)
_ = q.space("sales").store("vendors")
    .where("CreditRating", .ne, .{ .int = 1 })
    .countOnly();
```

---

## 4. Compound Filters (AND)

Combine multiple conditions. All must be true.

### YQL

```
space.store.filter(field1 = value1 and field2 = value2).count()
```

**Examples:**

```
sales.orders.filter(EmployeeID = 289 and CustomerID = 1045).count()     → 0
sales.employees.filter(Gender = "M" and MaritalStatus = "M").count()    → 7
sales.employees.filter(Gender = "M" and MaritalStatus = "S").count()    → 3
sales.orders.filter(EmployeeID >= 285 and EmployeeID <= 287).count()    → 164
```

### Builder API

Chain `.@"and"(...)` after `.where(...)`:

```zig
// Two different fields
_ = q.space("sales").store("orders")
    .where("EmployeeID", .eq, .{ .int = 289 })
    .@"and"("CustomerID", .eq, .{ .int = 1045 })
    .countOnly();

// Range on same field
_ = q.space("sales").store("orders")
    .where("EmployeeID", .gte, .{ .int = 285 })
    .@"and"("EmployeeID", .lte, .{ .int = 287 })
    .countOnly();
```

---

## 5. Limit & Skip

Control result pagination.

### YQL

```
space.store.limit(N).count()
space.store.skip(N).count()
```

**Examples:**

```
sales.orders.limit(10).count()        → 10
sales.orders.limit(5).count()         → 5
sales.orders.skip(3800).count()       → 6
sales.customers.limit(100).count()    → 100
```

### Builder API

```zig
_ = q.space("sales").store("orders").limit(10).countOnly();
_ = q.space("sales").store("orders").skip(3800).countOnly();
```

---

## 6. OrderBy (Sorting)

Sort results by a field in ascending or descending order.

### YQL

```
space.store.orderBy(field, asc).limit(N)
space.store.orderBy(field, desc).limit(N)
```

**Examples:**

```
sales.products.orderBy(ListPrice, desc).limit(5)
  → [3578.27, 3578.27, 3578.27, 3578.27, 3578.27]

sales.products.orderBy(ListPrice, asc).limit(5)
  → [2.29, 3.99, 4.99, 4.99, 4.99]

sales.employees.orderBy(EmployeeID, asc).limit(3)
  → [274, 275, 276]

sales.employees.orderBy(EmployeeID, desc).limit(3)
  → [290, 289, 288]
```

### Builder API

```zig
_ = q.space("sales").store("products")
    .orderBy("ListPrice", .desc)
    .limit(5);

_ = q.space("sales").store("employees")
    .orderBy("EmployeeID", .asc)
    .limit(3);
```

---

## 7. Multi-Sort

Sort by multiple fields. The first field is the primary sort key; ties are broken by subsequent fields.

### YQL

```
space.store.orderBy(field1, dir1).orderBy(field2, dir2).limit(N)
```

**Examples:**

```
sales.orders.orderBy(EmployeeID, asc).orderBy(TotalDue, desc).limit(10)
sales.employees.orderBy(Gender, asc).orderBy(EmployeeID, desc).limit(10)
sales.products.orderBy(SubCategoryID, asc).orderBy(ListPrice, desc).limit(10)

// With filter
sales.orders.filter(EmployeeID >= 285).orderBy(EmployeeID, asc).orderBy(TotalDue, asc).limit(20)
```

### Builder API

Chain multiple `.orderBy(...)` calls:

```zig
_ = q.space("sales").store("orders")
    .orderBy("EmployeeID", .asc)
    .orderBy("TotalDue", .desc)
    .limit(10);

// With filter + multi-sort
_ = q.space("sales").store("orders")
    .where("EmployeeID", .gte, .{ .int = 285 })
    .orderBy("EmployeeID", .asc)
    .orderBy("TotalDue", .asc)
    .limit(20);
```

---

## 8. Projection (Select Fields)

Return only specific fields from documents, reducing response size.

### YQL

Use `pluck(field1, field2, ...)` at the end of the query:

```
space.store.filter(field = value).pluck(field1, field2)
```

**Examples:**

```
sales.employees.filter(EmployeeID = 274).pluck(EmployeeID, FullName)
  → Returns only EmployeeID and FullName (no Gender, JobTitle, etc.)

sales.products.filter(SubCategoryID = 14).limit(1).pluck(ProductName, ListPrice)
  → Returns only ProductName and ListPrice

sales.employees.limit(1).pluck(EmployeeID)
  → Returns only EmployeeID

sales.orders.filter(EmployeeID = 289).orderBy(TotalDue, desc).limit(1).pluck(EmployeeID, TotalDue)
  → Returns the highest TotalDue order for employee 289, with only those two fields
```

### Builder API

Use `.select(&.{ "field1", "field2" })`:

```zig
_ = q.space("sales").store("employees")
    .where("EmployeeID", .eq, .{ .int = 274 })
    .select(&.{ "EmployeeID", "FullName" });

_ = q.space("sales").store("orders")
    .where("EmployeeID", .eq, .{ .int = 289 })
    .orderBy("TotalDue", .desc)
    .limit(1)
    .select(&.{ "EmployeeID", "TotalDue" });
```

---

## 9. Aggregation — Count

Count documents using the aggregation pipeline. Returns a named result field.

### YQL

```
space.store.aggregate(alias: count)
space.store.filter(field = value).aggregate(alias: count)
```

**Examples:**

```
sales.orders.aggregate(total: count)                                    → { "total": 3806 }
sales.orders.filter(EmployeeID = 289).aggregate(total: count)          → { "total": 348 }
sales.customers.aggregate(total: count)                                 → { "total": 635 }
sales.products.filter(MakeFlag = 1).aggregate(n: count)                → { "n": 212 }
```

### Builder API

Use `.count("alias")`:

```zig
_ = q.space("sales").store("orders").count("total");

_ = q.space("sales").store("orders")
    .where("EmployeeID", .eq, .{ .int = 289 })
    .count("total");
```

---

## 10. Aggregation — Sum, Avg, Min, Max

Compute numeric aggregations on a field.

### YQL

```
space.store.aggregate(alias: sum(field))
space.store.aggregate(alias: avg(field))
space.store.aggregate(alias: min(field))
space.store.aggregate(alias: max(field))
```

**Examples:**

```
sales.orders.aggregate(total: sum(TotalDue))          → 90775446.9931
sales.orders.aggregate(avg_total: avg(TotalDue))      → 23850.6167
sales.orders.aggregate(min_total: min(TotalDue))      → 1.5183
sales.orders.aggregate(max_total: max(TotalDue))      → 187487.825

// With filter
sales.orders.filter(EmployeeID = 289).aggregate(revenue: sum(TotalDue))  → 9585124.9477

// Products
sales.products.aggregate(avg_price: avg(ListPrice))   → 744.5952
sales.products.aggregate(max_price: max(ListPrice))   → 3578.27
sales.products.aggregate(min_price: min(ListPrice))   → 2.29
```

### Builder API

Use `.sum("alias", "field")`, `.avg(...)`, `.min(...)`, `.max(...)`:

```zig
_ = q.space("sales").store("orders").sum("total", "TotalDue");
_ = q.space("sales").store("orders").avg("avg_total", "TotalDue");
_ = q.space("sales").store("orders").min("min_total", "TotalDue");
_ = q.space("sales").store("orders").max("max_total", "TotalDue");

// With filter
_ = q.space("sales").store("orders")
    .where("EmployeeID", .eq, .{ .int = 289 })
    .sum("revenue", "TotalDue");
```

---

## 11. GroupBy

Group documents by one or more fields and apply aggregations per group.

### YQL

```
space.store.groupBy(field).aggregate(alias: count)
space.store.groupBy(field1, field2).aggregate(alias: count)
space.store.groupBy(field).aggregate(n: count, total: sum(field))
```

**Examples:**

```
sales.orders.groupBy(EmployeeID).aggregate(n: count)
  → 17 groups (one per employee)

sales.employees.groupBy(Gender).aggregate(n: count)
  → 2 groups (M, F)

sales.employees.groupBy(Gender, MaritalStatus).aggregate(n: count)
  → 4 groups (M+M, M+S, F+M, F+S)

sales.orders.groupBy(EmployeeID).aggregate(n: count, total: sum(TotalDue))
  → 17 groups with count and total revenue per employee

sales.vendors.groupBy(CreditRating).aggregate(n: count)
  → 5 groups
```

### Builder API

Chain `.groupBy("field")` and then aggregation calls:

```zig
_ = q.space("sales").store("orders")
    .groupBy("EmployeeID")
    .count("n");

// Multiple groupBy fields
_ = q.space("sales").store("employees")
    .groupBy("Gender")
    .groupBy("MaritalStatus")
    .count("n");

// GroupBy + multiple aggregations
_ = q.space("sales").store("orders")
    .groupBy("EmployeeID")
    .count("n")
    .sum("total", "TotalDue");
```

---

## 12. Filter + GroupBy

Apply a filter before grouping.

### YQL

```
space.store.filter(field > value).groupBy(field).aggregate(n: count)
```

**Examples:**

```
sales.orders.filter(TotalDue > 10000).groupBy(EmployeeID).aggregate(n: count)
  → 17 groups

sales.products.filter(ListPrice > 0).groupBy(SubCategoryID).aggregate(n: count, avg_price: avg(ListPrice))
  → 37 groups

sales.orders.filter(EmployeeID = 289).groupBy(CustomerID).aggregate(n: count, total: sum(TotalDue))
  → 62 groups (customers who ordered from employee 289)
```

### Builder API

```zig
_ = q.space("sales").store("orders")
    .where("TotalDue", .gt, .{ .float = 10000 })
    .groupBy("EmployeeID")
    .count("n");

_ = q.space("sales").store("products")
    .where("ListPrice", .gt, .{ .float = 0 })
    .groupBy("SubCategoryID")
    .count("n")
    .avg("avg_price", "ListPrice");
```

---

## 13. $in Operator

Match documents where a field's value is in a given list.

### YQL

```
space.store.filter(field in [value1, value2]).count()
space.store.filter(field in ["str1", "str2"]).count()
```

**Examples:**

```
sales.orders.filter(EmployeeID in [289, 288]).count()          → 478
sales.orders.filter(EmployeeID in [289, 287, 285]).count()     → 403
sales.products.filter(SubCategoryID in [1, 2, 14]).count()     → 108
sales.employees.filter(Gender in ["M"]).count()                → 10
sales.employees.filter(MaritalStatus in ["S", "M"]).count()    → 17
```

### Builder API

Pass `.array` as the value:

```zig
const Value = shinydb.yql.Value;

_ = q.space("sales").store("orders")
    .where("EmployeeID", .in, .{ .array = @constCast(&[_]Value{
        .{ .int = 289 },
        .{ .int = 288 },
    }) })
    .countOnly();

_ = q.space("sales").store("employees")
    .where("Gender", .in, .{ .array = @constCast(&[_]Value{
        .{ .string = "M" },
    }) })
    .countOnly();
```

---

## 14. $contains Operator

Match documents where a string field contains a substring (case-sensitive).

### YQL

```
space.store.filter(field contains "substring").count()
```

**Examples:**

```
sales.products.filter(ProductName contains "Road").count()        → 96
sales.products.filter(ProductName contains "Mountain").count()    → 87
sales.products.filter(ProductName contains "Frame").count()       → 79
sales.vendors.filter(VendorName contains "Bike").count()          → 22
```

### Builder API

```zig
_ = q.space("sales").store("products")
    .where("ProductName", .contains, .{ .string = "Road" })
    .countOnly();
```

---

## 15. $startsWith Operator

Match documents where a string field starts with a prefix (case-sensitive).

### YQL

```
space.store.filter(field startsWith "prefix").count()
```

**Examples:**

```
sales.products.filter(ProductName startsWith "HL").count()          → 47
sales.products.filter(ProductName startsWith "Mountain").count()    → 37
sales.employees.filter(FirstName startsWith "S").count()            → 3
```

### Builder API

```zig
_ = q.space("sales").store("products")
    .where("ProductName", .starts_with, .{ .string = "HL" })
    .countOnly();
```

---

## 16. $exists Operator

Check whether a field exists (is present and non-null) in a document.

### YQL

```
space.store.filter(field exists true).count()
```

**Examples:**

```
sales.products.filter(ProductName exists true).count()    → 295
sales.employees.filter(Gender exists true).count()        → 17
sales.products.filter(Color exists true).count()          → 0     (field doesn't exist)
sales.employees.filter(Salary exists true).count()        → 0     (field doesn't exist)
```

### Builder API

```zig
_ = q.space("sales").store("products")
    .where("ProductName", .exists, .{ .bool = true })
    .countOnly();
```

---

## 17. $regex Operator

Match documents where a string field matches a regular expression pattern.

### YQL

Use `~` as the regex operator:

```
space.store.filter(field ~ "pattern").count()
```

**Examples:**

```
sales.products.filter(ProductName ~ "^HL").count()              → 47   (starts with "HL")
sales.products.filter(ProductName ~ "Frame").count()            → 79   (contains "Frame")
sales.products.filter(ProductName ~ "58$").count()              → 15   (ends with "58")
sales.products.filter(ProductName ~ "^AWC Logo Cap$").count()   → 1    (exact match)
```

### Builder API

```zig
_ = q.space("sales").store("products")
    .where("ProductName", .regex, .{ .string = "^HL" })
    .countOnly();
```

---

## 18. OR Filters

Match documents where **any** condition is true (logical OR).

### YQL

```
space.store.filter(field1 = value1 or field2 = value2).count()
```

**Examples:**

```
sales.employees.filter(Gender = "M" or MaritalStatus = "S").count()       → 14
sales.products.filter(ProductName contains "Road" or ProductName contains "Mountain").count()  → 183
sales.products.filter(SubCategoryID = 1 or SubCategoryID = 2).count()     → 75
sales.orders.filter(TotalDue > 100000 or TotalDue < 100).count()         → 263
sales.orders.filter(EmployeeID = 289 or EmployeeID = 288).count()        → 478
```

### Builder API

Chain `.@"or"(...)` after `.where(...)`:

```zig
_ = q.space("sales").store("employees")
    .where("Gender", .eq, .{ .string = "M" })
    .@"or"("MaritalStatus", .eq, .{ .string = "S" })
    .countOnly();

_ = q.space("sales").store("products")
    .where("ProductName", .contains, .{ .string = "Road" })
    .@"or"("ProductName", .contains, .{ .string = "Mountain" })
    .countOnly();

_ = q.space("sales").store("orders")
    .where("TotalDue", .gt, .{ .float = 100000 })
    .@"or"("TotalDue", .lt, .{ .float = 100 })
    .countOnly();
```

---

## 19. Range Scans

Efficiently query a range of values on indexed fields. The engine uses secondary index range scans when available.

### YQL

Combine `>=`/`>` with `<=`/`<` using `and`:

```
space.store.filter(field >= low and field <= high).count()
space.store.filter(field > low and field < high).count()
space.store.filter(field > value).count()
space.store.filter(field < value).count()
```

**Examples:**

```
// Closed range (inclusive both ends)
sales.orders.filter(EmployeeID >= 285 and EmployeeID <= 287).count()    → 164
sales.orders.filter(EmployeeID >= 288 and EmployeeID <= 289).count()    → 478

// Point range (equals via range)
sales.orders.filter(EmployeeID >= 289 and EmployeeID <= 289).count()    → 348

// Open range (exclusive bounds)
sales.orders.filter(EmployeeID > 285 and EmployeeID < 289).count()     → 278

// One-sided ranges
sales.orders.filter(EmployeeID > 288).count()                           → 523
sales.orders.filter(EmployeeID < 285).count()                           → 2989
```

### Builder API

```zig
// Closed range
_ = q.space("sales").store("orders")
    .where("EmployeeID", .gte, .{ .int = 285 })
    .@"and"("EmployeeID", .lte, .{ .int = 287 })
    .countOnly();

// Open range (exclusive both bounds)
_ = q.space("sales").store("orders")
    .where("EmployeeID", .gt, .{ .int = 285 })
    .@"and"("EmployeeID", .lt, .{ .int = 289 })
    .countOnly();

// One-sided (upper bound only)
_ = q.space("sales").store("orders")
    .where("EmployeeID", .lt, .{ .int = 285 })
    .countOnly();
```

---

## 20. Nested Field Access

Access fields inside embedded sub-documents using dot notation.

### YQL

```
space.store.filter(Parent.Child = "value").count()
```

**Examples:**

```
sales.customers.filter(Address.City = "New York").count()      → 46
sales.customers.filter(Address.State = "CA").count()           → 111
sales.customers.filter(Address.City = "Chicago").count()       → 49
sales.customers.filter(Address.State = "TX").count()           → 84
sales.customers.filter(Address.Country = "US").count()         → 635
sales.customers.filter(Address.State = "FL").count()           → 53
sales.customers.filter(Address.City = "Seattle").count()       → 50
sales.customers.filter(Address.City = "Boston").count()        → 31
```

### Builder API

Use the full dot-path as the field name:

```zig
// Filter by nested field
_ = q.space("sales").store("customers")
    .where("Address.City", .eq, .{ .string = "New York" })
    .countOnly();

_ = q.space("sales").store("customers")
    .where("Address.State", .eq, .{ .string = "CA" })
    .countOnly();

// Sort by nested field
_ = q.space("sales").store("customers")
    .orderBy("Address.City", .asc)
    .limit(5);

// Filter + sort on nested fields
_ = q.space("sales").store("customers")
    .where("Address.State", .eq, .{ .string = "NY" })
    .orderBy("Address.ZipCode", .asc)
    .limit(5);
```

---

## Operator Reference

### Filter Operators

| Operator         | YQL Syntax         | Builder Enum   | Value Type                  | Description           |
| ---------------- | ------------------ | -------------- | --------------------------- | --------------------- |
| Equal            | `=`                | `.eq`          | `.int`, `.float`, `.string` | Exact match           |
| Not Equal        | `!=`               | `.ne`          | `.int`, `.float`, `.string` | Not equal             |
| Greater Than     | `>`                | `.gt`          | `.int`, `.float`            | Greater than          |
| Greater or Equal | `>=`               | `.gte`         | `.int`, `.float`            | Greater than or equal |
| Less Than        | `<`                | `.lt`          | `.int`, `.float`            | Less than             |
| Less or Equal    | `<=`               | `.lte`         | `.int`, `.float`            | Less than or equal    |
| In               | `in [...]`         | `.in`          | `.array`                    | Value in list         |
| Contains         | `contains "..."`   | `.contains`    | `.string`                   | Substring match       |
| Starts With      | `startsWith "..."` | `.starts_with` | `.string`                   | Prefix match          |
| Exists           | `exists true`      | `.exists`      | `.bool`                     | Field exists check    |
| Regex            | `~ "pattern"`      | `.regex`       | `.string`                   | Regex match           |

### Logical Operators

| Operator | YQL Syntax | Builder Method              |
| -------- | ---------- | --------------------------- |
| AND      | `and`      | `.@"and"(field, op, value)` |
| OR       | `or`       | `.@"or"(field, op, value)`  |

### Aggregation Functions

| Function | YQL Syntax                     | Builder Method           |
| -------- | ------------------------------ | ------------------------ |
| Count    | `aggregate(alias: count)`      | `.count("alias")`        |
| Sum      | `aggregate(alias: sum(field))` | `.sum("alias", "field")` |
| Average  | `aggregate(alias: avg(field))` | `.avg("alias", "field")` |
| Minimum  | `aggregate(alias: min(field))` | `.min("alias", "field")` |
| Maximum  | `aggregate(alias: max(field))` | `.max("alias", "field")` |

### Query Modifiers

| Modifier   | YQL Syntax                  | Builder Method                      |
| ---------- | --------------------------- | ----------------------------------- |
| Limit      | `.limit(N)`                 | `.limit(N)`                         |
| Skip       | `.skip(N)`                  | `.skip(N)`                          |
| Order By   | `.orderBy(field, asc/desc)` | `.orderBy("field", .asc/.desc)`     |
| Group By   | `.groupBy(field)`           | `.groupBy("field")`                 |
| Projection | `.pluck(field1, field2)`    | `.select(&.{ "field1", "field2" })` |
| Count Only | `.count()` (in YQL)         | `.countOnly()`                      |

### Builder Value Types

```zig
// Integer
.{ .int = 289 }

// Float
.{ .float = 50000.0 }

// String
.{ .string = "M" }

// Boolean (for $exists)
.{ .bool = true }

// Array (for $in)
.{ .array = @constCast(&[_]Value{ .{ .int = 289 }, .{ .int = 288 } }) }
```

---

## Query Chaining Order

The recommended chaining order for the Builder API:

```
Query.init(client)
  .space("space_name")
  .store("store_name")
  .where(...)              // optional filter
  .@"and"(...) / .@"or"(...)  // optional additional filters
  .orderBy(...)            // optional sort (can chain multiple)
  .limit(N)               // optional limit
  .skip(N)                // optional offset
  .select(...)            // optional projection
  .countOnly()            // optional: return count only
  .count("alias")         // optional: aggregation count
  .sum("alias", "field")  // optional: aggregation sum
  .avg("alias", "field")  // optional: aggregation avg
  .groupBy("field")       // optional: group by
```

### Running the Query

```zig
var q = Query.init(client);
_ = q.space("sales").store("orders")
    .where("EmployeeID", .eq, .{ .int = 289 })
    .orderBy("TotalDue", .desc)
    .limit(10);

var response = q.run() catch |err| {
    // handle error
};
defer response.deinit();
defer q.deinit();

// Access response data
const data = response.data;  // BSON bytes
const count = response.count; // document count
```

---

## Secondary Index Usage

Queries automatically use secondary indexes when available. Indexes accelerate:

- **Equality** (`=`, `.eq`) — exact key lookup
- **Range** (`>`, `>=`, `<`, `<=`) — B+ tree range scan
- **$in** — multi-key lookup on the index

Operators that **always require full scan** (no index benefit):

- `contains`, `startsWith`, `regex` — string pattern matching
- `exists` — field presence check
- `!=` (ne) — must scan all to find non-matches
- `or` — currently not index-optimized
- Queries with no `where` clause
