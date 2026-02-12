#!/usr/bin/env python3
"""
Generate ground-truth expected results for ShinyDB query correctness tests.
Reads JSON source files and computes expected values for every test case.
Output: tests/expected.json
"""

import json
import os
from collections import Counter
from statistics import mean

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
JSON_DIR = os.path.join(SCRIPT_DIR, "..", "src", "json")


def load(name):
    with open(os.path.join(JSON_DIR, name)) as f:
        return json.load(f)


def main():
    orders = load("orders.json")
    customers = load("customers.json")
    employees = load("employees.json")
    products = load("products.json")
    productcategories = load("productcategories.json")
    productsubcategories = load("productsubcategories.json")
    vendors = load("vendors.json")
    vendorproducts = load("vendorproduct.json")

    expected = {}

    # ── Category 1: Count Queries ──
    expected["1.1"] = {"type": "count", "value": len(orders)}
    expected["1.2"] = {"type": "count", "value": len(customers)}
    expected["1.3"] = {"type": "count", "value": len(employees)}
    expected["1.4"] = {"type": "count", "value": sum(1 for o in orders if o["EmployeeID"] == 289)}
    expected["1.5"] = {"type": "count", "value": sum(1 for o in orders if o["EmployeeID"] == 288)}
    expected["1.6"] = {"type": "count", "value": sum(1 for v in vendors if v["ActiveFlag"] == 1)}
    expected["1.7"] = {"type": "count", "value": sum(1 for p in products if p["MakeFlag"] == 1)}
    expected["1.8"] = {"type": "count", "value": sum(1 for o in orders if o["CustomerID"] == 1045)}

    # ── Category 2: Filter Queries (equality) — doc_count ──
    expected["2.1"] = {"type": "doc_count", "value": sum(1 for e in employees if e["Gender"] == "M")}
    expected["2.2"] = {"type": "doc_count", "value": sum(1 for e in employees if e["Gender"] == "F")}
    expected["2.3"] = {"type": "doc_count", "value": sum(1 for e in employees if e["EmployeeID"] == 274)}
    expected["2.4"] = {"type": "doc_count", "value": sum(1 for p in products if p["SubCategoryID"] == 14)}
    expected["2.5"] = {"type": "doc_count", "value": sum(1 for c in productcategories if c["CategoryName"] == "Bikes")}

    # ── Category 3: Filter Queries (comparison) ──
    expected["3.1"] = {"type": "count", "value": sum(1 for o in orders if o["TotalDue"] > 50000)}
    expected["3.2"] = {"type": "count", "value": sum(1 for o in orders if o["TotalDue"] < 100)}
    expected["3.3"] = {"type": "count", "value": sum(1 for o in orders if o["TotalDue"] >= 100000)}
    expected["3.4"] = {"type": "count", "value": sum(1 for p in products if p["ListPrice"] > 1000)}
    expected["3.5"] = {"type": "count", "value": sum(1 for p in products if p["ListPrice"] <= 0)}
    expected["3.6"] = {"type": "count", "value": sum(1 for v in vendors if v["CreditRating"] > 3)}
    expected["3.7"] = {"type": "count", "value": sum(1 for v in vendors if v["CreditRating"] != 1)}
    expected["3.8"] = {"type": "count", "value": sum(1 for o in orders if 285 <= o["EmployeeID"] <= 287)}

    # ── Category 4: Compound Filters ──
    expected["4.1"] = {"type": "count", "value": sum(1 for o in orders if o["EmployeeID"] == 289 and o["CustomerID"] == 1045)}
    expected["4.2"] = {"type": "count", "value": sum(1 for e in employees if e["Gender"] == "M" and e["MaritalStatus"] == "M")}
    expected["4.3"] = {"type": "count", "value": sum(1 for e in employees if e["Gender"] == "M" and e["MaritalStatus"] == "S")}

    # ── Category 5: Limit & Skip ──
    expected["5.1"] = {"type": "count", "value": min(10, len(orders))}
    expected["5.2"] = {"type": "count", "value": min(5, len(orders))}
    expected["5.3"] = {"type": "count", "value": max(0, len(orders) - 3800)}
    expected["5.4"] = {"type": "count", "value": min(100, len(customers))}

    # ── Category 6: OrderBy ──
    # Return the field values of the first N results in expected order
    products_by_price_desc = sorted(products, key=lambda p: p["ListPrice"], reverse=True)
    products_by_price_asc = sorted(products, key=lambda p: p["ListPrice"])
    employees_by_id_asc = sorted(employees, key=lambda e: e["EmployeeID"])
    employees_by_id_desc = sorted(employees, key=lambda e: e["EmployeeID"], reverse=True)

    expected["6.1"] = {"type": "order", "field": "ListPrice", "values": [p["ListPrice"] for p in products_by_price_desc[:5]]}
    expected["6.2"] = {"type": "order", "field": "ListPrice", "values": [p["ListPrice"] for p in products_by_price_asc[:5]]}
    expected["6.3"] = {"type": "order", "field": "EmployeeID", "values": [e["EmployeeID"] for e in employees_by_id_asc[:3]]}
    expected["6.4"] = {"type": "order", "field": "EmployeeID", "values": [e["EmployeeID"] for e in employees_by_id_desc[:3]]}

    # ── Category 7: Aggregation Count ──
    expected["7.1"] = {"type": "aggregate", "value": {"total": len(orders)}}
    expected["7.2"] = {"type": "aggregate", "value": {"total": sum(1 for o in orders if o["EmployeeID"] == 289)}}
    expected["7.3"] = {"type": "aggregate", "value": {"total": len(customers)}}
    expected["7.4"] = {"type": "aggregate", "value": {"n": sum(1 for p in products if p["MakeFlag"] == 1)}}

    # ── Category 8: Aggregation Sum, Avg, Min, Max ──
    all_totals = [o["TotalDue"] for o in orders]
    emp289_totals = [o["TotalDue"] for o in orders if o["EmployeeID"] == 289]
    all_list_prices = [p["ListPrice"] for p in products]

    expected["8.1"] = {"type": "aggregate", "value": {"total": sum(all_totals)}}
    expected["8.2"] = {"type": "aggregate", "value": {"avg_total": mean(all_totals)}}
    expected["8.3"] = {"type": "aggregate", "value": {"min_total": min(all_totals)}}
    expected["8.4"] = {"type": "aggregate", "value": {"max_total": max(all_totals)}}
    expected["8.5"] = {"type": "aggregate", "value": {"revenue": sum(emp289_totals)}}
    expected["8.6"] = {"type": "aggregate", "value": {
        "avg_price": mean(all_list_prices),
        "max_price": max(all_list_prices),
        "min_price": min(all_list_prices),
    }}

    # ── Category 9: Aggregation GroupBy ──
    # 9.1 GroupBy EmployeeID → count
    emp_counts = Counter(o["EmployeeID"] for o in orders)
    expected["9.1"] = {"type": "group_aggregate", "value": {str(k): {"n": v} for k, v in emp_counts.items()}}

    # 9.2 GroupBy Gender → count
    gender_counts = Counter(e["Gender"] for e in employees)
    expected["9.2"] = {"type": "group_aggregate", "value": {k: {"n": v} for k, v in gender_counts.items()}}

    # 9.3 GroupBy Gender, MaritalStatus → count
    gm_counts = Counter((e["Gender"], e["MaritalStatus"]) for e in employees)
    expected["9.3"] = {"type": "group_aggregate", "value": {f"{g},{m}": {"n": v} for (g, m), v in gm_counts.items()}}

    # 9.4 GroupBy EmployeeID → count + sum(TotalDue)
    emp_agg = {}
    for o in orders:
        eid = str(o["EmployeeID"])
        if eid not in emp_agg:
            emp_agg[eid] = {"n": 0, "total": 0.0}
        emp_agg[eid]["n"] += 1
        emp_agg[eid]["total"] += o["TotalDue"]
    expected["9.4"] = {"type": "group_aggregate", "value": emp_agg}

    # 9.5 GroupBy CreditRating → count
    cr_counts = Counter(v["CreditRating"] for v in vendors)
    expected["9.5"] = {"type": "group_aggregate", "value": {str(k): {"n": v} for k, v in cr_counts.items()}}

    # 9.6 Filter EmployeeID=289 → GroupBy CustomerID → count + sum(TotalDue)
    emp289_orders = [o for o in orders if o["EmployeeID"] == 289]
    cust_agg = {}
    for o in emp289_orders:
        cid = str(o["CustomerID"])
        if cid not in cust_agg:
            cust_agg[cid] = {"n": 0, "total": 0.0}
        cust_agg[cid]["n"] += 1
        cust_agg[cid]["total"] += o["TotalDue"]
    expected["9.6"] = {"type": "group_aggregate", "value": cust_agg}

    # ── Category 10: Filter + GroupBy ──
    # 10.1 Filter TotalDue > 10000 → GroupBy EmployeeID → count
    big_orders = [o for o in orders if o["TotalDue"] > 10000]
    big_emp_counts = Counter(o["EmployeeID"] for o in big_orders)
    expected["10.1"] = {"type": "group_aggregate", "value": {str(k): {"n": v} for k, v in big_emp_counts.items()}}

    # 10.2 Filter ListPrice > 0 → GroupBy SubCategoryID → count + avg(ListPrice)
    priced_products = [p for p in products if p["ListPrice"] > 0]
    subcat_agg = {}
    for p in priced_products:
        sid = str(p["SubCategoryID"])
        if sid not in subcat_agg:
            subcat_agg[sid] = {"prices": [], "n": 0}
        subcat_agg[sid]["n"] += 1
        subcat_agg[sid]["prices"].append(p["ListPrice"])
    for sid in subcat_agg:
        subcat_agg[sid]["avg_price"] = mean(subcat_agg[sid]["prices"])
        del subcat_agg[sid]["prices"]
    expected["10.2"] = {"type": "group_aggregate", "value": subcat_agg}

    # Write output
    out_path = os.path.join(SCRIPT_DIR, "expected.json")
    with open(out_path, "w") as f:
        json.dump(expected, f, indent=2, sort_keys=True)

    # Summary
    print(f"Generated {len(expected)} test expectations → {out_path}")
    for key in sorted(expected.keys(), key=lambda k: (int(k.split('.')[0]), int(k.split('.')[1]))):
        e = expected[key]
        t = e["type"]
        if t == "count":
            print(f"  {key}: count = {e['value']}")
        elif t == "doc_count":
            print(f"  {key}: doc_count = {e['value']}")
        elif t == "aggregate":
            print(f"  {key}: aggregate = {e['value']}")
        elif t == "group_aggregate":
            print(f"  {key}: group_aggregate ({len(e['value'])} groups)")
        elif t == "order":
            print(f"  {key}: order = {e['values']}")


if __name__ == "__main__":
    main()
