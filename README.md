# ruby-zig infrastructure

This public repository owns scheduled fork maintenance for the `ruby-zig` organization. It contains no credentials: the GitHub App ID and private key live only in Actions secrets. Public build policy, the reusable Zig action, target definitions, and build evidence belong in public `ruby-zig/toolchain`; this repository only advances existing fork refs to their exact Ruby upstream refs.

Keeping the controller public makes its inventory and mutation rules reviewable, while standard GitHub-hosted runners remain available without maintaining a private runner fleet.

## Scope

`config/repositories.json` is the active, reviewable inventory: 39 repositories whose products or relevant tests require native compilation. It expands to 42 tracked refs. Every repository tracks its default branch; `ruby/ruby` additionally tracks `ruby_4_0`, `ruby_3_4`, and `ruby_3_3`. EOL branch `ruby_3_2` is intentionally excluded.

`config/discovery-repositories.json` preserves the 190-repository organization snapshot used to derive the native scope. `config/affected-repositories.txt` is the exact ordered allowlist for the active inventory. Repositories that do not require native compilation are discovered but are neither forked nor synchronized.

Inventory changes are reviewed commits, not live reads from a moving controller branch.

## Trust boundary

The workflow runs only on a schedule or by manual dispatch from the protected default branch. It does not check out or execute upstream code. The trusted prepare job uses its read-only workflow token to compare each tracked upstream and destination ref. It scans with eight workers and retries transient API failures, then starts sync lanes only for changed, missing, or unreadable pairs. When all refs are current, the workflow ends successfully after the prepare job.

Each selected lane mints a short-lived GitHub App token scoped to one destination repository. It never stores or prints the token, and the token action revokes it at job teardown. An explicit manual repository dispatch runs every tracked ref for that repository even when current. Supplying a branch narrows the run to that exact checked-in repository/ref pair; a branch cannot be supplied with `all`.

A sync is allowed only when all of these checks pass:

- the repository and branch are an exact pair in the active manifest;
- the destination is a public fork whose direct parent matches the manifest;
- the fork's actual default branch matches the manifest, even when synchronizing a maintenance branch;
- both upstream and destination refs exist; and
- the destination commit is an ancestor of the observed upstream commit.

GitHub then receives a non-forced reference update. Missing, ahead, diverged, mismatched, protected, or untracked refs fail their lanes and remain unchanged. The controller never merges, rebases, resets, deletes, creates branches, or force-pushes. Zig work belongs on `zigcc/<upstream-branch>` or narrow topic branches; tracked refs stay upstream-clean.

## GitHub App

Install a dedicated App on the 39 destination forks with only:

- **Contents: read and write** for Git references;
- **Workflows: read and write** because a legitimate upstream fast-forward can change `.github/workflows`;
- **Metadata: read**, which GitHub grants implicitly.

It needs no organization permissions, webhooks, or branch-protection bypass. Configure these Actions secrets on this repository:

- `RUBY_ZIG_SYNC_APP_ID`
- `RUBY_ZIG_SYNC_APP_PRIVATE_KEY`

No personal access token is used. A token is minted only inside a selected sync lane and narrowed to that lane's repository.

## Operation

`.github/workflows/sync-upstreams.yml` checks all 42 tracked refs every three hours on `ubuntu-24.04`. The prepare job makes two public ref reads per identity with bounded concurrency. It emits only non-current or failed checks, with at most 20 standard GitHub-hosted runners active for sync work.

Manual dispatch accepts `all` or one exact repository name. For one repository it also accepts an optional exact tracked branch. Lane, report, and artifact identifiers contain a bounded branch slug plus a stable hash, so branches containing slashes remain safe and distinct. A lane that reaches `sync-one.sh` uploads its JSON result and reports drift without stopping unrelated lanes. Token-mint or earlier setup failures remain visible in the job result and logs but may occur before a JSON report exists.

The controller assumes the forks and tracked branches already exist. Fork creation is a separate, account-authorized bootstrap with one worker by default and a hard maximum of four. A destination-only App installation cannot create forks from repositories in the separate `ruby` organization.
