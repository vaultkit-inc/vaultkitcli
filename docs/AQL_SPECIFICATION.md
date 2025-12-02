# AQL Syntax & Specification

**Version:** `v0.2`  
**Applies to:** Funl Data Translator  
**Maintained by:** VaultKit Engineering Team  

---

## 📘 Overview

**AQL (Abstract Query Language)** is a structured, JSON-based query specification format used by the **VaultKit + Funl** stack.  
It allows secure, policy-aware data access by expressing *what data to retrieve* rather than writing raw SQL.

AQL queries are translated into SQL dynamically by Funl, applying masking, approval, and compliance policies before execution.

---

## 🧭 Table of Contents

1. [Overview](#-overview)  
2. [Top-Level Structure](#-top-level-structure)  
3. [Field Reference](#-field-reference)  
4. [Clause Details](#-clause-details)  
   - [SELECT](#-select-clause)  
   - [JOIN](#-join-clause)  
   - [WHERE](#-where-clause)  
   - [HAVING](#-having-clause)  
   - [ORDER BY](#-order-by-clause)  
   - [LIMIT / OFFSET](#-limit-and-offset)  
5. [Masking & Security Extensions](#-masking--security-extensions)  
6. [Examples](#-examples)  
7. [Future Extensions](#-future-extensions)  
8. [Full Example Query](#-example-full-query)  
9. [Summary](#-summary)

---

## 🧩 Top-Level Structure

Every AQL query describes a single data retrieval request.

```json
{
  "source_table": "orders",
  "columns": ["id", "region", "amount"],
  "joins": [],
  "aggregates": [],
  "filters": [],
  "group_by": [],
  "having": [],
  "order_by": null,
  "limit": 0,
  "offset": 0
}
```

---

## 🧱 Field Reference

| Field | Type | Description | Example |
|-------|------|--------------|----------|
| `source_table` | string | The base table or dataset to query. | `"users"` |
| `columns` | array[string] | List of fields to select (supports `table.field`). | `["email", "username"]` |
| `joins` | array[Join] | Describes table joins. | `[{"type": "LEFT", "table": "orders", "left_field": "users.id", "right_field": "orders.user_id"}]` |
| `aggregates` | array[Aggregation] | Aggregate functions. | `[{"func": "sum", "field": "orders.amount", "alias": "total"}]` |
| `filters` | array[Filter] | WHERE clause filters. | `[{"operator": "eq", "field": "users.active", "value": true}]` |
| `group_by` | array[string] | Columns to group results by. | `["region"]` |
| `having` | array[Having] | Post-aggregation filters. | `[{"operator": "gt", "field": "SUM(orders.amount)", "value": 10000}]` |
| `order_by` | object | Sorting configuration. | `{"column": "orders.amount", "direction": "DESC"}` |
| `limit` | integer | Max number of rows to return. | `10` |
| `offset` | integer | Pagination offset. | `20` |

---

## 🔹 Clause Details

### 🧱 SELECT Clause

Determines which fields or aggregates to return.

```json
{
  "source_table": "users",
  "columns": ["email", "username"]
}
```

➡️ **SQL Output:**

```sql
SELECT users.email, users.username FROM users;
```

With aggregates:

```json
{
  "source_table": "orders",
  "columns": ["region"],
  "aggregates": [{ "func": "sum", "field": "orders.amount", "alias": "total_amount" }],
  "group_by": ["region"]
}
```

➡️ **SQL Output:**

```sql
SELECT region, SUM(orders.amount) AS total_amount FROM orders GROUP BY region;
```

💡 If `group_by` is missing but aggregates exist, Funl automatically groups by columns.

---

### 🔗 JOIN Clause

```json
"joins": [
  {
    "type": "LEFT",
    "table": "orders",
    "alias": "o",
    "left_field": "users.id",
    "right_field": "o.user_id"
  }
]
```

➡️ **SQL Output:**

```sql
LEFT JOIN orders o ON users.id = o.user_id
```

**Supported join types:** `INNER`, `LEFT`, `RIGHT`, `FULL`

---

## 🔍 WHERE Clause

Used for filtering before aggregation.  
Supports both simple conditions and nested logical groups using `AND` and `OR`.

### 🧱 Basic Example

```json
"filters": [
  { "operator": "eq", "field": "users.active", "value": true },
  { "operator": "gt", "field": "orders.amount", "value": 100 }
]
```

➡️ **SQL Output:**

```sql
WHERE users.active = $1 AND orders.amount > $2
```

---

### 🧩 Advanced Example — OR and Nested Logic

```json
"filters": [
  {
    "logic": "OR",
    "conditions": [
      { "operator": "eq", "field": "users.role", "value": "admin" },
      { "operator": "eq", "field": "users.role", "value": "manager" }
    ]
  },
  { "operator": "gt", "field": "orders.amount", "value": 100 }
]
```

➡️ **SQL Output:**

```sql
WHERE (users.role = $1 OR users.role = $2) AND orders.amount > $3;
```

---

### 🧠 Nested Groups

You can nest multiple logical groups, and the translator will automatically wrap `OR` blocks in parentheses to preserve precedence.

```json
"filters": [
  {
    "logic": "AND",
    "conditions": [
      {
        "logic": "OR",
        "conditions": [
          { "operator": "eq", "field": "users.country", "value": "CA" },
          { "operator": "eq", "field": "users.country", "value": "US" }
        ]
      },
      {
        "logic": "OR",
        "conditions": [
          { "operator": "gt", "field": "orders.amount", "value": 5000 },
          { "operator": "eq", "field": "users.vip", "value": true }
        ]
      }
    ]
  }
]
```

➡️ **SQL Output:**

```sql
WHERE ((users.country = $1 OR users.country = $2)
   AND (orders.amount > $3 OR users.vip = $4));
```

---

### ⚙️ Supported Operators

| Operator | SQL Equivalent | Example |
|-----------|----------------|----------|
| `eq` | `=` | `users.role = $1` |
| `neq` | `!=` | `users.role != $1` |
| `gt` | `>` | `orders.amount > $1` |
| `lt` | `<` | `orders.amount < $1` |
| `gte` | `>=` | `orders.amount >= $1` |
| `lte` | `<=` | `orders.amount <= $1` |
| `like` | `LIKE` | `users.email LIKE '%@example.com%'` |
| `in` | `IN (...)` | `users.id IN ($1, $2, $3)` |
| `is_null` | `IS NULL` | `users.deleted_at IS NULL` |
| `is_not_null` | `IS NOT NULL` | `users.deleted_at IS NOT NULL` |

---

### 🔒 Masking-Aware Filtering

If masking policies are defined for a field, filters on that field automatically use the masked version in SQL.

Example:

```json
{ "operator": "eq", "field": "users.email", "value": "test@example.com" }
```

➡️ **SQL Output (with hash masking):**
```sql
WHERE ENCODE(DIGEST(users.email::text, 'sha256'), 'hex') = $1
```

---

### 🧮 HAVING Clause

Post-aggregation filters.

```json
"having": [
  { "operator": "gt", "field": "SUM(orders.amount)", "value": 10000 }
]
```

➡️ **SQL Output:**

```sql
HAVING SUM(orders.amount) > $1
```

---

### 🔠 ORDER BY Clause

```json
"order_by": { "column": "orders.amount", "direction": "DESC" }
```

➡️ **SQL Output:**

```sql
ORDER BY orders.amount DESC
```

---

### 📏 LIMIT and OFFSET

```json
"limit": 10,
"offset": 20
```

➡️ **SQL Output:**

```sql
LIMIT 10 OFFSET 20
```

---

## 🔒 Masking & Security Extensions

Funl can apply masking at translation time based on registered policies.

| Type | Description | SQL Output |
|------|--------------|------------|
| `partial` | Show first few characters | `CONCAT(LEFT(email, 3), '****')` |
| `hash` | Replace with irreversible hash | `ENCODE(DIGEST(email::text, 'sha256'), 'hex')` |
| `full` | Fully masked | `'*****'` |

**Example:**

```json
{
  "source_table": "users",
  "columns": ["email", "username"]
}
```

**Mask registry:**

```go
masking.Register("users.email", masking.Policy{Type: "partial"})
```

➡️ **SQL Output:**

```sql
SELECT CONCAT(LEFT(users.email, 3), '****') AS email, users.username FROM users;
```

---

## 🧩 Examples

### ✅ Basic Selection

```json
{
  "source_table": "users",
  "columns": ["id", "email"]
}
```

➡️ **SQL Output:**

```sql
SELECT users.id, users.email FROM users;
```

---

### ✅ Aggregation + Filtering

```json
{
  "source_table": "orders",
  "columns": ["region"],
  "aggregates": [{ "func": "sum", "field": "orders.amount", "alias": "total" }],
  "group_by": ["region"],
  "having": [{ "operator": "gt", "field": "SUM(orders.amount)", "value": 5000 }]
}
```

➡️ **SQL Output:**

```sql
SELECT region, SUM(orders.amount) AS total
FROM orders
GROUP BY region
HAVING SUM(orders.amount) > $1;
```

---

### ✅ Join Example

```json
{
  "source_table": "users",
  "columns": ["users.id", "orders.amount"],
  "joins": [
    {"type": "LEFT", "table": "orders", "left_field": "users.id", "right_field": "orders.user_id"}
  ],
  "filters": [
    {"operator": "eq", "field": "users.active", "value": true}
  ]
}
```

➡️ **SQL Output:**

```sql
SELECT users.id, orders.amount
FROM users
LEFT JOIN orders ON users.id = orders.user_id
WHERE users.active = $1;
```

---

## 🚀 Future Extensions

| Feature | Description |
|----------|--------------|
| Nested subqueries | `SELECT ... FROM (SELECT ...)` support |
| CASE expressions | Conditional field derivation |
| Window functions | `ROW_NUMBER() OVER (...)`, `RANK()` |
| UNION / INTERSECT / EXCEPT | Multi-query composition |
| JSON operators | Semi-structured data support (e.g., `->`, `->>`) |

---

## 🧮 Example Full Query

**AQL:**

```json
{
  "source_table": "users",
  "joins": [
    {"type": "LEFT", "table": "orders", "left_field": "users.id", "right_field": "orders.user_id"}
  ],
  "columns": ["users.email", "users.username"],
  "aggregates": [{"func": "sum", "field": "orders.amount", "alias": "total_spent"}],
  "group_by": ["users.email", "users.username"],
  "having": [{"operator": "gt", "field": "SUM(orders.amount)", "value": 500}],
  "order_by": {"column": "total_spent", "direction": "DESC"},
  "limit": 10
}
```

**SQL Output:**

```sql
SELECT users.email, users.username, SUM(orders.amount) AS total_spent
FROM users
LEFT JOIN orders ON users.id = orders.user_id
GROUP BY users.email, users.username
HAVING SUM(orders.amount) > $1
ORDER BY total_spent DESC
LIMIT 10;
```

---

## 📘 Summary

| Concept | SQL Equivalent | AQL Field | Supported |
|----------|----------------|------------|------------|
| SELECT | columns, aggregates | ✅ | ✅ |
| FROM | source_table | ✅ | ✅ |
| JOIN | joins | ✅ | ✅ |
| WHERE | filters | ✅ | ✅ |
| GROUP BY | group_by / inferred | ✅ | ✅ |
| HAVING | having | ✅ | ✅ |
| ORDER BY | order_by | ✅ | ✅ |
| LIMIT / OFFSET | limit, offset | ✅ | ✅ |

---

### ✳️ Notes

- All values in AQL are **safely parameter-bound** before execution.  
- Whitespace or missing semicolons do **not** affect execution.  
- Masking is applied **at translation**, not post-processing.
