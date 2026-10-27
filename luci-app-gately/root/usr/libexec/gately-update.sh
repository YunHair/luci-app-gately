#!/bin/sh

UPDATE_DIR="/tmp/gately_update"
RUN_DIR="$UPDATE_DIR/.run_$$"
trap 'rm -rf "$RUN_DIR"' EXIT
STATUS_FILE="$UPDATE_DIR/status"
LOG_FILE="$UPDATE_DIR/log"
RELEASES_FILE="$UPDATE_DIR/releases.json"
AUTO_LOG="$UPDATE_DIR/autoupdate.log"

PROGRESS_FILE="$UPDATE_DIR/progress"
CHECKSUMS_FILE="$UPDATE_DIR/checksums.txt"

# Gately 仅在 GitHub 发布（官网 gately.cn 不提供 release 目录索引）
GITHUB_API="https://api.github.com/repos/wangwanjie/gately/releases"
DOWNLOAD_BASE="https://github.com/wangwanjie/gately/releases/download"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >&2
    [ -n "$LOG_TO_FILE" ] && echo "$msg" >> "$LOG_TO_FILE"
}

init_dir() {
    [ -d "$UPDATE_DIR" ] || mkdir -p "$UPDATE_DIR"
    mkdir -p "$RUN_DIR"
}

tag_to_ver() { echo "$1" | sed 's/^v//'; }

uci_get() {
    local v; v=$(uci -q get "gately.gately.$1" 2>/dev/null)
    echo "${v:-$2}"
}

write_status() {
    echo "$2" > "$STATUS_FILE"
}

die() {
    local code="$2" detail="${3:-$2}"
    log "ERROR: $detail"
    write_status "error:$code"
    exit 1
}

http_get() {
    local url="$1" out="$2" t="${3:-60}"
    curl -fsSL --connect-timeout 15 --max-time "$t" -o "$out" "$url"
}

http_get_var() {
    local url="$1" t="${2:-30}"
    curl -fsSL --connect-timeout 15 --max-time "$t" "$url" 2>/dev/null
}

# Gately 为 Go 架构命名，文件名形如 gately_<tag>_linux_<arch>.tar.gz
detect_arch() {
    local a; a=$(uci -q get gately.gately.arch 2>/dev/null)
    [ -n "$a" ] && [ "$a" != "auto" ] && echo "$a" && return
    case "$(uname -m)" in
        x86_64)        echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7*)        echo "arm" ;;
        armv8*)        echo "arm64" ;;
        riscv64)       echo "riscv64" ;;
        mips)          echo "mips" ;;
        mipsel|mipsle) echo "mipsle" ;;
        *)             echo "amd64" ;;
    esac
}

fmt_size() {
    local bytes="$1"
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ] 2>/dev/null; then
        echo "unknown"
        return
    fi
    awk -v b="$bytes" 'BEGIN{
        if(b>=1048576) printf "%.1fM", b/1048576
        else           printf "%.1fKB", b/1024
    }'
}

# 预发布后缀归一化：dev<alpha<beta<rc，输出 rank.num 便于 sort -V
pre_key() {
    local s="$1" word num rank
    word=$(printf '%s' "$s" | grep -oE '[a-zA-Z]+' | head -1)
    num=$(printf '%s' "$s" | grep -oE '[0-9]+' | head -1)
    num=${num:-0}
    case "$word" in
        dev)               rank=0 ;;
        alpha|a)           rank=1 ;;
        beta|b)            rank=2 ;;
        rc|c)              rank=3 ;;
        *)                 rank=0 ;;
    esac
    echo "${rank}.${num}"
}

# 语义化版本比较：返回 0 表示 $1 < $2
version_lt() {
    local a b
    a=$(echo "$1" | sed 's/^v//')
    b=$(echo "$2" | sed 's/^v//')
    [ "$a" = "$b" ] && return 1

    local ca cb pa pb
    ca="${a%%-*}"; [ "$ca" = "$a" ] && pa="" || pa="${a#*-}"
    cb="${b%%-*}"; [ "$cb" = "$b" ] && pb="" || pb="${b#*-}"

    # 比较数字核心（逐段，缺省补 0）
    local i n na nb va vb
    na=$(printf '%s' "$ca" | awk -F. '{print NF}')
    nb=$(printf '%s' "$cb" | awk -F. '{print NF}')
    n=$na; [ "$nb" -gt "$n" ] && n=$nb
    for i in $(seq 1 "$n"); do
        va=$(printf '%s' "$ca" | awk -F. -v i="$i" '{print $i}'); va=${va:-0}
        vb=$(printf '%s' "$cb" | awk -F. -v i="$i" '{print $i}'); vb=${vb:-0}
        [ "$va" -lt "$vb" ] && return 0
        [ "$va" -gt "$vb" ] && return 1
    done

    # 核心相同：正式版 > 预发布版
    if [ -z "$pa" ] && [ -n "$pb" ]; then return 1; fi
    if [ -n "$pa" ] && [ -z "$pb" ]; then return 0; fi
    [ -z "$pa" ] && [ -z "$pb" ] && return 1

    # 都为预发布：比较后缀
    local ka kb lo
    ka=$(pre_key "$pa"); kb=$(pre_key "$pb")
    [ "$ka" = "$kb" ] && return 1
    lo=$(printf '%s\n%s' "$ka" "$kb" | sort -V | head -1)
    [ "$lo" = "$ka" ]
}

get_installed_version() {
    uci -q get gately.gately.installed_version 2>/dev/null || echo ""
}

save_installed_version() {
    uci -q set gately.gately.installed_version="$1" 2>/dev/null
    uci -q commit gately 2>/dev/null
}

extract_url_from_releases() {
    local esc
    esc=$(printf '%s' "$2" | sed 's/\./\\./g')
    grep -o "\"name\":\"${esc}\",\"url\":\"[^\"]*\"" "$1" \
        | grep -o '"url":"[^"]*"' | cut -d'"' -f4 | head -1
}

# 从 release API JSON 中抽取关键行（按出现顺序）：tag_name、prerelease、linux 压缩包 URL
fetch_api_lines() {
    local raw="$1" out="$2"
    printf '%s' "$raw" \
        | grep -oE '"tag_name":[[:space:]]*"[^"]*"|"prerelease":[[:space:]]*(true|false)|https://github.com/wangwanjie/gately/releases/download/[^"]*_linux_[^"]*\.tar\.gz' \
        > "$out"
}

# 状态机解析为 releases JSON；release_type=prerelease 时才包含预发布版本
parse_release_lines() {
    local lines="$1" arch="$2" reltype="$3"
    local result=""
    local cur_tag="" cur_pre="false" files_json="" best_name="" best_url=""

    emit_release() {
        [ -n "$cur_tag" ] && [ -n "$files_json" ] || return 0
        if [ "$cur_pre" = "true" ] && [ "$reltype" != "prerelease" ]; then
            return 0
        fi
        result="${result:+$result,}{\"tag\":\"$cur_tag\",\"best\":\"$best_name\",\"best_url\":\"$best_url\",\"files\":[$files_json]}"
    }

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in
            '"tag_name"'*)
                emit_release
                cur_tag=$(printf '%s' "$line" | tr -d ' ' | cut -d'"' -f4)
                cur_pre="false"; files_json=""; best_name=""; best_url=""
                ;;
            '"prerelease"'*)
                case "$line" in *true*) cur_pre="true" ;; *) cur_pre="false" ;; esac
                ;;
            https://*)
                local fname="${line##*/}"
                [ -z "$fname" ] && continue
                echo "$files_json" | grep -q "\"$fname\"" && continue
                files_json="${files_json:+$files_json,}{\"name\":\"$fname\",\"url\":\"$line\"}"
                if [ -z "$best_name" ]; then
                    case "$fname" in
                        *_linux_${arch}.tar.gz) best_name="$fname"; best_url="$line" ;;
                    esac
                fi
                ;;
        esac
    done < "$lines"
    emit_release

    printf '%s' "$result"
}

build_releases() {
    local raw="$1" arch="$2" reltype="$3"
    local lf="$RUN_DIR/.api_lines"
    fetch_api_lines "$raw" "$lf"
    local r
    r=$(parse_release_lines "$lf" "$arch" "$reltype")
    rm -f "$lf"
    printf '[%s]\n' "$r"
}

check_releases_count() {
    local json="$1" count
    { [ -z "$json" ] || [ "$json" = "[]" ]; } && return 1
    count=$(printf '%s' "$json" | grep -o '"tag"' | wc -l | tr -d ' ')
    [ "$count" -gt 0 ] 2>/dev/null || return 1
    printf '%s' "$count"
}

# Gately 提供标准 sha256sum 格式的 checksums.txt：<hash>  <filename>
fetch_checksums() {
    local tag="$1"
    rm -f "$CHECKSUMS_FILE"
    http_get "${DOWNLOAD_BASE}/${tag}/checksums.txt" "$CHECKSUMS_FILE" 30 \
        && [ -s "$CHECKSUMS_FILE" ] \
        && { log "Got checksums.txt for $tag"; return 0; }
    rm -f "$CHECKSUMS_FILE"
    log "WARN: checksums.txt not available, verification will be skipped"
    return 0
}

verify_sha256() {
    local file="$1" checksums="$2" fname expected actual
    [ -s "$checksums" ] || return 0
    fname="${file##*/}"
    expected=$(awk -v f="$fname" '$2==f{print $1; exit}' "$checksums")
    if [ -z "$expected" ]; then
        log "WARN: no checksum entry for $fname, verification skipped"
        return 0
    fi
    actual=$(sha256sum "$file" | awk '{print $1}')
    log "Expected sha256: $expected"
    log "Computed sha256: $actual"
    if [ "$expected" = "$actual" ]; then
        log "SHA256 verified OK"
        return 0
    fi
    log "SHA256 verification failed"
    return 1
}

do_download() {
    local releases_file="$1" tag="$2" filename="$3"
    local progress
    local url
    url=$(extract_url_from_releases "$releases_file" "$filename")
    [ -z "$url" ] && die "url_not_found" "No download URL found for $filename"

    init_dir
    echo 0 > "$PROGRESS_FILE"
    write_status "downloading:$tag"
    log "Downloading: $filename"
    log "URL: $url"

    local f="$UPDATE_DIR/$filename"

    local total_size
    total_size=$(curl -sIL --connect-timeout 15 "$url" 2>/dev/null \
        | grep -i content-length | tail -1 | awk '{print $2}' | tr -d '\r')

    if [ -n "$total_size" ] && [ "$total_size" -gt 0 ] 2>/dev/null; then
        log "Total size: $(fmt_size "$total_size")"
        (
            while true; do
                sleep 1
                [ -f "$f" ] || continue
                downloaded=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
                [ "${downloaded:-0}" -gt 0 ] 2>/dev/null || continue
                pct=$(awk "BEGIN{printf \"%d\", $downloaded*100/$total_size}")
                echo "$pct" > "$PROGRESS_FILE"
                [ "$pct" -ge 100 ] && break
            done
        ) &
        local progress_pid=$!

        http_get "$url" "$f" 300
        local ret=$?
        kill "$progress_pid" 2>/dev/null
        wait "$progress_pid" 2>/dev/null
    else
        log "Total size: unknown"
        http_get "$url" "$f" 300
        local ret=$?
    fi
    echo 100 > "$PROGRESS_FILE"

    [ $ret -ne 0 ] && die "download_failed" "Download failed: $url"
    [ -s "$f" ]    || die "download_empty" "Downloaded file is empty"
    log "Download complete: $(fmt_size "$(wc -c < "$f" | tr -d ' ')")"

    fetch_checksums "$tag"
    verify_sha256 "$f" "$CHECKSUMS_FILE" \
        || die "checksum_failed" "SHA256 verification failed, file may be corrupted"
    echo "$f"
}

cmd_check() {
    local reltype="${1:-$(uci_get release_type stable)}"
    local arch="${2:-$(detect_arch)}"
    [ "$arch" = "auto" ] && arch=$(detect_arch)

    init_dir
    write_status "checking"
    log "Checking upstream versions (channel=$reltype arch=$arch)"

    local raw
    raw=$(http_get_var "$GITHUB_API?per_page=100")
    { [ -z "$raw" ] || ! printf '%s' "$raw" | grep -q '"tag_name"'; } \
        && die "check_failed" "GitHub API request failed or returned invalid data"

    local releases_json
    releases_json=$(build_releases "$raw" "$arch" "$reltype")

    local count; count=$(check_releases_count "$releases_json") \
        || die "no_releases" "No gately versions found"
    printf '%s\n' "$releases_json" > "$RELEASES_FILE"
    log "Found $count versions"
    write_status "ready:$count"
}

backup_config() {
    local configdir
    configdir=$(uci_get configdir "")
    { [ -z "$configdir" ] || [ ! -d "$configdir" ]; } && return 0
    local ver; ver=$(uci_get installed_version "")
    [ -z "$ver" ] && ver="unknown"
    local backup_file="$UPDATE_DIR/gately_${ver}_$(date +%Y%m%d%H%M%S).tar.gz"
    tar -czf "$backup_file" -C "$(dirname "$configdir")" "$(basename "$configdir")" 2>/dev/null
    log "Config backed up: $backup_file"
}

cmd_download() {
    local tag="$1" filename="$2" binpath="${3:-$(uci_get binpath /usr/bin/gately)}"
    [ -z "$tag" ]      && die "invalid_request" "download: missing tag"
    [ -z "$filename" ] && die "invalid_request" "download: missing filename"

    local dl
    dl=$(do_download "$RELEASES_FILE" "$tag" "$filename") || exit 1
    write_status "installing:$tag"

    local xdir="$UPDATE_DIR/extract"
    rm -rf "$xdir" && mkdir -p "$xdir"
    log "Extracting..."
    case "$filename" in
        *.tar.gz|*.tgz) tar -xzf "$dl" -C "$xdir" 2>/dev/null \
                             || die "extract_failed" "Extract failed: $filename" ;;
        *) die "unsupported_format" "Unsupported format: $filename" ;;
    esac

    local bin; bin=$(find "$xdir" -type f -name "gately" | head -1)
    [ -z "$bin" ] && die "binary_not_found" "Binary 'gately' not found in archive"
    log "Found binary: $bin"

    mkdir -p "$(dirname "$binpath")"
    backup_config
    log "Stopping service..."
    /etc/init.d/gately stop 2>/dev/null; sleep 1

    log "Installing to: $binpath"
    cp "$bin" "$binpath" && chmod 755 "$binpath" \
        || die "install_failed" "Failed to install to $binpath"
    rm -rf "$xdir" "$dl"

    log "Starting service..."
    /etc/init.d/gately start 2>/dev/null
    local ver; ver=$(tag_to_ver "$tag")
    save_installed_version "${ver:-$tag}"
    log "Installation complete: ${ver:-$tag}"
    write_status "done:${ver:-$tag}"
}

maybe_update() {
    local cur="$1" latest="$2" label="$3"
    if [ -n "$cur" ] && [ -n "$latest" ] && ! version_lt "$cur" "$latest"; then
        log "$label is up to date ($cur)"
        return 1
    fi
    return 0
}

cmd_auto() {
    local reltype arch binpath
    reltype=$(uci_get release_type stable)
    arch=$(detect_arch)
    binpath=$(uci_get binpath /usr/bin/gately)

    init_dir
    rm -f "$PROGRESS_FILE"
    write_status "checking"
    log "Auto update: channel=$reltype arch=$arch"

    local cur_ver=""
    if [ -x "$binpath" ]; then
        cur_ver=$(get_installed_version)
        log "Current gately: ${cur_ver:-unknown}"
    else
        log "Gately binary not found, will download and install it"
    fi

    cmd_check "$reltype" "$arch"
    [ -f "$RELEASES_FILE" ] || die "check_failed" "Failed to check upstream versions"

    local latest_tag best_file
    latest_tag=$(grep -o '"tag":"[^"]*"' "$RELEASES_FILE" | head -1 | cut -d'"' -f4)
    best_file=$(grep -o '"best":"[^"]*"' "$RELEASES_FILE" | head -1 | cut -d'"' -f4)
    [ -z "$latest_tag" ] && die "check_failed" "Cannot parse latest tag"
    [ -z "$best_file" ]  && die "check_failed" "Cannot parse best file"

    log "Latest: $latest_tag (current: ${cur_ver:-none})"

    local done_msg="ok"
    if maybe_update "$cur_ver" "$(tag_to_ver "$latest_tag")" "Gately"; then
        cmd_download "$latest_tag" "$best_file" "$binpath"
        done_msg=$(tag_to_ver "$latest_tag")
    fi

    write_status "done:${done_msg}"
    log "Auto update complete"
}

case "$1" in
    check)       init_dir; LOG_TO_FILE="$LOG_FILE"; : > "$LOG_FILE"; cmd_check "$2" "$3" ;;
    download)    init_dir; LOG_TO_FILE="$LOG_FILE"; : > "$LOG_FILE"; cmd_download "$2" "$3" "$4" ;;
    auto|"")     init_dir; LOG_TO_FILE="$AUTO_LOG"; : > "$AUTO_LOG"; cmd_auto ;;
    detect_arch) detect_arch ;;
    *)
        echo "Usage: $0 {check|download|auto|detect_arch}"
        exit 1 ;;
esac
