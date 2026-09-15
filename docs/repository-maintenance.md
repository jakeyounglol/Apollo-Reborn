# Repository Maintenance

## Ownership And Upstream

`Thetromboneman1/Apollo-Reborn` is a maintained fork of
`Apollo-Reborn/Apollo-Reborn`. The upstream project owns product development;
this fork owns only reviewed downstream changes and local build validation.

## Safe Synchronization

1. Fetch upstream `main` and create a dedicated review branch.
2. Merge without force-pushing or rewriting either history.
3. Inspect changes to build, signing, packaging, and release workflows.
4. Run the repository's tests and a bounded build before merging.
5. Keep credentials in GitHub Actions or the Boneman vault. Never add API keys,
   signing material, or decrypted application packages to Git.

The scheduled sync requires a repository Actions secret named
`BONEMAN_UPSTREAM_SYNC_TOKEN`. Use a dedicated fine-grained token with access
only to `Thetromboneman1/Apollo-Reborn` and grant Contents, Pull requests, and
Workflows write permissions. Workflows permission is required because a
review branch can legitimately contain upstream changes under
`.github/workflows/`; the built-in `GITHUB_TOKEN` cannot push those changes.
Rotate the token through GitHub Actions or the Boneman vault, never a tracked
file.

Automated review branches use the
`Thetromboneman1/upstream-sync-<upstream-sha>` naming convention.

If the histories conflict, stop the automated sync and resolve the review
branch manually. Closing the pull request and deleting its branch safely
abandons an update.
