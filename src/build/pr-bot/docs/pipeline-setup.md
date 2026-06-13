# CI Pipeline Setup (Azure DevOps + GitHub source)

This repo ships an **Azure DevOps**-built pipeline ([`azure-pipelines.yml`](../../../../azure-pipelines.yml))
whose source lives in **GitHub**. The pipeline lints (`shellcheck`), runs the bash test
suites, and builds the runtime container image — pushing it to a registry on `main`.

> Native GitHub Actions are intentionally **out of scope**: there is no `.github/workflows/`.
> CI is ADO-built against the GitHub source via an ADO **GitHub service connection**.

The public repo contains **no environment-specific values**. Everything site-specific is
supplied as **pipeline variables** (or a linked variable group) on the build definition.

## 1. Create the ADO → GitHub service connection

ADO needs a GitHub service connection to read the repo and register the webhook that
triggers builds. Two options:

- **GitHub App** (recommended): install the *Azure Pipelines* GitHub App on the repo, then
  create an ADO service connection of type **GitHub** using it.
- **PAT**: a GitHub Personal Access Token with **`repo`** + **`admin:repo_hook`** scopes.

CLI (PAT path):

```bash
# The token is read from $GH_SERVICE_PAT; it is never committed or echoed.
az devops service-endpoint github create \
  --name "GitHub-LeftJab" \
  --github-url "https://github.com/<owner>/<repo>" \
  --org "https://dev.azure.com/<your-ado-org>" \
  --project "<your-ado-project>"
# (export AZURE_DEVOPS_EXT_GITHUB_PAT=<token> first; do NOT inline the token in shell history)
```

## 2. Create the build definition

Point a new pipeline at the GitHub repo's `azure-pipelines.yml`:

```bash
az pipelines create \
  --name "left-jab-harness" \
  --repository "https://github.com/<owner>/<repo>" \
  --branch main \
  --yml-path azure-pipelines.yml \
  --service-connection "<github-service-connection-id>" \
  --org "https://dev.azure.com/<your-ado-org>" \
  --project "<your-ado-project>" \
  --skip-first-run true
```

## 3. Set the required pipeline variables

Set these on the pipeline (UI: *Edit → Variables*, or `az pipelines variable create`).
They are the **only** site-specific inputs the YAML needs:

| Variable | Purpose | Example |
|----------|---------|---------|
| `dockerRegistryServiceConnection` | ADO **docker-registry** service connection (auth to push) | `MyRegistry_ACR` |
| `containerRegistry` | Registry login server | `<name>.azurecr.io` |
| `imageRepository` | Image repository / name | `left-jab-harness` |

A docker-registry service connection (for ACR, Workload Identity Federation is preferred
over an admin key):

```bash
az devops service-endpoint azurerm create ...   # WIF, then grant AcrPush on the registry
```

## 4. Behavior

| Trigger | `dockerCommand` | Result |
|---------|-----------------|--------|
| **PR** to `main` (touching `src/build/**` or the YAML) | `build` | lint + test + image **build** (no push) |
| **Push** to `main` | `buildAndPush` | lint + test + image **build & push** (`tag=<commit sha>`, plus `latest`) |

The image carries **no secrets and no config** — `config.env` / `.secrets.env` and the
`TARGET_REPO_DIR` volume are injected at runtime by the deploying environment.
