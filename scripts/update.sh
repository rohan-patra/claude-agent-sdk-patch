#!/usr/bin/env bash
#
# Fully-automated upstream update + patch re-application.
#
#   ./scripts/update.sh            # vendor latest, merge, re-apply patch, commit
#   ./scripts/update.sh --version 0.3.210   # pin a specific upstream version
#   ./scripts/update.sh --no-vendor         # skip vendoring; just (re)merge current `upstream`
#
# The local patch on sdk.mjs is a *pure function* of pristine upstream, so this
# script does not hand-resolve a 3-way merge: it takes upstream's sdk.mjs
# wholesale and re-derives the two spawn-site edits with backreference regexes
# (the minified env-object identifier is captured, never hard-coded). It then
# runs a set of hard assertions that mirror the manual review checklist. If ANY
# assertion trips, it aborts the merge and exits non-zero so a human can fall
# back to the manual procedure in CLAUDE.md — it never commits a half-applied
# patch.
#
# On success it leaves the merge committed on the current branch. It does NOT
# push or cut a release (see CLAUDE.md for those steps).
set -euo pipefail

PKG=@anthropic-ai/claude-agent-sdk
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION=""
DO_VENDOR=1
for arg in "$@"; do
  case "$arg" in
    --version) shift; VERSION="${1:-}";;               # handled below
    --version=*) VERSION="${arg#*=}";;
    --no-vendor) DO_VENDOR=0;;
    -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0;;
  esac
done
# support `--version 0.3.210` (space form)
if [ "${1:-}" = "--version" ]; then VERSION="${2:-}"; fi

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

manual_fallback() {
  printf '\033[1;31mFAIL\033[0m %s\n' "$1" >&2
  cat >&2 <<'EOF'

The automated patch could not be applied safely. The merge has been aborted and
the working tree restored. Fall back to the manual procedure documented in
CLAUDE.md ("Re-applying after git merge upstream"):

  git merge upstream
  git checkout --theirs sdk.mjs
  # inspect the two spawn sites and re-apply by hand with perl -i -pe
  grep -on 'CLAUDE_CODE_ENTRYPOINT="sdk-ts"' sdk.mjs   # expect 2

EOF
  exit 1
}

# --- preconditions -----------------------------------------------------------
say "Checking preconditions"
git diff --quiet && git diff --cached --quiet || die "working tree is dirty; commit or stash first"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || die "expected to be on 'main', currently on '$BRANCH'"
git rev-parse --verify -q upstream >/dev/null || die "no 'upstream' branch found"
ok "on main, clean tree, upstream branch present"

# --- vendor ------------------------------------------------------------------
if [ "$DO_VENDOR" -eq 1 ]; then
  if [ -n "$VERSION" ]; then
    say "Vendoring $PKG@$VERSION onto 'upstream'"
    D="$(mktemp -d)"; ( cd "$D" && npm pack "$PKG@$VERSION" >/dev/null )
    tar -xzf "$D"/*.tgz -C "$D"
    git checkout -q upstream
    rsync -a --delete --exclude=.git "$D/package/" ./
    git add -A
    if git diff --cached --quiet; then
      echo "upstream already at $VERSION"
    else
      git commit -q -m "vendor: $PKG@$VERSION"; git tag -f "upstream-$VERSION"
      ok "vendored $VERSION on upstream"
    fi
    git checkout -q "$BRANCH"; rm -rf "$D"
  else
    say "Vendoring latest $PKG onto 'upstream'"
    npm run --silent update-upstream
  fi
fi

# Nothing to merge?
if git merge-base --is-ancestor upstream HEAD; then
  ok "main already contains upstream ($(git rev-parse --short upstream)); nothing to merge"
  exit 0
fi
NEWVER="$(git show upstream:package.json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).version))')"
say "Merging upstream ($NEWVER) into $BRANCH"

# --- merge (no auto-commit) --------------------------------------------------
# Prefer upstream on any conflicting hunk; main-only files (CLAUDE.md, scripts/)
# have no upstream side so they are preserved untouched.
if ! git merge --no-commit --no-ff -X theirs upstream >/dev/null 2>&1; then
  : # conflicts are expected in sdk.mjs; handled below
fi

# sdk.mjs: discard whatever the merge produced, take pristine upstream.
git checkout upstream -- sdk.mjs

# --- re-apply the patch deterministically ------------------------------------
say "Re-applying spawn-site patch to sdk.mjs"
perl -0777 -i -pe '
  s/([\w\$]+)\.CLAUDE_CODE_ENTRYPOINT="sdk-ts";if\(delete \1\.NODE_OPTIONS,/$1.CLAUDE_CODE_ENTRYPOINT="cli";delete $1.CLAUDE_AGENT_SDK_VERSION;if(delete $1.NODE_OPTIONS,/g;
  s/([\w\$]+)\.CLAUDE_CODE_ENTRYPOINT="sdk-ts";if\(!\1\.CLAUDE_AGENT_SDK_VERSION\)\1\.CLAUDE_AGENT_SDK_VERSION="[^"]*";/$1.CLAUDE_CODE_ENTRYPOINT="cli";delete $1.CLAUDE_AGENT_SDK_VERSION;/g;
' sdk.mjs

# --- hard assertions (mirror the manual review checklist) --------------------
say "Verifying patch"
abort() { git merge --abort 2>/dev/null || git reset -q --hard HEAD; manual_fallback "$1"; }

node --check sdk.mjs 2>/dev/null || abort "sdk.mjs failed 'node --check' after patch"
cnt() { grep -oc "$1" sdk.mjs || true; }
[ "$(cnt 'CLAUDE_CODE_ENTRYPOINT="sdk-ts"')" = "0" ] || abort "sdk.mjs still has ENTRYPOINT=\"sdk-ts\" assignments (site structure changed?)"
[ "$(cnt 'CLAUDE_CODE_ENTRYPOINT="cli"')"    = "2" ] || abort "expected 2 ENTRYPOINT=\"cli\" sites in sdk.mjs, got $(cnt 'CLAUDE_CODE_ENTRYPOINT="cli"')"
[ "$(grep -oc 'delete [A-Za-z0-9_$]*\.CLAUDE_AGENT_SDK_VERSION' sdk.mjs || true)" = "2" ] \
  || abort "expected 2 'delete …CLAUDE_AGENT_SDK_VERSION' sites in sdk.mjs"
ok "sdk.mjs: 2x cli, 0x sdk-ts, 2x delete-version, node --check passes"

# No OTHER bundle reintroduced a spawn site (assistant.mjs was dropped in 0.3.181).
for f in assistant.mjs browser-sdk.js bridge.mjs; do
  [ -f "$f" ] || continue
  if [ "$f" = bridge.mjs ]; then
    # bridge.mjs legitimately keeps a `case"sdk-ts"` telemetry label; only an
    # *assignment* would signal a new spawn site.
    ! grep -q 'CLAUDE_CODE_ENTRYPOINT="sdk-ts"' "$f" || abort "$f gained an ENTRYPOINT=\"sdk-ts\" assignment — new spawn site, patch by hand"
  else
    ! grep -q 'CLAUDE_CODE_ENTRYPOINT="sdk-ts"' "$f" || abort "$f contains a spawn site — a second bundle reappeared, patch by hand"
  fi
done
ok "no other bundle carries an unpatched spawn site"

# package.json must still carry our update-upstream script and be valid JSON.
node -e 'const p=require("./package.json"); if(!p.scripts||!p.scripts["update-upstream"]) process.exit(1)' \
  || abort "package.json lost scripts.update-upstream (merge favored upstream); re-add it by hand"
ok "package.json retains scripts.update-upstream"

# Any unresolved conflict markers left anywhere?
if git diff --name-only --diff-filter=U | grep -q .; then
  abort "unresolved merge conflicts remain in: $(git diff --name-only --diff-filter=U | tr '\n' ' ')"
fi

# Final delta vs upstream must touch ONLY the three expected files.
git add -A
UNEXPECTED="$(git diff --cached --name-only upstream | grep -vxE 'sdk\.mjs|package\.json|CLAUDE\.md|scripts/update\.sh' || true)"
[ -z "$UNEXPECTED" ] || abort "unexpected files differ from upstream: $(echo "$UNEXPECTED" | tr '\n' ' ')"
ok "delta vs upstream limited to sdk.mjs, package.json, CLAUDE.md, scripts/update.sh"

# --- commit ------------------------------------------------------------------
git commit -q --no-edit -m "Merge branch 'upstream'"
say "Done — merged $NEWVER and re-applied patch."
cat <<EOF

Next steps (not automated — see CLAUDE.md):
  git push origin main upstream upstream-$NEWVER
  gh release create v$NEWVER --target main --title v$NEWVER --notes '...'
EOF
