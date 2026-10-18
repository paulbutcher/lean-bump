# lean-bump

A GitHub Action that keeps a Lake package's dependencies on your own packages current. It moves each git `require` pinned to a release tag to the latest release, runs `lake update` for just those packages, builds and tests, and opens a pull request.

Lake has no notion of "latest compatible", so `lake update` alone never moves a `rev = "v0.4.0"` pin. Editing those pins across many interdependent repositories is the chore this removes.

## What it does

For each root `require` in `lake-manifest.json` whose git URL matches `owner-pattern`:

- **Pinned to a tag** (`v1.2.3` or `1.2.3`): rewrites the `rev` in `lakefile.toml` or `lakefile.lean` to the highest newer release tag. Prereleases are ignored, as are tags whose `lean-toolchain` is a release candidate, unless `allow-rc-toolchain` is set.
- **Tracking a branch**: updates it if the branch head has moved.

It also moves `lean-toolchain` to the latest stable Lean release, if that is newer. A release candidate moves to its release, and a toolchain that is not a `leanprover/lean4` release, such as a nightly, is left alone.

It then runs `lake update` naming only those packages, without `--keep-toolchain`, since in that mode a dependency's manifest can override the root's own pins ([lean4 issue](https://github.com/leanprover/lean4/issues/15761)). The PR description lists what was requested, anything else that changed in the manifest, and any toolchain change. If the build or tests fail, the PR is opened as a draft.

## Usage

Add [templates/lean-bump.yml](templates/lean-bump.yml) to a repository as `.github/workflows/lean-bump.yml`, or let [bootstrap](#bootstrap) do it. It runs weekly, on demand, and whenever a sibling package is released.

| Input | Default | |
|---|---|---|
| `token` | `GITHUB_TOKEN` | Pushes the branch and opens the PR. See [Tokens](#tokens). |
| `owner-pattern` | the repository owner's GitHub account | Regex matched against each require's git URL. |
| `allow-rc-toolchain` | `false` | Accept releases on release-candidate toolchains. |
| `branch` | `lean-bump` | Branch the PR is opened from. |

Outputs: `changed` and `pull-request-url`.

## Releasing down the dependency graph

To have a release ripple through your packages, add a step to each library's release workflow:

```yaml
- uses: paulbutcher/lean-bump/notify@v1
  with:
    token: ${{ secrets.LEAN_BUMP_TOKEN }}
```

It sends `lean-dependency-released` to every non-archived, non-fork repository in the account with a root `lake-manifest.json`, other than the one releasing. There is no list of dependents to maintain: a repository that does not depend on the release runs a bump that finds nothing and opens no PR. Each one that does opens a PR; merging and tagging it notifies everything again, which carries the release to the next level.

## Bootstrap

To bring every package up to date at once, run the Bootstrap workflow from this repository's Actions tab (it needs the [`LEAN_BUMP_TOKEN`](#tokens) secret in this repository too, and defaults to a dry run), or locally:

```bash
GITHUB_TOKEN=... OWNER=paulbutcher DRY_RUN=true ./bootstrap.sh
```

Locally, `GITHUB_TOKEN` is just the variable the script reads: set it to the same token as `LEAN_BUMP_TOKEN`.

For each Lake package in the account, it triggers the bump workflow if the package has `.github/workflows/lean-bump.yml`, and otherwise opens a PR adding it. Run it again after merging those PRs to trigger the newly installed workflows. It is safe to rerun: a package whose install PR is still open is skipped. Each round brings packages up to date with what is released now, so a change several levels down still needs a release at each level, which `notify` then carries onwards.

## Tokens

Two tokens are involved:

- **`GITHUB_TOKEN`** is created by GitHub Actions for each run. There is nothing to set up, but it has two limits. It can only act on the repository running the workflow, so it cannot notify or bootstrap other repositories. And events it causes do not start other workflows, so a PR it opens runs no CI.
- **`LEAN_BUMP_TOKEN`** is a secret you create, holding a token you generate for your account. It has neither limit.

| Used by | Token | |
|---|---|---|
| the bump action's `token` input | either | `GITHUB_TOKEN` works, but its PRs run no CI. The [template](templates/lean-bump.yml) passes `LEAN_BUMP_TOKEN`. |
| `notify` | `LEAN_BUMP_TOKEN` | Sends events to the account's other repositories. |
| `bootstrap` | `LEAN_BUMP_TOKEN` | Adds a workflow file and opens a PR in each of the account's other repositories. |

`notify` makes one API call per repository in the account, well inside the authenticated rate limit.

### Creating `LEAN_BUMP_TOKEN`

1. Open [New fine-grained personal access token](https://github.com/settings/personal-access-tokens/new) (Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token).
2. Set **Resource owner** to the account or organization that owns your packages. An organization may need to approve the token before it works.
3. Choose an **Expiration**, and note to rotate the token before then.
4. Under **Repository access**, choose **All repositories**, so packages created later are covered too.
5. Under **Permissions → Repository permissions**, set **Contents**, **Pull requests** and **Workflows** to **Read and write**. **Metadata** is added as read-only automatically. Workflows is needed only by `bootstrap`, which adds a file under `.github/workflows`.
6. Generate the token and copy it.

Then store it as a secret named `LEAN_BUMP_TOKEN` in every repository that uses it: each package running the bump workflow or `notify`, and the repository running Bootstrap. For an organization, one organization secret covers them all:

```bash
gh secret set LEAN_BUMP_TOKEN --org ORG --visibility all
```

For a personal account, set it in each repository:

```bash
read -rs token
for repo in liba libb; do printf %s "$token" | gh secret set LEAN_BUMP_TOKEN --repo OWNER/$repo; done
```

A GitHub App installation token with the same permissions works instead of a personal access token, and is not tied to a person.

Every repository the bump reaches must be public, or readable with the credentials `actions/checkout` leaves configured, since `git ls-remote` and `lake update` fetch from it.

## Testing

`tests/run.sh` builds fixture repositories locally and runs `bump.sh` against them; it needs `elan`, `git`, `jq` and `perl`. `tests/github.sh` runs `notify` and `bootstrap` against a fake GitHub API.
