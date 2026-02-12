# ShinyDB Query Correctness Test Plan

Automated tests that execute YQL queries against a running ShinyDB server and compare results with Python3 ground-truth computed directly from the source JSON files.

---

## Overview

### Goal

Verify that **every supported query type** — filter, count, aggregate, groupBy, orderBy, limit, skip — returns results that **exactly match** Python3 computations on the same JSON source data.

### Architecture

```
┌──────────────────┐       ┌─────────────────┐       ┌──────────────────┐
│   Python3 script │       │  ShinyDB Server  │       │  Zig test binary │
│  (ground truth)  │       │  (pre-loaded     │       │  (YQL queries    │
│  reads JSON files│       │   with JSON data)│       │   via client)    │
│  → expected.json │       └────────┬─────────┘       └────────┬─────────┘
└────────┬─────────┘                │                          │
         │                     TCP:23469                       │
         │                          │                          │
         ▼                          ▼                          ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    Compare: expected vs actual                          │
│                    Report: PASS / FAIL per test case                   │
└─────────────────────────────────────────────────────────────────────────┘
```

### Workflow

1. **Generate ground truth** — Run `python3 tests/generate_expected.py` which reads the JSON files and writes `tests/expected.json` with expected results for every test case.
2. **Run Zig tests** — Run `zig build test` which connects to the running server, executes each YQL query, reads `expected.json`, and compares.

### Prerequisites

- ShinyDB server running on `127.0.0.1:23469`
- Sales data loaded via `salesdb-loader all`
- Python 3.6+ installed
- Data **not modified** after loading (no inserts/updates/deletes)

---

## Data Inventory

| Store                        | JSON File                   | Doc Count | Key Fields (type)                                                                                                           |
| ---------------------------- | --------------------------- | --------- | --------------------------------------------------------------------------------------------------------------------------- |
| `sales.orders`               | `orders.json`               | 3,806     | EmployeeID (int), CustomerID (int), SubTotal (float), TaxAmt (float), TotalDue (float), SalesOrderID (int), OrderDate (str) |
| `sales.customers`            | `customers.json`            | 635       | CustomerID (int), FirstName (str), LastName (str), FullName (str)                                                           |
| `sales.employees`            | `employees.json`            | 17        | EmployeeID (int), ManagerID (int/null), JobTitle (str), Gender (str), MaritalStatus (str)                                   |
| `sales.products`             | `products.json`             | 295       | ProductID (int), ProductName (str), StandardCost (float), ListPrice (float), SubCategoryID (int), MakeFlag (int)            |
| `sales.productcategories`    | `productcategories.json`    | 4         | CategoryID (int), CategoryName (str)                                                                                        |
| `sales.productsubcategories` | `productsubcategories.json` | 37        | SubCategoryID (int), CategoryID (int), SubCategoryName (str)                                                                |
| `sales.vendors`              | `vendors.json`              | 104       | VendorID (int), VendorName (str), CreditRating (int), ActiveFlag (int)                                                      |
| `sales.vendorproducts`       | `vendorproduct.json`        | 460       | ProductID (int), VendorID (int)                                                                                             |

---

## Test Cases

### Category 1: Count Queries (`.count()`)

| #   | YQL Query                                        | Python Equivalent                                 | What It Tests                      |
| --- | ------------------------------------------------ | ------------------------------------------------- | ---------------------------------- |
| 1.1 | `sales.orders.count()`                           | `len(orders)`                                     | Total count, no filter             |
| 1.2 | `sales.customers.count()`                        | `len(customers)`                                  | Count on different store           |
| 1.3 | `sales.employees.count()`                        | `len(employees)`                                  | Small collection count             |
| 1.4 | `sales.orders.filter(EmployeeID = 289).count()`  | `sum(1 for o in orders if o['EmployeeID']==289)`  | Count with int equality filter     |
| 1.5 | `sales.orders.filter(EmployeeID = 288).count()`  | `sum(1 for o in orders if o['EmployeeID']==288)`  | Count with different int value     |
| 1.6 | `sales.vendors.filter(ActiveFlag = 1).count()`   | `sum(1 for v in vendors if v['ActiveFlag']==1)`   | Count with boolean-like int filter |
| 1.7 | `sales.products.filter(MakeFlag = 1).count()`    | `sum(1 for p in products if p['MakeFlag']==1)`    | Count with 0/1 int field           |
| 1.8 | `sales.orders.filter(CustomerID = 1045).count()` | `sum(1 for o in orders if o['CustomerID']==1045)` | Count with high-cardinality field  |

### Category 2: Filter Queries (equality)

| #   | YQL Query                                                | Python Equivalent                                 | What It Tests                 |
| --- | -------------------------------------------------------- | ------------------------------------------------- | ----------------------------- |
| 2.1 | `sales.employees.filter(Gender = "M")`                   | `[e for e in employees if e['Gender']=='M']`      | String equality               |
| 2.2 | `sales.employees.filter(Gender = "F")`                   | `[e for e in employees if e['Gender']=='F']`      | String equality (other value) |
| 2.3 | `sales.employees.filter(EmployeeID = 274)`               | `[e for e in employees if e['EmployeeID']==274]`  | Int equality, single result   |
| 2.4 | `sales.products.filter(SubCategoryID = 14)`              | `[p for p in products if p['SubCategoryID']==14]` | Int equality on products      |
| 2.5 | `sales.productcategories.filter(CategoryName = "Bikes")` | `[c for c in cats if c['CategoryName']=='Bikes']` | String equality on small set  |

### Category 3: Filter Queries (comparison operators)

| #   | YQL Query                                                              | Python Equivalent                                     | What It Tests             |
| --- | ---------------------------------------------------------------------- | ----------------------------------------------------- | ------------------------- |
| 3.1 | `sales.orders.filter(TotalDue > 50000).count()`                        | `sum(1 for o in orders if o['TotalDue']>50000)`       | Float greater-than        |
| 3.2 | `sales.orders.filter(TotalDue < 100).count()`                          | `sum(1 for o in orders if o['TotalDue']<100)`         | Float less-than           |
| 3.3 | `sales.orders.filter(TotalDue >= 100000).count()`                      | `sum(1 for o in orders if o['TotalDue']>=100000)`     | Float gte                 |
| 3.4 | `sales.products.filter(ListPrice > 1000).count()`                      | `sum(1 for p in products if p['ListPrice']>1000)`     | Float gt on products      |
| 3.5 | `sales.products.filter(ListPrice <= 0).count()`                        | `sum(1 for p in products if p['ListPrice']<=0)`       | Float lte (zero boundary) |
| 3.6 | `sales.vendors.filter(CreditRating > 3).count()`                       | `sum(1 for v in vendors if v['CreditRating']>3)`      | Int gt                    |
| 3.7 | `sales.vendors.filter(CreditRating != 1).count()`                      | `sum(1 for v in vendors if v['CreditRating']!=1)`     | Int not-equal             |
| 3.8 | `sales.orders.filter(EmployeeID >= 285 and EmployeeID <= 287).count()` | `sum(1 for o in orders if 285<=o['EmployeeID']<=287)` | Range filter with AND     |

### Category 4: Compound Filters (AND / OR)

| #   | YQL Query                                                              | Python Equivalent                                                           | What It Tests              |
| --- | ---------------------------------------------------------------------- | --------------------------------------------------------------------------- | -------------------------- |
| 4.1 | `sales.orders.filter(EmployeeID = 289 and CustomerID = 1045).count()`  | `sum(1 for o in orders if o['EmployeeID']==289 and o['CustomerID']==1045)`  | AND with two int fields    |
| 4.2 | `sales.employees.filter(Gender = "M" and MaritalStatus = "M").count()` | `sum(1 for e in employees if e['Gender']=='M' and e['MaritalStatus']=='M')` | AND with two string fields |
| 4.3 | `sales.employees.filter(Gender = "M" and MaritalStatus = "S").count()` | `sum(1 for e in employees if e['Gender']=='M' and e['MaritalStatus']=='S')` | AND (different combo)      |

### Category 5: Limit & Skip

| #   | YQL Query                            | Python Equivalent                         | What It Tests      |
| --- | ------------------------------------ | ----------------------------------------- | ------------------ |
| 5.1 | `sales.orders.limit(10).count()`     | `min(10, len(orders))` → count of results | Limit caps results |
| 5.2 | `sales.orders.limit(5).count()`      | `5`                                       | Small limit        |
| 5.3 | `sales.orders.skip(3800).count()`    | `max(0, len(orders) - 3800)`              | Skip near end      |
| 5.4 | `sales.customers.limit(100).count()` | `100`                                     | Limit on customers |

### Category 6: OrderBy (verify sort order)

| #   | YQL Query                                            | What We Verify                     |
| --- | ---------------------------------------------------- | ---------------------------------- |
| 6.1 | `sales.products.orderBy(ListPrice, desc).limit(5)`   | First result has highest ListPrice |
| 6.2 | `sales.products.orderBy(ListPrice, asc).limit(5)`    | First result has lowest ListPrice  |
| 6.3 | `sales.employees.orderBy(EmployeeID, asc).limit(3)`  | EmployeeIDs in ascending order     |
| 6.4 | `sales.employees.orderBy(EmployeeID, desc).limit(3)` | EmployeeIDs in descending order    |

### Category 7: Aggregation — Count

| #   | YQL Query                                                       | Python Equivalent                                     | What It Tests         |
| --- | --------------------------------------------------------------- | ----------------------------------------------------- | --------------------- |
| 7.1 | `sales.orders.aggregate(total: count)`                          | `{"total": len(orders)}`                              | Simple count agg      |
| 7.2 | `sales.orders.filter(EmployeeID = 289).aggregate(total: count)` | `{"total": 348}`                                      | Count agg with filter |
| 7.3 | `sales.customers.aggregate(total: count)`                       | `{"total": len(customers)}`                           | Count on customers    |
| 7.4 | `sales.products.filter(MakeFlag = 1).aggregate(n: count)`       | `{"n": sum(1 for p in products if p['MakeFlag']==1)}` | Filtered count agg    |

### Category 8: Aggregation — Sum, Avg, Min, Max

| #   | YQL Query                                                                                                   | Python Equivalent                                    | What It Tests         |
| --- | ----------------------------------------------------------------------------------------------------------- | ---------------------------------------------------- | --------------------- |
| 8.1 | `sales.orders.aggregate(total: sum(TotalDue))`                                                              | `{"total": sum(o['TotalDue'] for o in orders)}`      | Sum float field       |
| 8.2 | `sales.orders.aggregate(avg_total: avg(TotalDue))`                                                          | `{"avg_total": mean(o['TotalDue'] for o in orders)}` | Avg float field       |
| 8.3 | `sales.orders.aggregate(min_total: min(TotalDue))`                                                          | `{"min_total": min(o['TotalDue'] for o in orders)}`  | Min float field       |
| 8.4 | `sales.orders.aggregate(max_total: max(TotalDue))`                                                          | `{"max_total": max(o['TotalDue'] for o in orders)}`  | Max float field       |
| 8.5 | `sales.orders.filter(EmployeeID = 289).aggregate(revenue: sum(TotalDue))`                                   | Filtered sum                                         | Sum with filter       |
| 8.6 | `sales.products.aggregate(avg_price: avg(ListPrice), max_price: max(ListPrice), min_price: min(ListPrice))` | Multi-agg                                            | Multiple aggregations |

### Category 9: Aggregation — GroupBy

| #   | YQL Query                                                                                             | Python Equivalent                             | What It Tests                |
| --- | ----------------------------------------------------------------------------------------------------- | --------------------------------------------- | ---------------------------- |
| 9.1 | `sales.orders.groupBy(EmployeeID).aggregate(n: count)`                                                | `Counter(o['EmployeeID'] for o in orders)`    | GroupBy int, count           |
| 9.2 | `sales.employees.groupBy(Gender).aggregate(n: count)`                                                 | `Counter(e['Gender'] for e in employees)`     | GroupBy string               |
| 9.3 | `sales.employees.groupBy(Gender, MaritalStatus).aggregate(n: count)`                                  | Multi-field groupBy                           | GroupBy multiple fields      |
| 9.4 | `sales.orders.groupBy(EmployeeID).aggregate(n: count, total: sum(TotalDue))`                          | GroupBy + multi-agg                           | GroupBy with sum             |
| 9.5 | `sales.vendors.groupBy(CreditRating).aggregate(n: count)`                                             | `Counter(v['CreditRating'] for v in vendors)` | GroupBy int on vendors       |
| 9.6 | `sales.orders.filter(EmployeeID = 289).groupBy(CustomerID).aggregate(n: count, total: sum(TotalDue))` | Filtered groupBy                              | Filter + GroupBy + multi-agg |

### Category 10: Aggregation with Filter + GroupBy + OrderBy

| #    | YQL Query                                                                                                    | Python Equivalent        | What It Tests          |
| ---- | ------------------------------------------------------------------------------------------------------------ | ------------------------ | ---------------------- |
| 10.1 | `sales.orders.filter(TotalDue > 10000).groupBy(EmployeeID).aggregate(n: count)`                              | Filtered group count     | Filter + GroupBy       |
| 10.2 | `sales.products.filter(ListPrice > 0).groupBy(SubCategoryID).aggregate(n: count, avg_price: avg(ListPrice))` | Filtered group multi-agg | Filter + GroupBy + avg |

---

## Builder API Tests (Programmatic)

These tests use the `Query` builder from `builder.zig` directly (no YQL text parsing). Each builder test mirrors a text-based test above to verify both paths produce identical results.

### Builder API Reference

```zig
const Query = shinydb.Query;
const FilterOp = shinydb.FilterOp;
const Value = shinydb.Value;
const OrderDir = shinydb.OrderDir;

// Basic query
var q = Query.init(client);
defer q.deinit();
var resp = try q.space("sales").store("orders").limit(10).run();

// Filter with where/and
var q = Query.init(client);
defer q.deinit();
var resp = try q.space("sales").store("orders")
    .where("EmployeeID", .eq, Value{ .int = 289 })
    .countOnly()
    .run();

// Aggregation
var q = Query.init(client);
defer q.deinit();
var resp = try q.space("sales").store("orders")
    .groupBy("EmployeeID")
    .count("n")
    .sum("total", "TotalDue")
    .run();
```

### Category 11: Builder — Count Queries

| #    | Builder Code                                                                                    | Mirrors | What It Tests                  |
| ---- | ----------------------------------------------------------------------------------------------- | ------- | ------------------------------ |
| 11.1 | `q.space("sales").store("orders").countOnly().run()`                                            | 1.1     | Total count via builder        |
| 11.2 | `q.space("sales").store("customers").countOnly().run()`                                         | 1.2     | Count on different store       |
| 11.3 | `q.space("sales").store("employees").countOnly().run()`                                         | 1.3     | Small collection count         |
| 11.4 | `q.space("sales").store("orders").where("EmployeeID", .eq, .{ .int = 289 }).countOnly().run()`  | 1.4     | Count with int equality filter |
| 11.5 | `q.space("sales").store("orders").where("EmployeeID", .eq, .{ .int = 288 }).countOnly().run()`  | 1.5     | Count with different int value |
| 11.6 | `q.space("sales").store("vendors").where("ActiveFlag", .eq, .{ .int = 1 }).countOnly().run()`   | 1.6     | Count with boolean-like int    |
| 11.7 | `q.space("sales").store("products").where("MakeFlag", .eq, .{ .int = 1 }).countOnly().run()`    | 1.7     | Count with 0/1 int field       |
| 11.8 | `q.space("sales").store("orders").where("CustomerID", .eq, .{ .int = 1045 }).countOnly().run()` | 1.8     | Count with high-cardinality    |

### Category 12: Builder — Filter Queries (equality)

| #    | Builder Code                                                                                           | Mirrors | What It Tests                 |
| ---- | ------------------------------------------------------------------------------------------------------ | ------- | ----------------------------- |
| 12.1 | `q.space("sales").store("employees").where("Gender", .eq, .{ .string = "M" }).run()`                   | 2.1     | String equality via builder   |
| 12.2 | `q.space("sales").store("employees").where("Gender", .eq, .{ .string = "F" }).run()`                   | 2.2     | String equality (other value) |
| 12.3 | `q.space("sales").store("employees").where("EmployeeID", .eq, .{ .int = 274 }).run()`                  | 2.3     | Int equality, single result   |
| 12.4 | `q.space("sales").store("products").where("SubCategoryID", .eq, .{ .int = 14 }).run()`                 | 2.4     | Int equality on products      |
| 12.5 | `q.space("sales").store("productcategories").where("CategoryName", .eq, .{ .string = "Bikes" }).run()` | 2.5     | String equality on small set  |

### Category 13: Builder — Filter Queries (comparison operators)

| #    | Builder Code                                                                                                                                | Mirrors | What It Tests         |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------- | ------- | --------------------- |
| 13.1 | `q.space("sales").store("orders").where("TotalDue", .gt, .{ .float = 50000 }).countOnly().run()`                                            | 3.1     | Float greater-than    |
| 13.2 | `q.space("sales").store("orders").where("TotalDue", .lt, .{ .float = 100 }).countOnly().run()`                                              | 3.2     | Float less-than       |
| 13.3 | `q.space("sales").store("orders").where("TotalDue", .gte, .{ .float = 100000 }).countOnly().run()`                                          | 3.3     | Float gte             |
| 13.4 | `q.space("sales").store("products").where("ListPrice", .gt, .{ .float = 1000 }).countOnly().run()`                                          | 3.4     | Float gt on products  |
| 13.5 | `q.space("sales").store("products").where("ListPrice", .lte, .{ .float = 0 }).countOnly().run()`                                            | 3.5     | Float lte (zero)      |
| 13.6 | `q.space("sales").store("vendors").where("CreditRating", .gt, .{ .int = 3 }).countOnly().run()`                                             | 3.6     | Int gt                |
| 13.7 | `q.space("sales").store("vendors").where("CreditRating", .ne, .{ .int = 1 }).countOnly().run()`                                             | 3.7     | Int not-equal         |
| 13.8 | `q.space("sales").store("orders").where("EmployeeID", .gte, .{ .int = 285 }).@"and"("EmployeeID", .lte, .{ .int = 287 }).countOnly().run()` | 3.8     | Range filter with AND |

### Category 14: Builder — Compound Filters

| #    | Builder Code                                                                                                                                      | Mirrors | What It Tests              |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | -------------------------- |
| 14.1 | `q.space("sales").store("orders").where("EmployeeID", .eq, .{ .int = 289 }).@"and"("CustomerID", .eq, .{ .int = 1045 }).countOnly().run()`        | 4.1     | AND with two int fields    |
| 14.2 | `q.space("sales").store("employees").where("Gender", .eq, .{ .string = "M" }).@"and"("MaritalStatus", .eq, .{ .string = "M" }).countOnly().run()` | 4.2     | AND with two string fields |
| 14.3 | `q.space("sales").store("employees").where("Gender", .eq, .{ .string = "M" }).@"and"("MaritalStatus", .eq, .{ .string = "S" }).countOnly().run()` | 4.3     | AND (different combo)      |

### Category 15: Builder — Limit & Skip

| #    | Builder Code                                                       | Mirrors | What It Tests      |
| ---- | ------------------------------------------------------------------ | ------- | ------------------ |
| 15.1 | `q.space("sales").store("orders").limit(10).countOnly().run()`     | 5.1     | Limit caps results |
| 15.2 | `q.space("sales").store("orders").limit(5).countOnly().run()`      | 5.2     | Small limit        |
| 15.3 | `q.space("sales").store("orders").skip(3800).countOnly().run()`    | 5.3     | Skip near end      |
| 15.4 | `q.space("sales").store("customers").limit(100).countOnly().run()` | 5.4     | Limit on customers |

### Category 16: Builder — OrderBy

| #    | Builder Code                                                                      | Mirrors | What It Tests         |
| ---- | --------------------------------------------------------------------------------- | ------- | --------------------- |
| 16.1 | `q.space("sales").store("products").orderBy("ListPrice", .desc).limit(5).run()`   | 6.1     | Sort desc via builder |
| 16.2 | `q.space("sales").store("products").orderBy("ListPrice", .asc).limit(5).run()`    | 6.2     | Sort asc via builder  |
| 16.3 | `q.space("sales").store("employees").orderBy("EmployeeID", .asc).limit(3).run()`  | 6.3     | Int sort asc          |
| 16.4 | `q.space("sales").store("employees").orderBy("EmployeeID", .desc).limit(3).run()` | 6.4     | Int sort desc         |

### Category 17: Builder — Aggregation Count

| #    | Builder Code                                                                                      | Mirrors | What It Tests         |
| ---- | ------------------------------------------------------------------------------------------------- | ------- | --------------------- |
| 17.1 | `q.space("sales").store("orders").count("total").run()`                                           | 7.1     | Simple count agg      |
| 17.2 | `q.space("sales").store("orders").where("EmployeeID", .eq, .{ .int = 289 }).count("total").run()` | 7.2     | Count agg with filter |
| 17.3 | `q.space("sales").store("customers").count("total").run()`                                        | 7.3     | Count on customers    |
| 17.4 | `q.space("sales").store("products").where("MakeFlag", .eq, .{ .int = 1 }).count("n").run()`       | 7.4     | Filtered count agg    |

### Category 18: Builder — Aggregation Sum, Avg, Min, Max

| #    | Builder Code                                                                                                                         | Mirrors | What It Tests         |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------ | ------- | --------------------- |
| 18.1 | `q.space("sales").store("orders").sum("total", "TotalDue").run()`                                                                    | 8.1     | Sum float field       |
| 18.2 | `q.space("sales").store("orders").avg("avg_total", "TotalDue").run()`                                                                | 8.2     | Avg float field       |
| 18.3 | `q.space("sales").store("orders").min("min_total", "TotalDue").run()`                                                                | 8.3     | Min float field       |
| 18.4 | `q.space("sales").store("orders").max("max_total", "TotalDue").run()`                                                                | 8.4     | Max float field       |
| 18.5 | `q.space("sales").store("orders").where("EmployeeID", .eq, .{ .int = 289 }).sum("revenue", "TotalDue").run()`                        | 8.5     | Sum with filter       |
| 18.6 | `q.space("sales").store("products").avg("avg_price", "ListPrice").max("max_price", "ListPrice").min("min_price", "ListPrice").run()` | 8.6     | Multiple aggregations |

### Category 19: Builder — Aggregation GroupBy

| #    | Builder Code                                                                                                                                 | Mirrors | What It Tests                |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ---------------------------- |
| 19.1 | `q.space("sales").store("orders").groupBy("EmployeeID").count("n").run()`                                                                    | 9.1     | GroupBy int, count           |
| 19.2 | `q.space("sales").store("employees").groupBy("Gender").count("n").run()`                                                                     | 9.2     | GroupBy string               |
| 19.3 | `q.space("sales").store("employees").groupBy("Gender").groupBy("MaritalStatus").count("n").run()`                                            | 9.3     | GroupBy multiple fields      |
| 19.4 | `q.space("sales").store("orders").groupBy("EmployeeID").count("n").sum("total", "TotalDue").run()`                                           | 9.4     | GroupBy with sum             |
| 19.5 | `q.space("sales").store("vendors").groupBy("CreditRating").count("n").run()`                                                                 | 9.5     | GroupBy int on vendors       |
| 19.6 | `q.space("sales").store("orders").where("EmployeeID", .eq, .{ .int = 289 }).groupBy("CustomerID").count("n").sum("total", "TotalDue").run()` | 9.6     | Filter + GroupBy + multi-agg |

### Category 20: Builder — Filter + GroupBy Combined

| #    | Builder Code                                                                                                                                          | Mirrors | What It Tests          |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ---------------------- |
| 20.1 | `q.space("sales").store("orders").where("TotalDue", .gt, .{ .float = 10000 }).groupBy("EmployeeID").count("n").run()`                                 | 10.1    | Filter + GroupBy       |
| 20.2 | `q.space("sales").store("products").where("ListPrice", .gt, .{ .float = 0 }).groupBy("SubCategoryID").count("n").avg("avg_price", "ListPrice").run()` | 10.2    | Filter + GroupBy + avg |

---

## Test Implementation Plan

### Step 1: Python Ground Truth Generator

**File:** `tests/generate_expected.py`

Reads all JSON files from `src/json/`, computes expected results for every test case above, and writes `tests/expected.json`.

The output format:

```json
{
  "1.1": {"type": "count", "value": 3806},
  "1.4": {"type": "count", "value": 348},
  "2.1": {"type": "doc_count", "value": 10},
  "7.1": {"type": "aggregate", "value": {"total": 3806}},
  "9.1": {"type": "group_aggregate", "value": {"274": {"n": 48}, "275": {"n": 450}, ...}},
  ...
}
```

### Step 2: Zig Test Binary

**File:** `tests/query_tests.zig`

Added to `build.zig` as a test step. Two test modules:

#### a) Text-based YQL tests (Categories 1–10)

Each test:

1. Parses a YQL string using the client's YQL parser
2. Sends the query to the server
3. Reads the corresponding expected value from `tests/expected.json`
4. Compares actual vs expected
5. Reports PASS/FAIL

#### b) Builder API tests (Categories 11–20)

Each test:

1. Constructs a query using `Query.init(client)` and the fluent builder API
2. Calls `.run()` to execute against the server
3. Reads the same expected value (mirrors the text-based test)
4. Compares actual vs expected
5. Reports PASS/FAIL

This ensures both the YQL text parser path and the programmatic builder path produce identical results for every query type.

### Step 3: Build Integration

Add a `test` step to `build.zig` that compiles and runs `tests/query_tests.zig`.

### Running

```bash
# 1. Ensure server is running and data is loaded
salesdb-loader all

# 2. Generate ground truth
cd shinydb-demo
python3 tests/generate_expected.py

# 3. Run tests
zig build test
```

---

## YQL Quick Reference

### Query Syntax

```
space.store[.filter(expr)][.orderBy(field, dir)][.limit(n)][.skip(n)][.count()]
```

### Aggregate Syntax

```
space.store[.filter(expr)][.groupBy(field1, field2)].aggregate(name: func, name: func(field))
```

### Filter Operators

| Operator   | Example                 |
| ---------- | ----------------------- |
| `=`        | `field = value`         |
| `!=`       | `field != value`        |
| `>`        | `field > 100`           |
| `>=`       | `field >= 100`          |
| `<`        | `field < 100`           |
| `<=`       | `field <= 100`          |
| `~`        | `field ~ "pattern"`     |
| `in`       | `field in [1, 2, 3]`    |
| `contains` | `field contains "text"` |
| `exists`   | `field exists`          |

### Aggregate Functions

| Function     | Example                   |
| ------------ | ------------------------- |
| `count`      | `total: count`            |
| `sum(field)` | `revenue: sum(TotalDue)`  |
| `avg(field)` | `average: avg(ListPrice)` |
| `min(field)` | `lowest: min(ListPrice)`  |
| `max(field)` | `highest: max(ListPrice)` |

### Logical Operators

```
field1 = val1 and field2 > val2
field1 = val1 or field1 = val2
```

---

## Success Criteria

- **All count tests** must match exactly (integer comparison)
- **All doc count tests** must match exactly
- **All aggregate numeric tests** must match within ±0.01 tolerance (floating point)
- **All groupBy tests** must have same groups with matching values
- **All orderBy tests** must have correct sort order in first N results
- **Zero false positives** — the Python ground truth is the authoritative source

## Coverage Summary

| Category                    | Test Count | Stores Covered                                  | API      |
| --------------------------- | ---------- | ----------------------------------------------- | -------- |
| Count                       | 8          | orders, customers, employees, vendors, products | YQL text |
| Filter (equality)           | 5          | employees, products, productcategories          | YQL text |
| Filter (comparison)         | 8          | orders, products, vendors                       | YQL text |
| Compound filters            | 3          | orders, employees                               | YQL text |
| Limit & Skip                | 4          | orders, customers                               | YQL text |
| OrderBy                     | 4          | products, employees                             | YQL text |
| Agg count                   | 4          | orders, customers, products                     | YQL text |
| Agg sum/avg/min/max         | 6          | orders, products                                | YQL text |
| Agg groupBy                 | 6          | orders, employees, vendors                      | YQL text |
| Agg filter+groupBy          | 2          | orders, products                                | YQL text |
| **Text subtotal**           | **50**     |                                                 |          |
| Builder count               | 8          | orders, customers, employees, vendors, products | Builder  |
| Builder filter (equality)   | 5          | employees, products, productcategories          | Builder  |
| Builder filter (comparison) | 8          | orders, products, vendors                       | Builder  |
| Builder compound filters    | 3          | orders, employees                               | Builder  |
| Builder limit & skip        | 4          | orders, customers                               | Builder  |
| Builder orderBy             | 4          | products, employees                             | Builder  |
| Builder agg count           | 4          | orders, customers, products                     | Builder  |
| Builder agg sum/avg/min/max | 6          | orders, products                                | Builder  |
| Builder agg groupBy         | 6          | orders, employees, vendors                      | Builder  |
| Builder agg filter+groupBy  | 2          | orders, products                                | Builder  |
| **Builder subtotal**        | **50**     |                                                 |          |
| **Grand Total**             | **100**    | **7 of 8 stores**                               | **Both** |
