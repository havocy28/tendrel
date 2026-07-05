#!/usr/bin/env bash
# Scaffold a repo so the tendrel plugin will operate in it.
# Usage: bash setup-research-repo.sh <repo-path> <project-name>
#
# Creates raw/ wiki/ graph/ and a .research-graph project marker. The Stop reconcile hook
# fires in any repo that has a graph/ dir, so creating graph/ is what "turns the system on"
# for a repo (after the plugin is enabled there).
set -euo pipefail
repo="${1:?usage: bash setup-research-repo.sh <repo-path> <project-name>}"
project="${2:?usage: bash setup-research-repo.sh <repo-path> <project-name>}"

mkdir -p "$repo/raw" "$repo/wiki" "$repo/graph"
touch "$repo/raw/.gitkeep" "$repo/wiki/.gitkeep" "$repo/graph/.gitkeep"
printf 'project = %s\n' "$project" > "$repo/.research-graph"

echo "Scaffolded $repo"
echo "  project = $project   (.research-graph marker)"
echo "  raw/ wiki/ graph/ created"
echo "Next: enable the tendrel plugin in this repo, then work normally."
