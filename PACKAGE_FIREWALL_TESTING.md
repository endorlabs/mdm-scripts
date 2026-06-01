# Endor Labs Package Firewall — Python Package Manager Testing

Tests the [Endor Labs Package Firewall](https://docs.endorlabs.com/integrations/package-firewall) against pip, uv, and poetry. The firewall proxies PyPI and blocks packages based on malware detection and configured policies, returning **403 Forbidden** for blocked packages.

## Test packages

| Package | Expected result |
|---------|----------------|
| `aiohttp` | ✅ Allowed — installs successfully |
| `endor-firewall-test==1.0.0` | ❌ Blocked — 403 Forbidden |

---

## pip

### How it works

pip reads `~/.pip/pip.conf` automatically. No extra configuration needed beyond setting the firewall as the index URL.

### Configuration

`~/.pip/pip.conf`:
```ini
[global]
index-url = https://<username>:<password>@factory.endorlabs.com/v1/namespaces/<namespace>/firewall/pypi/simple/
trusted-host = factory.endorlabs.com
```

### Test commands

```bash
# Verify pip is using the firewall index
pip config list

# Should install successfully
pip install aiohttp

# Should fail with 403 Forbidden
pip install "endor-firewall-test==1.0.0"
```

### Result

```
# Blocked package
ERROR: 403 Client Error: Forbidden for url: https://factory.endorlabs.com/.../endor_firewall_test-1.0.0-py3-none-any.whl.metadata
```

---

## uv

### How it works

uv does **not** respect `~/.pip/pip.conf`. It uses its own `uv.toml` config. Placing a `uv.toml` in the project directory is sufficient — uv discovers it automatically.

Credentials can be embedded directly in the index URL (no separate credential store needed).

### Configuration

`uv.toml` (in project directory):
```toml
[[index]]
url = "https://<username>:<password>@factory.endorlabs.com/v1/namespaces/<namespace>/firewall/pypi/simple/"
default = true
```

### Test commands

```bash
# Initialize a new project (if needed)
uv init --no-workspace

# Should install successfully (uv picks up uv.toml automatically)
uv add aiohttp

# Should fail with 403 Forbidden
uv add "endor-firewall-test==1.0.0"
```

### Result

```
# Blocked package
error: Failed to fetch: `https://factory.endorlabs.com/.../endor_firewall_test-1.0.0-py3-none-any.whl.metadata`
  Caused by: HTTP status client error (403 Forbidden) for url (...)
```

---

## poetry

### How it works

Poetry uses a named source in `pyproject.toml`. Credentials **cannot** be embedded in the source URL — poetry ignores them and falls back to unauthenticated requests, causing 401 errors.

Credentials must be passed via environment variables using the pattern:
```
POETRY_HTTP_BASIC_<SOURCE_NAME_UPPERCASE>_USERNAME
POETRY_HTTP_BASIC_<SOURCE_NAME_UPPERCASE>_PASSWORD
```

> **Note:** macOS keychain storage (`poetry config http-basic.<name>`) does not reliably handle tokens containing `+` characters. Use env vars instead.

### Configuration

1. Add the source to `pyproject.toml` (URL without credentials):

```toml
[[tool.poetry.source]]
name = "endor-firewall"
url = "https://factory.endorlabs.com/v1/namespaces/<namespace>/firewall/pypi/simple/"
priority = "primary"
```

Or via CLI:
```bash
poetry source add endor-firewall "https://factory.endorlabs.com/v1/namespaces/<namespace>/firewall/pypi/simple/" --priority=primary
```

2. Set credentials as environment variables:

```bash
export POETRY_HTTP_BASIC_ENDOR_FIREWALL_USERNAME="<username>"
export POETRY_HTTP_BASIC_ENDOR_FIREWALL_PASSWORD="<password>"
```

### Test commands

```bash
# Initialize a new project (if needed)
poetry init --no-interaction

# Should install successfully
POETRY_HTTP_BASIC_ENDOR_FIREWALL_USERNAME="<username>" \
POETRY_HTTP_BASIC_ENDOR_FIREWALL_PASSWORD="<password>" \
poetry add aiohttp

# Should fail with 403 Forbidden
POETRY_HTTP_BASIC_ENDOR_FIREWALL_USERNAME="<username>" \
POETRY_HTTP_BASIC_ENDOR_FIREWALL_PASSWORD="<password>" \
poetry add "endor-firewall-test==1.0.0"
```

### Result

```
# Blocked package
Source (endor-firewall): Failed to retrieve metadata at https://factory.endorlabs.com/.../endor_firewall_test-1.0.0-py3-none-any.whl.metadata
403 Client Error: Forbidden for url: https://factory.endorlabs.com/.../endor_firewall_test-1.0.0-py3-none-any.whl
```

---

## Summary

| Tool | Config file | Auto-detects pip.conf | Credential method |
|------|-------------|----------------------|-------------------|
| pip | `~/.pip/pip.conf` | ✅ Yes | Embedded in URL |
| uv | `uv.toml` in project dir | ❌ No | Embedded in URL |
| poetry | `pyproject.toml` + env vars | ❌ No | Env vars (`POETRY_HTTP_BASIC_*`) |

## Firewall behavior

- Allowed packages return **307** (redirect to public registry for download)
- Blocked packages return **403 Forbidden** on the `.whl.metadata` fetch, halting installation
- Transitive dependencies are also checked — if any dep in the tree is blocked, the entire install fails
