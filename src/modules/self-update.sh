# ══════════════════════════════════════════════════════════
#  脚本自我管理模块
# ══════════════════════════════════════════════════════════

SCRIPT_URL="https://raw.githubusercontent.com/chnnic/SSH-Hardening/refs/heads/main/SSH-Hardening.sh"
CHECKSUM_URL="https://raw.githubusercontent.com/chnnic/SSH-Hardening/refs/heads/main/SSH-Hardening.sh.sha256"
MANIFEST_URL="https://raw.githubusercontent.com/chnnic/SSH-Hardening/refs/heads/main/SSH-Hardening.manifest.json"
GITHUB_REF_URL="https://api.github.com/repos/chnnic/SSH-Hardening/git/ref/heads/main"
LOCAL_SCRIPT="/usr/local/bin/vps-tools"

file_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
    else return 1
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

    # 优先复制当前运行的脚本
    local SELF; SELF=$(readlink -f "${0}" 2>/dev/null || echo "${0}")

    if [ -f "$SELF" ] && [ "$SELF" != "$LOCAL_SCRIPT" ]; then
        cp "$SELF" "$LOCAL_SCRIPT"
    elif [ -f /tmp/ssh_hardening.sh ]; then
        cp /tmp/ssh_hardening.sh "$LOCAL_SCRIPT"
    else
        info "本地缓存不存在，从 GitHub 下载..."
        if ! curl -fsSL "$SCRIPT_URL" -o "$LOCAL_SCRIPT" 2>/dev/null; then
            error "下载失败，请检查网络"; return 1
        fi
    fi

    chmod +x "$LOCAL_SCRIPT"
    info "脚本已安装到 ${LOCAL_SCRIPT} ✓"

    # 创建系统级命令 v / V（最可靠，无需 source）
    # 检测 v/V 是否已被其他脚本占用
    for _CMD in v V; do
        local _TARGET="/usr/local/bin/${_CMD}"
        if [ -L "$_TARGET" ] && [ "$(readlink "$_TARGET")" != "$LOCAL_SCRIPT" ]; then
            warn "快捷键 ${_CMD} 已被其他脚本占用（$(readlink "$_TARGET")），跳过"
        elif [ -f "$_TARGET" ] && [ ! -L "$_TARGET" ]; then
            warn "快捷键 ${_CMD} 是独立文件（非软链接），跳过以避免覆盖"
        else
            ln -sf "$LOCAL_SCRIPT" "$_TARGET" 2>/dev/null && info "系统命令 ${_CMD} 已创建 ✓"
        fi
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

    local TMP_FILE CHECKSUM_FILE MANIFEST_FILE; TMP_FILE="/tmp/vps_update_$$.sh"; CHECKSUM_FILE="/tmp/vps_update_$$.sha256"; MANIFEST_FILE="/tmp/vps_update_$$.manifest.json"

    info "正在下载最新版本..."
    local TRY EXPECTED_HASH ACTUAL_HASH DOWNLOAD_OK SCRIPT_FETCH_URL CHECKSUM_FETCH_URL MANIFEST_FETCH_URL TS REMOTE_SHA
    DOWNLOAD_OK=0
    REMOTE_SHA=$(self_remote_main_sha || true)
    if [ -n "$REMOTE_SHA" ]; then
        info "已锁定 GitHub main commit：${REMOTE_SHA:0:12}"
    fi
    for TRY in 1 2 3 4 5; do
        TS=$(date +%s)
        case "$TRY" in
            1)
                if [ -n "$REMOTE_SHA" ]; then
                    SCRIPT_FETCH_URL="https://raw.githubusercontent.com/chnnic/SSH-Hardening/${REMOTE_SHA}/SSH-Hardening.sh"
                    CHECKSUM_FETCH_URL="https://raw.githubusercontent.com/chnnic/SSH-Hardening/${REMOTE_SHA}/SSH-Hardening.sh.sha256"
                    MANIFEST_FETCH_URL="https://raw.githubusercontent.com/chnnic/SSH-Hardening/${REMOTE_SHA}/SSH-Hardening.manifest.json"
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
                SCRIPT_FETCH_URL="https://github.com/chnnic/SSH-Hardening/raw/refs/heads/main/SSH-Hardening.sh"
                CHECKSUM_FETCH_URL="https://github.com/chnnic/SSH-Hardening/raw/refs/heads/main/SSH-Hardening.sh.sha256"
                MANIFEST_FETCH_URL="https://github.com/chnnic/SSH-Hardening/raw/refs/heads/main/SSH-Hardening.manifest.json"
                ;;
            *)
                SCRIPT_FETCH_URL="https://cdn.jsdelivr.net/gh/chnnic/SSH-Hardening@main/SSH-Hardening.sh"
                CHECKSUM_FETCH_URL="https://cdn.jsdelivr.net/gh/chnnic/SSH-Hardening@main/SSH-Hardening.sh.sha256"
                MANIFEST_FETCH_URL="https://cdn.jsdelivr.net/gh/chnnic/SSH-Hardening@main/SSH-Hardening.manifest.json"
                ;;
        esac
        rm -f "$TMP_FILE" "$CHECKSUM_FILE" "$MANIFEST_FILE"
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
        return
    fi
    info "SHA256 校验通过：${ACTUAL_HASH:0:16}..."

    # 验证语法
    if ! bash -n "$TMP_FILE" 2>/dev/null; then
        rm -f "$TMP_FILE"
        error "下载的文件语法有误，已取消更新"
        return
    fi

    # 版本对比
    local NEW_VER; NEW_VER=$(grep -oE 'V[0-9]+\.[0-9]+\.[0-9]+|V[0-9]+\.[0-9]+' "$TMP_FILE" | head -1)
    local CUR_VER; CUR_VER=$(grep -oE 'V[0-9]+\.[0-9]+\.[0-9]+|V[0-9]+\.[0-9]+' "${LOCAL_SCRIPT}" 2>/dev/null | head -1)
    echo -e "  当前版本：${BOLD}${CUR_VER:-未知}${NC}  →  最新版本：${GREEN}${BOLD}${NEW_VER:-未知}${NC}"
    echo ""

    # 覆盖前保留当前可执行版本
    if [ -f "$LOCAL_SCRIPT" ]; then
        mkdir -p "$VPS_VERSION_DIR"
        chmod 700 "$VPS_DATA_DIR" "$VPS_VERSION_DIR" 2>/dev/null || true
        local SAVED_VER
        SAVED_VER="${CUR_VER:-unknown}_$(date +%Y%m%d_%H%M%S).sh"
        cp "$LOCAL_SCRIPT" "$VPS_VERSION_DIR/$SAVED_VER"
        chmod 700 "$VPS_VERSION_DIR/$SAVED_VER"
    fi
    # 覆盖安装
    cp "$TMP_FILE" "$LOCAL_SCRIPT"
    chmod +x "$LOCAL_SCRIPT"
    cp "$TMP_FILE" /tmp/ssh_hardening.sh 2>/dev/null
    rm -f "$TMP_FILE"

    # 确保 v 命令还在
    ln -sf "$LOCAL_SCRIPT" /usr/local/bin/v 2>/dev/null
    ln -sf "$LOCAL_SCRIPT" /usr/local/bin/V 2>/dev/null

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
    rm -f /tmp/.vps_new_version 2>/dev/null
    warn "即将用新版本重启脚本..."
    sleep 1
    exec "$LOCAL_SCRIPT"
}

# ── 回滚到更新前版本 ──────────────────────────────────────
self_rollback() {
    print_header "回滚脚本版本"
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
    if ! cp "$SELECTED" "$LOCAL_SCRIPT" || ! chmod 700 "$LOCAL_SCRIPT"; then error "回滚失败"; return 1; fi
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
    [ -f "$SRC" ] || SRC=$(resolve_self_path)
    [ -f "$SRC" ] || { error "找不到可打包的脚本"; return 1; }
    TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/vps-offline.XXXXXX") || return 1
    ARCHIVE="$TMPDIR/SSH-Hardening.sh"
    cp "$SRC" "$ARCHIVE" || { rm -rf "$TMPDIR"; error "复制脚本失败"; return 1; }
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$ARCHIVE" > "$TMPDIR/SSH-Hardening.sh.sha256"
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$ARCHIVE" > "$TMPDIR/SSH-Hardening.sh.sha256"
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

self_offline_bundle_install() {
    local PACKAGE="$1" TMPDIR FILE SHA_FILE EXPECTED ACTUAL DEST SRC_FILE
    [ -f "$PACKAGE" ] || { error "离线包不存在"; return 1; }
    TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/vps-offline-install.XXXXXX") || return 1
    case "$PACKAGE" in
        *.tar.gz|*.tgz)
            tar -xzf "$PACKAGE" -C "$TMPDIR" || { rm -rf "$TMPDIR"; error "解包失败"; return 1; }
            FILE=$(find "$TMPDIR" -maxdepth 1 -type f \( -name 'SSH-Hardening.sh' -o -name 'vps-tools.sh' -o -name '*.sh' \) | head -1)
            [ -n "$FILE" ] || FILE=$(find "$TMPDIR" -maxdepth 1 -type f ! -name '*.sha256' | head -1)
            SHA_FILE=$(find "$TMPDIR" -maxdepth 1 -type f -name '*.sha256' | head -1)
            [ -n "$FILE" ] || { rm -rf "$TMPDIR"; error "离线包中没有脚本文件"; return 1; }
            if [ -n "$SHA_FILE" ]; then
                EXPECTED=$(awk 'NR==1{print $1}' "$SHA_FILE")
                ACTUAL=$(file_sha256 "$FILE" 2>/dev/null || true)
                [ -n "$ACTUAL" ] && [ "$ACTUAL" = "$EXPECTED" ] || { rm -rf "$TMPDIR"; error "离线包校验失败"; return 1; }
            fi
            SRC_FILE="$FILE"
            ;;
        *.sh)
            SRC_FILE="$PACKAGE"
            bash -n "$SRC_FILE" 2>/dev/null || { rm -rf "$TMPDIR"; error "脚本语法校验失败"; return 1; }
            ;;
        *)
            rm -rf "$TMPDIR"
            error "仅支持 .sh / .tar.gz / .tgz 离线包"
            return 1
            ;;
    esac
    DEST="${LOCAL_SCRIPT:-/usr/local/bin/vps-tools}"
    mkdir -p "$(dirname "$DEST")" 2>/dev/null || { rm -rf "$TMPDIR"; error "无法创建安装目录"; return 1; }
    cp "$SRC_FILE" "$DEST" || { rm -rf "$TMPDIR"; error "安装失败"; return 1; }
    chmod 700 "$DEST" 2>/dev/null || true
    ln -sf "$DEST" /usr/local/bin/v 2>/dev/null || true
    ln -sf "$DEST" /usr/local/bin/V 2>/dev/null || true
    audit_action "离线安装脚本 $(basename "$PACKAGE")" SUCCESS
    info "离线安装完成：$DEST"
    rm -rf "$TMPDIR"
}

# ── 脚本管理菜单 ──────────────────────────────────────────
# ── 删除本地脚本和快捷键 ─────────────────────────────────
self_uninstall() {
    print_header "删除本地脚本和快捷键"
    warn "将删除以下内容："
    echo -e "  ${DIM}${LOCAL_SCRIPT}${NC}"
    echo -e "  ${DIM}/usr/local/bin/v${NC}"
    echo -e "  ${DIM}/usr/local/bin/V${NC}"
    echo -e "  ${DIM}/usr/local/bin/V${NC}"
    echo -e "  ${DIM}各 shell 配置文件中的 alias v=...${NC}"
    echo ""
    read -rp "  确认删除？(Y/n，默认Y): " CONFIRM
    [ -z "$CONFIRM" ] && CONFIRM="y"
    if ! echo "$CONFIRM" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    # 删除本地脚本
    rm -f "$LOCAL_SCRIPT" && info "已删除 ${LOCAL_SCRIPT} ✓"

    # 删除系统命令
    rm -f /usr/local/bin/v /usr/local/bin/V && info "已删除系统命令 v/V ✓"

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
    [ -f /usr/local/bin/v ] && return
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
        [ -f /usr/local/bin/v ] && HAS_CMD=true

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
