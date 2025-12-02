# VaultKit Policy Schema (Reference)

## Overview
Each policy file in `config/policies/*.yaml` defines **one** rule that governs
how VaultKit handles access to a specific dataset under specific conditions.

A policy contains four major sections:

1. **id** — unique policy identifier  
2. **description** — human-readable explanation  
3. **match** — what data + contexts trigger this policy  
4. **action** — what VaultKit should do when it matches  

Below is the full reference schema.

---

## VaultKit Policy Schema (YAML)

```yaml
id: <string>                       # REQUIRED — unique policy ID
description: <string>              # REQUIRED — clear explanation of rule

match:                             # OPTIONAL — define when this policy applies
  dataset: <dataset_name>          # e.g., customers, orders, payments
  fields:                          # OPTIONAL — field-level sensitivity logic
    sensitivity: <tag>             # e.g., pii, financial, internal, secret
    contains: [<tag>, <tag>]       # triggers if query includes all listed tags
    any: [field1, field2]          # triggers if ANY of these fields appear
    all: [field1, field2]          # triggers only if ALL appear

  context:                         # OPTIONAL — identity + environment constraints
    requester_role: <role>         # e.g., analyst, engineer, admin
    requester_clearance: <string>  # e.g., low, high, confidential
    requester_region: <region>     # e.g., US, EU, CA
    dataset_region: <region>       # e.g., US, EU
    environment: <env>             # production | staging | dev

    time:                          # OPTIONAL — time window constraint
      after:  "HH:MM"              # 24h local to timezone
      before: "HH:MM"
      timezone: "America/New_York" # OPTIONAL (defaults to UTC)

action:                            # REQUIRED — outcome VaultKit enforces
  deny: true | false               # Access fully blocked

  require_approval: true | false   # Place request in approval queue
  approver_role: <role>            # Required if require_approval == true

  mask: true | false               # Apply field masking (uses registry metadata)
  mask_strategy: strict | soft     # OPTIONAL: advanced masking modes

  allow: true | false              # Explicit allow (if no higher-priority rule)

  ttl: "1h"                        # OPTIONAL — grant duration (applies for allow/mask)
  reason: <string>                 # REQUIRED for deny / require_approval
```

---

## Priority Rules
When multiple policies match, VaultKit resolves using the following priority:

| Priority | Action             |
|---------|--------------------|
| 3       | deny               |
| 2       | require_approval   |
| 1       | mask               |
| 0       | allow              |

So a `deny` rule always overrides all other matched policies.

---

## Example Minimal Template

```yaml
id: example_policy
description: "Example showing every top-level field."

match:
  dataset: customers
  fields:
    sensitivity: pii
  context:
    requester_role: analyst
    environment: production
    time:
      after: "09:00"
      before: "17:00"

action:
  mask: true
  reason: "PII is masked for analysts during business hours."
  ttl: "1h"
```
