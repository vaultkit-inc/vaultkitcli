# Driving vkit from a coding agent

A coding agent (Claude Code, Cursor and others) can set VaultKit up for a person with vkit. Every command
takes `--format json`, every setup step runs on flags alone, and the person is asked only for what an agent
mustn't handle: secrets, and confirmations of destructive steps.

## The envelope

With `--format json`, a command prints exactly one JSON object to stdout and nothing else:

```json
{
  "status": "ok" | "error" | "needs_input",
  "result": { ... },
  "next": ["<the command to run next>", "..."],
  "error": { "code": "<stable_snake_case_code>", "message": "...", "fix": "<one sentence: what to do>" }
}
```

`error` is there only when `status` isn't `ok`. Logs, progress and the human output go to stderr.

| Exit code | Meaning |
|-----------|---------|
| 0 | `ok` |
| 1 | `error` |
| 3 | `needs_input`: the person has to do something (see `error.fix`); don't retry as-is |

Some commands keep exit codes that scripts already rely on:

- `vkit registry diff`: 0 means no differences, 1 means differences (`status` is still `ok`, with `result.changed: true`), and 2 means error.
- `vkit request`: a denial exits 2 (`request_denied`).

`vkit approvals:watch --format json` is a stream rather than a single envelope. It prints one JSON object per new approval, as before. An error before the stream starts is still an envelope.

## Secrets

Secrets are never command-line arguments, because those end up in shell history and agent transcripts. They are also never read from stdin, which is the agent's pipe.

- **`vkit datasource add`**:
  - `--password-prompt` reads the password from `/dev/tty` with echo off. The person types it into their terminal, and it never passes through the agent.
  - `--password-env VAR_NAME` reads it from an environment variable.
  - `--password` still works but prints a deprecation warning.
  - If no password source is given, the command returns `needs_input` / `secret_required`. Ask the person to run the same command with `--password-prompt` in their own terminal.
- **`vkit login`**:
  - With a browser (OIDC) login, the agent can run it: the person signs in in the browser.
  - A password or token login under `--format json` needs `--password-prompt` (read from `/dev/tty`). Without it, the command returns `secret_required`.
- **`vkit agents tokens create`** needs `--secret-file PATH` under `--format json`. The token is written there (mode 600) and never printed.

Passwords and tokens never appear in any output, error messages included.

## Setting VaultKit up

```bash
vkit login --endpoint https://vaultkit.example.com --format json      # the person signs in
vkit init --dir policies --format json                                # git init, starter pack
cd policies
vkit datasource add --id shop --engine postgres --username vaultkit_ro \
  --config '{"host":"db","port":5432,"database":"shop"}' \
  --region US --environment production --password-prompt              # the person runs this one
vkit scan shop --format json                                          # what would change
vkit scan shop --mode apply --format json                             # update the registry
vkit registry export --force --format json                            # write datasets/registry.yaml
# review datasets/registry.yaml with the person: each column's sensitivity
git add -A && git commit -m "Add VaultKit policies"
vkit policy bundle --format json
vkit policy deploy --format json
```

Each step is safe to run twice:

- **`init`** in an initialised folder changes nothing and returns `already_existed: true`.
- **`datasource add`** with an existing id changes nothing and returns `already_existed: true`.
- **`policy pack add`** for an installed pack returns `already_existed: true`.
- **`policy deploy`** of the version that's already active returns `already_deployed: true`.

## Reviewing classifications

`vkit scan --format json` (either mode) lists every column of the scanned datasets. Each column has:

- `sensitivity` and `category`;
- `unknown`: the classifier couldn't place it;
- `unreviewed`: nobody has reviewed it yet. The starter pack masks these columns for agents.
- `change`: `added`, `removed`, `changed` or `null`;
- `suggestion`: the classifier's suggestion for a column someone already reviewed, the `?` lines in the human output.

The review itself happens in `datasets/registry.yaml`. Check it against the control plane with `vkit registry diff --format json`.

## Confirmations

A command that would ask a question returns `needs_input` instead. Ask the person, then rerun with the flag named in `error.fix`:

| Command | `error.code` | Flag |
|---------|--------------|------|
| `vkit reset` | `confirmation_required` | `--yes` |
| `vkit grant:revoke`, `vkit policy revoke`, `vkit agents tokens revoke` | `confirmation_required` | `--yes` (or `--force`) |
| `vkit registry export` over an existing file | `overwrite_confirmation_required` | `--force` |
| `vkit policy pack upgrade` with missing pack files | `confirmation_required` | `--restore` |
| `vkit approval:deny` without `--reason` | `reason_required` | `--reason "..."` |

## Error codes

| `error.code` | When |
|--------------|------|
| `not_logged_in` | No saved login, and no `VKIT_ENDPOINT`/`VKIT_TOKEN` |
| `session_expired` | The login has expired (logins last an hour), or an agent token has |
| `token_revoked` | The login was logged out elsewhere, or the agent token was revoked |
| `not_authenticated` | Any other credential the control plane refuses |
| `control_plane_unreachable` | Connection refused, DNS, timeout or TLS failure talking to the control plane |
| `datasource_unreachable` | `vkit scan`: the database's host or port can't be reached |
| `datasource_connection_failed` | `vkit scan`: the database refused the connection. A wrong password is reported this way, and so is any other connection failure |
| `datasource_permission_denied` | `vkit scan`: the role can't read the schema |
| `datasource_query_failed`, `datasource_busy`, `query_runtime_unavailable` | `vkit scan`: other failures on the way to the database |
| `secret_required`, `secret_env_missing`, `conflicting_password_sources` | Password sources (see Secrets) |
| `admin_required` | Datasource commands need an admin |
| `bundle_not_committed`, `bundle_not_versioned` | `vkit policy bundle`: commit the policies first (see `error.fix`) |
| `bundle_version_exists` | `vkit policy deploy`: this version was uploaded before and isn't the active one |
| `bundle_invalid`, `policy_invalid` | The bundle or a policy fails validation |
| `unknown_pack` | No such policy pack. `result.available_packs` lists them |
| `pack_dependency_missing`, `pack_upgrade_failed` | Policy pack problems |
| `not_a_project` | Not run in (or pointed at with `--dir`) a folder made by `vkit init` |
| `registry_not_found` | `vkit registry diff` with no `datasets/registry.yaml` |
| `invalid_arguments` | A missing or unknown option |
| `command_failed` | Anything else: `error.message` says what |

Other control plane errors keep the status they came with, and the control plane's own code when it sends one: `forbidden`, `not_found` or `api_error` (with `http_status`).

Datasource connections are checked only when a datasource is scanned. `vkit datasource add` stores the credentials without connecting. vkit doesn't check whether the database role is a superuser or can bypass row-level security, and neither does the control plane.
