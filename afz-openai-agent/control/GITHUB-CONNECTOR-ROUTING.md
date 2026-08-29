# AFZ GitHub Connector Routing

## Canonical repository

Use `f3arif/homelab-control` for AFZ control/source policy unless a project has a dedicated repository.

## Connector discovery rule

The ChatGPT GitHub connector must use the installed GitHub App repository list / explicit `owner/repo` addressing as the authority for repository access.

Do not treat an empty generic code-search response as evidence that a repository is disconnected. Some accessible repositories may report `is_code_search_indexed=false`.

When code search is unavailable or unindexed:

1. Resolve the repository through the GitHub App installation.
2. Address the repository explicitly as `owner/repo`.
3. Read known files with direct repository/path fetches.
4. Discover directories/branches through repository APIs rather than fuzzy code search.

## AFZ transport authority

- Direct Fabric / Control Hub / typed AFZ agent APIs remain the live execution and worker-authority plane.
- GitHub is the normal source, coordination, durable evidence, policy, and result-summary plane.
- OneDrive/SharePoint is emergency fallback only after GitHub/direct validation.
- Do not create a second GitHub scheduler, lease database, or liveness authority.

## Cutover safety

Keep the existing OneDrive worker available during validation. Disable normal OneDrive polling only after the GitHub/direct path is proven and an emergency fallback procedure is retained.

No legacy branch deletion is part of this change.
