#!/usr/bin/env bash
set -euo pipefail

# ─── WordPress WebP Image Converter ─────────────────────────────────────────
#
# Converts JPEG/PNG images in wp-content/uploads/ to WebP format. Two modes:
#   Full mode   — converts files + updates WordPress database
#   Files only  — converts files only, no database needed
#
# Prerequisites: cwebp, convert, identify (ImageMagick), php-cli, mysqldump
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHP_HELPER="$SCRIPT_DIR/wp-webp-db-update.php"

# ─── Colors ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Utility Functions ───────────────────────────────────────────────────────

info()  { echo -e "    ${GREEN}✓${NC} $*"; }
warn()  { echo -e "    ${YELLOW}⚠${NC} $*"; }
fail()  { echo -e "    ${RED}✗${NC} $*" >&2; }

start_keepalive() {
    ( while true; do printf '.'; sleep 5; done ) &
    KEEPALIVE_PID=$!
}

stop_keepalive() {
    if [[ -n "${KEEPALIVE_PID:-}" ]]; then
        kill "$KEEPALIVE_PID" 2>/dev/null
        wait "$KEEPALIVE_PID" 2>/dev/null
    fi
    KEEPALIVE_PID=""
    printf '\n'
}

format_bytes() {
    local bytes=$1
    if (( bytes >= 1073741824 )); then
        echo "$(( bytes / 1073741824 )).$(( (bytes % 1073741824) * 10 / 1073741824 )) GB"
    elif (( bytes >= 1048576 )); then
        echo "$(( bytes / 1048576 )).$(( (bytes % 1048576) * 10 / 1048576 )) MB"
    elif (( bytes >= 1024 )); then
        echo "$(( bytes / 1024 )) KB"
    else
        echo "$bytes B"
    fi
}

# ─── Dependency Check ────────────────────────────────────────────────────────

check_dependencies() {
    local missing=()
    command -v cwebp    >/dev/null 2>&1 || missing+=("cwebp (apt install webp)")
    command -v convert  >/dev/null 2>&1 || missing+=("convert (apt install imagemagick)")
    command -v identify >/dev/null 2>&1 || missing+=("identify (apt install imagemagick)")

    if (( FILES_ONLY == 0 )); then
        command -v php      >/dev/null 2>&1 || missing+=("php (apt install php-cli)")
        command -v mysqldump >/dev/null 2>&1 || missing+=("mysqldump (apt install mysql-client)")
    fi

    if (( ${#missing[@]} > 0 )); then
        fail "Missing dependencies:"
        for dep in "${missing[@]}"; do
            echo "      - $dep"
        done
        exit 1
    fi

    if (( FILES_ONLY == 0 )); then
        # Check that the PHP helper exists
        if [[ ! -f "$PHP_HELPER" ]]; then
            fail "PHP helper not found: $PHP_HELPER"
            fail "This file must be in the same directory as this script."
            exit 1
        fi

        # Check PHP has mysqli extension
        if ! php -m 2>/dev/null | grep -qi mysqli; then
            fail "PHP mysqli extension is required (apt install php-mysql)"
            exit 1
        fi
    fi
}

# ─── Main Script ─────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}=== WordPress WebP Image Converter ===${NC}"
echo ""

# ── Mode selection ────────────────────────────────────────────────────────

echo "Select mode:"
echo "    (1) Full       — convert files + update WordPress database"
echo "    (2) Files only — convert files, no database operations"
read -rp "Mode (1/2): " MODE_CHOICE

if [[ "$MODE_CHOICE" == "2" ]]; then
    FILES_ONLY=1
    info "Files-only mode selected"
else
    FILES_ONLY=0
    info "Full mode selected"
fi
echo ""

check_dependencies

STEP=0

# ── Step: Locate wp-config.php (full mode only) ─────────────────────────

if (( FILES_ONLY == 0 )); then
    STEP=$(( STEP + 1 ))
    read -rp "[$STEP] Path to wp-config.php: " WP_CONFIG

    if [[ ! -f "$WP_CONFIG" ]]; then
        fail "File not found: $WP_CONFIG"
        exit 1
    fi

    # Make it an absolute path
    WP_CONFIG="$(cd "$(dirname "$WP_CONFIG")" && pwd)/$(basename "$WP_CONFIG")"

    # Parse DB credentials using the PHP helper
    PHP_STDERR=$(mktemp)
    DB_INFO=$(php "$PHP_HELPER" parse "$WP_CONFIG" 2>"$PHP_STDERR") || {
        fail "Failed to parse wp-config.php"
        cat "$PHP_STDERR" >&2
        rm -f "$PHP_STDERR"
        exit 1
    }
    rm -f "$PHP_STDERR"

    # Parse JSON (single PHP call instead of four)
    eval "$(echo "$DB_INFO" | php -r '
        $j = json_decode(file_get_contents("php://stdin"));
        if (!$j) { fwrite(STDERR, "Failed to parse DB credentials JSON\n"); exit(1); }
        echo "DB_NAME=" . escapeshellarg($j->db_name) . "\n";
        echo "DB_USER=" . escapeshellarg($j->db_user) . "\n";
        echo "DB_HOST=" . escapeshellarg($j->db_host) . "\n";
        echo "DB_PREFIX=" . escapeshellarg($j->table_prefix) . "\n";
    ')" || {
        fail "Failed to parse database credentials"
        exit 1
    }

    if [[ -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_HOST" ]]; then
        fail "Could not extract database credentials from wp-config.php"
        exit 1
    fi

    info "Database: ${CYAN}$DB_NAME${NC} | User: ${CYAN}$DB_USER${NC} | Host: ${CYAN}$DB_HOST${NC} | Prefix: ${CYAN}$DB_PREFIX${NC}"

    # Detect uploads directory
    WP_ROOT="$(dirname "$WP_CONFIG")"
    UPLOADS_DIR="$WP_ROOT/wp-content/uploads"

    if [[ ! -d "$UPLOADS_DIR" ]]; then
        warn "Default uploads dir not found: $UPLOADS_DIR"
        read -rp "    Enter uploads directory path: " UPLOADS_DIR
        if [[ ! -d "$UPLOADS_DIR" ]]; then
            fail "Directory not found: $UPLOADS_DIR"
            exit 1
        fi
    else
        echo -e "    Uploads dir: ${CYAN}$UPLOADS_DIR${NC}"
        read -rp "    Use this directory? (y/n): " UPLOADS_CONFIRM
        if [[ ! "$UPLOADS_CONFIRM" =~ ^[Yy]$ ]]; then
            read -rp "    Enter uploads directory path: " UPLOADS_DIR
            if [[ ! -d "$UPLOADS_DIR" ]]; then
                fail "Directory not found: $UPLOADS_DIR"
                exit 1
            fi
        fi
    fi
else
    STEP=$(( STEP + 1 ))
    read -rp "[$STEP] Path to uploads directory: " UPLOADS_DIR

    if [[ ! -d "$UPLOADS_DIR" ]]; then
        fail "Directory not found: $UPLOADS_DIR"
        exit 1
    fi
fi

# Make uploads dir absolute
UPLOADS_DIR="$(cd "$UPLOADS_DIR" && pwd)"

# Count images on disk
DISK_COUNT=$(find "$UPLOADS_DIR" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) | wc -l)
info "$DISK_COUNT image files found on disk"

# Build file list
TRACKED_LIST=$(mktemp)

if (( FILES_ONLY == 0 )); then
    # Full mode: get tracked attachments from database
    if ! php "$PHP_HELPER" list "$WP_CONFIG" > "$TRACKED_LIST" 2>/dev/null; then
        fail "Could not connect to database or query attachments"
        rm -f "$TRACKED_LIST"
        exit 1
    fi
    TRACKED_COUNT=$(wc -l < "$TRACKED_LIST")
    info "$TRACKED_COUNT image attachments tracked in database"
else
    # Files-only mode: find all JPEG/PNG files on disk
    find "$UPLOADS_DIR" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) \
        | sed "s|^$UPLOADS_DIR/||" | sort > "$TRACKED_LIST"
    TRACKED_COUNT=$DISK_COUNT
fi

if (( TRACKED_COUNT == 0 )); then
    warn "No JPEG/PNG images found. Nothing to do."
    rm -f "$TRACKED_LIST"
    exit 0
fi

echo ""

# ── Step: Backup uploads directory ────────────────────────────────────────

STEP=$(( STEP + 1 ))
read -rp "[$STEP] Backup uploads directory? (y/n): " BACKUP_UPLOADS
if [[ "$BACKUP_UPLOADS" =~ ^[Yy] ]]; then
    BACKUP_DATE=$(date +%Y-%m-%d_%H%M%S)
    UPLOADS_BACKUP="$(dirname "$UPLOADS_DIR")/uploads_backup_$BACKUP_DATE"
    echo -e "    → Copying to ${CYAN}$UPLOADS_BACKUP${NC} ..."
    cp -a "$UPLOADS_DIR" "$UPLOADS_BACKUP"
    BACKUP_SIZE=$(du -sh "$UPLOADS_BACKUP" | cut -f1)
    info "Backup complete ($BACKUP_SIZE)"
fi
echo ""

# ── Step: Backup database (full mode only) ────────────────────────────────

if (( FILES_ONLY == 0 )); then
    STEP=$(( STEP + 1 ))
    read -rp "[$STEP] Backup database? (y/n): " BACKUP_DB
    if [[ "$BACKUP_DB" =~ ^[Yy] ]]; then
        BACKUP_DATE=$(date +%Y-%m-%d_%H%M%S)
        DB_BACKUP="$SCRIPT_DIR/database-backup-$BACKUP_DATE.sql"
        echo -e "    → Dumping to ${CYAN}$DB_BACKUP${NC} ..."

        # Extract password via PHP helper (avoids shell escaping issues)
        DB_PASS=$(php "$PHP_HELPER" get-password "$WP_CONFIG" 2>/dev/null)

        # Build mysqldump command (omit -p flag if password is empty to avoid interactive prompt)
        if [[ -n "$DB_PASS" ]]; then
            mysqldump -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" > "$DB_BACKUP" 2>/dev/null
        else
            mysqldump -h"$DB_HOST" -u"$DB_USER" "$DB_NAME" > "$DB_BACKUP" 2>/dev/null
        fi
        DB_BACKUP_SIZE=$(du -sh "$DB_BACKUP" | cut -f1)
        info "Database backup complete ($DB_BACKUP_SIZE)"
    fi
    echo ""
fi

# ── Step: WebP quality ────────────────────────────────────────────────────

STEP=$(( STEP + 1 ))
read -rp "[$STEP] WebP quality (1-100, default 80): " WEBP_QUALITY
WEBP_QUALITY=${WEBP_QUALITY:-80}

# Validate
if ! [[ "$WEBP_QUALITY" =~ ^[0-9]+$ ]] || (( WEBP_QUALITY < 1 || WEBP_QUALITY > 100 )); then
    fail "Invalid quality: $WEBP_QUALITY (must be 1-100)"
    rm -f "$TRACKED_LIST"
    exit 1
fi
info "WebP quality: $WEBP_QUALITY"
echo ""

# ── Step: Max image dimensions ────────────────────────────────────────────

STEP=$(( STEP + 1 ))
echo "[$STEP] Max image dimensions — images larger than this will be resized."
read -rp "    Max width  (default 1920): " MAX_WIDTH
read -rp "    Max height (default 1080): " MAX_HEIGHT
MAX_WIDTH=${MAX_WIDTH:-1920}
MAX_HEIGHT=${MAX_HEIGHT:-1080}
info "Max dimensions: ${MAX_WIDTH}x${MAX_HEIGHT}"
echo ""

# ── Step: Resize target ──────────────────────────────────────────────────

STEP=$(( STEP + 1 ))
echo "[$STEP] Resize target for oversized images (aspect ratio is preserved)."
read -rp "    Target width  (default $MAX_WIDTH): " TARGET_WIDTH
read -rp "    Target height (default $MAX_HEIGHT): " TARGET_HEIGHT
TARGET_WIDTH=${TARGET_WIDTH:-$MAX_WIDTH}
TARGET_HEIGHT=${TARGET_HEIGHT:-$MAX_HEIGHT}
info "Resize target: ${TARGET_WIDTH}x${TARGET_HEIGHT}"
echo ""

# ── Step: Minimum file size ──────────────────────────────────────────────

STEP=$(( STEP + 1 ))
read -rp "[$STEP] Minimum file size to process in KB (default 50): " MIN_SIZE_KB
MIN_SIZE_KB=${MIN_SIZE_KB:-50}
MIN_SIZE_BYTES=$(( MIN_SIZE_KB * 1024 ))
info "Skipping files under ${MIN_SIZE_KB} KB"
echo ""

# ── Step: Parallel workers ───────────────────────────────────────────

STEP=$(( STEP + 1 ))
DETECTED_CORES=$(nproc 2>/dev/null || echo 4)
read -rp "[$STEP] Parallel conversion workers (default $DETECTED_CORES): " PARALLEL_JOBS
PARALLEL_JOBS=${PARALLEL_JOBS:-$DETECTED_CORES}
if ! [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] || (( PARALLEL_JOBS < 1 )); then
    PARALLEL_JOBS=$DETECTED_CORES
fi
info "Parallel workers: $PARALLEL_JOBS"
echo ""

# ── Step: Confirm ─────────────────────────────────────────────────────────

STEP=$(( STEP + 1 ))
echo -e "${BOLD}Settings summary:${NC}"
echo "    Uploads:     $UPLOADS_DIR"
if (( FILES_ONLY == 0 )); then
    echo "    Database:    $DB_NAME ($DB_HOST)"
    echo "    Attachments: $TRACKED_COUNT tracked in database"
else
    echo "    Images:      $TRACKED_COUNT found on disk"
fi
echo "    Quality:     $WEBP_QUALITY"
echo "    Max size:    ${MAX_WIDTH}x${MAX_HEIGHT}"
echo "    Resize to:   ${TARGET_WIDTH}x${TARGET_HEIGHT}"
echo "    Min file:    ${MIN_SIZE_KB} KB"
echo "    Workers:     $PARALLEL_JOBS parallel"
echo ""
read -rp "[$STEP] Ready to process. Proceed? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
    echo "Aborted."
    rm -f "$TRACKED_LIST"
    exit 0
fi
echo ""

# ─── Processing ──────────────────────────────────────────────────────────────

LOG_FILE="$SCRIPT_DIR/wp-webp-convert-$(date +%Y-%m-%d_%H%M%S).log"
CONVERTED=0
SKIPPED=0
ERRORS=0
TOTAL_SAVED=0
START_TIME=$(date +%s)

# Create temp work directory for parallel processing
WORK_DIR=$(mktemp -d)
RESULTS_DIR="$WORK_DIR/results"
THUMB_DIR="$WORK_DIR/thumbs"
mkdir -p "$RESULTS_DIR" "$THUMB_DIR"

# ─── Start PHP Batch Daemon (full mode only) ─────────────────────────────────

cleanup() {
    rm -rf "$WORK_DIR" 2>/dev/null
    if [[ -n "${PHP_DAEMON_PID_SAVED:-}" ]] && kill -0 "$PHP_DAEMON_PID_SAVED" 2>/dev/null; then
        exec {PHP_DAEMON[1]}>&- 2>/dev/null
        wait "$PHP_DAEMON_PID_SAVED" 2>/dev/null
    fi
}
trap cleanup EXIT

if (( FILES_ONLY == 0 )); then
    coproc PHP_DAEMON { php "$PHP_HELPER" batch "$WP_CONFIG" 2>/dev/null; }
    PHP_DAEMON_PID_SAVED="$PHP_DAEMON_PID"

    # Send a command to the PHP daemon and read the response.
    # Each command produces exactly one response line.
    php_cmd() {
        printf '%s\n' "$1" >&"${PHP_DAEMON[1]}" 2>/dev/null || return 1
        IFS= read -r REPLY <&"${PHP_DAEMON[0]}" || return 1
        printf '%s' "$REPLY"
    }
fi

# ─── Phase 1: Pre-fetch thumbnail info (full mode only) ──────────────────────
# Query the daemon for each image's thumbnails upfront so the parallel
# conversion workers can process thumbnails without needing DB access.

if (( FILES_ONLY == 0 )); then
    echo -n "Pre-fetching thumbnail info for $TRACKED_COUNT attachments..."
    PREFETCH_CURRENT=0
    while IFS= read -r REL_PATH; do
        PREFETCH_CURRENT=$(( PREFETCH_CURRENT + 1 ))
        KEY=$(printf '%s' "$REL_PATH" | md5sum | cut -d' ' -f1)
        DAEMON_RESP=$(php_cmd "$(printf 'INFO\t%s' "$REL_PATH")")
        if [[ "$DAEMON_RESP" == THUMBS$'\t'* ]]; then
            printf '%s' "${DAEMON_RESP#THUMBS	}" | tr '\t' '\n' > "$THUMB_DIR/$KEY"
        fi
        if (( PREFETCH_CURRENT % 100 == 0 )); then
            printf '\r    Pre-fetching thumbnail info: %d/%d' "$PREFETCH_CURRENT" "$TRACKED_COUNT"
        fi
    done < "$TRACKED_LIST"
    printf '\r    Pre-fetching thumbnail info: %d/%d\n' "$TRACKED_COUNT" "$TRACKED_COUNT"
    info "Thumbnail info collected"
    echo ""
fi

# ─── Phase 2: Parallel image conversion ──────────────────────────────────────
# Write a self-contained worker script that handles resize + cwebp for one
# image plus its thumbnails. Workers write results to individual files in
# RESULTS_DIR, avoiding the need for locking.

WORKER_SCRIPT="$WORK_DIR/worker.sh"
cat > "$WORKER_SCRIPT" << 'WORKER_EOF'
#!/usr/bin/env bash
set -uo pipefail

REL_PATH="$1"
FILEPATH="$UPLOADS_DIR/$REL_PATH"
KEY=$(printf '%s' "$REL_PATH" | md5sum | cut -d' ' -f1)
RESULT_FILE="$RESULTS_DIR/$KEY"

# Check if file exists
if [[ ! -f "$FILEPATH" ]]; then
    WEBP_CHECK="${FILEPATH%.*}.webp"
    if [[ -f "$WEBP_CHECK" ]]; then
        printf 'SKIPPED\t%s\tWebP already exists\n' "$REL_PATH" > "$RESULT_FILE"
    else
        printf 'SKIPPED\t%s\tfile not found\n' "$REL_PATH" > "$RESULT_FILE"
    fi
    exit 0
fi

# Check file size
FILE_SIZE=$(stat -c%s "$FILEPATH" 2>/dev/null || echo 0)
if (( FILE_SIZE < MIN_SIZE_BYTES )); then
    printf 'SKIPPED\t%s\t%s < %s KB\n' "$REL_PATH" "$FILE_SIZE" "$MIN_SIZE_KB" > "$RESULT_FILE"
    exit 0
fi

# Get dimensions
DIMENSIONS=$(identify -format '%wx%h' "$FILEPATH[0]" 2>/dev/null || echo "0x0")
CUR_WIDTH="${DIMENSIONS%%x*}"
CUR_HEIGHT="${DIMENSIONS##*x}"
FINAL_WIDTH="$CUR_WIDTH"
FINAL_HEIGHT="$CUR_HEIGHT"

# Resize if exceeding max dimensions (maintain aspect ratio, only shrink)
if (( CUR_WIDTH > MAX_WIDTH || CUR_HEIGHT > MAX_HEIGHT )); then
    if ! mogrify -resize "${TARGET_WIDTH}x${TARGET_HEIGHT}>" -quality 95 "$FILEPATH" 2>/dev/null; then
        printf 'ERROR\t%s\tresize failed\n' "$REL_PATH" > "$RESULT_FILE"
        exit 0
    fi
    NEW_DIMS=$(identify -format '%wx%h' "$FILEPATH[0]" 2>/dev/null || echo "0x0")
    FINAL_WIDTH="${NEW_DIMS%%x*}"
    FINAL_HEIGHT="${NEW_DIMS##*x}"
fi

# Convert main image to WebP
WEBP_PATH="${FILEPATH%.*}.webp"
ORIG_SIZE=$(stat -c%s "$FILEPATH" 2>/dev/null || echo 0)

if ! cwebp -q "$WEBP_QUALITY" "$FILEPATH" -o "$WEBP_PATH" -quiet 2>/dev/null; then
    printf 'ERROR\t%s\tcwebp failed\n' "$REL_PATH" > "$RESULT_FILE"
    exit 0
fi

WEBP_SIZE=$(stat -c%s "$WEBP_PATH" 2>/dev/null || echo 0)

# Only keep if WebP is actually smaller
if (( WEBP_SIZE >= ORIG_SIZE )); then
    rm -f "$WEBP_PATH"
    printf 'SKIPPED\t%s\tWebP not smaller\n' "$REL_PATH" > "$RESULT_FILE"
    exit 0
fi

SAVED=$(( ORIG_SIZE - WEBP_SIZE ))
SAVINGS_PCT=0
if (( ORIG_SIZE > 0 )); then
    SAVINGS_PCT=$(( (SAVED * 100) / ORIG_SIZE ))
fi

# Convert thumbnails
THUMB_CONVERTED=0
THUMB_SAVED=0
DIR_OF_FILE=$(dirname "$FILEPATH")
THUMB_FILE_LIST="$THUMB_DIR/$KEY"

if [[ -f "$THUMB_FILE_LIST" ]]; then
    while IFS= read -r THUMB_FILE; do
        [[ -z "$THUMB_FILE" ]] && continue
        THUMB_PATH="$DIR_OF_FILE/$THUMB_FILE"
        [[ ! -f "$THUMB_PATH" ]] && continue

        THUMB_WEBP="${THUMB_PATH%.*}.webp"
        if cwebp -q "$WEBP_QUALITY" "$THUMB_PATH" -o "$THUMB_WEBP" -quiet 2>/dev/null; then
            T_ORIG=$(stat -c%s "$THUMB_PATH" 2>/dev/null || echo 0)
            T_WEBP=$(stat -c%s "$THUMB_WEBP" 2>/dev/null || echo 0)
            if (( T_WEBP < T_ORIG )); then
                THUMB_SAVED=$(( THUMB_SAVED + T_ORIG - T_WEBP ))
                rm -f "$THUMB_PATH"
                THUMB_CONVERTED=$(( THUMB_CONVERTED + 1 ))
            else
                rm -f "$THUMB_WEBP"
            fi
        fi
    done < "$THUMB_FILE_LIST"
fi

# Remove original
rm -f "$FILEPATH"

WEBP_REL="${REL_PATH%.*}.webp"
TOTAL_SAVED_IMG=$(( SAVED + THUMB_SAVED ))

# Result: CONVERTED REL_PATH WEBP_REL FINAL_W FINAL_H TOTAL_SAVED SAVINGS_PCT THUMB_COUNT ORIG_SIZE WEBP_SIZE
printf 'CONVERTED\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$REL_PATH" "$WEBP_REL" "$FINAL_WIDTH" "$FINAL_HEIGHT" \
    "$TOTAL_SAVED_IMG" "$SAVINGS_PCT" "$THUMB_CONVERTED" "$ORIG_SIZE" "$WEBP_SIZE" \
    > "$RESULT_FILE"
WORKER_EOF
chmod +x "$WORKER_SCRIPT"

# Export variables for workers
export UPLOADS_DIR WEBP_QUALITY MAX_WIDTH MAX_HEIGHT TARGET_WIDTH TARGET_HEIGHT
export MIN_SIZE_BYTES MIN_SIZE_KB RESULTS_DIR THUMB_DIR

echo "Converting $TRACKED_COUNT images ($PARALLEL_JOBS parallel workers)..."
echo "Log: $LOG_FILE"
echo ""

# Run parallel conversion with progress monitoring
xargs -d '\n' -P "$PARALLEL_JOBS" -I {} bash "$WORKER_SCRIPT" {} < "$TRACKED_LIST" &
XARGS_PID=$!

while kill -0 "$XARGS_PID" 2>/dev/null; do
    DONE=$(find "$RESULTS_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l)
    printf '\r    Progress: %d/%d images processed' "$DONE" "$TRACKED_COUNT"
    sleep 1
done
wait "$XARGS_PID"
DONE=$(find "$RESULTS_DIR" -maxdepth 1 -type f | wc -l)
printf '\r    Progress: %d/%d images processed\n' "$DONE" "$TRACKED_COUNT"
echo ""

# ─── Phase 3: Process results + database updates ─────────────────────────────
# Read conversion results, update counters, and send DB metadata updates
# sequentially via the daemon (fast indexed queries).

RESULT_CURRENT=0

for RESULT_FILE in "$RESULTS_DIR"/*; do
    [[ ! -f "$RESULT_FILE" ]] && continue
    RESULT_CURRENT=$(( RESULT_CURRENT + 1 ))
    IFS=$'\t' read -ra PARTS < "$RESULT_FILE"
    STATUS="${PARTS[0]}"

    case "$STATUS" in
        CONVERTED)
            REL_PATH="${PARTS[1]}"
            WEBP_REL="${PARTS[2]}"
            FINAL_WIDTH="${PARTS[3]}"
            FINAL_HEIGHT="${PARTS[4]}"
            IMG_SAVED="${PARTS[5]}"
            SAVINGS_PCT="${PARTS[6]}"
            THUMB_COUNT="${PARTS[7]}"
            ORIG_SIZE="${PARTS[8]}"
            WEBP_SIZE="${PARTS[9]}"

            CONVERTED=$(( CONVERTED + 1 ))
            TOTAL_SAVED=$(( TOTAL_SAVED + IMG_SAVED ))

            echo -e "${BOLD}[$CONVERTED]${NC} $REL_PATH"
            echo -e "    Converted: $(format_bytes "$WEBP_SIZE") (${GREEN}${SAVINGS_PCT}% savings${NC})"
            if (( THUMB_COUNT > 0 )); then
                echo "    Thumbnails: $THUMB_COUNT converted"
            fi

            # Database metadata update (full mode only)
            if (( FILES_ONLY == 0 )); then
                DB_RESULT=$(php_cmd "$(printf 'UPDATE\t%s\t%s\t%s\t%s' "$REL_PATH" "$WEBP_REL" "$FINAL_WIDTH" "$FINAL_HEIGHT")")

                if [[ "$DB_RESULT" == ERROR* ]]; then
                    IFS=$'\t' read -ra ERR_PARTS <<< "$DB_RESULT"
                    fail "    Database update failed: ${ERR_PARTS[1]:-unknown}"
                    echo "ERROR: DB update failed: $REL_PATH" >> "$LOG_FILE"
                    ERRORS=$(( ERRORS + 1 ))
                else
                    IFS=$'\t' read -ra META_PARTS <<< "$DB_RESULT"
                    ATTACH_ID="${META_PARTS[1]:-?}"
                    echo -e "    Database: ${GREEN}✓${NC} attachment #${ATTACH_ID} updated"
                fi
            fi

            echo "CONVERTED: $REL_PATH → $WEBP_REL (saved ${SAVINGS_PCT}%, thumbs: ${THUMB_COUNT})" >> "$LOG_FILE"
            ;;

        SKIPPED)
            REL_PATH="${PARTS[1]}"
            REASON="${PARTS[2]}"
            SKIPPED=$(( SKIPPED + 1 ))
            echo "SKIPPED: $REL_PATH ($REASON)" >> "$LOG_FILE"
            ;;

        ERROR)
            REL_PATH="${PARTS[1]}"
            REASON="${PARTS[2]}"
            ERRORS=$(( ERRORS + 1 ))
            fail "$REL_PATH — $REASON"
            echo "ERROR: $REASON: $REL_PATH" >> "$LOG_FILE"
            ;;
    esac
done

rm -f "$TRACKED_LIST"

# ─── Phase 4: Batch Content Replacement (full mode only) ─────────────────────
# All post_content and Elementor replacements were accumulated during Phase 3
# UPDATE commands. Now flush them — the PHP daemon fetches affected rows,
# applies all replacements in PHP, and writes back only changed rows.

if (( FILES_ONLY == 0 && CONVERTED > 0 )); then
    echo ""
    echo -n "Replacing image references in posts and Elementor data..."
    start_keepalive
    REPLACE_RESULT=$(php_cmd "FLUSH-REPLACE")
    stop_keepalive
    if [[ "$REPLACE_RESULT" == REPLACED* ]]; then
        IFS=$'\t' read -ra REPLACE_PARTS <<< "$REPLACE_RESULT"
        CONTENT_ROWS="${REPLACE_PARTS[1]:-0}"
        ELEM_ROWS="${REPLACE_PARTS[2]:-0}"
        info "Content updated: $CONTENT_ROWS posts, $ELEM_ROWS Elementor entries"
    else
        warn "Content replacement returned unexpected result: $REPLACE_RESULT"
    fi

    echo -n "Flushing Elementor CSS cache..."
    start_keepalive
    FLUSH_RESULT=$(php_cmd "FLUSH-CACHE")
    stop_keepalive
    if [[ "$FLUSH_RESULT" == FLUSHED* ]]; then
        info "Elementor CSS cache cleared"
    else
        warn "Could not flush Elementor cache (may not be installed — this is fine)"
    fi
fi

# ─── Untracked Files Notice (full mode only) ─────────────────────────────────

if (( FILES_ONLY == 0 )); then
    REMAINING=$(find "$UPLOADS_DIR" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) | wc -l)
    if (( REMAINING > 0 )); then
        echo ""
        warn "$REMAINING image files on disk are not tracked in the WordPress database."
        echo "    These may be thumbnails from skipped images, orphaned files, or manually uploaded."
        echo "    They were not processed. You can convert them manually with cwebp if needed."
    fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))
DURATION_MIN=$(( DURATION / 60 ))
DURATION_SEC=$(( DURATION % 60 ))

echo ""
echo -e "${BOLD}=== Complete ===${NC}"
echo "    Converted:  $CONVERTED images"
echo "    Skipped:    $SKIPPED images"
echo "    Errors:     $ERRORS"
echo "    Space saved: $(format_bytes $TOTAL_SAVED)"
echo "    Duration:   ${DURATION_MIN}m ${DURATION_SEC}s"
echo "    Log:        $LOG_FILE"
echo ""

if (( ERRORS > 0 )); then
    warn "There were $ERRORS errors. Check the log for details."
fi

exit 0
