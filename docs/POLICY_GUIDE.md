# VaultKit Policy Schema (Reference)

## Overview
Each policy file in `config/policies/*.yaml` defines **one** rule that governs
how VaultKit handles a request. A policy has four parts:

1. **id**: unique policy identifier
2. **description**: human-readable explanation
3. **match** and **context**: which requests it applies to
4. **action**: what VaultKit does when it matches

Policies match fields by their labels in `datasets/registry.yaml`: each field's
`sensitivity` (`high`, `medium`, `low` or `unknown`) and its `category`, which
policies see as a tag. `vkit scan` suggests labels; review them before deploying.

`unknown` means the scanner couldn't place a column that could hold anything,
such as `payload` (jsonb) or `notes` (text). Give it a real label once you know
what it holds. A rescan replaces an `unknown` label, but keeps labels you've set.

`vkit policy bundle` rejects a policy that can never match, for example one that
uses a tag no field can have.

---

## VaultKit Policy Schema (YAML)

```yaml
id: <string>                       # REQUIRED: unique policy ID
description: <string>              # REQUIRED: clear explanation of the rule
priority: <integer>                # OPTIONAL: see "Which policy wins"

match:                             # OPTIONAL: which data this policy applies to
  dataset: <dataset_name>          # a dataset in datasets/registry.yaml
  fields:                          # matches if ANY of these conditions holds
    sensitivity: high | medium | low | unknown
    contains: [<tag>, <tag>]       # a requested field has ANY of these tags
    any: [field1, field2]          # ANY of these fields is requested
    all: [field1, field2]          # required as well: ALL of these are requested

  context:                         # OPTIONAL: like `context` below, plus time
    time:
      after:  "HH:MM"
      before: "HH:MM"

context:                           # OPTIONAL: who is asking, and where
  environment: production | staging | development | sandbox   # the datasource's
  dataset_region: EU | US | CA | APAC                           # the datasource's
  requester_role: <role>           # admin, member, approver, an approval group,
                                   # or agent (the default for agent tokens)
  requester_clearance: low | medium | high   # set by an admin on the user or token
  requester_region: EU | US | CA | APAC      # set by an admin on the user or token

action:                            # REQUIRED: exactly one of these is true
  deny: true
  require_approval: true
  mask: true
  allow: true

  approver_role: <group>           # REQUIRED with require_approval
  reason: <string>                 # REQUIRED with deny and require_approval
  ttl: "1h"                        # OPTIONAL: how long the grant lasts

masking:                           # OPTIONAL, with mask
  default_method: full | partial | hash
```

The tags the classifier assigns are `pii`, `financial`, `credential`,
`internal` and `unknown`. You can use your own by setting `category` on fields in
`datasets/registry.yaml`.

### Requester clearance and region

Admins set a clearance and a region on each user (Team, Edit member) and agent
token. Requests can't claim their own, so policies can rely on them, for example
for data residency:

```yaml
context:
  requester_region: US
  dataset_region: EU
```

A policy that names a clearance or region doesn't match a requester without one.
There's no "not equal", so to restrict everyone below a level, match the levels
you want to restrict (for example one policy each for `low` and `medium`).
Requires a control plane with admin-set clearance and region.

---

## Tenant-scoped datasets

When your customers' rows share tables, keyed by a column like
`organization_id`, mark those datasets in `datasets/registry.yaml`:

```yaml
tickets:
  datasource: app
  tenant_column: organization_id
  fields:
    organization_id: { type: uuid, sensitivity: low, category: internal }
```

Then issue each agent session a token for one tenant:

```bash
vkit agents tokens create --name support-assistant --tenant org_42 --expires-in 1h
```

Every query that reads a tenant-scoped dataset, as its source or through a
join, is confined to the token's tenant. VaultKit adds
`organization_id = 'org_42'` to the query, ANDed with the agent's own filters,
so the agent can't ask for another tenant, leave the tenant out, or widen past it
with `OR`. Grants, approvals and grant reuse are bound to the tenant, and every
request records it in the audit log.

- **Fails closed.** A requester without a tenant, including every user, is
  denied on tenant-scoped datasets.
- **Set by an admin.** The tenant is fixed when the token is issued; requests
  can't change it. A short-lived token per customer session keeps it tight.
- **Unmarked tenant tables are an error.** `vkit policy bundle` refuses a dataset
  that has another dataset's tenant column but no `tenant_column`. Mark it, or set
  `tenant_column: false` for a table every tenant may read (for example a plans
  catalogue).
- **Shared tables only.** A schema or database per tenant isn't supported yet.

## Which policy wins

When several policies match, the strongest action wins, whatever their priority:

| Strength | Action             |
|---------|--------------------|
| 3       | deny               |
| 2       | require_approval   |
| 1       | mask               |
| 0       | allow              |

When several approval policies match, every one of their approver groups must
sign off, and the shortest TTL applies. Masking from every matching mask policy
is combined. With no matching policy, a request is allowed.

Masking combines every mask policy that matches, with the requester's context;
when two mask one field, the strictest method wins (full, then hash, then
partial). An approval lifts the approval requirement, not the masks: a field a
mask policy covers stays masked after approval.

---

## Policy packs

Packs are ready-made policies. `vkit init` installs `starter`; add others with
`vkit policy pack add <name>`, and update with `vkit policy pack upgrade`.

| Pack | What it does |
|---|---|
| `starter` | Denies credentials. Masks personal data and high-sensitivity fields, also after approval. High-sensitivity data in production needs approval from `data_owner`. `unknown` columns are allowed but flagged: the decision records why, so they show up in the audit log. Other grants last 4 hours. |
| `ai_safety` | Agents need approval from `security` for personal, financial or `unknown` data in production, and for high-sensitivity data in any environment. |
| `financial_compliance` | Financial data in production needs approval from `finance_manager`, and grants with financial fields last 30 minutes. |

Before relying on a pack:

- **Create its approval groups** (`data_owner`, `security`, `finance_manager`) and
  add people to them. Until then, only admins can approve.
- **Review the registry labels.** The packs act on them, and a field labelled
  `low` that holds personal data isn't protected.
- **Agents match `requester_role: agent`,** the default role for agent tokens.
  Tokens created with another role don't.

---

## Example

```yaml
id: mask_customer_contact_in_business_hours
description: "Customer contact details are masked during business hours."

match:
  dataset: customers
  fields:
    any: [email, phone]
  context:
    time:
      after: "09:00"
      before: "17:00"

context:
  environment: production

action:
  mask: true
  reason: "Contact details are masked during business hours."
  ttl: "1h"

masking:
  default_method: partial
```
