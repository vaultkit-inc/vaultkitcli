# VaultKit Policy Schema (Reference)

## Overview
Each policy file in `config/policies/*.yaml` defines **one** rule that governs
how VaultKit handles a request. A policy has four parts:

1. **id**: unique policy identifier
2. **description**: human-readable explanation
3. **match** and **context**: which requests it applies to
4. **action**: what VaultKit does when it matches

Policies match fields by their labels in `datasets/registry.yaml`: each field's
`sensitivity` (`high`, `medium` or `low`) and its `category`, which policies see
as a tag. `vkit scan` suggests labels; review them before deploying.

`vkit policy bundle` rejects a policy that can never match, for example one that
uses a tag no field can have, and warns about one that matches on something the
requester supplies.

---

## VaultKit Policy Schema (YAML)

```yaml
id: <string>                       # REQUIRED: unique policy ID
description: <string>              # REQUIRED: clear explanation of the rule
priority: <integer>                # OPTIONAL: see "Which policy wins"

match:                             # OPTIONAL: which data this policy applies to
  dataset: <dataset_name>          # a dataset in datasets/registry.yaml
  fields:                          # matches if ANY of these conditions holds
    sensitivity: high | medium | low
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

The tags the classifier assigns are `pii`, `financial`, `credential` and
`internal`. You can use your own by setting `category` on fields in
`datasets/registry.yaml`.

### Context VaultKit can't enforce yet

- `requester_clearance`: VaultKit doesn't record a clearance for users or agent
  tokens, so a policy using it never matches. `vkit policy bundle` rejects it.
- `requester_region`: users have no region, so the value comes from the request
  itself, and a requester can leave it out. `vkit policy bundle` warns about it;
  don't rely on it for data residency. `dataset_region` comes from the datasource
  and is safe to use.

---

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

After an approval, each field is checked again on its own, without the
requester's context, and a field is masked if the strongest policy that still
matches is a mask. So a mask policy with no `context` keeps a field masked after
approval, unless an approval or deny policy with no `context` also matches it.
The packs give their approval policies a context for this reason.

---

## Policy packs

Packs are ready-made policies. `vkit init` installs `starter`; add others with
`vkit policy pack add <name>`, and update with `vkit policy pack upgrade`.

| Pack | What it does |
|---|---|
| `starter` | Denies credentials. Masks personal data and high-sensitivity fields, also after approval. High-sensitivity data in production needs approval from `data_owner`. Other grants last 4 hours. |
| `ai_safety` | Agents need approval from `security` for personal or financial data in production, and for high-sensitivity data in any environment. |
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
