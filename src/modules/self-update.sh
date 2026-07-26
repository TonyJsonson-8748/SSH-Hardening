# ══════════════════════════════════════════════════════════
#  脚本自我管理模块
# ══════════════════════════════════════════════════════════

SCRIPT_URL="https://raw.githubusercontent.com/TonyJsonson-8748/SSH-Hardening/refs/heads/main/SSH-Hardening.sh"
CHECKSUM_URL="https://raw.githubusercontent.com/TonyJsonson-8748/SSH-Hardening/refs/heads/main/SSH-Hardening.sh.sha256"
MANIFEST_URL="https://raw.githubusercontent.com/TonyJsonson-8748/SSH-Hardening/refs/heads/main/SSH-Hardening.manifest.json"
GITHUB_REF_URL="https://api.github.com/repos/TonyJsonson-8748/SSH-Hardening/git/ref/heads/main"
LOCAL_BIN_DIR="${LOCAL_BIN_DIR:-/usr/local/bin}"
LOCAL_SCRIPT="${LOCAL_SCRIPT:-${LOCAL_BIN_DIR}/vps-tools}"
UPDATE_NOTICE_FILE="${UPDATE_NOTICE_FILE:-${VPS_DATA_DIR}/update_available}"

file_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
    else return 1
    fi
}

if ! declare -F archive_gzip_decompress_bounded >/dev/null 2>&1; then
archive_gzip_decompress_bounded() {
    local INPUT="$1" OUTPUT="$2" MAX_COMPRESSED="$3" MAX_RAW="$4"
    local COMPRESSED_SIZE RAW_SIZE
    [[ "$MAX_COMPRESSED" =~ ^[1-9][0-9]*$ ]] \
        && [[ "$MAX_RAW" =~ ^[1-9][0-9]*$ ]] || return 1
    COMPRESSED_SIZE=$(stat -c '%s' "$INPUT" 2>/dev/null) || return 1
    [[ "$COMPRESSED_SIZE" =~ ^[0-9]+$ ]] \
        && [ "$COMPRESSED_SIZE" -le "$MAX_COMPRESSED" ] || return 1
    if ! command -v gzip >/dev/null 2>&1 \
        || ! command -v head >/dev/null 2>&1 \
        || ! (set -o pipefail; gzip -dc < "$INPUT" 2>/dev/null \
            | head -c "$((MAX_RAW + 1))" > "$OUTPUT"); then
        rm -f "$OUTPUT"
        return 1
    fi
    RAW_SIZE=$(stat -c '%s' "$OUTPUT" 2>/dev/null) || {
        rm -f "$OUTPUT"
        return 1
    }
    [[ "$RAW_SIZE" =~ ^[0-9]+$ ]] && [ "$RAW_SIZE" -le "$MAX_RAW" ] || {
        rm -f "$OUTPUT"
        return 1
    }
}
fi

self_atomic_replace() {
    local SOURCE="$1" DEST="$2" INSTALL_TMP
    mkdir -p "$(dirname "$DEST")" || return 1
    INSTALL_TMP=$(mktemp "$(dirname "$DEST")/.vps-tools.update.XXXXXX") || return 1
    if ! install -m 755 "$SOURCE" "$INSTALL_TMP" || ! mv -f "$INSTALL_TMP" "$DEST"; then
        rm -f "$INSTALL_TMP"
        return 1
    fi
}

self_script_valid() {
    local FILE="$1"
    [ -f "$FILE" ] && [ -r "$FILE" ] || return 1
    bash -n "$FILE" >/dev/null 2>&1 || return 1
    grep -qE '^APP_VERSION="V[0-9]+\.[0-9]+(\.[0-9]+)?"' "$FILE" 2>/dev/null
}

self_resolve_script_source() {
    local CANDIDATE="${1:-$0}" RESOLVED
    case "$CANDIDATE" in
        -|/dev/fd/*|/dev/stdin|/proc/*/fd/*) return 1 ;;
    esac
    RESOLVED=$(readlink -f "$CANDIDATE" 2>/dev/null) || return 1
    case "$RESOLVED" in
        /dev/fd/*|/dev/stdin|/proc/*/fd/*) return 1 ;;
    esac
    self_script_valid "$RESOLVED" || return 1
    printf '%s\n' "$RESOLVED"
}

self_fetch_script() {
    local DEST="$1" REMOTE_SHA FETCH_URL
    REMOTE_SHA=$(self_remote_main_sha || true)
    if [ -n "$REMOTE_SHA" ]; then
        FETCH_URL="https://raw.githubusercontent.com/TonyJsonson-8748/SSH-Hardening/${REMOTE_SHA}/SSH-Hardening.sh"
    else
        FETCH_URL="${SCRIPT_URL}?ts=$(date +%s)"
    fi
    curl -fsSL --retry 2 --retry-delay 1 \
        -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
        "$FETCH_URL" -o "$DEST" 2>/dev/null || return 1
    self_script_valid "$DEST"
}

self_local_runner_path_lexical_valid() {
    local TARGET="${1:-${LOCAL_SCRIPT:-}}" EXPECTED
    [ -n "${LOCAL_BIN_DIR:-}" ] && [ -n "$TARGET" ] || return 1
    case "$LOCAL_BIN_DIR" in
        /*) ;;
        *) return 1 ;;
    esac
    case "$LOCAL_BIN_DIR" in
        /|*/|*//*|*/../*|*/..|*/./*|*/.) return 1 ;;
    esac
    case "$LOCAL_BIN_DIR" in
        *[!A-Za-z0-9_./-]*) return 1 ;;
    esac
    EXPECTED="${LOCAL_BIN_DIR%/}/vps-tools"
    [ "$TARGET" = "$EXPECTED" ]
}

self_path_component_safe() {
    local PATH_COMPONENT="$1" IS_FINAL="${2:-no}" OWNER MODE PERMS EUID_NOW
    [ -d "$PATH_COMPONENT" ] && [ ! -L "$PATH_COMPONENT" ] || return 1
    read -r OWNER MODE < <(stat -c '%u %a' "$PATH_COMPONENT" 2>/dev/null) || return 1
    EUID_NOW=$(id -u 2>/dev/null) || return 1
    [ "$OWNER" = 0 ] || [ "$OWNER" = "$EUID_NOW" ] || return 1
    PERMS=$((8#$MODE))
    if [ $((PERMS & 0022)) -ne 0 ]; then
        [ "$IS_FINAL" != yes ] || return 1
        # A root/current-user owned sticky directory (normally /tmp) cannot
        # have another user's entries renamed and is safe as an ancestor.
        [ $((PERMS & 1000)) -ne 0 ] || return 1
    fi
}

self_local_runner_parent_safe() {
    local ALLOW_MISSING="${1:-no}" REMAINDER COMPONENT CURRENT="/"
    self_local_runner_path_lexical_valid || return 1
    REMAINDER="${LOCAL_BIN_DIR#/}"
    while [ -n "$REMAINDER" ]; do
        COMPONENT="${REMAINDER%%/*}"
        if [ "$REMAINDER" = "$COMPONENT" ]; then
            REMAINDER=""
        else
            REMAINDER="${REMAINDER#*/}"
        fi
        CURRENT="${CURRENT%/}/$COMPONENT"
        if [ ! -e "$CURRENT" ] && [ ! -L "$CURRENT" ]; then
            [ "$ALLOW_MISSING" = yes ] || return 1
            continue
        fi
        if [ -z "$REMAINDER" ]; then
            self_path_component_safe "$CURRENT" yes || return 1
        else
            self_path_component_safe "$CURRENT" no || return 1
        fi
    done
}

self_local_runner_path_valid() {
    local TARGET="${1:-${LOCAL_SCRIPT:-}}"
    self_local_runner_path_lexical_valid "$TARGET" || return 1
    self_local_runner_parent_safe no || return 1
    if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
        [ -f "$TARGET" ] && [ ! -L "$TARGET" ] || return 1
    fi
}

self_local_runner_prepare_target() {
    self_local_runner_path_lexical_valid || return 1
    self_local_runner_parent_safe yes || return 1
    mkdir -p "$LOCAL_BIN_DIR" 2>/dev/null || return 1
    self_local_runner_path_valid "$LOCAL_SCRIPT"
}

self_local_runner_restore() {
    local HAD_TARGET="$1" BACKUP="$2" DEST="$3"
    if [ "$HAD_TARGET" = yes ]; then
        [ -f "$BACKUP" ] && [ ! -L "$BACKUP" ] || return 1
        mv -f "$BACKUP" "$DEST" || return 1
        [ -f "$DEST" ] && [ ! -L "$DEST" ]
    else
        rm -f "$DEST" || return 1
        [ ! -e "$DEST" ] && [ ! -L "$DEST" ]
    fi
}

self_local_runner_install() {
    local SOURCE="$1" MODE="${2:-755}" REQUIRED_ENTRY="${3:-}"
    local BACKUP="" HAD_TARGET=no
    SELF_LOCAL_RUNNER_RECOVERY_BACKUP=""
    self_local_runner_prepare_target || return 1
    if [ -e "$LOCAL_SCRIPT" ] || [ -L "$LOCAL_SCRIPT" ]; then
        [ -f "$LOCAL_SCRIPT" ] && [ ! -L "$LOCAL_SCRIPT" ] || return 1
        BACKUP=$(mktemp "${LOCAL_BIN_DIR}/.vps-tools.backup.XXXXXX") || return 1
        if ! cp -p "$LOCAL_SCRIPT" "$BACKUP"; then
            rm -f "$BACKUP"
            return 1
        fi
        HAD_TARGET=yes
    fi
    if ! self_atomic_replace "$SOURCE" "$LOCAL_SCRIPT"; then
        [ -z "$BACKUP" ] || rm -f "$BACKUP"
        return 1
    fi
    if chmod "$MODE" "$LOCAL_SCRIPT" 2>/dev/null \
        && self_local_runner_path_valid "$LOCAL_SCRIPT" \
        && self_runner_file_valid "$LOCAL_SCRIPT" "$REQUIRED_ENTRY"; then
        [ -z "$BACKUP" ] || rm -f "$BACKUP"
        return 0
    fi
    if self_local_runner_restore "$HAD_TARGET" "$BACKUP" "$LOCAL_SCRIPT"; then
        [ -z "$BACKUP" ] || rm -f "$BACKUP"
        return 1
    fi
    SELF_LOCAL_RUNNER_RECOVERY_BACKUP="$BACKUP"
    return 2
}

self_runner_file_valid() {
    local FILE="$1" REQUIRED_ENTRY="${2:-}"
    self_script_valid "$FILE" || return 1
    [ -z "$REQUIRED_ENTRY" ] || grep -Fq -- "$REQUIRED_ENTRY" "$FILE" 2>/dev/null
}

# Ensure background jobs always point at a complete, executable local script.
# A directly executed trusted script is copied locally; stream execution falls
# back to the same verified fetch path used by the installer.
self_ensure_local_runner() {
    local REQUIRED_ENTRY="${1:-}" SOURCE="" DOWNLOAD_TMP="" INSTALL_RC
    self_local_runner_prepare_target || {
        error "本地脚本路径不适合后台任务：$LOCAL_SCRIPT"
        return 1
    }
    if self_runner_file_valid "$LOCAL_SCRIPT" "$REQUIRED_ENTRY"; then
        chmod 755 "$LOCAL_SCRIPT" 2>/dev/null || {
            error "无法设置后台任务脚本执行权限"
            return 1
        }
        return 0
    fi

    SOURCE=$(self_resolve_script_source "$0" 2>/dev/null || true)
    if [ -n "$SOURCE" ] && ! self_runner_file_valid "$SOURCE" "$REQUIRED_ENTRY"; then
        SOURCE=""
    fi
    if [ -z "$SOURCE" ]; then
        info "后台任务需要本地完整脚本，正在获取已校验版本..."
        DOWNLOAD_TMP=$(mktemp "${TMPDIR:-/tmp}/vps-tools-runner.XXXXXX") || {
            error "无法创建后台任务脚本临时文件"
            return 1
        }
        if ! self_fetch_script "$DOWNLOAD_TMP" \
            || ! self_runner_file_valid "$DOWNLOAD_TMP" "$REQUIRED_ENTRY"; then
            [ -z "$DOWNLOAD_TMP" ] || rm -f "$DOWNLOAD_TMP"
            error "无法获取包含所需后台入口的完整脚本"
            return 1
        fi
        SOURCE="$DOWNLOAD_TMP"
    fi

    if [ "$SOURCE" != "$LOCAL_SCRIPT" ]; then
        if self_local_runner_install "$SOURCE" 755 "$REQUIRED_ENTRY"; then
            :
        else
            INSTALL_RC=$?
            [ -z "$DOWNLOAD_TMP" ] || rm -f "$DOWNLOAD_TMP"
            if [ "$INSTALL_RC" -eq 2 ]; then
                error "后台任务脚本安装后校验失败，且原脚本恢复不完整${SELF_LOCAL_RUNNER_RECOVERY_BACKUP:+（备份：$SELF_LOCAL_RUNNER_RECOVERY_BACKUP）}"
            else
                error "无法安装后台任务执行脚本，原脚本未被替换"
            fi
            return 1
        fi
    fi
    [ -z "$DOWNLOAD_TMP" ] || rm -f "$DOWNLOAD_TMP"
    self_runner_file_valid "$LOCAL_SCRIPT" "$REQUIRED_ENTRY" || {
        error "后台任务执行脚本校验失败"
        return 1
    }
    chmod 755 "$LOCAL_SCRIPT" 2>/dev/null || {
        error "无法设置后台任务脚本执行权限"
        return 1
    }
}

self_shortcut_path() {
    printf '%s/%s\n' "$LOCAL_BIN_DIR" "$1"
}

self_shortcut_owned() {
    local TARGET LINK
    TARGET=$(self_shortcut_path "$1")
    [ -L "$TARGET" ] || return 1
    LINK=$(readlink "$TARGET" 2>/dev/null || true)
    [ "$LINK" = "$LOCAL_SCRIPT" ]
}

self_managed_script_file() {
    [ -f "$1" ] || return 1
    grep -qE 'VPS 开荒脚本|APP_UI_TITLE="VPS TOOLS"' "$1" 2>/dev/null
}

self_install_shortcut() {
    local CMD="$1" TARGET LINK
    TARGET=$(self_shortcut_path "$CMD")
    mkdir -p "$LOCAL_BIN_DIR" 2>/dev/null || return 1

    if self_shortcut_owned "$CMD"; then
        ln -sfn "$LOCAL_SCRIPT" "$TARGET" 2>/dev/null || return 1
        info "系统命令 ${CMD} 已创建 ✓"
        return 0
    fi

    if [ -L "$TARGET" ]; then
        LINK=$(readlink "$TARGET" 2>/dev/null || true)
        if [ ! -e "$TARGET" ]; then
            warn "快捷键 ${CMD} 指向失效路径（${LINK:-未知}），正在修复"
        elif self_managed_script_file "$TARGET"; then
            warn "快捷键 ${CMD} 指向旧版 VPS Tools，正在修复"
        else
            warn "快捷键 ${CMD} 已被其他脚本占用（${LINK:-未知}），跳过"
            return 0
        fi
    elif [ -e "$TARGET" ]; then
        if self_managed_script_file "$TARGET"; then
            warn "快捷键 ${CMD} 是旧版 VPS Tools 文件，正在替换为软链接"
        else
            warn "快捷键 ${CMD} 是独立文件（非软链接），跳过以避免覆盖"
            return 0
        fi
    fi

    ln -sfn "$LOCAL_SCRIPT" "$TARGET" 2>/dev/null || return 1
    info "系统命令 ${CMD} 已创建 ✓"
}

self_remove_shortcut() {
    local CMD="$1" TARGET
    TARGET=$(self_shortcut_path "$CMD")
    if self_shortcut_owned "$CMD" || self_managed_script_file "$TARGET"; then
        rm -f "$TARGET"
    fi
}

self_manifest_value() {
    local FILE="$1" KEY="$2"
    sed -n 's/.*"'$KEY'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$FILE" | head -1
}

self_remote_main_sha() {
    curl -fsSL --retry 2 --retry-delay 1 \
        -H 'Accept: application/vnd.github+json' \
        -H 'Cache-Control: no-cache' \
        -H 'Pragma: no-cache' \
        "$GITHUB_REF_URL" 2>/dev/null \
        | sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' \
        | head -1
}

# ── 安装脚本到本地（设置快捷键 v）────────────────────────
self_install() {
    print_header "安装脚本到本地"
    echo -e "  将脚本安装到 ${BOLD}${LOCAL_SCRIPT}${NC}"
    echo -e "  安装后输入 ${GREEN}v${NC} 或 ${GREEN}V${NC} 即可快速呼出"
    echo ""

    local SELF="" SOURCE="" DOWNLOAD_TMP="" INSTALL_RC
    self_local_runner_prepare_target || {
        error "安装目标必须严格为 LOCAL_BIN_DIR/vps-tools，且父目录和现有目标必须安全"
        return 1
    }
    SELF=$(self_resolve_script_source "$0" 2>/dev/null || true)
    if [ -n "$SELF" ]; then
        SOURCE="$SELF"
    else
        info "当前通过管道运行，正在下载完整脚本..."
        DOWNLOAD_TMP=$(mktemp "${TMPDIR:-/tmp}/vps-tools-install.XXXXXX") || {
            error "无法创建安装临时文件"; return 1
        }
        if self_fetch_script "$DOWNLOAD_TMP"; then
            SOURCE="$DOWNLOAD_TMP"
        else
            rm -f "$DOWNLOAD_TMP"
            error "无法获取完整脚本，请检查网络"
            return 1
        fi
    fi

    if [ "$SOURCE" != "$LOCAL_SCRIPT" ]; then
        if self_local_runner_install "$SOURCE" 755; then
            :
        else
            INSTALL_RC=$?
            rm -f "$DOWNLOAD_TMP"
            if [ "$INSTALL_RC" -eq 2 ]; then
                error "脚本安装后校验失败，且原文件恢复不完整${SELF_LOCAL_RUNNER_RECOVERY_BACKUP:+（备份：$SELF_LOCAL_RUNNER_RECOVERY_BACKUP）}"
            else
                error "脚本安装失败，原文件已保留/恢复"
            fi
            return 1
        fi
    fi
    rm -f "$DOWNLOAD_TMP"
    self_script_valid "$LOCAL_SCRIPT" || {
        error "安装后的脚本完整性校验失败"
        return 1
    }
    chmod 755 "$LOCAL_SCRIPT" || { error "无法设置脚本执行权限"; return 1; }
    info "脚本已安装到 ${LOCAL_SCRIPT} ✓"

    # 创建系统级命令 v / V（最可靠，无需 source）。
    for _CMD in v V; do
        self_install_shortcut "$_CMD" || warn "快捷键 ${_CMD} 创建失败"
    done

    echo ""
    menu_div
    info "安装完成！新终端直接输入 ${BOLD}v${NC} 即可启动"
    echo -e "  ${DIM}软链接已创建，无需 source，新终端直接可用${NC}"
    menu_div
}

# ── 强制从 GitHub 更新脚本 ────────────────────────────────
self_update() {
    print_header "强制更新脚本"
    echo -e "  ${DIM}${SCRIPT_URL}${NC}"
    echo ""

    local TMP_FILE CHECKSUM_FILE MANIFEST_FILE INSTALL_RC
    self_local_runner_prepare_target || {
        error "更新目标必须严格为 LOCAL_BIN_DIR/vps-tools，且父目录和现有目标必须安全"
        return 1
    }
    TMP_FILE=$(mktemp "${TMPDIR:-/tmp}/vps-update-script.XXXXXX") || {
        error "无法创建更新临时文件"
        return 1
    }
    CHECKSUM_FILE=$(mktemp "${TMPDIR:-/tmp}/vps-update-checksum.XXXXXX") || {
        rm -f "$TMP_FILE"
        error "无法创建更新校验临时文件"
        return 1
    }
    MANIFEST_FILE=$(mktemp "${TMPDIR:-/tmp}/vps-update-manifest.XXXXXX") || {
        rm -f "$TMP_FILE" "$CHECKSUM_FILE"
        error "无法创建更新清单临时文件"
        return 1
    }

    info "正在下载最新版本..."
    local TRY EXPECTED_HASH ACTUAL_HASH DOWNLOAD_OK SCRIPT_FETCH_URL CHECKSUM_FETCH_URL MANIFEST_FETCH_URL TS REMOTE_SHA
    DOWNLOAD_OK=0
    REMOTE_SHA=$(self_remote_main_sha || true)
    if [ -n "$REMOTE_SHA" ]; then
        info "已锁定 GitHub main commit：${REMOTE_SHA:0:12}"
    fi
    for TRY in 1 2 3 4 5; do
        EXPECTED_HASH="" ACTUAL_HASH=""
        TS=$(date +%s)
        case "$TRY" in
            1)
                if [ -n "$REMOTE_SHA" ]; then
                    SCRIPT_FETCH_URL="https://raw.githubusercontent.com/TonyJsonson-8748/SSH-Hardening/${REMOTE_SHA}/SSH-Hardening.sh"
                    CHECKSUM_FETCH_URL="https://raw.githubusercontent.com/TonyJsonson-8748/SSH-Hardening/${REMOTE_SHA}/SSH-Hardening.sh.sha256"
                    MANIFEST_FETCH_URL="https://raw.githubusercontent.com/TonyJsonson-8748/SSH-Hardening/${REMOTE_SHA}/SSH-Hardening.manifest.json"
                else
                    SCRIPT_FETCH_URL="$SCRIPT_URL"
                    CHECKSUM_FETCH_URL="$CHECKSUM_URL"
                    MANIFEST_FETCH_URL="$MANIFEST_URL"
                fi
                ;;
            2)
                SCRIPT_FETCH_URL="$SCRIPT_URL"
                CHECKSUM_FETCH_URL="$CHECKSUM_URL"
                MANIFEST_FETCH_URL="$MANIFEST_URL"
                ;;
            3)
                SCRIPT_FETCH_URL="$SCRIPT_URL?ts=$TS"
                CHECKSUM_FETCH_URL="$CHECKSUM_URL?ts=$TS"
                MANIFEST_FETCH_URL="$MANIFEST_URL?ts=$TS"
                ;;
            4)
                SCRIPT_FETCH_URL="https://github.com/TonyJsonson-8748/SSH-Hardening/raw/refs/heads/main/SSH-Hardening.sh"
                CHECKSUM_FETCH_URL="https://github.com/TonyJsonson-8748/SSH-Hardening/raw/refs/heads/main/SSH-Hardening.sh.sha256"
                MANIFEST_FETCH_URL="https://github.com/TonyJsonson-8748/SSH-Hardening/raw/refs/heads/main/SSH-Hardening.manifest.json"
                ;;
            *)
                SCRIPT_FETCH_URL="https://cdn.jsdelivr.net/gh/TonyJsonson-8748/SSH-Hardening@main/SSH-Hardening.sh"
                CHECKSUM_FETCH_URL="https://cdn.jsdelivr.net/gh/TonyJsonson-8748/SSH-Hardening@main/SSH-Hardening.sh.sha256"
                MANIFEST_FETCH_URL="https://cdn.jsdelivr.net/gh/TonyJsonson-8748/SSH-Hardening@main/SSH-Hardening.manifest.json"
                ;;
        esac
        : > "$TMP_FILE"
        : > "$CHECKSUM_FILE"
        : > "$MANIFEST_FILE"
        if curl -fsSL --retry 2 --retry-delay 1 -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
            "$SCRIPT_FETCH_URL" -o "$TMP_FILE" 2>/dev/null \
            && curl -fsSL --retry 2 --retry-delay 1 -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
            "$CHECKSUM_FETCH_URL" -o "$CHECKSUM_FILE" 2>/dev/null; then
            EXPECTED_HASH=$(awk 'NR==1 {print $1}' "$CHECKSUM_FILE")
            if curl -fsSL --retry 1 --retry-delay 1 -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
                "$MANIFEST_FETCH_URL" -o "$MANIFEST_FILE" 2>/dev/null; then
                local MANIFEST_HASH
                MANIFEST_HASH=$(self_manifest_value "$MANIFEST_FILE" sha256)
                [ -n "$MANIFEST_HASH" ] && EXPECTED_HASH="$MANIFEST_HASH"
            fi
            ACTUAL_HASH=$(file_sha256 "$TMP_FILE" 2>/dev/null || true)
            if [ -n "$ACTUAL_HASH" ] && [ "$ACTUAL_HASH" = "$EXPECTED_HASH" ]; then
                DOWNLOAD_OK=1
                break
            fi
        fi
        warn "下载或校验未通过，正在重试（${TRY}/5）"
        if [ -n "${ACTUAL_HASH:-}" ] || [ -n "${EXPECTED_HASH:-}" ]; then
            echo -e "  ${DIM}期望：${EXPECTED_HASH:-未知}  实际：${ACTUAL_HASH:-未知}${NC}"
        fi
        sleep 1
    done
    rm -f "$CHECKSUM_FILE" "$MANIFEST_FILE"
    if [ "$DOWNLOAD_OK" -ne 1 ]; then
        rm -f "$TMP_FILE"
        error "SHA256 校验失败，已拒绝更新"
        echo -e "  ${DIM}可先手动验证：curl -fsSL '${SCRIPT_URL}' -o /tmp/SSH-Hardening.sh && sha256sum /tmp/SSH-Hardening.sh${NC}"
        echo -e "  ${DIM}若 VPS 网络缓存异常，可临时手动覆盖：curl -fsSL '${SCRIPT_URL}' -o ${LOCAL_SCRIPT} && chmod +x ${LOCAL_SCRIPT}${NC}"
        audit_action "脚本更新SHA256校验失败" FAILED
        return 1
    fi
    info "SHA256 校验通过：${ACTUAL_HASH:0:16}..."

    # 验证语法
    if ! bash -n "$TMP_FILE" 2>/dev/null; then
        rm -f "$TMP_FILE"
        error "下载的文件语法有误，已取消更新"
        return 1
    fi

    # 版本对比
    local NEW_VER; NEW_VER=$(grep -oE 'V[0-9]+\.[0-9]+\.[0-9]+|V[0-9]+\.[0-9]+' "$TMP_FILE" | head -1)
    local CUR_VER; CUR_VER=$(grep -oE 'V[0-9]+\.[0-9]+\.[0-9]+|V[0-9]+\.[0-9]+' "${LOCAL_SCRIPT}" 2>/dev/null | head -1)
    echo -e "  当前版本：${BOLD}${CUR_VER:-未知}${NC}  →  最新版本：${GREEN}${BOLD}${NEW_VER:-未知}${NC}"
    echo ""

    # 覆盖前保留当前可执行版本
    if [ -f "$LOCAL_SCRIPT" ]; then
        mkdir -p "$VPS_VERSION_DIR" || { rm -f "$TMP_FILE"; error "无法创建版本备份目录"; return 1; }
        chmod 700 "$VPS_DATA_DIR" "$VPS_VERSION_DIR" 2>/dev/null || true
        local SAVED_VER
        SAVED_VER="${CUR_VER:-unknown}_$(date +%Y%m%d_%H%M%S).sh"
        cp "$LOCAL_SCRIPT" "$VPS_VERSION_DIR/$SAVED_VER" \
            && chmod 700 "$VPS_VERSION_DIR/$SAVED_VER" \
            || { rm -f "$TMP_FILE"; error "当前版本备份失败，已取消更新"; return 1; }
    fi
    # 同目录写入后原子替换，避免磁盘满或中断破坏当前脚本。
    if self_local_runner_install "$TMP_FILE" 755; then
        :
    else
        INSTALL_RC=$?
        rm -f "$TMP_FILE"
        if [ "$INSTALL_RC" -eq 2 ]; then
            error "更新后校验失败，且当前版本恢复不完整${SELF_LOCAL_RUNNER_RECOVERY_BACKUP:+（备份：$SELF_LOCAL_RUNNER_RECOVERY_BACKUP）}"
        else
            error "更新文件安装或校验失败，当前版本已保留/恢复"
        fi
        audit_action "脚本更新安装失败" FAILED
        return 1
    fi
    rm -f "$TMP_FILE"

    # 确保 v 命令还在
    self_install_shortcut v || warn "快捷键 v 修复失败"
    self_install_shortcut V || warn "快捷键 V 修复失败"

    info "更新完成 ✓"
    audit_action "脚本更新 ${CUR_VER:-未知} 到 ${NEW_VER:-未知}" SUCCESS
    # 清理 DDNS 日志，保留最后 500 行（避免文件过大）
    if [ -f /var/log/ddns.log ]; then
        local _LL; _LL=$(wc -l < /var/log/ddns.log 2>/dev/null || echo 0)
        if [ "$_LL" -gt 500 ]; then
            tail -n 500 /var/log/ddns.log > /var/log/ddns.log.tmp \
                && mv /var/log/ddns.log.tmp /var/log/ddns.log
            info "DDNS 日志已清理（保留最近 500 条）✓"
        fi
    fi
    # 清理旧版写入的 alias（旧版本会写 alias v=，会拦截其他命令如 volss）
    for RC in /root/.bashrc /root/.bash_profile ~/.bashrc ~/.bash_profile ~/.zshrc; do
        [ -f "$RC" ] || continue
        if grep -q "VPS 开荒脚本快捷键" "$RC" 2>/dev/null; then
            grep -v "alias v=\|alias V=\|VPS 开荒脚本快捷键" "$RC" > "${RC}.tmp" \
                && mv "${RC}.tmp" "$RC"
            info "已清理旧版 alias（${RC}）✓"
        fi
    done
    # 清除更新提示，避免新版本启动后还显示旧提示
    rm -f "$UPDATE_NOTICE_FILE" 2>/dev/null
    warn "即将用新版本重启脚本..."
    sleep 1
    exec "$LOCAL_SCRIPT"
}

# ── 回滚到更新前版本 ──────────────────────────────────────
self_rollback() {
    print_header "回滚脚本版本"
    local INSTALL_RC
    self_local_runner_prepare_target || {
        error "回滚目标必须严格为 LOCAL_BIN_DIR/vps-tools，且父目录和现有目标必须安全"
        return 1
    }
    mkdir -p "$VPS_VERSION_DIR"
    local FILES=() f i=1
    while IFS= read -r f; do FILES+=("$f"); done < <(find "$VPS_VERSION_DIR" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | sort -r)
    [ "${#FILES[@]}" -gt 0 ] || { warn "暂无可回滚版本"; return; }
    for f in "${FILES[@]}"; do echo -e "  ${GREEN}[$i]${NC} $(basename "$f")"; i=$((i+1)); done
    read -rp "  选择版本编号（回车取消）: " N
    [ -n "$N" ] || return
    echo "$N" | grep -qE '^[0-9]+$' || { warn "编号无效"; return; }
    [ "$N" -ge 1 ] && [ "$N" -le "${#FILES[@]}" ] || { warn "编号无效"; return; }
    local SELECTED="${FILES[$((N-1))]}"
    bash -n "$SELECTED" 2>/dev/null || { error "该版本语法校验失败"; return 1; }
    read -rp "  确认回滚到 $(basename "$SELECTED")？(y/N): " OK
    echo "$OK" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }
    [ -f "$LOCAL_SCRIPT" ] && cp "$LOCAL_SCRIPT" "$VPS_VERSION_DIR/before_rollback_$(date +%Y%m%d_%H%M%S).sh"
    if self_local_runner_install "$SELECTED" 700; then
        :
    else
        INSTALL_RC=$?
        if [ "$INSTALL_RC" -eq 2 ]; then
            error "版本回滚后校验失败，且原脚本恢复不完整${SELF_LOCAL_RUNNER_RECOVERY_BACKUP:+（备份：$SELF_LOCAL_RUNNER_RECOVERY_BACKUP）}"
        else
            error "版本回滚失败，原脚本已保留/恢复"
        fi
        return 1
    fi
    audit_action "脚本回滚到 $(basename "$SELECTED")" SUCCESS
    info "版本回滚完成"
    warn "即将用回滚版本重启脚本..."
    sleep 1
    exec "$LOCAL_SCRIPT"
}

self_offline_bundle_create() {
    print_header "离线安装包"
    local SRC TMPDIR BUNDLE ARCHIVE
    SRC="${LOCAL_SCRIPT:-}"
    self_script_valid "$SRC" 2>/dev/null \
        || SRC=$(self_resolve_script_source "$0" 2>/dev/null || true)
    self_script_valid "$SRC" 2>/dev/null \
        || { error "找不到完整且可校验的打包脚本"; return 1; }
    TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/vps-offline.XXXXXX") || return 1
    ARCHIVE="$TMPDIR/SSH-Hardening.sh"
    cp "$SRC" "$ARCHIVE" || { rm -rf "$TMPDIR"; error "复制脚本失败"; return 1; }
    self_script_valid "$ARCHIVE" 2>/dev/null || {
        rm -rf "$TMPDIR"
        error "暂存脚本完整性校验失败"
        return 1
    }
    if command -v sha256sum >/dev/null 2>&1; then
        if ! (cd "$TMPDIR" && sha256sum SSH-Hardening.sh > SSH-Hardening.sh.sha256); then
            rm -rf "$TMPDIR"
            error "生成离线包 SHA256 校验文件失败"
            return 1
        fi
    elif command -v shasum >/dev/null 2>&1; then
        if ! (cd "$TMPDIR" && shasum -a 256 SSH-Hardening.sh > SSH-Hardening.sh.sha256); then
            rm -rf "$TMPDIR"
            error "生成离线包 SHA256 校验文件失败"
            return 1
        fi
    else
        rm -rf "$TMPDIR"; error "缺少 SHA256 工具"; return 1
    fi
    BUNDLE="$VPS_DATA_DIR/offline/SSH-Hardening_offline_$(date +%Y%m%d_%H%M%S).tar.gz"
    mkdir -p "$VPS_DATA_DIR/offline" 2>/dev/null || { rm -rf "$TMPDIR"; error "无法创建离线包目录"; return 1; }
    tar -czf "$BUNDLE" -C "$TMPDIR" SSH-Hardening.sh SSH-Hardening.sh.sha256 || { rm -rf "$TMPDIR"; error "打包失败"; return 1; }
    rm -rf "$TMPDIR"
    chmod 600 "$BUNDLE" 2>/dev/null || true
    audit_action "生成离线安装包 $(basename "$BUNDLE")" SUCCESS
    info "离线安装包已生成：$BUNDLE"
    printf '%s\n' "$BUNDLE"
}

self_offline_archive_raw_types_valid() {
    local PACKAGE="$1" RAW="$2" OFFSET=0 TOTAL HEADER_NONZERO TAIL_NONZERO
    local TYPE_BYTE SIZE_TEXT SIZE BLOCKS FOUND_END=no
    local MAX_COMPRESSED="${SELF_OFFLINE_MAX_COMPRESSED_BYTES:-33554432}"
    local MAX_RAW="${SELF_OFFLINE_MAX_RAW_BYTES:-134217728}"
    if ! archive_gzip_decompress_bounded \
        "$PACKAGE" "$RAW" "$MAX_COMPRESSED" "$MAX_RAW"; then
        return 1
    fi
    TOTAL=$(stat -c '%s' "$RAW" 2>/dev/null) || return 1
    [[ "$TOTAL" =~ ^[0-9]+$ ]] && [ "$TOTAL" -ge 1024 ] \
        && [ $((TOTAL % 512)) -eq 0 ] || return 1
    while [ $((OFFSET + 512)) -le "$TOTAL" ]; do
        HEADER_NONZERO=$(dd if="$RAW" bs=512 skip=$((OFFSET / 512)) count=1 2>/dev/null \
            | od -An -tu1 \
            | awk '{for (i=1; i<=NF; i++) if ($i != 0) {print 1; exit}}')
        if [ -z "$HEADER_NONZERO" ]; then
            [ $((OFFSET + 1024)) -le "$TOTAL" ] || return 1
            TAIL_NONZERO=$(dd if="$RAW" bs=512 skip=$((OFFSET / 512)) 2>/dev/null \
                | od -An -tu1 \
                | awk '{for (i=1; i<=NF; i++) if ($i != 0) {print 1; exit}}')
            [ -z "$TAIL_NONZERO" ] || return 1
            FOUND_END=yes
            break
        fi
        TYPE_BYTE=$(dd if="$RAW" bs=1 skip=$((OFFSET + 156)) count=1 2>/dev/null \
            | od -An -tu1 | tr -d '[:space:]')
        SIZE_TEXT=$(dd if="$RAW" bs=1 skip=$((OFFSET + 124)) count=12 2>/dev/null \
            | tr -d '\000[:space:]')
        case "$TYPE_BYTE" in
            0|48|53) ;;
            *) return 1 ;;
        esac
        case "$SIZE_TEXT" in
            "") SIZE=0 ;;
            *[!0-7]*) return 1 ;;
            *) SIZE=$((8#$SIZE_TEXT)) ;;
        esac
        BLOCKS=$(((SIZE + 511) / 512))
        OFFSET=$((OFFSET + 512 + BLOCKS * 512))
        [ "$OFFSET" -le "$TOTAL" ] || return 1
    done
    [ "$FOUND_END" = yes ]
}

self_offline_archive_validate() {
    local PACKAGE="$1" MEMBER_LIST="$2" TYPE_LIST="$3" RAW_TAR="${TYPE_LIST}.raw"
    if ! self_offline_archive_raw_types_valid "$PACKAGE" "$RAW_TAR"; then
        rm -f "$RAW_TAR"
        return 1
    fi
    rm -f "$RAW_TAR"
    tar -tzf "$PACKAGE" > "$MEMBER_LIST" 2>/dev/null || return 1
    awk '
        {
            path=$0
            sub(/\r$/, "", path)
            original=path
            while (path ~ /^\.\//) sub(/^\.\//, "", path)
            sub(/\/+$/, "", path)
            if (original == "" || path == "" || path == ".") bad=1
            if (path ~ /^[/\\]/ || path ~ /^[[:alpha:]]:[/\\]/ \
                || path ~ /(^|[/\\])\.\.([/\\]|$)/ \
                || path ~ /(^|[/\\])\.([/\\]|$)/) bad=1
        }
        END { exit bad ? 1 : 0 }
    ' "$MEMBER_LIST" || return 1
    LC_ALL=C tar -tvzf "$PACKAGE" > "$TYPE_LIST" 2>/dev/null || return 1
    awk '
        NF {
            type=substr($1, 1, 1)
            if (type != "-" && type != "d") bad=1
        }
        END { exit bad ? 1 : 0 }
    ' "$TYPE_LIST"
}

self_offline_archive_extract() {
    local PACKAGE="$1" DEST="$2"
    if tar --version 2>/dev/null | grep -q 'GNU tar'; then
        tar --no-same-owner --no-same-permissions -xzf "$PACKAGE" -C "$DEST"
    else
        # BusyBox/OpenWrt tar may not implement --no-same-owner. This fallback
        # is used only after path, root metadata, and member-type validation.
        tar -xzf "$PACKAGE" -C "$DEST"
    fi
}

self_offline_bundle_install() {
    local PACKAGE="$1" TMPDIR FILE SHA_FILE EXPECTED ACTUAL DEST SRC_FILE
    local MEMBER_LIST TYPE_LIST STAGED_PACKAGE INSTALL_RC OLD_UMASK
    local LINK_COUNT UNSAFE_EXTRACTED_MEMBER=no PACKAGE_SIZE
    local MAX_PACKAGE_BYTES="${SELF_OFFLINE_MAX_COMPRESSED_BYTES:-33554432}"
    local -a CANDIDATES=()
    [ -f "$PACKAGE" ] || { error "离线包不存在"; return 1; }
    PACKAGE_SIZE=$(stat -c '%s' "$PACKAGE" 2>/dev/null) || {
        error "无法读取离线包大小"
        return 1
    }
    [[ "$MAX_PACKAGE_BYTES" =~ ^[1-9][0-9]*$ ]] \
        && [[ "$PACKAGE_SIZE" =~ ^[0-9]+$ ]] \
        && [ "$PACKAGE_SIZE" -le "$MAX_PACKAGE_BYTES" ] || {
        error "离线包超过安全大小上限"
        return 1
    }
    OLD_UMASK=$(umask)
    umask 077
    TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/vps-offline-install.XXXXXX")
    INSTALL_RC=$?
    umask "$OLD_UMASK"
    if [ "$INSTALL_RC" -ne 0 ] || [ -z "$TMPDIR" ]; then
        error "无法创建私有离线安装暂存目录"
        return 1
    fi
    chmod 700 "$TMPDIR" || {
        rm -rf "$TMPDIR"
        error "无法创建私有离线安装暂存目录"
        return 1
    }
    MEMBER_LIST="$TMPDIR/.archive-members"
    TYPE_LIST="$TMPDIR/.archive-types"
    case "$PACKAGE" in
        *.tar.gz|*.tgz)
            STAGED_PACKAGE="$TMPDIR/package.tar.gz"
            cp "$PACKAGE" "$STAGED_PACKAGE" || {
                rm -rf "$TMPDIR"
                error "无法复制离线归档到私有暂存目录"
                return 1
            }
            chmod 600 "$STAGED_PACKAGE" 2>/dev/null || {
                rm -rf "$TMPDIR"
                error "无法保护离线归档暂存副本"
                return 1
            }
            self_offline_archive_validate "$STAGED_PACKAGE" "$MEMBER_LIST" "$TYPE_LIST" || {
                rm -rf "$TMPDIR"
                error "离线包包含不安全路径、链接或无效归档成员"
                return 1
            }
            rm -f "$MEMBER_LIST" "$TYPE_LIST"
            self_offline_archive_extract "$STAGED_PACKAGE" "$TMPDIR" \
                || { rm -rf "$TMPDIR"; error "解包失败"; return 1; }
            rm -f "$STAGED_PACKAGE"
            while IFS= read -r -d '' FILE; do
                LINK_COUNT=$(stat -c '%h' "$FILE" 2>/dev/null || true)
                if [ "$LINK_COUNT" != 1 ]; then
                    UNSAFE_EXTRACTED_MEMBER=yes
                    break
                fi
            done < <(find "$TMPDIR" -mindepth 1 -type f -print0 2>/dev/null)
            if [ "$UNSAFE_EXTRACTED_MEMBER" = yes ] \
                || find "$TMPDIR" -mindepth 1 -type l -print -quit 2>/dev/null | grep -q .; then
                rm -rf "$TMPDIR"
                error "离线包解压后包含链接或无法唯一验证的文件"
                return 1
            fi
            while IFS= read -r -d '' FILE; do
                CANDIDATES+=("$FILE")
            done < <(
                find "$TMPDIR" -mindepth 1 -maxdepth 2 -type f \
                    \( -name 'SSH-Hardening.sh' -o -name 'vps-tools.sh' \) -print0
            )
            if [ "${#CANDIDATES[@]}" -ne 1 ]; then
                rm -rf "$TMPDIR"
                error "离线包必须且只能包含一个明确的 VPS Tools 脚本"
                return 1
            fi
            FILE="${CANDIDATES[0]}"
            SHA_FILE="${FILE}.sha256"
            [ -f "$SHA_FILE" ] || {
                rm -rf "$TMPDIR"
                error "离线包缺少与脚本同目录、同名的 SHA256 文件"
                return 1
            }
            EXPECTED=$(awk 'NR==1{print $1}' "$SHA_FILE" | tr '[:upper:]' '[:lower:]')
            if [ "${#EXPECTED}" -ne 64 ] \
                || ! printf '%s\n' "$EXPECTED" | grep -qE '^[0-9a-f]{64}$'; then
                rm -rf "$TMPDIR"
                error "离线包 SHA256 格式无效"
                return 1
            fi
            ACTUAL=$(file_sha256 "$FILE" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
            [ -n "$ACTUAL" ] && [ "$ACTUAL" = "$EXPECTED" ] || {
                rm -rf "$TMPDIR"
                error "离线包校验失败"
                return 1
            }
            SRC_FILE="$FILE"
            ;;
        *.sh)
            STAGED_PACKAGE="$TMPDIR/package.sh"
            cp "$PACKAGE" "$STAGED_PACKAGE" || {
                rm -rf "$TMPDIR"
                error "无法复制离线脚本到私有暂存目录"
                return 1
            }
            chmod 600 "$STAGED_PACKAGE" 2>/dev/null || {
                rm -rf "$TMPDIR"
                error "无法保护离线脚本暂存副本"
                return 1
            }
            SRC_FILE="$STAGED_PACKAGE"
            ;;
        *)
            rm -rf "$TMPDIR"
            error "仅支持 .sh / .tar.gz / .tgz 离线包"
            return 1
            ;;
    esac
    bash -n "$SRC_FILE" 2>/dev/null || {
        rm -rf "$TMPDIR"
        error "脚本语法校验失败"
        return 1
    }
    self_script_valid "$SRC_FILE" || {
        rm -rf "$TMPDIR"
        error "离线脚本缺少有效的 VPS Tools 版本标记"
        return 1
    }
    DEST="${LOCAL_SCRIPT:-/usr/local/bin/vps-tools}"
    self_local_runner_prepare_target || {
        rm -rf "$TMPDIR"
        error "离线安装目标必须严格为 LOCAL_BIN_DIR/vps-tools，且父目录和现有目标必须安全"
        return 1
    }
    if self_local_runner_install "$SRC_FILE" 700; then
        :
    else
        INSTALL_RC=$?
        rm -rf "$TMPDIR"
        if [ "$INSTALL_RC" -eq 2 ]; then
            error "安装后校验失败，且原脚本恢复不完整${SELF_LOCAL_RUNNER_RECOVERY_BACKUP:+（备份：$SELF_LOCAL_RUNNER_RECOVERY_BACKUP）}"
        else
            error "安装失败或安装后校验失败，原脚本已保留/恢复"
        fi
        return 1
    fi
    self_install_shortcut v || warn "快捷键 v 创建失败"
    self_install_shortcut V || warn "快捷键 V 创建失败"
    audit_action "离线安装脚本 $(basename "$PACKAGE")" SUCCESS
    info "离线安装完成：$DEST"
    rm -rf "$TMPDIR"
}

# ── 脚本管理菜单 ──────────────────────────────────────────
# ── 删除本地脚本和快捷键 ─────────────────────────────────
self_uninstall() {
    print_header "删除本地脚本和快捷键"
    self_local_runner_path_valid "$LOCAL_SCRIPT" || {
        error "卸载目标不是安全的 LOCAL_BIN_DIR/vps-tools，已拒绝删除"
        return 1
    }
    warn "将删除以下内容："
    echo -e "  ${DIM}${LOCAL_SCRIPT}${NC}"
    echo -e "  ${DIM}$(self_shortcut_path v)${NC}"
    echo -e "  ${DIM}$(self_shortcut_path V)${NC}"
    echo -e "  ${DIM}各 shell 配置文件中的 alias v=...${NC}"
    echo ""
    read -rp "  确认删除？(Y/n，默认Y): " CONFIRM
    [ -z "$CONFIRM" ] && CONFIRM="y"
    if ! echo "$CONFIRM" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    # 删除本地脚本
    rm -f "$LOCAL_SCRIPT" && info "已删除 ${LOCAL_SCRIPT} ✓"

    # 删除系统命令
    self_remove_shortcut v
    self_remove_shortcut V
    info "已删除 VPS Tools 管理的系统命令 v/V ✓"

    # 清理 shell 配置文件中可能残留的旧版 alias
    for RC in /root/.bashrc /root/.bash_profile ~/.bashrc ~/.bash_profile ~/.zshrc; do
        [ -f "$RC" ] || continue
        if grep -q "VPS 开荒脚本快捷键" "$RC" 2>/dev/null; then
            grep -v "alias v=\|alias V=\|VPS 开荒脚本快捷键" "$RC" > "${RC}.tmp" \
                && mv "${RC}.tmp" "$RC"
            info "已清理旧版 alias（${RC}）✓"
        fi
    done

    echo ""
    info "清理完成，快捷键 v 已移除"
    warn "当前会话仍可使用 alias，重新登录后完全生效"
    ui_pause
    return
}

# ── 首次运行检测是否已安装快捷键 ─────────────────────────
self_check_first_run() {
    # 已安装则跳过
    self_shortcut_owned v && return
    [ -f "$LOCAL_SCRIPT" ] && return

    print_header "首次运行设置"
    echo -e "  ${YELLOW}检测到脚本未安装到本地${NC}"
    echo -e "  安装后可随时输入 ${BOLD}v${NC} 快速启动"
    echo ""
    menu_div
    menu_item "1" "立即安装  ${DIM}推荐${NC}"
    menu_item "0" "跳过并进入主菜单" "$RED"
    menu_div
    echo ""
    read -rp "$(ui_prompt '选择操作 [0-1]: ')" CH
    case "$CH" in
        1)
            self_install
            ui_pause
            ;;
        *) ;;
    esac
}

self_manage_menu() {
    while true; do
        print_header "脚本管理"

        local IS_INSTALLED=false
        local CUR_VER=""
        if [ -f "$LOCAL_SCRIPT" ]; then
            IS_INSTALLED=true
            CUR_VER=$(grep -oE 'V[0-9]+\.[0-9]+\.[0-9]+|V[0-9]+\.[0-9]+' "$LOCAL_SCRIPT" | head -1)
        fi
        local HAS_CMD=false
        self_shortcut_owned v && HAS_CMD=true

        echo -e "  本地路径：${BOLD}${LOCAL_SCRIPT}${NC}"
        if [ "$IS_INSTALLED" = true ]; then
            echo -e "  状  态  ：${GREEN}${BOLD}已安装${NC}  版本：${BOLD}${CUR_VER:-未知}${NC}"
        else
            echo -e "  状  态  ：${YELLOW}${BOLD}未安装${NC}"
        fi
        echo -e "  快捷键 v：${BOLD}$([ "$HAS_CMD" = true ] && echo "${GREEN}已设置${NC}" || echo "${YELLOW}未设置${NC}")${NC}"
        echo ""
        menu_div
        menu_pair "1" "安装并设置快捷键" "2" "更新到最新版"
        menu_pair "3" "卸载本地脚本" "4" "回滚历史版本" "$YELLOW" "$YELLOW"
        menu_pair "5" "离线安装包" "0" "返回主菜单" "$CYAN" "$RED"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择操作 [0-5]: ')" CH

        case "$CH" in
            1) self_install ;;
            2) self_update ;;
            3) self_uninstall ;;
            4) self_rollback ;;
            5)
                while true; do
                    print_header "离线安装包"
                    menu_item "1" "生成离线安装包" "$GREEN"
                    menu_item "2" "安装本地离线包" "$YELLOW"
                    menu_item "0" "返回上级" "$RED"
                    menu_div; echo ""
                    read -rp "$(ui_prompt '选择操作 [0-2]: ')" OCH
                    case "$OCH" in
                        1) self_offline_bundle_create; ui_pause ;;
                        2)
                            local PKG
                            read -rp "$(ui_prompt '输入离线包路径 (.sh/.tar.gz): ')" PKG
                            [ -n "$PKG" ] && self_offline_bundle_install "$PKG"
                            ui_pause
                            ;;
                        0) break ;;
                        *) warn "无效选项"; sleep 1 ;;
                    esac
                done
                ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && [ "${CH}" != "3" ] && ui_pause
    done
}
