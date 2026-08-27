# ruby-zig infrastructure

This public repository owns scheduled fork maintenance for the `ruby-zig` organization. It contains no credentials: the GitHub App ID and private key live only in Actions secrets. Public build policy, the reusable Zig action, target definitions, and build evidence belong in public `ruby-zig/toolchain`; this repository only advances existing fork default branches to their Ruby upstreams.

Keeping the controller public makes its inventory and mutation rules reviewable, while standard GitHub-hosted runners remain available without maintaining a private runner fleet.

## Trust boundary

The workflow runs only on a schedule or by manual dispatch from the protected default branch. It does not run pull-request or upstream code. The trusted prepare job uses its read-only workflow token to compare the upstream and destination default-branch refs. It scans with eight workers and retries transient API failures, then starts sync lanes only for changed, missing, or unreadable pairs. When all forks are current, the workflow ends successfully after the single prepare job.

Each selected lane mints a short-lived GitHub App token scoped to one destination repository; it never stores or prints the token, and the token action revokes it at job teardown. An explicit manual dispatch for one repository always runs that repository's lane, even when the preliminary scan says it is current.

A sync is allowed only when the destination is a fork whose direct parent and default branch match the checked-in manifest, and its current commit is an ancestor of the observed upstream commit. GitHub then receives a non-forced reference update. Missing, ahead, diverged, mismatched, or protected forks fail their lanes and remain unchanged. The controller never merges, rebases, resets, deletes, or force-pushes. Feature work belongs on `zigcc/<default-branch>` or topic branches; defaults stay upstream-clean.

`config/repositories.json` is the run's complete reviewable inventory. It contains all 190 public `ruby/*` repositories. Inventory changes are reviewed commits, not live reads from a moving controller branch.

## GitHub App

Install a dedicated App on the 190 destination forks with only:

- **Contents: read and write** for Git references;
- **Workflows: read and write** because a legitimate upstream fast-forward can change `.github/workflows`;
- **Metadata: read**, which GitHub grants implicitly.

It needs no organization permissions, webhooks, or branch-protection bypass. Configure these Actions secrets on this repository:

- `RUBY_ZIG_SYNC_APP_ID`
- `RUBY_ZIG_SYNC_APP_PRIVATE_KEY`

No personal access token is used. A token is minted only inside a selected sync lane and narrowed to that lane's repository.

## Operation

`.github/workflows/sync-upstreams.yml` checks every three hours on `ubuntu-24.04`. The prepare job makes two public ref reads per inventory entry with bounded concurrency. It emits a matrix containing only non-current or failed checks, with at most 20 standard GitHub-hosted runners active for the resulting sync work. Manual dispatch accepts `all` or one exact repository name. Every lane uploads a JSON result and reports drift without stopping unrelated lanes.

The controller assumes the forks already exist. Fork creation is a separate one-time account-authorized bootstrap; a destination-only App installation cannot create forks from repositories in the separate `ruby` organization.
