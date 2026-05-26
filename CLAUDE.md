# claude-agent-sdk-patch

A fork of [`@anthropic-ai/claude-agent-sdk`](https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk)
that tracks upstream releases closely while carrying a small set of local
patches.

## Upstream lives on npm, not GitHub

The package's GitHub repo (`anthropics/claude-agent-sdk-typescript`) ships only
docs/examples/changelog — **not** the SDK implementation. The real shipped code
is the **bundled npm tarball** (`sdk.mjs`, `bridge.mjs`, `assistant.mjs`,
`browser-sdk.js`, the `*.d.ts` types, `package.json`, `manifest*.json`). So this
fork vendors the **npm tarball** as upstream.

> The vendored `.mjs`/`.js` files are bundled & minified — not original source.
> Patches are possible and 3-way merges work, but bundle diffs are noisy. Keep
> local patches small and surgical.

## Branch model

- **`upstream`** — pristine. Holds *exactly* the npm tarball contents, nothing
  else. One commit per release, tagged `upstream-<version>` (e.g.
  `upstream-0.3.150`).
- **`main`** — the fork. Branched from `upstream`'s root, so the two share
  history and `git merge upstream` is a true 3-way merge (conflicts only where a
  patch overlaps an upstream change).

## Update to a new upstream release

```bash
# 1. Vendor the latest published version onto the `upstream` branch.
#    (Must be run from a clean working tree; returns you to your branch.)
npm run update-upstream

# 2. Fold it into the fork, resolving any conflicts, then commit the merge.
git checkout main
git merge upstream
```

`npm run update-upstream` always vendors the **latest** version. To pin a
specific version, do it by hand (same steps the script automates):

```bash
git checkout upstream
D=$(mktemp -d); ( cd "$D" && npm pack @anthropic-ai/claude-agent-sdk@0.3.151 ); tar -xzf "$D"/*.tgz -C "$D"
rsync -a --delete --exclude=.git "$D/package/" ./
git add -A && git commit -m "vendor: @anthropic-ai/claude-agent-sdk@0.3.151" && git tag upstream-0.3.151
git checkout main && git merge upstream
```

Diff any two releases with their tags: `git diff upstream-0.3.150 upstream-0.3.151`.

## Local patches

Make changes on `main` (one focused commit each, so merges stay easy).

- `package.json` → `scripts.update-upstream` is the only patch on top of a clean
  copy of upstream `0.3.150`. Because it edits a vendored file, expect to
  re-resolve it if upstream ever adds its own `scripts` block.

The package name is left as `@anthropic-ai/claude-agent-sdk` so the fork is a
drop-in replacement. Note `optionalDependencies` pin the native
`@anthropic-ai/claude-agent-sdk-*` packages to the upstream version — revisit
those if you ever publish under a different name.
