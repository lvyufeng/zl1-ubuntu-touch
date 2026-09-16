# External build tree

Keep large Android/Halium sources outside this repository.

Recommended path:

```text
/mnt/data/halium-zl1-build
```

This repo stores only:

- documentation
- local manifests
- small helper scripts
- build summaries

It should not store:

- `.repo`
- Android source trees
- `out/` build output
- partition images
- downloaded ROM zips
- Ubuntu Touch rootfs images

## Setup script

Use:

```bash
scripts/setup-halium9-tree.sh /mnt/data/halium-zl1-build
scripts/sync-halium9-tree.sh /mnt/data/halium-zl1-build
```

The setup script should refuse to initialize inside `/mnt/data/zl1-bb10`.

## `repo` tool

The setup/sync scripts automatically include `$HOME/bin` in `PATH`. In this environment the `repo` launcher was installed at:

```text
/home/lvyufeng/bin/repo
```

If a new shell cannot find `repo`, either run scripts from this repository or add this to the shell profile:

```bash
export PATH="$HOME/bin:$PATH"
```

## Sync parallelism

The sync script defaults to `JOBS=8` instead of raw `nproc` to avoid excessive concurrent network jobs. Override with `JOBS=<n>` if needed.
