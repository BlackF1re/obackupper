#!/bin/sh
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin
SCRIPT_BASENAME="obackupper.sh"
SHORTCUT_NAME="obackupper"
INSTALL_PATH="/usr/bin/$SCRIPT_BASENAME"
SHORTCUT_PATH="/usr/bin/$SHORTCUT_NAME"
LEGACY_INSTALL_PATH="/usr/bin/openwrt_overlay_backupper.sh"
CONFIG_PATH="/etc/openwrt_overlay_backupper.conf"
BACKUP_ROOT_DIRNAME="obackupper_backups"
FALLBACK_BACKUP_ROOT="/overlay/share/$BACKUP_ROOT_DIRNAME"
DEFAULT_RESTORE_TARGET="/overlay/upper"
ARCHIVE_NAME="overlay-upper.tar.gz"
PACKAGE_LIST_NAME="installed_packages.txt"
METADATA_NAME="metadata.txt"
CHECKSUMS_NAME="sha256sums.txt"
COMPRESSOR_MODE="${COMPRESSOR_MODE:-pigz}"
RETENTION_COUNT="${RETENTION_COUNT:-20}"
AUTO_UPDATE="${AUTO_UPDATE:-1}"
AUTO_UPDATE_URL="${AUTO_UPDATE_URL:-https://raw.githubusercontent.com/BlackF1re/obackupper/main/obackupper.sh}"
AUTO_UPDATE_INTERVAL="${AUTO_UPDATE_INTERVAL:-0}"
SELF_UPDATE_STAMP="/tmp/${SHORTCUT_NAME}.self-update.stamp"
LOCK_DIR="/tmp/${SCRIPT_BASENAME}.lock"
ALLOW_RAM_BACKUP=0
REMOVE_INSTALLATION=0

C_RESET= C_RED= C_GREEN= C_YELLOW= C_CYAN= C_BOLD=
BACKUP_ROOT="${BACKUP_ROOT:-$FALLBACK_BACKUP_ROOT}"
[ -r "$CONFIG_PATH" ] && . "$CONFIG_PATH"

setup_colors() {
    if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ] && [ "${TERM:-}" != dumb ]; then
        C_RESET=$(printf '\033[0m'); C_BOLD=$(printf '\033[1m')
        C_RED=$(printf '\033[31m'); C_GREEN=$(printf '\033[32m')
        C_YELLOW=$(printf '\033[33m'); C_CYAN=$(printf '\033[36m')
    fi
}
log() { printf "%s==>%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf "%sWarning:%s %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() { printf "%sError:%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
    local root
    root=$(normalize_backup_root_path "$BACKUP_ROOT" 2>/dev/null || echo "$BACKUP_ROOT")
    cat <<EOF_USAGE
Usage:
  $SCRIPT_BASENAME [--pigz|--gzip] [--allow-ram] backup [DIR]
  $SCRIPT_BASENAME [--pigz|--gzip] restore [BACKUP_DIR] [TARGET]
  $SCRIPT_BASENAME [--pigz|--gzip] list
  $SCRIPT_BASENAME place
  $SCRIPT_BASENAME -remove

Commands:
  backup [DIR]        Create backup in DIR/<hostname>/<OpenWrt version + timestamp>
  restore             Open safe hostname -> backup selector; does not restore immediately
  restore BACKUP_DIR  Restore concrete backup only after explicit confirmation
  list                Interactive hostname -> backup -> action selector
  place               Interactive writable storage / existing backup-root selector
  -remove             Remove installed script, shortcut and config

Menus:
  Use Up/Down arrows, Enter to select, q to cancel.

Current BACKUP_ROOT: $root
EOF_USAGE
}

require_root() { [ "$(id -u)" = 0 ] || die "Run this script as root."; }
require_commands() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "Required command not found: $c"; done; }
is_interactive() { [ -t 0 ] && [ -t 1 ] && [ -r /dev/tty ] && [ -w /dev/tty ]; }

prompt_value() {
    local text def ans prompt
    text="$1"; def="${2:-}"; ans=""
    if [ -n "$def" ]; then prompt="$text [$def]: "; else prompt="$text: "; fi
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
        printf "%s" "$prompt" > /dev/tty
        IFS= read -r ans < /dev/tty || ans=""
    else
        printf "%s" "$prompt"
        IFS= read -r ans || ans=""
    fi
    [ -n "$ans" ] || ans="$def"
    printf "%s" "$ans"
}
ask_yes_no() { local ans; ans=$(prompt_value "$1" "${2:-n}"); ans=$(printf "%s" "$ans" | tr A-Z a-z); [ "$ans" = y ] || [ "$ans" = yes ]; }

sanitize_path_component() { printf "%s" "$1" | sed 's#[/[:space:]]#_#g; s/[^A-Za-z0-9._-]/_/g; s/^__*/_/; s/__*$//'; }
current_hostname() { local h; h=$(uname -n 2>/dev/null || hostname 2>/dev/null || echo OpenWrt); h=$(sanitize_path_component "$h"); [ -n "$h" ] && echo "$h" || echo OpenWrt; }
normalize_backup_root_path() { local p; p="${1:-$BACKUP_ROOT}"; [ -n "$p" ] || p="$FALLBACK_BACKUP_ROOT"; p=${p%/}; case "$p" in */$BACKUP_ROOT_DIRNAME) echo "$p";; *) echo "$p/$BACKUP_ROOT_DIRNAME";; esac; }
normalize_restore_target() { local t; t="${1:-$DEFAULT_RESTORE_TARGET}"; [ "$t" = / ] && echo "$DEFAULT_RESTORE_TARGET" || echo "${t%/}"; }

validate_settings() {
    case "$RETENTION_COUNT" in ''|*[!0-9]*) die "RETENTION_COUNT must be a non-negative integer.";; esac
    case "$AUTO_UPDATE" in 0|1) ;; *) die "AUTO_UPDATE must be 0 or 1.";; esac
    case "$AUTO_UPDATE_INTERVAL" in ''|*[!0-9]*) die "AUTO_UPDATE_INTERVAL must be a non-negative integer.";; esac
}

find_download_tool() { command -v uclient-fetch >/dev/null 2>&1 && { echo uclient-fetch; return; }; command -v wget >/dev/null 2>&1 && { echo wget; return; }; command -v curl >/dev/null 2>&1 && { echo curl; return; }; return 1; }
download_to() { local tool; tool=$(find_download_tool) || return 1; case "$tool" in wget) wget -q -O "$2" "$1";; uclient-fetch) uclient-fetch -q -O "$2" "$1";; curl) curl -fsSL -o "$2" "$1";; esac; }
file_checksum() { [ -f "$1" ] || return 1; sha256sum "$1" | awk '{print $1}'; }
existing_install_path() { [ -f "$INSTALL_PATH" ] && { echo "$INSTALL_PATH"; return; }; [ -f "$LEGACY_INSTALL_PATH" ] && { echo "$LEGACY_INSTALL_PATH"; return; }; return 1; }
is_installed_invocation() {
    case "$0" in
        "$INSTALL_PATH"|"$SHORTCUT_PATH"|"$LEGACY_INSTALL_PATH"|"$SCRIPT_BASENAME"|"$SHORTCUT_NAME") return 0;;
    esac
    return 1
}

write_config() {
    local root tmp
    root=$(normalize_backup_root_path "$1"); tmp="/tmp/${SCRIPT_BASENAME}.config.$$"
    { echo "BACKUP_ROOT='$root'"; echo "RETENTION_COUNT='$RETENTION_COUNT'"; echo "AUTO_UPDATE='$AUTO_UPDATE'"; echo "AUTO_UPDATE_URL='$AUTO_UPDATE_URL'"; echo "AUTO_UPDATE_INTERVAL='$AUTO_UPDATE_INTERVAL'"; } > "$tmp"
    mkdir -p "$(dirname "$CONFIG_PATH")"; mv "$tmp" "$CONFIG_PATH"
}
install_self() {
    require_commands cp chmod ln mkdir dirname rm
    mkdir -p "$(dirname "$INSTALL_PATH")"
    cp "$0" "$INSTALL_PATH"; chmod 0755 "$INSTALL_PATH"; ln -sf "$INSTALL_PATH" "$SHORTCUT_PATH"
    [ -r "$CONFIG_PATH" ] || write_config "$BACKUP_ROOT"
    [ -f "$LEGACY_INSTALL_PATH" ] && rm -f "$LEGACY_INSTALL_PATH"
    log "Installed to $INSTALL_PATH"; echo "Shortcut: $SHORTCUT_PATH"; echo "Backup root: $(normalize_backup_root_path "$BACKUP_ROOT")"
}
remove_installed_artifacts() { local p any; any=0; for p in "$INSTALL_PATH" "$LEGACY_INSTALL_PATH" "$SHORTCUT_PATH" "$CONFIG_PATH"; do if [ -e "$p" ] || [ -L "$p" ]; then rm -f "$p"; echo "Removed: $p"; any=1; else echo "Not present: $p"; fi; done; [ "$any" = 1 ] || echo "Nothing to remove."; }

self_update_if_enabled() {
    is_installed_invocation || return 0
    [ "$AUTO_UPDATE" = 1 ] || return 0
    [ -n "$AUTO_UPDATE_URL" ] || return 0
    if [ "$AUTO_UPDATE_INTERVAL" -gt 0 ] && [ -f "$SELF_UPDATE_STAMP" ]; then
        local now last elapsed
        now=$(date +%s); last=$(cat "$SELF_UPDATE_STAMP" 2>/dev/null || echo 0); case "$last" in ''|*[!0-9]*) last=0;; esac
        elapsed=$((now - last)); [ "$elapsed" -lt "$AUTO_UPDATE_INTERVAL" ] && return 0
    fi
    find_download_tool >/dev/null 2>&1 || return 0
    local tmp cur new
    tmp="/tmp/${SCRIPT_BASENAME}.update.$$"
    if download_to "$AUTO_UPDATE_URL" "$tmp"; then
        cur=$(file_checksum "$(existing_install_path)" 2>/dev/null || true); new=$(file_checksum "$tmp" 2>/dev/null || true)
        if [ -n "$new" ] && [ "$new" != "$cur" ]; then
            log "Updating $SHORTCUT_NAME from GitHub"
            cp "$tmp" "$INSTALL_PATH"; chmod 0755 "$INSTALL_PATH"; ln -sf "$INSTALL_PATH" "$SHORTCUT_PATH"
            date +%s > "$SELF_UPDATE_STAMP" 2>/dev/null || true; rm -f "$tmp"; exec "$SHORTCUT_PATH" "$@"
        fi
    fi
    rm -f "$tmp"; date +%s > "$SELF_UPDATE_STAMP" 2>/dev/null || true
}

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then echo $$ > "$LOCK_DIR/pid"; trap 'release_lock' EXIT INT TERM HUP; return; fi
    local pid
    pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && die "Another instance is already running (PID $pid)."
    warn "Removing stale lock: $LOCK_DIR"; rm -rf "$LOCK_DIR"; mkdir "$LOCK_DIR" || die "Failed to acquire lock: $LOCK_DIR"; echo $$ > "$LOCK_DIR/pid"; trap 'release_lock' EXIT INT TERM HUP
}
release_lock() { local pid; [ -d "$LOCK_DIR" ] || return 0; pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true); [ -n "$pid" ] && [ "$pid" != $$ ] && return 0; rm -rf "$LOCK_DIR"; }

detect_package_manager() { command -v opkg >/dev/null 2>&1 && { echo opkg; return; }; command -v apk >/dev/null 2>&1 && { echo apk; return; }; echo unknown; }
list_installed_packages() { case "$(detect_package_manager)" in opkg) opkg list-installed 2>/dev/null | sort;; apk) apk info -vv 2>/dev/null | sort;; *) true;; esac; }
owrt_value() { local key; key="$1"; [ -r /etc/openwrt_release ] && . /etc/openwrt_release; eval "printf '%s' \"\${$key:-}\""; }
current_backup_leaf_name() { local r v; r=$(sanitize_path_component "$(owrt_value DISTRIB_RELEASE)"); v=$(sanitize_path_component "$(owrt_value DISTRIB_REVISION)"); [ -n "$r" ] || r=unknown; [ -n "$v" ] || v=unknown; echo "OpenWrt_${r}_${v}_$(date '+%F_%H-%M-%S')"; }

write_package_list() { list_installed_packages > "$1/$PACKAGE_LIST_NAME"; }
append_section() { local s; s="$1"; shift; echo; echo "[$s]"; "$@" 2>&1 || true; }
write_metadata() {
    local dir recorded pm cnt
    dir="$1"; recorded="$2"; pm=$(detect_package_manager); cnt=$(wc -l < "$dir/$PACKAGE_LIST_NAME" | tr -d ' ')
    { echo "backup_created=$(date '+%F %T %z')"; echo "backup_dir=$recorded"; echo "hostname=$(uname -n 2>/dev/null || echo unknown)"; echo "kernel=$(uname -a 2>/dev/null || echo unknown)"; echo "package_count=$cnt"; echo "package_manager=$pm"; echo "compressor_mode=$COMPRESSOR_MODE"; echo "configured_backup_root=$BACKUP_ROOT";
      [ -r /tmp/sysinfo/model ] && echo "model=$(cat /tmp/sysinfo/model)"; [ -r /tmp/sysinfo/board_name ] && echo "board_name=$(cat /tmp/sysinfo/board_name)";
      if [ -r /etc/openwrt_release ]; then . /etc/openwrt_release; echo "openwrt_release=${DISTRIB_RELEASE:-unknown}"; echo "openwrt_revision=${DISTRIB_REVISION:-unknown}"; echo "openwrt_target=${DISTRIB_TARGET:-unknown}"; echo "openwrt_arch=${DISTRIB_ARCH:-unknown}"; echo "openwrt_description=${DISTRIB_DESCRIPTION:-unknown}"; fi
      [ -r /etc/openwrt_release ] && append_section openwrt_release cat /etc/openwrt_release; [ -r /etc/os-release ] && append_section os_release cat /etc/os-release; append_section mount mount; append_section df_h df -h; append_section package_list sort "$dir/$PACKAGE_LIST_NAME"; } > "$dir/$METADATA_NAME"
}
write_checksums() { ( cd "$1" && sha256sum "$ARCHIVE_NAME" "$PACKAGE_LIST_NAME" "$METADATA_NAME" > "$CHECKSUMS_NAME" ); }
verify_checksums() { [ -f "$1/$CHECKSUMS_NAME" ] || die "Checksums file not found: $1/$CHECKSUMS_NAME"; log "Verifying checksums"; ( cd "$1" && sha256sum -c "$CHECKSUMS_NAME" ); }
archive_create() { if [ "$COMPRESSOR_MODE" = pigz ] && command -v pigz >/dev/null 2>&1; then tar -cf - -C /overlay/upper . | pigz -c > "$1"; else [ "$COMPRESSOR_MODE" = pigz ] && warn "pigz not found; using gzip."; tar -czf "$1" -C /overlay/upper .; fi; }

prepare_key_refs() {
    local key_dir
    key_dir="$1"; rm -rf "$key_dir"; mkdir -p "$key_dir"
    printf '\033' > "$key_dir/esc"; printf '[' > "$key_dir/lb"
    printf 'A' > "$key_dir/up"; printf 'B' > "$key_dir/down"
    printf '\r' > "$key_dir/cr"; printf '\n' > "$key_dir/lf"
    printf 'q' > "$key_dir/q"; printf 'Q' > "$key_dir/Q"
}
read_tty_key_file() { : > "$1"; dd bs=1 count=1 of="$1" 2>/dev/null < /dev/tty || true; }
key_file_matches() { cmp -s "$1" "$2" 2>/dev/null; }

print_host_option() {
    local idx selected line name cnt date time pref note
    idx="$1"; selected="$2"; line="$3"
    name=$(echo "$line"|cut -d'|' -f2); cnt=$(echo "$line"|cut -d'|' -f3); date=$(echo "$line"|cut -d'|' -f4); time=$(echo "$line"|cut -d'|' -f5); pref=$(echo "$line"|cut -d'|' -f6)
    note=""; [ "$pref" = 1 ] && note=current
    if [ "$selected" = 1 ] || [ "$pref" = 1 ]; then
        printf "%s  %-3s %-24s %-8s %-12s %-10s %-8s%s\n" "$C_GREEN" "$idx" "$name" "$cnt" "$date" "$time" "$note" "$C_RESET"
    else
        printf "  %-3s %-24s %-8s %-12s %-10s %-8s\n" "$idx" "$name" "$cnt" "$date" "$time" "$note"
    fi
}
print_backup_option() {
    local idx selected line name date time size checks
    idx="$1"; selected="$2"; line="$3"
    name=$(echo "$line"|cut -d'|' -f2); date=$(echo "$line"|cut -d'|' -f3); time=$(echo "$line"|cut -d'|' -f4); size=$(echo "$line"|cut -d'|' -f5); checks=$(echo "$line"|cut -d'|' -f6)
    if [ "$selected" = 1 ]; then
        printf "%s  %-3s %-34s %-12s %-10s %-10s %-8s%s\n" "$C_GREEN" "$idx" "$name" "$date" "$time" "$size" "$checks" "$C_RESET"
    else
        printf "  %-3s %-34s %-12s %-10s %-10s %-8s\n" "$idx" "$name" "$date" "$time" "$size" "$checks"
    fi
}
print_storage_option() {
    local idx selected line root kind avail note
    idx="$1"; selected="$2"; line="$3"
    root=$(echo "$line"|cut -d'|' -f1); kind=$(echo "$line"|cut -d'|' -f3); avail=$(echo "$line"|cut -d'|' -f4); note=$(echo "$line"|cut -d'|' -f5)
    if [ "$selected" = 1 ]; then
        printf "%s  %-3s %-48s %-10s %-10s %-16s%s\n" "$C_GREEN" "$idx" "$root" "$kind" "$avail" "$note" "$C_RESET"
    else
        printf "  %-3s %-48s %-10s %-10s %-16s\n" "$idx" "$root" "$kind" "$avail" "$note"
    fi
}
print_action_option() {
    local idx selected line label
    idx="$1"; selected="$2"; line="$3"
    label=$(echo "$line"|cut -d'|' -f2)
    if [ "$selected" = 1 ]; then printf "%s  %-3s %s%s\n" "$C_GREEN" "$idx" "$label" "$C_RESET"; else printf "  %-3s %s\n" "$idx" "$label"; fi
}

render_menu() {
    local kind title file selected idx line is_sel
    kind="$1"; title="$2"; file="$3"; selected="$4"
    printf '\033[H\033[J'
    echo "$title"
    echo "Use Up/Down arrows, Enter to select. Press q to cancel."
    echo
    case "$kind" in
        host) printf "  %-3s %-24s %-8s %-12s %-10s %-8s\n" No Hostname Backups "Last date" "Last time" Priority; printf "  %-3s %-24s %-8s %-12s %-10s %-8s\n" -- -------- ------- --------- --------- --------;;
        backup) printf "  %-3s %-34s %-12s %-10s %-10s %-8s\n" No "OpenWrt version" Date Time Size Checks; printf "  %-3s %-34s %-12s %-10s %-10s %-8s\n" -- --------------- ---- ---- ---- ------;;
        storage) printf "  %-3s %-48s %-10s %-10s %-16s\n" No "Backup root" Type Available Note; printf "  %-3s %-48s %-10s %-10s %-16s\n" -- ----------- ---- -------- ----;;
        action) :;;
    esac
    idx=1
    while IFS= read -r line; do
        is_sel=0; [ "$idx" -eq "$selected" ] && is_sel=1
        case "$kind" in
            host) print_host_option "$idx" "$is_sel" "$line";;
            backup) print_backup_option "$idx" "$is_sel" "$line";;
            storage) print_storage_option "$idx" "$is_sel" "$line";;
            action) print_action_option "$idx" "$is_sel" "$line";;
        esac
        idx=$((idx + 1))
    done < "$file"
}

select_menu_line() {
    local kind title file total tty_state key_dir selected
    kind="$1"; title="$2"; file="$3"
    total=$(wc -l < "$file" | tr -d ' ')
    SELECTED_LINE=""
    [ "$total" -gt 0 ] || return 1
    if ! is_interactive; then
        render_menu "$kind" "$title" "$file" 0
        return 1
    fi
    command -v stty >/dev/null 2>&1 || die "Interactive menus require stty. Install coreutils-stty."
    command -v dd >/dev/null 2>&1 || die "Interactive menus require dd."
    command -v cmp >/dev/null 2>&1 || die "Interactive menus require cmp."
    tty_state=$(stty -g < /dev/tty)
    key_dir="/tmp/${SCRIPT_BASENAME}.keys.$$"
    prepare_key_refs "$key_dir"
    trap 'stty "$tty_state" < /dev/tty 2>/dev/null || true; rm -rf "$key_dir"; exit 130' INT TERM HUP
    stty -echo -icanon min 1 time 0 < /dev/tty
    selected=1
    while true; do
        render_menu "$kind" "$title" "$file" "$selected"
        read_tty_key_file "$key_dir/key1"
        [ -s "$key_dir/key1" ] || continue
        if key_file_matches "$key_dir/key1" "$key_dir/esc"; then
            read_tty_key_file "$key_dir/key2"
            read_tty_key_file "$key_dir/key3"
            if key_file_matches "$key_dir/key2" "$key_dir/lb" && key_file_matches "$key_dir/key3" "$key_dir/up"; then
                [ "$selected" -gt 1 ] && selected=$((selected - 1))
            elif key_file_matches "$key_dir/key2" "$key_dir/lb" && key_file_matches "$key_dir/key3" "$key_dir/down"; then
                [ "$selected" -lt "$total" ] && selected=$((selected + 1))
            fi
            continue
        fi
        if key_file_matches "$key_dir/key1" "$key_dir/cr" || key_file_matches "$key_dir/key1" "$key_dir/lf"; then
            stty "$tty_state" < /dev/tty 2>/dev/null || true
            trap - INT TERM HUP
            rm -rf "$key_dir"
            printf '\033[H\033[J'
            SELECTED_LINE=$(sed -n "${selected}p" "$file")
            return 0
        fi
        if key_file_matches "$key_dir/key1" "$key_dir/q" || key_file_matches "$key_dir/key1" "$key_dir/Q"; then
            stty "$tty_state" < /dev/tty 2>/dev/null || true
            trap - INT TERM HUP
            rm -rf "$key_dir"
            printf '\033[H\033[J'
            echo "Cancelled."
            return 1
        fi
    done
}

backup_identity_value() { [ -r "$1/$METADATA_NAME" ] || return 0; grep "^$2=" "$1/$METADATA_NAME" 2>/dev/null | sed -n '1s/^[^=]*=//p'; }
backup_name_date_time() {
    local dir leaf name created date time
    dir="$1"; leaf=$(basename "$dir"); name=$(backup_identity_value "$dir" openwrt_description || true); created=$(backup_identity_value "$dir" backup_created || true)
    if [ -n "$created" ]; then set -- $created; date="${1:-unknown}"; time="${2:-unknown}"; [ -n "$name" ] || name="$leaf"; echo "$name|$date|$time"; return; fi
    date=$(printf "%s" "$leaf" | sed -n 's/^.*_\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)_[0-9-]*$/\1/p')
    time=$(printf "%s" "$leaf" | sed -n 's/^.*_[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_\([0-9-]*\)$/\1/p' | tr - :)
    [ -n "$date" ] || date=unknown; [ -n "$time" ] || time=unknown
    [ -n "$name" ] || name=$(printf "%s" "$leaf" | sed 's/_[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9-]*$//')
    echo "$name|$date|$time"
}
backup_sort_key() { local c leaf k; c=$(backup_identity_value "$1" backup_created || true); if [ -n "$c" ]; then k=$(printf "%s" "$c" | tr -cd 0-9 | cut -c1-14); [ -n "$k" ] && { echo "$k"; return; }; fi; leaf=$(basename "$1"); k=$(printf "%s" "$leaf" | sed -n 's/^.*_\([0-9][0-9][0-9][0-9]\)-\([0-9][0-9]\)-\([0-9][0-9]\)_\([0-9][0-9]\)-\([0-9][0-9]\)-\([0-9][0-9]\)$/\1\2\3\4\5\6/p'); [ -n "$k" ] && echo "$k" || echo 00000000000000; }
backup_checksums_state() { [ -f "$1/$CHECKSUMS_NAME" ] && echo ok || echo missing; }

gather_backup_candidates() {
    local host_root out sortf b sort ndt name date time size checks
    host_root="$1"; out="$2"; sortf="/tmp/${SCRIPT_BASENAME}.backup-sorted.$$"
    : > "$out"; : > "$sortf"; [ -d "$host_root" ] || { rm -f "$sortf"; return; }
    find "$host_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r b; do
        [ -f "$b/$ARCHIVE_NAME" ] || continue
        sort=$(backup_sort_key "$b"); ndt=$(backup_name_date_time "$b"); name=$(echo "$ndt"|cut -d'|' -f1); date=$(echo "$ndt"|cut -d'|' -f2); time=$(echo "$ndt"|cut -d'|' -f3); size=$(du -h "$b/$ARCHIVE_NAME" 2>/dev/null|awk '{print $1}'); checks=$(backup_checksums_state "$b"); [ -n "$size" ] || size=unknown
        echo "$sort|$b|$name|$date|$time|$size|$checks" >> "$sortf"
    done
    [ -s "$sortf" ] && sort -t'|' -k1,1r -k2,2r "$sortf" | cut -d'|' -f2- > "$out"
    rm -f "$sortf"
}

gather_host_candidates() {
    local root out sortf tmp cur h key safe hf cnt latest date time pref psort
    root="$1"; out="$2"; sortf="/tmp/${SCRIPT_BASENAME}.host-sorted.$$"; tmp="/tmp/${SCRIPT_BASENAME}.hosts.$$"; cur=$(current_hostname)
    : > "$out"; : > "$sortf"; rm -rf "$tmp"; mkdir -p "$tmp"
    [ -d "$root" ] || { rm -rf "$tmp"; rm -f "$sortf"; return; }
    find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r h; do
        key=$(basename "$h"); safe=$(sanitize_path_component "$key"); hf="$tmp/$safe.backups"; gather_backup_candidates "$h" "$hf"; [ -s "$hf" ] || continue
        cnt=$(wc -l < "$hf" | tr -d ' '); latest=$(sed -n '1p' "$hf"); date=$(echo "$latest"|cut -d'|' -f3); time=$(echo "$latest"|cut -d'|' -f4); pref=0; psort=1; [ "$key" = "$cur" ] && { pref=1; psort=0; }
        echo "$psort|$key|$h|$key|$cnt|$date|$time|$pref" >> "$sortf"
    done
    [ -s "$sortf" ] && sort -t'|' -k1,1n -k2,2 "$sortf" | cut -d'|' -f3- > "$out"
    rm -rf "$tmp"; rm -f "$sortf"
}

list_backups_interactive() {
    local root hostf backupf
    root=$(normalize_backup_root_path "$BACKUP_ROOT"); BACKUP_ROOT="$root"; hostf="/tmp/${SCRIPT_BASENAME}.host-candidates.$$"; backupf="/tmp/${SCRIPT_BASENAME}.backup-candidates.$$"
    gather_host_candidates "$root" "$hostf"
    [ -s "$hostf" ] || { rm -f "$hostf" "$backupf"; die "No backups found in $root. Expected layout: $root/<hostname>/<backup_dir>"; }
    select_menu_line host "Hostname groups in: $BACKUP_ROOT" "$hostf" || { rm -f "$hostf" "$backupf"; return 0; }
    SELECTED_HOST_DIR=$(echo "$SELECTED_LINE" | cut -d'|' -f1)
    rm -f "$hostf"
    [ -n "$SELECTED_HOST_DIR" ] || { rm -f "$backupf"; return 0; }
    gather_backup_candidates "$SELECTED_HOST_DIR" "$backupf"
    [ -s "$backupf" ] || { rm -f "$backupf"; die "No restorable backups found in $SELECTED_HOST_DIR"; }
    select_menu_line backup "Backups for hostname: $(basename "$SELECTED_HOST_DIR")" "$backupf" || { rm -f "$backupf"; return 0; }
    SELECTED_BACKUP_DIR=$(echo "$SELECTED_LINE" | cut -d'|' -f1)
    rm -f "$backupf"
    [ -n "$SELECTED_BACKUP_DIR" ] && handle_selected_backup "$SELECTED_BACKUP_DIR"
}

print_backup_identity_lines() { local b h model desc created; b="$1"; h=$(backup_identity_value "$b" hostname || true); model=$(backup_identity_value "$b" model || true); desc=$(backup_identity_value "$b" openwrt_description || true); created=$(backup_identity_value "$b" backup_created || true); [ -n "$h" ] && echo "  Source hostname: $h"; [ -n "$model" ] && echo "  Source model:    $model"; [ -n "$desc" ] && echo "  OpenWrt:         $desc"; [ -n "$created" ] && echo "  Created:         $created"; }
handle_selected_backup() {
    local b af action
    b="$1"; af="/tmp/${SCRIPT_BASENAME}.actions.$$"
    echo "Selected backup: $b"; print_backup_identity_lines "$b"; [ -f "$b/$CHECKSUMS_NAME" ] || warn "This backup is missing $CHECKSUMS_NAME. Restore will fail until the file is restored."; echo
    { echo "restore|Restore selected backup"; echo "delete|Delete selected backup"; echo "cancel|Cancel"; } > "$af"
    select_menu_line action "Choose action for selected backup" "$af" || { rm -f "$af"; return 0; }
    action=$(echo "$SELECTED_LINE" | cut -d'|' -f1); rm -f "$af"
    case "$action" in
        restore) restore_backup "$b" "$DEFAULT_RESTORE_TARGET";;
        delete) ask_yes_no "Delete selected backup permanently? [y/N]" n || return 0; acquire_lock; rm -rf "$b"; rmdir "$(dirname "$b")" 2>/dev/null || true; echo "Backup deleted: $b";;
        *) echo "Cancelled.";;
    esac
}

storage_seen_contains() { [ -f "$1" ] && grep -Fx -- "$2" "$1" >/dev/null 2>&1; }
storage_available_for() { local base; base="$1"; df -h "$base" 2>/dev/null | awk 'NR==2{print $4}'; }
add_storage_candidate() {
    local out seen root kind note parent avail
    out="$1"; seen="$2"; root=$(normalize_backup_root_path "$3"); kind="$4"; note="$5"
    [ -n "$root" ] || return 0
    storage_seen_contains "$seen" "$root" && return 0
    parent=$(dirname "$root")
    case "$parent" in /proc|/sys|/dev|/rom|/tmp|/run|/var|/var/*|/proc/*|/sys/*|/dev/*|/rom/*|/tmp/*|/run/*) return 0;; esac
    if [ "$kind" = existing ]; then [ -d "$root" ] || return 0; [ -w "$root" ] || return 0; else [ -d "$parent" ] || return 0; [ -w "$parent" ] || return 0; fi
    avail=$(storage_available_for "$parent"); [ -n "$avail" ] || avail=unknown
    echo "$root" >> "$seen"
    echo "$root|$root|$kind|$avail|$note" >> "$out"
}

gather_storage_candidates() {
    local out seen tmp cur base root mp
    out="$1"; seen="/tmp/${SCRIPT_BASENAME}.storage-seen.$$"; tmp="/tmp/${SCRIPT_BASENAME}.storage-tmp.$$"
    cur=$(normalize_backup_root_path "$BACKUP_ROOT")
    : > "$out"; : > "$seen"; : > "$tmp"

    if [ -d "$cur" ]; then add_storage_candidate "$out" "$seen" "$cur" existing current; fi

    for base in /mnt /overlay/share /overlay /root; do
        [ -d "$base" ] || continue
        find "$base" -maxdepth 3 -type d -name "$BACKUP_ROOT_DIRNAME" 2>/dev/null | while IFS= read -r root; do echo "$root" >> "$tmp"; done
    done
    sort -u "$tmp" 2>/dev/null | while IFS= read -r root; do add_storage_candidate "$out" "$seen" "$root" existing detected; done
    : > "$tmp"

    if [ ! -d "$cur" ]; then add_storage_candidate "$out" "$seen" "$(dirname "$cur")" create current; fi

    df -P 2>/dev/null | awk 'NR>1 {print $6}' | while IFS= read -r mp; do
        case "$mp" in /|/proc|/sys|/dev|/rom|/tmp|/run|/var|/boot|/boot/*|/proc/*|/sys/*|/dev/*|/rom/*|/tmp/*|/run/*) continue;; esac
        [ -d "$mp" ] || continue
        echo "$mp" >> "$tmp"
    done
    sort -u "$tmp" 2>/dev/null | while IFS= read -r base; do add_storage_candidate "$out" "$seen" "$base" create writable; done

    rm -f "$seen" "$tmp"
}

reconfigure_backup_root() {
    local cur sf root
    cur=$(normalize_backup_root_path "$BACKUP_ROOT"); sf="/tmp/${SCRIPT_BASENAME}.storage-candidates.$$"
    echo "Current backup root:"
    echo "  $cur"
    echo
    gather_storage_candidates "$sf"
    [ -s "$sf" ] || { rm -f "$sf"; die "No writable storage candidates found. Mount a disk or create a writable directory first."; }
    select_menu_line storage "Select backup storage. Existing $BACKUP_ROOT_DIRNAME folders are shown first; writable disks create one automatically." "$sf" || { rm -f "$sf"; echo "Backup root unchanged."; return 0; }
    root=$(echo "$SELECTED_LINE" | cut -d'|' -f1); rm -f "$sf"
    [ -n "$root" ] || { echo "Backup root unchanged."; return 0; }
    mkdir -p "$root" || die "Failed to create backup root: $root"
    [ -w "$root" ] || die "Backup root is not writable: $root"
    BACKUP_ROOT="$root"; write_config "$root"
    log "Saved config to $CONFIG_PATH"
    echo "New backup root: $BACKUP_ROOT"
}

rotate_old_backups() { local host f n b rest; host="$1"; f="/tmp/${SCRIPT_BASENAME}.rotate.$$"; n=0; [ "$RETENTION_COUNT" -eq 0 ] && return; gather_backup_candidates "$host" "$f"; while IFS='|' read -r b rest; do [ -n "$b" ] || continue; n=$((n+1)); [ "$n" -gt "$RETENTION_COUNT" ] && { rm -rf "$b"; echo "Rotated old backup: $b"; }; done < "$f"; rm -f "$f"; }
create_backup() {
    local root host target stage fs size
    [ -d /overlay/upper ] || die "Directory /overlay/upper is not available."
    require_commands tar sha256sum awk sed grep sort wc du date uname cp chmod dirname basename find rm df mkdir mv cat
    root=$(normalize_backup_root_path "${1:-$BACKUP_ROOT}"); host="$root/$(current_hostname)"; target="$host/$(current_backup_leaf_name)"; stage="$host/.${SCRIPT_BASENAME}.staging.$$"
    mkdir -p "$host"; fs=$(df -T "$root" 2>/dev/null|awk 'NR==2{print $2}' || true); case "$fs" in tmpfs|ramfs) [ "$ALLOW_RAM_BACKUP" = 1 ] || die "Backup root is on RAM filesystem ($fs). Use --allow-ram to override.";; esac
    [ ! -e "$target" ] || die "Backup directory already exists: $target"
    echo "Backup preflight:"; echo "  Source:      /overlay/upper"; echo "  Root:        $root"; echo "  Destination: $target"; echo "  Compressor:  $COMPRESSOR_MODE"; echo "  Retention:   $RETENTION_COUNT per hostname"; echo
    mkdir -p "$stage"; trap 'rm -rf "$stage"; release_lock' EXIT INT TERM HUP
    log "Writing package list"; write_package_list "$stage"; log "Writing metadata"; write_metadata "$stage" "$target"; log "Creating archive $ARCHIVE_NAME"; archive_create "$stage/$ARCHIVE_NAME"; log "Verifying archive integrity"; tar -tzf "$stage/$ARCHIVE_NAME" >/dev/null; log "Writing checksums"; write_checksums "$stage"; verify_checksums "$stage"; log "Finalizing backup directory"; mv "$stage" "$target"; trap 'release_lock' EXIT INT TERM HUP
    size=$(du -h "$target/$ARCHIVE_NAME"|awk '{print $1}'); echo; echo "Backup created successfully."; echo "Directory: $target"; echo "Archive:   $target/$ARCHIVE_NAME"; echo "Packages:  $target/$PACKAGE_LIST_NAME"; echo "Metadata:  $target/$METADATA_NAME"; echo "Checksums: $target/$CHECKSUMS_NAME"; echo "Size:      $size"; rotate_old_backups "$host"
}

validate_restore_inputs() { local b t; b="$1"; t=$(normalize_restore_target "${2:-$DEFAULT_RESTORE_TARGET}"); [ -d "$b" ] || die "Backup directory not found: $b"; [ -f "$b/$ARCHIVE_NAME" ] || die "Archive not found: $b/$ARCHIVE_NAME"; [ -d "$t" ] || die "Restore target not found: $t"; [ "$t" = / ] && die "Refusing to restore directly into /."; case "$t" in "$b"|"$b"/*) die "Restore target must not be inside the backup directory.";; esac; case "$b" in "$t"|"$t"/*) die "Restore target must not contain the backup directory.";; esac; }
confirm_restore() { local b t x; b="$1"; t="$2"; echo "Restore preflight:"; echo "  Backup: $b"; echo "  Target: $t"; print_backup_identity_lines "$b"; echo; echo "This will delete current contents of $t before extracting the backup."; echo; ask_yes_no "Continue restore? [y/N]" n || { echo "Restore cancelled."; return 1; }; x=$(prompt_value "Type RESTORE to confirm destructive restore" ""); [ "$x" = RESTORE ] || { echo "Restore cancelled."; return 1; }; }
wipe_restore_target_contents() { local t e; t="$1"; [ -d "$t" ] || die "Restore target not found: $t"; [ "$t" != / ] || die "Refusing to wipe / directly."; log "Clearing existing contents of $t"; for e in "$t"/* "$t"/.[!.]* "$t"/..?*; do [ -e "$e" ] || [ -L "$e" ] || continue; rm -rf "$e"; done; }
prompt_reboot_now() { echo; if ask_yes_no "Reboot now? [y/N]" n; then reboot; else echo "Reboot skipped. Reboot manually to use restored overlay."; fi; }
restore_backup() { local b t; b="$1"; t=$(normalize_restore_target "${2:-$DEFAULT_RESTORE_TARGET}"); require_commands tar sha256sum awk sed grep sort wc du date uname dirname basename find rm df mkdir cat; validate_restore_inputs "$b" "$t"; verify_checksums "$b"; confirm_restore "$b" "$t" || return 0; acquire_lock; wipe_restore_target_contents "$t"; log "Extracting $ARCHIVE_NAME into $t"; tar -xzf "$b/$ARCHIVE_NAME" -C "$t"; echo; echo "Overlay restore completed."; [ "$t" = "$DEFAULT_RESTORE_TARGET" ] && prompt_reboot_now || echo "Test restore target populated successfully. No reboot required."; }

main() {
    setup_colors
    while [ $# -gt 0 ]; do case "$1" in --pigz) COMPRESSOR_MODE=pigz; shift;; --gzip) COMPRESSOR_MODE=gzip; shift;; --allow-ram) ALLOW_RAM_BACKUP=1; shift;; -remove|--remove) REMOVE_INSTALLATION=1; shift;; *) break;; esac; done
    require_root; validate_settings
    if [ "$REMOVE_INSTALLATION" = 1 ]; then [ $# -eq 0 ] || die "-remove does not accept additional arguments."; remove_installed_artifacts; exit 0; fi
    self_update_if_enabled "$@"; BACKUP_ROOT=$(normalize_backup_root_path "$BACKUP_ROOT")
    if ! is_installed_invocation; then case "${1:-}" in -h|--help|help) usage; exit 0;; *) install_self; [ $# -gt 0 ] && exec "$SHORTCUT_PATH" "$@"; exit 0;; esac; fi
    [ $# -gt 0 ] || { usage; exit 1; }
    local cmd
    cmd="$1"; shift
    case "$cmd" in
        backup) [ $# -le 1 ] || die "backup accepts at most one argument."; acquire_lock; create_backup "${1:-$BACKUP_ROOT}";;
        restore) [ $# -le 2 ] || die "restore accepts at most two arguments."; if [ $# -eq 0 ]; then echo "Restore without arguments opens the safe backup selector."; echo "No backup is restored until you select one and confirm explicitly."; echo; list_backups_interactive; else restore_backup "$1" "${2:-$DEFAULT_RESTORE_TARGET}"; fi;;
        list) [ $# -eq 0 ] || die "list does not accept arguments."; list_backups_interactive;;
        place) [ $# -eq 0 ] || die "place does not accept arguments."; reconfigure_backup_root;;
        -h|--help|help) usage;;
        *) die "Unknown command: $cmd";;
    esac
}
main "$@"
