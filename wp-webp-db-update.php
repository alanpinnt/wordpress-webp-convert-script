#!/usr/bin/env php
<?php
/**
 * wp-webp-db-update.php — WordPress WebP Database Updater
 *
 * Companion script to wp-webp-convert.sh. Handles all database operations
 * for WebP image conversion, including safe handling of PHP serialized data
 * and Elementor page builder support.
 *
 * Commands:
 *   parse       <wp-config>                                Parse DB credentials → JSON
 *   list        <wp-config>                                List image attachment paths (one per line)
 *   info        <wp-config> <relative-path>                Get thumbnail filenames (one per line)
 *   update      <wp-config> <old-path> <new-path> <w> <h>  Update all DB references for one image
 *   flush-cache <wp-config>                                Clear Elementor CSS cache
 */

// ─── Helpers ────────────────────────────────────────────────────────────────

function err(string $msg): void {
    fwrite(STDERR, "ERROR: $msg\n");
}

function warn(string $msg): void {
    fwrite(STDERR, "WARN: $msg\n");
}

function usage(): int {
    fwrite(STDERR, "WordPress WebP Database Updater\n\n");
    fwrite(STDERR, "Usage:\n");
    fwrite(STDERR, "  php wp-webp-db-update.php parse        <wp-config.php>\n");
    fwrite(STDERR, "  php wp-webp-db-update.php get-password <wp-config.php>\n");
    fwrite(STDERR, "  php wp-webp-db-update.php list         <wp-config.php>\n");
    fwrite(STDERR, "  php wp-webp-db-update.php info        <wp-config.php> <relative-path>\n");
    fwrite(STDERR, "  php wp-webp-db-update.php update      <wp-config.php> <old-path> <new-path> <width> <height>\n");
    fwrite(STDERR, "  php wp-webp-db-update.php flush-cache <wp-config.php>\n");
    return 1;
}

// ─── Config Parsing ─────────────────────────────────────────────────────────

function extract_define(string $config, string $name): ?string {
    // Match both single and double quoted values, including empty strings
    $escaped = preg_quote($name, '/');
    // Try single quotes first: define('NAME', 'value')
    if (preg_match("/define\s*\(\s*['\"]" . $escaped . "['\"]\s*,\s*'([^']*)'\s*\)/", $config, $m)) {
        return $m[1];
    }
    // Try double quotes: define("NAME", "value")
    if (preg_match("/define\s*\(\s*['\"]" . $escaped . "['\"]\s*,\s*\"([^\"]*)\"\s*\)/", $config, $m)) {
        return $m[1];
    }
    return null;
}

function extract_table_prefix(string $config): string {
    if (preg_match('/\$table_prefix\s*=\s*[\'"](.+?)[\'"]\s*;/', $config, $m)) {
        return $m[1];
    }
    return 'wp_';
}

function parse_wp_config(string $content): array {
    $required = ['DB_NAME', 'DB_USER', 'DB_PASSWORD', 'DB_HOST'];
    $result = [];

    foreach ($required as $key) {
        $val = extract_define($content, $key);
        if ($val === null) {
            // DB_PASSWORD can legitimately be absent (defaults to empty)
            if ($key === 'DB_PASSWORD') {
                $result['db_password'] = '';
                continue;
            }
            err("Could not find $key in wp-config.php");
            exit(1);
        }
        $result[strtolower($key)] = $val;
    }

    $result['table_prefix'] = extract_table_prefix($content);
    return $result;
}

// ─── Database Connection ────────────────────────────────────────────────────

function validate_prefix(string $prefix): void {
    // Table prefix should only contain alphanumeric chars and underscores
    if (!preg_match('/^[a-zA-Z0-9_]+$/', $prefix)) {
        err("Invalid table prefix: $prefix");
        exit(1);
    }
}

function get_db(array $config): mysqli {
    $db = @new mysqli(
        $config['db_host'],
        $config['db_user'],
        $config['db_password'],
        $config['db_name']
    );

    if ($db->connect_error) {
        err("Database connection failed: " . $db->connect_error);
        exit(1);
    }

    $db->set_charset('utf8mb4');
    return $db;
}

// ─── Command: parse ─────────────────────────────────────────────────────────
// Outputs DB credentials as JSON (password excluded for safety in logs)

function cmd_parse(array $config): int {
    echo json_encode([
        'db_name'      => $config['db_name'],
        'db_user'      => $config['db_user'],
        'db_host'      => $config['db_host'],
        'table_prefix' => $config['table_prefix'],
    ]) . "\n";
    return 0;
}

// ─── Command: get-password ──────────────────────────────────────────────────
// Outputs raw DB password to stdout. Separate from parse to avoid logging it.

function cmd_get_password(array $config): int {
    echo $config['db_password'];
    return 0;
}

// ─── Command: list ──────────────────────────────────────────────────────────
// Lists all image attachments (JPEG/PNG) tracked in the database.
// Outputs one relative path per line (relative to wp-content/uploads/).

function cmd_list(array $config): int {
    $prefix = $config['table_prefix'];
    validate_prefix($prefix);
    $db = get_db($config);

    $sql = "SELECT pm.meta_value AS file_path
            FROM {$prefix}postmeta pm
            INNER JOIN {$prefix}posts p ON p.ID = pm.post_id
            WHERE pm.meta_key = '_wp_attached_file'
              AND p.post_type = 'attachment'
              AND p.post_mime_type IN ('image/jpeg', 'image/png')
            ORDER BY pm.meta_value";

    $result = $db->query($sql);
    if (!$result) {
        err("Query failed: " . $db->error);
        $db->close();
        return 1;
    }

    while ($row = $result->fetch_assoc()) {
        echo $row['file_path'] . "\n";
    }

    $db->close();
    return 0;
}

// ─── Command: info ──────────────────────────────────────────────────────────
// For a given main attachment file, outputs its thumbnail filenames (one per line).
// Filenames are basename only (e.g., hero-banner-150x150.jpg), not full paths.
// Outputs nothing if the file is not a tracked attachment or has no thumbnails.

function cmd_info(array $config, string $rel_path): int {
    $prefix = $config['table_prefix'];
    validate_prefix($prefix);
    $db = get_db($config);

    $stmt = $db->prepare(
        "SELECT pm2.meta_value AS metadata
         FROM {$prefix}postmeta pm
         LEFT JOIN {$prefix}postmeta pm2
           ON pm2.post_id = pm.post_id AND pm2.meta_key = '_wp_attachment_metadata'
         WHERE pm.meta_key = '_wp_attached_file' AND pm.meta_value = ?"
    );
    $stmt->bind_param('s', $rel_path);
    $stmt->execute();
    $result = $stmt->get_result();
    $row = $result->fetch_assoc();

    if (!$row || !$row['metadata']) {
        $db->close();
        return 0;
    }

    $metadata = @unserialize($row['metadata']);
    if (!is_array($metadata) || !isset($metadata['sizes'])) {
        $db->close();
        return 0;
    }

    foreach ($metadata['sizes'] as $size_data) {
        if (isset($size_data['file'])) {
            echo $size_data['file'] . "\n";
        }
    }

    $db->close();
    return 0;
}

// ─── Command: update ────────────────────────────────────────────────────────
// Updates all database references for a converted image:
//   1. _wp_attached_file (plain string)
//   2. _wp_attachment_metadata (serialized PHP — must unserialize/reserialize)
//   3. wp_posts.guid (URL)
//   4. wp_posts.post_mime_type
//   5. wp_posts.post_content (image URLs in posts/pages)
//   6. Elementor _elementor_data (JSON, handles escaped slashes)

function cmd_update(array $config, string $old_rel, string $new_rel, int $width, int $height): int {
    $prefix = $config['table_prefix'];
    validate_prefix($prefix);
    $db = get_db($config);

    $old_basename = basename($old_rel);
    $new_basename = basename($new_rel);
    $old_dir = dirname($old_rel);
    // dirname() returns '.' for files with no directory component — normalize to empty
    if ($old_dir === '.') {
        $old_dir = '';
    }

    // Collect thumbnail old→new relative paths for content replacements
    $thumbnail_replacements = [];

    // ── 1. Find attachment ID ───────────────────────────────────────────

    $stmt = $db->prepare(
        "SELECT post_id FROM {$prefix}postmeta
         WHERE meta_key = '_wp_attached_file' AND meta_value = ?"
    );
    $stmt->bind_param('s', $old_rel);
    $stmt->execute();
    $result = $stmt->get_result();
    $row = $result->fetch_assoc();

    if (!$row) {
        warn("No attachment found for $old_rel — skipping DB update");
        $db->close();
        return 0;
    }

    $attachment_id = (int)$row['post_id'];

    // ── 2. Update _wp_attached_file (plain string) ──────────────────────

    $stmt = $db->prepare(
        "UPDATE {$prefix}postmeta SET meta_value = ?
         WHERE post_id = ? AND meta_key = '_wp_attached_file'"
    );
    $stmt->bind_param('si', $new_rel, $attachment_id);
    $stmt->execute();

    // ── 3. Update _wp_attachment_metadata (serialized) ──────────────────
    // This is the critical part. PHP serialized data encodes string byte
    // lengths, so we MUST unserialize → modify → reserialize. A raw SQL
    // REPLACE would corrupt the data.

    $stmt = $db->prepare(
        "SELECT meta_value FROM {$prefix}postmeta
         WHERE post_id = ? AND meta_key = '_wp_attachment_metadata'"
    );
    $stmt->bind_param('i', $attachment_id);
    $stmt->execute();
    $result = $stmt->get_result();
    $meta_row = $result->fetch_assoc();

    if ($meta_row && $meta_row['meta_value']) {
        $metadata = @unserialize($meta_row['meta_value']);

        if (is_array($metadata)) {
            // Main file reference
            if (isset($metadata['file'])) {
                $metadata['file'] = $new_rel;
            }

            // Dimensions (updated if the image was resized)
            if ($width > 0 && $height > 0) {
                $metadata['width'] = $width;
                $metadata['height'] = $height;
            }

            // Thumbnail references
            if (isset($metadata['sizes']) && is_array($metadata['sizes'])) {
                foreach ($metadata['sizes'] as $size_name => &$size_data) {
                    if (isset($size_data['file'])) {
                        $old_thumb = $size_data['file'];
                        $new_thumb = preg_replace('/\.(jpe?g|png)$/i', '.webp', $old_thumb);
                        $size_data['file'] = $new_thumb;

                        // Track for post_content and Elementor replacements
                        $old_thumb_rel = $old_dir !== '' ? $old_dir . '/' . $old_thumb : $old_thumb;
                        $new_thumb_rel = $old_dir !== '' ? $old_dir . '/' . $new_thumb : $new_thumb;
                        $thumbnail_replacements[$old_thumb_rel] = $new_thumb_rel;
                    }
                    if (isset($size_data['mime-type'])) {
                        $size_data['mime-type'] = 'image/webp';
                    }
                }
                unset($size_data);
            }

            // Reserialize and save
            $new_meta = serialize($metadata);
            $stmt = $db->prepare(
                "UPDATE {$prefix}postmeta SET meta_value = ?
                 WHERE post_id = ? AND meta_key = '_wp_attachment_metadata'"
            );
            $stmt->bind_param('si', $new_meta, $attachment_id);
            $stmt->execute();
        }
    }

    // ── 4. Update wp_posts GUID ─────────────────────────────────────────

    $stmt = $db->prepare(
        "UPDATE {$prefix}posts SET guid = REPLACE(guid, ?, ?)
         WHERE ID = ? AND post_type = 'attachment'"
    );
    $stmt->bind_param('ssi', $old_basename, $new_basename, $attachment_id);
    $stmt->execute();

    // ── 5. Update post_mime_type ────────────────────────────────────────

    $stmt = $db->prepare(
        "UPDATE {$prefix}posts SET post_mime_type = 'image/webp'
         WHERE ID = ? AND post_type = 'attachment'"
    );
    $stmt->bind_param('i', $attachment_id);
    $stmt->execute();

    // ── 6. Replace image URLs in post_content ───────────────────────────
    // Uses the full relative path (e.g., 2024/03/hero.jpg) to avoid
    // false matches with similarly-named files.

    $content_rows = 0;

    // Main file
    $stmt = $db->prepare(
        "UPDATE {$prefix}posts SET post_content = REPLACE(post_content, ?, ?)
         WHERE post_content LIKE CONCAT('%', ?, '%')"
    );
    $stmt->bind_param('sss', $old_rel, $new_rel, $old_rel);
    $stmt->execute();
    $content_rows += max(0, $db->affected_rows);

    // Thumbnails
    foreach ($thumbnail_replacements as $old_thumb_rel => $new_thumb_rel) {
        $stmt = $db->prepare(
            "UPDATE {$prefix}posts SET post_content = REPLACE(post_content, ?, ?)
             WHERE post_content LIKE CONCAT('%', ?, '%')"
        );
        $stmt->bind_param('sss', $old_thumb_rel, $new_thumb_rel, $old_thumb_rel);
        $stmt->execute();
        $content_rows += max(0, $db->affected_rows);
    }

    // ── 7. Elementor: _elementor_data ───────────────────────────────────
    // Elementor stores page data as JSON in wp_postmeta. JSON doesn't
    // encode string byte lengths like PHP serialization, so SQL REPLACE
    // is safe here.
    //
    // Elementor JSON often escapes forward slashes (2024\/03\/hero.jpg),
    // so we do two passes: one for unescaped paths, one for escaped.

    $elementor_rows = 0;

    // Build list of all replacements (main file + thumbnails)
    $all_replacements = array_merge(
        [$old_rel => $new_rel],
        $thumbnail_replacements
    );

    foreach ($all_replacements as $old_path => $new_path) {
        // Unescaped version
        $stmt = $db->prepare(
            "UPDATE {$prefix}postmeta SET meta_value = REPLACE(meta_value, ?, ?)
             WHERE meta_key = '_elementor_data' AND meta_value LIKE CONCAT('%', ?, '%')"
        );
        $stmt->bind_param('sss', $old_path, $new_path, $old_path);
        $stmt->execute();
        $elementor_rows += max(0, $db->affected_rows);

        // JSON-escaped version (forward slashes escaped as \/)
        $old_escaped = str_replace('/', '\\/', $old_path);
        $new_escaped = str_replace('/', '\\/', $new_path);
        if ($old_escaped !== $old_path) {
            $stmt = $db->prepare(
                "UPDATE {$prefix}postmeta SET meta_value = REPLACE(meta_value, ?, ?)
                 WHERE meta_key = '_elementor_data' AND meta_value LIKE CONCAT('%', ?, '%')"
            );
            $stmt->bind_param('sss', $old_escaped, $new_escaped, $old_escaped);
            $stmt->execute();
            $elementor_rows += max(0, $db->affected_rows);
        }
    }

    $db->close();

    echo "OK attachment_id=$attachment_id content_rows=$content_rows elementor_rows=$elementor_rows\n";
    return 0;
}

// ─── Command: flush-cache ───────────────────────────────────────────────────
// Clears Elementor's CSS cache so it regenerates with the new image URLs.
// Call this once after all image updates are complete.

function cmd_flush_cache(array $config): int {
    $prefix = $config['table_prefix'];
    validate_prefix($prefix);
    $db = get_db($config);

    // Elementor per-post CSS cache
    $stmt = $db->query("DELETE FROM {$prefix}postmeta WHERE meta_key = '_elementor_css'");
    $post_css = $db->affected_rows;

    // Elementor global CSS cache
    $db->query("DELETE FROM {$prefix}options WHERE option_name = '_elementor_global_css'");

    // Elementor CSS last updated timestamp (forces regeneration on next load)
    $db->query("DELETE FROM {$prefix}options WHERE option_name = '_elementor_css_updated_time'");

    $db->close();

    echo "OK elementor_css_cleared=$post_css\n";
    return 0;
}

// ─── Main ───────────────────────────────────────────────────────────────────

function main(int $argc, array $argv): int {
    if ($argc < 3) {
        return usage();
    }

    $command = $argv[1];
    $wp_config_path = $argv[2];

    if (!file_exists($wp_config_path)) {
        err("File not found: $wp_config_path");
        return 1;
    }

    $content = file_get_contents($wp_config_path);
    $config = parse_wp_config($content);

    switch ($command) {
        case 'parse':
            return cmd_parse($config);

        case 'get-password':
            return cmd_get_password($config);

        case 'list':
            return cmd_list($config);

        case 'info':
            if ($argc < 4) return usage();
            return cmd_info($config, $argv[3]);

        case 'update':
            if ($argc < 7) return usage();
            return cmd_update($config, $argv[3], $argv[4], (int)$argv[5], (int)$argv[6]);

        case 'flush-cache':
            return cmd_flush_cache($config);

        default:
            err("Unknown command: $command");
            return usage();
    }
}

exit(main($argc, $argv));
