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

## Before committing any change

Always review the full delta of your branch (committed history **plus**
uncommitted working-tree changes) against pristine upstream, and confirm it is
minimal, surgical, and correct — no incidental edits to vendored bundles, no
stray files:

```bash
git diff upstream            # everything on this branch + working tree vs. upstream
git diff --stat upstream     # quick file-level overview
```

Only commit once that diff is exactly the intended patch and nothing more.

## Local patches

Make changes on `main` (one focused commit each, so merges stay easy).

- `package.json` → `scripts.update-upstream` is the only patch on top of a clean
  copy of upstream `0.3.150`. Because it edits a vendored file, expect to
  re-resolve it if upstream ever adds its own `scripts` block.

### Subprocess environment normalization (`sdk.mjs`, `assistant.mjs`)

When the SDK spawns the `claude` CLI it tags the child process env so the CLI
can tell it is being driven programmatically. We strip the two tags that are
present on *every* spawn so the child env matches an ordinary interactive
session. This is a behavioral patch on the bundled (minified) code, so it must
be re-applied by hand after each `git merge upstream` — the minified identifiers
(`H`, `V6`, `G`, `XQ`, …) change between releases, so match on the surrounding
structure, not the exact variable names.

There are **four** spawn/child-env construction sites — two in each file (the
streaming/transport path and the one-shot `query()` path). At each one, upstream
does roughly:

```js
if(!E.CLAUDE_CODE_ENTRYPOINT)E.CLAUDE_CODE_ENTRYPOINT="sdk-ts";   // E = child env object
// ...and on the one-shot paths also:
if(!E.CLAUDE_AGENT_SDK_VERSION)E.CLAUDE_AGENT_SDK_VERSION="0.3.150"; // or =process.env.CLAUDE_AGENT_SDK_VERSION
```

Rewrite each to:

1. **Entrypoint** — change the assigned value from `"sdk-ts"` to `"cli"`. `cli`
   is the value a real interactive session uses (and the `default` of the
   entrypoint→telemetry switch in `bridge.mjs`/`assistant.mjs`), so the CLI's
   User-Agent and telemetry source become indistinguishable from interactive
   use. Keep the `if(!…)` guard; only the literal changes.
2. **Version** — replace the *assignment* with an unconditional
   `delete E.CLAUDE_AGENT_SDK_VERSION;` on the child env. A delete (rather than
   just not setting it) also clears the value inherited from the host
   `process.env`, which upstream self-tags near the top of `query()`
   (`process.env.CLAUDE_AGENT_SDK_VERSION="0.3.150"`) — leave that host-side
   line alone; it is not a child-CLI signal once the child env is cleaned.

So a streaming-path site `…ENTRYPOINT="sdk-ts";if(delete E.NODE_OPTIONS,…`
becomes `…ENTRYPOINT="cli";delete E.CLAUDE_AGENT_SDK_VERSION;if(delete E.NODE_OPTIONS,…`,
and a one-shot site `…ENTRYPOINT="sdk-ts";if(!E.CLAUDE_AGENT_SDK_VERSION)E.CLAUDE_AGENT_SDK_VERSION="0.3.150";`
becomes `…ENTRYPOINT="cli";delete E.CLAUDE_AGENT_SDK_VERSION;`.

Intentionally **not** touched, so don't add them back as "missing":

- `NODE_OPTIONS`/`DEBUG` are still deleted by upstream — that absence is only a
  tell when paired with the entrypoint tag, and the entrypoint now reads `cli`.
- The conditional `CLAUDE_CODE_*SDK*` / `CLAUDE_CODE_SANDBOXED` /
  `CLAUDE_CODE_QUESTION_PREVIEW_FORMAT` vars only appear when the caller opts
  into the matching feature, and some are load-bearing (e.g.
  `CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH` gates token-refresh callbacks). Leave them.
- The `--output-format/--input-format stream-json --verbose` argv flags, the
  `initialize` control_request, SDK hook callback IDs, `type:'sdk'` MCP servers,
  and the `SDKUserMessage` envelope are the actual control protocol — removing
  them breaks the SDK. They are not addressable here by design.

Verify after re-applying: `node --check sdk.mjs && node --check assistant.mjs`,
then confirm no `CLAUDE_CODE_ENTRYPOINT="sdk-ts"` assignments remain (the
`case"sdk-ts"` in the telemetry switch should stay) and that there are two
`delete …CLAUDE_AGENT_SDK_VERSION` sites per file.

The package name is left as `@anthropic-ai/claude-agent-sdk` so the fork is a
drop-in replacement. Note `optionalDependencies` pin the native
`@anthropic-ai/claude-agent-sdk-*` packages to the upstream version — revisit
those if you ever publish under a different name.
