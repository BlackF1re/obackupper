#!/bin/sh

set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin

LEGACY_SCRIPT_STEM="openwrt_overlay_backupper"
LEGACY_SCRIPT_BASENAME="${LEGACY_SCRIPT_STEM}.sh"
SCRIPT_BASENAME="obackupper.sh"
INSTALL_PATH="/usr/bin/$SCRIPT_BASENAME"
LEGACY_INSTALL_PATH="/usr/bin/$LEGACY_SCRIPT_BASENAME"
SHORTCUT_NAME="obackupper"
SHORTCUT_PATH="/usr/bin/$SHORTCUT_NAME"
CONFIG_PATH="/etc/openwrt_overlay_backupper.conf"
BACKUP_ROOT_DIRNAME="obackupper_backups"
FALLBACK_BACKUP_ROOT="/overlay/share/$BACKUP_ROOT_DIRNAME"
DEFAULT_RESTORE_TARGET="/overlay/upper"

ARCHIVE_NAME="overlay-upper.tar.gz"
PACKAGE_LIST_NAME="installed_packages.txt"
METADATA_NAME="metadata.txt"
CHECKSUMS_NAME="sha256sums.txt"
COMPRESSOR_MODE="pigz"
ALLOW_RAM_BACKUP="0"
REMOVE_INSTALLATION="0"
RETENTION_COUNT="${RETENTION_COUNT:-20}"
AUTO_UPDATE="${AUTO_UPDATE:-1}"
AUTO_UPDATE_URL="${AUTO_UPDATE_URL:-https://raw.githubusercontent.com/BlackF1re/obackupper/main/obackupper.sh}"
AUTO_UPDATE_INTERVAL="${AUTO_UPDATE_INTERVAL:-0}"
SELF_UPDATE_STAMP="/tmp/${SHORTCUT_NAME}.self-update.stamp"
LOCK_DIR="/tmp/${SCRIPT_BASENAME}.lock"
EXIT_CLEANUP_PATHS=""

C_RESET=""
C_BOLD=""
C_RED=""
C_GREEN=""
C_YELLOW=""
C_CYAN=""

BACKUP_ROOT="$FALLBACK_BACKUP_ROOT"
if [ -r "$CONFIG_PATH" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_PATH"
fi

usage() {
    display_backup_root=$(normalize_backup_root_path "$BACKUP_ROOT" 2>/dev/null || echo "$BACKUP_ROOT")
    cat <<EOF
Usage:
  $SCRIPT_BASENAME [--pigz|--gzip] [--allow-ram] backup [DIR]
  $SCRIPT_BASENAME [--pigz|--gzip] restore [DIR] [TARGET]
  $SCRIPT_BASENAME [--pigz|--gzip] list
  $SCRIPT_BASENAME place
  $SCRIPT_BASENAME -remove

Options:
  --pigz               Use pigz (default; requires package pigz)
  --gzip               Use built-in tar gzip mode
  --allow-ram          Allow backup DIR on tmpfs/ramfs
Commands:
  backup [DIR]         Create backup in DIR/<hostname>/<OpenWrt version + timestamp>
  restore [DIR] [TARGET]
                       Restore DIR, or latest backup from BACKUP_ROOT when DIR is omitted; requires confirmation
  list                 Select hostname, then interactively restore or delete a backup
  place                Reconfigure backup storage directory; folder name stays $BACKUP_ROOT_DIRNAME
  -remove              Remove $INSTALL_PATH, $SHORTCUT_PATH, $CONFIG_PATH

Run mode:
  A copy outside /usr/bin auto-installs, hands off to the installed copy, then removes itself.
  Backup/restore/list/place run only from $INSTALL_PATH or $SHORTCUT_PATH.

Config:
  $CONFIG_PATH
  BACKUP_ROOT='$display_backup_root'
  RETENTION_COUNT='$RETENTION_COUNT'   0 disables rotation
  AUTO_UPDATE='$AUTO_UPDATE'           1 enables GitHub self-update on start
  AUTO_UPDATE_INTERVAL='$AUTO_UPDATE_INTERVAL'   0 checks on every start
EOF
}

setup_colors() {
    if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ] && [ "${TERM:-}" != "dumb" ]; then
        C_RESET=$(printf '\033[0m')
        C_BOLD=$(printf '\033[1m')
        C_RED=$(printf '\033[31m')
        C_GREEN=$(printf '\033[32m')
        C_YELLOW=$(printf '\033[33m')
        C_CYAN=$(printf '\033[36m')
    fi
}

log() {
    printf "%s==>%s %s\n" "$C_GREEN" "$C_RESET" "$*"
}

warn() {
    printf "%sWarning:%s %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2
}

die() {
    printf "%sError:%s %s\n" "$C_RED" "$C_RESET" "$*" >&2
    exit 1
}

require_root() {
    [ "$(id -u)" = "0" ] || die "Run this script as root."
}

require_commands() {
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
    done
}

validate_retention_count() {
    case "$RETENTION_COUNT" in
        ''|*[!0-9]*)
            die "RETENTION_COUNT must be a non-negative integer."
            ;;
    esac
}

validate_auto_update_settings() {
    case "$AUTO_UPDATE" in
        0|1)
            ;;
        *)
            die "AUTO_UPDATE must be 0 or 1."
            ;;
    esac

    case "$AUTO_UPDATE_INTERVAL" in
        ''|*[!0-9]*)
            die "AUTO_UPDATE_INTERVAL must be a non-negative integer."
            ;;
    esac

    if [ "$AUTO_UPDATE" = "1" ] && [ -z "$AUTO_UPDATE_URL" ]; then
        die "AUTO_UPDATE_URL must not be empty when AUTO_UPDATE=1."
    fi
}

file_checksum() {
    file_path="$1"
    [ -f "$file_path" ] || return 1
    sha256sum "$file_path" | awk '{print $1}'
}

existing_install_path() {
    if [ -f "$INSTALL_PATH" ]; then
        echo "$INSTALL_PATH"
        return 0
    fi

    if [ -f "$LEGACY_INSTALL_PATH" ]; then
        echo "$LEGACY_INSTALL_PATH"
        return 0
    fi

    return 1
}

installed_script_exists() {
    existing_install_path >/dev/null 2>&1
}

installed_script_differs() {
    current_path="$1"
    installed_path=$(existing_install_path 2>/dev/null || true)

    current_checksum=$(file_checksum "$current_path" 2>/dev/null || true)
    installed_checksum=$(file_checksum "$installed_path" 2>/dev/null || true)

    [ -n "$current_checksum" ] || return 0
    [ -n "$installed_checksum" ] || return 0
    [ "$current_checksum" != "$installed_checksum" ]
}

remove_installed_artifacts() {
    removed_any="0"

    for target_path in "$INSTALL_PATH" "$LEGACY_INSTALL_PATH" "$SHORTCUT_PATH" "$CONFIG_PATH"; do
        if [ -e "$target_path" ] || [ -L "$target_path" ]; then
            rm -f "$target_path"
            echo "Removed: $target_path"
            removed_any="1"
        else
            echo "Not present: $target_path"
        fi
    done

    if [ "$removed_any" = "0" ]; then
        echo "Nothing to remove."
    fi
}

humanize_kib() {
    value_kib="$1"
    awk -v kib="$value_kib" '
        BEGIN {
            split("KiB MiB GiB TiB", unit, " ")
            idx = 1
            value = kib + 0
            while (value >= 1024 && idx < 4) {
                value /= 1024
                idx++
            }
            printf "%.1f %s", value, unit[idx]
        }
    '
}

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$LOCK_DIR/pid"
        trap 'on_exit' EXIT INT TERM HUP
        return 0
    fi

    existing_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
        die "Another instance is already running (PID $existing_pid)."
    fi

    warn "Removing stale lock: $LOCK_DIR"
    rm -rf "$LOCK_DIR"

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$LOCK_DIR/pid"
        trap 'on_exit' EXIT INT TERM HUP
        return 0
    fi

    die "Failed to acquire lock: $LOCK_DIR"
}

register_exit_cleanup_path() {
    cleanup_path="$1"
    [ -n "$cleanup_path" ] || return 0

    case "
$EXIT_CLEANUP_PATHS
" in
        *"
$cleanup_path
"*)
            return 0
            ;;
    esac

    EXIT_CLEANUP_PATHS="${EXIT_CLEANUP_PATHS}${EXIT_CLEANUP_PATHS:+
}$cleanup_path"
}

unregister_exit_cleanup_path() {
    cleanup_path="$1"
    [ -n "$cleanup_path" ] || return 0
    [ -n "$EXIT_CLEANUP_PATHS" ] || return 0

    new_cleanup_paths=""
    old_ifs=$IFS
    IFS='
'
    for existing_cleanup_path in $EXIT_CLEANUP_PATHS; do
        [ -n "$existing_cleanup_path" ] || continue
        [ "$existing_cleanup_path" = "$cleanup_path" ] && continue
        new_cleanup_paths="${new_cleanup_paths}${new_cleanup_paths:+
}$existing_cleanup_path"
    done
    IFS=$old_ifs

    EXIT_CLEANUP_PATHS="$new_cleanup_paths"
}

cleanup_exit_paths() {
    [ -n "$EXIT_CLEANUP_PATHS" ] || return 0

    old_ifs=$IFS
    IFS='
'
    for cleanup_path in $EXIT_CLEANUP_PATHS; do
        [ -n "$cleanup_path" ] || continue
        rm -rf "$cleanup_path" 2>/dev/null || true
    done
    IFS=$old_ifs

    EXIT_CLEANUP_PATHS=""
}

on_exit() {
    cleanup_exit_paths
    release_lock
}

release_lock() {
    if [ ! -d "$LOCK_DIR" ]; then
        return 0
    fi

    current_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [ -n "$current_pid" ] && [ "$current_pid" != "$$" ]; then
        return 0
    fi

    rm -rf "$LOCK_DIR"
}

detect_package_manager() {
    if command -v opkg >/dev/null 2>&1; then
        echo "opkg"
        return 0
    fi

    if command -v apk >/dev/null 2>&1; then
        echo "apk"
        return 0
    fi

    echo "unknown"
}

print_pigz_install_hint() {
    package_manager=$(detect_package_manager)

    case "$package_manager" in
        opkg)
            echo "Install command: opkg update && opkg install pigz" >&2
            ;;
        apk)
            echo "Install command: apk add pigz" >&2
            ;;
        *)
            echo "Install pigz with your package manager." >&2
            ;;
    esac
}

print_downloader_install_hint() {
    package_manager=$(detect_package_manager)

    case "$package_manager" in
        opkg)
            echo "Install command: opkg update && opkg install wget-ssl" >&2
            ;;
        apk)
            echo "Install command: apk add wget" >&2
            ;;
        *)
            echo "Install wget, uclient-fetch, or curl with your package manager." >&2
            ;;
    esac
}

print_stty_install_hint() {
    package_manager=$(detect_package_manager)

    case "$package_manager" in
        opkg)
            echo "Install command: opkg update && opkg install coreutils-stty" >&2
            ;;
        apk)
            echo "Install command: apk add coreutils-stty" >&2
            ;;
        *)
            echo "Install stty with your package manager, or use the numeric fallback menus." >&2
            ;;
    esac
}

ensure_supported_environment() {
    package_manager=$(detect_package_manager)
    [ "$package_manager" != "unknown" ] || die "No supported package manager found. Expected opkg or apk."
}

ensure_downloader_available() {
    find_download_tool >/dev/null 2>&1 && return 0
    echo "Error: AUTO_UPDATE is enabled, but no downloader is available." >&2
    print_downloader_install_hint
    exit 1
}

check_install_prerequisites() {
    ensure_supported_environment
    require_commands tar sha256sum mount awk sed grep sort wc du date uname cp chmod ln dirname pwd basename dd find rm cut tr cat df mkdir mv rmdir

    if [ "$AUTO_UPDATE" = "1" ]; then
        ensure_downloader_available
    fi

    if [ "$COMPRESSOR_MODE" = "pigz" ] && ! command -v pigz >/dev/null 2>&1; then
        echo "Error: pigz is not installed, but pigz mode is the default install target." >&2
        print_pigz_install_hint
        echo "Alternative: install with COMPRESSOR_MODE=gzip or run backup/restore with --gzip." >&2
        exit 1
    fi
}

supports_tty_menu() {
    command -v stty >/dev/null 2>&1
}

require_pigz() {
    command -v pigz >/dev/null 2>&1 && return 0
    echo "Error: pigz mode requested, but pigz is not installed." >&2
    print_pigz_install_hint
    exit 1
}

list_installed_packages() {
    package_manager=$(detect_package_manager)

    case "$package_manager" in
        opkg)
            opkg list-installed | awk '{print $1}' | sort -u
            ;;
        apk)
            apk info 2>/dev/null | sort -u
            ;;
        *)
            die "No supported package manager found. Expected opkg or apk."
            ;;
    esac
}

archive_create() {
    archive_path="$1"

    case "$COMPRESSOR_MODE" in
        pigz)
            require_pigz
            tar -C /overlay/upper -cpf - . | pigz > "$archive_path"
            ;;
        gzip)
            tar -C /overlay/upper -czpf "$archive_path" .
            ;;
        *)
            die "Unsupported compressor mode: $COMPRESSOR_MODE"
            ;;
    esac
}

archive_verify() {
    archive_path="$1"

    case "$COMPRESSOR_MODE" in
        pigz)
            require_pigz
            pigz -dc "$archive_path" | tar -tf - >/dev/null
            ;;
        gzip)
            tar -tzf "$archive_path" >/dev/null
            ;;
        *)
            die "Unsupported compressor mode: $COMPRESSOR_MODE"
            ;;
    esac
}

archive_extract() {
    archive_path="$1"
    restore_target="$2"

    case "$COMPRESSOR_MODE" in
        pigz)
            require_pigz
            pigz -dc "$archive_path" | tar -C "$restore_target" -xpf -
            ;;
        gzip)
            tar -C "$restore_target" -xzpf "$archive_path"
            ;;
        *)
            die "Unsupported compressor mode: $COMPRESSOR_MODE"
            ;;
    esac
}

timestamp() {
    date '+%F_%H-%M-%S'
}

existing_probe_path() {
    probe_path="$1"

    while [ ! -e "$probe_path" ] && [ "$probe_path" != "/" ]; do
        probe_path=$(dirname "$probe_path")
    done

    echo "$probe_path"
}

mount_point_for_path() {
    probe_path=$(existing_probe_path "$1")
    df -P "$probe_path" 2>/dev/null | awk 'NR == 2 {print $NF}'
}

mount_source_for_path() {
    mount_point=$(mount_point_for_path "$1")
    [ -n "$mount_point" ] || return 1
    mount | awk -v mp="$mount_point" '$3 == mp { print $1; exit }'
}

filesystem_type_for_path() {
    mount_point=$(mount_point_for_path "$1")
    [ -n "$mount_point" ] || return 1
    mount | awk -v mp="$mount_point" '$3 == mp { print $5; exit }'
}

backup_root_shares_overlay_storage() {
    backup_root="$1"
    backup_source=$(mount_source_for_path "$backup_root" 2>/dev/null || true)
    overlay_source=$(mount_source_for_path "/overlay/upper" 2>/dev/null || true)

    [ -n "$backup_source" ] || return 1
    [ -n "$overlay_source" ] || return 1
    [ "$backup_source" = "$overlay_source" ]
}

storage_safety_label() {
    candidate_path="$1"

    if backup_root_shares_overlay_storage "$candidate_path"; then
        echo "same-as-overlay"
    else
        echo "external"
    fi
}

assert_backup_root_allowed() {
    backup_root="$1"
    fs_type=$(filesystem_type_for_path "$backup_root" 2>/dev/null || true)

    case "$fs_type" in
        tmpfs|ramfs)
            [ "$ALLOW_RAM_BACKUP" = "1" ] && return 0
            die "Backup root $backup_root is on $fs_type. Re-run with --allow-ram to allow RAM-backed storage."
            ;;
        overlay)
            die "Backup root $backup_root is on the live root overlay. Use /overlay/... or external storage outside the backed-up filesystem."
            ;;
    esac
}

estimate_required_kib() {
    source_kib=$(du -sk /overlay/upper 2>/dev/null | awk '{print $1}')
    [ -n "$source_kib" ] || source_kib=0
    echo $((source_kib + (source_kib / 20) + 1024))
}

estimate_backup_stage_required_kib() {
    source_kib=$(du -sk /overlay/upper 2>/dev/null | awk '{print $1}')
    [ -n "$source_kib" ] || source_kib=0
    echo $((source_kib + (source_kib / 20) + 2048))
}

available_kib_for_path() {
    target_path="$1"
    probe_path=$(existing_probe_path "$target_path")
    df -Pk "$probe_path" 2>/dev/null | awk 'NR == 2 {print $4}'
}

used_kib_for_path() {
    target_path="$1"
    [ -d "$target_path" ] || {
        echo 0
        return 0
    }

    used_kib=$(du -sk "$target_path" 2>/dev/null | awk '{print $1}')
    case "$used_kib" in
        ''|*[!0-9]*)
            echo 0
            ;;
        *)
            echo "$used_kib"
            ;;
    esac
}

check_free_space() {
    backup_root="$1"
    available_kib=$(available_kib_for_path "$backup_root")
    required_kib=$(estimate_required_kib)

    [ -n "$available_kib" ] || die "Unable to determine free space for $backup_root"

    if [ "$available_kib" -lt "$required_kib" ]; then
        die "Not enough free space for $backup_root. Required: $(humanize_kib "$required_kib"), available: $(humanize_kib "$available_kib")."
    fi
}

estimate_restore_required_kib() {
    backup_dir="$1"
    unpacked_kib=$(archive_unpacked_kib "$backup_dir/$ARCHIVE_NAME")

    case "$unpacked_kib" in
        ''|*[!0-9]*)
            die "Unable to estimate required restore space for $backup_dir"
            ;;
    esac

    echo $((unpacked_kib + (unpacked_kib / 20) + 1024))
}

check_restore_free_space() {
    backup_dir="$1"
    restore_target="$2"
    available_kib=$(available_kib_for_path "$restore_target")
    reclaimable_kib=$(used_kib_for_path "$restore_target")
    projected_kib=$((available_kib + reclaimable_kib))
    required_kib=$(estimate_restore_required_kib "$backup_dir")

    [ -n "$available_kib" ] || die "Unable to determine free space for $restore_target"

    if [ "$projected_kib" -lt "$required_kib" ]; then
        die "Not enough projected free space for $restore_target after clearing it. Required: $(humanize_kib "$required_kib"), available now: $(humanize_kib "$available_kib"), projected after clearing: $(humanize_kib "$projected_kib")."
    fi
}

find_download_tool() {
    if command -v uclient-fetch >/dev/null 2>&1; then
        echo "uclient-fetch"
        return 0
    fi

    if command -v wget >/dev/null 2>&1; then
        echo "wget"
        return 0
    fi

    if command -v curl >/dev/null 2>&1; then
        echo "curl"
        return 0
    fi

    return 1
}

download_to_file() {
    source_url="$1"
    target_path="$2"
    download_tool=$(find_download_tool 2>/dev/null || true)

    case "$download_tool" in
        uclient-fetch)
            uclient-fetch -O "$target_path" "$source_url"
            ;;
        wget)
            wget -O "$target_path" "$source_url"
            ;;
        curl)
            curl -fsSL -o "$target_path" "$source_url"
            ;;
        *)
            return 1
            ;;
    esac
}

self_update_due() {
    case "$AUTO_UPDATE_INTERVAL" in
        ''|*[!0-9]*)
            return 0
            ;;
    esac

    if [ "$AUTO_UPDATE_INTERVAL" -eq 0 ]; then
        return 0
    fi

    if [ ! -f "$SELF_UPDATE_STAMP" ]; then
        return 0
    fi

    last_check=$(cat "$SELF_UPDATE_STAMP" 2>/dev/null || true)
    case "$last_check" in
        ''|*[!0-9]*)
            return 0
            ;;
    esac

    now_epoch=$(date +%s 2>/dev/null || true)
    [ -n "$now_epoch" ] || return 0

    [ $((now_epoch - last_check)) -ge "$AUTO_UPDATE_INTERVAL" ]
}

mark_self_update_check() {
    date +%s > "$SELF_UPDATE_STAMP" 2>/dev/null || true
}

self_update_if_enabled() {
    [ "$AUTO_UPDATE" = "1" ] || return 0
    [ "${OBACKUPPER_SKIP_SELF_UPDATE:-0}" = "1" ] && return 0
    self_update_due || return 0

    current_path=$(script_path)
    update_target_path="$current_path"
    reexec_target_path="$current_path"
    current_checksum_path="$current_path"
    installed_mode="0"

    if is_installed_invocation; then
        current_installed_path=$(existing_install_path 2>/dev/null || true)
        [ -n "$current_installed_path" ] || return 0
        update_target_path="$INSTALL_PATH"
        reexec_target_path="$INSTALL_PATH"
        current_checksum_path="$current_installed_path"
        installed_mode="1"
    fi

    tmp_update_path="/tmp/${SCRIPT_BASENAME}.self-update.$$"

    if ! download_to_file "$AUTO_UPDATE_URL" "$tmp_update_path" >/dev/null 2>&1; then
        mark_self_update_check
        rm -f "$tmp_update_path"
        return 0
    fi

    mark_self_update_check

    if [ ! -s "$tmp_update_path" ]; then
        rm -f "$tmp_update_path"
        return 0
    fi

    if ! sh -n "$tmp_update_path" >/dev/null 2>&1; then
        warn "Downloaded update failed syntax check. Keeping current version."
        rm -f "$tmp_update_path"
        return 0
    fi

    current_checksum=$(file_checksum "$current_checksum_path" 2>/dev/null || true)
    updated_checksum=$(file_checksum "$tmp_update_path" 2>/dev/null || true)

    if [ -z "$updated_checksum" ]; then
        rm -f "$tmp_update_path"
        return 0
    fi

    if [ "$updated_checksum" = "$current_checksum" ]; then
        rm -f "$tmp_update_path"

        if [ "$installed_mode" = "1" ] && [ "$current_installed_path" = "$LEGACY_INSTALL_PATH" ] && [ ! -f "$INSTALL_PATH" ]; then
            cp "$current_installed_path" "$INSTALL_PATH" || return 0
            chmod 755 "$INSTALL_PATH"
            ln -sf "$INSTALL_PATH" "$SHORTCUT_PATH"
            rm -f "$LEGACY_INSTALL_PATH"
            log "Migrated installed script to $INSTALL_PATH"
            OBACKUPPER_SKIP_SELF_UPDATE=1 exec "$INSTALL_PATH" "$@"
        fi

        return 0
    fi

    cp "$tmp_update_path" "$update_target_path" || {
        warn "Failed to install downloaded update to $update_target_path"
        rm -f "$tmp_update_path"
        return 0
    }
    chmod 755 "$update_target_path"

    if [ "$installed_mode" = "1" ]; then
        ln -sf "$INSTALL_PATH" "$SHORTCUT_PATH"
    fi

    if [ "$installed_mode" = "1" ] && [ -f "$LEGACY_INSTALL_PATH" ] && [ "$LEGACY_INSTALL_PATH" != "$INSTALL_PATH" ]; then
        rm -f "$LEGACY_INSTALL_PATH"
    fi

    rm -f "$tmp_update_path"
    log "Updated from GitHub: $AUTO_UPDATE_URL"
    OBACKUPPER_SKIP_SELF_UPDATE=1 exec "$reexec_target_path" "$@"
}


shell_quote() {
    printf "'"
    printf "%s" "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

trim_trailing_slashes() {
    path_value="$1"

    while [ "$path_value" != "/" ] && [ "${path_value%/}" != "$path_value" ]; do
        path_value=${path_value%/}
    done

    echo "$path_value"
}

normalize_backup_root_path() {
    backup_root=$(trim_trailing_slashes "$1")
    [ -n "$backup_root" ] || return 1

    backup_root_base=$(basename "$backup_root")
    backup_root_parent=$(dirname "$backup_root")

    case "$backup_root_base" in
        "$BACKUP_ROOT_DIRNAME")
            echo "$backup_root"
            ;;
        overlay-backups|*_overlay_backups|*_overlay-backups)
            echo "$backup_root_parent/$BACKUP_ROOT_DIRNAME"
            ;;
        *)
            echo "$backup_root/$BACKUP_ROOT_DIRNAME"
            ;;
    esac
}

sanitize_path_component() {
    raw_value="$1"
    sanitized_value=$(printf "%s" "$raw_value" | tr ' /:\t' '_' | tr -cd 'A-Za-z0-9._-')
    sanitized_value=$(printf "%s" "$sanitized_value" | sed 's/__*/_/g; s/^_*//; s/_*$//')

    if [ -n "$sanitized_value" ]; then
        echo "$sanitized_value"
    else
        echo "unknown"
    fi
}

current_hostname() {
    uname -n
}

current_openwrt_description() {
    if [ -r /etc/openwrt_release ]; then
        # shellcheck disable=SC1091
        . /etc/openwrt_release
        echo "${DISTRIB_DESCRIPTION:-OpenWrt}"
        return 0
    fi

    echo "OpenWrt"
}

host_backup_root() {
    backup_root=$(normalize_backup_root_path "$1")
    host_name="${2:-$(current_hostname)}"
    echo "$backup_root/$(sanitize_path_component "$host_name")"
}

current_host_backup_root() {
    host_backup_root "${1:-$BACKUP_ROOT}" "$(current_hostname)"
}

current_backup_leaf_name() {
    os_description=$(sanitize_path_component "$(current_openwrt_description)")
    echo "${os_description}_$(timestamp)"
}

validate_backup_root_path() {
    backup_root=$(normalize_backup_root_path "$1")

    case "$backup_root" in
        '')
            die "Backup root must not be empty."
            ;;
        /*)
            ;;
        *)
            die "Backup root must be an absolute path: $backup_root"
            ;;
    esac

    case "$backup_root" in
        /)
            die "Backup root must not be /."
            ;;
        /overlay/upper|/overlay/upper/*)
            die "Backup root must not be inside /overlay/upper. Use a path outside the mutable overlay contents."
            ;;
        *'|'*)
            die "Backup root must not contain the | character."
            ;;
    esac
}

assert_backup_root_writable() {
    backup_root=$(normalize_backup_root_path "$1")
    validate_backup_root_path "$backup_root"
    assert_backup_root_allowed "$backup_root"

    if backup_root_shares_overlay_storage "$backup_root"; then
        warn "Backup root $backup_root is on the same device as /overlay. This protects against bad changes, but not storage failure."
    fi

    mkdir -p "$backup_root" 2>/dev/null || die "Unable to create backup root: $backup_root"

    write_test_path="$backup_root/.${SCRIPT_BASENAME}.write-test.$$"
    if ! (: > "$write_test_path") 2>/dev/null; then
        rm -f "$write_test_path" 2>/dev/null || true
        die "Backup root is not writable: $backup_root"
    fi

    rm -f "$write_test_path" 2>/dev/null || true
}

require_supported_package_manager() {
    package_manager=$(detect_package_manager)
    [ "$package_manager" != "unknown" ] || die "No supported package manager found. Expected opkg or apk."
}

require_compressor_prerequisites() {
    case "$COMPRESSOR_MODE" in
        pigz)
            if ! command -v pigz >/dev/null 2>&1; then
                printf "%sMissing required package:%s pigz\n" "$C_RED" "$C_RESET" >&2
                print_pigz_install_hint
                die "Install pigz manually, then rerun this command. You can also use --gzip for slower built-in gzip mode."
            fi
            ;;
        gzip)
            ;;
        *)
            die "Unsupported compressor mode: $COMPRESSOR_MODE"
            ;;
    esac
}

require_backup_prerequisites() {
    require_supported_package_manager
    require_compressor_prerequisites
}

require_restore_prerequisites() {
    require_compressor_prerequisites
}

is_live_overlay_target() {
    [ "$1" = "/overlay/upper" ]
}

assert_restore_target_supported() {
    restore_target="$1"
    fs_type=$(filesystem_type_for_path "$restore_target" 2>/dev/null || true)

    case "$fs_type" in
        vfat|msdos|exfat|ntfs|ntfs3|fuseblk)
            die "Restore target $restore_target is on $fs_type, which does not support the Unix metadata required by overlay backups. Use /overlay/upper, /tmp, or a Linux filesystem such as ext4/ubifs."
            ;;
        '')
            die "Unable to determine filesystem type for restore target: $restore_target"
            ;;
    esac
}

format_kib_or_unknown() {
    value_kib="$1"

    case "$value_kib" in
        ''|*[!0-9]*)
            echo "unknown"
            ;;
        *)
            humanize_kib "$value_kib"
            ;;
    esac
}

metadata_value() {
    metadata_path="$1"
    metadata_key="$2"

    [ -r "$metadata_path" ] || return 1
    sed -n "s/^${metadata_key}=//p" "$metadata_path" | sed -n '1p'
}

display_value_or_unknown() {
    value="$1"

    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "unknown"
    fi
}

backup_identity_value() {
    backup_dir="$1"
    metadata_key="$2"
    metadata_path="$backup_dir/$METADATA_NAME"

    metadata_value "$metadata_path" "$metadata_key" 2>/dev/null || true
}

backup_checksums_state() {
    backup_dir="$1"

    if [ -f "$backup_dir/$CHECKSUMS_NAME" ]; then
        echo "present"
    else
        echo "missing"
    fi
}

backup_stage_mode_for_root() {
    backup_root="$1"
    ram_stage_available_kib=$(available_kib_for_path "/tmp")
    ram_stage_required_kib=$(estimate_backup_stage_required_kib)

    if [ -n "$ram_stage_available_kib" ] && [ "$ram_stage_available_kib" -ge "$ram_stage_required_kib" ]; then
        echo "verify in /tmp before writing to disk"
    else
        echo "verify directly on disk (/tmp insufficient)"
    fi
}

prepare_backup_stage_dir() {
    backup_root="$1"
    final_tmp_dir="$2"
    ram_stage_dir="/tmp/${SCRIPT_BASENAME}.stage.$$"
    ram_stage_available_kib=$(available_kib_for_path "/tmp")
    ram_stage_required_kib=$(estimate_backup_stage_required_kib)

    if [ -n "$ram_stage_available_kib" ] && [ "$ram_stage_available_kib" -ge "$ram_stage_required_kib" ]; then
        mkdir -p "$ram_stage_dir" || die "Unable to create RAM stage directory: $ram_stage_dir"
        echo "$ram_stage_dir"
        return 0
    fi

    warn "Not enough free space in /tmp for pre-write staging. Falling back to direct on-disk verification."
    mkdir -p "$final_tmp_dir" || die "Unable to create staging directory: $final_tmp_dir"
    echo "$final_tmp_dir"
}

copy_backup_payload() {
    source_dir="$1"
    target_dir="$2"

    cp "$source_dir/$ARCHIVE_NAME" "$target_dir/$ARCHIVE_NAME"
    cp "$source_dir/$PACKAGE_LIST_NAME" "$target_dir/$PACKAGE_LIST_NAME"
    cp "$source_dir/$METADATA_NAME" "$target_dir/$METADATA_NAME"
    cp "$source_dir/$CHECKSUMS_NAME" "$target_dir/$CHECKSUMS_NAME"
}

move_backup_payload() {
    source_dir="$1"
    target_dir="$2"

    mv "$source_dir/$ARCHIVE_NAME" "$target_dir/$ARCHIVE_NAME"
    mv "$source_dir/$PACKAGE_LIST_NAME" "$target_dir/$PACKAGE_LIST_NAME"
    mv "$source_dir/$METADATA_NAME" "$target_dir/$METADATA_NAME"
    mv "$source_dir/$CHECKSUMS_NAME" "$target_dir/$CHECKSUMS_NAME"
}

archive_unpacked_kib() {
    archive_path="$1"

    case "$COMPRESSOR_MODE" in
        pigz)
            require_compressor_prerequisites
            pigz -dc "$archive_path" 2>/dev/null | tar -tvf - 2>/dev/null | awk '{sum += $3} END {printf "%d\n", int((sum + 1023) / 1024)}'
            ;;
        gzip)
            tar -tzvf "$archive_path" 2>/dev/null | awk '{sum += $3} END {printf "%d\n", int((sum + 1023) / 1024)}'
            ;;
        *)
            die "Unsupported compressor mode: $COMPRESSOR_MODE"
            ;;
    esac
}

print_plan_line() {
    label="$1"
    value="$2"

    printf "  %-21s %s\n" "$label:" "$value"
}

print_backup_identity_lines() {
    backup_dir="$1"
    backup_created=$(display_value_or_unknown "$(backup_identity_value "$backup_dir" "backup_created")")
    backup_host=$(display_value_or_unknown "$(backup_identity_value "$backup_dir" "hostname")")
    backup_model=$(display_value_or_unknown "$(backup_identity_value "$backup_dir" "model")")
    backup_board=$(display_value_or_unknown "$(backup_identity_value "$backup_dir" "board_name")")
    backup_pkgmgr=$(display_value_or_unknown "$(backup_identity_value "$backup_dir" "package_manager")")
    checksum_state=$(backup_checksums_state "$backup_dir")

    print_plan_line "Backup created" "$backup_created"
    print_plan_line "Source router" "$backup_host"
    print_plan_line "Source model" "$backup_model"
    print_plan_line "Source board" "$backup_board"
    print_plan_line "Package manager" "$backup_pkgmgr"
    print_plan_line "Checksums file" "$checksum_state"
}

print_backup_preflight() {
    backup_root="$1"
    backup_dir="$2"
    backup_stage_mode="$3"
    source_kib=$(du -sk /overlay/upper 2>/dev/null | awk '{print $1}')
    required_kib=$(estimate_required_kib)
    available_kib=$(available_kib_for_path "$backup_root")

    echo
    printf "%s%s%s\n" "$C_BOLD" "Backup plan" "$C_RESET"
    print_plan_line "Source overlay" "/overlay/upper (current writable overlay)"
    print_plan_line "Destination backup" "$backup_dir"
    print_plan_line "Archive contents" "$(format_kib_or_unknown "$source_kib") current overlay data"
    print_plan_line "Space required" "$(format_kib_or_unknown "$required_kib") estimated writable space"
    print_plan_line "Space available" "$(format_kib_or_unknown "$available_kib") at destination"
    print_plan_line "Using" "$COMPRESSOR_MODE"
    print_plan_line "Staging" "$backup_stage_mode"
    if backup_root_shares_overlay_storage "$backup_root"; then
        print_plan_line "Storage safety" "same device as overlay; not safe against storage failure"
    else
        print_plan_line "Storage safety" "separate storage from overlay"
    fi
    echo
}

print_restore_preflight() {
    backup_dir="$1"
    restore_target="$2"
    archive_path="$backup_dir/$ARCHIVE_NAME"
    unpacked_kib=$(archive_unpacked_kib "$archive_path")
    required_kib=$(estimate_restore_required_kib "$backup_dir")
    available_kib=$(available_kib_for_path "$restore_target")
    reclaimable_kib=$(used_kib_for_path "$restore_target")
    projected_kib=$((available_kib + reclaimable_kib))
    restore_target_label="$restore_target"
    [ "$restore_target" = "/overlay/upper" ] && restore_target_label="/overlay/upper (current writable overlay)"

    echo
    printf "%s%s%s\n" "$C_BOLD" "Restore plan" "$C_RESET"
    print_plan_line "Source backup" "$archive_path"
    print_backup_identity_lines "$backup_dir"
    print_plan_line "Restore target" "$restore_target_label"
    print_plan_line "Archive contents" "$(format_kib_or_unknown "$unpacked_kib") unpacked backup data"
    print_plan_line "Space required" "$(format_kib_or_unknown "$required_kib") estimated writable space"
    print_plan_line "Space available now" "$(format_kib_or_unknown "$available_kib") at destination"
    print_plan_line "Projected after clear" "$(format_kib_or_unknown "$projected_kib") estimated free space"
    print_plan_line "Using" "$COMPRESSOR_MODE"
    echo
}

confirm_restore() {
    backup_dir="$1"
    restore_target="$2"

    if ! is_interactive; then
        die "Restore requires interactive confirmation. Run it from a terminal."
    fi

    printf "%sWARNING:%s this will replace the contents of %s from %s.\n" "$C_RED" "$C_RESET" "$restore_target" "$ARCHIVE_NAME"
    echo "Current files in the restore target will be removed first."
    if is_live_overlay_target "$restore_target"; then
        echo "Router reboot will be required after restore."
    else
        echo "No reboot is needed when restoring into a non-live test directory."
    fi
    echo
    printf "Type RESTORE to continue: " > /dev/tty
    IFS= read -r restore_confirmation < /dev/tty || restore_confirmation=""

    if [ "$restore_confirmation" != "RESTORE" ]; then
        echo "Cancelled."
        return 1
    fi

    return 0
}

prompt_reboot_now() {
    echo "Reboot required."

    if is_interactive && ask_yes_no "Reboot now? [y/N]" "n"; then
        if command -v reboot >/dev/null 2>&1; then
            log "Rebooting"
            reboot
            return 0
        fi
        warn "reboot command not found. Reboot the router manually."
        return 0
    fi

    echo "Run this command when ready:"
    echo "reboot"
}

handle_post_install_handoff() {
    [ -n "${OBACKUPPER_POST_INSTALL_SUMMARY:-}" ] || [ -n "${OBACKUPPER_POST_INSTALL_SOURCE:-}" ] || [ -n "${OBACKUPPER_POST_INSTALL_ROOT:-}" ] || return 0

    if [ -n "${OBACKUPPER_POST_INSTALL_SUMMARY:-}" ]; then
        echo "$OBACKUPPER_POST_INSTALL_SUMMARY"
    fi

    if [ -n "${OBACKUPPER_POST_INSTALL_ROOT:-}" ]; then
        echo "Backup root: ${OBACKUPPER_POST_INSTALL_ROOT}"
    fi

    if [ -n "${OBACKUPPER_POST_INSTALL_SOURCE:-}" ]; then
        source_copy_path="${OBACKUPPER_POST_INSTALL_SOURCE}"
        case "$source_copy_path" in
            "$INSTALL_PATH"|"$LEGACY_INSTALL_PATH"|"$SHORTCUT_PATH")
                ;;
            *)
                if [ -e "$source_copy_path" ] || [ -L "$source_copy_path" ]; then
                    if rm -f "$source_copy_path" 2>/dev/null; then
                        echo "Removed source copy: $source_copy_path"
                    else
                        warn "Failed to remove source copy: $source_copy_path"
                    fi
                fi
                ;;
        esac
    fi

    if [ "${OBACKUPPER_POST_INSTALL_SHOW_USAGE:-0}" = "1" ] && [ $# -eq 0 ]; then
        echo
        usage
        exit 0
    fi
}

script_path() {
    case "$0" in
        /*) echo "$0" ;;
        *) echo "$(pwd)/$0" ;;
    esac
}

is_installed_invocation() {
    current_path=$(script_path)
    [ "$current_path" = "$INSTALL_PATH" ] || [ "$current_path" = "$LEGACY_INSTALL_PATH" ] || [ "$current_path" = "$SHORTCUT_PATH" ]
}

is_interactive() {
    [ -t 0 ] && [ -t 1 ]
}

ask_yes_no() {
    prompt="$1"
    default_answer="$2"

    while true; do
        if is_interactive; then
            printf "%s " "$prompt" > /dev/tty
            IFS= read -r answer < /dev/tty || answer=""
        else
            printf "%s " "$prompt"
            IFS= read -r answer || answer=""
        fi
        answer=$(echo "$answer" | tr 'A-Z' 'a-z')

        if [ -z "$answer" ]; then
            answer="$default_answer"
        fi

        case "$answer" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
        esac

        echo "Please answer yes or no."
    done
}

prompt_value() {
    prompt="$1"
    default_value="$2"

    if is_interactive; then
        printf "%s [%s]: " "$prompt" "$default_value" > /dev/tty
        IFS= read -r value < /dev/tty || value=""
    else
        printf "%s [%s]: " "$prompt" "$default_value"
        IFS= read -r value || value=""
    fi

    if [ -z "$value" ]; then
        echo "$default_value"
    else
        echo "$value"
    fi
}


prepare_key_refs() {
    key_dir="$1"

    mkdir -p "$key_dir"
    printf '\033' > "$key_dir/esc"
    printf '[' > "$key_dir/lb"
    printf 'A' > "$key_dir/up"
    printf 'B' > "$key_dir/down"
    printf '\r' > "$key_dir/cr"
    printf '\n' > "$key_dir/lf"
    printf '\010' > "$key_dir/bs"
    printf '\177' > "$key_dir/del"
}

read_tty_key_file() {
    output_file="$1"
    dd if=/dev/tty of="$output_file" bs=1 count=1 2>/dev/null >/dev/null
}

key_file_matches() {
    left_file="$1"
    right_file="$2"

    if command -v cmp >/dev/null 2>&1; then
        cmp -s "$left_file" "$right_file"
        return $?
    fi

    if command -v busybox >/dev/null 2>&1; then
        busybox cmp -s "$left_file" "$right_file"
        return $?
    fi

    die "No cmp utility found for interactive selector."
}


number_in_range() {
    value="$1"
    max_value="$2"

    case "$value" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    [ "$value" -ge 1 ] 2>/dev/null && [ "$value" -le "$max_value" ] 2>/dev/null
}

storage_candidates_file() {
    echo "/tmp/${SCRIPT_BASENAME}.storage-candidates.$$"
}

gather_storage_candidates() {
    candidates_file="$1"
    sortable_file="/tmp/${SCRIPT_BASENAME}.storage-sorted.$$"

    : > "$candidates_file"
    : > "$sortable_file"

    mount | awk '
        $1 ~ "^/dev/" && $0 ~ /\(rw/ {
            print $1 "|" $3 "|" $5
        }
    ' | while IFS='|' read -r device_name mount_point fs_type; do
        [ -n "$device_name" ] || continue
        [ -n "$mount_point" ] || continue

        df_line=$(df -hP "$mount_point" 2>/dev/null | awk 'NR == 2 {print}')
        [ -n "$df_line" ] || continue

        total_size=$(echo "$df_line" | awk '{print $2}')
        free_size=$(echo "$df_line" | awk '{print $4}')
        disk_name=$(basename "$device_name")
        suggested_path="${mount_point}/${BACKUP_ROOT_DIRNAME}"
        safety_label=$(storage_safety_label "$suggested_path")

        case "$safety_label" in
            external)
                safety_rank=0
                ;;
            *)
                safety_rank=1
                ;;
        esac

        echo "${safety_rank}|${device_name}|${mount_point}|${fs_type}|${free_size}|${total_size}|${disk_name}|${suggested_path}|${safety_label}" >> "$sortable_file"
    done

    if [ -s "$sortable_file" ]; then
        sort -t'|' -k1,1n -k3,3 "$sortable_file" | cut -d'|' -f2- > "$candidates_file"
    fi

    rm -f "$sortable_file"
}

print_storage_option() {
    option_number="$1"
    is_selected="$2"
    option_line="$3"

    device_name=$(echo "$option_line" | cut -d'|' -f1)
    mount_point=$(echo "$option_line" | cut -d'|' -f2)
    fs_type=$(echo "$option_line" | cut -d'|' -f3)
    free_size=$(echo "$option_line" | cut -d'|' -f4)
    total_size=$(echo "$option_line" | cut -d'|' -f5)
    suggested_path=$(echo "$option_line" | cut -d'|' -f7)
    safety_label=$(echo "$option_line" | cut -d'|' -f8)

    if [ "$is_selected" = "1" ]; then
        printf "%s  %-3s %-18s %-14s %-8s %-10s %-10s %-15s %s%s\n" \
            "$C_GREEN" "$option_number" "$device_name" "$mount_point" "$fs_type" "$free_size" "$total_size" "$safety_label" "$suggested_path" "$C_RESET"
    else
        printf "  %-3s %-18s %-14s %-8s %-10s %-10s %-15s %s\n" \
            "$option_number" "$device_name" "$mount_point" "$fs_type" "$free_size" "$total_size" "$safety_label" "$suggested_path"
    fi
}

render_storage_menu() {
    candidates_file="$1"
    selected_index="$2"
    total_count="$3"
    number_buffer="${4:-}"

    printf '\033[H\033[J'
    echo "Select backup storage."
    echo "Use Up/Down + Enter, or type number and press Enter. q cancels."
    echo
    printf "  %-3s %-18s %-14s %-8s %-10s %-10s %-15s %s\n" "No" "Device" "Mount" "FS" "Free" "Total" "Safety" "Suggested path"
    printf "  %-3s %-18s %-14s %-8s %-10s %-10s %-15s %s\n" "--" "------" "-----" "--" "----" "-----" "------" "--------------"

    current_index=1
    while IFS= read -r option_line; do
        is_selected="0"
        [ "$current_index" -eq "$selected_index" ] && is_selected="1"
        print_storage_option "$current_index" "$is_selected" "$option_line"
        current_index=$((current_index + 1))
    done < "$candidates_file"

    if [ -n "$number_buffer" ]; then
        echo
        echo "Typed number: $number_buffer"
    fi
}

select_storage_candidate_simple() {
    candidates_file="$1"
    total_count="$2"

    echo "Select backup storage."
    echo
    printf "  %-3s %-18s %-14s %-8s %-10s %-10s %-15s %s\n" "No" "Device" "Mount" "FS" "Free" "Total" "Safety" "Suggested path"
    printf "  %-3s %-18s %-14s %-8s %-10s %-10s %-15s %s\n" "--" "------" "-----" "--" "----" "-----" "------" "--------------"

    current_index=1
    while IFS= read -r option_line; do
        print_storage_option "$current_index" "0" "$option_line"
        current_index=$((current_index + 1))
    done < "$candidates_file"

    while true; do
        selection=$(prompt_value "Enter storage number or q to cancel" "1")
        case "$selection" in
            q|Q)
                STORAGE_SELECTION_CANCELLED="1"
                echo "Storage selection cancelled."
                return 1
                ;;
        esac

        if number_in_range "$selection" "$total_count"; then
            SELECTED_STORAGE_PATH=$(sed -n "${selection}p" "$candidates_file" | cut -d'|' -f7)
            return 0
        fi

        echo "Enter a number from 1 to $total_count, or q."
    done
}

select_storage_candidate() {
    candidates_file="$1"
    total_count=$(wc -l < "$candidates_file" | tr -d ' ')
    SELECTED_STORAGE_PATH=""
    STORAGE_SELECTION_CANCELLED="0"

    [ "$total_count" -gt 0 ] || return 1

    if [ "$total_count" -eq 1 ]; then
        selected_line=$(sed -n '1p' "$candidates_file")
        echo
        echo "Detected backup storage:"
        printf "  %-3s %-18s %-14s %-8s %-10s %-10s %-15s %s\n" "No" "Device" "Mount" "FS" "Free" "Total" "Safety" "Suggested path"
        printf "  %-3s %-18s %-14s %-8s %-10s %-10s %-15s %s\n" "--" "------" "-----" "--" "----" "-----" "------" "--------------"
        print_storage_option "1" "1" "$selected_line"
        SELECTED_STORAGE_PATH=$(echo "$selected_line" | cut -d'|' -f7)
        return 0
    fi

    if ! supports_tty_menu; then
        warn "stty is not available. Falling back to simple numbered selection."
        print_stty_install_hint
        echo
        select_storage_candidate_simple "$candidates_file" "$total_count"
        return $?
    fi

    tty_state=$(stty -g </dev/tty)
    trap 'stty "$tty_state" </dev/tty 2>/dev/null || true' EXIT INT TERM
    stty -echo -icanon min 1 time 0 </dev/tty
    key_dir="/tmp/${SCRIPT_BASENAME}.keys.$$"
    prepare_key_refs "$key_dir"

    selected_index=1
    number_buffer=""
    while true; do
        render_storage_menu "$candidates_file" "$selected_index" "$total_count" "$number_buffer"
        read_tty_key_file "$key_dir/key1"

        [ -s "$key_dir/key1" ] || continue

        if key_file_matches "$key_dir/key1" "$key_dir/esc"; then
            read_tty_key_file "$key_dir/key2"
            read_tty_key_file "$key_dir/key3"
            number_buffer=""
            if key_file_matches "$key_dir/key2" "$key_dir/lb" && key_file_matches "$key_dir/key3" "$key_dir/up"; then
                if [ "$selected_index" -gt 1 ]; then
                    selected_index=$((selected_index - 1))
                fi
            elif key_file_matches "$key_dir/key2" "$key_dir/lb" && key_file_matches "$key_dir/key3" "$key_dir/down"; then
                if [ "$selected_index" -lt "$total_count" ]; then
                    selected_index=$((selected_index + 1))
                fi
            fi
            continue
        fi

        if key_file_matches "$key_dir/key1" "$key_dir/cr" || key_file_matches "$key_dir/key1" "$key_dir/lf"; then
            if [ -n "$number_buffer" ]; then
                if number_in_range "$number_buffer" "$total_count"; then
                    selected_index="$number_buffer"
                    break
                fi
                number_buffer=""
                continue
            fi
            break
        fi

        if key_file_matches "$key_dir/key1" "$key_dir/bs" || key_file_matches "$key_dir/key1" "$key_dir/del"; then
            number_buffer=${number_buffer%?}
            continue
        fi

        key_value=$(cat "$key_dir/key1" 2>/dev/null || true)
        case "$key_value" in
            q|Q)
                STORAGE_SELECTION_CANCELLED="1"
                stty "$tty_state" </dev/tty 2>/dev/null || stty sane </dev/tty 2>/dev/null || true
                trap - EXIT INT TERM
                rm -rf "$key_dir"
                printf '\033[H\033[J'
                echo "Storage selection cancelled."
                return 1
                ;;
            [0-9])
                number_buffer="${number_buffer}${key_value}"
                if number_in_range "$number_buffer" "$total_count"; then
                    selected_index="$number_buffer"
                elif number_in_range "$key_value" "$total_count"; then
                    number_buffer="$key_value"
                    selected_index="$key_value"
                fi
                ;;
        esac
    done

    stty "$tty_state" </dev/tty 2>/dev/null || stty sane </dev/tty 2>/dev/null || true
    trap - EXIT INT TERM
    rm -rf "$key_dir"
    printf '\033[H\033[J'
    echo

    SELECTED_STORAGE_PATH=$(sed -n "${selected_index}p" "$candidates_file" | cut -d'|' -f7)
}

choose_backup_root() {
    candidates_file=$(storage_candidates_file)
    selected_backup_root=""
    CHOSEN_BACKUP_ROOT=""

    gather_storage_candidates "$candidates_file"

    if [ -s "$candidates_file" ]; then
        select_storage_candidate "$candidates_file" || true
        selected_backup_root="$SELECTED_STORAGE_PATH"
    fi

    rm -f "$candidates_file"

    if [ "${STORAGE_SELECTION_CANCELLED:-0}" = "1" ]; then
        echo "Backup root selection cancelled."
        return 1
    fi

    if [ -z "$selected_backup_root" ]; then
        selected_backup_root="$BACKUP_ROOT"
        warn "No writable /dev/* storage candidates detected. Falling back to $selected_backup_root"
    fi

    selected_backup_root=$(normalize_backup_root_path "$selected_backup_root")

    echo
    echo "Suggested backup root:"
    echo "  $selected_backup_root"

    if ask_yes_no "Use this backup root? [Y/n]" "y"; then
        CHOSEN_BACKUP_ROOT="$selected_backup_root"
        return 0
    fi

    CHOSEN_BACKUP_ROOT=$(normalize_backup_root_path "$(prompt_value "Enter backup root" "$selected_backup_root")")
}

auto_select_backup_root() {
    candidates_file=$(storage_candidates_file)
    AUTO_SELECTED_BACKUP_ROOT=""

    gather_storage_candidates "$candidates_file"

    if [ -s "$candidates_file" ]; then
        AUTO_SELECTED_BACKUP_ROOT=$(sed -n '1p' "$candidates_file" | cut -d'|' -f7)
    fi

    rm -f "$candidates_file"

    if [ -z "$AUTO_SELECTED_BACKUP_ROOT" ]; then
        AUTO_SELECTED_BACKUP_ROOT="$BACKUP_ROOT"
    fi

    AUTO_SELECTED_BACKUP_ROOT=$(normalize_backup_root_path "$AUTO_SELECTED_BACKUP_ROOT")
}

write_config() {
    configured_backup_root=$(normalize_backup_root_path "$1")
    validate_backup_root_path "$configured_backup_root"
    quoted_backup_root=$(shell_quote "$configured_backup_root")
    quoted_auto_update_url=$(shell_quote "$AUTO_UPDATE_URL")

    mkdir -p "$(dirname "$CONFIG_PATH")"
    cat > "$CONFIG_PATH" <<EOF
BACKUP_ROOT=$quoted_backup_root
RETENTION_COUNT='$RETENTION_COUNT'
AUTO_UPDATE='$AUTO_UPDATE'
AUTO_UPDATE_URL=$quoted_auto_update_url
AUTO_UPDATE_INTERVAL='$AUTO_UPDATE_INTERVAL'
EOF
}

update_installed_script() {
    current_path="$1"

    cp "$current_path" "$INSTALL_PATH"
    chmod 755 "$INSTALL_PATH"
    ln -sf "$INSTALL_PATH" "$SHORTCUT_PATH"
    if [ -f "$LEGACY_INSTALL_PATH" ] && [ "$LEGACY_INSTALL_PATH" != "$INSTALL_PATH" ]; then
        rm -f "$LEGACY_INSTALL_PATH"
    fi
    log "Updated installed script at $INSTALL_PATH"
}

handle_existing_installation() {
    current_path="$1"
    shift
    INSTALL_RUN_EXISTING="1"
    installed_path=$(existing_install_path 2>/dev/null || true)
    INSTALL_SUMMARY_MESSAGE=""

    if ! installed_script_differs "$current_path"; then
        if [ "$installed_path" = "$LEGACY_INSTALL_PATH" ]; then
            update_installed_script "$current_path"
            INSTALL_SUMMARY_MESSAGE="Migrated installed script to $INSTALL_PATH"
        else
            INSTALL_SUMMARY_MESSAGE="Installed copy already current: $installed_path"
        fi
    else
        update_installed_script "$current_path"
        INSTALL_SUMMARY_MESSAGE="Updated installed script: $INSTALL_PATH"
    fi

    INSTALL_RUN_EXISTING="1"
}

run_installer() {
    current_path=$(script_path)
    show_usage_after_install="0"

    [ $# -gt 0 ] || show_usage_after_install="1"

    if installed_script_exists; then
        handle_existing_installation "$current_path" "$@"
        installed_path=$(existing_install_path 2>/dev/null || echo "$INSTALL_PATH")
        OBACKUPPER_POST_INSTALL_SOURCE="$current_path" \
        OBACKUPPER_POST_INSTALL_SHOW_USAGE="$show_usage_after_install" \
        OBACKUPPER_POST_INSTALL_SUMMARY="$INSTALL_SUMMARY_MESSAGE" \
        exec "$installed_path" "$@"
    fi

    check_install_prerequisites
    auto_select_backup_root

    cp "$current_path" "$INSTALL_PATH"
    chmod 755 "$INSTALL_PATH"
    ln -sf "$INSTALL_PATH" "$SHORTCUT_PATH"
    if [ -f "$LEGACY_INSTALL_PATH" ] && [ "$LEGACY_INSTALL_PATH" != "$INSTALL_PATH" ]; then
        rm -f "$LEGACY_INSTALL_PATH"
    fi

    BACKUP_ROOT="$AUTO_SELECTED_BACKUP_ROOT"
    assert_backup_root_writable "$BACKUP_ROOT"

    write_config "$BACKUP_ROOT"
    OBACKUPPER_POST_INSTALL_SOURCE="$current_path" \
    OBACKUPPER_POST_INSTALL_SHOW_USAGE="$show_usage_after_install" \
    OBACKUPPER_POST_INSTALL_SUMMARY="Installed to $INSTALL_PATH" \
    OBACKUPPER_POST_INSTALL_ROOT="$BACKUP_ROOT" \
    exec "$INSTALL_PATH" "$@"
}

append_section() {
    title="$1"
    shift

    echo
    echo "[$title]"
    if "$@" 2>&1; then
        :
    else
        warn "Failed to collect section: $title"
    fi
}

append_opkg_metadata() {
    if [ -r /etc/opkg.conf ] || [ -d /etc/opkg ]; then
        append_section "opkg_conf" sh -c 'ls -ld /etc/opkg.conf /etc/opkg 2>/dev/null; if [ -r /etc/opkg.conf ]; then echo; sed -n "1,200p" /etc/opkg.conf; fi'
    fi

    if [ -r /etc/opkg/customfeeds.conf ]; then
        append_section "opkg_customfeeds" sed -n '1,200p' /etc/opkg/customfeeds.conf
    fi

    if [ -r /etc/opkg/distfeeds.conf ]; then
        append_section "opkg_distfeeds" sed -n '1,200p' /etc/opkg/distfeeds.conf
    fi

    if [ -d /etc/opkg/keys ]; then
        append_section "opkg_keys" ls -l /etc/opkg/keys
    fi
}

append_apk_metadata() {
    if [ -r /etc/apk/repositories ]; then
        append_section "apk_repositories" sed -n '1,200p' /etc/apk/repositories
    fi

    if [ -r /etc/apk/world ]; then
        append_section "apk_world" sed -n '1,200p' /etc/apk/world
    fi

    if [ -d /etc/apk/keys ]; then
        append_section "apk_keys" ls -l /etc/apk/keys
    fi

    if command -v apk >/dev/null 2>&1; then
        append_section "apk_policy" sh -c 'apk policy 2>/dev/null'
    fi
}

append_package_manager_metadata() {
    package_manager="$1"

    case "$package_manager" in
        opkg)
            append_opkg_metadata
            ;;
        apk)
            append_apk_metadata
            ;;
    esac
}

write_metadata() {
    backup_dir="$1"
    recorded_backup_dir="${2:-$backup_dir}"
    metadata_path="$backup_dir/$METADATA_NAME"
    overlay_mount_line=$(mount | awk '$3 == "/overlay" { print; exit }')
    overlay_source=$(mount | awk '$3 == "/overlay" { print $1; exit }')
    overlay_type=$(mount | awk '$3 == "/overlay" { print $5; exit }')
    package_manager=$(detect_package_manager)
    package_count=$(list_installed_packages | wc -l | tr -d ' ')

    {
        echo "backup_created=$(date '+%F %T %z')"
        echo "backup_dir=$recorded_backup_dir"
        echo "hostname=$(uname -n)"
        echo "kernel=$(uname -a)"
        echo "overlay_mount=${overlay_mount_line:-unavailable}"
        echo "overlay_source=${overlay_source:-unavailable}"
        echo "overlay_fstype=${overlay_type:-unavailable}"
        echo "package_count=$package_count"
        echo "package_manager=${package_manager:-unknown}"
        echo "compressor_mode=$COMPRESSOR_MODE"
        echo "config_path=$CONFIG_PATH"
        echo "configured_backup_root=$BACKUP_ROOT"

        if [ -r /tmp/sysinfo/model ]; then
            echo "model=$(cat /tmp/sysinfo/model)"
        fi

        if [ -r /tmp/sysinfo/board_name ]; then
            echo "board_name=$(cat /tmp/sysinfo/board_name)"
        fi

        if [ -r /etc/openwrt_release ]; then
            . /etc/openwrt_release
            echo "openwrt_release=${DISTRIB_RELEASE:-unknown}"
            echo "openwrt_revision=${DISTRIB_REVISION:-unknown}"
            echo "openwrt_target=${DISTRIB_TARGET:-unknown}"
            echo "openwrt_arch=${DISTRIB_ARCH:-unknown}"
            echo "openwrt_description=${DISTRIB_DESCRIPTION:-unknown}"
        fi

        if [ -r /etc/openwrt_release ]; then
            append_section "openwrt_release" cat /etc/openwrt_release
        fi

        if [ -r /etc/os-release ]; then
            append_section "os_release" cat /etc/os-release
        fi

        append_section "mount" mount
        append_section "df_h" df -h

        if command -v block >/dev/null 2>&1; then
            append_section "block_info" block info
        fi

        append_section "rc_d" ls -1 /etc/rc.d
        append_package_manager_metadata "$package_manager"

        append_section "package_list" sort "$backup_dir/$PACKAGE_LIST_NAME"
    } > "$metadata_path"
}

write_package_list() {
    backup_dir="$1"
    list_installed_packages > "$backup_dir/$PACKAGE_LIST_NAME"
}

write_checksums() {
    backup_dir="$1"
    (
        cd "$backup_dir"
        sha256sum "$ARCHIVE_NAME" "$PACKAGE_LIST_NAME" "$METADATA_NAME" > "$CHECKSUMS_NAME"
    )
}

verify_checksums() {
    backup_dir="$1"
    checksum_path="$backup_dir/$CHECKSUMS_NAME"

    [ -f "$checksum_path" ] || die "Checksums file not found: $checksum_path"

    log "Verifying checksums"
    (
        cd "$backup_dir"
        sha256sum -c "$CHECKSUMS_NAME"
    )
}

rotate_old_backups() {
    host_backup_root="$1"
    validate_retention_count

    if [ "$RETENTION_COUNT" -eq 0 ]; then
        return 0
    fi

    list_file="/tmp/${SCRIPT_BASENAME}.rotate.$$"
    count=0

    gather_backup_candidates "$host_backup_root" "$list_file"

    while IFS='|' read -r backup_dir _rest; do
        [ -n "$backup_dir" ] || continue
        count=$((count + 1))
        if [ "$count" -le "$RETENTION_COUNT" ]; then
            continue
        fi
        rm -rf "$backup_dir"
    done < "$list_file"

    rm -f "$list_file"
}

normalize_restore_target() {
    restore_target="${1:-$DEFAULT_RESTORE_TARGET}"

    case "$restore_target" in
        /)
            echo "/overlay/upper"
            ;;
        *)
            echo "$restore_target"
            ;;
    esac
}


backup_candidates_file() {
    echo "/tmp/${SCRIPT_BASENAME}.backup-candidates.$$"
}

host_candidates_file() {
    echo "/tmp/${SCRIPT_BASENAME}.host-candidates.$$"
}

backup_name_date_time() {
    backup_dir="$1"
    backup_leaf=$(basename "$backup_dir")
    backup_name=$(backup_identity_value "$backup_dir" "openwrt_description")
    metadata_path="$backup_dir/$METADATA_NAME"

    if [ -r "$metadata_path" ]; then
        created_line=$(grep '^backup_created=' "$metadata_path" 2>/dev/null | sed -n '1p' || true)
        if [ -n "$created_line" ]; then
            created_value=${created_line#backup_created=}
            set -- $created_value
            created_date="${1:-unknown}"
            created_time="${2:-unknown}"
            [ -n "$backup_name" ] || backup_name="$backup_leaf"
            echo "$backup_name|$created_date|$created_time"
            return 0
        fi
    fi

    case "$backup_leaf" in
        *_????-??-??_??-??-??)
            created_date=$(printf "%s" "$backup_leaf" | sed -n 's/^.*_\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)_[0-9-][0-9-][0-9-][0-9-][0-9-][0-9-][0-9-][0-9-]$/\1/p')
            created_time=$(printf "%s" "$backup_leaf" | sed -n 's/^.*_[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_\([0-9-][0-9-][0-9-][0-9-][0-9-][0-9-][0-9-][0-9-]\)$/\1/p')
            created_time=$(echo "$created_time" | tr '-' ':')
            ;;
        *)
            created_date="unknown"
            created_time="unknown"
            ;;
    esac

    [ -n "$backup_name" ] || backup_name=$(printf "%s" "$backup_leaf" | sed 's/_[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9-][0-9-][0-9-][0-9-][0-9-][0-9-][0-9-][0-9-]$//')
    [ -n "$backup_name" ] || backup_name="$backup_leaf"

    echo "$backup_name|$created_date|$created_time"
}

backup_sort_key() {
    backup_dir="$1"
    metadata_path="$backup_dir/$METADATA_NAME"
    backup_leaf=$(basename "$backup_dir")

    if [ -r "$metadata_path" ]; then
        created_line=$(grep '^backup_created=' "$metadata_path" 2>/dev/null | sed -n '1p' || true)
        if [ -n "$created_line" ]; then
            created_value=${created_line#backup_created=}
            created_key=$(printf "%s" "$created_value" | tr -cd '0-9' | cut -c1-14)
            if [ -n "$created_key" ]; then
                echo "$created_key"
                return 0
            fi
        fi
    fi

    parsed_key=$(printf "%s" "$backup_leaf" | sed -n 's/^.*_\([0-9][0-9][0-9][0-9]\)-\([0-9][0-9]\)-\([0-9][0-9]\)_\([0-9][0-9]\)-\([0-9][0-9]\)-\([0-9][0-9]\)$/\1\2\3\4\5\6/p')
    if [ -n "$parsed_key" ]; then
        echo "$parsed_key"
    else
        echo "00000000000000"
    fi
}

gather_backup_candidates() {
    host_root="$1"
    candidates_file="$2"
    sortable_file="/tmp/${SCRIPT_BASENAME}.backup-sorted.$$"

    : > "$candidates_file"
    : > "$sortable_file"

    [ -d "$host_root" ] || {
        rm -f "$sortable_file"
        return 0
    }

    find "$host_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r backup_dir; do
        [ -f "$backup_dir/$ARCHIVE_NAME" ] || continue

        backup_sort=$(backup_sort_key "$backup_dir")
        name_date_time=$(backup_name_date_time "$backup_dir")
        backup_name=$(echo "$name_date_time" | cut -d'|' -f1)
        backup_date=$(echo "$name_date_time" | cut -d'|' -f2)
        backup_time=$(echo "$name_date_time" | cut -d'|' -f3)
        backup_size=$(du -h "$backup_dir/$ARCHIVE_NAME" 2>/dev/null | awk '{print $1}')
        checksum_state=$(backup_checksums_state "$backup_dir")
        [ -n "$backup_size" ] || backup_size="unknown"

        echo "${backup_sort}|${backup_dir}|${backup_name}|${backup_date}|${backup_time}|${backup_size}|${checksum_state}" >> "$sortable_file"
    done

    if [ -s "$sortable_file" ]; then
        sort -t'|' -k1,1r -k2,2r "$sortable_file" | cut -d'|' -f2- > "$candidates_file"
    fi

    rm -f "$sortable_file"
}

gather_host_candidates() {
    backup_root="$1"
    candidates_file="$2"
    sortable_file="/tmp/${SCRIPT_BASENAME}.host-sorted.$$"
    current_host_key=$(sanitize_path_component "$(current_hostname)")

    : > "$candidates_file"
    : > "$sortable_file"

    [ -d "$backup_root" ] || {
        rm -f "$sortable_file"
        return 0
    }

    find "$backup_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r host_dir; do
        host_key=$(basename "$host_dir")
        host_backups_file="/tmp/${SCRIPT_BASENAME}.host-backups.$$.$host_key"

        gather_backup_candidates "$host_dir" "$host_backups_file"
        if [ ! -s "$host_backups_file" ]; then
            rm -f "$host_backups_file"
            continue
        fi

        backup_count=$(wc -l < "$host_backups_file" | tr -d ' ')
        latest_line=$(sed -n '1p' "$host_backups_file")
        latest_date=$(echo "$latest_line" | cut -d'|' -f3)
        latest_time=$(echo "$latest_line" | cut -d'|' -f4)
        preferred_flag="0"
        [ "$host_key" = "$current_host_key" ] && preferred_flag="1"

        echo "${preferred_flag}|${host_dir}|${host_key}|${backup_count}|${latest_date}|${latest_time}|${preferred_flag}" >> "$sortable_file"
        rm -f "$host_backups_file"
    done

    if [ -s "$sortable_file" ]; then
        sort -t'|' -k1,1nr -k3,3 "$sortable_file" | cut -d'|' -f2- > "$candidates_file"
    fi

    rm -f "$sortable_file"
}

print_host_option() {
    option_number="$1"
    is_selected="$2"
    option_line="$3"

    host_name=$(echo "$option_line" | cut -d'|' -f2)
    backup_count=$(echo "$option_line" | cut -d'|' -f3)
    latest_date=$(echo "$option_line" | cut -d'|' -f4)
    latest_time=$(echo "$option_line" | cut -d'|' -f5)
    preferred_flag=$(echo "$option_line" | cut -d'|' -f6)
    host_note=""

    [ "$preferred_flag" = "1" ] && host_note="current"

    if [ "$is_selected" = "1" ] || [ "$preferred_flag" = "1" ]; then
        printf "%s  %-3s %-24s %-8s %-12s %-10s %-8s%s\n" \
            "$C_GREEN" "$option_number" "$host_name" "$backup_count" "$latest_date" "$latest_time" "$host_note" "$C_RESET"
    else
        printf "  %-3s %-24s %-8s %-12s %-10s %-8s\n" \
            "$option_number" "$host_name" "$backup_count" "$latest_date" "$latest_time" "$host_note"
    fi
}

print_host_table() {
    candidates_file="$1"

    printf "  %-3s %-24s %-8s %-12s %-10s %-8s\n" "No" "Hostname" "Backups" "Last date" "Last time" "Priority"
    printf "  %-3s %-24s %-8s %-12s %-10s %-8s\n" "--" "--------" "-------" "---------" "---------" "--------"

    current_index=1
    while IFS= read -r option_line; do
        print_host_option "$current_index" "0" "$option_line"
        current_index=$((current_index + 1))
    done < "$candidates_file"
}

select_host_candidate_simple() {
    candidates_file="$1"
    total_count="$2"

    echo "Hostname groups in: $BACKUP_ROOT"
    echo
    print_host_table "$candidates_file"

    while true; do
        selection=$(prompt_value "Enter hostname number or q to cancel" "1")
        case "$selection" in
            q|Q)
                echo "Cancelled."
                return 1
                ;;
        esac

        if number_in_range "$selection" "$total_count"; then
            SELECTED_HOST_DIR=$(sed -n "${selection}p" "$candidates_file" | cut -d'|' -f1)
            return 0
        fi

        echo "Enter a number from 1 to $total_count, or q."
    done
}

select_host_candidate() {
    candidates_file="$1"
    total_count=$(wc -l < "$candidates_file" | tr -d ' ')
    SELECTED_HOST_DIR=""

    [ "$total_count" -gt 0 ] || return 1

    if ! is_interactive; then
        echo "Hostname groups in: $BACKUP_ROOT"
        echo
        print_host_table "$candidates_file"
        return 1
    fi

    if ! supports_tty_menu; then
        warn "stty is not available. Falling back to simple numbered selection."
        print_stty_install_hint
        echo
        select_host_candidate_simple "$candidates_file" "$total_count"
        return $?
    fi

    tty_state=$(stty -g </dev/tty)
    trap 'stty "$tty_state" </dev/tty 2>/dev/null || true' EXIT INT TERM
    stty -echo -icanon min 1 time 0 </dev/tty
    key_dir="/tmp/${SCRIPT_BASENAME}.keys.$$"
    prepare_key_refs "$key_dir"

    selected_index=1
    number_buffer=""
    while true; do
        printf '\033[H\033[J'
        echo "Hostname groups in: $BACKUP_ROOT"
        echo "Use Up/Down + Enter, or type number and press Enter. q cancels."
        echo
        printf "  %-3s %-24s %-8s %-12s %-10s %-8s\n" "No" "Hostname" "Backups" "Last date" "Last time" "Priority"
        printf "  %-3s %-24s %-8s %-12s %-10s %-8s\n" "--" "--------" "-------" "---------" "---------" "--------"

        current_index=1
        while IFS= read -r option_line; do
            is_selected="0"
            [ "$current_index" -eq "$selected_index" ] && is_selected="1"
            print_host_option "$current_index" "$is_selected" "$option_line"
            current_index=$((current_index + 1))
        done < "$candidates_file"

        if [ -n "$number_buffer" ]; then
            echo
            echo "Typed number: $number_buffer"
        fi

        read_tty_key_file "$key_dir/key1"

        [ -s "$key_dir/key1" ] || continue

        if key_file_matches "$key_dir/key1" "$key_dir/esc"; then
            read_tty_key_file "$key_dir/key2"
            read_tty_key_file "$key_dir/key3"
            number_buffer=""
            if key_file_matches "$key_dir/key2" "$key_dir/lb" && key_file_matches "$key_dir/key3" "$key_dir/up"; then
                if [ "$selected_index" -gt 1 ]; then
                    selected_index=$((selected_index - 1))
                fi
            elif key_file_matches "$key_dir/key2" "$key_dir/lb" && key_file_matches "$key_dir/key3" "$key_dir/down"; then
                if [ "$selected_index" -lt "$total_count" ]; then
                    selected_index=$((selected_index + 1))
                fi
            fi
            continue
        fi

        if key_file_matches "$key_dir/key1" "$key_dir/cr" || key_file_matches "$key_dir/key1" "$key_dir/lf"; then
            if [ -n "$number_buffer" ]; then
                if number_in_range "$number_buffer" "$total_count"; then
                    selected_index="$number_buffer"
                    break
                fi
                number_buffer=""
                continue
            fi
            break
        fi

        if key_file_matches "$key_dir/key1" "$key_dir/bs" || key_file_matches "$key_dir/key1" "$key_dir/del"; then
            number_buffer=${number_buffer%?}
            continue
        fi

        key_value=$(cat "$key_dir/key1" 2>/dev/null || true)
        case "$key_value" in
            q|Q)
                stty "$tty_state" </dev/tty 2>/dev/null || stty sane </dev/tty 2>/dev/null || true
                trap - EXIT INT TERM
                rm -rf "$key_dir"
                printf '\033[H\033[J'
                echo "Cancelled."
                return 1
                ;;
            [0-9])
                number_buffer="${number_buffer}${key_value}"
                if number_in_range "$number_buffer" "$total_count"; then
                    selected_index="$number_buffer"
                elif number_in_range "$key_value" "$total_count"; then
                    number_buffer="$key_value"
                    selected_index="$key_value"
                fi
                ;;
        esac
    done

    stty "$tty_state" </dev/tty 2>/dev/null || stty sane </dev/tty 2>/dev/null || true
    trap - EXIT INT TERM
    rm -rf "$key_dir"
    printf '\033[H\033[J'
    echo

    SELECTED_HOST_DIR=$(sed -n "${selected_index}p" "$candidates_file" | cut -d'|' -f1)
}

print_backup_option() {
    option_number="$1"
    is_selected="$2"
    option_line="$3"

    backup_name=$(echo "$option_line" | cut -d'|' -f2)
    backup_date=$(echo "$option_line" | cut -d'|' -f3)
    backup_time=$(echo "$option_line" | cut -d'|' -f4)
    backup_size=$(echo "$option_line" | cut -d'|' -f5)
    checksum_state=$(echo "$option_line" | cut -d'|' -f6)

    if [ "$is_selected" = "1" ]; then
        printf "%s  %-3s %-34s %-12s %-10s %-10s %-8s%s\n" \
            "$C_GREEN" "$option_number" "$backup_name" "$backup_date" "$backup_time" "$backup_size" "$checksum_state" "$C_RESET"
    else
        printf "  %-3s %-34s %-12s %-10s %-10s %-8s\n" \
            "$option_number" "$backup_name" "$backup_date" "$backup_time" "$backup_size" "$checksum_state"
    fi
}

print_backup_table() {
    candidates_file="$1"

    printf "  %-3s %-34s %-12s %-10s %-10s %-8s\n" "No" "OpenWrt version" "Date" "Time" "Size" "Checks"
    printf "  %-3s %-34s %-12s %-10s %-10s %-8s\n" "--" "---------------" "----" "----" "----" "------"

    current_index=1
    while IFS= read -r option_line; do
        print_backup_option "$current_index" "0" "$option_line"
        current_index=$((current_index + 1))
    done < "$candidates_file"
}

render_backup_menu() {
    candidates_file="$1"
    selected_index="$2"
    total_count="$3"
    number_buffer="${4:-}"
    selected_host_dir="$5"

    printf '\033[H\033[J'
    echo "Backups for hostname: $(basename "$selected_host_dir")"
    echo "Use Up/Down + Enter, or type number and press Enter. q cancels."
    echo
    printf "  %-3s %-34s %-12s %-10s %-10s %-8s\n" "No" "OpenWrt version" "Date" "Time" "Size" "Checks"
    printf "  %-3s %-34s %-12s %-10s %-10s %-8s\n" "--" "---------------" "----" "----" "----" "------"

    current_index=1
    while IFS= read -r option_line; do
        is_selected="0"
        [ "$current_index" -eq "$selected_index" ] && is_selected="1"
        print_backup_option "$current_index" "$is_selected" "$option_line"
        current_index=$((current_index + 1))
    done < "$candidates_file"

    if [ -n "$number_buffer" ]; then
        echo
        echo "Typed number: $number_buffer"
    fi
}

select_backup_candidate_simple() {
    candidates_file="$1"
    total_count="$2"
    selected_host_dir="$3"

    echo "Backups for hostname: $(basename "$selected_host_dir")"
    echo
    print_backup_table "$candidates_file"

    while true; do
        selection=$(prompt_value "Enter backup number or q to cancel" "1")
        case "$selection" in
            q|Q)
                echo "Cancelled."
                return 1
                ;;
        esac

        if number_in_range "$selection" "$total_count"; then
            SELECTED_BACKUP_DIR=$(sed -n "${selection}p" "$candidates_file" | cut -d'|' -f1)
            return 0
        fi

        echo "Enter a number from 1 to $total_count, or q."
    done
}

select_backup_candidate() {
    candidates_file="$1"
    selected_host_dir="$2"
    total_count=$(wc -l < "$candidates_file" | tr -d ' ')
    SELECTED_BACKUP_DIR=""

    [ "$total_count" -gt 0 ] || return 1

    if ! is_interactive; then
        echo "Backups for hostname: $(basename "$selected_host_dir")"
        echo
        print_backup_table "$candidates_file"
        return 1
    fi

    if ! supports_tty_menu; then
        warn "stty is not available. Falling back to simple numbered selection."
        print_stty_install_hint
        echo
        select_backup_candidate_simple "$candidates_file" "$total_count" "$selected_host_dir"
        return $?
    fi

    tty_state=$(stty -g </dev/tty)
    trap 'stty "$tty_state" </dev/tty 2>/dev/null || true' EXIT INT TERM
    stty -echo -icanon min 1 time 0 </dev/tty
    key_dir="/tmp/${SCRIPT_BASENAME}.keys.$$"
    prepare_key_refs "$key_dir"

    selected_index=1
    number_buffer=""
    while true; do
        render_backup_menu "$candidates_file" "$selected_index" "$total_count" "$number_buffer" "$selected_host_dir"
        read_tty_key_file "$key_dir/key1"

        [ -s "$key_dir/key1" ] || continue

        if key_file_matches "$key_dir/key1" "$key_dir/esc"; then
            read_tty_key_file "$key_dir/key2"
            read_tty_key_file "$key_dir/key3"
            number_buffer=""
            if key_file_matches "$key_dir/key2" "$key_dir/lb" && key_file_matches "$key_dir/key3" "$key_dir/up"; then
                if [ "$selected_index" -gt 1 ]; then
                    selected_index=$((selected_index - 1))
                fi
            elif key_file_matches "$key_dir/key2" "$key_dir/lb" && key_file_matches "$key_dir/key3" "$key_dir/down"; then
                if [ "$selected_index" -lt "$total_count" ]; then
                    selected_index=$((selected_index + 1))
                fi
            fi
            continue
        fi

        if key_file_matches "$key_dir/key1" "$key_dir/cr" || key_file_matches "$key_dir/key1" "$key_dir/lf"; then
            if [ -n "$number_buffer" ]; then
                if number_in_range "$number_buffer" "$total_count"; then
                    selected_index="$number_buffer"
                    break
                fi
                number_buffer=""
                continue
            fi
            break
        fi

        if key_file_matches "$key_dir/key1" "$key_dir/bs" || key_file_matches "$key_dir/key1" "$key_dir/del"; then
            number_buffer=${number_buffer%?}
            continue
        fi

        key_value=$(cat "$key_dir/key1" 2>/dev/null || true)
        case "$key_value" in
            q|Q)
                stty "$tty_state" </dev/tty 2>/dev/null || stty sane </dev/tty 2>/dev/null || true
                trap - EXIT INT TERM
                rm -rf "$key_dir"
                printf '\033[H\033[J'
                echo "Cancelled."
                return 1
                ;;
            [0-9])
                number_buffer="${number_buffer}${key_value}"
                if number_in_range "$number_buffer" "$total_count"; then
                    selected_index="$number_buffer"
                elif number_in_range "$key_value" "$total_count"; then
                    number_buffer="$key_value"
                    selected_index="$key_value"
                fi
                ;;
        esac
    done

    stty "$tty_state" </dev/tty 2>/dev/null || stty sane </dev/tty 2>/dev/null || true
    trap - EXIT INT TERM
    rm -rf "$key_dir"
    printf '\033[H\033[J'
    echo

    SELECTED_BACKUP_DIR=$(sed -n "${selected_index}p" "$candidates_file" | cut -d'|' -f1)
}

latest_backup_dir() {
    backup_root=$(normalize_backup_root_path "$1")
    candidates_file=$(backup_candidates_file)
    host_file=$(host_candidates_file)
    latest_dir=""
    preferred_host_dir=$(current_host_backup_root "$backup_root")

    gather_backup_candidates "$preferred_host_dir" "$candidates_file"

    if [ ! -s "$candidates_file" ]; then
        gather_host_candidates "$backup_root" "$host_file"
        if [ -s "$host_file" ]; then
            selected_host_dir=$(sed -n '1p' "$host_file" | cut -d'|' -f1)
            gather_backup_candidates "$selected_host_dir" "$candidates_file"
        fi
    fi

    if [ -s "$candidates_file" ]; then
        latest_dir=$(sed -n '1p' "$candidates_file" | cut -d'|' -f1)
    fi

    rm -f "$host_file"
    rm -f "$candidates_file"

    [ -n "$latest_dir" ] || die "No backups found in $backup_root"
    echo "$latest_dir"
}

delete_backup_dir() {
    backup_dir="$1"
    host_dir=$(dirname "$backup_dir")

    [ -d "$backup_dir" ] || die "Backup directory not found: $backup_dir"
    [ -f "$backup_dir/$ARCHIVE_NAME" ] || die "Archive not found: $backup_dir/$ARCHIVE_NAME"

    rm -rf "$backup_dir"
    rmdir "$host_dir" 2>/dev/null || true
    echo "Backup deleted: $backup_dir"
}

handle_selected_backup() {
    selected_backup_dir="$1"

    echo "Selected backup: $selected_backup_dir"
    print_backup_identity_lines "$selected_backup_dir"
    if [ ! -f "$selected_backup_dir/$CHECKSUMS_NAME" ]; then
        warn "This backup is missing $CHECKSUMS_NAME. Restore will fail until the file is restored."
    fi
    echo

    while true; do
        if is_interactive; then
            printf "Action: [r]estore, [d]elete, [c]ancel: " > /dev/tty
            IFS= read -r action < /dev/tty || action=""
        else
            printf "Action: [r]estore, [d]elete, [c]ancel: "
            IFS= read -r action || action=""
        fi

        action=$(echo "$action" | tr 'A-Z' 'a-z')

        case "$action" in
            r|restore)
                restore_backup "$selected_backup_dir" "$DEFAULT_RESTORE_TARGET"
                return 0
                ;;
            d|delete)
                ask_yes_no "Delete selected backup permanently? [y/N]" "n" || return 0
                acquire_lock
                delete_backup_dir "$selected_backup_dir"
                return 0
                ;;
            c|cancel|q|quit|'')
                echo "Cancelled."
                return 0
                ;;
            *)
                echo "Enter r, d, or c."
                ;;
        esac
    done
}

list_backups_interactive() {
    backup_root=$(normalize_backup_root_path "$BACKUP_ROOT")
    host_file=$(host_candidates_file)
    candidates_file=$(backup_candidates_file)

    gather_host_candidates "$backup_root" "$host_file"

    if [ ! -s "$host_file" ]; then
        rm -f "$host_file"
        rm -f "$candidates_file"
        die "No backups found in $backup_root"
    fi

    select_host_candidate "$host_file" || {
        rm -f "$host_file"
        rm -f "$candidates_file"
        return 0
    }

    rm -f "$host_file"

    [ -n "$SELECTED_HOST_DIR" ] || {
        rm -f "$candidates_file"
        return 0
    }

    gather_backup_candidates "$SELECTED_HOST_DIR" "$candidates_file"

    if [ ! -s "$candidates_file" ]; then
        rm -f "$candidates_file"
        die "No backups found in $SELECTED_HOST_DIR"
    fi

    select_backup_candidate "$candidates_file" "$SELECTED_HOST_DIR" || {
        rm -f "$candidates_file"
        return 0
    }

    rm -f "$candidates_file"

    [ -n "$SELECTED_BACKUP_DIR" ] || return 0
    handle_selected_backup "$SELECTED_BACKUP_DIR"
}

reconfigure_backup_root() {
    echo "Current backup root:"
    echo "  $(normalize_backup_root_path "$BACKUP_ROOT")"

    choose_backup_root || {
        echo "Backup root unchanged."
        return 0
    }
    BACKUP_ROOT=$(normalize_backup_root_path "$CHOSEN_BACKUP_ROOT")
    assert_backup_root_writable "$BACKUP_ROOT"
    write_config "$BACKUP_ROOT"

    log "Saved config to $CONFIG_PATH"
    echo "New backup root: $BACKUP_ROOT"
}

create_backup() {
    target_backup_root=$(normalize_backup_root_path "${1:-$BACKUP_ROOT}")
    target_host_root=$(current_host_backup_root "$target_backup_root")
    target_backup_dir="$target_host_root/$(current_backup_leaf_name)"
    staging_dir=""
    finalize_dir="$target_host_root/.${SCRIPT_BASENAME}.complete.$$"
    selected_stage_mode=$(backup_stage_mode_for_root "$target_backup_root")

    [ -d /overlay/upper ] || die "Directory /overlay/upper is not available."
    require_backup_prerequisites
    assert_backup_root_writable "$target_backup_root"
    check_free_space "$target_backup_root"
    [ ! -e "$target_backup_dir" ] || die "Backup directory already exists: $target_backup_dir"
    [ ! -e "$finalize_dir" ] || die "Temporary destination already exists: $finalize_dir"
    print_backup_preflight "$target_backup_root" "$target_backup_dir" "$selected_stage_mode"

    register_exit_cleanup_path "$finalize_dir"
    staging_dir=$(prepare_backup_stage_dir "$target_backup_root" "$finalize_dir")
    register_exit_cleanup_path "$staging_dir"

    log "Writing package list"
    write_package_list "$staging_dir"

    log "Writing metadata"
    write_metadata "$staging_dir" "$target_backup_dir"

    log "Creating archive $ARCHIVE_NAME"
    archive_create "$staging_dir/$ARCHIVE_NAME"

    log "Verifying archive integrity"
    archive_verify "$staging_dir/$ARCHIVE_NAME"

    log "Writing checksums"
    write_checksums "$staging_dir"

    log "Verifying staged checksums"
    verify_checksums "$staging_dir"

    if [ "$staging_dir" != "$finalize_dir" ]; then
        log "Copying verified backup to destination"
        mkdir -p "$finalize_dir"
        copy_backup_payload "$staging_dir" "$finalize_dir"

        log "Verifying written checksums"
        verify_checksums "$finalize_dir"
    fi

    log "Finalizing backup directory"
    mkdir -p "$target_backup_dir"
    move_backup_payload "$finalize_dir" "$target_backup_dir"

    log "Verifying finalized checksums"
    verify_checksums "$target_backup_dir"

    rmdir "$finalize_dir" 2>/dev/null || rm -rf "$finalize_dir"
    rm -rf "$staging_dir"
    unregister_exit_cleanup_path "$staging_dir"
    unregister_exit_cleanup_path "$finalize_dir"

    archive_size=$(du -h "$target_backup_dir/$ARCHIVE_NAME" | awk '{print $1}')

    echo
    echo "Backup created successfully."
    echo "Directory: $target_backup_dir"
    echo "Archive:   $target_backup_dir/$ARCHIVE_NAME"
    echo "Packages:  $target_backup_dir/$PACKAGE_LIST_NAME"
    echo "Metadata:  $target_backup_dir/$METADATA_NAME"
    echo "Checksums: $target_backup_dir/$CHECKSUMS_NAME"
    echo "Size:      $archive_size"

    rotate_old_backups "$target_host_root"
}

validate_restore_inputs() {
    backup_dir="$1"
    restore_target=$(normalize_restore_target "${2:-$DEFAULT_RESTORE_TARGET}")
    archive_path="$backup_dir/$ARCHIVE_NAME"

    [ -d "$backup_dir" ] || die "Backup directory not found: $backup_dir"
    [ -f "$archive_path" ] || die "Archive not found: $archive_path"
    [ -d "$restore_target" ] || die "Restore target not found: $restore_target"
    assert_restore_target_supported "$restore_target"

    case "$restore_target" in
        /)
            die "Refusing to restore directly into /."
            ;;
    esac

    case "$restore_target" in
        "$backup_dir"|"$backup_dir"/*)
            die "Restore target must not be inside the backup directory."
            ;;
    esac

    case "$backup_dir" in
        "$restore_target"|"$restore_target"/*)
            die "Restore target must not contain the backup directory."
            ;;
    esac
}

restore_backup() {
    backup_dir="$1"
    restore_target=$(normalize_restore_target "${2:-$DEFAULT_RESTORE_TARGET}")

    require_restore_prerequisites
    validate_restore_inputs "$backup_dir" "$restore_target"
    check_restore_free_space "$backup_dir" "$restore_target"
    print_restore_preflight "$backup_dir" "$restore_target"
    confirm_restore "$backup_dir" "$restore_target" || return 0

    acquire_lock
    extract_archive "$backup_dir" "$restore_target"
}

wipe_restore_target_contents() {
    restore_target="$1"

    [ -d "$restore_target" ] || die "Restore target not found: $restore_target"
    [ "$restore_target" != "/" ] || die "Refusing to wipe / directly."

    log "Clearing existing contents of $restore_target"
    for entry in "$restore_target"/* "$restore_target"/.[!.]* "$restore_target"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        rm -rf "$entry"
    done
}

extract_archive() {
    backup_dir="$1"
    restore_target=$(normalize_restore_target "${2:-$DEFAULT_RESTORE_TARGET}")
    archive_path="$backup_dir/$ARCHIVE_NAME"

    require_restore_prerequisites
    validate_restore_inputs "$backup_dir" "$restore_target"
    verify_checksums "$backup_dir"
    wipe_restore_target_contents "$restore_target"

    log "Extracting $ARCHIVE_NAME into $restore_target"
    archive_extract "$archive_path" "$restore_target"

    echo
    echo "Overlay restore completed."
    if is_live_overlay_target "$restore_target"; then
        prompt_reboot_now
    else
        echo "Test restore target populated successfully. No reboot required."
    fi
}

main() {
    setup_colors

    while [ $# -gt 0 ]; do
        case "$1" in
            --pigz)
                COMPRESSOR_MODE="pigz"
                shift
                ;;
            --gzip)
                COMPRESSOR_MODE="gzip"
                shift
                ;;
            --allow-ram)
                ALLOW_RAM_BACKUP="1"
                shift
                ;;
            -remove|--remove)
                REMOVE_INSTALLATION="1"
                shift
                ;;
            *)
                break
                ;;
        esac
    done

    if [ "$REMOVE_INSTALLATION" != "1" ]; then
        self_update_if_enabled "$@"
    fi

    require_root
    require_commands tar sha256sum mount awk sed grep sort wc du date uname cp chmod ln dirname pwd basename dd find rm cut tr cat df mkdir mv rmdir

    if [ "$REMOVE_INSTALLATION" = "1" ]; then
        [ $# -eq 0 ] || die "-remove does not accept additional arguments."
        remove_installed_artifacts
        exit 0
    fi

    BACKUP_ROOT=$(normalize_backup_root_path "$BACKUP_ROOT")
    validate_retention_count
    validate_auto_update_settings
    handle_post_install_handoff "$@"

    if ! is_installed_invocation; then
        [ $# -gt 0 ] || run_installer
    fi

    [ $# -gt 0 ] || {
        usage
        exit 1
    }

    command_name="$1"
    shift

    if ! is_installed_invocation; then
        case "$command_name" in
            -h|--help|help)
                usage
                exit 0
                ;;
            backup|restore|list|place)
                run_installer "$command_name" "$@"
                die "Installed command handoff failed."
                ;;
            *)
                die "This copy can only show help, remove the installed script, or hand off supported commands to the installed copy."
                ;;
        esac
    fi

    case "$command_name" in
        backup)
            [ $# -le 1 ] || die "backup accepts at most one argument."
            require_backup_prerequisites
            acquire_lock
            create_backup "${1:-$BACKUP_ROOT}"
            ;;
        restore)
            [ $# -le 2 ] || die "restore accepts at most two arguments."
            if [ $# -eq 0 ]; then
                selected_restore_dir=$(latest_backup_dir "$BACKUP_ROOT")
                echo "Selected latest backup: $selected_restore_dir"
                restore_backup "$selected_restore_dir" "$DEFAULT_RESTORE_TARGET"
            else
                restore_backup "$1" "${2:-$DEFAULT_RESTORE_TARGET}"
            fi
            ;;
        list)
            [ $# -eq 0 ] || die "list does not accept arguments."
            list_backups_interactive
            ;;
        place)
            [ $# -eq 0 ] || die "place does not accept arguments."
            reconfigure_backup_root
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            die "Unknown command: $command_name"
            ;;
    esac
}

main "$@"
