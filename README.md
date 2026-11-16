# lean-bump

A GitHub Action that keeps a Lake package's dependencies on your own packages current. It moves each git `require` pinned to a release tag to the latest release, runs `lake update` for just those packages, and opens a pull request.

Lake has no notion of "latest compatible", so `lake update` alone never moves a `rev = "v0.4.0"` pin. Editing those pins across many interdependent repositories is the chore this removes.

## What it does

For each root `require` in `lake-manifest.json` whose git URL matches `owner-pattern`:

- **Pinned to a tag** (`v1.2.3` or `1.2.3`): rewrites the `rev` in `lakefile.toml` or `lakefile.lean` to the highest newer release tag. Prereleases are ignored, as are tags whose `lean-toolchain` is a release candidate, unless `allow-rc-toolchain` is set.
- **Tracking a branch**: updates it if the branch head has moved.

It also moves `lean-toolchain` to the latest stable Lean release, if that is newer. That is the newest published GitHub release of `leanprover/lean4` with binaries attached, not the newest tag: Lean pushes the tag before its CI has built and published the release, and until then elan cannot install it. A release candidate moves to its release, and a toolchain that is not a `leanprover/lean4` release, such as a nightly, is left alone.

It then runs `lake update` naming only those packages, without `--keep-toolchain`, since in that mode a dependency's manifest can override the root's own pins ([lean4 issue](https://github.com/leanprover/lean4/issues/15761)). The PR description lists what was requested, anything else that changed in the manifest, and any toolchain change. It also lists any version disagreements: a dependency that requires one of your packages at a different version than the one Lake kept, and so is built against a version it was not released with. That usually means a package in the middle of the graph has an unreleased bump, which holds back everything that requires it.

A repository can hold several Lake projects, each directory with a `lake-manifest.json` outside `.lake`, such as a test package beside the root that requires it by path. Each is bumped the same way, after any project it requires by path. A package that such a dependency's update moved is updated in the requiring project too, so its manifest follows, and is reported there under "Also changed". If the base branch already has the same changes by the time the PR would open, for example because an earlier bump PR was merged during the run, no PR is opened and `changed` is `false`.

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

To have a release ripple through your packages, add [templates/lean_bump_notify.yml](templates/lean_bump_notify.yml) to each library as `.github/workflows/lean_bump_notify.yml`. [Bootstrap](#bootstrap) keeps it up to date once it is there, but does not add it, since only a library needs it.

The tag patterns match the release tags the bump looks for, so prerelease tags such as `v1.2.0-rc1` notify nothing. GitHub does not start workflows for a tag pushed with `GITHUB_TOKEN`, nor for any tag when more than three are pushed at once. If a release workflow pushes the tag with `GITHUB_TOKEN`, add the `notify` step to that workflow instead, after the tag is pushed.

`notify` sends `lean-dependency-released` to every non-archived, non-fork repository in the account with a root `lake-manifest.json`, other than the one releasing. There is no list of dependents to maintain: a repository that does not depend on the release runs a bump that finds nothing and opens no PR. Each one that does opens a PR; merging and tagging it notifies everything again, which carries the release to the next level.

## Bootstrap

To bring every package up to date at once, run the Bootstrap workflow from this repository's Actions tab (it needs the [App](#tokens) set up in this repository too, and defaults to a dry run), or locally:

```bash
GITHUB_TOKEN=$(gh auth token) OWNER=... DRY_RUN=true ./bootstrap.sh
```

Locally, `GITHUB_TOKEN` is just the variable the script reads. Your own login works if it has the `workflow` scope (`gh auth refresh -s workflow`), though the PRs are then opened by you rather than the App.

For each Lake package in the account, it triggers the bump workflow if the package has `.github/workflows/lean-bump.yml`. It also opens a PR that adds the bump and resolve workflows where they are missing, and brings every workflow from [templates](templates) that the package has up to date, notify included. Run it again after merging those PRs to trigger the newly installed workflows. It is safe to rerun: a package whose install PR is still open is skipped, and one whose workflows all match their templates gets no PR. Each round brings packages up to date with what is released now, so a change several levels down still needs a release at each level, which `notify` then carries onwards.

## Protecting the default branch

`protect.sh` gives each Lake package's default branch a ruleset named `lean-bump` that requires its CI jobs to pass before a merge, so nothing merges a bump PR that CI has not passed:

```bash
GITHUB_TOKEN=$(gh auth token) OWNER=... DRY_RUN=true ./protect.sh
```

It needs a token with administration rights on the repositories, which the App deliberately lacks, so it runs locally with your own login rather than as a workflow. The jobs are those of the latest successful run of `Lean Action CI` (set `CI_WORKFLOW` for another name) on the default branch, required from GitHub Actions so no other app can satisfy them. A package with no such run is skipped. Repository admins may bypass the ruleset, so you can still push to the default branch directly. Rerun it after adding a package or changing its CI jobs: it updates the ruleset in place.

## Tokens

Two tokens are involved:

- **`GITHUB_TOKEN`** is created by GitHub Actions for each run. There is nothing to set up, but it has two limits. It can only act on the repository running the workflow, so it cannot notify or bootstrap other repositories. And events it causes do not start other workflows, so a PR it opens runs no CI.
- **The App's token** is minted for each run by [`actions/create-github-app-token`](https://github.com/actions/create-github-app-token) from a GitHub App you create. It has neither limit, does not expire with a person's token, and acts as the App rather than as you.

| Used by | Token | |
|---|---|---|
| the bump action's `token` input | either | `GITHUB_TOKEN` works, but its PRs run no CI. The [template](templates/lean-bump.yml) passes the App's token, for its own repository. |
| `notify` | the App's | Sends events to the account's other repositories. The [template](templates/lean_bump_notify.yml) asks for a token covering every repository the App is installed on. |
| `bootstrap` | the App's | Adds a workflow file and opens a PR in each of the account's other repositories. |
| `resolve` | the App's | Pushes fixes, comments, merges and tags. |

`notify` finds the account's Lake packages with one GraphQL query per 100 repositories, then sends the events a second apart. Each event starts a bump run on the same token, so if GitHub still reports a rate limit, `notify` and `bootstrap` wait as long as it asks and retry, up to four times. A search or other read that hits a transient server error (HTTP 502, 503 or 504) is retried the same way, after 5, 10, 20 and 40 seconds; a write is not, because it may already have taken effect.

### Creating the App

1. Open [New GitHub App](https://github.com/settings/apps/new) (Settings → Developer settings → GitHub Apps → New GitHub App), or the same page under the organization's settings.
2. Give it a name and a homepage URL, and clear **Webhook → Active**: nothing is sent to it.
3. Under **Repository permissions**, set **Contents**, **Pull requests** and **Workflows** to **Read and write**. **Metadata** is added as read-only automatically. Workflows is needed only by `bootstrap`, which adds files under `.github/workflows`.
4. Create it, note its **App ID**, and under **Private keys** generate a key, which downloads a `.pem` file.
5. Under **Install App**, install it on the account that owns your packages, with **All repositories**, so packages created later are covered too.

Then store the ID as a variable named `LEAN_BOT_APP_ID` and the key as a secret named `LEAN_BOT_PRIVATE_KEY` in every repository that uses them: each package, and the repository running Bootstrap. For an organization, one of each covers them all:

```bash
gh variable set LEAN_BOT_APP_ID --org ORG --visibility all --body APP_ID
gh secret set LEAN_BOT_PRIVATE_KEY --org ORG --visibility all < key.pem
```

For a personal account, set them in each repository:

```bash
for repo in liba libb; do
  gh variable set LEAN_BOT_APP_ID --repo OWNER/$repo --body APP_ID
  gh secret set LEAN_BOT_PRIVATE_KEY --repo OWNER/$repo < key.pem
done
```

A token you create yourself, such as a fine-grained personal access token with the same permissions, works too: pass it as the bump action's or `notify`'s `token` input instead of the App's.

Every repository the bump reaches must be public, or readable with the credentials `actions/checkout` leaves configured, since `git ls-remote` and `lake update` fetch from it.

## Testing

`tests/run.sh` builds fixture repositories locally and runs `bump.sh` and `check-base.sh` against them; it needs `elan`, `git`, `jq` and `perl`. `tests/github.sh` runs `notify`, `bootstrap` and `protect` against a fake GitHub API.
