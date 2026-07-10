---
title: "Immich — bulk import from Google Photos"
description: "Reproducible procedure to migrate a full Google Photos library into Immich with immich-go: single-pass import staged on the ZFS dataset, with two Takeout transport options (Drive+rclone or email link+scp), plus the metadata/duplicate pitfalls to watch."
---

# Immich — bulk import from Google Photos

One-shot migration of an entire Google Photos library into the homelab's
[Immich](immich.md) instance, using **immich-go** (`from-google-photos`). This is a
runtime operation — no IaC is changed, nothing is installed on the Proxmox host.

The whole thing runs **inside the Immich LXC** (104, `192.168.1.63`), against the
Immich server on loopback `:2283`, with the Takeout archives staged on the
`rpool/data/immich-photos` dataset (852 GB free). Two ways to get the Takeout parts
onto the dataset — pick based on your **Google Drive free space**:

- **Option A — Add to Drive + rclone.** Cleanest and mostly automated, but the export
  is written into your Drive and **counts against your Google quota**. Only viable if
  Drive has enough free space to hold the whole export.
- **Option B — Send download link via email + browser + scp.** Google hosts the
  archive temporarily and emails download links; **nothing touches your Drive quota**.
  You download the parts through a logged-in browser on `thallium`, then relay them to
  the LXC. More manual, but immune to a full Drive. Recommended when Drive is short on
  space.

## The one rule that dictates everything: single pass

**Import all Takeout zip parts together, in a single `immich-go` run
(`takeout-*.zip`).** Google Takeout splits a photo, its `.json` sidecar (date + GPS)
and the album metadata across *different* zip parts. With immich-go's defaults
(`--include-unmatched=false`), a photo whose sidecar lands in another part is
**skipped entirely** — lost, not merely undated — and albums whose metadata is alone
in a part are **not created**.

A part-by-part import therefore silently drops photos and breaks albums. Because the
workstation (`thallium`, ~38 GB free) can't stage the archives, the import runs on
the LXC where the 852 GB dataset can hold the whole Takeout at once.

## Points of attention

| # | Watch out for | Mitigation |
|---|---|---|
| 1 | **Google Drive quota** (Option A only) — a Takeout to Drive consumes 30–150 GB of quota | Either switch to **Option B** (email link — no Drive usage), or export **year by year**, rclone-then-`rm` each year onto the LXC, **then** one import pass over the whole set |
| 2 | **Edited-photo duplicates** — Takeout ships `photo.jpg` *and* `photo-edited.jpg`; both are uploaded. Same for **Live Photos** (still + live) | Clean up afterwards in Immich: **Utilities → Review Duplicates → Deduplicate all** |
| 3 | **GPS loss** on some sidecars (`geoData` vs `geoDataExif` quirk) | Verify GPS on a random sample after import |
| 4 | **Google omits the `.json`** for some files | Use `--include-unmatched=true` so those import with EXIF-only metadata instead of being dropped; if many are missing, request a fresh Takeout |
| 5 | **Not in the Takeout at all**: Trash and Locked Folder | Expected — nothing to do |
| 6 | **Do not delete anything on the Google side** until Immich is verified | Google stays the source of truth until counts + samples + albums + GPS all check out |
| 7 | Split boundaries increase with more parts | Use the largest part size your transport disk allows — **50 GB** for Option A (Drive); **10 GB** for Option B so each part fits in `thallium`'s ~38 GB free while relaying |
| 8 | **`.zip`, not `.tgz`** | immich-go reads `.zip` archives directly (random access); `.tgz` is a sequential stream and is not the supported path |
| 9 | **Email links expire** (~1 week, Option B) | Download the parts promptly; the links need your logged-in Google session, so use a browser on `thallium` (not headless on the LXC) |

## Procedure

### 1. Export from Google Takeout

- <https://takeout.google.com/settings/takeout> → **Deselect all**, tick only
  **Google Photos**. Format **.zip** (point of attention #8). Export once.
- **Destination and part size depend on your transport option:**
  - **Option A (Add to Drive):** destination **"Add to Drive"**, part size **50 GB**.
    Confirm Drive has room first (point of attention #1; otherwise export per year).
  - **Option B (email link):** destination **"Send download link via email"**, part
    size **10 GB** (so each part fits on `thallium` while relaying — point #7).
- Wait for the "your archive is ready" email (hours to days).

### 2. Install immich-go on the Immich LXC

```bash
ssh root@192.168.1.63
# immich-go: static Go binary from the GitHub releases (linux amd64)
#   -> drop into /usr/local/bin/immich-go, chmod +x
immich-go version          # expect 0.32.x or newer (Immich V3 compatible)
mkdir -p /mnt/immich-photos/_takeout-staging   # staging dir, sibling of library/
```

`_takeout-staging` is a sibling of `library/`, so Immich never scans it. Staging
(≤150 GB) plus the imported copies (≤150 GB) fit comfortably in 852 GB.

### 3. Get all parts onto the dataset — pick your option

**Option A — rclone from Google Drive** (Drive has the room):

```bash
apt-get install -y rclone   # if not already present
rclone config
#   n) new remote  ->  name: gdrive  ->  type: drive  ->  scope: drive.readonly
# Headless auth: run `rclone authorize "drive"` on thallium (has a browser),
# paste the returned token back into the rclone config session on the LXC.
rclone lsd gdrive:Takeout    # verify the parts are visible
rclone copy gdrive:Takeout /mnt/immich-photos/_takeout-staging \
  --include 'takeout-*.zip' --progress --transfers=4
```

**Option B — browser download + scp** (no Drive quota used):

Download the parts from the email links through a logged-in browser on `thallium`,
then relay them to the LXC **one at a time** so the ~38 GB free is never exceeded:

```bash
# on thallium, for each downloaded part:
rsync -P ~/Downloads/takeout-NNN.zip \
  root@192.168.1.63:/mnt/immich-photos/_takeout-staging/
rm ~/Downloads/takeout-NNN.zip        # free local space, download the next part
```

### 4. Confirm every part is staged

```bash
ls -lh /mnt/immich-photos/_takeout-staging   # all takeout-*.zip present?
```

### 5. Create an Immich API key

`https://photos.flefevre.fr` → sign in with the **daily-use account** (imported
assets land in *that* account's library) → Account Settings → **API Keys** → New API
Key.

### 6. Dry run (no writes)

```bash
immich-go upload from-google-photos \
  --server=http://localhost:2283 --api-key=<KEY> --dry-run \
  --include-unmatched=true \
  /mnt/immich-photos/_takeout-staging/takeout-*.zip
```

### 7. Real import — a single pass (run inside tmux/screen; it takes a while)

```bash
immich-go upload from-google-photos \
  --server=http://localhost:2283 \
  --api-key=<KEY> \
  --concurrent-tasks=4 \
  --client-timeout=60m \
  --on-errors=continue \
  --include-unmatched=true \
  --session-tag \
  /mnt/immich-photos/_takeout-staging/takeout-*.zip
```

Useful v0.32 defaults are kept: `--include-archived=true`, `--include-partner=true`,
`--include-trashed=false`, `--sync-albums=true`, and `--pause-immich-jobs=true`
(pauses ML jobs during upload; they resume afterwards). `--concurrent-tasks=4` is
deliberately modest for a 4 vCPU / 6 GB LXC.

immich-go deduplicates and **resumes on interruption** without creating duplicates —
if the run is cut off (network, reboot), just re-run the same command.

### 8. Verify

- Immich **Admin → Jobs**: let ML (face recognition + CLIP) finish. Expect the CPU to
  be busy for a while — this is the normal initial indexing (see [immich.md](immich.md)).
- **Utilities → Review Duplicates → Deduplicate all**: clears edited/original and
  still/live pairs (point of attention #2).
- Compare the **asset count** in Immich against Google Photos.
- Spot-check a sample: correct **date**, **GPS**, and **album** membership.
- `curl http://localhost:2283/api/server/ping` → `{"res":"pong"}`.

### 9. Clean up (only after verification passes)

```bash
rm -rf /mnt/immich-photos/_takeout-staging   # reclaim dataset space
# optional: remove the immich-go binary; for Option A, also remove the rclone
# remote (it holds a Google OAuth token)
```

Then, **only once everything checks out**: for Option A delete the Takeout from
Google Drive to reclaim quota; either way, — your call — stop Google Photos backup.
Keep Google until you're satisfied the migration is complete.

## Notes

- Everything happens **inside the LXC** — immich-go is a one-shot CLI, not a service,
  so this respects the "no user services on the Proxmox host" rule.
- No Terraform/Ansible is touched: this is a runtime operation plus this document.

## Sources

- immich-go — [best-practices](https://github.com/simulot/immich-go/blob/main/docs/best-practices.md),
  [from-google-photos flags (manpage)](https://manpages.debian.org/unstable/immich-go/immich-go-upload-from-google-photos.1.en.html)
- Pitfalls — [#1296 files skipped](https://github.com/simulot/immich-go/issues/1296),
  [#1277 album not created](https://github.com/simulot/immich-go/issues/1277),
  [#841 GPS geoData](https://github.com/simulot/immich-go/issues/841),
  [Takeout omits some JSON](https://support.google.com/photos/thread/328281808),
  [edited/live duplicates](https://o-toole.com/google-photos-to-immich/)
