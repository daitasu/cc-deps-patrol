# cc-deps-patrol

A GitHub Composite Action that auto-merges Dependabot PRs with configurable strategies per semver level (patch / minor / major).

Uses [Claude Code Action](https://github.com/anthropics/claude-code-action) for AI-powered reviews.

## Strategies

| Strategy | Behavior |
|---|---|
| `auto-merge` | Approve and merge immediately |
| `verify-and-merge` | Check supply-chain trust signals, merge if passed |
| `review-and-merge` | AI reviews the PR — merges if approved |
| `review-only` | AI posts a review comment (no merge) |
| `none` | Do nothing |

> `verify-and-merge`, `review-and-merge`, and `review-only` all run an automated **supply-chain trust check** that verifies:
>
> | Signal | What it checks | Source |
> |---|---|---|
> | **npm provenance** | Sigstore attestation linking the package to its source repo and CI/CD build | npm registry attestation API |
> | **Install scripts** | Newly added `postinstall` / `preinstall` / `install` scripts (common malware vector) | `npm view` |
> | **Release age** | Days since the version was published (informational) | npm registry `time` field |
>
> For `verify-and-merge`, new install scripts will **block** the merge. Missing provenance triggers a warning but does not block on its own (adoption is still growing).

### Defaults

| semver level | default strategy |
|---|---|
| patch | `auto-merge` |
| minor | `review-and-merge` |
| major | `review-only` |

## Usage

> **Note:** Dependabot PRs cannot access repository secrets with the `pull_request` event.
> Use `pull_request_target` instead.

```yaml
name: Dependabot Auto Merge
on:
  pull_request_target:
    types: [opened, reopened, ready_for_review]

permissions: {}

jobs:
  dependabot-automerge:
    if: github.event.pull_request.user.login == 'dependabot[bot]'
    runs-on: ubuntu-latest
    timeout-minutes: 15
    permissions:
      contents: read
      pull-requests: write
    steps:
      - name: Generate App Token
        id: app-token
        uses: actions/create-github-app-token@v3
        with:
          client-id: ${{ vars.BOT_CLIENT_ID }}
          private-key: ${{ secrets.BOT_PRIVATE_KEY }}

      - uses: actions/checkout@v4

      - uses: daitasu/cc-deps-patrol@v1
        with:
          github-token: ${{ steps.app-token.outputs.token }}
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          claude-github-token: ${{ steps.app-token.outputs.token }}
          # patch-strategy: 'auto-merge'       # default
          # minor-strategy: 'review-and-merge'  # default
          # major-strategy: 'review-only'       # default
          reviewer-login: "my-bot[bot]"
```

### Supply-chain verified auto-merge (no AI, no API key needed)

```yaml
- uses: daitasu/cc-deps-patrol@v1
  with:
    github-token: ${{ steps.app-token.outputs.token }}
    patch-strategy: "verify-and-merge"
    minor-strategy: "verify-and-merge"
    major-strategy: "review-only"
    anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}     # only for review-only
    claude-github-token: ${{ steps.app-token.outputs.token }}
```

### Patch-only auto-merge (no AI review)

```yaml
- uses: daitasu/cc-deps-patrol@v1
  with:
    github-token: ${{ steps.app-token.outputs.token }}
    patch-strategy: "auto-merge"
    minor-strategy: "none"
    major-strategy: "none"
```

### AI review + merge for all levels

```yaml
- uses: daitasu/cc-deps-patrol@v1
  with:
    github-token: ${{ steps.app-token.outputs.token }}
    anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
    claude-github-token: ${{ steps.app-token.outputs.token }}
    patch-strategy: "review-and-merge"
    minor-strategy: "review-and-merge"
    major-strategy: "review-and-merge"
    reviewer-login: "my-bot[bot]"
```

### Japanese review comments

```yaml
- uses: daitasu/cc-deps-patrol@v1
  with:
    github-token: ${{ steps.app-token.outputs.token }}
    anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
    claude-github-token: ${{ steps.app-token.outputs.token }}
    review-language: "ja"
    reviewer-login: "my-bot[bot]"
```

## Inputs

| Name | Required | Default | Description |
|---|---|---|---|
| `patch-strategy` | No | `auto-merge` | Strategy for patch updates |
| `minor-strategy` | No | `review-and-merge` | Strategy for minor updates |
| `major-strategy` | No | `review-only` | Strategy for major updates |
| `github-token` | **Yes** | - | GitHub token for approve/merge (e.g. GitHub App token or PAT) |
| `anthropic-api-key` | No | `""` | Anthropic API key (required for `review-and-merge` / `review-only`) |
| `claude-github-token` | No | `""` | GitHub token for Claude Code Action (required for `review-and-merge` / `review-only`) |
| `claude-model` | No | `sonnet` | Claude model for AI review |
| `reviewer-login` | No | `""` | Bot login name to check for approval (`review-and-merge` only) |
| `review-language` | No | `en` | Language for AI review comments (`en`, `ja`, etc.) |

## Outputs

| Name | Description |
|---|---|
| `strategy` | The strategy that was applied |
| `update-type` | The semver update level (`patch`, `minor`, `major`) |
| `provenance-result` | Supply-chain check result: `pass`, `warn`, `fail`, or `skip` |

## Required Permissions

### GitHub App

- **Pull requests**: Read & Write (approve, review comments)
- **Contents**: Read & Write (read repository, merge PRs)

> **Note:** You can pass the same token to both `github-token` and `claude-github-token` — a single GitHub App is sufficient.
> Use separate Apps if you want to isolate permissions.

### Workflow permissions

```yaml
permissions:
  contents: read
  pull-requests: write
```

> These only apply to `GITHUB_TOKEN`. GitHub App tokens use their own permission set.

## License

MIT
