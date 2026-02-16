# WordPress WebP Image Converter

A bash + PHP script that batch-converts JPEG/PNG images to WebP in WordPress `wp-content/uploads/`, updating all database references so WordPress serves the new files seamlessly. No plugins, no external APIs, no ongoing overhead — run it once and your media library is smaller and faster.

---

> **USE AT YOUR OWN RISK.** This script modifies your WordPress files and database directly. It is provided as-is with no warranty. The author is not responsible for any data loss, broken sites, or other issues that may result from using this script. **Always have backups before running it.**

---

## Why Not a Plugin?

WordPress image optimization plugins run inside PHP on every page load or cron cycle. They add database rows, depend on external services with usage limits, and expand your attack surface. When WordPress or PHP updates, they can break — leaving images half-processed with no clear path to undo.

This script runs once from the command line, converts everything, updates the database, and gets out of the way. You get a detailed log of exactly what happened and full backups to roll back if needed.

## How Much Space Does It Save?

WebP typically produces files **60-90% smaller** than JPEG/PNG at equivalent visual quality. A 3 GB media library can drop to under 1 GB. Smaller files mean faster page loads, lower bandwidth costs, and better Core Web Vitals scores.

## Backups — Read This First

This script offers to create backups of your uploads directory and database before it makes any changes. **Use them.** But don't stop there:

- **Keep a separate, independent backup** of your entire WordPress installation (files + database) **before** you even run this script. Copy it to a different machine, an external drive, cloud storage — somewhere completely outside the server this script will run on.
- The script's built-in backups live on the same disk as your site. If something goes wrong with the disk, you lose both.
- **Test your backups.** Make sure you can actually restore from them before you need to.
- If you're running full mode on a production site, do it during a maintenance window. Better yet, test on a staging copy first.

It's a great tool for shrinking your media library, but it rewrites files and database records permanently. Better to be safe than sorry.

## Two Modes

| Mode | What it does | What it needs |
|---|---|---|
| **Full** | Converts files + updates all WordPress database references | `cwebp`, ImageMagick, PHP CLI with `mysqli`, `mysqldump` |
| **Files only** | Converts files, no database changes | `cwebp`, ImageMagick |

**Files-only mode** is perfect for testing on a copy of your uploads directory to see how much space you'd save, or for sites where you don't have database access.

**Full mode** is the real deal — it converts every image and updates every database reference so WordPress, Elementor, Gutenberg, and WP Bakery all serve the new WebP files without any manual intervention.

## Requirements

- Linux (uses `stat -c%s` for file sizes)
- **cwebp** — `apt install webp`
- **ImageMagick** (`convert`, `identify`, `mogrify`) — `apt install imagemagick`
- **PHP CLI with mysqli** (full mode only) — `apt install php-cli php-mysql`
- **mysqldump** (full mode only) — `apt install mysql-client`
- **Bash**

## Quick Start

```bash
git clone <repo-url> && cd wordpress-webp-convert
chmod +x wp-webp-convert.sh
./wp-webp-convert.sh
```

The script is fully interactive — it walks you through every step and asks for confirmation before making changes.

## Full Mode Walkthrough

```
=== WordPress WebP Image Converter ===

Select mode:
    (1) Full       — convert files + update WordPress database
    (2) Files only — convert files, no database operations
Mode (1/2): 1
    ✓ Full mode selected

[1] Path to wp-config.php: /var/www/html/wp-config.php
    ✓ Database: wp_mysite | User: wp_user | Host: localhost | Prefix: wp_
    Uploads dir: /var/www/html/wp-content/uploads
    Use this directory? (y/n): y
    ✓ 2847 image files found on disk
    ✓ 2641 image attachments tracked in database

[2] Backup uploads directory? (y/n): y
    → Copying to /var/www/html/wp-content/uploads_backup_2026-02-14_143022 ...
    ✓ Backup complete (3.2 GB)

[3] Backup database? (y/n): y
    → Dumping to ./database-backup-2026-02-14_143022.sql ...
    ✓ Database backup complete (48 MB)

[4] WebP quality (1-100, default 80): 82
    ✓ WebP quality: 82

[5] Max image dimensions — images larger than this will be resized.
    Max width  (default 1920): 1920
    Max height (default 1080): 1080
    ✓ Max dimensions: 1920x1080

[6] Resize target for oversized images (aspect ratio is preserved).
    Target width  (default 1920): 1920
    Target height (default 1080): 1080
    ✓ Resize target: 1920x1080

[7] Minimum file size to process in KB (default 50): 50
    ✓ Skipping files under 50 KB

Settings summary:
    Uploads:     /var/www/html/wp-content/uploads
    Database:    wp_mysite (localhost)
    Attachments: 2641 tracked in database
    Quality:     82
    Max size:    1920x1080
    Resize to:   1920x1080
    Min file:    50 KB

[8] Ready to process. Proceed? (y/n): y

[1/2641] 2024/03/hero-banner.jpg
    Original: 2560x1440, 1.8 MB
    Resizing to fit 1920x1080...
    Resized:  1920x1080
    Converted: 142 KB (92% savings)
    Thumbnails: 4 converted
    Database: ✓ attachment #1247 updated

[2/2641] 2024/03/icon-small.png
    Skipped (12 KB < 50 KB)

...

Replacing image references in posts and Elementor data...
    ✓ Content updated: 847 posts, 132 Elementor entries
Flushing Elementor CSS cache...
    ✓ Elementor CSS cache cleared

=== Complete ===
    Converted:  2204 images
    Skipped:    437 images
    Errors:     0
    Space saved: 2.1 GB
    Duration:   4m 32s
    Log:        ./wp-webp-convert-2026-02-14_143022.log
```

## What the Script Configures

| Setting | What it controls |
|---|---|
| **WebP quality** (1-100) | Compression level. 80 is a good default. Higher = larger files but sharper. |
| **Max dimensions** | Images larger than this (width or height) get resized before conversion. |
| **Resize target** | What oversized images get resized to. Aspect ratio is always preserved. |
| **Minimum file size** | Files smaller than this are skipped (tiny icons/logos rarely benefit from WebP). |

## What Gets Updated in the Database

Full mode updates every place WordPress stores image references:

| Location | How it's updated | When |
|---|---|---|
| `_wp_attached_file` (file path) | Direct string replacement | Per image |
| `_wp_attachment_metadata` (serialized PHP) | Safe unserialize/modify/reserialize via PHP — raw SQL would corrupt it | Per image |
| `wp_posts.guid` (attachment URL) | String replacement | Per image |
| `wp_posts.post_mime_type` | Set to `image/webp` | Per image |
| `wp_posts.post_content` (image URLs in posts) | Batched string replacement for main image + all thumbnails | End of run |
| `_elementor_data` (Elementor page builder JSON) | Batched string replacement with both escaped and unescaped slash handling | End of run |
| `_elementor_css` (Elementor CSS cache) | Deleted — Elementor regenerates it automatically on next page load | End of run |

The serialized `_wp_attachment_metadata` field is the reason a PHP helper exists. This field encodes string byte lengths (`s:24:"hero-banner.jpg"`), so changing a filename without updating the length prefix corrupts the data. The PHP helper safely deserializes, modifies, and reserializes it.

### Batch Database Architecture

The script uses a two-phase approach to minimize database load:

**Phase 1 — Per-image metadata (during processing):** A single PHP process runs as a persistent daemon for the entire conversion run, connected to the database once. For each image, it updates only the per-attachment fields (`_wp_attached_file`, `_wp_attachment_metadata`, `guid`, `post_mime_type`) using fast, indexed queries. It also accumulates all filename changes (main images + thumbnails) in memory.

**Phase 2 — Bulk content replacement (after processing):** All accumulated old→new path mappings are applied to `post_content` and `_elementor_data` in batched queries — 50 replacements per query using nested SQL `REPLACE()` calls. This turns what would be tens of thousands of full table scans into a few hundred, reducing a multi-hour process to minutes.

The daemon architecture eliminates the overhead of spawning a new PHP process and opening a new database connection for every image. On a site with 2,000+ images, this can reduce full-mode runtime from 12+ hours to under 2 hours.

## Page Builder Support

| Builder | Support |
|---|---|
| **Elementor** | Full — URL replacement in `_elementor_data` JSON + CSS cache flush |
| **WP Bakery / Visual Composer** | Automatic — uses attachment IDs (unchanged) and URLs in `post_content` (replaced) |
| **Gutenberg** | Automatic — image URLs in `post_content` are replaced |
| **Beaver Builder** | Partial — `post_content` is handled, but `_fl_builder_data` (serialized) is not |
| **Divi** | Partial — shortcodes in `post_content` are handled, but `et_pb_*` options in `wp_options` are not |

## Files

| File | Purpose |
|---|---|
| `wp-webp-convert.sh` | Main script — interactive prompts, file backups, image resizing, WebP conversion |
| `wp-webp-db-update.php` | PHP helper — persistent daemon for database operations, serialized metadata handling, batched content replacement, Elementor support |

Both files must be in the same directory. The bash script calls the PHP helper automatically.

## Rollback

If anything goes wrong, restore from the backups the script created:

```bash
# Restore uploads
rm -rf /var/www/html/wp-content/uploads
mv /var/www/html/wp-content/uploads_backup_2026-02-14_143022 /var/www/html/wp-content/uploads

# Restore database (full mode only)
mysql -h localhost -u wp_user -p wp_mysite < ./database-backup-2026-02-14_143022.sql
```

Or better yet, restore from your **independent external backup** that you made before running the script.

## Limitations

- **Single-site WordPress only** — multisite installations use per-site table prefixes (`wp_2_posts`, etc.) and would need additional handling.
- **Standard uploads path** — expects `wp-content/uploads/` relative to `wp-config.php`. The script prompts to confirm or override if the path doesn't exist at the default location.
- **Linux only** — uses `stat -c%s` for file sizes (macOS uses `stat -f%z`).
- **Theme options not updated** — image URLs stored in `wp_options` (theme settings, widget configurations) vary by theme and are not modified.
- **Originals are removed** — after successful conversion, original JPEG/PNG files are deleted. This is why backups are critical.

## Edge Cases Handled

- **Empty database passwords** — common in local/dev setups, handled correctly
- **WebP larger than original** — if WebP produces a bigger file (happens with small or already-optimized images), the original is kept
- **Partial runs** — if the script fails partway through, re-running it skips already-converted files
- **Files in uploads root** — images without year/month subdirectories are handled correctly
- **PHP startup warnings** — stderr is captured separately so timezone notices don't corrupt output
- **Special characters in paths** — all `wp-config.php` parsing goes through the PHP helper, avoiding shell escaping issues
- **Aspect ratio preservation** — resizing uses ImageMagick's bounding box mode; images are never stretched or distorted
- **Thumbnails** — in full mode, thumbnails are converted alongside their parent image and all database references are updated together

## License

MIT
