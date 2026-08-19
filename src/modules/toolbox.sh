# ══════════════════════════════════════════════════════════
#  系统检查、备份与诊断工具箱
# ══════════════════════════════════════════════════════════

config_backup_allowed_roots() {
    local p
    for p in \
        etc/hostname etc/hosts \
        etc/ssh/sshd_config etc/ssh/sshd_config.d root/.ssh/authorized_keys \
        etc/fail2ban etc/ufw etc/firewalld etc/iptables/rules.v4 etc/iptables/rules.v6 etc/nftables.conf etc/nftables.d/vps-tools-nftpf.nft etc/nft-port-forward \
        etc/sysctl.conf etc/sysctl.d/99-vps-bbr.conf etc/sysctl.d/99-ipv6-disable.conf \
        etc/gai.conf etc/resolv.conf etc/systemd/resolved.conf etc/systemd/resolved.conf.d \
        etc/NetworkManager/conf.d etc/NetworkManager/system-connections etc/resolvconf/resolv.conf.d \
        etc/netplan etc/network/interfaces etc/network/interfaces.d etc/sysconfig/network-scripts \
        etc/systemd/network \
        etc/caddy root/ddns.sh root/.cf_token root/.hw_dns_aksk root/.cf_zone root/.cf_tg root/.cf_last_change \
        root/.cf_last_change_A root/.cf_last_change_AAAA root/.cf_last_status_A root/.cf_last_status_AAAA \
        root/.vps-monitor root/.vps-monitor.state root/.vps-monitor.history root/.vps-monitor.metrics \
        var/spool/cron/crontabs/root var/spool/cron/root etc/crontabs/root; do
        printf '%s\n' "$p"
    done
}

config_backup_root_is_directory() {
    case "$1" in
        etc/ssh/sshd_config.d|\
        etc/fail2ban|etc/ufw|etc/firewalld|\
        etc/systemd/resolved.conf.d|\
        etc/NetworkManager/conf.d|etc/NetworkManager/system-connections|\
        etc/resolvconf/resolv.conf.d|etc/netplan|etc/network/interfaces.d|\
        etc/sysconfig/network-scripts|etc/systemd/network|etc/caddy|etc/nft-port-forward)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

config_backup_paths() {
    local p
    while IFS= read -r p; do
        [ -e "/$p" ] || [ -L "/$p" ] || continue
        printf '%s\n' "$p"
    done < <(config_backup_allowed_roots)
}

config_archive_raw_types_valid() {
    local FILE="$1" RAW OFFSET=0 TOTAL HEADER_NONZERO TAIL_NONZERO
    local TYPE_BYTE SIZE_TEXT SIZE BLOCKS FOUND_END=no
    local MAX_COMPRESSED="${CONFIG_ARCHIVE_MAX_COMPRESSED_BYTES:-67108864}"
    local MAX_RAW="${CONFIG_ARCHIVE_MAX_RAW_BYTES:-268435456}"
    RAW=$(mktemp) || return 1
    if ! archive_gzip_decompress_bounded \
        "$FILE" "$RAW" "$MAX_COMPRESSED" "$MAX_RAW"; then
        rm -f "$RAW"
        return 1
    fi
    TOTAL=$(stat -c '%s' "$RAW" 2>/dev/null) || {
        rm -f "$RAW"
        return 1
    }
    [[ "$TOTAL" =~ ^[0-9]+$ ]] && [ "$TOTAL" -ge 1024 ] \
        && [ $((TOTAL % 512)) -eq 0 ] || {
        rm -f "$RAW"
        return 1
    }
    while [ $((OFFSET + 512)) -le "$TOTAL" ]; do
        HEADER_NONZERO=$(dd if="$RAW" bs=512 skip=$((OFFSET / 512)) count=1 2>/dev/null \
            | od -An -tu1 \
            | awk '{for (i=1; i<=NF; i++) if ($i != 0) {print 1; exit}}')
        if [ -z "$HEADER_NONZERO" ]; then
            # A valid tar stream ends with at least two zero records.  Reject a
            # single-zero pivot and any non-zero data after the end marker.
            [ $((OFFSET + 1024)) -le "$TOTAL" ] || {
                rm -f "$RAW"
                return 1
            }
            TAIL_NONZERO=$(dd if="$RAW" bs=512 skip=$((OFFSET / 512)) 2>/dev/null \
                | od -An -tu1 \
                | awk '{for (i=1; i<=NF; i++) if ($i != 0) {print 1; exit}}')
            [ -z "$TAIL_NONZERO" ] || {
                rm -f "$RAW"
                return 1
            }
            FOUND_END=yes
            break
        fi
        TYPE_BYTE=$(dd if="$RAW" bs=1 skip=$((OFFSET + 156)) count=1 2>/dev/null \
            | od -An -tu1 | tr -d '[:space:]')
        SIZE_TEXT=$(dd if="$RAW" bs=1 skip=$((OFFSET + 124)) count=12 2>/dev/null \
            | tr -d '\000[:space:]')
        case "$TYPE_BYTE" in
            0|48|50|53) ;;
            *) rm -f "$RAW"; return 1 ;;
        esac
        case "$SIZE_TEXT" in
            "") SIZE=0 ;;
            *[!0-7]*) rm -f "$RAW"; return 1 ;;
            *) SIZE=$((8#$SIZE_TEXT)) ;;
        esac
        BLOCKS=$(((SIZE + 511) / 512))
        OFFSET=$((OFFSET + 512 + BLOCKS * 512))
        [ "$OFFSET" -le "$TOTAL" ] || {
            rm -f "$RAW"
            return 1
        }
    done
    rm -f "$RAW"
    [ "$FOUND_END" = yes ]
}

config_archive_validate() {
    local FILE="$1" MEMBER ROOT OK ROOT_KIND DETAIL TYPE EXTRA LINK
    local MEMBER_LIST TYPE_LIST NORMALIZED_LIST LINK_LIST
    MEMBER_LIST=$(mktemp) || return 1
    TYPE_LIST=$(mktemp) || { rm -f "$MEMBER_LIST"; return 1; }
    NORMALIZED_LIST=$(mktemp) || { rm -f "$MEMBER_LIST" "$TYPE_LIST"; return 1; }
    LINK_LIST=$(mktemp) || {
        rm -f "$MEMBER_LIST" "$TYPE_LIST" "$NORMALIZED_LIST"
        return 1
    }
    if ! config_archive_raw_types_valid "$FILE" \
        || ! tar -tzf "$FILE" > "$MEMBER_LIST" 2>/dev/null \
        || ! LC_ALL=C tar -tvzf "$FILE" > "$TYPE_LIST" 2>/dev/null; then
        rm -f "$MEMBER_LIST" "$TYPE_LIST" "$NORMALIZED_LIST" "$LINK_LIST"
        error "备份文件损坏"
        return 1
    fi
    if [ ! -s "$MEMBER_LIST" ]; then
        rm -f "$MEMBER_LIST" "$TYPE_LIST" "$NORMALIZED_LIST" "$LINK_LIST"
        error "备份归档为空"
        return 1
    fi

    exec 7< "$MEMBER_LIST"
    exec 8< "$TYPE_LIST"
    while IFS= read -r MEMBER <&7; do
        if ! IFS= read -r DETAIL <&8; then
            exec 7<&- 8<&-
            rm -f "$MEMBER_LIST" "$TYPE_LIST" "$NORMALIZED_LIST" "$LINK_LIST"
            error "无法核对归档成员类型"
            return 1
        fi
        MEMBER=${MEMBER%$'\r'}
        while [ "${MEMBER#./}" != "$MEMBER" ]; do MEMBER=${MEMBER#./}; done
        MEMBER=${MEMBER%/}
        [ -n "$MEMBER" ] || {
            exec 7<&- 8<&-
            rm -f "$MEMBER_LIST" "$TYPE_LIST" "$NORMALIZED_LIST" "$LINK_LIST"
            error "归档包含不允许的根目录元数据"
            return 1
        }
        case "$MEMBER" in
            /*|\\*|*\\*|[A-Za-z]:/*|..|../*|*/../*|*/..|\
            *//*|*/./*|*/.|*/)
                exec 7<&- 8<&-
                rm -f "$MEMBER_LIST" "$TYPE_LIST" "$NORMALIZED_LIST" "$LINK_LIST"
                error "归档包含不安全路径：$MEMBER"
                return 1
                ;;
        esac

        OK=false
        # shellcheck disable=SC2209  # "file" is a literal ROOT_KIND state value, not the `file` command
        ROOT_KIND=file
        while IFS= read -r ROOT; do
            if config_backup_root_is_directory "$ROOT"; then
                case "$MEMBER" in
                    "$ROOT") OK=true; ROOT_KIND=directory-root; break ;;
                    "$ROOT"/*) OK=true; ROOT_KIND=directory-child; break ;;
                esac
            elif [ "$MEMBER" = "$ROOT" ]; then
                OK=true
                # shellcheck disable=SC2209  # "file" is a literal ROOT_KIND state value, not the `file` command
                ROOT_KIND=file
                break
            fi
        done < <(config_backup_allowed_roots)
        if [ "$OK" != true ]; then
            exec 7<&- 8<&-
            rm -f "$MEMBER_LIST" "$TYPE_LIST" "$NORMALIZED_LIST" "$LINK_LIST"
            error "归档包含非 VPS Tools 配置路径：$MEMBER"
            return 1
        fi

        TYPE=${DETAIL:0:1}
        case "$TYPE:$ROOT_KIND" in
            -:file|d:directory-root|-:directory-child|d:directory-child)
                ;;
            l:directory-child)
                printf '%s\n' "$MEMBER" >> "$LINK_LIST" || {
                    exec 7<&- 8<&-
                    rm -f "$MEMBER_LIST" "$TYPE_LIST" "$NORMALIZED_LIST" "$LINK_LIST"
                    return 1
                }
                ;;
            l:file)
                if [ "$MEMBER" != "etc/resolv.conf" ]; then
                    exec 7<&- 8<&-
                    rm -f "$MEMBER_LIST" "$TYPE_LIST" "$NORMALIZED_LIST" "$LINK_LIST"
                    error "归档中的配置文件类型不安全：$MEMBER"
                    return 1
                fi
                printf '%s\n' "$MEMBER" >> "$LINK_LIST" || {
                    exec 7<&- 8<&-
                    rm -f "$MEMBER_LIST" "$TYPE_LIST" "$NORMALIZED_LIST" "$LINK_LIST"
                    return 1
                }
                ;;
            *)
                exec 7<&- 8<&-
                rm -f "$MEMBER_LIST" "$TYPE_LIST" "$NORMALIZED_LIST" "$LINK_LIST"
                error "归档包含链接、设备或其他特殊成员：$MEMBER"
                return 1
                ;;
        esac
        printf '%s\n' "$MEMBER" >> "$NORMALIZED_LIST" || {
            exec 7<&- 8<&-
            rm -f "$MEMBER_LIST" "$TYPE_LIST" "$NORMALIZED_LIST" "$LINK_LIST"
            return 1
        }
    done
    if IFS= read -r EXTRA <&8; then
        exec 7<&- 8<&-
        rm -f "$MEMBER_LIST" "$TYPE_LIST" "$NORMALIZED_LIST" "$LINK_LIST"
        error "归档成员清单与类型清单不一致"
        return 1
    fi
    exec 7<&- 8<&-

    if [ "$(sort "$NORMALIZED_LIST" | uniq -d | wc -l | tr -d ' ')" -gt 0 ]; then
        rm -f "$MEMBER_LIST" "$TYPE_LIST" "$NORMALIZED_LIST" "$LINK_LIST"
        error "归档包含重复成员"
        return 1
    fi
    while IFS= read -r LINK; do
        [ -n "$LINK" ] || continue
        if awk -v link="$LINK" '$0 != link && index($0, link "/") == 1 {found=1} END {exit !found}' \
            "$NORMALIZED_LIST"; then
            rm -f "$MEMBER_LIST" "$TYPE_LIST" "$NORMALIZED_LIST" "$LINK_LIST"
            error "归档试图通过符号链接写入子路径：$LINK"
            return 1
        fi
    done < "$LINK_LIST"
    rm -f "$MEMBER_LIST" "$TYPE_LIST" "$NORMALIZED_LIST" "$LINK_LIST"
    return 0
}

config_path_identity() {
    stat -c '%d:%i' -- "$1" 2>/dev/null
}

config_roots_match() {
    local ROOT="$1" LEFT_ROOT="$2" RIGHT_ROOT="$3"
    local LEFT_TAR="" RIGHT_TAR="" RESULT=1
    LEFT_TAR=$(mktemp) || LEFT_TAR=""
    RIGHT_TAR=$(mktemp) || RIGHT_TAR=""
    if [ -n "$LEFT_TAR" ] && [ -n "$RIGHT_TAR" ] \
        && tar "${TAR_COMPARE_ARGS[@]}" -cf "$LEFT_TAR" \
            -C "$LEFT_ROOT" "$ROOT" 2>/dev/null \
        && tar "${TAR_COMPARE_ARGS[@]}" -cf "$RIGHT_TAR" \
            -C "$RIGHT_ROOT" "$ROOT" 2>/dev/null \
        && cmp -s "$LEFT_TAR" "$RIGHT_TAR"; then
        RESULT=0
    fi
    [ -z "$LEFT_TAR" ] || rm -f -- "$LEFT_TAR"
    [ -z "$RIGHT_TAR" ] || rm -f -- "$RIGHT_TAR"
    return "$RESULT"
}

config_archive_extract() {
    local FILE="$1" STAGE LINK REL TARGET ROOT SRC DEST OLD RESTORE_ROOT ENTRY META OWNER MODE EXPECTED_OWNER=0
    local NEW HAD_OLD INDEX=0 COMMITTED=0 COMMIT_FAILED=no TXN_ID
    local DEST_ID NEW_ID CURRENT_ID INSTALLED_ID
    local IMPORT_ROOTS="" TARGET_ROOTS="" TARGET_SNAPSHOT=""
    local CURRENT_TARGET_ROOTS="" CURRENT_TARGET_SNAPSHOT="" TAR_OPTION
    local ORIGINAL_STAGE="" VERIFY_STAGE="" VERIFY_PATH=""
    local ROLLBACK_FAILED=no CLEANUP_FAILED=no
    local -a RESTORE_ROOTS=() RESTORE_DESTS=() RESTORE_OLDS=() RESTORE_NEWS=()
    local -a RESTORE_HAD_OLD=() RESTORE_ORIGINAL_IDS=() RESTORE_NEW_IDS=()
    local -a RESTORE_INSTALLED=() RESTORE_INSTALLED_IDS=()
    local -a TAR_EXTRACT_ARGS=(-xzf "$FILE")
    local -a TAR_COMPARE_ARGS=()
    RESTORE_ROOT="${CONFIG_RESTORE_ROOT:-/}"
    if [ "${VPS_TOOLS_TEST_MODE:-0}" = 1 ]; then
        EXPECTED_OWNER=$(id -u 2>/dev/null || printf '0')
    fi
    STAGE=$(mktemp -d) || return 1
    TXN_ID=${STAGE##*/}
    if tar --help 2>&1 | grep -q -- '--no-same-owner'; then
        TAR_EXTRACT_ARGS+=(--no-same-owner)
    fi
    if tar --help 2>&1 | grep -q -- '--no-same-permissions'; then
        TAR_EXTRACT_ARGS+=(--no-same-permissions)
    fi
    TAR_EXTRACT_ARGS+=(-C "$STAGE")
    if ! tar "${TAR_EXTRACT_ARGS[@]}" 2>/dev/null; then
        rm -rf "$STAGE"
        error "导入包解压失败"
        return 1
    fi
    while IFS= read -r -d '' ENTRY; do
        META=$(stat -c '%u:%a' -- "$ENTRY" 2>/dev/null) || {
            rm -rf "$STAGE"
            error "无法核对归档成员权限"
            return 1
        }
        OWNER=${META%%:*}
        MODE=${META#*:}
        if [ "$OWNER" != "$EXPECTED_OWNER" ]; then
            rm -rf "$STAGE"
            error "归档成员不是 root 所有：${ENTRY#"$STAGE"/}"
            return 1
        fi
        if [ ! -L "$ENTRY" ]; then
            [[ "$MODE" =~ ^[0-7]+$ ]] || {
                rm -rf "$STAGE"
                error "归档成员权限无效：${ENTRY#"$STAGE"/}"
                return 1
            }
            if [ $((8#$MODE & 0022)) -ne 0 ]; then
                rm -rf "$STAGE"
                error "归档成员允许组或其他用户写入：${ENTRY#"$STAGE"/}"
                return 1
            fi
        fi
    done < <(find "$STAGE" -mindepth 1 -print0 2>/dev/null)
    while IFS= read -r LINK; do
        REL=${LINK#"$STAGE"/}
        TARGET=$(readlink "$LINK" 2>/dev/null || true)
        case "$TARGET" in
            /*)
                case "$REL:$TARGET" in
                    etc/resolv.conf:/run/systemd/resolve/*|etc/resolv.conf:/run/NetworkManager/*|etc/resolv.conf:/run/resolvconf/*) ;;
                    *) rm -rf "$STAGE"; error "归档包含不安全符号链接：$REL -> $TARGET"; return 1 ;;
                esac
                ;;
            ..|../*|*/../*|*/..)
                case "$REL:$TARGET" in
                    etc/resolv.conf:../run/systemd/resolve/*|etc/resolv.conf:../run/NetworkManager/*|etc/resolv.conf:../run/resolvconf/*) ;;
                    *) rm -rf "$STAGE"; error "归档包含越界符号链接：$REL -> $TARGET"; return 1 ;;
                esac
                ;;
        esac
    done < <(find "$STAGE" -type l 2>/dev/null)
    IMPORT_ROOTS=$(mktemp) || IMPORT_ROOTS=""
    TARGET_ROOTS=$(mktemp) || TARGET_ROOTS=""
    TARGET_SNAPSHOT=$(mktemp) || TARGET_SNAPSHOT=""
    CURRENT_TARGET_ROOTS=$(mktemp) || CURRENT_TARGET_ROOTS=""
    CURRENT_TARGET_SNAPSHOT=$(mktemp) || CURRENT_TARGET_SNAPSHOT=""
    if [ -z "$IMPORT_ROOTS" ] || [ -z "$TARGET_ROOTS" ] \
        || [ -z "$TARGET_SNAPSHOT" ] || [ -z "$CURRENT_TARGET_ROOTS" ] \
        || [ -z "$CURRENT_TARGET_SNAPSHOT" ]; then
        rm -f -- "$IMPORT_ROOTS" "$TARGET_ROOTS" "$TARGET_SNAPSHOT" \
            "$CURRENT_TARGET_ROOTS" "$CURRENT_TARGET_SNAPSHOT"
        rm -rf "$STAGE"
        error "无法创建配置导入事务快照"
        return 1
    fi
    : > "$IMPORT_ROOTS"
    : > "$TARGET_ROOTS"
    while IFS= read -r ROOT; do
        SRC="$STAGE/$ROOT"
        [ -e "$SRC" ] || [ -L "$SRC" ] || continue
        printf '%s\n' "$ROOT" >> "$IMPORT_ROOTS" || {
            rm -f -- "$IMPORT_ROOTS" "$TARGET_ROOTS" "$TARGET_SNAPSHOT" \
                "$CURRENT_TARGET_ROOTS" "$CURRENT_TARGET_SNAPSHOT"
            rm -rf "$STAGE"
            return 1
        }
        DEST="${RESTORE_ROOT%/}/$ROOT"
        if [ -e "$DEST" ] || [ -L "$DEST" ]; then
            printf '%s\n' "$ROOT" >> "$TARGET_ROOTS" || {
                rm -f -- "$IMPORT_ROOTS" "$TARGET_ROOTS" "$TARGET_SNAPSHOT" \
                    "$CURRENT_TARGET_ROOTS" "$CURRENT_TARGET_SNAPSHOT"
                rm -rf "$STAGE"
                return 1
            }
        fi
    done < <(config_backup_allowed_roots)
    while IFS= read -r TAR_OPTION; do
        TAR_COMPARE_ARGS+=("$TAR_OPTION")
    done < <(safety_tar_metadata_options)
    if ! tar "${TAR_COMPARE_ARGS[@]}" -cf "$TARGET_SNAPSHOT" \
        -C "$RESTORE_ROOT" -T "$TARGET_ROOTS" 2>/dev/null; then
        rm -f -- "$IMPORT_ROOTS" "$TARGET_ROOTS" "$TARGET_SNAPSHOT" \
            "$CURRENT_TARGET_ROOTS" "$CURRENT_TARGET_SNAPSHOT"
        rm -rf "$STAGE"
        error "无法创建导入前配置快照"
        return 1
    fi
    while IFS= read -r ROOT; do
        SRC="$STAGE/$ROOT"
        # Imported archives may intentionally contain only a subset of the
        # allowlist. Replace roots that are present exactly, but never delete
        # unrelated roots merely because the package omitted them.
        [ -e "$SRC" ] || [ -L "$SRC" ] || continue
        DEST="${RESTORE_ROOT%/}/$ROOT"
        case "$DEST" in
            "${RESTORE_ROOT%/}/"*) ;;
            *)
                rm -f -- "$IMPORT_ROOTS" "$TARGET_ROOTS" "$TARGET_SNAPSHOT" \
                    "$CURRENT_TARGET_ROOTS" "$CURRENT_TARGET_SNAPSHOT"
                rm -rf "$STAGE"
                error "恢复目标越界：$ROOT"
                return 1
                ;;
        esac
        OLD="${DEST}.vps-tools-restore-old.${TXN_ID}.${INDEX}"
        NEW="${DEST}.vps-tools-restore-new.${TXN_ID}.${INDEX}"
        if [ -e "$OLD" ] || [ -L "$OLD" ] || [ -e "$NEW" ] || [ -L "$NEW" ]; then
            rm -rf "$STAGE"
            rm -f -- "$IMPORT_ROOTS" "$TARGET_ROOTS" "$TARGET_SNAPSHOT" \
                "$CURRENT_TARGET_ROOTS" "$CURRENT_TARGET_SNAPSHOT"
            error "恢复暂存路径已存在，拒绝覆盖：$ROOT"
            return 1
        fi
        if ! mkdir -p "$(dirname "$DEST")" \
            || ! cp -a -- "$SRC" "$NEW"; then
            rm -rf -- "$NEW" 2>/dev/null || true
            for NEW in "${RESTORE_NEWS[@]}"; do
                rm -rf -- "$NEW" 2>/dev/null || true
            done
            rm -rf "$STAGE"
            rm -f -- "$IMPORT_ROOTS" "$TARGET_ROOTS" "$TARGET_SNAPSHOT" \
                "$CURRENT_TARGET_ROOTS" "$CURRENT_TARGET_SNAPSHOT"
            error "无法准备恢复候选：$ROOT"
            return 1
        fi
        HAD_OLD=no
        DEST_ID=""
        if [ -e "$DEST" ] || [ -L "$DEST" ]; then
            HAD_OLD=yes
            DEST_ID=$(config_path_identity "$DEST") || {
                rm -rf -- "$NEW" "$STAGE"
                for ENTRY in "${RESTORE_NEWS[@]}"; do
                    rm -rf -- "$ENTRY" 2>/dev/null || true
                done
                rm -f -- "$IMPORT_ROOTS" "$TARGET_ROOTS" "$TARGET_SNAPSHOT" \
                    "$CURRENT_TARGET_ROOTS" "$CURRENT_TARGET_SNAPSHOT"
                error "无法记录现有恢复目标身份：$ROOT"
                return 1
            }
        fi
        NEW_ID=$(config_path_identity "$NEW") || {
            rm -rf -- "$NEW" "$STAGE"
            for ENTRY in "${RESTORE_NEWS[@]}"; do
                rm -rf -- "$ENTRY" 2>/dev/null || true
            done
            rm -f -- "$IMPORT_ROOTS" "$TARGET_ROOTS" "$TARGET_SNAPSHOT" \
                "$CURRENT_TARGET_ROOTS" "$CURRENT_TARGET_SNAPSHOT"
            error "无法记录恢复候选身份：$ROOT"
            return 1
        }
        RESTORE_ROOTS+=("$ROOT")
        RESTORE_DESTS+=("$DEST")
        RESTORE_OLDS+=("$OLD")
        RESTORE_NEWS+=("$NEW")
        RESTORE_HAD_OLD+=("$HAD_OLD")
        RESTORE_ORIGINAL_IDS+=("$DEST_ID")
        RESTORE_NEW_IDS+=("$NEW_ID")
        RESTORE_INSTALLED+=(no)
        RESTORE_INSTALLED_IDS+=("")
        INDEX=$((INDEX + 1))
    done < "$IMPORT_ROOTS"

    : > "$CURRENT_TARGET_ROOTS"
    while IFS= read -r ROOT; do
        DEST="${RESTORE_ROOT%/}/$ROOT"
        [ -e "$DEST" ] || [ -L "$DEST" ] || continue
        printf '%s\n' "$ROOT" >> "$CURRENT_TARGET_ROOTS" || {
            COMMIT_FAILED=yes
            break
        }
    done < "$IMPORT_ROOTS"
    if [ "$COMMIT_FAILED" = no ] \
        && { ! tar "${TAR_COMPARE_ARGS[@]}" -cf "$CURRENT_TARGET_SNAPSHOT" \
                -C "$RESTORE_ROOT" -T "$CURRENT_TARGET_ROOTS" 2>/dev/null \
            || ! cmp -s "$TARGET_ROOTS" "$CURRENT_TARGET_ROOTS" \
            || ! cmp -s "$TARGET_SNAPSHOT" "$CURRENT_TARGET_SNAPSHOT"; }; then
        error "恢复目标在候选准备期间发生变化，已拒绝覆盖并发修改"
        COMMIT_FAILED=yes
    fi
    if [ "$COMMIT_FAILED" = no ]; then
        ORIGINAL_STAGE=$(mktemp -d) || ORIGINAL_STAGE=""
        VERIFY_STAGE=$(mktemp -d) || VERIFY_STAGE=""
        if [ -z "$ORIGINAL_STAGE" ] || [ -z "$VERIFY_STAGE" ] \
            || ! tar "${TAR_COMPARE_ARGS[@]}" -xf "$TARGET_SNAPSHOT" \
                -C "$ORIGINAL_STAGE" 2>/dev/null; then
            error "无法准备恢复目标的提交校验快照"
            COMMIT_FAILED=yes
        fi
    fi

    for ((INDEX=0; INDEX<${#RESTORE_ROOTS[@]}; INDEX++)); do
        [ "$COMMIT_FAILED" = no ] || break
        DEST=${RESTORE_DESTS[$INDEX]}
        OLD=${RESTORE_OLDS[$INDEX]}
        NEW=${RESTORE_NEWS[$INDEX]}
        HAD_OLD=${RESTORE_HAD_OLD[$INDEX]}
        if [ "$HAD_OLD" = yes ]; then
            CURRENT_ID=$(config_path_identity "$DEST") || CURRENT_ID=""
            if [ "$CURRENT_ID" != "${RESTORE_ORIGINAL_IDS[$INDEX]}" ] \
                || ! mv -- "$DEST" "$OLD"; then
                error "恢复目标在提交前已变化：${RESTORE_ROOTS[$INDEX]}"
                COMMIT_FAILED=yes
                break
            fi
            CURRENT_ID=$(config_path_identity "$OLD") || CURRENT_ID=""
            if [ "$CURRENT_ID" != "${RESTORE_ORIGINAL_IDS[$INDEX]}" ]; then
                [ -e "$DEST" ] || [ -L "$DEST" ] \
                    || mv -- "$OLD" "$DEST" 2>/dev/null || true
                error "无法确认旧配置暂存身份：${RESTORE_ROOTS[$INDEX]}"
                COMMIT_FAILED=yes
                break
            fi
            VERIFY_PATH="$VERIFY_STAGE/${RESTORE_ROOTS[$INDEX]}"
            if ! mkdir -p "$(dirname "$VERIFY_PATH")" 2>/dev/null \
                || ! cp -a "$OLD" "$VERIFY_PATH" 2>/dev/null \
                || ! config_roots_match \
                    "${RESTORE_ROOTS[$INDEX]}" "$ORIGINAL_STAGE" "$VERIFY_STAGE"; then
                rm -rf -- "$VERIFY_PATH" 2>/dev/null || true
                [ -e "$DEST" ] || [ -L "$DEST" ] \
                    || mv -- "$OLD" "$DEST" 2>/dev/null || true
                error "旧配置内容在提交瞬间发生变化：${RESTORE_ROOTS[$INDEX]}"
                COMMIT_FAILED=yes
                break
            fi
            rm -rf -- "$VERIFY_PATH" 2>/dev/null || true
        elif [ -e "$DEST" ] || [ -L "$DEST" ]; then
            error "原本不存在的恢复目标在提交前被创建：${RESTORE_ROOTS[$INDEX]}"
            COMMIT_FAILED=yes
            break
        fi
        COMMITTED=$((INDEX + 1))
        if [ -e "$DEST" ] || [ -L "$DEST" ] || ! mv -- "$NEW" "$DEST"; then
            error "无法提交恢复候选：${RESTORE_ROOTS[$INDEX]}"
            COMMIT_FAILED=yes
            break
        fi
        INSTALLED_ID=$(config_path_identity "$DEST") || INSTALLED_ID=""
        if [ "$INSTALLED_ID" != "${RESTORE_NEW_IDS[$INDEX]}" ]; then
            error "恢复候选提交后身份不一致：${RESTORE_ROOTS[$INDEX]}"
            COMMIT_FAILED=yes
            break
        fi
        RESTORE_INSTALLED[$INDEX]=yes
        RESTORE_INSTALLED_IDS[$INDEX]="$INSTALLED_ID"
    done

    if [ "$COMMIT_FAILED" = yes ] \
        || [ "$COMMITTED" -ne "${#RESTORE_ROOTS[@]}" ]; then
        for ((INDEX=COMMITTED-1; INDEX>=0; INDEX--)); do
            DEST=${RESTORE_DESTS[$INDEX]}
            OLD=${RESTORE_OLDS[$INDEX]}
            HAD_OLD=${RESTORE_HAD_OLD[$INDEX]}
            if [ "${RESTORE_INSTALLED[$INDEX]:-no}" = yes ]; then
                CURRENT_ID=$(config_path_identity "$DEST") || CURRENT_ID=""
                if [ "$CURRENT_ID" = "${RESTORE_INSTALLED_IDS[$INDEX]}" ] \
                    && config_roots_match \
                        "${RESTORE_ROOTS[$INDEX]}" "$STAGE" "$RESTORE_ROOT"; then
                    rm -rf -- "$DEST" 2>/dev/null || ROLLBACK_FAILED=yes
                else
                    ROLLBACK_FAILED=yes
                    continue
                fi
            elif [ -e "$DEST" ] || [ -L "$DEST" ]; then
                ROLLBACK_FAILED=yes
                continue
            fi
            if [ "$HAD_OLD" = yes ]; then
                mv -- "$OLD" "$DEST" 2>/dev/null || ROLLBACK_FAILED=yes
            fi
        done
        for NEW in "${RESTORE_NEWS[@]}"; do
            rm -rf -- "$NEW" 2>/dev/null || true
        done
        rm -rf "$STAGE"
        rm -rf -- "$ORIGINAL_STAGE" "$VERIFY_STAGE"
        rm -f -- "$IMPORT_ROOTS" "$TARGET_ROOTS" "$TARGET_SNAPSHOT" \
            "$CURRENT_TARGET_ROOTS" "$CURRENT_TARGET_SNAPSHOT"
        [ "$ROLLBACK_FAILED" = no ] \
            || error "配置恢复提交失败，且部分旧配置未能完整复原"
        return 1
    fi

    for OLD in "${RESTORE_OLDS[@]}"; do
        [ -e "$OLD" ] || [ -L "$OLD" ] || continue
        rm -rf -- "$OLD" 2>/dev/null || CLEANUP_FAILED=yes
    done
    rm -rf "$STAGE"
    rm -rf -- "$ORIGINAL_STAGE" "$VERIFY_STAGE"
    rm -f -- "$IMPORT_ROOTS" "$TARGET_ROOTS" "$TARGET_SNAPSHOT" \
        "$CURRENT_TARGET_ROOTS" "$CURRENT_TARGET_SNAPSHOT"
    [ "$CLEANUP_FAILED" = no ] || warn "配置已完整恢复，但部分旧配置暂存文件清理失败"
}

safety_roots_for_label() {
    case "$1" in
        ssh_login|ssh_revoke_login|ssh_strict_login)
            printf '%s\n' etc/ssh/sshd_config
            ;;
        ssh_port)
            printf '%s\n' \
                etc/ssh/sshd_config \
                etc/systemd/system/ssh.socket.d \
                etc/fail2ban \
                etc/ufw \
                etc/firewalld \
                etc/iptables/rules.v4 \
                etc/iptables/rules.v6
            ;;
        dns)
            printf '%s\n' \
                etc/resolv.conf \
                etc/systemd/resolved.conf \
                etc/systemd/resolved.conf.d \
                etc/NetworkManager/conf.d \
                etc/NetworkManager/system-connections \
                etc/resolvconf/resolv.conf.d
            ;;
        dns_manual)
            printf '%s\n' etc/resolv.conf
            ;;
        prefer_v4|prefer_v6)
            printf '%s\n' etc/gai.conf
            ;;
        disable_v6|enable_v6)
            printf '%s\n' etc/sysctl.d/99-ipv6-disable.conf
            ;;
        network_interface)
            printf '%s\n' \
                etc/resolv.conf \
                etc/netplan \
                etc/NetworkManager/system-connections \
                etc/systemd/network \
                etc/network/interfaces \
                etc/network/interfaces.d \
                etc/sysconfig/network-scripts
            ;;
        ufw|firewall_install_ufw)
            printf '%s\n' etc/ufw
            ;;
        firewalld|firewall_install_firewalld)
            printf '%s\n' etc/firewalld
            ;;
        config_restore)
            config_backup_allowed_roots
            ;;
        *)
            return 1
            ;;
    esac
}

safety_snapshot_restore_paths() {
    local OUTPUT="$1" LABEL="$2" ROOT
    : > "$OUTPUT" || return 1
    while IFS= read -r ROOT; do
        [ -n "$ROOT" ] || continue
        printf '%s\n' "$ROOT" >> "$OUTPUT" || return 1
    done < <(safety_roots_for_label "$LABEL") || return 1
    [ -s "$OUTPUT" ] || return 1
    chmod 600 "$OUTPUT" 2>/dev/null || true
}

safety_snapshot_sysctl_state() {
    local OUTPUT="$1" LABEL="$2" KEY VALUE
    : > "$OUTPUT" || return 1
    command -v sysctl >/dev/null 2>&1 || return 0
    case "$LABEL" in
        disable_v6|enable_v6)
            set -- \
                net.ipv6.conf.all.disable_ipv6 \
                net.ipv6.conf.default.disable_ipv6 \
                net.ipv6.conf.lo.disable_ipv6
            ;;
        prefer_v4)
            set -- net.ipv4.conf.all.promote_secondaries
            ;;
        config_restore)
            set -- \
                net.ipv6.conf.all.disable_ipv6 \
                net.ipv6.conf.default.disable_ipv6 \
                net.ipv6.conf.lo.disable_ipv6 \
                net.ipv4.conf.all.promote_secondaries
            ;;
        *)
            set --
            ;;
    esac
    for KEY in "$@"; do
        VALUE=$(sysctl -n "$KEY" 2>/dev/null) || continue
        case "$VALUE" in ''|*[!0-9-]*) continue ;; esac
        printf '%s=%s\n' "$KEY" "$VALUE" >> "$OUTPUT" || return 1
    done
    chmod 600 "$OUTPUT" 2>/dev/null || true
}

safety_snapshot_iptables_state() {
    local OUTPUT="$1" LABEL="$2"
    SAFETY_IPTABLES_SNAPSHOT_AVAILABLE=no
    : > "$OUTPUT" || return 1
    case "$LABEL" in
        ssh_port|ufw|firewalld|firewall_install_ufw|\
        firewall_install_firewalld|config_restore) ;;
        *) return 0 ;;
    esac
    if command -v iptables-save >/dev/null 2>&1; then
        if iptables-save > "$OUTPUT" 2>/dev/null; then
            SAFETY_IPTABLES_SNAPSHOT_AVAILABLE=yes
        else
            : > "$OUTPUT"
        fi
    fi
    chmod 600 "$OUTPUT" 2>/dev/null || true
    return 0
}

safety_snapshot_ip6tables_state() {
    local OUTPUT="$1" LABEL="$2"
    SAFETY_IP6TABLES_SNAPSHOT_AVAILABLE=no
    : > "$OUTPUT" || return 1
    case "$LABEL" in
        ssh_port|ufw|firewalld|firewall_install_ufw|\
        firewall_install_firewalld|config_restore) ;;
        *) return 0 ;;
    esac
    if command -v ip6tables-save >/dev/null 2>&1; then
        if ip6tables-save > "$OUTPUT" 2>/dev/null; then
            SAFETY_IP6TABLES_SNAPSHOT_AVAILABLE=yes
        else
            : > "$OUTPUT"
        fi
    fi
    chmod 600 "$OUTPUT" 2>/dev/null || true
    return 0
}

safety_tar_metadata_options() {
    local HELP
    HELP=$(LC_ALL=C tar --help 2>/dev/null) || return 0
    printf '%s\n' "$HELP" | grep -q -- '--acls' && printf '%s\n' --acls
    printf '%s\n' "$HELP" | grep -q -- '--xattrs' && printf '%s\n' --xattrs
    printf '%s\n' "$HELP" | grep -q -- '--selinux' && printf '%s\n' --selinux
    # GNU tar records atime/ctime in extended PAX headers when metadata
    # options are enabled. Merely reading a protected file updates atime, and
    # the archival read itself can subsequently update ctime on some filesystems
    # (observed with Git for Windows and possible network/overlay mounts).
    # That makes otherwise identical archives differ and can falsely turn a timed SSH
    # rollback into a failed "concurrent modification". These timestamps are
    # volatile, cannot be restored meaningfully, and are not part of the
    # configuration state being protected. Keep all durable metadata while
    # normalizing only those volatile PAX fields. The same content/owner/mode/
    # ACL/xattr guard remains in place for durable configuration changes.
    printf '%s\n' "$HELP" | grep -q -- '--pax-option' \
        && printf '%s\n' '--pax-option=delete=atime,delete=ctime'
    return 0
}

safety_snapshot_create() {
    local OUTPUT="$1" ROOTS_FILE="$2" LIST ROOT
    local SOURCE_ROOT="${SAFETY_SNAPSHOT_ROOT:-${SAFETY_RESTORE_ROOT:-/}}"
    local TAR_EXTRA=() TAR_OPTION
    LIST=$(mktemp) || return 1
    : > "$LIST" || { rm -f "$LIST"; return 1; }
    while IFS= read -r ROOT; do
        case "$ROOT" in
            etc/*|root/*|var/spool/cron/*) ;;
            *) rm -f "$LIST" "$OUTPUT"; return 1 ;;
        esac
        [ -e "${SOURCE_ROOT%/}/$ROOT" ] || [ -L "${SOURCE_ROOT%/}/$ROOT" ] || continue
        printf '%s\n' "$ROOT" >> "$LIST" || {
            rm -f "$LIST" "$OUTPUT"
            return 1
        }
    done < "$ROOTS_FILE"
    while IFS= read -r TAR_OPTION; do
        [ -n "$TAR_OPTION" ] && TAR_EXTRA+=("$TAR_OPTION")
    done < <(safety_tar_metadata_options)
    if ! tar "${TAR_EXTRA[@]}" -czf "$OUTPUT" \
        -C "$SOURCE_ROOT" -T "$LIST" 2>/dev/null; then
        rm -f "$LIST" "$OUTPUT"
        return 1
    fi
    rm -f "$LIST"
    chmod 600 "$OUTPUT" 2>/dev/null || true
}

safety_applied_snapshot_create() {
    local OUTPUT="$1" PRESENT_FILE="$2" ROOTS_FILE="$3"
    local ROOT SOURCE_ROOT="${SAFETY_RESTORE_ROOT:-/}"
    local TAR_EXTRA=() TAR_OPTION
    : > "$PRESENT_FILE" || return 1
    while IFS= read -r ROOT; do
        case "$ROOT" in
            etc/*|root/*|var/spool/cron/*) ;;
            *) return 1 ;;
        esac
        [ -e "${SOURCE_ROOT%/}/$ROOT" ] || [ -L "${SOURCE_ROOT%/}/$ROOT" ] \
            || continue
        printf '%s\n' "$ROOT" >> "$PRESENT_FILE" || return 1
    done < "$ROOTS_FILE"
    while IFS= read -r TAR_OPTION; do
        [ -n "$TAR_OPTION" ] && TAR_EXTRA+=("$TAR_OPTION")
    done < <(safety_tar_metadata_options)
    tar "${TAR_EXTRA[@]}" -cf "$OUTPUT" \
        -C "$SOURCE_ROOT" -T "$PRESENT_FILE" 2>/dev/null \
        || return 1
    chmod 600 "$OUTPUT" "$PRESENT_FILE" 2>/dev/null || true
}

safety_artifact_remove() {
    local FILE="${1:-}"
    [ -n "$FILE" ] || return 0
    case "$FILE" in
        "${VPS_DATA_DIR}"/rollback_*.sh|\
        "${VPS_DATA_DIR}"/rollback_*.roots|\
        "${VPS_DATA_DIR}"/rollback_*.sysctl|\
        "${VPS_DATA_DIR}"/rollback_*.iptables|\
        "${VPS_DATA_DIR}"/rollback_*.ip6tables|\
        "${VPS_DATA_DIR}"/rollback_*.applied.tar|\
        "${VPS_DATA_DIR}"/rollback_*.applied.roots|\
        "${VPS_DATA_DIR}"/rollback_*.tar.gz)
            rm -f -- "$FILE" 2>/dev/null || true
            ;;
    esac
}

config_backup_prune() {
    local FILES=() f REMOVE_COUNT i
    while IFS= read -r f; do FILES+=("$f"); done < <(
        find "$VPS_BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' 2>/dev/null | sort -r
    )
    [ "${#FILES[@]}" -le "$VPS_BACKUP_KEEP" ] && return 0
    REMOVE_COUNT=$((${#FILES[@]} - VPS_BACKUP_KEEP))
    for ((i=${#FILES[@]}-1; i>=VPS_BACKUP_KEEP; i--)); do
        rm -f "${FILES[$i]}"
    done
    audit_action "自动清理 $REMOVE_COUNT 个旧配置备份" SUCCESS
}

safety_state_write_atomic() {
    local STATE_FILE="$1" PID="$2" SCRIPT="$3" ROOTS_FILE="$4"
    local SYSCTL_FILE="$5" SNAPSHOT="$6" STATUS="$7" STATE_TMP
    STATE_TMP=$(mktemp "${STATE_FILE}.tmp.XXXXXX") || return 1
    if printf '%s|%s|%s|%s|%s|%s\n' \
        "$PID" "$SCRIPT" "$ROOTS_FILE" "$SYSCTL_FILE" "$SNAPSHOT" "$STATUS" \
        > "$STATE_TMP" \
        && chmod 600 "$STATE_TMP" 2>/dev/null \
        && mv -f -- "$STATE_TMP" "$STATE_FILE"; then
        return 0
    fi
    rm -f -- "$STATE_TMP"
    return 1
}

safety_load_pending() {
    local STATE_FILE="${SAFETY_STATE_FILE:-${VPS_DATA_DIR}/rollback.active}"
    local PID="" SCRIPT="" ROOTS_FILE="" SYSCTL_FILE="" SNAPSHOT="" STATUS=""
    if [ -f "$STATE_FILE" ]; then
        IFS='|' read -r PID SCRIPT ROOTS_FILE SYSCTL_FILE SNAPSHOT STATUS < "$STATE_FILE" || true
        [ -n "$STATUS" ] || STATUS=armed
        SAFETY_PID="$PID"
        SAFETY_SCRIPT="$SCRIPT"
        SAFETY_ROOTS_FILE="$ROOTS_FILE"
        SAFETY_SYSCTL_FILE="$SYSCTL_FILE"
        SAFETY_SNAPSHOT="$SNAPSHOT"
        SAFETY_IPTABLES_FILE="${SCRIPT%.sh}.iptables"
        SAFETY_IP6TABLES_FILE="${SCRIPT%.sh}.ip6tables"
        SAFETY_APPLIED_SNAPSHOT="${SCRIPT%.sh}.applied.tar"
        SAFETY_APPLIED_ROOTS="${SCRIPT%.sh}.applied.roots"
        SAFETY_STATUS="$STATUS"
        if [ "$STATUS" = failed ]; then
            return 0
        fi
        if safety_worker_identity_valid "$PID" "$SCRIPT"; then
            return 0
        fi
        PID=""
        if [ -n "$SNAPSHOT" ] && [ -f "$SNAPSHOT" ]; then
            SAFETY_PID=""
            if safety_state_write_atomic \
                "$STATE_FILE" "" "$SCRIPT" "$ROOTS_FILE" "$SYSCTL_FILE" \
                "$SNAPSHOT" failed; then
                SAFETY_STATUS=failed
                error "检测到异常终止的防断联任务，已原子保留失败状态和快照：$SNAPSHOT"
            else
                SAFETY_STATUS=armed
                error "检测到异常终止的防断联任务，但无法写入失败状态；原状态和快照均未清理：$SNAPSHOT"
            fi
            return 0
        fi
        safety_artifact_remove "$SCRIPT"
        safety_artifact_remove "$ROOTS_FILE"
        safety_artifact_remove "$SYSCTL_FILE"
        safety_artifact_remove "${SCRIPT%.sh}.iptables"
        safety_artifact_remove "${SCRIPT%.sh}.ip6tables"
        safety_artifact_remove "${SCRIPT%.sh}.applied.tar"
        safety_artifact_remove "${SCRIPT%.sh}.applied.roots"
        safety_artifact_remove "$SNAPSHOT"
        rm -f "$STATE_FILE" 2>/dev/null || true
    fi
    if safety_worker_identity_valid \
        "${SAFETY_PID:-}" "${SAFETY_SCRIPT:-}"; then
        return 0
    fi
    safety_artifact_remove "${SAFETY_SCRIPT:-}"
    safety_artifact_remove "${SAFETY_ROOTS_FILE:-}"
    safety_artifact_remove "${SAFETY_SYSCTL_FILE:-}"
    safety_artifact_remove "${SAFETY_IPTABLES_FILE:-}"
    safety_artifact_remove "${SAFETY_IP6TABLES_FILE:-}"
    safety_artifact_remove "${SAFETY_APPLIED_SNAPSHOT:-}"
    safety_artifact_remove "${SAFETY_APPLIED_ROOTS:-}"
    safety_artifact_remove "${SAFETY_SNAPSHOT:-}"
    SAFETY_PID="" SAFETY_SCRIPT="" SAFETY_ROOTS_FILE="" SAFETY_SYSCTL_FILE=""
    SAFETY_IPTABLES_FILE="" SAFETY_IP6TABLES_FILE=""
    SAFETY_APPLIED_SNAPSHOT="" SAFETY_APPLIED_ROOTS=""
    SAFETY_SNAPSHOT="" SAFETY_STATUS=""
    return 1
}

safety_process_start_token() {
    local PROCESS_PID="$1" PROCESS_STAT="" PROCESS_REST="" TOKEN=""
    [[ "$PROCESS_PID" =~ ^[1-9][0-9]*$ ]] || return 1
    if [ -r "/proc/${PROCESS_PID}/stat" ]; then
        IFS= read -r PROCESS_STAT < "/proc/${PROCESS_PID}/stat" || return 1
        PROCESS_REST=${PROCESS_STAT##*) }
        TOKEN=$(printf '%s\n' "$PROCESS_REST" | awk '{print $20}') || return 1
    elif command -v ps >/dev/null 2>&1; then
        TOKEN=$(LC_ALL=C ps -p "$PROCESS_PID" -o lstart= 2>/dev/null) || return 1
        TOKEN=$(printf '%s\n' "$TOKEN" | awk '{$1=$1; print}')
    fi
    [ -n "$TOKEN" ] || return 1
    printf '%s\n' "$TOKEN"
}

safety_lock_owner_valid() {
    local OWNER="$1" OWNER_PID OWNER_TOKEN CURRENT_TOKEN
    case "$OWNER" in *'|'*) ;; *) return 1 ;; esac
    OWNER_PID=${OWNER%%|*}
    OWNER_TOKEN=${OWNER#*|}
    [[ "$OWNER_PID" =~ ^[1-9][0-9]*$ ]] && [ -n "$OWNER_TOKEN" ] \
        && kill -0 "$OWNER_PID" 2>/dev/null || return 1
    CURRENT_TOKEN=$(safety_process_start_token "$OWNER_PID") || return 1
    [ "$CURRENT_TOKEN" = "$OWNER_TOKEN" ]
}

safety_lock_acquire() {
    local STATE_FILE="${SAFETY_STATE_FILE:-${VPS_DATA_DIR}/rollback.active}"
    local LOCK_DIR="${STATE_FILE}.lock" LOCK_OWNER="" LOCK_OWNER_AFTER=""
    local SELF_TOKEN="" SELF_OWNER=""
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        LOCK_OWNER=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
        if safety_lock_owner_valid "$LOCK_OWNER"; then
            return 1
        fi
        # A new owner may have created the directory but not written its PID
        # yet. Recheck before treating a PID-less/dead lock as stale.
        sleep 1
        LOCK_OWNER_AFTER=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
        if safety_lock_owner_valid "$LOCK_OWNER_AFTER"; then
            return 1
        fi
        [ "$LOCK_OWNER" = "$LOCK_OWNER_AFTER" ] || return 1
        rm -f "$LOCK_DIR/pid" 2>/dev/null || return 1
        rmdir "$LOCK_DIR" 2>/dev/null || return 1
        mkdir "$LOCK_DIR" 2>/dev/null || return 1
    fi
    SELF_TOKEN=$(safety_process_start_token "$$") || SELF_TOKEN=""
    SELF_OWNER="$$|$SELF_TOKEN"
    if [ -z "$SELF_TOKEN" ] || ! printf '%s\n' "$SELF_OWNER" > "$LOCK_DIR/pid"; then
        rm -f "$LOCK_DIR/pid" 2>/dev/null || true
        rmdir "$LOCK_DIR" 2>/dev/null || true
        return 1
    fi
    SAFETY_LOCK_DIR="$LOCK_DIR"
    SAFETY_LOCK_OWNER="$SELF_OWNER"
}

safety_lock_release() {
    local LOCK_DIR="${SAFETY_LOCK_DIR:-}" LOCK_OWNER=""
    [ -n "$LOCK_DIR" ] || return 0
    LOCK_OWNER=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [ "$LOCK_OWNER" = "${SAFETY_LOCK_OWNER:-}" ]; then
        rm -f "$LOCK_DIR/pid" 2>/dev/null || true
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
    SAFETY_LOCK_DIR=""
    SAFETY_LOCK_OWNER=""
}

safety_worker_identity_valid() {
    local WORKER_PID="$1" WORKER_SCRIPT="$2" CMDLINE=""
    [[ "$WORKER_PID" =~ ^[1-9][0-9]*$ ]] && [ -f "$WORKER_SCRIPT" ] \
        && kill -0 "$WORKER_PID" 2>/dev/null || return 1
    if [ -r "/proc/${WORKER_PID}/cmdline" ]; then
        CMDLINE=$(tr '\0' ' ' < "/proc/${WORKER_PID}/cmdline" 2>/dev/null) \
            || return 1
    elif command -v ps >/dev/null 2>&1; then
        CMDLINE=$(ps -p "$WORKER_PID" -o args= 2>/dev/null) || return 1
    else
        return 1
    fi
    case "$CMDLINE" in *"$WORKER_SCRIPT"*) return 0 ;; *) return 1 ;; esac
}

safety_mark_applied() {
    local STATE_FILE="${SAFETY_STATE_FILE:-${VPS_DATA_DIR}/rollback.active}"
    local APPLIED_SNAPSHOT APPLIED_ROOTS SNAP_TMP ROOTS_TMP
    local EXPECTED_PID="${SAFETY_PID:-}" EXPECTED_SCRIPT="${SAFETY_SCRIPT:-}"
    local EXPECTED_ROOTS="${SAFETY_ROOTS_FILE:-}"
    local EXPECTED_SYSCTL="${SAFETY_SYSCTL_FILE:-}"
    local EXPECTED_SNAPSHOT="${SAFETY_SNAPSHOT:-}"
    local STATE_PID STATE_SCRIPT STATE_ROOTS STATE_SYSCTL STATE_SNAPSHOT STATE_STATUS
    [[ "$EXPECTED_PID" =~ ^[1-9][0-9]*$ ]] && [ -n "$EXPECTED_SCRIPT" ] \
        || return 1
    if ! safety_lock_acquire; then
        error "自动回滚正在执行，无法记录本次变更的提交状态"
        return 1
    fi
    if ! IFS='|' read -r STATE_PID STATE_SCRIPT STATE_ROOTS STATE_SYSCTL \
        STATE_SNAPSHOT STATE_STATUS < "$STATE_FILE" 2>/dev/null \
        || [ "$STATE_PID" != "$EXPECTED_PID" ] \
        || [ "$STATE_SCRIPT" != "$EXPECTED_SCRIPT" ] \
        || [ "$STATE_ROOTS" != "$EXPECTED_ROOTS" ] \
        || [ "$STATE_SYSCTL" != "$EXPECTED_SYSCTL" ] \
        || [ "$STATE_SNAPSHOT" != "$EXPECTED_SNAPSHOT" ] \
        || ! safety_worker_identity_valid "$STATE_PID" "$STATE_SCRIPT"; then
        safety_lock_release
        error "防断联任务已超时、已被替换或身份不匹配"
        return 1
    fi
    APPLIED_SNAPSHOT="${EXPECTED_SCRIPT%.sh}.applied.tar"
    APPLIED_ROOTS="${EXPECTED_SCRIPT%.sh}.applied.roots"
    if [ "$STATE_STATUS" = applied ]; then
        if [ -f "$APPLIED_SNAPSHOT" ] && [ -f "$APPLIED_ROOTS" ]; then
            SAFETY_APPLIED_SNAPSHOT="$APPLIED_SNAPSHOT"
            SAFETY_APPLIED_ROOTS="$APPLIED_ROOTS"
            safety_lock_release
            return 0
        fi
        safety_lock_release
        error "防断联任务的提交快照不完整"
        return 1
    fi
    if [ "$STATE_STATUS" != armed ] \
        || [ -z "$EXPECTED_ROOTS" ] || [ ! -f "$EXPECTED_ROOTS" ]; then
        safety_lock_release
        error "防断联任务状态不允许记录提交快照"
        return 1
    fi
    SNAP_TMP=$(mktemp "${APPLIED_SNAPSHOT}.tmp.XXXXXX") || SNAP_TMP=""
    ROOTS_TMP=$(mktemp "${APPLIED_ROOTS}.tmp.XXXXXX") || ROOTS_TMP=""
    if [ -z "$SNAP_TMP" ] || [ -z "$ROOTS_TMP" ] \
        || ! safety_applied_snapshot_create \
            "$SNAP_TMP" "$ROOTS_TMP" "$EXPECTED_ROOTS" \
        || ! mv -f -- "$ROOTS_TMP" "$APPLIED_ROOTS" \
        || ! mv -f -- "$SNAP_TMP" "$APPLIED_SNAPSHOT" \
        || ! safety_state_write_atomic \
            "$STATE_FILE" "$STATE_PID" "$STATE_SCRIPT" \
            "$EXPECTED_ROOTS" "$EXPECTED_SYSCTL" \
            "$EXPECTED_SNAPSHOT" applied; then
        [ -z "$SNAP_TMP" ] || rm -f -- "$SNAP_TMP"
        [ -z "$ROOTS_TMP" ] || rm -f -- "$ROOTS_TMP"
        safety_artifact_remove "$APPLIED_SNAPSHOT"
        safety_artifact_remove "$APPLIED_ROOTS"
        safety_lock_release
        error "无法记录变更后的并发保护快照，自动回滚仍保持待命"
        return 1
    fi
    SAFETY_APPLIED_SNAPSHOT="$APPLIED_SNAPSHOT"
    SAFETY_APPLIED_ROOTS="$APPLIED_ROOTS"
    SAFETY_STATUS=applied
    safety_lock_release
    return 0
}

cancel_safety_timer() {
    local STATE_FILE="${SAFETY_STATE_FILE:-${VPS_DATA_DIR}/rollback.active}"
    local EXPECTED_PID="${1:-}" EXPECTED_SCRIPT="${2:-}" EXPECTED_ROOTS="${3:-}"
    local EXPECTED_SYSCTL="${4:-}" EXPECTED_SNAPSHOT="${5:-}" EXPECT_EXACT=no
    local ARTIFACT FAILED=no
    [ "$#" -lt 5 ] || EXPECT_EXACT=yes
    if ! safety_lock_acquire; then
        error "自动回滚已开始执行或正由其他进程处理，不能安全取消"
        return 1
    fi
    if ! safety_load_pending; then
        safety_lock_release
        [ "$EXPECT_EXACT" = no ] || {
            error "待取消的防断联任务已不存在"
            return 1
        }
        return 0
    fi
    if [ "$EXPECT_EXACT" = yes ] \
        && { [ "${SAFETY_PID:-}" != "$EXPECTED_PID" ] \
            || [ "${SAFETY_SCRIPT:-}" != "$EXPECTED_SCRIPT" ] \
            || [ "${SAFETY_ROOTS_FILE:-}" != "$EXPECTED_ROOTS" ] \
            || [ "${SAFETY_SYSCTL_FILE:-}" != "$EXPECTED_SYSCTL" ] \
            || [ "${SAFETY_SNAPSHOT:-}" != "$EXPECTED_SNAPSHOT" ]; }; then
        safety_lock_release
        error "当前防断联任务与待取消事务不一致，拒绝取消其他任务"
        return 1
    fi
    case "${SAFETY_STATUS:-armed}" in
        armed|applied|cancelled) ;;
        restoring)
            safety_lock_release
            error "自动回滚已经开始，不能在恢复过程中取消"
            return 1
            ;;
        failed)
            safety_lock_release
            error "自动回滚此前执行失败，快照和状态已保留，不能当作成功取消"
            return 1
            ;;
        *)
            safety_lock_release
            error "自动回滚状态未知，拒绝清理恢复材料"
            return 1
            ;;
    esac
    if [[ "${SAFETY_PID:-}" =~ ^[1-9][0-9]*$ ]]; then
        kill "$SAFETY_PID" 2>/dev/null || true
        wait "$SAFETY_PID" 2>/dev/null || true
        for _ in 1 2 3 4 5; do
            kill -0 "$SAFETY_PID" 2>/dev/null || break
            sleep 0.05
        done
        if kill -0 "$SAFETY_PID" 2>/dev/null; then
            safety_lock_release
            error "自动回滚进程未能停止，已保留状态和快照"
            return 1
        fi
    fi
    safety_artifact_remove "${SAFETY_SCRIPT:-}"
    safety_artifact_remove "${SAFETY_ROOTS_FILE:-}"
    safety_artifact_remove "${SAFETY_SYSCTL_FILE:-}"
    safety_artifact_remove "${SAFETY_IPTABLES_FILE:-}"
    safety_artifact_remove "${SAFETY_IP6TABLES_FILE:-}"
    safety_artifact_remove "${SAFETY_APPLIED_SNAPSHOT:-}"
    safety_artifact_remove "${SAFETY_APPLIED_ROOTS:-}"
    case "${SAFETY_SNAPSHOT:-}" in
        "${VPS_DATA_DIR}"/rollback_*.tar.gz)
            safety_artifact_remove "$SAFETY_SNAPSHOT"
            ;;
    esac
    for ARTIFACT in \
        "${SAFETY_SCRIPT:-}" "${SAFETY_ROOTS_FILE:-}" \
        "${SAFETY_SYSCTL_FILE:-}" "${SAFETY_IPTABLES_FILE:-}" \
        "${SAFETY_IP6TABLES_FILE:-}" "${SAFETY_APPLIED_SNAPSHOT:-}" \
        "${SAFETY_APPLIED_ROOTS:-}"; do
        [ -z "$ARTIFACT" ] \
            || { [ ! -e "$ARTIFACT" ] && [ ! -L "$ARTIFACT" ]; } \
            || FAILED=yes
    done
    case "${SAFETY_SNAPSHOT:-}" in
        "${VPS_DATA_DIR}"/rollback_*.tar.gz)
            { [ ! -e "$SAFETY_SNAPSHOT" ] && [ ! -L "$SAFETY_SNAPSHOT" ]; } \
                || FAILED=yes
            ;;
    esac
    if ! rm -f -- "$STATE_FILE" 2>/dev/null \
        || [ -e "$STATE_FILE" ] || [ -L "$STATE_FILE" ]; then
        FAILED=yes
    fi
    if [ "$FAILED" = yes ]; then
        safety_lock_release
        error "自动回滚进程已停止，但状态或恢复材料未能完整清理"
        return 1
    fi
    SAFETY_PID="" SAFETY_SCRIPT="" SAFETY_ROOTS_FILE="" SAFETY_SYSCTL_FILE=""
    SAFETY_IPTABLES_FILE="" SAFETY_IP6TABLES_FILE=""
    SAFETY_APPLIED_SNAPSHOT="" SAFETY_APPLIED_ROOTS=""
    SAFETY_SNAPSHOT="" SAFETY_STATUS=""
    safety_lock_release
    return 0
}

safety_cancel_current_transaction() {
    local EXPECTED_PID="${SAFETY_PID:-}" EXPECTED_SCRIPT="${SAFETY_SCRIPT:-}"
    local EXPECTED_ROOTS="${SAFETY_ROOTS_FILE:-}"
    local EXPECTED_SYSCTL="${SAFETY_SYSCTL_FILE:-}"
    local EXPECTED_SNAPSHOT="${SAFETY_SNAPSHOT:-}"
    [[ "$EXPECTED_PID" =~ ^[1-9][0-9]*$ ]] && [ -n "$EXPECTED_SCRIPT" ] \
        || return 1
    cancel_safety_timer \
        "$EXPECTED_PID" "$EXPECTED_SCRIPT" "$EXPECTED_ROOTS" \
        "$EXPECTED_SYSCTL" "$EXPECTED_SNAPSHOT"
}

confirm_change_preview() {
    local TITLE="$1"
    shift
    echo ""
    menu_div
    echo -e "  ${BOLD}变更预览：$TITLE${NC}"
    while [ "$#" -gt 0 ]; do echo -e "  ${YELLOW}•${NC} $1"; shift; done
    menu_div
    read -rp "  确认应用以上变更？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$'
}

confirm_file_diff() {
    local OLD_FILE="$1" NEW_FILE="$2" TITLE="$3"
    echo ""
    menu_div
    echo -e "  ${BOLD}配置差异：$TITLE${NC}"
    if command -v diff >/dev/null 2>&1; then
        diff -u "$OLD_FILE" "$NEW_FILE" 2>/dev/null | sed -n '1,120p' || true
    else
        warn "系统没有 diff，无法显示逐行差异"
    fi
    menu_div
    read -rp "  确认应用以上配置？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$'
}

config_archive_create_compatible() {
    local OUTPUT="$1" ROOT="$2" LIST="$3" HELP
    HELP=$(LC_ALL=C tar --help 2>/dev/null || true)
    if printf '%s\n' "$HELP" | grep -q -- '--format'; then
        tar --format=ustar -czf "$OUTPUT" -C "$ROOT" -T "$LIST" 2>/dev/null
    else
        tar -czf "$OUTPUT" -C "$ROOT" -T "$LIST" 2>/dev/null
    fi
}

config_backup_create() {
    local LABEL="${1:-manual}" QUIET="${2:-false}" TS FILE LIST TEMP_FILE SAFE_LABEL
    TS=$(date +%Y%m%d_%H%M%S)
    SAFE_LABEL=$(printf '%s' "$LABEL" | tr -c 'A-Za-z0-9._-' '_')
    [ -n "$SAFE_LABEL" ] || SAFE_LABEL=manual
    mkdir -p "$VPS_BACKUP_DIR" || {
        [ "$QUIET" = true ] || error "无法创建配置备份目录"
        return 1
    }
    chmod 700 "$VPS_DATA_DIR" "$VPS_BACKUP_DIR" 2>/dev/null || true
    FILE="$VPS_BACKUP_DIR/${TS}_${SAFE_LABEL}_$$_${RANDOM}.tar.gz"
    TEMP_FILE=$(mktemp "$VPS_BACKUP_DIR/.config-backup.XXXXXX") || {
        [ "$QUIET" = true ] || error "无法创建配置备份临时文件"
        return 1
    }
    LIST=$(mktemp) || {
        [ "$QUIET" = true ] || error "无法创建配置备份清单"
        rm -f -- "$TEMP_FILE"
        return 1
    }
    if ! config_backup_paths > "$LIST"; then
        rm -f "$LIST" "$TEMP_FILE"
        [ "$QUIET" = true ] || error "无法生成配置备份清单"
        return 1
    fi
    if [ ! -s "$LIST" ] \
        || ! config_archive_create_compatible "$TEMP_FILE" / "$LIST"; then
        rm -f "$LIST" "$TEMP_FILE"
        [ "$QUIET" = true ] || error "配置备份失败"
        return 1
    fi
    rm -f "$LIST"
    if ! config_archive_validate "$TEMP_FILE" >/dev/null 2>&1; then
        rm -f "$TEMP_FILE"
        [ "$QUIET" = true ] || error "当前配置包含无法安全恢复的链接或特殊文件，备份已取消"
        return 1
    fi
    if ! chmod 600 "$TEMP_FILE" \
        || [ -e "$FILE" ] || ! mv -- "$TEMP_FILE" "$FILE"; then
        rm -f "$TEMP_FILE"
        [ "$QUIET" = true ] || error "无法保护配置备份权限"
        return 1
    fi
    audit_action "创建配置备份 $(basename "$FILE")" SUCCESS
    config_backup_prune
    if [ "$QUIET" = true ]; then printf '%s\n' "$FILE"; else info "配置已备份：$FILE"; fi
}

config_archive_stage() {
    local SOURCE="$1" RESULT_VAR="$2" STAGE_DIR STAGED SIZE
    local MAX_COMPRESSED="${CONFIG_ARCHIVE_MAX_COMPRESSED_BYTES:-67108864}"
    case "$MAX_COMPRESSED" in
        ''|*[!0-9]*) MAX_COMPRESSED=67108864 ;;
    esac
    [ "$MAX_COMPRESSED" -ge 1 ] 2>/dev/null || MAX_COMPRESSED=67108864
    [ -f "$SOURCE" ] || return 1
    STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vps-config-restore.XXXXXX") || return 1
    STAGED="$STAGE_DIR/archive.tar.gz"
    if ! (umask 077; head -c "$((MAX_COMPRESSED + 1))" -- "$SOURCE" > "$STAGED"); then
        rm -f -- "$STAGED"
        rmdir -- "$STAGE_DIR" 2>/dev/null || true
        return 1
    fi
    SIZE=$(stat -c '%s' "$STAGED" 2>/dev/null) || {
        rm -f -- "$STAGED"
        rmdir -- "$STAGE_DIR" 2>/dev/null || true
        return 1
    }
    if [ "$SIZE" -gt "$MAX_COMPRESSED" ]; then
        rm -f -- "$STAGED"
        rmdir -- "$STAGE_DIR" 2>/dev/null || true
        return 1
    fi
    chmod 600 "$STAGED" 2>/dev/null || {
        rm -f -- "$STAGED"
        rmdir -- "$STAGE_DIR" 2>/dev/null || true
        return 1
    }
    printf -v "$RESULT_VAR" '%s' "$STAGED"
}

config_archive_stage_cleanup() {
    local STAGED="${1:-}" STAGE_DIR
    [ -n "$STAGED" ] || return 0
    STAGE_DIR=$(dirname -- "$STAGED") || return 1
    rm -f -- "$STAGED" 2>/dev/null || true
    rmdir -- "$STAGE_DIR" 2>/dev/null || true
}

config_backup_restore() {
    local SOURCE_FILE="$1" FILE="" DISPLAY_NAME APPLY_FAILED=no
    local APPLY_FIREWALL_BACKEND=none UFW_STATUS="" IPTABLES_STATUS=""
    [ -f "$SOURCE_FILE" ] || { error "备份不存在"; return 1; }
    DISPLAY_NAME=$(basename -- "$SOURCE_FILE")
    if ! config_archive_stage "$SOURCE_FILE" FILE; then
        error "无法安全暂存配置备份，文件可能过大、已损坏或无法读取"
        return 1
    fi
    if ! config_archive_validate "$FILE"; then
        config_archive_stage_cleanup "$FILE"
        return 1
    fi
    warn "恢复将覆盖当前配置，并重启相关服务。"
    read -rp "  输入 RESTORE 确认恢复: " CONFIRM
    if [ "$CONFIRM" != "RESTORE" ]; then
        config_archive_stage_cleanup "$FILE"
        warn "已取消"
        return
    fi
    if ! config_backup_create before_restore true >/dev/null; then
        config_archive_stage_cleanup "$FILE"
        return 1
    fi
    if ! safety_arm config_restore; then
        config_archive_stage_cleanup "$FILE"
        return 1
    fi
    if ! config_archive_extract "$FILE"; then
        config_archive_stage_cleanup "$FILE"
        error "恢复失败，已保留恢复前快照"
        audit_action "恢复配置 $DISPLAY_NAME" FAILED
        return 1
    fi
    config_archive_stage_cleanup "$FILE"
    if command -v sshd >/dev/null 2>&1 && ! sshd -t 2>/dev/null; then
        error "恢复后的 SSH 配置语法错误，请从 before_restore 快照恢复"
        audit_action "恢复配置 $DISPLAY_NAME SSH校验失败" FAILED
        return 1
    fi
    if command -v sshd >/dev/null 2>&1 && ! restart_ssh >/dev/null 2>&1; then
        error "配置文件已恢复，但 SSH 服务重载/重启失败"
        APPLY_FAILED=yes
    fi
    if command -v ufw >/dev/null 2>&1; then
        UFW_STATUS=$(LC_ALL=C ufw status 2>/dev/null) || {
            error "配置文件已恢复，但无法可靠读取 UFW 状态"
            APPLY_FAILED=yes
        }
        case "$UFW_STATUS" in
            *"Status: active"*) APPLY_FIREWALL_BACKEND=ufw ;;
            *"Status: inactive"*) ;;
            "")
                [ "$APPLY_FAILED" = yes ] || {
                    error "配置文件已恢复，但 UFW 返回空状态"
                    APPLY_FAILED=yes
                }
                ;;
            *)
                error "配置文件已恢复，但 UFW 返回未知状态"
                APPLY_FAILED=yes
                ;;
        esac
    fi
    if [ "$APPLY_FIREWALL_BACKEND" = none ] && svc_is_active firewalld; then
        APPLY_FIREWALL_BACKEND=firewalld
    elif [ "$APPLY_FIREWALL_BACKEND" = none ] && svc_is_active nftables; then
        APPLY_FIREWALL_BACKEND=nftables
    elif [ "$APPLY_FIREWALL_BACKEND" = none ] \
        && command -v iptables >/dev/null 2>&1; then
        if IPTABLES_STATUS=$(iptables -S INPUT 2>/dev/null); then
            [ -z "$IPTABLES_STATUS" ] || APPLY_FIREWALL_BACKEND=iptables
        else
            error "配置文件已恢复，但无法可靠读取 iptables 状态"
            APPLY_FAILED=yes
        fi
    fi
    case "$APPLY_FIREWALL_BACKEND" in
        ufw)
            if ! ufw reload >/dev/null 2>&1; then
                error "配置文件已恢复，但 UFW 重载失败"
                APPLY_FAILED=yes
            fi
            ;;
        firewalld)
            if ! firewall-cmd --reload >/dev/null 2>&1; then
                error "配置文件已恢复，但 firewalld 重载失败"
                APPLY_FAILED=yes
            fi
            ;;
        nftables)
            if ! { systemctl restart nftables >/dev/null 2>&1 \
                || { command -v nft >/dev/null 2>&1 \
                    && [ -f /etc/nftables.conf ] \
                    && nft -f /etc/nftables.conf >/dev/null 2>&1; }; }; then
                error "配置文件已恢复，但 nftables 配置加载失败"
                APPLY_FAILED=yes
            fi
            ;;
        iptables)
            if [ -f /etc/iptables/rules.v4 ] \
                && command -v iptables-restore >/dev/null 2>&1; then
                if ! iptables-restore < /etc/iptables/rules.v4 >/dev/null 2>&1; then
                    error "配置文件已恢复，但 iptables 运行规则加载失败"
                    APPLY_FAILED=yes
                fi
            fi
            ;;
    esac
    if svc_is_active fail2ban \
        && ! { systemctl restart fail2ban >/dev/null 2>&1 \
            || service fail2ban restart >/dev/null 2>&1; }; then
        error "配置文件已恢复，但 Fail2ban 重启失败"
        APPLY_FAILED=yes
    fi
    if svc_is_active systemd-resolved \
        && ! systemctl restart systemd-resolved >/dev/null 2>&1; then
        error "配置文件已恢复，但 systemd-resolved 重启失败"
        APPLY_FAILED=yes
    fi
    if [ "$APPLY_FAILED" = yes ]; then
        audit_action "恢复配置 $DISPLAY_NAME 服务应用不完整" FAILED
        error "关键服务未完整应用恢复配置，防断联自动回滚保持运行"
        return 1
    fi
    audit_action "恢复配置 $DISPLAY_NAME" SUCCESS
    info "配置恢复完成"
    safety_confirm
}

config_backup_menu() {
    while true; do
        print_header "配置备份与恢复"
        mkdir -p "$VPS_BACKUP_DIR"
        local FILES=() f i=1
        while IFS= read -r f; do FILES+=("$f"); done < <(find "$VPS_BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' 2>/dev/null | sort -r)
        for f in "${FILES[@]}"; do
            echo -e "  ${GREEN}[$i]${NC} $(basename "$f")  ${DIM}$(du -h "$f" 2>/dev/null | awk '{print $1}')${NC}"
            i=$((i+1))
        done
        [ "${#FILES[@]}" -eq 0 ] && echo -e "  ${DIM}暂无备份${NC}"
        menu_div
        menu_pair "c" "创建备份" "r" "恢复备份" "$GREEN" "$YELLOW"
        menu_pair "d" "删除备份" "0" "返回上级" "$RED" "$RED"
        read -rp "$(ui_prompt '选择操作: ')" CH
        case "$CH" in
            c|C) config_backup_create manual ;;
            r|R|d|D)
                [ "${#FILES[@]}" -gt 0 ] || { warn "暂无备份"; sleep 1; continue; }
                read -rp "  输入备份编号: " N
                echo "$N" | grep -qE '^[0-9]+$' || { warn "编号无效"; continue; }
                [ "$N" -ge 1 ] && [ "$N" -le "${#FILES[@]}" ] || { warn "编号无效"; continue; }
                if echo "$CH" | grep -qi '^r$'; then
                    config_backup_restore "${FILES[$((N-1))]}"
                else
                    rm -f "${FILES[$((N-1))]}" && audit_action "删除配置备份 $(basename "${FILES[$((N-1))]}")" SUCCESS
                fi
                ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
        ui_pause
    done
}

config_export_archive() {
    local TARGET="${1:-}" LABEL="${2:-export}" TMP_ARCHIVE
    local OLD_KEEP="$VPS_BACKUP_KEEP"
    VPS_BACKUP_KEEP=999999
    TMP_ARCHIVE=$(config_backup_create "export_${LABEL}" true)
    local RC=$?
    VPS_BACKUP_KEEP="$OLD_KEEP"
    [ "$RC" -eq 0 ] || return "$RC"
    if [ -z "$TARGET" ]; then
        printf '%s\n' "$TMP_ARCHIVE"
        return 0
    fi
    mkdir -p "$(dirname "$TARGET")" 2>/dev/null || { error "无法创建导出目录"; return 1; }
    if ! cp "$TMP_ARCHIVE" "$TARGET" 2>/dev/null; then
        error "导出失败"
        return 1
    fi
    chmod 600 "$TARGET" 2>/dev/null || true
    audit_action "导出配置到 $(basename "$TARGET")" SUCCESS
    info "配置已导出：$TARGET"
    printf '%s\n' "$TARGET"
}

config_import_archive() {
    local FILE="$1"
    [ -f "$FILE" ] || { error "导入包不存在"; return 1; }
    config_backup_restore "$FILE"
}

config_transfer_menu() {
    while true; do
        print_header "配置导出 / 导入"
        ui_hint "适合迁移到新机器或把当前配置带走备份"
        echo ""; menu_div
        menu_item "1" "导出当前配置" "$GREEN"
        menu_item "2" "导入配置包" "$YELLOW"
        menu_item "0" "返回上级" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择操作 [0-2]: ')" CH
        case "$CH" in
            1)
                local TARGET ARCHIVE_NAME
                read -rp "$(ui_prompt '导出文件路径（默认 /root/vps-config-export.tar.gz）: ')" TARGET
                TARGET=${TARGET:-/root/vps-config-export.tar.gz}
                ARCHIVE_NAME="$(date +%Y%m%d_%H%M%S)_export"
                config_export_archive "$TARGET" "$ARCHIVE_NAME" || true
                ui_pause
                ;;
            2)
                local FILE
                read -rp "$(ui_prompt '输入要导入的 tar.gz 路径: ')" FILE
                config_import_archive "$FILE" || true
                ui_pause
                ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

safety_failed_task_clear() {
    local STATE_FILE="${SAFETY_STATE_FILE:-${VPS_DATA_DIR}/rollback.active}"
    local CONFIRM ARCHIVE="" ARCHIVED=no
    if ! safety_lock_acquire; then
        error "防断联任务正在由其他进程处理，请稍后重试"
        return 1
    fi
    if ! safety_load_pending || [ "${SAFETY_STATUS:-}" != failed ]; then
        safety_lock_release
        warn "当前没有标记为失败的防断联任务"
        return 0
    fi

    warn "检测到失败的防断联任务。解除阻塞不会再次自动应用快照。"
    echo -e "  状态文件：${BOLD}${STATE_FILE}${NC}"
    [ -z "${SAFETY_SNAPSHOT:-}" ] \
        || echo -e "  恢复快照/备份：${BOLD}${SAFETY_SNAPSHOT}${NC}"
    read -rp "  已人工核对并决定解除阻塞时，输入 CLEAR: " CONFIRM
    if [ "$CONFIRM" != CLEAR ]; then
        safety_lock_release
        warn "已取消，失败状态和恢复材料均保留"
        return 0
    fi

    case "${SAFETY_SNAPSHOT:-}" in
        "${VPS_DATA_DIR}"/rollback_*.tar.gz)
            if [ -f "$SAFETY_SNAPSHOT" ]; then
                mkdir -p "$VPS_BACKUP_DIR" 2>/dev/null || true
                ARCHIVE="$VPS_BACKUP_DIR/$(date +%Y%m%d_%H%M%S)_failed-safety_$$_${RANDOM}.tar.gz"
                if cp -p -- "$SAFETY_SNAPSHOT" "$ARCHIVE" 2>/dev/null \
                    && config_archive_validate "$ARCHIVE" >/dev/null 2>&1 \
                    && chmod 600 "$ARCHIVE" 2>/dev/null; then
                    ARCHIVED=yes
                else
                    rm -f -- "$ARCHIVE" 2>/dev/null || true
                    ARCHIVE=""
                    warn "快照无法归档为可恢复配置包，原文件将保留：$SAFETY_SNAPSHOT"
                fi
            fi
            ;;
        "")
            ;;
        *)
            [ ! -e "$SAFETY_SNAPSHOT" ] \
                || info "独立操作备份将保留：$SAFETY_SNAPSHOT"
            ;;
    esac

    safety_artifact_remove "${SAFETY_SCRIPT:-}"
    safety_artifact_remove "${SAFETY_ROOTS_FILE:-}"
    safety_artifact_remove "${SAFETY_SYSCTL_FILE:-}"
    safety_artifact_remove "${SAFETY_IPTABLES_FILE:-}"
    safety_artifact_remove "${SAFETY_IP6TABLES_FILE:-}"
    safety_artifact_remove "${SAFETY_APPLIED_SNAPSHOT:-}"
    safety_artifact_remove "${SAFETY_APPLIED_ROOTS:-}"
    if [ "$ARCHIVED" = yes ]; then
        safety_artifact_remove "${SAFETY_SNAPSHOT:-}"
    fi
    if ! rm -f -- "$STATE_FILE"; then
        safety_lock_release
        error "无法清理失败状态，任务仍保持阻塞"
        return 1
    fi
    SAFETY_PID="" SAFETY_SCRIPT="" SAFETY_ROOTS_FILE="" SAFETY_SYSCTL_FILE=""
    SAFETY_IPTABLES_FILE="" SAFETY_IP6TABLES_FILE=""
    SAFETY_APPLIED_SNAPSHOT="" SAFETY_APPLIED_ROOTS=""
    SAFETY_SNAPSHOT="" SAFETY_STATUS=""
    safety_lock_release
    if [ -n "$ARCHIVE" ]; then
        audit_action "人工解除失败的防断联任务，快照归档为 $(basename "$ARCHIVE")" SUCCESS
        info "失败快照已归档：$ARCHIVE"
    else
        audit_action "人工解除失败的防断联任务" SUCCESS
    fi
    info "失败状态已解除，后续防断联任务可再次启动"
}

rollback_center_menu() {
    while true; do
        local BACKUP_COUNT VERSION_COUNT LATEST_BACKUP LATEST_VERSION SAFETY_STATE_STATUS=""
        BACKUP_COUNT=$(find "$VPS_BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' 2>/dev/null | wc -l | tr -d ' ')
        VERSION_COUNT=$(find "$VPS_VERSION_DIR" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
        LATEST_BACKUP=$(find "$VPS_BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' 2>/dev/null | sort -r | head -1)
        LATEST_VERSION=$(find "$VPS_VERSION_DIR" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | sort -r | head -1)
        print_header "统一回滚中心"
        [ -n "$LATEST_BACKUP" ] && LATEST_BACKUP="${LATEST_BACKUP##*/}" || LATEST_BACKUP="无"
        [ -n "$LATEST_VERSION" ] && LATEST_VERSION="${LATEST_VERSION##*/}" || LATEST_VERSION="无"
        echo -e "  备份包：${BOLD}${BACKUP_COUNT:-0}${NC}   最新配置：${BOLD}${LATEST_BACKUP}${NC}"
        echo -e "  版本包：${BOLD}${VERSION_COUNT:-0}${NC}   最新脚本：${BOLD}${LATEST_VERSION}${NC}"
        if [ -f "${SAFETY_STATE_FILE:-${VPS_DATA_DIR}/rollback.active}" ]; then
            IFS='|' read -r _ _ _ _ _ SAFETY_STATE_STATUS \
                < "${SAFETY_STATE_FILE:-${VPS_DATA_DIR}/rollback.active}" || true
            [ -n "$SAFETY_STATE_STATUS" ] || SAFETY_STATE_STATUS=armed
        fi
        echo -e "  防断联任务：${BOLD}${SAFETY_STATE_STATUS:-无}${NC}"
        echo ""; menu_div
        menu_item "1" "配置备份与恢复" "$GREEN"
        menu_item "2" "配置导出 / 导入" "$CYAN"
        menu_item "3" "脚本版本回滚" "$YELLOW"
        menu_item "4" "处理失败的防断联任务" "$RED"
        menu_item "0" "返回上级" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择操作 [0-4]: ')" CH
        case "$CH" in
            1) config_backup_menu ;;
            2) config_transfer_menu ;;
            3) self_rollback ;;
            4) safety_failed_task_clear ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

monitor_alert_cfg() { echo "/root/.vps-monitor"; }
monitor_alert_script() { echo "/root/vps-monitor-alert.sh"; }
monitor_alert_state() { echo "/root/.vps-monitor.state"; }
monitor_alert_history() { echo "/root/.vps-monitor.history"; }
monitor_alert_metrics() { echo "/root/.vps-monitor.metrics"; }
monitor_alert_lock_file() { echo "${MONITOR_ALERT_LOCK_FILE:-/run/lock/vps-tools-monitor.lock}"; }

MONITOR_CRON_MARKER="# VPS_TOOLS_MONITOR_JOB"
MONITOR_DAILY_CRON_MARKER="# VPS_TOOLS_DAILY_JOB"

monitor_alert_cfg_get() {
    local KEY="$1" CFG; CFG=$(monitor_alert_cfg)
    [ -f "$CFG" ] || return 1
    grep "^${KEY}=" "$CFG" 2>/dev/null | head -1 | cut -d= -f2-
}

monitor_alert_state_get() {
    local KEY="$1" STATE
    STATE=$(monitor_alert_state)
    [ -f "$STATE" ] || return 1
    grep "^${KEY}=" "$STATE" 2>/dev/null | head -1 | cut -d= -f2-
}

monitor_alert_state_set() {
    local KEY="$1" VALUE="$2" STATE STATE_DIR TMP
    STATE=$(monitor_alert_state)
    STATE_DIR=$(dirname "$STATE")
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    TMP=$(mktemp "${STATE}.tmp.XXXXXX") || return 1
    [ -f "$STATE" ] && grep -v "^${KEY}=" "$STATE" > "$TMP" 2>/dev/null || true
    printf '%s=%s\n' "$KEY" "$VALUE" >> "$TMP"
    chmod 600 "$TMP" 2>/dev/null || true
    mv "$TMP" "$STATE" || { rm -f "$TMP"; return 1; }
}

monitor_alert_load_cfg() {
    local RAW_TRAFFIC_RX RAW_TRAFFIC_TX RAW_TRAFFIC_CYCLE_RX RAW_TRAFFIC_CYCLE_TX
    MON_ENABLED=$(monitor_alert_cfg_get ENABLED); MON_ENABLED=${MON_ENABLED:-no}
    MON_DISK_WARN=$(monitor_alert_cfg_get DISK_WARN); MON_DISK_WARN=${MON_DISK_WARN:-85}
    MON_MEM_WARN=$(monitor_alert_cfg_get MEM_WARN); MON_MEM_WARN=${MON_MEM_WARN:-85}
    MON_LOAD_WARN=$(monitor_alert_cfg_get LOAD_WARN); MON_LOAD_WARN=${MON_LOAD_WARN:-}
    MON_BOT_TOKEN=$(monitor_alert_cfg_get BOT_TOKEN)
    MON_CHAT_ID=$(monitor_alert_cfg_get CHAT_ID)
    MON_HOST_LABEL=$(monitor_alert_cfg_get HOST_LABEL)
    MON_TRAFFIC_ENABLED=$(monitor_alert_cfg_get TRAFFIC_ENABLED); MON_TRAFFIC_ENABLED=${MON_TRAFFIC_ENABLED:-no}
    MON_TRAFFIC_LIMIT_GB=$(monitor_alert_cfg_get TRAFFIC_LIMIT_GB); MON_TRAFFIC_LIMIT_GB=${MON_TRAFFIC_LIMIT_GB:-50}
    MON_TRAFFIC_BASELINE_DATE=$(monitor_alert_cfg_get TRAFFIC_BASELINE_DATE)
    MON_TRAFFIC_BASELINE_BYTES=$(monitor_int_normalize "$(monitor_alert_cfg_get TRAFFIC_BASELINE_BYTES)")
    RAW_TRAFFIC_RX=$(monitor_alert_cfg_get TRAFFIC_BASELINE_RX_BYTES)
    RAW_TRAFFIC_TX=$(monitor_alert_cfg_get TRAFFIC_BASELINE_TX_BYTES)
    [ -n "$RAW_TRAFFIC_RX" ] && MON_TRAFFIC_BASELINE_RX_BYTES=$(monitor_int_normalize "$RAW_TRAFFIC_RX") || MON_TRAFFIC_BASELINE_RX_BYTES=
    [ -n "$RAW_TRAFFIC_TX" ] && MON_TRAFFIC_BASELINE_TX_BYTES=$(monitor_int_normalize "$RAW_TRAFFIC_TX") || MON_TRAFFIC_BASELINE_TX_BYTES=
    MON_TRAFFIC_OFFSET_BYTES=$(monitor_int_normalize "$(monitor_alert_cfg_get TRAFFIC_OFFSET_BYTES)")
    MON_TRAFFIC_OFFSET_RX_BYTES=$(monitor_int_normalize "$(monitor_alert_cfg_get TRAFFIC_OFFSET_RX_BYTES)")
    MON_TRAFFIC_OFFSET_TX_BYTES=$(monitor_int_normalize "$(monitor_alert_cfg_get TRAFFIC_OFFSET_TX_BYTES)")
    MON_TRAFFIC_LAST_BYTES=$(monitor_int_normalize "$(monitor_alert_cfg_get TRAFFIC_LAST_BYTES)")
    MON_TRAFFIC_LAST_RX_BYTES=$(monitor_int_normalize "$(monitor_alert_cfg_get TRAFFIC_LAST_RX_BYTES)")
    MON_TRAFFIC_LAST_TX_BYTES=$(monitor_int_normalize "$(monitor_alert_cfg_get TRAFFIC_LAST_TX_BYTES)")
    MON_TRAFFIC_DAILY_BASELINE_RESET=no
    MON_TRAFFIC_CYCLE_BASELINE_RESET=no
    MON_TRAFFIC_RESET_DAY=$(monitor_alert_cfg_get TRAFFIC_RESET_DAY); MON_TRAFFIC_RESET_DAY=${MON_TRAFFIC_RESET_DAY:-1}
    MON_TRAFFIC_CYCLE_BASELINE_DATE=$(monitor_alert_cfg_get TRAFFIC_CYCLE_BASELINE_DATE)
    MON_TRAFFIC_CYCLE_BASELINE_BYTES=$(monitor_int_normalize "$(monitor_alert_cfg_get TRAFFIC_CYCLE_BASELINE_BYTES)")
    RAW_TRAFFIC_CYCLE_RX=$(monitor_alert_cfg_get TRAFFIC_CYCLE_BASELINE_RX_BYTES)
    RAW_TRAFFIC_CYCLE_TX=$(monitor_alert_cfg_get TRAFFIC_CYCLE_BASELINE_TX_BYTES)
    [ -n "$RAW_TRAFFIC_CYCLE_RX" ] && MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES=$(monitor_int_normalize "$RAW_TRAFFIC_CYCLE_RX") || MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES=
    [ -n "$RAW_TRAFFIC_CYCLE_TX" ] && MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES=$(monitor_int_normalize "$RAW_TRAFFIC_CYCLE_TX") || MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES=
    MON_TRAFFIC_CYCLE_OFFSET_BYTES=$(monitor_int_normalize "$(monitor_alert_cfg_get TRAFFIC_CYCLE_OFFSET_BYTES)")
    MON_TRAFFIC_CYCLE_OFFSET_RX_BYTES=$(monitor_int_normalize "$(monitor_alert_cfg_get TRAFFIC_CYCLE_OFFSET_RX_BYTES)")
    MON_TRAFFIC_CYCLE_OFFSET_TX_BYTES=$(monitor_int_normalize "$(monitor_alert_cfg_get TRAFFIC_CYCLE_OFFSET_TX_BYTES)")
    MON_RENEW_ENABLED=$(monitor_alert_cfg_get RENEW_ENABLED); MON_RENEW_ENABLED=${MON_RENEW_ENABLED:-no}
    MON_RENEW_MODE=$(monitor_alert_cfg_get RENEW_MODE); MON_RENEW_MODE=${MON_RENEW_MODE:-interval}
    MON_RENEW_NEXT_DATE=$(monitor_date_normalize "$(monitor_alert_cfg_get RENEW_NEXT_DATE)" 2>/dev/null || true)
    MON_RENEW_INTERVAL_DAYS=$(monitor_alert_cfg_get RENEW_INTERVAL_DAYS); MON_RENEW_INTERVAL_DAYS=${MON_RENEW_INTERVAL_DAYS:-365}
    MON_RENEW_MONTH_DAY=$(monitor_alert_cfg_get RENEW_MONTH_DAY); MON_RENEW_MONTH_DAY=${MON_RENEW_MONTH_DAY:-1}
    MON_RENEW_NOTICE_DAYS=$(monitor_alert_cfg_get RENEW_NOTICE_DAYS); MON_RENEW_NOTICE_DAYS=${MON_RENEW_NOTICE_DAYS:-30,7,3,1}
    MON_RENEW_AUTO_ADVANCE=$(monitor_alert_cfg_get RENEW_AUTO_ADVANCE); MON_RENEW_AUTO_ADVANCE=${MON_RENEW_AUTO_ADVANCE:-no}
    MON_RENEW_LAST_ALERT=$(monitor_alert_cfg_get RENEW_LAST_ALERT)
    MON_DAILY_REPORT_ENABLED=$(monitor_alert_cfg_get DAILY_REPORT_ENABLED); MON_DAILY_REPORT_ENABLED=${MON_DAILY_REPORT_ENABLED:-no}
    MON_DAILY_REPORT_TIME=$(monitor_time_normalize "$(monitor_alert_cfg_get DAILY_REPORT_TIME)" 2>/dev/null || true); MON_DAILY_REPORT_TIME=${MON_DAILY_REPORT_TIME:-08:00}
    MON_ALERT_COOLDOWN_MIN=$(monitor_alert_cfg_get ALERT_COOLDOWN_MIN); MON_ALERT_COOLDOWN_MIN=${MON_ALERT_COOLDOWN_MIN:-30}
    MON_ALERT_SILENCE_START=$(monitor_alert_cfg_get ALERT_SILENCE_START)
    MON_ALERT_SILENCE_END=$(monitor_alert_cfg_get ALERT_SILENCE_END)
    MON_RECOVERY_ENABLED=$(monitor_alert_cfg_get RECOVERY_ENABLED); MON_RECOVERY_ENABLED=${MON_RECOVERY_ENABLED:-yes}
    MON_CHECK_SSH=$(monitor_alert_cfg_get CHECK_SSH); MON_CHECK_SSH=${MON_CHECK_SSH:-yes}
    MON_CHECK_FAIL2BAN=$(monitor_alert_cfg_get CHECK_FAIL2BAN); MON_CHECK_FAIL2BAN=${MON_CHECK_FAIL2BAN:-yes}
    MON_CHECK_DOCKER=$(monitor_alert_cfg_get CHECK_DOCKER); MON_CHECK_DOCKER=${MON_CHECK_DOCKER:-yes}
    MON_CHECK_CADDY=$(monitor_alert_cfg_get CHECK_CADDY); MON_CHECK_CADDY=${MON_CHECK_CADDY:-yes}
    monitor_percent_valid "$MON_DISK_WARN" || MON_DISK_WARN=85
    monitor_percent_valid "$MON_MEM_WARN" || MON_MEM_WARN=85
    [ -z "$MON_LOAD_WARN" ] || monitor_positive_number_valid "$MON_LOAD_WARN" || MON_LOAD_WARN=
    monitor_positive_number_valid "$MON_TRAFFIC_LIMIT_GB" || MON_TRAFFIC_LIMIT_GB=50
    monitor_traffic_reset_day_valid "$MON_TRAFFIC_RESET_DAY" || MON_TRAFFIC_RESET_DAY=1
    case "$MON_RENEW_MODE" in interval|monthly|manual) : ;; *) MON_RENEW_MODE=interval ;; esac
    monitor_positive_int_valid "$MON_RENEW_INTERVAL_DAYS" || MON_RENEW_INTERVAL_DAYS=365
    monitor_traffic_reset_day_valid "$MON_RENEW_MONTH_DAY" || MON_RENEW_MONTH_DAY=1
    monitor_renew_notice_days_valid "$MON_RENEW_NOTICE_DAYS" || MON_RENEW_NOTICE_DAYS=30,7,3,1
    [ "$MON_RENEW_AUTO_ADVANCE" = yes ] || MON_RENEW_AUTO_ADVANCE=no
    case "$MON_RENEW_MODE" in interval|monthly) : ;; *) MON_RENEW_AUTO_ADVANCE=no ;; esac
    monitor_positive_int_valid "$MON_ALERT_COOLDOWN_MIN" || MON_ALERT_COOLDOWN_MIN=30
}

monitor_alert_save_cfg() {
    local CFG CFG_DIR TMP
    CFG=$(monitor_alert_cfg)
    CFG_DIR=$(dirname "$CFG")
    mkdir -p "$CFG_DIR" 2>/dev/null || true
    TMP=$(mktemp "${CFG}.tmp.XXXXXX") || return 1
    cat > "$TMP" <<EOF
ENABLED=${MON_ENABLED:-no}
DISK_WARN=${MON_DISK_WARN:-85}
MEM_WARN=${MON_MEM_WARN:-85}
LOAD_WARN=${MON_LOAD_WARN:-}
BOT_TOKEN=${MON_BOT_TOKEN:-}
CHAT_ID=${MON_CHAT_ID:-}
HOST_LABEL=${MON_HOST_LABEL:-}
TRAFFIC_ENABLED=${MON_TRAFFIC_ENABLED:-no}
TRAFFIC_LIMIT_GB=${MON_TRAFFIC_LIMIT_GB:-50}
TRAFFIC_BASELINE_DATE=${MON_TRAFFIC_BASELINE_DATE:-}
TRAFFIC_BASELINE_BYTES=${MON_TRAFFIC_BASELINE_BYTES:-0}
TRAFFIC_BASELINE_RX_BYTES=${MON_TRAFFIC_BASELINE_RX_BYTES:-}
TRAFFIC_BASELINE_TX_BYTES=${MON_TRAFFIC_BASELINE_TX_BYTES:-}
TRAFFIC_OFFSET_BYTES=${MON_TRAFFIC_OFFSET_BYTES:-0}
TRAFFIC_OFFSET_RX_BYTES=${MON_TRAFFIC_OFFSET_RX_BYTES:-0}
TRAFFIC_OFFSET_TX_BYTES=${MON_TRAFFIC_OFFSET_TX_BYTES:-0}
TRAFFIC_LAST_BYTES=${MON_TRAFFIC_LAST_BYTES:-0}
TRAFFIC_LAST_RX_BYTES=${MON_TRAFFIC_LAST_RX_BYTES:-0}
TRAFFIC_LAST_TX_BYTES=${MON_TRAFFIC_LAST_TX_BYTES:-0}
TRAFFIC_RESET_DAY=${MON_TRAFFIC_RESET_DAY:-1}
TRAFFIC_CYCLE_BASELINE_DATE=${MON_TRAFFIC_CYCLE_BASELINE_DATE:-}
TRAFFIC_CYCLE_BASELINE_BYTES=${MON_TRAFFIC_CYCLE_BASELINE_BYTES:-0}
TRAFFIC_CYCLE_BASELINE_RX_BYTES=${MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES:-}
TRAFFIC_CYCLE_BASELINE_TX_BYTES=${MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES:-}
TRAFFIC_CYCLE_OFFSET_BYTES=${MON_TRAFFIC_CYCLE_OFFSET_BYTES:-0}
TRAFFIC_CYCLE_OFFSET_RX_BYTES=${MON_TRAFFIC_CYCLE_OFFSET_RX_BYTES:-0}
TRAFFIC_CYCLE_OFFSET_TX_BYTES=${MON_TRAFFIC_CYCLE_OFFSET_TX_BYTES:-0}
RENEW_ENABLED=${MON_RENEW_ENABLED:-no}
RENEW_MODE=${MON_RENEW_MODE:-interval}
RENEW_NEXT_DATE=${MON_RENEW_NEXT_DATE:-}
RENEW_INTERVAL_DAYS=${MON_RENEW_INTERVAL_DAYS:-365}
RENEW_MONTH_DAY=${MON_RENEW_MONTH_DAY:-1}
RENEW_NOTICE_DAYS=${MON_RENEW_NOTICE_DAYS:-30,7,3,1}
RENEW_AUTO_ADVANCE=${MON_RENEW_AUTO_ADVANCE:-no}
RENEW_LAST_ALERT=${MON_RENEW_LAST_ALERT:-}
DAILY_REPORT_ENABLED=${MON_DAILY_REPORT_ENABLED:-no}
DAILY_REPORT_TIME=${MON_DAILY_REPORT_TIME:-08:00}
ALERT_COOLDOWN_MIN=${MON_ALERT_COOLDOWN_MIN:-30}
ALERT_SILENCE_START=${MON_ALERT_SILENCE_START:-}
ALERT_SILENCE_END=${MON_ALERT_SILENCE_END:-}
RECOVERY_ENABLED=${MON_RECOVERY_ENABLED:-yes}
CHECK_SSH=${MON_CHECK_SSH:-yes}
CHECK_FAIL2BAN=${MON_CHECK_FAIL2BAN:-yes}
CHECK_DOCKER=${MON_CHECK_DOCKER:-yes}
CHECK_CADDY=${MON_CHECK_CADDY:-yes}
EOF
    chmod 600 "$TMP" 2>/dev/null || true
    mv "$TMP" "$CFG" || { rm -f "$TMP"; return 1; }
}

monitor_time_normalize() {
    local IN="${1:-}" HH MM
    IN=${IN//[[:space:]]/}
    case "$IN" in
        [0-9][0-9]:[0-9][0-9])
            HH=${IN%:*}
            MM=${IN#*:}
            ;;
        [0-9][0-9][0-9][0-9])
            HH=${IN:0:2}
            MM=${IN:2:2}
            ;;
        *)
            return 1
            ;;
    esac
    echo "$HH" | grep -qE '^[0-9]+$' || return 1
    echo "$MM" | grep -qE '^[0-9]+$' || return 1
    [ "$HH" -lt 24 ] || return 1
    [ "$MM" -lt 60 ] || return 1
    printf '%02d:%02d\n' "$((10#$HH))" "$((10#$MM))"
}

monitor_date_normalize() {
    local IN="${1:-}" Y M D
    IN=${IN//[[:space:]]/}
    case "$IN" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
            Y=${IN%%-*}
            M=${IN#*-}; M=${M%-*}
            D=${IN##*-}
            ;;
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
            Y=${IN:0:4}
            M=${IN:4:2}
            D=${IN:6:2}
            ;;
        *)
            return 1
            ;;
    esac
    python3 - "$Y" "$M" "$D" <<'PY'
from datetime import date
import sys
y, m, d = map(int, sys.argv[1:])
print(date(y, m, d).isoformat())
PY
}

monitor_alert_host_label() {
    if [ -n "${MON_HOST_LABEL:-}" ]; then
        echo "$MON_HOST_LABEL"
    else
        hostname 2>/dev/null || echo unknown
    fi
}

monitor_alert_html_escape() {
    local VALUE="${1:-}"
    VALUE=${VALUE//&/\&amp;}
    VALUE=${VALUE//</\&lt;}
    VALUE=${VALUE//>/\&gt;}
    printf '%s' "$VALUE"
}

monitor_alert_host_label_html() {
    monitor_alert_html_escape "$(monitor_alert_host_label)"
}

monitor_alert_set_host_label() {
    local HOST_LABEL_IN
    read -rp "$(ui_prompt "推送中显示的主机名 [${MON_HOST_LABEL:-自动使用 hostname}]: ")" HOST_LABEL_IN
    MON_HOST_LABEL="$HOST_LABEL_IN"
    monitor_alert_save_cfg
    info "主机显示名称已保存"
}

monitor_int_normalize() {
    local VALUE="${1:-0}"
    awk -v value="$VALUE" 'BEGIN {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        if (value ~ /^[-+]?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$/) {
            printf "%.0f\n", value
        } else {
            print 0
        }
    }'
}

monitor_positive_number_valid() {
    local VALUE="${1:-}"
    echo "$VALUE" | grep -qE '^[0-9]+([.][0-9]+)?$' || return 1
    awk -v value="$VALUE" 'BEGIN { exit !(value + 0 > 0) }'
}

monitor_positive_int_valid() {
    local VALUE="${1:-}"
    echo "$VALUE" | grep -qE '^[0-9]+$' || return 1
    [ "$VALUE" -ge 1 ]
}

monitor_percent_valid() {
    local VALUE="${1:-}"
    echo "$VALUE" | grep -qE '^[0-9]+$' || return 1
    [ "$VALUE" -ge 1 ] && [ "$VALUE" -le 100 ]
}

monitor_renew_notice_days_valid() {
    local LIST="${1:-}" ITEM
    echo "$LIST" | grep -qE '^[0-9]+(,[0-9]+)*$' || return 1
    IFS=',' read -r -a MON_NOTICE_LIST <<< "$LIST"
    for ITEM in "${MON_NOTICE_LIST[@]}"; do
        [ "$ITEM" -le 3650 ] || return 1
    done
}

monitor_traffic_interfaces() {
    if [ -n "${MON_TRAFFIC_INTERFACES:-}" ]; then
        printf '%s\n' "$MON_TRAFFIC_INTERFACES" | tr ',' ' ' | awk '{for (i=1; i<=NF; i++) if ($i != "lo" && !seen[$i]++) {printf "%s%s", sep, $i; sep=" "}} END {print ""}'
        return 0
    fi
    command -v ip >/dev/null 2>&1 || return 0
    {
        ip -4 route show default 2>/dev/null || true
        ip -6 route show default 2>/dev/null || true
    } | awk '{for (i=1; i<NF; i++) if ($i == "dev" && $(i+1) != "lo" && !seen[$(i+1)]++) {printf "%s%s", sep, $(i+1); sep=" "}} END {if (sep != "") print ""}'
}

monitor_traffic_totals() {
    local INTERFACES
    INTERFACES=$(monitor_traffic_interfaces)
    if [ -r /proc/net/dev ]; then
        awk -v interfaces="$INTERFACES" 'BEGIN {
            count=split(interfaces, list, /[[:space:]]+/)
            for (i=1; i<=count; i++) if (list[i] != "") wanted[list[i]]=1
        }
        NR>2 {
            gsub(":", "", $1)
            if ($1 != "lo" && (interfaces == "" || wanted[$1])) {rx += $2; tx += $10}
        }
        END {printf "%.0f %.0f %.0f\n", rx+0, tx+0, rx+tx}' /proc/net/dev 2>/dev/null
        return
    fi
    if command -v ip >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
        ip -j -s link show 2>/dev/null | python3 -c '
import sys, json
interfaces = set(sys.argv[1].split())
data = json.load(sys.stdin)
rx_total = 0
tx_total = 0
for item in data:
    ifname = item.get("ifname")
    if ifname == "lo" or (interfaces and ifname not in interfaces):
        continue
    stats = item.get("stats64") or item.get("stats") or {}
    rx = stats.get("rx", {}).get("bytes", 0)
    tx = stats.get("tx", {}).get("bytes", 0)
    rx_total += int(rx)
    tx_total += int(tx)
print(f"{rx_total:d} {tx_total:d} {rx_total + tx_total:d}")
' "$INTERFACES" 2>/dev/null && return
    fi
    echo "0 0 0"
}

monitor_traffic_total_bytes() {
    monitor_traffic_totals | awk '{printf "%.0f\n", $3}'
}

monitor_traffic_ensure_baseline() {
    local TODAY RX TX CURRENT
    TODAY=$(date +%F)
    read -r RX TX CURRENT <<EOF
$(monitor_traffic_totals)
EOF
    if [ -z "${MON_TRAFFIC_BASELINE_DATE:-}" ] || [ "$MON_TRAFFIC_BASELINE_DATE" != "$TODAY" ] || ! echo "${MON_TRAFFIC_BASELINE_BYTES:-0}" | grep -qE '^[0-9]+$'; then
        MON_TRAFFIC_BASELINE_DATE="$TODAY"
        MON_TRAFFIC_BASELINE_BYTES="$CURRENT"
        MON_TRAFFIC_BASELINE_RX_BYTES="$RX"
        MON_TRAFFIC_BASELINE_TX_BYTES="$TX"
        MON_TRAFFIC_OFFSET_BYTES=0
        MON_TRAFFIC_OFFSET_RX_BYTES=0
        MON_TRAFFIC_OFFSET_TX_BYTES=0
        MON_TRAFFIC_DAILY_BASELINE_RESET=yes
        monitor_alert_save_cfg
    fi
}

monitor_traffic_current_cycle_start() {
    local RESET_DAY="$1" TODAY
    TODAY="${2:-$(date +%F)}"
    python3 - "$RESET_DAY" "$TODAY" <<'PY'
from calendar import monthrange
from datetime import date
import sys
reset_day = int(sys.argv[1] or 1)
today = date.fromisoformat(sys.argv[2])
reset_day = max(1, min(31, reset_day))
def anchor(y, m):
    last = monthrange(y, m)[1]
    if reset_day <= last:
        return date(y, m, reset_day)
    if m == 12:
        return date(y + 1, 1, 1)
    return date(y, m + 1, 1)
this_month = anchor(today.year, today.month)
if today >= this_month:
    print(this_month.isoformat())
else:
    y = today.year - 1 if today.month == 1 else today.year
    m = 12 if today.month == 1 else today.month - 1
    print(anchor(y, m).isoformat())
PY
}

monitor_traffic_reset_day_valid() {
    local DAY="${1:-}"
    echo "$DAY" | grep -qE '^[0-9]+$' || return 1
    [ "$DAY" -ge 1 ] && [ "$DAY" -le 31 ]
}

monitor_traffic_cycle_ensure_baseline() {
    [ "${MON_TRAFFIC_ENABLED:-no}" = "yes" ] || return 0
    local TODAY RX TX CURRENT CYCLE_START
    TODAY=$(date +%F)
    read -r RX TX CURRENT <<EOF
$(monitor_traffic_totals)
EOF
    CYCLE_START=$(monitor_traffic_current_cycle_start "${MON_TRAFFIC_RESET_DAY:-1}" "$TODAY")
    if [ -z "${MON_TRAFFIC_CYCLE_BASELINE_DATE:-}" ] || [ "$MON_TRAFFIC_CYCLE_BASELINE_DATE" != "$CYCLE_START" ] || ! echo "${MON_TRAFFIC_CYCLE_BASELINE_BYTES:-0}" | grep -qE '^[0-9]+$'; then
        MON_TRAFFIC_CYCLE_BASELINE_DATE="$CYCLE_START"
        MON_TRAFFIC_CYCLE_BASELINE_BYTES="$CURRENT"
        MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES="$RX"
        MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES="$TX"
        MON_TRAFFIC_CYCLE_OFFSET_BYTES=0
        MON_TRAFFIC_CYCLE_OFFSET_RX_BYTES=0
        MON_TRAFFIC_CYCLE_OFFSET_TX_BYTES=0
        MON_TRAFFIC_CYCLE_BASELINE_RESET=yes
        monitor_alert_save_cfg
    fi
}

monitor_traffic_reset_baselines() {
    local TODAY RX TX CURRENT CYCLE_START
    TODAY=$(date +%F)
    read -r RX TX CURRENT <<EOF
$(monitor_traffic_totals)
EOF
    CYCLE_START=$(monitor_traffic_current_cycle_start "${MON_TRAFFIC_RESET_DAY:-1}" "$TODAY")
    MON_TRAFFIC_BASELINE_DATE="$TODAY"
    MON_TRAFFIC_BASELINE_BYTES="$CURRENT"
    MON_TRAFFIC_BASELINE_RX_BYTES="$RX"
    MON_TRAFFIC_BASELINE_TX_BYTES="$TX"
    MON_TRAFFIC_OFFSET_BYTES=0
    MON_TRAFFIC_OFFSET_RX_BYTES=0
    MON_TRAFFIC_OFFSET_TX_BYTES=0
    MON_TRAFFIC_CYCLE_BASELINE_DATE="$CYCLE_START"
    MON_TRAFFIC_CYCLE_BASELINE_BYTES="$CURRENT"
    MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES="$RX"
    MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES="$TX"
    MON_TRAFFIC_CYCLE_OFFSET_BYTES=0
    MON_TRAFFIC_CYCLE_OFFSET_RX_BYTES=0
    MON_TRAFFIC_CYCLE_OFFSET_TX_BYTES=0
    MON_TRAFFIC_LAST_BYTES="$CURRENT"
    MON_TRAFFIC_LAST_RX_BYTES="$RX"
    MON_TRAFFIC_LAST_TX_BYTES="$TX"
}

monitor_traffic_enable_with_prompt() {
    local CLEAR_OLD
    read -rp "$(ui_prompt '是否清除旧流量记录并从当前流量重新统计？[y/N]: ')" CLEAR_OLD
    MON_TRAFFIC_ENABLED=yes
    if [[ "$CLEAR_OLD" =~ ^[Yy]$ ]]; then
        monitor_traffic_reset_baselines
        info "流量监控已启用，旧记录已清除"
    else
        monitor_traffic_ensure_baseline
        monitor_traffic_cycle_ensure_baseline
        info "流量监控已启用，已保留旧记录"
    fi
    monitor_alert_save_cfg
}

monitor_traffic_used_bytes() {
    monitor_traffic_usage_triplet daily | awk '{printf "%.0f\n", $3}'
}

monitor_traffic_used_gb() {
    awk "BEGIN {printf \"%.2f\", ($1/1024/1024/1024)}"
}

monitor_traffic_delta_bytes() {
    local CURRENT BASE OFFSET DELTA
    CURRENT=$(monitor_int_normalize "${1:-0}")
    BASE=$(monitor_int_normalize "${2:-0}")
    OFFSET=$(monitor_int_normalize "${3:-0}")
    if [ "$CURRENT" -ge "$BASE" ]; then
        DELTA=$((CURRENT - BASE))
    else
        # /proc/net/dev is since-boot. After reboot/interface reset the raw
        # counter can be lower than the saved baseline; keep counting from the
        # new counter instead of pinning this period at 0.
        DELTA="$CURRENT"
    fi
    echo $((DELTA + OFFSET))
}

monitor_traffic_rebase_daily_after_counter_reset() {
    local RX="$1" TX="$2" TOTAL="$3" LAST_RX="$4" LAST_TX="$5" LAST_TOTAL="$6" PREV_RX PREV_TX PREV_TOTAL
    [ -n "${MON_TRAFFIC_BASELINE_DATE:-}" ] || return 0
    [ "${MON_TRAFFIC_DAILY_BASELINE_RESET:-no}" = yes ] && return 0
    if [ -n "${MON_TRAFFIC_BASELINE_RX_BYTES:-}" ] && [ -n "${MON_TRAFFIC_BASELINE_TX_BYTES:-}" ]; then
        PREV_RX=$(monitor_traffic_delta_bytes "$LAST_RX" "${MON_TRAFFIC_BASELINE_RX_BYTES:-0}" "${MON_TRAFFIC_OFFSET_RX_BYTES:-0}")
        PREV_TX=$(monitor_traffic_delta_bytes "$LAST_TX" "${MON_TRAFFIC_BASELINE_TX_BYTES:-0}" "${MON_TRAFFIC_OFFSET_TX_BYTES:-0}")
        PREV_TOTAL=$((PREV_RX + PREV_TX))
        MON_TRAFFIC_OFFSET_RX_BYTES="$PREV_RX"
        MON_TRAFFIC_OFFSET_TX_BYTES="$PREV_TX"
        MON_TRAFFIC_OFFSET_BYTES="$PREV_TOTAL"
        MON_TRAFFIC_BASELINE_RX_BYTES="$RX"
        MON_TRAFFIC_BASELINE_TX_BYTES="$TX"
        MON_TRAFFIC_BASELINE_BYTES="$TOTAL"
    else
        PREV_TOTAL=$(monitor_traffic_delta_bytes "$LAST_TOTAL" "${MON_TRAFFIC_BASELINE_BYTES:-0}" "${MON_TRAFFIC_OFFSET_BYTES:-0}")
        MON_TRAFFIC_OFFSET_BYTES="$PREV_TOTAL"
        MON_TRAFFIC_BASELINE_BYTES="$TOTAL"
    fi
}

monitor_traffic_rebase_cycle_after_counter_reset() {
    local RX="$1" TX="$2" TOTAL="$3" LAST_RX="$4" LAST_TX="$5" LAST_TOTAL="$6" PREV_RX PREV_TX PREV_TOTAL
    [ "${MON_TRAFFIC_ENABLED:-no}" = yes ] || return 0
    [ -n "${MON_TRAFFIC_CYCLE_BASELINE_DATE:-}" ] || return 0
    [ "${MON_TRAFFIC_CYCLE_BASELINE_RESET:-no}" = yes ] && return 0
    if [ -n "${MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES:-}" ] && [ -n "${MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES:-}" ]; then
        PREV_RX=$(monitor_traffic_delta_bytes "$LAST_RX" "${MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES:-0}" "${MON_TRAFFIC_CYCLE_OFFSET_RX_BYTES:-0}")
        PREV_TX=$(monitor_traffic_delta_bytes "$LAST_TX" "${MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES:-0}" "${MON_TRAFFIC_CYCLE_OFFSET_TX_BYTES:-0}")
        PREV_TOTAL=$((PREV_RX + PREV_TX))
        MON_TRAFFIC_CYCLE_OFFSET_RX_BYTES="$PREV_RX"
        MON_TRAFFIC_CYCLE_OFFSET_TX_BYTES="$PREV_TX"
        MON_TRAFFIC_CYCLE_OFFSET_BYTES="$PREV_TOTAL"
        MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES="$RX"
        MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES="$TX"
        MON_TRAFFIC_CYCLE_BASELINE_BYTES="$TOTAL"
    else
        PREV_TOTAL=$(monitor_traffic_delta_bytes "$LAST_TOTAL" "${MON_TRAFFIC_CYCLE_BASELINE_BYTES:-0}" "${MON_TRAFFIC_CYCLE_OFFSET_BYTES:-0}")
        MON_TRAFFIC_CYCLE_OFFSET_BYTES="$PREV_TOTAL"
        MON_TRAFFIC_CYCLE_BASELINE_BYTES="$TOTAL"
    fi
}

monitor_traffic_reconcile_counters() {
    local RX TX TOTAL LAST_RX LAST_TX LAST_TOTAL SAVE=no RESET=no
    RX=$(monitor_int_normalize "${1:-0}")
    TX=$(monitor_int_normalize "${2:-0}")
    TOTAL=$(monitor_int_normalize "${3:-0}")
    LAST_RX=$(monitor_int_normalize "${MON_TRAFFIC_LAST_RX_BYTES:-0}")
    LAST_TX=$(monitor_int_normalize "${MON_TRAFFIC_LAST_TX_BYTES:-0}")
    LAST_TOTAL=$(monitor_int_normalize "${MON_TRAFFIC_LAST_BYTES:-0}")
    [ "$LAST_TOTAL" -gt 0 ] || LAST_TOTAL=$((LAST_RX + LAST_TX))
    if { [ "$LAST_RX" -gt 0 ] && [ "$RX" -lt "$LAST_RX" ]; } || { [ "$LAST_TX" -gt 0 ] && [ "$TX" -lt "$LAST_TX" ]; }; then
        RESET=yes
    fi
    if [ "$RESET" = yes ]; then
        monitor_traffic_rebase_daily_after_counter_reset "$RX" "$TX" "$TOTAL" "$LAST_RX" "$LAST_TX" "$LAST_TOTAL"
        monitor_traffic_rebase_cycle_after_counter_reset "$RX" "$TX" "$TOTAL" "$LAST_RX" "$LAST_TX" "$LAST_TOTAL"
        SAVE=yes
    fi
    if [ "$RX" != "$LAST_RX" ] || [ "$TX" != "$LAST_TX" ] || [ "$TOTAL" != "$LAST_TOTAL" ]; then
        MON_TRAFFIC_LAST_RX_BYTES="$RX"
        MON_TRAFFIC_LAST_TX_BYTES="$TX"
        MON_TRAFFIC_LAST_BYTES="$TOTAL"
        SAVE=yes
    fi
    [ "$SAVE" = yes ] && monitor_alert_save_cfg
}

monitor_traffic_usage_triplet() {
    local KIND="${1:-daily}" RX TX TOTAL BASE_RX BASE_TX BASE_TOTAL OFFSET_RX=0 OFFSET_TX=0 OFFSET_TOTAL=0 USED_RX USED_TX USED_TOTAL HAS_SPLIT=no
    read -r RX TX TOTAL <<EOF
$(monitor_traffic_totals)
EOF
    RX=$(monitor_int_normalize "$RX")
    TX=$(monitor_int_normalize "$TX")
    TOTAL=$(monitor_int_normalize "$TOTAL")
    monitor_traffic_reconcile_counters "$RX" "$TX" "$TOTAL"
    if [ "$KIND" = "cycle" ]; then
        BASE_RX=${MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES:-}
        BASE_TX=${MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES:-}
        BASE_TOTAL=${MON_TRAFFIC_CYCLE_BASELINE_BYTES:-0}
        OFFSET_RX=${MON_TRAFFIC_CYCLE_OFFSET_RX_BYTES:-0}
        OFFSET_TX=${MON_TRAFFIC_CYCLE_OFFSET_TX_BYTES:-0}
        OFFSET_TOTAL=${MON_TRAFFIC_CYCLE_OFFSET_BYTES:-0}
    else
        BASE_RX=${MON_TRAFFIC_BASELINE_RX_BYTES:-}
        BASE_TX=${MON_TRAFFIC_BASELINE_TX_BYTES:-}
        BASE_TOTAL=${MON_TRAFFIC_BASELINE_BYTES:-0}
        OFFSET_RX=${MON_TRAFFIC_OFFSET_RX_BYTES:-0}
        OFFSET_TX=${MON_TRAFFIC_OFFSET_TX_BYTES:-0}
        OFFSET_TOTAL=${MON_TRAFFIC_OFFSET_BYTES:-0}
    fi
    [ -n "${BASE_RX:-}" ] && [ -n "${BASE_TX:-}" ] && HAS_SPLIT=yes
    BASE_RX=$(monitor_int_normalize "${BASE_RX:-0}")
    BASE_TX=$(monitor_int_normalize "${BASE_TX:-0}")
    BASE_TOTAL=$(monitor_int_normalize "${BASE_TOTAL:-0}")
    OFFSET_RX=$(monitor_int_normalize "${OFFSET_RX:-0}")
    OFFSET_TX=$(monitor_int_normalize "${OFFSET_TX:-0}")
    OFFSET_TOTAL=$(monitor_int_normalize "${OFFSET_TOTAL:-0}")
    if [ "$HAS_SPLIT" = "yes" ]; then
        USED_RX=$(monitor_traffic_delta_bytes "$RX" "$BASE_RX" "$OFFSET_RX")
        USED_TX=$(monitor_traffic_delta_bytes "$TX" "$BASE_TX" "$OFFSET_TX")
        USED_TOTAL=$((USED_RX + USED_TX))
    else
        USED_TOTAL=$(monitor_traffic_delta_bytes "$TOTAL" "$BASE_TOTAL" "$OFFSET_TOTAL")
        USED_RX=0
        USED_TX=0
    fi
    printf '%s %s %s\n' "$USED_RX" "$USED_TX" "$USED_TOTAL"
}

monitor_traffic_usage_text() {
    local KIND="${1:-daily}" RX TX TOTAL RX_GB TX_GB TOTAL_GB
    read -r RX TX TOTAL <<EOF
$(monitor_traffic_usage_triplet "$KIND")
EOF
    RX_GB=$(monitor_traffic_used_gb "$RX")
    TX_GB=$(monitor_traffic_used_gb "$TX")
    TOTAL_GB=$(monitor_traffic_used_gb "$TOTAL")
    printf '↓%sG ↑%sG ↓↑%sG' "$RX_GB" "$TX_GB" "$TOTAL_GB"
}

monitor_traffic_current_cycle_used_bytes() {
    monitor_traffic_usage_triplet cycle | awk '{printf "%.0f\n", $3}'
}

monitor_traffic_current_cycle_used_gb() {
    monitor_traffic_used_gb "$1"
}

monitor_traffic_set_cycle_usage_split_gb() {
    local USED_RX_GB="$1" USED_TX_GB="$2" RX TX BASE BASE_RX BASE_TX CYCLE_START USED_RX_BYTES USED_TX_BYTES OFFSET_RX OFFSET_TX
    echo "$USED_RX_GB" | grep -qE '^[0-9]+([.][0-9]+)?$' || return 1
    echo "$USED_TX_GB" | grep -qE '^[0-9]+([.][0-9]+)?$' || return 1
    read -r RX TX _ <<EOF
$(monitor_traffic_totals)
EOF
    RX=$(monitor_int_normalize "$RX")
    TX=$(monitor_int_normalize "$TX")
    USED_RX_BYTES=$(awk "BEGIN {printf \"%.0f\", ($USED_RX_GB*1024*1024*1024)}")
    USED_TX_BYTES=$(awk "BEGIN {printf \"%.0f\", ($USED_TX_GB*1024*1024*1024)}")
    if [ "$USED_RX_BYTES" -gt "$RX" ]; then
        BASE_RX=0
        OFFSET_RX=$((USED_RX_BYTES - RX))
    else
        BASE_RX=$((RX - USED_RX_BYTES))
        OFFSET_RX=0
    fi
    if [ "$USED_TX_BYTES" -gt "$TX" ]; then
        BASE_TX=0
        OFFSET_TX=$((USED_TX_BYTES - TX))
    else
        BASE_TX=$((TX - USED_TX_BYTES))
        OFFSET_TX=0
    fi
    BASE=$((BASE_RX + BASE_TX))
    CYCLE_START=$(monitor_traffic_current_cycle_start "${MON_TRAFFIC_RESET_DAY:-1}" "$(date +%F)")
    MON_TRAFFIC_CYCLE_BASELINE_DATE="$CYCLE_START"
    MON_TRAFFIC_CYCLE_BASELINE_BYTES="$BASE"
    MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES="$BASE_RX"
    MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES="$BASE_TX"
    MON_TRAFFIC_CYCLE_OFFSET_RX_BYTES="$OFFSET_RX"
    MON_TRAFFIC_CYCLE_OFFSET_TX_BYTES="$OFFSET_TX"
    MON_TRAFFIC_CYCLE_OFFSET_BYTES=$((OFFSET_RX + OFFSET_TX))
    MON_TRAFFIC_LAST_RX_BYTES="$RX"
    MON_TRAFFIC_LAST_TX_BYTES="$TX"
    MON_TRAFFIC_LAST_BYTES=$((RX + TX))
    monitor_alert_save_cfg
}

monitor_traffic_set_cycle_usage_gb() {
    monitor_traffic_set_cycle_usage_split_gb 0 "$1"
}

monitor_daily_report_due() {
    local TIME="${1:-08:00}" NOW
    NOW=$(date +%H:%M)
    [ "$NOW" \> "$TIME" ] || [ "$NOW" = "$TIME" ]
}

monitor_alert_daily_report() {
    local HOST TODAY DAILY_TEXT CYCLE_TEXT CYCLE_START RENEW_LEFT NEXT TREND_TEXT
    HOST=$(monitor_alert_host_label_html)
    TODAY=$(date +%F)
    monitor_traffic_ensure_baseline
    monitor_traffic_cycle_ensure_baseline
    DAILY_TEXT=$(monitor_traffic_usage_text daily)
    CYCLE_TEXT=$(monitor_traffic_usage_text cycle)
    TREND_TEXT=$(monitor_alert_trend_summary)
    CYCLE_START="${MON_TRAFFIC_CYCLE_BASELINE_DATE:-$(monitor_traffic_current_cycle_start "${MON_TRAFFIC_RESET_DAY:-1}" "$TODAY")}"
    NEXT="${MON_RENEW_NEXT_DATE:-未设置}"
    if [ -n "${MON_RENEW_NEXT_DATE:-}" ]; then
        RENEW_LEFT=$(monitor_renew_days_left "$MON_RENEW_NEXT_DATE" 2>/dev/null || echo 0)
    else
        RENEW_LEFT="未设置"
    fi
    monitor_alert_notify "📊 <b>VPS 每日日报</b>" "$(cat <<EOF
主机：<code>${HOST}</code>
日期：<code>${TODAY}</code>
今日流量：${DAILY_TEXT}
当前周期：${CYCLE_TEXT}
${TREND_TEXT}
周期起点：<code>${CYCLE_START}</code>
续费日期：<code>${NEXT}</code>
剩余天数：<code>${RENEW_LEFT}</code>
EOF
)"
}

monitor_alert_daily_report_check() {
    [ "${MON_DAILY_REPORT_ENABLED:-no}" = "yes" ] || return 0
    local TODAY CUR_TS LAST_DATE SIG
    TODAY=$(date +%F)
    monitor_daily_report_due "${MON_DAILY_REPORT_TIME:-08:00}" || return 0
    CUR_TS=$(date +%s)
    LAST_DATE=$(monitor_alert_state_get DAILY_REPORT_DATE 2>/dev/null || true)
    SIG=$(printf 'daily|%s|%s' "$(monitor_alert_host_label)" "$TODAY" | sha256sum 2>/dev/null | awk '{print $1}')
    [ "$LAST_DATE" = "$TODAY" ] && return 0
    if ! monitor_alert_daily_report; then
        monitor_alert_history_add ERROR "每日日报发送失败：$TODAY"
        audit_action "发送每日日报失败：$TODAY" FAILURE
        return 1
    fi
    monitor_alert_state_set DAILY_REPORT_DATE "$TODAY"
    monitor_alert_state_set DAILY_REPORT_TS "$CUR_TS"
    monitor_alert_state_set DAILY_REPORT_SIG "$SIG"
    audit_action "发送每日日报：$TODAY" SUCCESS
}

monitor_alert_cron_command() {
    local RUNNER="${SVC_PATH:-${LOCAL_SCRIPT:-$0}}"
    printf '%q --monitor-alert >> /var/log/vps-monitor.log 2>&1' "$RUNNER"
}

monitor_alert_release_lock() {
    local LOCK_DIR="${MONITOR_ALERT_LOCK_DIR:-}" LOCK_PID=""
    [ -n "$LOCK_DIR" ] || return 0
    LOCK_PID=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [ "$LOCK_PID" = "$$" ]; then
        rm -f "$LOCK_DIR/pid" 2>/dev/null || true
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
    MONITOR_ALERT_LOCK_DIR=""
}

monitor_alert_acquire_lock() {
    local LOCK_FILE LOCK_PARENT LOCK_PID="" LOCK_PID_AFTER=""
    LOCK_FILE=$(monitor_alert_lock_file)
    LOCK_PARENT=$(dirname "$LOCK_FILE")
    mkdir -p "$LOCK_PARENT" 2>/dev/null || return 1
    if [ "${MONITOR_ALERT_FORCE_MKDIR_LOCK:-0}" != 1 ] && command -v flock >/dev/null 2>&1; then
        exec 9> "$LOCK_FILE" || return 1
        flock -n 9
        return
    fi
    MONITOR_ALERT_LOCK_DIR="${LOCK_FILE}.d"
    if ! mkdir "$MONITOR_ALERT_LOCK_DIR" 2>/dev/null; then
        LOCK_PID=$(cat "$MONITOR_ALERT_LOCK_DIR/pid" 2>/dev/null || true)
        if [[ "$LOCK_PID" =~ ^[0-9]+$ ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
            return 1
        fi
        sleep 1
        LOCK_PID_AFTER=$(cat "$MONITOR_ALERT_LOCK_DIR/pid" 2>/dev/null || true)
        if [[ "$LOCK_PID_AFTER" =~ ^[0-9]+$ ]] && kill -0 "$LOCK_PID_AFTER" 2>/dev/null; then
            return 1
        fi
        [ "$LOCK_PID" = "$LOCK_PID_AFTER" ] || return 1
        rm -f "$MONITOR_ALERT_LOCK_DIR/pid" 2>/dev/null || return 1
        rmdir "$MONITOR_ALERT_LOCK_DIR" 2>/dev/null || return 1
        mkdir "$MONITOR_ALERT_LOCK_DIR" 2>/dev/null || return 1
    fi
    if ! printf '%s\n' "$$" > "$MONITOR_ALERT_LOCK_DIR/pid"; then
        rm -f "$MONITOR_ALERT_LOCK_DIR/pid" 2>/dev/null || true
        rmdir "$MONITOR_ALERT_LOCK_DIR" 2>/dev/null || true
        return 1
    fi
    trap monitor_alert_release_lock EXIT
}

monitor_alert_daily_cron_expr() {
    local T="${1:-08:00}" HH MM
    T=$(monitor_time_normalize "$T" 2>/dev/null || echo "08:00")
    HH=${T%:*}
    MM=${T#*:}
    printf '%s %s * * *' "$((10#$MM))" "$((10#$HH))"
}

monitor_alert_cron_without_managed() {
    awk -v monitor="$MONITOR_CRON_MARKER" \
        -v daily="$MONITOR_DAILY_CRON_MARKER" '
        index($0, monitor) == 0 \
            && index($0, daily) == 0 \
            && index($0, "# vps-monitor-alert") == 0 \
            && index($0, "# vps-monitor-daily-report") == 0 {
                print
            }
    '
}

monitor_alert_restore_crontab() {
    local BACKUP="$1" HAD_CRONTAB="$2"
    if [ "$HAD_CRONTAB" = yes ]; then
        crontab "$BACKUP" >/dev/null 2>&1
    else
        crontab -r >/dev/null 2>&1 || {
            # Several cron implementations return non-zero when no table
            # exists, which is already the desired restored state.
            ! crontab -l >/dev/null 2>&1
        }
    fi
}

monitor_alert_install_cron() {
    local CMD DAILY_EXPR RUNNER="${SVC_PATH:-${LOCAL_SCRIPT:-}}"
    local CRON_BACKUP="" CRON_NEW="" CRON_ERROR="" CRON_ERROR_TEXT="" HAD_CRONTAB=no
    if [ -n "${SVC_PATH:-}" ]; then
        [ -x "$SVC_PATH" ] || { error "定时监控执行脚本不可用：$SVC_PATH"; return 1; }
    elif command -v self_ensure_local_runner >/dev/null 2>&1; then
        self_ensure_local_runner '--monitor-alert)' \
            || { error "无法准备定时监控执行脚本"; return 1; }
    elif [ -z "$RUNNER" ] || [ ! -x "$RUNNER" ]; then
        error "定时监控执行脚本不存在，请先安装本地脚本"
        return 1
    fi
    command -v crontab >/dev/null 2>&1 || ddns_ensure_cron >/dev/null 2>&1 || true
    command -v crontab >/dev/null 2>&1 || { warn "未检测到 crontab，无法安装定时监控"; return 1; }
    CRON_BACKUP=$(mktemp) || { error "无法创建 crontab 备份"; return 1; }
    CRON_NEW=$(mktemp) || {
        rm -f "$CRON_BACKUP"
        error "无法创建 crontab 候选文件"
        return 1
    }
    CRON_ERROR=$(mktemp) || {
        rm -f "$CRON_BACKUP" "$CRON_NEW"
        error "无法创建 crontab 错误日志"
        return 1
    }
    if LC_ALL=C crontab -l > "$CRON_BACKUP" 2> "$CRON_ERROR"; then
        HAD_CRONTAB=yes
    else
        CRON_ERROR_TEXT=$(tr '[:upper:]' '[:lower:]' < "$CRON_ERROR" 2>/dev/null || true)
        case "$CRON_ERROR_TEXT" in
            *"no crontab for"*)
                : > "$CRON_BACKUP"
                ;;
            *)
                rm -f "$CRON_BACKUP" "$CRON_NEW" "$CRON_ERROR"
                error "无法读取现有 crontab，已拒绝覆盖"
                return 1
                ;;
        esac
    fi
    rm -f "$CRON_ERROR"
    CMD=$(monitor_alert_cron_command)
    if ! monitor_alert_cron_without_managed < "$CRON_BACKUP" > "$CRON_NEW"; then
        rm -f "$CRON_BACKUP" "$CRON_NEW"
        error "无法生成监控 crontab 候选"
        return 1
    fi
    printf '*/10 * * * * %s %s\n' "$CMD" "$MONITOR_CRON_MARKER" >> "$CRON_NEW" || {
        rm -f "$CRON_BACKUP" "$CRON_NEW"
        error "无法写入监控 crontab 候选"
        return 1
    }
    if [ "${MON_DAILY_REPORT_ENABLED:-no}" = "yes" ]; then
        DAILY_EXPR=$(monitor_alert_daily_cron_expr "${MON_DAILY_REPORT_TIME:-08:00}")
        printf '%s %s %s\n' "$DAILY_EXPR" "$CMD" "$MONITOR_DAILY_CRON_MARKER" >> "$CRON_NEW" || {
            rm -f "$CRON_BACKUP" "$CRON_NEW"
            error "无法写入日报 crontab 候选"
            return 1
        }
    fi
    if ! crontab "$CRON_NEW"; then
        if monitor_alert_restore_crontab "$CRON_BACKUP" "$HAD_CRONTAB"; then
            error "写入监控 crontab 失败，已恢复原 crontab"
        else
            error "写入监控 crontab 失败，且原 crontab 恢复失败，请立即检查"
        fi
        rm -f "$CRON_BACKUP" "$CRON_NEW"
        return 1
    fi
    if ! ddns_start_cron_service >/dev/null 2>&1; then
        if monitor_alert_restore_crontab "$CRON_BACKUP" "$HAD_CRONTAB"; then
            error "cron 服务未能启动，已恢复原 crontab"
        else
            error "cron 服务未能启动，且原 crontab 恢复失败，请立即检查"
        fi
        rm -f "$CRON_BACKUP" "$CRON_NEW"
        return 1
    fi
    rm -f "$CRON_BACKUP" "$CRON_NEW"
    return 0
}

monitor_alert_remove_cron() {
    local CRON_BACKUP CRON_NEW CRON_ERROR CRON_ERROR_TEXT HAD_CRONTAB=no
    command -v crontab >/dev/null 2>&1 || return 0
    CRON_BACKUP=$(mktemp) || return 1
    CRON_NEW=$(mktemp) || { rm -f "$CRON_BACKUP"; return 1; }
    CRON_ERROR=$(mktemp) || {
        rm -f "$CRON_BACKUP" "$CRON_NEW"
        return 1
    }
    if LC_ALL=C crontab -l > "$CRON_BACKUP" 2> "$CRON_ERROR"; then
        HAD_CRONTAB=yes
    else
        CRON_ERROR_TEXT=$(tr '[:upper:]' '[:lower:]' < "$CRON_ERROR" 2>/dev/null || true)
        case "$CRON_ERROR_TEXT" in
            *"no crontab for"*)
                rm -f "$CRON_BACKUP" "$CRON_NEW" "$CRON_ERROR"
                return 0
                ;;
            *)
                rm -f "$CRON_BACKUP" "$CRON_NEW" "$CRON_ERROR"
                error "无法读取现有 crontab，已拒绝覆盖"
                return 1
                ;;
        esac
    fi
    rm -f "$CRON_ERROR"
    if ! monitor_alert_cron_without_managed < "$CRON_BACKUP" > "$CRON_NEW"; then
        rm -f "$CRON_BACKUP" "$CRON_NEW"
        return 1
    fi
    if cmp -s "$CRON_BACKUP" "$CRON_NEW"; then
        rm -f "$CRON_BACKUP" "$CRON_NEW"
        return 0
    fi
    if ! crontab "$CRON_NEW"; then
        monitor_alert_restore_crontab "$CRON_BACKUP" "$HAD_CRONTAB" >/dev/null 2>&1 || true
        rm -f "$CRON_BACKUP" "$CRON_NEW"
        error "移除监控 crontab 失败，已尝试恢复原配置"
        return 1
    fi
    rm -f "$CRON_BACKUP" "$CRON_NEW"
}

monitor_alert_cron_status() {
    local KIND="${1:-monitor}"
    command -v crontab >/dev/null 2>&1 || { echo "crontab 不可用"; return 0; }
    case "$KIND" in
        daily)
            crontab -l 2>/dev/null | grep -Fq -e "$MONITOR_DAILY_CRON_MARKER" -e "# vps-monitor-daily-report" && echo "已安装" || echo "未安装"
            ;;
        *)
            crontab -l 2>/dev/null | grep -Fq -e "$MONITOR_CRON_MARKER" -e "# vps-monitor-alert" && echo "已安装" || echo "未安装"
            ;;
    esac
}

monitor_alert_next_daily_time() {
    [ "${MON_DAILY_REPORT_ENABLED:-no}" = "yes" ] || { echo "未启用"; return 0; }
    python3 - "${MON_DAILY_REPORT_TIME:-08:00}" <<'PY'
from datetime import datetime, timedelta
import sys
t = sys.argv[1] or "08:00"
hour, minute = map(int, t.split(":"))
now = datetime.now()
target = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
if target <= now:
    target += timedelta(days=1)
label = "今天" if target.date() == now.date() else "明天"
print(f"{label} {target:%H:%M}")
PY
}

monitor_alert_configured_without_cron() {
    [ "${MON_ENABLED:-no}" = yes ] && return 1
    [ "${MON_DAILY_REPORT_ENABLED:-no}" = yes ] && return 0
    [ "${MON_TRAFFIC_ENABLED:-no}" = yes ] && return 0
    [ "${MON_RENEW_ENABLED:-no}" = yes ] && return 0
    return 1
}

monitor_alert_service_menu() {
    local ACTION_LABEL
    while true; do
        monitor_alert_load_cfg
        print_header "后台监控"
        echo -e "  状态：${BOLD}$([ "$MON_ENABLED" = yes ] && echo '已启用' || echo '未启用')${NC}"
        echo -e "  监控 Cron：${BOLD}$(monitor_alert_cron_status monitor)${NC}"
        echo -e "  日报 Cron：${BOLD}$(monitor_alert_cron_status daily)${NC}"
        echo -e "  下次日报：${BOLD}$(monitor_alert_next_daily_time)${NC}"
        echo ""
        [ "$MON_ENABLED" != yes ] && monitor_alert_configured_without_cron && warn "已配置日报 / 流量 / 续费，但后台监控未启用，定时推送不会执行。"
        menu_div
        ACTION_LABEL=$([ "$MON_ENABLED" = yes ] && echo "重装 / 刷新后台监控" || echo "启用后台监控")
        menu_item "1" "$ACTION_LABEL" "$GREEN"
        menu_item "2" "关闭后台监控" "$YELLOW"
        menu_item "0" "返回上级" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择操作 [0-2]: ')" CH
        case "$CH" in
            1)
                MON_ENABLED=yes
                monitor_alert_save_cfg
                if monitor_alert_install_cron; then
                    info "后台监控已启用 / 刷新"
                else
                    MON_ENABLED=no
                    monitor_alert_save_cfg
                    error "后台监控启用失败"
                fi
                ;;
            2)
                MON_ENABLED=no
                monitor_alert_save_cfg
                monitor_alert_remove_cron
                info "后台监控已关闭"
                ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

monitor_alert_home_menu() {
    while true; do
        monitor_alert_load_cfg
        print_header "监控告警中心"
        monitor_traffic_ensure_baseline
        monitor_traffic_cycle_ensure_baseline
        local DAILY_TEXT CYCLE_TEXT HOST
        HOST=$(monitor_alert_host_label)
        DAILY_TEXT=$(monitor_traffic_usage_text daily)
        CYCLE_TEXT=$(monitor_traffic_usage_text cycle)
        echo -e "  主机：${BOLD}${HOST}${NC}"
        echo -e "  后台监控：${BOLD}$([ "$MON_ENABLED" = yes ] && echo "已启用 · $(monitor_alert_cron_status monitor)" || echo '未启用')${NC}"
        echo -e "  通知：${BOLD}$([ -n "$MON_BOT_TOKEN" ] && [ -n "$MON_CHAT_ID" ] && echo '已配置' || echo '未配置')${NC}"
        echo -e "  每日日报：${BOLD}$([ "$MON_DAILY_REPORT_ENABLED" = yes ] && echo "${MON_DAILY_REPORT_TIME} · $(monitor_alert_cron_status daily)" || echo '未启用')${NC}"
        echo -e "  今日流量：${DAILY_TEXT}"
        echo -e "  当前周期：${CYCLE_TEXT}"
        echo -e "  续费提醒：${BOLD}$([ "$MON_RENEW_ENABLED" = yes ] && echo "${MON_RENEW_MODE} · ${MON_RENEW_NEXT_DATE:-未设置}" || echo '未启用')${NC}"
        echo -e "  下次日报：${BOLD}$(monitor_alert_next_daily_time)${NC}"
        echo ""
        [ "$MON_ENABLED" != yes ] && monitor_alert_configured_without_cron && warn "已配置日报 / 流量 / 续费，但后台监控未启用，定时推送不会执行。"
        menu_div
        menu_item "1" "快速启用监控" "$GREEN"
        menu_item "2" "通知设置" "$GREEN"
        menu_item "3" "每日日报" "$CYAN"
        menu_item "4" "流量监控" "$CYAN"
        menu_item "5" "续费提醒" "$YELLOW"
        menu_item "6" "资源告警" "$YELLOW"
        menu_item "7" "高级策略" "$GREEN"
        menu_item "8" "最近记录" "$CYAN"
        menu_item "9" "后台监控" "$GREEN"
        menu_item "0" "返回上级" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择操作 [0-9]: ')" CH
        case "$CH" in
            1) monitor_alert_quick_setup_menu ;;
            2) monitor_alert_notify_menu ;;
            3) monitor_alert_daily_menu ;;
            4) monitor_alert_traffic_menu ;;
            5) monitor_alert_renew_menu ;;
            6) monitor_alert_resource_menu ;;
            7) monitor_alert_advanced_menu ;;
            8) monitor_alert_history_view; ui_pause ;;
            9) monitor_alert_service_menu ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

monitor_renew_next_date() {
    local MODE="$1" BASE="$2" DAYS="$3" MONTH_DAY="$4"
    python3 - "$MODE" "$BASE" "$DAYS" "$MONTH_DAY" <<'PY'
from calendar import monthrange
from datetime import date, datetime, timedelta
import sys
mode, base, days, month_day = sys.argv[1:]
base_date = datetime.strptime(base, "%Y-%m-%d").date()
if mode == "interval":
    print((base_date + timedelta(days=int(days))).isoformat())
elif mode == "monthly":
    target_day = max(1, min(31, int(month_day or 1)))
    y, m = base_date.year, base_date.month
    for _ in range(24):
        last = monthrange(y, m)[1]
        cand = date(y, m, min(target_day, last))
        if cand > base_date:
            print(cand.isoformat())
            break
        m += 1
        if m > 12:
            y += 1
            m = 1
else:
    print(base)
PY
}

monitor_renew_future_date() {
    local MODE="$1" BASE="$2" DAYS="$3" MONTH_DAY="$4" TODAY="$5"
    python3 - "$MODE" "$BASE" "$DAYS" "$MONTH_DAY" "$TODAY" <<'PY'
from calendar import monthrange
from datetime import date, datetime, timedelta
import sys

mode, base, days, month_day, today = sys.argv[1:]
base_date = datetime.strptime(base, "%Y-%m-%d").date()
today_date = datetime.strptime(today, "%Y-%m-%d").date()
if today_date <= base_date:
    raise SystemExit(1)

if mode == "interval":
    period = int(days)
    if period < 1:
        raise SystemExit(1)
    elapsed = (today_date - base_date).days
    periods = (elapsed + period - 1) // period
    print((base_date + timedelta(days=periods * period)).isoformat())
elif mode == "monthly":
    target_day = max(1, min(31, int(month_day or 1)))
    year, month = today_date.year, today_date.month
    for _ in range(24):
        candidate = date(year, month, min(target_day, monthrange(year, month)[1]))
        if candidate >= today_date:
            print(candidate.isoformat())
            break
        month += 1
        if month > 12:
            year += 1
            month = 1
else:
    raise SystemExit(1)
PY
}

monitor_renew_days_left() {
    local NEXT="$1"
    python3 - "$NEXT" <<'PY'
from datetime import date, datetime
import sys
next_date = datetime.strptime(sys.argv[1], "%Y-%m-%d").date()
print((next_date - date.today()).days)
PY
}

monitor_renew_notice_match() {
    local DAYS_LEFT="$1" LIST="${2:-30,7,3,1}" I
    [ "$DAYS_LEFT" -le 0 ] && return 0
    IFS=',' read -r -a MON_LIST <<< "$LIST"
    for I in "${MON_LIST[@]}"; do
        [ -n "$I" ] || continue
        [ "$DAYS_LEFT" -eq "$I" ] && return 0
    done
    return 1
}

monitor_alert_notify() {
    local TITLE="$1" BODY="$2" BOT CHAT
    BOT=$(monitor_alert_cfg_get BOT_TOKEN)
    CHAT=$(monitor_alert_cfg_get CHAT_ID)
    [ -n "$BOT" ] && [ -n "$CHAT" ] || return 1
    local TEXT
    TEXT=$(printf '%s\n%b' "$TITLE" "$BODY")
    monitor_alert_telegram_send "$BOT" "$CHAT" "$TEXT"
}

monitor_alert_telegram_send() {
    local BOT="$1" CHAT="$2" TEXT="$3"
    MONITOR_TG_BOT="$BOT" MONITOR_TG_CHAT="$CHAT" MONITOR_TG_TEXT="$TEXT" python3 <<'PY'
import json
import os
import sys
import urllib.parse
import urllib.request

token = os.environ["MONITOR_TG_BOT"]
payload = urllib.parse.urlencode({
    "chat_id": os.environ["MONITOR_TG_CHAT"],
    "text": os.environ["MONITOR_TG_TEXT"],
    "parse_mode": "HTML",
}).encode()
request = urllib.request.Request(
    f"https://api.telegram.org/bot{token}/sendMessage",
    data=payload,
    headers={"User-Agent": "VPS-TOOLS-Monitor/1"},
)
try:
    with urllib.request.urlopen(request, timeout=15) as response:
        result = json.loads(response.read().decode())
except Exception as exc:
    print(f"Telegram request failed: {exc}", file=sys.stderr)
    raise SystemExit(1)
if not result.get("ok"):
    print(f"Telegram API rejected message: {result.get('description', 'unknown error')}", file=sys.stderr)
    raise SystemExit(1)
PY
}

monitor_alert_history_add() {
    local KIND="$1" MSG="$2" HIST TMP
    HIST=$(monitor_alert_history)
    mkdir -p "$(dirname "$HIST")" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$KIND" "$MSG" >> "$HIST" 2>/dev/null || true
    TMP=$(mktemp "${HIST}.tmp.XXXXXX") || return 0
    tail -n 80 "$HIST" > "$TMP" 2>/dev/null && mv "$TMP" "$HIST" 2>/dev/null || rm -f "$TMP"
    chmod 600 "$HIST" 2>/dev/null || true
}

monitor_alert_history_view() {
    print_header "最近告警记录"
    local HIST; HIST=$(monitor_alert_history)
    if [ -s "$HIST" ]; then
        tail -50 "$HIST" | column -t -s $'\t' 2>/dev/null || tail -50 "$HIST"
    else
        warn "暂无告警记录"
    fi
}

monitor_alert_cooldown_seconds() {
    local MIN="${MON_ALERT_COOLDOWN_MIN:-30}"
    echo "$MIN" | grep -qE '^[0-9]+$' || MIN=30
    [ "$MIN" -lt 1 ] && MIN=1
    echo $((MIN * 60))
}

monitor_alert_time_to_minutes() {
    local T="$1" H M
    T=$(monitor_time_normalize "$T" 2>/dev/null || true)
    [ -n "$T" ] || return 1
    H=${T%:*}
    M=${T#*:}
    echo $((10#$H * 60 + 10#$M))
}

monitor_alert_in_silence() {
    [ -n "${MON_ALERT_SILENCE_START:-}" ] && [ -n "${MON_ALERT_SILENCE_END:-}" ] || return 1
    local START END NOW HH MM
    START=$(monitor_alert_time_to_minutes "$MON_ALERT_SILENCE_START" 2>/dev/null || true)
    END=$(monitor_alert_time_to_minutes "$MON_ALERT_SILENCE_END" 2>/dev/null || true)
    [ -n "$START" ] && [ -n "$END" ] || return 1
    HH=$(date +%H)
    MM=$(date +%M)
    NOW=$((10#$HH * 60 + 10#$MM))
    if [ "$START" -le "$END" ]; then
        [ "$NOW" -ge "$START" ] && [ "$NOW" -lt "$END" ]
    else
        [ "$NOW" -ge "$START" ] || [ "$NOW" -lt "$END" ]
    fi
}

monitor_alert_level_label() {
    case "${1:-warning}" in
        critical) echo "严重" ;;
        notice) echo "提醒" ;;
        *) echo "警告" ;;
    esac
}

monitor_alert_level_icon() {
    case "${1:-warning}" in
        critical) echo "🚨" ;;
        notice) echo "ℹ️" ;;
        *) echo "⚠️" ;;
    esac
}

monitor_alert_level_rank() {
    case "${1:-warning}" in
        critical) echo 3 ;;
        warning) echo 2 ;;
        notice) echo 1 ;;
        *) echo 0 ;;
    esac
}

monitor_alert_worst_level() {
    local CUR="${1:-}" NEXT="${2:-warning}"
    [ "$(monitor_alert_level_rank "$NEXT")" -gt "$(monitor_alert_level_rank "$CUR")" ] && echo "$NEXT" || echo "$CUR"
}

monitor_alert_metrics_sample() {
    local METRICS TS DISK_PCT MEM_PCT LOAD1 RX TX TOTAL LAST_TS TMP
    METRICS=$(monitor_alert_metrics)
    mkdir -p "$(dirname "$METRICS")" 2>/dev/null || true
    TS=$(date +%s)
    LAST_TS=$(tail -n 1 "$METRICS" 2>/dev/null | awk '{print $1}')
    LAST_TS=$(monitor_int_normalize "${LAST_TS:-0}")
    [ $((TS - LAST_TS)) -lt 300 ] && return 0
    DISK_PCT=$(df -P / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5+0}')
    MEM_PCT=$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {if (t>0) printf "%.0f", (t-a)*100/t; else print 0}' /proc/meminfo 2>/dev/null)
    LOAD1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
    read -r RX TX TOTAL <<EOF
$(monitor_traffic_totals)
EOF
    printf '%s %s %s %s %s\n' "$TS" "${DISK_PCT:-0}" "${MEM_PCT:-0}" "${LOAD1:-0}" "$(monitor_int_normalize "${TOTAL:-0}")" >> "$METRICS" 2>/dev/null || true
    TMP=$(mktemp "${METRICS}.tmp.XXXXXX") || return 0
    tail -n 1500 "$METRICS" > "$TMP" 2>/dev/null && mv "$TMP" "$METRICS" 2>/dev/null || rm -f "$TMP"
    chmod 600 "$METRICS" 2>/dev/null || true
}

monitor_alert_trend_line() {
    local LABEL="$1" SECONDS="$2" METRICS NOW
    METRICS=$(monitor_alert_metrics)
    [ -s "$METRICS" ] || { printf '%s：数据积累中\n' "$LABEL"; return; }
    NOW=$(date +%s)
    awk -v label="$LABEL" -v since="$((NOW - SECONDS))" '
        $1 >= since {
            if (!seen) {
                first_disk=$2; first_mem=$3; first_load=$4; first_traffic=$5; seen=1
            } else {
                delta=$5-prev_traffic
                if (delta < 0) delta=$5
                if (delta > 0) traffic_delta+=delta
            }
            last_disk=$2; last_mem=$3; last_load=$4; last_traffic=$5; count++
            prev_traffic=$5
        }
        END {
            if (count < 2) {
                printf "%s：数据积累中\n", label
                exit
            }
            printf "%s：磁盘 %+d%% 内存 %+d%% 负载 %+.2f 流量 +%.2fG\n", label, last_disk-first_disk, last_mem-first_mem, last_load-first_load, traffic_delta/1024/1024/1024
        }
    ' "$METRICS"
}

monitor_alert_trend_summary() {
    monitor_alert_metrics_sample
    monitor_alert_trend_line "24小时趋势" 86400
    monitor_alert_trend_line "7天趋势" 604800
}

monitor_alert_service_state() {
    local SVC="$1"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl is-active --quiet "$SVC" 2>/dev/null && echo running || echo stopped
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$SVC" status >/dev/null 2>&1 && echo running || echo stopped
    else
        echo unknown
    fi
}

monitor_alert_any_service_state() {
    local SVC STATE SEEN_STOPPED=no
    for SVC in "$@"; do
        STATE=$(monitor_alert_service_state "$SVC")
        [ "$STATE" = running ] && { echo running; return 0; }
        [ "$STATE" = stopped ] && SEEN_STOPPED=yes
    done
    [ "$SEEN_STOPPED" = yes ] && echo stopped || echo unknown
}

monitor_alert_ssh_state() {
    monitor_alert_any_service_state ssh sshd
}

monitor_alert_resource_check() {
    local HOST DISK_PCT MEM_PCT LOAD1 CPU_COUNT ISSUES="" ISSUE_KEYS="" LEVEL=notice
    HOST=$(monitor_alert_host_label_html)
    DISK_PCT=$(df -P / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5+0}')
    MEM_PCT=$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {if (t>0) printf "%.0f", (t-a)*100/t; else print 0}' /proc/meminfo 2>/dev/null)
    LOAD1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
    CPU_COUNT=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)
    local LOAD_WARN_VALUE="${MON_LOAD_WARN:-}"
    [ -n "$LOAD_WARN_VALUE" ] || LOAD_WARN_VALUE=$(awk "BEGIN{printf \"%.1f\", $CPU_COUNT*1.5}")

    if [ "${DISK_PCT:-0}" -ge "${MON_DISK_WARN:-85}" ]; then
        ISSUES="${ISSUES}磁盘 ${DISK_PCT}%  "
        ISSUE_KEYS="${ISSUE_KEYS}disk,"
        [ "${DISK_PCT:-0}" -ge 95 ] && LEVEL=$(monitor_alert_worst_level "$LEVEL" critical) || LEVEL=$(monitor_alert_worst_level "$LEVEL" warning)
    fi
    if [ "${MEM_PCT:-0}" -ge "${MON_MEM_WARN:-85}" ]; then
        ISSUES="${ISSUES}内存 ${MEM_PCT}%  "
        ISSUE_KEYS="${ISSUE_KEYS}memory,"
        [ "${MEM_PCT:-0}" -ge 95 ] && LEVEL=$(monitor_alert_worst_level "$LEVEL" critical) || LEVEL=$(monitor_alert_worst_level "$LEVEL" warning)
    fi
    if awk -v current="${LOAD1:-0}" -v threshold="$LOAD_WARN_VALUE" 'BEGIN{exit !(current + 0 >= threshold + 0)}'; then
        ISSUES="${ISSUES}负载 ${LOAD1}  "
        ISSUE_KEYS="${ISSUE_KEYS}load,"
        if awk -v current="${LOAD1:-0}" -v threshold="$LOAD_WARN_VALUE" 'BEGIN{exit !(current + 0 >= (threshold + 0) * 2)}'; then
            LEVEL=$(monitor_alert_worst_level "$LEVEL" critical)
        else
            LEVEL=$(monitor_alert_worst_level "$LEVEL" warning)
        fi
    fi
    if [ "${MON_CHECK_SSH:-yes}" = yes ] && [ "$(monitor_alert_ssh_state)" != running ]; then
        ISSUES="${ISSUES}SSH 服务异常  "
        ISSUE_KEYS="${ISSUE_KEYS}ssh,"
        LEVEL=$(monitor_alert_worst_level "$LEVEL" critical)
    fi
    if [ "${MON_CHECK_FAIL2BAN:-yes}" = yes ] && command -v fail2ban-client >/dev/null 2>&1 && [ "$(f2b_status 2>/dev/null || echo stopped)" != running ]; then
        ISSUES="${ISSUES}Fail2ban 异常  "
        ISSUE_KEYS="${ISSUE_KEYS}fail2ban,"
        LEVEL=$(monitor_alert_worst_level "$LEVEL" warning)
    fi
    if [ "${MON_CHECK_DOCKER:-yes}" = yes ] && command -v docker >/dev/null 2>&1 && [ "$(docker_status 2>/dev/null || echo not_installed)" = stopped ]; then
        ISSUES="${ISSUES}Docker 服务异常  "
        ISSUE_KEYS="${ISSUE_KEYS}docker,"
        LEVEL=$(monitor_alert_worst_level "$LEVEL" warning)
    fi
    if [ "${MON_CHECK_CADDY:-yes}" = yes ] && command -v caddy >/dev/null 2>&1 && [ "$(caddy_status 2>/dev/null || echo not_installed)" = stopped ]; then
        ISSUES="${ISSUES}Caddy 服务异常  "
        ISSUE_KEYS="${ISSUE_KEYS}caddy,"
        LEVEL=$(monitor_alert_worst_level "$LEVEL" warning)
    fi
    local PREV_STATE LAST_SIG LAST_TS CUR_TS SIG COOLDOWN
    CUR_TS=$(date +%s)
    COOLDOWN=$(monitor_alert_cooldown_seconds)
    PREV_STATE=$(monitor_alert_state_get RESOURCE_STATE 2>/dev/null || echo ok)
    LAST_SIG=$(monitor_alert_state_get RESOURCE_SIG 2>/dev/null || true)
    LAST_TS=$(monitor_alert_state_get RESOURCE_TS 2>/dev/null || echo 0)
    LAST_TS=$(monitor_int_normalize "${LAST_TS:-0}")
    if [ -z "${ISSUES// }" ]; then
        if [ "$PREV_STATE" = alert ] && [ "${MON_RECOVERY_ENABLED:-yes}" = yes ] && ! monitor_alert_in_silence; then
            if ! monitor_alert_notify "✅ <b>VPS 监控恢复</b>" "主机：<code>${HOST}</code>\n时间：<code>$(date '+%Y-%m-%d %H:%M:%S')</code>\n状态：<code>资源告警已恢复</code>"; then
                monitor_alert_history_add ERROR "资源恢复通知发送失败"
                audit_action "发送系统监控恢复失败：$HOST" FAILURE
                return 1
            fi
            monitor_alert_history_add RECOVER "资源告警恢复"
            audit_action "发送系统监控恢复：$HOST" SUCCESS
        fi
        monitor_alert_state_set RESOURCE_STATE ok
        monitor_alert_state_set RESOURCE_SIG ""
        return 0
    fi
    SIG=$(printf '%s|%s|%s' "$(monitor_alert_host_label)" "$ISSUE_KEYS" "$LEVEL" | sha256sum 2>/dev/null | awk '{print $1}')
    if [ "$SIG" = "$LAST_SIG" ] && [ $((CUR_TS - LAST_TS)) -lt "$COOLDOWN" ]; then
        return 0
    fi
    if monitor_alert_in_silence; then
        monitor_alert_state_set RESOURCE_STATE alert
        monitor_alert_state_set RESOURCE_SIG "$SIG"
        monitor_alert_state_set RESOURCE_TS "$CUR_TS"
        monitor_alert_history_add SILENCED "$(monitor_alert_level_label "$LEVEL") 资源告警静默：$ISSUES"
        return 0
    fi
    local MSG LEVEL_LABEL LEVEL_ICON
    LEVEL_LABEL=$(monitor_alert_level_label "$LEVEL")
    LEVEL_ICON=$(monitor_alert_level_icon "$LEVEL")
    MSG=$(cat <<EOF
监控告警
级别：<code>${LEVEL_LABEL}</code>
主机：<code>${HOST}</code>
时间：<code>$(date '+%Y-%m-%d %H:%M:%S')</code>
磁盘：<code>${DISK_PCT}%</code>
内存：<code>${MEM_PCT}%</code>
负载：<code>${LOAD1}</code>
异常：<code>${ISSUES}</code>
EOF
)
    if ! monitor_alert_notify "${LEVEL_ICON} <b>VPS 监控${LEVEL_LABEL}</b>" "$MSG"; then
        monitor_alert_history_add ERROR "${LEVEL_LABEL} 资源告警发送失败：$ISSUES"
        audit_action "发送系统监控告警失败：$ISSUES" FAILURE
        return 1
    fi
    monitor_alert_history_add ALERT "${LEVEL_LABEL} 资源告警：$ISSUES"
    monitor_alert_state_set RESOURCE_STATE alert
    monitor_alert_state_set RESOURCE_SIG "$SIG"
    monitor_alert_state_set RESOURCE_TS "$CUR_TS"
    audit_action "发送系统监控告警：$ISSUES" SUCCESS
}

monitor_alert_test_snapshot() {
    local HOST DISK_PCT MEM_PCT LOAD1 CPU_COUNT LOAD_WARN_VALUE DAILY_TEXT TREND_TEXT SSH_STATE F2B_STATE DOCKER_STATE CADDY_STATE
    HOST=$(monitor_alert_host_label_html)
    monitor_traffic_ensure_baseline
    DAILY_TEXT=$(monitor_traffic_usage_text daily)
    TREND_TEXT=$(monitor_alert_trend_summary)
    DISK_PCT=$(df -P / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5+0}')
    MEM_PCT=$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {if (t>0) printf "%.0f", (t-a)*100/t; else print 0}' /proc/meminfo 2>/dev/null)
    LOAD1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
    CPU_COUNT=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)
    LOAD_WARN_VALUE="${MON_LOAD_WARN:-}"
    [ -n "$LOAD_WARN_VALUE" ] || LOAD_WARN_VALUE=$(awk "BEGIN{printf \"%.1f\", $CPU_COUNT*1.5}")
    SSH_STATE=$(monitor_alert_ssh_state)
    F2B_STATE="未安装"
    command -v fail2ban-client >/dev/null 2>&1 && F2B_STATE=$(f2b_status 2>/dev/null || echo unknown)
    DOCKER_STATE="未安装"
    command -v docker >/dev/null 2>&1 && DOCKER_STATE=$(docker_status 2>/dev/null || echo unknown)
    CADDY_STATE="未安装"
    command -v caddy >/dev/null 2>&1 && CADDY_STATE=$(caddy_status 2>/dev/null || echo unknown)
    monitor_alert_notify "✅ <b>VPS 监控测试</b>" "$(cat <<EOF
主机：<code>${HOST}</code>
时间：<code>$(date '+%Y-%m-%d %H:%M:%S')</code>
磁盘：<code>${DISK_PCT}% / ${MON_DISK_WARN}%</code>
内存：<code>${MEM_PCT}% / ${MON_MEM_WARN}%</code>
负载：<code>${LOAD1} / ${LOAD_WARN_VALUE}</code>
今日流量：${DAILY_TEXT}
${TREND_TEXT}
SSH：<code>${SSH_STATE}</code>
Fail2ban：<code>${F2B_STATE}</code>
Docker：<code>${DOCKER_STATE}</code>
Caddy：<code>${CADDY_STATE}</code>
EOF
)"
}

monitor_alert_resource_snapshot() {
    monitor_alert_test_snapshot
}

monitor_alert_traffic_snapshot() {
    local HOST TODAY_TEXT CYCLE_TEXT LIMIT_GB RESET_DAY CYCLE_START
    HOST=$(monitor_alert_host_label_html)
    monitor_traffic_ensure_baseline
    monitor_traffic_cycle_ensure_baseline
    TODAY_TEXT=$(monitor_traffic_usage_text daily)
    CYCLE_TEXT=$(monitor_traffic_usage_text cycle)
    LIMIT_GB="${MON_TRAFFIC_LIMIT_GB:-50}"
    RESET_DAY="${MON_TRAFFIC_RESET_DAY:-1}"
    CYCLE_START="${MON_TRAFFIC_CYCLE_BASELINE_DATE:-$(monitor_traffic_current_cycle_start "$RESET_DAY" "$(date +%F)")}"
    monitor_alert_notify "📡 <b>VPS 流量快照</b>" "$(cat <<EOF
主机：<code>${HOST}</code>
时间：<code>$(date '+%Y-%m-%d %H:%M:%S')</code>
今日流量：${TODAY_TEXT}
当前周期：${CYCLE_TEXT}
日阈值：<code>${LIMIT_GB} GB</code>
重置日：<code>${RESET_DAY}</code>
周期起点：<code>${CYCLE_START}</code>
EOF
)"
}

monitor_alert_renew_snapshot() {
    local HOST NEXT DAYS_LEFT MODE NOTICE EXTRA AUTO_ADVANCE
    HOST=$(monitor_alert_host_label_html)
    MODE="${MON_RENEW_MODE:-interval}"
    NEXT="${MON_RENEW_NEXT_DATE:-}"
    NOTICE="${MON_RENEW_NOTICE_DAYS:-30,7,3,1}"
    AUTO_ADVANCE=$([ "${MON_RENEW_AUTO_ADVANCE:-no}" = yes ] && echo "已启用（到期次日存活）" || echo "未启用")
    [ -n "$NEXT" ] && DAYS_LEFT=$(monitor_renew_days_left "$NEXT" 2>/dev/null || echo "未设置") || DAYS_LEFT="未设置"
    case "$MODE" in
        interval) EXTRA="周期：<code>${MON_RENEW_INTERVAL_DAYS:-365} 天</code>" ;;
        monthly) EXTRA="每月固定日：<code>${MON_RENEW_MONTH_DAY:-1}</code>" ;;
        manual) EXTRA="类型：<code>固定日期一次性提醒</code>" ;;
        *) EXTRA="模式：<code>${MODE}</code>" ;;
    esac
    monitor_alert_notify "🧾 <b>VPS 续费快照</b>" "$(cat <<EOF
主机：<code>${HOST}</code>
时间：<code>$(date '+%Y-%m-%d %H:%M:%S')</code>
状态：<code>$([ "${MON_RENEW_ENABLED:-no}" = yes ] && echo '已启用' || echo '未启用')</code>
模式：<code>${MODE}</code>
下次续费：<code>${NEXT:-未设置}</code>
剩余天数：<code>${DAYS_LEFT}</code>
提醒天数：<code>${NOTICE}</code>
自动顺延：<code>${AUTO_ADVANCE}</code>
${EXTRA}
EOF
)"
}

monitor_alert_renew_reset_state() {
    MON_RENEW_LAST_ALERT=
    monitor_alert_state_set RENEW_SIG ""
    monitor_alert_state_set RENEW_TS "0"
    monitor_alert_state_set RENEW_STATE ok
}

monitor_alert_renew_mark_paid() {
    local NEXT="${MON_RENEW_NEXT_DATE:-}" OLD_NEXT NEW_NEXT CONFIRM
    [ "${MON_RENEW_ENABLED:-no}" = yes ] || { warn "续费提醒未启用"; return 1; }
    [ -n "$NEXT" ] || { warn "下次续费日期未设置"; return 1; }
    OLD_NEXT="$NEXT"
    case "${MON_RENEW_MODE:-interval}" in
        interval)
            NEW_NEXT=$(monitor_renew_next_date interval "$OLD_NEXT" "${MON_RENEW_INTERVAL_DAYS:-365}" "${MON_RENEW_MONTH_DAY:-1}")
            ;;
        monthly)
            NEW_NEXT=$(monitor_renew_next_date monthly "$OLD_NEXT" "${MON_RENEW_INTERVAL_DAYS:-365}" "${MON_RENEW_MONTH_DAY:-1}")
            ;;
        manual)
            warn "固定日期提醒没有下一个周期，请改用每月固定日或按周期循环。"
            return 1
            ;;
        *)
            warn "未知续费模式：${MON_RENEW_MODE:-未设置}"
            return 1
            ;;
    esac
    echo ""
    warn "将把本期续费提醒跳过：${OLD_NEXT} → ${NEW_NEXT}"
    read -rp "  确认已续费并跳到下一个周期？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$' || { warn "已取消"; return 1; }
    MON_RENEW_NEXT_DATE="$NEW_NEXT"
    monitor_alert_renew_reset_state
    monitor_alert_save_cfg
    monitor_alert_history_add RECOVER "已确认续费：$OLD_NEXT → $NEW_NEXT"
    audit_action "确认已续费：$OLD_NEXT → $NEW_NEXT" SUCCESS
    info "已跳到下一个续费周期：$NEW_NEXT"
}

monitor_alert_renew_auto_advance_toggle() {
    local CONFIRM OLD_VALUE="${MON_RENEW_AUTO_ADVANCE:-no}"
    if [ "${MON_RENEW_AUTO_ADVANCE:-no}" = yes ]; then
        MON_RENEW_AUTO_ADVANCE=no
        if ! monitor_alert_save_cfg; then
            MON_RENEW_AUTO_ADVANCE="$OLD_VALUE"
            error "自动顺延配置保存失败"
            return 1
        fi
        info "到期存活自动顺延已关闭"
        return 0
    fi
    case "${MON_RENEW_MODE:-interval}" in
        interval|monthly) ;;
        *)
            warn "固定日期提醒没有可顺延周期，请先选择每月固定日或按周期循环。"
            return 1
            ;;
    esac
    warn "服务商可能存在停机宽限期；仅凭到期次日机器仍运行可能误判为已续费。"
    [ "${MON_ENABLED:-no}" = yes ] || warn "后台监控尚未启用；启用后自动顺延规则才会定时执行。"
    read -rp "  确认启用到期次日存活自动顺延？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$' || { warn "已取消"; return 1; }
    MON_RENEW_AUTO_ADVANCE=yes
    if ! monitor_alert_save_cfg; then
        MON_RENEW_AUTO_ADVANCE="$OLD_VALUE"
        error "自动顺延配置保存失败"
        return 1
    fi
    monitor_alert_renew_reset_state || true
    info "到期存活自动顺延已启用"
}

monitor_alert_renew_auto_advance() {
    local TODAY="$1" OLD_NEXT="${MON_RENEW_NEXT_DATE:-}" NEW_NEXT OLD_LAST_ALERT
    [ -n "$OLD_NEXT" ] || return 1
    case "${MON_RENEW_MODE:-interval}" in
        interval|monthly) ;;
        *) return 1 ;;
    esac
    NEW_NEXT=$(monitor_renew_future_date "${MON_RENEW_MODE:-interval}" "$OLD_NEXT" \
        "${MON_RENEW_INTERVAL_DAYS:-365}" "${MON_RENEW_MONTH_DAY:-1}" "$TODAY") || return 1
    [ -n "$NEW_NEXT" ] && [ "$NEW_NEXT" != "$OLD_NEXT" ] || return 1

    OLD_LAST_ALERT="${MON_RENEW_LAST_ALERT:-}"
    MON_RENEW_NEXT_DATE="$NEW_NEXT"
    MON_RENEW_LAST_ALERT=
    if ! monitor_alert_save_cfg; then
        MON_RENEW_NEXT_DATE="$OLD_NEXT"
        MON_RENEW_LAST_ALERT="$OLD_LAST_ALERT"
        monitor_alert_history_add ERROR "续费自动顺延保存失败：$OLD_NEXT → $NEW_NEXT"
        audit_action "续费自动顺延保存失败：$OLD_NEXT → $NEW_NEXT" FAILURE
        return 1
    fi
    monitor_alert_renew_reset_state || true
    monitor_alert_history_add RECOVER "到期后机器仍在运行，自动顺延续费周期：$OLD_NEXT → $NEW_NEXT"
    audit_action "续费到期存活自动顺延：$OLD_NEXT → $NEW_NEXT" SUCCESS

    if [ -n "${MON_BOT_TOKEN:-}" ] && [ -n "${MON_CHAT_ID:-}" ]; then
        if ! monitor_alert_notify "✅ <b>续费周期已自动顺延</b>" "$(cat <<EOF
主机：<code>$(monitor_alert_host_label_html)</code>
检测日期：<code>${TODAY}</code>
原续费日期：<code>${OLD_NEXT}</code>
下次续费日期：<code>${NEW_NEXT}</code>
依据：<code>到期后监控任务仍正常运行</code>
EOF
)"; then
            monitor_alert_history_add ERROR "续费自动顺延通知发送失败：$OLD_NEXT → $NEW_NEXT"
            audit_action "发送续费自动顺延通知失败：$OLD_NEXT → $NEW_NEXT" FAILURE
            return 1
        fi
    fi
    return 0
}

monitor_alert_traffic_check() {
    [ "${MON_TRAFFIC_ENABLED:-no}" = "yes" ] || return 0
    monitor_traffic_ensure_baseline
    monitor_traffic_cycle_ensure_baseline
    local USED_RX USED_TX USED_BYTES USED_GB LIMIT_GB DAILY_TEXT LEVEL LEVEL_LABEL LEVEL_ICON
    read -r USED_RX USED_TX USED_BYTES <<EOF
$(monitor_traffic_usage_triplet daily)
EOF
    USED_GB=$(monitor_traffic_used_gb "$USED_BYTES")
    DAILY_TEXT=$(monitor_traffic_usage_text daily)
    LIMIT_GB="${MON_TRAFFIC_LIMIT_GB:-50}"
    if awk -v used="$USED_GB" -v limit="$LIMIT_GB" 'BEGIN{exit !(used + 0 >= limit + 0)}'; then
        LEVEL=warning
        if awk -v used="$USED_GB" -v limit="$LIMIT_GB" 'BEGIN{exit !(used + 0 >= (limit + 0) * 1.2)}'; then
            LEVEL=critical
        fi
        LEVEL_LABEL=$(monitor_alert_level_label "$LEVEL")
        LEVEL_ICON=$(monitor_alert_level_icon "$LEVEL")
        local SIG CUR_TS LAST_SIG LAST_TS PREV_STATE COOLDOWN
        CUR_TS=$(date +%s)
        COOLDOWN=$(monitor_alert_cooldown_seconds)
        SIG=$(printf 'traffic|%s|%s|%s' "$(monitor_alert_host_label)" "$LIMIT_GB" "$LEVEL" | sha256sum 2>/dev/null | awk '{print $1}')
        LAST_SIG=$(monitor_alert_state_get TRAFFIC_SIG 2>/dev/null || true)
        LAST_TS=$(monitor_alert_state_get TRAFFIC_TS 2>/dev/null || echo 0)
        LAST_TS=$(monitor_int_normalize "${LAST_TS:-0}")
        PREV_STATE=$(monitor_alert_state_get TRAFFIC_STATE 2>/dev/null || echo ok)
        if [ "$SIG" = "$LAST_SIG" ] && [ $((CUR_TS - LAST_TS)) -lt "$COOLDOWN" ]; then
            return 0
        fi
        if monitor_alert_in_silence; then
            monitor_alert_state_set TRAFFIC_STATE alert
            monitor_alert_state_set TRAFFIC_SIG "$SIG"
            monitor_alert_state_set TRAFFIC_TS "$CUR_TS"
            monitor_alert_history_add SILENCED "${LEVEL_LABEL} 流量超限：${USED_GB}GB / ${LIMIT_GB}GB"
            return 0
        fi
        if ! monitor_alert_notify "${LEVEL_ICON} <b>流量超限${LEVEL_LABEL}</b>" "$(cat <<EOF
级别：<code>${LEVEL_LABEL}</code>
主机：<code>$(monitor_alert_host_label_html)</code>
今日流量：${DAILY_TEXT}
阈值：<code>${LIMIT_GB} GB</code>
EOF
)"; then
            monitor_alert_history_add ERROR "${LEVEL_LABEL} 流量告警发送失败：${USED_GB}GB / ${LIMIT_GB}GB"
            audit_action "发送流量超限告警失败：${USED_GB}GB / ${LIMIT_GB}GB" FAILURE
            return 1
        fi
        [ "$PREV_STATE" = alert ] || monitor_alert_history_add ALERT "${LEVEL_LABEL} 流量超限：${USED_GB}GB / ${LIMIT_GB}GB"
        monitor_alert_state_set TRAFFIC_STATE alert
        monitor_alert_state_set TRAFFIC_SIG "$SIG"
        monitor_alert_state_set TRAFFIC_TS "$CUR_TS"
        audit_action "发送流量超限告警：${USED_GB}GB / ${LIMIT_GB}GB" SUCCESS
    else
        if [ "$(monitor_alert_state_get TRAFFIC_STATE 2>/dev/null || echo ok)" = alert ] && [ "${MON_RECOVERY_ENABLED:-yes}" = yes ] && ! monitor_alert_in_silence; then
            if ! monitor_alert_notify "✅ <b>流量恢复</b>" "主机：<code>$(monitor_alert_host_label_html)</code>\n时间：<code>$(date '+%Y-%m-%d %H:%M:%S')</code>\n状态：<code>流量已回到阈值下</code>"; then
                monitor_alert_history_add ERROR "流量恢复通知发送失败"
                audit_action "发送流量恢复通知失败" FAILURE
                return 1
            fi
            monitor_alert_history_add RECOVER "流量恢复"
            audit_action "发送流量恢复通知" SUCCESS
        fi
        monitor_alert_state_set TRAFFIC_STATE ok
    fi
}

monitor_alert_renew_check() {
    [ "${MON_RENEW_ENABLED:-no}" = "yes" ] || return 0
    local NEXT="${MON_RENEW_NEXT_DATE:-}" TODAY DAYS_LEFT LEVEL LEVEL_LABEL LEVEL_ICON
    TODAY=$(date +%F)
    if [ -z "$NEXT" ]; then
        NEXT="$TODAY"
    fi
    DAYS_LEFT=$(monitor_renew_days_left "$NEXT" 2>/dev/null || echo 0)
    if [ "${MON_RENEW_AUTO_ADVANCE:-no}" = yes ] && [ "$DAYS_LEFT" -le -1 ]; then
        case "${MON_RENEW_MODE:-interval}" in
            interval|monthly)
                if monitor_alert_renew_auto_advance "$TODAY"; then
                    return 0
                fi
                return 1
                ;;
        esac
    fi
    [ "${MON_RENEW_LAST_ALERT:-}" = "$TODAY" ] && return 0
    if ! monitor_renew_notice_match "$DAYS_LEFT" "${MON_RENEW_NOTICE_DAYS:-30,7,3,1}"; then
        return 0
    fi
    LEVEL=notice
    [ "$DAYS_LEFT" -le 3 ] && LEVEL=warning
    [ "$DAYS_LEFT" -le 0 ] && LEVEL=critical
    LEVEL_LABEL=$(monitor_alert_level_label "$LEVEL")
    LEVEL_ICON=$(monitor_alert_level_icon "$LEVEL")
    local SIG CUR_TS LAST_SIG LAST_TS
    CUR_TS=$(date +%s)
    SIG=$(printf 'renew|%s|%s|%s' "$(monitor_alert_host_label)" "$NEXT" "$DAYS_LEFT" | sha256sum 2>/dev/null | awk '{print $1}')
    LAST_SIG=$(monitor_alert_state_get RENEW_SIG 2>/dev/null || true)
    LAST_TS=$(monitor_alert_state_get RENEW_TS 2>/dev/null || echo 0)
    LAST_TS=$(monitor_int_normalize "${LAST_TS:-0}")
    if [ "$SIG" = "$LAST_SIG" ] && [ $((CUR_TS - LAST_TS)) -lt "$(monitor_alert_cooldown_seconds)" ]; then
        return 0
    fi
    if monitor_alert_in_silence; then
        monitor_alert_state_set RENEW_STATE alert
        monitor_alert_state_set RENEW_SIG "$SIG"
        monitor_alert_state_set RENEW_TS "$CUR_TS"
        MON_RENEW_LAST_ALERT="$TODAY"
        monitor_alert_save_cfg
        monitor_alert_history_add SILENCED "${LEVEL_LABEL} 续费提醒：$NEXT，剩余 $DAYS_LEFT 天"
        return 0
    fi
    if ! monitor_alert_notify "${LEVEL_ICON} <b>续费${LEVEL_LABEL}</b>" "$(cat <<EOF
级别：<code>${LEVEL_LABEL}</code>
主机：<code>$(monitor_alert_host_label_html)</code>
下次续费日期：<code>${NEXT}</code>
剩余天数：<code>${DAYS_LEFT}</code>
EOF
)"; then
        monitor_alert_history_add ERROR "${LEVEL_LABEL} 续费提醒发送失败：$NEXT，剩余 $DAYS_LEFT 天"
        audit_action "发送续费提醒失败：$NEXT，剩余 $DAYS_LEFT 天" FAILURE
        return 1
    fi
    monitor_alert_history_add ALERT "${LEVEL_LABEL} 续费提醒：$NEXT，剩余 $DAYS_LEFT 天"
    monitor_alert_state_set RENEW_SIG "$SIG"
    monitor_alert_state_set RENEW_TS "$CUR_TS"
    monitor_alert_state_set RENEW_STATE alert
    MON_RENEW_LAST_ALERT="$TODAY"
    monitor_alert_save_cfg
    audit_action "发送续费提醒：$NEXT，剩余 $DAYS_LEFT 天" SUCCESS
}

monitor_alert_check() {
    local CFG EXIT_CODE=0
    CFG=$(monitor_alert_cfg)
    [ -f "$CFG" ] || return 0
    monitor_alert_load_cfg
    [ "${MON_ENABLED:-no}" = "yes" ] || return 0
    monitor_alert_acquire_lock || return 0
    monitor_alert_metrics_sample
    monitor_alert_resource_check || EXIT_CODE=1
    monitor_alert_traffic_check || EXIT_CODE=1
    monitor_alert_renew_check || EXIT_CODE=1
    monitor_alert_daily_report_check || EXIT_CODE=1
    return "$EXIT_CODE"
}

monitor_alert_notify_menu() {
    while true; do
        monitor_alert_load_cfg
        print_header "通知设置"
        echo -e "  状态：${BOLD}$([ -n "$MON_BOT_TOKEN" ] && [ -n "$MON_CHAT_ID" ] && echo '已配置' || echo '未配置')${NC}"
        echo -e "  主机显示：${BOLD}${MON_HOST_LABEL:-自动使用 hostname}${NC}"
        echo ""
        menu_div
        menu_item "1" "配置 Bot Token / Chat ID" "$GREEN"
        menu_item "2" "设置主机显示名" "$CYAN"
        menu_item "3" "发送测试推送" "$YELLOW"
        menu_item "4" "清除通知配置" "$RED"
        menu_item "0" "返回上级" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择操作 [0-4]: ')" CH
        case "$CH" in
            1)
                read -rsp "$(ui_prompt 'Bot Token: ')" BOT_TOKEN
                echo ""
                read -rp "$(ui_prompt 'Chat ID: ')" CHAT_ID
                [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ] || { warn "已取消"; continue; }
                MON_BOT_TOKEN="$BOT_TOKEN"
                MON_CHAT_ID="$CHAT_ID"
                monitor_alert_save_cfg
                info "Telegram 已配置"
                ;;
            2)
                monitor_alert_set_host_label
                ;;
            3)
                if monitor_alert_test_snapshot; then
                    info "测试消息已发送"
                else
                    error "测试消息发送失败，请检查 Bot Token、Chat ID 和网络"
                fi
                ;;
            4)
                MON_BOT_TOKEN=
                MON_CHAT_ID=
                monitor_alert_save_cfg
                info "通知配置已清除"
                ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

monitor_alert_resource_menu() {
    while true; do
        monitor_alert_load_cfg
        print_header "资源告警"
        echo -e "  磁盘阈值：${BOLD}${MON_DISK_WARN}%${NC}"
        echo -e "  内存阈值：${BOLD}${MON_MEM_WARN}%${NC}"
        echo -e "  负载阈值：${BOLD}${MON_LOAD_WARN:-自动}${NC}"
        echo -e "  检查项：SSH=$([ "${MON_CHECK_SSH:-yes}" = yes ] && echo 启用 || echo 关闭) / Fail2ban=$([ "${MON_CHECK_FAIL2BAN:-yes}" = yes ] && echo 启用 || echo 关闭) / Docker=$([ "${MON_CHECK_DOCKER:-yes}" = yes ] && echo 启用 || echo 关闭) / Caddy=$([ "${MON_CHECK_CADDY:-yes}" = yes ] && echo 启用 || echo 关闭)"
        echo ""
        menu_div
        menu_item "1" "设置磁盘阈值" "$GREEN"
        menu_item "2" "设置内存阈值" "$GREEN"
        menu_item "3" "设置负载阈值" "$CYAN"
        menu_item "4" "服务检查开关" "$YELLOW"
        menu_item "5" "立即发送一次" "$GREEN"
        menu_item "0" "返回上级" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择操作 [0-5]: ')" CH
        case "$CH" in
            1)
                read -rp "$(ui_prompt "磁盘阈值 [${MON_DISK_WARN}%]: ")" DISK_WARN_IN
                if [ -n "$DISK_WARN_IN" ]; then
                    monitor_percent_valid "$DISK_WARN_IN" || { warn "磁盘阈值必须是 1-100 的整数"; continue; }
                    MON_DISK_WARN="$DISK_WARN_IN"
                fi
                monitor_alert_save_cfg
                info "磁盘阈值已保存"
                ;;
            2)
                read -rp "$(ui_prompt "内存阈值 [${MON_MEM_WARN}%]: ")" MEM_WARN_IN
                if [ -n "$MEM_WARN_IN" ]; then
                    monitor_percent_valid "$MEM_WARN_IN" || { warn "内存阈值必须是 1-100 的整数"; continue; }
                    MON_MEM_WARN="$MEM_WARN_IN"
                fi
                monitor_alert_save_cfg
                info "内存阈值已保存"
                ;;
            3)
                read -rp "$(ui_prompt "负载阈值（空=自动） [${MON_LOAD_WARN:-自动}]: ")" LOAD_WARN_IN
                [ -z "$LOAD_WARN_IN" ] || monitor_positive_number_valid "$LOAD_WARN_IN" || { warn "负载阈值必须是大于 0 的数字"; continue; }
                MON_LOAD_WARN="$LOAD_WARN_IN"
                monitor_alert_save_cfg
                info "负载阈值已保存"
                ;;
            4)
                monitor_alert_service_checks_menu
                ;;
            5)
                if monitor_alert_resource_snapshot; then info "资源快照已发送"; else error "资源快照发送失败"; fi
                ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

monitor_alert_service_checks_menu() {
    while true; do
        monitor_alert_load_cfg
        print_header "服务检查开关"
        echo -e "  SSH：${BOLD}$([ "${MON_CHECK_SSH:-yes}" = yes ] && echo 启用 || echo 关闭)${NC}"
        echo -e "  Fail2ban：${BOLD}$([ "${MON_CHECK_FAIL2BAN:-yes}" = yes ] && echo 启用 || echo 关闭)${NC}"
        echo -e "  Docker：${BOLD}$([ "${MON_CHECK_DOCKER:-yes}" = yes ] && echo 启用 || echo 关闭)${NC}"
        echo -e "  Caddy：${BOLD}$([ "${MON_CHECK_CADDY:-yes}" = yes ] && echo 启用 || echo 关闭)${NC}"
        echo ""
        menu_div
        menu_item "1" "切换 SSH 检查" "$GREEN"
        menu_item "2" "切换 Fail2ban 检查" "$GREEN"
        menu_item "3" "切换 Docker 检查" "$GREEN"
        menu_item "4" "切换 Caddy 检查" "$GREEN"
        menu_item "0" "返回上级" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择操作 [0-4]: ')" CH
        case "$CH" in
            1) [ "${MON_CHECK_SSH:-yes}" = yes ] && MON_CHECK_SSH=no || MON_CHECK_SSH=yes ;;
            2) [ "${MON_CHECK_FAIL2BAN:-yes}" = yes ] && MON_CHECK_FAIL2BAN=no || MON_CHECK_FAIL2BAN=yes ;;
            3) [ "${MON_CHECK_DOCKER:-yes}" = yes ] && MON_CHECK_DOCKER=no || MON_CHECK_DOCKER=yes ;;
            4) [ "${MON_CHECK_CADDY:-yes}" = yes ] && MON_CHECK_CADDY=no || MON_CHECK_CADDY=yes ;;
            0) return ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac
        monitor_alert_save_cfg
        info "检查项已更新"
    done
}

monitor_alert_traffic_menu() {
    while true; do
        monitor_alert_load_cfg
        print_header "流量监控"
        echo -e "  状态：${BOLD}$([ "$MON_TRAFFIC_ENABLED" = yes ] && echo '已启用' || echo '未启用')${NC}"
        echo -e "  日阈值：${BOLD}${MON_TRAFFIC_LIMIT_GB} GB${NC}"
        monitor_traffic_ensure_baseline
        monitor_traffic_cycle_ensure_baseline
        local TODAY_TEXT CYCLE_TEXT CYCLE_RX_BYTES CYCLE_TX_BYTES CYCLE_RX_GB CYCLE_TX_GB
        TODAY_TEXT=$(monitor_traffic_usage_text daily)
        CYCLE_TEXT=$(monitor_traffic_usage_text cycle)
        read -r CYCLE_RX_BYTES CYCLE_TX_BYTES _ <<EOF
$(monitor_traffic_usage_triplet cycle)
EOF
        CYCLE_RX_GB=$(monitor_traffic_used_gb "$CYCLE_RX_BYTES")
        CYCLE_TX_GB=$(monitor_traffic_used_gb "$CYCLE_TX_BYTES")
        echo -e "  今日：${TODAY_TEXT}"
        echo -e "  周期：${CYCLE_TEXT}"
        echo -e "  重置日：${BOLD}${MON_TRAFFIC_RESET_DAY}${NC}"
        echo -e "  周期起点：${BOLD}${MON_TRAFFIC_CYCLE_BASELINE_DATE:-未设置}${NC}"
        echo ""
        menu_div
        menu_item "1" "$([ "$MON_TRAFFIC_ENABLED" = yes ] && echo '关闭流量监控' || echo '开启流量监控')" "$GREEN"
        menu_item "2" "设置日阈值" "$CYAN"
        menu_item "3" "设置流量重置日" "$GREEN"
        menu_item "4" "校准当前周期流量" "$YELLOW"
        menu_item "5" "重置今日统计" "$YELLOW"
        menu_item "6" "立即发送一次" "$GREEN"
        menu_item "0" "返回上级" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择操作 [0-6]: ')" CH
        case "$CH" in
            1)
                if [ "$MON_TRAFFIC_ENABLED" = yes ]; then
                    MON_TRAFFIC_ENABLED=no
                    info "流量监控已关闭"
                else
                    monitor_traffic_enable_with_prompt
                fi
                monitor_alert_save_cfg
                ;;
            2)
                read -rp "$(ui_prompt "流量阈值（GB/日） [${MON_TRAFFIC_LIMIT_GB}]: ")" LIMIT_IN
                if [ -n "$LIMIT_IN" ]; then
                    monitor_positive_number_valid "$LIMIT_IN" || { warn "流量阈值必须是大于 0 的数字"; continue; }
                    MON_TRAFFIC_LIMIT_GB="$LIMIT_IN"
                fi
                monitor_alert_save_cfg
                info "阈值已保存"
                ;;
            3)
                read -rp "$(ui_prompt "每月流量重置日（1-31，短月顺延下月1日） [${MON_TRAFFIC_RESET_DAY}]: ")" RESET_IN
                if [ -n "$RESET_IN" ]; then
                    monitor_traffic_reset_day_valid "$RESET_IN" || { warn "重置日必须是 1-31"; continue; }
                    MON_TRAFFIC_RESET_DAY="$RESET_IN"
                fi
                local CUR_RX CUR_TX CUR_TOTAL
                read -r CUR_RX CUR_TX CUR_TOTAL <<EOF
$(monitor_traffic_totals)
EOF
                MON_TRAFFIC_CYCLE_BASELINE_DATE=$(monitor_traffic_current_cycle_start "${MON_TRAFFIC_RESET_DAY:-1}" "$(date +%F)")
                MON_TRAFFIC_CYCLE_BASELINE_BYTES="$CUR_TOTAL"
                MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES="$CUR_RX"
                MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES="$CUR_TX"
                MON_TRAFFIC_CYCLE_OFFSET_BYTES=0
                MON_TRAFFIC_CYCLE_OFFSET_RX_BYTES=0
                MON_TRAFFIC_CYCLE_OFFSET_TX_BYTES=0
                MON_TRAFFIC_LAST_BYTES="$CUR_TOTAL"
                MON_TRAFFIC_LAST_RX_BYTES="$CUR_RX"
                MON_TRAFFIC_LAST_TX_BYTES="$CUR_TX"
                monitor_alert_save_cfg
                info "重置日已保存"
                ;;
            4)
                local CYCLE_RX_IN CYCLE_TX_IN
                read -rp "$(ui_prompt "当前周期下行已消耗（GB） [${CYCLE_RX_GB}]: ")" CYCLE_RX_IN
                read -rp "$(ui_prompt "当前周期上行已消耗（GB） [${CYCLE_TX_GB}]: ")" CYCLE_TX_IN
                CYCLE_RX_IN=${CYCLE_RX_IN:-$CYCLE_RX_GB}
                CYCLE_TX_IN=${CYCLE_TX_IN:-$CYCLE_TX_GB}
                monitor_traffic_set_cycle_usage_split_gb "$CYCLE_RX_IN" "$CYCLE_TX_IN" || { warn "输入无效"; continue; }
                info "当前周期流量已更新"
                ;;
            5)
                local CUR_RX CUR_TX CUR_TOTAL
                read -r CUR_RX CUR_TX CUR_TOTAL <<EOF
$(monitor_traffic_totals)
EOF
                MON_TRAFFIC_BASELINE_DATE=$(date +%F)
                MON_TRAFFIC_BASELINE_BYTES="$CUR_TOTAL"
                MON_TRAFFIC_BASELINE_RX_BYTES="$CUR_RX"
                MON_TRAFFIC_BASELINE_TX_BYTES="$CUR_TX"
                MON_TRAFFIC_OFFSET_BYTES=0
                MON_TRAFFIC_OFFSET_RX_BYTES=0
                MON_TRAFFIC_OFFSET_TX_BYTES=0
                MON_TRAFFIC_LAST_BYTES="$CUR_TOTAL"
                MON_TRAFFIC_LAST_RX_BYTES="$CUR_RX"
                MON_TRAFFIC_LAST_TX_BYTES="$CUR_TX"
                monitor_alert_save_cfg
                info "今日基线已重置"
                ;;
            6)
                if monitor_alert_traffic_snapshot; then info "流量快照已发送"; else error "流量快照发送失败"; fi
                ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

monitor_alert_daily_menu() {
    while true; do
        monitor_alert_load_cfg
        print_header "每日日报"
        echo -e "  状态：${BOLD}$([ "$MON_DAILY_REPORT_ENABLED" = yes ] && echo '已启用' || echo '未启用')${NC}"
        echo -e "  时间：${BOLD}${MON_DAILY_REPORT_TIME}${NC}"
        echo -e "  Cron：${BOLD}$(monitor_alert_cron_status daily)${NC}"
        echo -e "  下次推送：${BOLD}$(monitor_alert_next_daily_time)${NC}"
        echo -e "  今日流量：$(monitor_traffic_usage_text daily)"
        echo -e "  当前周期：$(monitor_traffic_usage_text cycle)"
        [ -z "${MON_BOT_TOKEN:-}" ] || [ -z "${MON_CHAT_ID:-}" ] && warn "日报需要 Telegram 通知，请先配置 Bot / Chat。"
        echo ""
        menu_div
        menu_item "1" "启用日报" "$GREEN"
        menu_item "2" "设置推送时间" "$CYAN"
        menu_item "3" "立即发送一次" "$YELLOW"
        menu_item "4" "关闭日报" "$RED"
        menu_item "0" "返回上级" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择操作 [0-4]: ')" CH
        case "$CH" in
            1)
                if [ -z "${MON_BOT_TOKEN:-}" ] || [ -z "${MON_CHAT_ID:-}" ]; then
                    warn "请先配置 Telegram Bot / Chat"
                    continue
                fi
                MON_DAILY_REPORT_ENABLED=yes
                [ -z "${MON_DAILY_REPORT_TIME:-}" ] && MON_DAILY_REPORT_TIME="08:00"
                MON_ENABLED=yes
                monitor_alert_save_cfg
                if monitor_alert_install_cron; then
                    info "每日日报已启用"
                else
                    MON_ENABLED=no
                    monitor_alert_save_cfg
                    error "每日日报定时任务安装失败"
                fi
                ;;
            2)
                local NORMAL_TIME
                read -rp "$(ui_prompt "日报时间（支持 23:59 / 2359） [${MON_DAILY_REPORT_TIME}]: ")" TIME_IN
                if [ -n "$TIME_IN" ]; then
                    NORMAL_TIME=$(monitor_time_normalize "$TIME_IN" 2>/dev/null || true)
                    [ -n "$NORMAL_TIME" ] || { warn "时间格式无效"; continue; }
                    MON_DAILY_REPORT_TIME="$NORMAL_TIME"
                fi
                monitor_alert_save_cfg
                if [ "$MON_ENABLED" = yes ] && ! monitor_alert_install_cron; then
                    error "日报时间已保存，但定时任务更新失败"
                    continue
                fi
                info "日报时间已保存"
                ;;
            3)
                if monitor_alert_daily_report; then info "日报已发送"; else error "日报发送失败"; fi
                ;;
            4)
                MON_DAILY_REPORT_ENABLED=no
                monitor_alert_save_cfg
                if [ "$MON_ENABLED" = yes ]; then
                    monitor_alert_install_cron || { error "日报已关闭，但定时任务更新失败"; continue; }
                else
                    monitor_alert_remove_cron
                fi
                info "每日日报已关闭"
                ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

monitor_alert_renew_menu() {
    while true; do
        monitor_alert_load_cfg
        print_header "续费提醒"
        echo -e "  状态：${BOLD}$([ "$MON_RENEW_ENABLED" = yes ] && echo '已启用' || echo '未启用')${NC}"
        echo -e "  模式：${BOLD}${MON_RENEW_MODE}${NC}"
        echo -e "  下次续费：${BOLD}${MON_RENEW_NEXT_DATE:-未设置}${NC}"
        echo -e "  提醒天数：${BOLD}${MON_RENEW_NOTICE_DAYS}${NC}"
        echo -e "  自动顺延：${BOLD}$([ "${MON_RENEW_AUTO_ADVANCE:-no}" = yes ] && echo '已启用（到期次日存活）' || echo '未启用')${NC}"
        case "${MON_RENEW_MODE:-interval}" in
            interval) echo -e "  周期：${BOLD}${MON_RENEW_INTERVAL_DAYS} 天${NC}" ;;
            monthly) echo -e "  每月固定日：${BOLD}${MON_RENEW_MONTH_DAY}${NC}" ;;
            manual) echo -e "  类型：${BOLD}固定日期一次性提醒${NC}" ;;
        esac
        echo ""
        menu_div
        menu_item "1" "固定日期提醒" "$GREEN"
        menu_item "2" "每月固定日" "$CYAN"
        menu_item "3" "按周期循环" "$YELLOW"
        menu_item "4" "设置提醒天数" "$GREEN"
        menu_item "5" "关闭续费提醒" "$RED"
        menu_item "6" "我已续费" "$YELLOW"
        menu_item "7" "立即发送一次" "$GREEN"
        menu_item "8" "$([ "${MON_RENEW_AUTO_ADVANCE:-no}" = yes ] && echo '关闭到期存活自动顺延' || echo '启用到期存活自动顺延')" "$CYAN"
        menu_item "0" "返回上级" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择操作 [0-8]: ')" CH
        case "$CH" in
            1)
                local NORMAL_DATE
                read -rp "$(ui_prompt '请输入下次续费日期（支持 2026-05-15 / 20260515）: ')" NEXT_IN
                NORMAL_DATE=$(monitor_date_normalize "$NEXT_IN" 2>/dev/null || true)
                [ -n "$NORMAL_DATE" ] || { warn "日期格式无效"; continue; }
                MON_RENEW_ENABLED=yes
                MON_RENEW_MODE=manual
                MON_RENEW_NEXT_DATE="$NORMAL_DATE"
                MON_RENEW_AUTO_ADVANCE=no
                monitor_alert_renew_reset_state
                monitor_alert_save_cfg
                info "续费日期已设置"
                ;;
            2)
                read -rp "$(ui_prompt '每月固定日（1-31）: ')" MDAY
                monitor_traffic_reset_day_valid "$MDAY" || { warn "每月固定日必须是 1-31"; continue; }
                MON_RENEW_ENABLED=yes
                MON_RENEW_MODE=monthly
                MON_RENEW_MONTH_DAY="$MDAY"
                MON_RENEW_NEXT_DATE=$(monitor_renew_next_date monthly "$(date +%F)" "${MON_RENEW_INTERVAL_DAYS:-365}" "$MDAY")
                monitor_alert_renew_reset_state
                monitor_alert_save_cfg
                info "每月续费提醒已设置"
                ;;
            3)
                read -rp "$(ui_prompt '循环天数（如 30/90/365）: ')" DAYS_IN
                monitor_positive_int_valid "$DAYS_IN" || { warn "循环天数必须是大于 0 的整数"; continue; }
                local NORMAL_BASE_DATE
                read -rp "$(ui_prompt '下次续费日期（支持 2026-05-15 / 20260515，留空=今天加循环天数）: ')" BASE_IN
                if [ -n "$BASE_IN" ]; then
                    NORMAL_BASE_DATE=$(monitor_date_normalize "$BASE_IN" 2>/dev/null || true)
                    [ -n "$NORMAL_BASE_DATE" ] || { warn "日期格式无效"; continue; }
                else
                    NORMAL_BASE_DATE=$(monitor_renew_next_date interval "$(date +%F)" "$DAYS_IN" "$MON_RENEW_MONTH_DAY")
                fi
                MON_RENEW_ENABLED=yes
                MON_RENEW_MODE=interval
                MON_RENEW_INTERVAL_DAYS="$DAYS_IN"
                MON_RENEW_NEXT_DATE="$NORMAL_BASE_DATE"
                monitor_alert_renew_reset_state
                monitor_alert_save_cfg
                info "循环续费已设置"
                ;;
            4)
                read -rp "$(ui_prompt '提醒天数（逗号分隔，如 30,7,3,1）: ')" NOTICE_IN
                if [ -n "$NOTICE_IN" ]; then
                    monitor_renew_notice_days_valid "$NOTICE_IN" || { warn "提醒天数必须是逗号分隔的非负整数"; continue; }
                    MON_RENEW_NOTICE_DAYS="$NOTICE_IN"
                fi
                monitor_alert_renew_reset_state
                monitor_alert_save_cfg
                info "提醒天数已保存"
                ;;
            5)
                MON_RENEW_ENABLED=no
                MON_RENEW_AUTO_ADVANCE=no
                monitor_alert_save_cfg
                info "续费提醒已关闭"
                ;;
            6)
                monitor_alert_renew_mark_paid || true
                ;;
            7)
                if monitor_alert_renew_snapshot; then info "续费快照已发送"; else error "续费快照发送失败"; fi
                ;;
            8)
                monitor_alert_renew_auto_advance_toggle || true
                ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

monitor_alert_advanced_menu() {
    while true; do
        monitor_alert_load_cfg
        print_header "高级策略"
        echo -e "  冷却时间：${BOLD}${MON_ALERT_COOLDOWN_MIN:-30} 分钟${NC}"
        echo -e "  静默时段：${BOLD}${MON_ALERT_SILENCE_START:-未设} - ${MON_ALERT_SILENCE_END:-未设}${NC}"
        echo -e "  恢复通知：${BOLD}$([ "${MON_RECOVERY_ENABLED:-yes}" = yes ] && echo '已启用' || echo '未启用')${NC}"
        echo ""
        menu_div
        menu_item "1" "设置冷却时间" "$GREEN"
        menu_item "2" "设置静默时段" "$YELLOW"
        menu_item "3" "开关恢复通知" "$CYAN"
        menu_item "0" "返回上级" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择操作 [0-3]: ')" CH
        case "$CH" in
            1)
                read -rp "$(ui_prompt "告警冷却时间（分钟） [${MON_ALERT_COOLDOWN_MIN:-30}]: ")" COOLDOWN_IN
                if [ -n "$COOLDOWN_IN" ]; then
                    monitor_positive_int_valid "$COOLDOWN_IN" || { warn "冷却时间必须是大于 0 的整数"; continue; }
                    MON_ALERT_COOLDOWN_MIN="$COOLDOWN_IN"
                fi
                monitor_alert_save_cfg
                info "告警冷却已保存"
                ;;
            2)
                read -rp "$(ui_prompt "静默开始时间（支持 23:59 / 2359，留空=取消） [${MON_ALERT_SILENCE_START:-未设}]: ")" SILENCE_START_IN
                read -rp "$(ui_prompt "静默结束时间（支持 23:59 / 2359，留空=取消） [${MON_ALERT_SILENCE_END:-未设}]: ")" SILENCE_END_IN
                if [ -z "$SILENCE_START_IN" ] || [ -z "$SILENCE_END_IN" ]; then
                    MON_ALERT_SILENCE_START=
                    MON_ALERT_SILENCE_END=
                else
                    MON_ALERT_SILENCE_START=$(monitor_time_normalize "$SILENCE_START_IN" 2>/dev/null || true)
                    MON_ALERT_SILENCE_END=$(monitor_time_normalize "$SILENCE_END_IN" 2>/dev/null || true)
                    [ -n "$MON_ALERT_SILENCE_START" ] && [ -n "$MON_ALERT_SILENCE_END" ] || { warn "时间格式无效"; continue; }
                fi
                monitor_alert_save_cfg
                info "静默时段已保存"
                ;;
            3)
                [ "${MON_RECOVERY_ENABLED:-yes}" = yes ] && MON_RECOVERY_ENABLED=no || MON_RECOVERY_ENABLED=yes
                monitor_alert_save_cfg
                info "恢复通知已切换"
                ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

monitor_alert_quick_setup_menu() {
    while true; do
        monitor_alert_load_cfg
        print_header "快速启用监控"
        echo -e "  通知：${BOLD}$([ -n "$MON_BOT_TOKEN" ] && [ -n "$MON_CHAT_ID" ] && echo '已配置' || echo '未配置')${NC}"
        echo -e "  主机显示：${BOLD}${MON_HOST_LABEL:-自动使用 hostname}${NC}"
        echo -e "  每日日报：${BOLD}$([ "$MON_DAILY_REPORT_ENABLED" = yes ] && echo "${MON_DAILY_REPORT_TIME}" || echo '未启用')${NC}"
        echo -e "  流量阈值：${BOLD}${MON_TRAFFIC_LIMIT_GB} GB/日${NC}"
        echo -e "  续费提醒：${BOLD}$([ "$MON_RENEW_ENABLED" = yes ] && echo "${MON_RENEW_MODE} · ${MON_RENEW_NEXT_DATE:-未设置}" || echo '未启用')${NC}"
        echo -e "  后台监控：${BOLD}$([ "$MON_ENABLED" = yes ] && echo '已启用' || echo '未启用')${NC}"
        echo ""
        menu_div
        menu_item "1" "配置通知" "$GREEN"
        menu_item "2" "设置主机显示名" "$CYAN"
        menu_item "3" "设置日报时间" "$GREEN"
        menu_item "4" "设置流量阈值" "$YELLOW"
        menu_item "5" "设置续费提醒" "$YELLOW"
        menu_item "6" "启用后台监控" "$GREEN"
        menu_item "0" "返回上级" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择操作 [0-6]: ')" CH
        case "$CH" in
            1) monitor_alert_notify_menu ;;
            2)
                monitor_alert_set_host_label
                ;;
            3)
                local NORMAL_TIME
                read -rp "$(ui_prompt "日报时间（支持 23:59 / 2359） [${MON_DAILY_REPORT_TIME}]: ")" TIME_IN
                NORMAL_TIME=$(monitor_time_normalize "${TIME_IN:-$MON_DAILY_REPORT_TIME}" 2>/dev/null || true)
                [ -n "$NORMAL_TIME" ] || { warn "时间格式无效"; continue; }
                MON_DAILY_REPORT_TIME="$NORMAL_TIME"
                MON_DAILY_REPORT_ENABLED=yes
                monitor_alert_save_cfg
                if [ "$MON_ENABLED" = yes ] && ! monitor_alert_install_cron; then
                    error "日报时间已保存，但定时任务更新失败"
                    continue
                fi
                info "日报时间已保存"
                ;;
            4)
                read -rp "$(ui_prompt "流量阈值（GB/日） [${MON_TRAFFIC_LIMIT_GB}]: ")" LIMIT_IN
                if [ -n "$LIMIT_IN" ]; then
                    monitor_positive_number_valid "$LIMIT_IN" || { warn "流量阈值必须是大于 0 的数字"; continue; }
                    MON_TRAFFIC_LIMIT_GB="$LIMIT_IN"
                fi
                [ "${MON_TRAFFIC_ENABLED:-no}" = yes ] || monitor_traffic_enable_with_prompt
                monitor_alert_save_cfg
                info "流量阈值已保存"
                ;;
            5) monitor_alert_renew_menu ;;
            6)
                if [ -z "${MON_BOT_TOKEN:-}" ] || [ -z "${MON_CHAT_ID:-}" ]; then
                    warn "通知未配置，建议先配置 Bot / Chat"
                    continue
                fi
                MON_ENABLED=yes
                monitor_alert_save_cfg
                if monitor_alert_install_cron; then
                    info "后台监控已启用"
                else
                    MON_ENABLED=no
                    monitor_alert_save_cfg
                    error "后台监控启用失败"
                fi
                ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

monitor_alert_config_menu() {
    monitor_alert_home_menu
}

monitor_alert_legacy_config_menu() {
    local CFG; CFG=$(monitor_alert_cfg)
    mkdir -p "$(dirname "$CFG")" 2>/dev/null || true
    monitor_alert_load_cfg
    print_header "监控告警配置"
    echo -e "  状态：${BOLD}$([ "$MON_ENABLED" = yes ] && echo '已启用' || echo '未启用')${NC}"
    echo -e "  磁盘阈值：${BOLD}${MON_DISK_WARN}%${NC}"
    echo -e "  内存阈值：${BOLD}${MON_MEM_WARN}%${NC}"
    echo -e "  负载阈值：${BOLD}${MON_LOAD_WARN:-自动}${NC}"
    monitor_traffic_ensure_baseline
    monitor_traffic_cycle_ensure_baseline
    local TODAY_TEXT CYCLE_TEXT
    TODAY_TEXT=$(monitor_traffic_usage_text daily)
    CYCLE_TEXT=$(monitor_traffic_usage_text cycle)
    echo -e "  流量监控：${BOLD}$([ "$MON_TRAFFIC_ENABLED" = yes ] && echo "${MON_TRAFFIC_LIMIT_GB} GB/日" || echo '未启用')${NC}"
    echo -e "  今日流量：${TODAY_TEXT}"
    echo -e "  当前周期：${CYCLE_TEXT}"
    echo -e "  重置日：${BOLD}${MON_TRAFFIC_RESET_DAY}${NC}   周期起点：${BOLD}${MON_TRAFFIC_CYCLE_BASELINE_DATE:-未设置}${NC}"
    echo -e "  续费提醒：${BOLD}$([ "$MON_RENEW_ENABLED" = yes ] && echo "${MON_RENEW_MODE} · ${MON_RENEW_NEXT_DATE:-未设置}" || echo '未启用')${NC}"
    echo -e "  每日日报：${BOLD}$([ "$MON_DAILY_REPORT_ENABLED" = yes ] && echo "${MON_DAILY_REPORT_TIME}" || echo '未启用')${NC}"
    echo -e "  告警冷却：${BOLD}${MON_ALERT_COOLDOWN_MIN:-30} 分钟${NC}"
    echo -e "  静默时段：${BOLD}${MON_ALERT_SILENCE_START:-未设} - ${MON_ALERT_SILENCE_END:-未设}${NC}"
    echo -e "  主机显示：${BOLD}${MON_HOST_LABEL:-自动使用 hostname}${NC}"
    echo -e "  通知：${BOLD}$([ -n "$MON_BOT_TOKEN" ] && echo '已配置' || echo '未配置')${NC}"
    echo ""
    menu_div
    menu_item "1" "设置资源告警阈值" "$YELLOW"
    menu_item "2" "流量监控与周期" "$CYAN"
    menu_item "3" "每日日报设置" "$GREEN"
    menu_item "4" "续费提醒设置" "$GREEN"
    menu_item "5" "主机显示名称" "$YELLOW"
    menu_item "6" "发送测试告警" "$CYAN"
    menu_item "7" "高级告警策略" "$GREEN"
    menu_item "8" "最近告警记录" "$CYAN"
    menu_item "9" "启用定时告警" "$GREEN"
    menu_item "10" "关闭定时告警" "$RED"
    menu_item "0" "返回上级" "$RED"
    menu_div; echo ""
    read -rp "$(ui_prompt '选择操作 [0-10]: ')" CH
    case "$CH" in
        1)
            read -rp "$(ui_prompt "磁盘阈值 [${MON_DISK_WARN}%]: ")" DISK_WARN_IN
            read -rp "$(ui_prompt "内存阈值 [${MON_MEM_WARN}%]: ")" MEM_WARN_IN
            read -rp "$(ui_prompt "负载阈值（空=自动） [${MON_LOAD_WARN:-自动}]: ")" LOAD_WARN_IN
            [ -n "$DISK_WARN_IN" ] && MON_DISK_WARN="$DISK_WARN_IN"
            [ -n "$MEM_WARN_IN" ] && MON_MEM_WARN="$MEM_WARN_IN"
            [ -n "$LOAD_WARN_IN" ] && MON_LOAD_WARN="$LOAD_WARN_IN"
            monitor_alert_save_cfg
            info "阈值已保存"
            ;;
        2)
            while true; do
                print_header "流量监控"
                echo -e "  状态：${BOLD}$([ "$MON_TRAFFIC_ENABLED" = yes ] && echo '已启用' || echo '未启用')${NC}"
                echo -e "  阈值：${BOLD}${MON_TRAFFIC_LIMIT_GB} GB / 日${NC}"
                monitor_traffic_ensure_baseline
                monitor_traffic_cycle_ensure_baseline
                local TODAY_TEXT CYCLE_TEXT CYCLE_RX_BYTES CYCLE_TX_BYTES CYCLE_RX_GB CYCLE_TX_GB
                TODAY_TEXT=$(monitor_traffic_usage_text daily)
                CYCLE_TEXT=$(monitor_traffic_usage_text cycle)
                read -r CYCLE_RX_BYTES CYCLE_TX_BYTES _ <<EOF
$(monitor_traffic_usage_triplet cycle)
EOF
                CYCLE_RX_GB=$(monitor_traffic_used_gb "$CYCLE_RX_BYTES")
                CYCLE_TX_GB=$(monitor_traffic_used_gb "$CYCLE_TX_BYTES")
                echo -e "  今日累计：${TODAY_TEXT}"
                echo -e "  当前周期：${CYCLE_TEXT}"
                echo -e "  基线日期：${DIM}${MON_TRAFFIC_BASELINE_DATE:-未设置}${NC}"
                echo -e "  重置日：${DIM}${MON_TRAFFIC_RESET_DAY}${NC}   周期起点：${DIM}${MON_TRAFFIC_CYCLE_BASELINE_DATE:-未设置}${NC}"
                menu_div
                menu_item "1" "设置阈值" "$GREEN"
                menu_item "2" "$([ "$MON_TRAFFIC_ENABLED" = yes ] && echo '关闭流量监控' || echo '启用流量监控')" "$YELLOW"
                menu_item "3" "重置今日基线" "$CYAN"
                menu_item "4" "设置重置日" "$GREEN"
                menu_item "5" "校准周期下行 / 上行流量" "$YELLOW"
                menu_item "0" "返回上级" "$RED"
                menu_div; echo ""
                read -rp "$(ui_prompt '选择操作 [0-5]: ')" TCH
                case "$TCH" in
                    1)
                        read -rp "$(ui_prompt "流量阈值（GB/日，默认 50） [${MON_TRAFFIC_LIMIT_GB}]: ")" LIMIT_IN
                        [ -n "$LIMIT_IN" ] && MON_TRAFFIC_LIMIT_GB="$LIMIT_IN"
                        monitor_alert_save_cfg
                        info "阈值已保存"
                        ;;
                    2)
                        if [ "$MON_TRAFFIC_ENABLED" = yes ]; then
                            MON_TRAFFIC_ENABLED=no
                            info "流量监控已关闭"
                        else
                            monitor_traffic_enable_with_prompt
                        fi
                        monitor_alert_save_cfg
                        ;;
                    3)
                        local CUR_RX CUR_TX CUR_TOTAL
                        read -r CUR_RX CUR_TX CUR_TOTAL <<EOF
$(monitor_traffic_totals)
EOF
                        MON_TRAFFIC_BASELINE_DATE=$(date +%F)
                        MON_TRAFFIC_BASELINE_BYTES="$CUR_TOTAL"
                        MON_TRAFFIC_BASELINE_RX_BYTES="$CUR_RX"
                        MON_TRAFFIC_BASELINE_TX_BYTES="$CUR_TX"
                        MON_TRAFFIC_OFFSET_BYTES=0
                        MON_TRAFFIC_OFFSET_RX_BYTES=0
                        MON_TRAFFIC_OFFSET_TX_BYTES=0
                        MON_TRAFFIC_LAST_BYTES="$CUR_TOTAL"
                        MON_TRAFFIC_LAST_RX_BYTES="$CUR_RX"
                        MON_TRAFFIC_LAST_TX_BYTES="$CUR_TX"
                        monitor_alert_save_cfg
                        info "今日基线已重置"
                        ;;
                    4)
                        read -rp "$(ui_prompt "每月流量重置日（1-31，短月顺延下月1日） [${MON_TRAFFIC_RESET_DAY}]: ")" RESET_IN
                        if [ -n "$RESET_IN" ]; then
                            monitor_traffic_reset_day_valid "$RESET_IN" || { warn "重置日必须是 1-31；例如 31 遇到 2 月会顺延到 3 月 1 日"; continue; }
                            MON_TRAFFIC_RESET_DAY="$RESET_IN"
                        fi
                        local CUR_RX CUR_TX CUR_TOTAL
                        read -r CUR_RX CUR_TX CUR_TOTAL <<EOF
$(monitor_traffic_totals)
EOF
                        MON_TRAFFIC_CYCLE_BASELINE_DATE=$(monitor_traffic_current_cycle_start "${MON_TRAFFIC_RESET_DAY:-1}" "$(date +%F)")
                        MON_TRAFFIC_CYCLE_BASELINE_BYTES="$CUR_TOTAL"
                        MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES="$CUR_RX"
                        MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES="$CUR_TX"
                        MON_TRAFFIC_CYCLE_OFFSET_BYTES=0
                        MON_TRAFFIC_CYCLE_OFFSET_RX_BYTES=0
                        MON_TRAFFIC_CYCLE_OFFSET_TX_BYTES=0
                        MON_TRAFFIC_LAST_BYTES="$CUR_TOTAL"
                        MON_TRAFFIC_LAST_RX_BYTES="$CUR_RX"
                        MON_TRAFFIC_LAST_TX_BYTES="$CUR_TX"
                        monitor_alert_save_cfg
                        info "重置日已保存"
                        ;;
                    5)
                        local CYCLE_RX_IN CYCLE_TX_IN
                        read -rp "$(ui_prompt "当前周期下行已消耗（GB） [${CYCLE_RX_GB}]: ")" CYCLE_RX_IN
                        read -rp "$(ui_prompt "当前周期上行已消耗（GB） [${CYCLE_TX_GB}]: ")" CYCLE_TX_IN
                        CYCLE_RX_IN=${CYCLE_RX_IN:-$CYCLE_RX_GB}
                        CYCLE_TX_IN=${CYCLE_TX_IN:-$CYCLE_TX_GB}
                        monitor_traffic_set_cycle_usage_split_gb "$CYCLE_RX_IN" "$CYCLE_TX_IN" || { warn "输入无效"; continue; }
                        info "当前周期流量已更新"
                        ;;
                    0) break ;;
                    *) warn "无效选项"; sleep 1 ;;
                esac
            done
            ;;
        3)
            while true; do
                print_header "每日日报"
                echo -e "  状态：${BOLD}$([ "$MON_DAILY_REPORT_ENABLED" = yes ] && echo '已启用' || echo '未启用')${NC}"
                echo -e "  时间：${BOLD}${MON_DAILY_REPORT_TIME}${NC}"
                echo -e "  今日流量：$(monitor_traffic_usage_text daily)"
                echo -e "  当前周期：$(monitor_traffic_usage_text cycle)"
                menu_div
                menu_item "1" "启用 / 更新日报" "$GREEN"
                menu_item "2" "关闭每日日报" "$YELLOW"
                menu_item "3" "设置日报时间" "$CYAN"
                menu_item "4" "立即发送日报" "$GREEN"
                menu_item "0" "返回上级" "$RED"
                menu_div; echo ""
                read -rp "$(ui_prompt '选择操作 [0-4]: ')" DCH
                case "$DCH" in
                    1)
                        MON_DAILY_REPORT_ENABLED=yes
                        [ -z "${MON_DAILY_REPORT_TIME:-}" ] && MON_DAILY_REPORT_TIME="08:00"
                        monitor_alert_save_cfg
                        MON_ENABLED=yes
                        monitor_alert_save_cfg
                        if monitor_alert_install_cron; then
                            info "每日日报已启用"
                        else
                            MON_ENABLED=no
                            monitor_alert_save_cfg
                            error "每日日报定时任务安装失败"
                        fi
                        ;;
                    2)
                        MON_DAILY_REPORT_ENABLED=no
                        monitor_alert_save_cfg
                        if [ "$MON_ENABLED" = yes ]; then
                            monitor_alert_install_cron || { error "日报已关闭，但定时任务更新失败"; continue; }
                        else
                            monitor_alert_remove_cron
                        fi
                        info "每日日报已关闭"
                        ;;
                    3)
                        local NORMAL_TIME
                        read -rp "$(ui_prompt "日报时间（支持 23:59 / 2359） [${MON_DAILY_REPORT_TIME}]: ")" TIME_IN
                        if [ -n "$TIME_IN" ]; then
                            NORMAL_TIME=$(monitor_time_normalize "$TIME_IN" 2>/dev/null || true)
                            [ -n "$NORMAL_TIME" ] || { warn "时间格式无效"; continue; }
                            MON_DAILY_REPORT_TIME="$NORMAL_TIME"
                        fi
                        monitor_alert_save_cfg
                        if [ "$MON_ENABLED" = yes ] && ! monitor_alert_install_cron; then
                            error "日报时间已保存，但定时任务更新失败"
                            continue
                        fi
                        info "日报时间已保存"
                        ;;
                    4)
                        monitor_alert_daily_report
                        info "日报已发送（如已配置 Telegram）"
                        ;;
                    0) break ;;
                    *) warn "无效选项"; sleep 1 ;;
                esac
            done
            ;;
        4)
            while true; do
                print_header "续费提醒"
                echo -e "  状态：${BOLD}$([ "$MON_RENEW_ENABLED" = yes ] && echo '已启用' || echo '未启用')${NC}"
                echo -e "  模式：${BOLD}${MON_RENEW_MODE}${NC}"
                echo -e "  下次续费：${BOLD}${MON_RENEW_NEXT_DATE:-未设置}${NC}"
                echo -e "  提前提醒：${BOLD}${MON_RENEW_NOTICE_DAYS}${NC}"
                case "${MON_RENEW_MODE:-interval}" in
                    interval)
                        echo -e "  周期：${BOLD}${MON_RENEW_INTERVAL_DAYS} 天${NC}"
                        ;;
                    monthly)
                        echo -e "  每月固定日：${BOLD}${MON_RENEW_MONTH_DAY}${NC}"
                        ;;
                    manual)
                        echo -e "  类型：${BOLD}固定日期一次性提醒${NC}"
                        ;;
                esac
                menu_div
                menu_item "1" "设置固定日期" "$GREEN"
                menu_item "2" "按周期循环（30/90/365）" "$YELLOW"
                menu_item "3" "按每月固定日" "$CYAN"
                menu_item "4" "设置提醒天数" "$GREEN"
                menu_item "5" "关闭续费提醒" "$RED"
                menu_item "0" "返回上级" "$RED"
                menu_div; echo ""
                read -rp "$(ui_prompt '选择操作 [0-5]: ')" RCH
                case "$RCH" in
                    1)
                        local NORMAL_DATE
                        read -rp "$(ui_prompt '请输入下次续费日期（支持 2026-05-15 / 20260515）: ')" NEXT_IN
                        NORMAL_DATE=$(monitor_date_normalize "$NEXT_IN" 2>/dev/null || true)
                        [ -n "$NORMAL_DATE" ] || { warn "日期格式无效"; continue; }
                        MON_RENEW_ENABLED=yes
                        MON_RENEW_MODE=manual
                        MON_RENEW_NEXT_DATE="$NORMAL_DATE"
                        monitor_alert_save_cfg
                        info "续费日期已设置"
                        ;;
                    2)
                        read -rp "$(ui_prompt '循环天数（如 30/90/365）: ')" DAYS_IN
                        echo "$DAYS_IN" | grep -qE '^[0-9]+$' || { warn "输入无效"; continue; }
                        local NORMAL_BASE_DATE
                        read -rp "$(ui_prompt '下次续费日期（支持 2026-05-15 / 20260515，留空=今天起算）: ')" BASE_IN
                        BASE_IN=${BASE_IN:-$(date +%F)}
                        NORMAL_BASE_DATE=$(monitor_date_normalize "$BASE_IN" 2>/dev/null || true)
                        [ -n "$NORMAL_BASE_DATE" ] || { warn "日期格式无效"; continue; }
                        MON_RENEW_ENABLED=yes
                        MON_RENEW_MODE=interval
                        MON_RENEW_INTERVAL_DAYS="$DAYS_IN"
                        MON_RENEW_NEXT_DATE=$(monitor_renew_next_date interval "$NORMAL_BASE_DATE" "$DAYS_IN" "$MON_RENEW_MONTH_DAY")
                        monitor_alert_save_cfg
                        info "循环续费已设置"
                        ;;
                    3)
                        read -rp "$(ui_prompt '每月固定日（1-28/31）: ')" MDAY
                        echo "$MDAY" | grep -qE '^[0-9]+$' || { warn "输入无效"; continue; }
                        MON_RENEW_ENABLED=yes
                        MON_RENEW_MODE=monthly
                        MON_RENEW_MONTH_DAY="$MDAY"
                        MON_RENEW_NEXT_DATE=$(monitor_renew_next_date monthly "$(date +%F)" "${MON_RENEW_INTERVAL_DAYS:-365}" "$MDAY")
                        monitor_alert_save_cfg
                        info "每月续费提醒已设置"
                        ;;
                    4)
                        read -rp "$(ui_prompt '提醒天数（逗号分隔，如 30,7,3,1）: ')" NOTICE_IN
                        [ -n "$NOTICE_IN" ] && MON_RENEW_NOTICE_DAYS="$NOTICE_IN"
                        monitor_alert_save_cfg
                        info "提醒天数已保存"
                        ;;
                    5)
                        MON_RENEW_ENABLED=no
                        monitor_alert_save_cfg
                        info "续费提醒已关闭"
                        ;;
                    0) break ;;
                    *) warn "无效选项"; sleep 1 ;;
                esac
            done
            ;;
        5)
            monitor_alert_set_host_label
            ;;
        6)
            monitor_alert_test_snapshot
            info "测试消息已发送（如已配置 Telegram）"
            ;;
        7)
            while true; do
                print_header "高级告警策略"
                echo -e "  冷却时间：${BOLD}${MON_ALERT_COOLDOWN_MIN:-30} 分钟${NC}"
                echo -e "  静默时段：${BOLD}${MON_ALERT_SILENCE_START:-未设} - ${MON_ALERT_SILENCE_END:-未设}${NC}"
                echo -e "  恢复通知：${BOLD}$([ "${MON_RECOVERY_ENABLED:-yes}" = yes ] && echo '已启用' || echo '未启用')${NC}"
                echo -e "  检查项：SSH=$([ "${MON_CHECK_SSH:-yes}" = yes ] && echo 启用 || echo 关闭) / Fail2ban=$([ "${MON_CHECK_FAIL2BAN:-yes}" = yes ] && echo 启用 || echo 关闭) / Docker=$([ "${MON_CHECK_DOCKER:-yes}" = yes ] && echo 启用 || echo 关闭) / Caddy=$([ "${MON_CHECK_CADDY:-yes}" = yes ] && echo 启用 || echo 关闭)"
                menu_div
                menu_item "1" "设置告警冷却" "$GREEN"
                menu_item "2" "设置静默时段" "$YELLOW"
                menu_item "3" "切换恢复通知" "$CYAN"
                menu_item "4" "切换 SSH 检查" "$GREEN"
                menu_item "5" "切换 Fail2ban 检查" "$GREEN"
                menu_item "6" "切换 Docker 检查" "$GREEN"
                menu_item "7" "切换 Caddy 检查" "$GREEN"
                menu_item "0" "返回上级" "$RED"
                menu_div; echo ""
                read -rp "$(ui_prompt '选择操作 [0-7]: ')" ACH
                case "$ACH" in
                    1)
                        read -rp "$(ui_prompt "告警冷却时间（分钟） [${MON_ALERT_COOLDOWN_MIN:-30}]: ")" COOLDOWN_IN
                        [ -n "$COOLDOWN_IN" ] && MON_ALERT_COOLDOWN_MIN="$COOLDOWN_IN"
                        monitor_alert_save_cfg
                        info "告警冷却已保存"
                        ;;
                    2)
                        read -rp "$(ui_prompt "静默开始时间（支持 23:59 / 2359，留空=取消） [${MON_ALERT_SILENCE_START:-未设}]: ")" SILENCE_START_IN
                        read -rp "$(ui_prompt "静默结束时间（支持 23:59 / 2359，留空=取消） [${MON_ALERT_SILENCE_END:-未设}]: ")" SILENCE_END_IN
                        if [ -z "$SILENCE_START_IN" ] || [ -z "$SILENCE_END_IN" ]; then
                            MON_ALERT_SILENCE_START=
                            MON_ALERT_SILENCE_END=
                        else
                            MON_ALERT_SILENCE_START=$(monitor_time_normalize "$SILENCE_START_IN" 2>/dev/null || true)
                            MON_ALERT_SILENCE_END=$(monitor_time_normalize "$SILENCE_END_IN" 2>/dev/null || true)
                            [ -n "$MON_ALERT_SILENCE_START" ] && [ -n "$MON_ALERT_SILENCE_END" ] || { warn "时间格式无效"; continue; }
                        fi
                        monitor_alert_save_cfg
                        info "静默时段已保存"
                        ;;
                    3)
                        case "${MON_RECOVERY_ENABLED:-yes}" in
                            yes) MON_RECOVERY_ENABLED=no ;;
                            *) MON_RECOVERY_ENABLED=yes ;;
                        esac
                        monitor_alert_save_cfg
                        info "恢复通知已切换"
                        ;;
                    4)
                        case "${MON_CHECK_SSH:-yes}" in
                            yes) MON_CHECK_SSH=no ;;
                            *) MON_CHECK_SSH=yes ;;
                        esac
                        monitor_alert_save_cfg
                        info "SSH 检查已切换"
                        ;;
                    5)
                        case "${MON_CHECK_FAIL2BAN:-yes}" in
                            yes) MON_CHECK_FAIL2BAN=no ;;
                            *) MON_CHECK_FAIL2BAN=yes ;;
                        esac
                        monitor_alert_save_cfg
                        info "Fail2ban 检查已切换"
                        ;;
                    6)
                        case "${MON_CHECK_DOCKER:-yes}" in
                            yes) MON_CHECK_DOCKER=no ;;
                            *) MON_CHECK_DOCKER=yes ;;
                        esac
                        monitor_alert_save_cfg
                        info "Docker 检查已切换"
                        ;;
                    7)
                        case "${MON_CHECK_CADDY:-yes}" in
                            yes) MON_CHECK_CADDY=no ;;
                            *) MON_CHECK_CADDY=yes ;;
                        esac
                        monitor_alert_save_cfg
                        info "Caddy 检查已切换"
                        ;;
                    0) break ;;
                    *) warn "无效选项"; sleep 1 ;;
                esac
            done
            ;;
        8)
            monitor_alert_history_view
            ui_pause
            ;;
        9)
            if monitor_alert_install_cron; then
                MON_ENABLED=yes
                monitor_alert_save_cfg
                info "已启用定时告警"
            else
                MON_ENABLED=no
                monitor_alert_save_cfg
                error "定时告警启用失败"
            fi
            ;;
        10)
            MON_ENABLED=no
            monitor_alert_save_cfg
            monitor_alert_remove_cron
            info "已关闭定时告警"
            ;;
        0) return ;;
        *) warn "无效选项" ;;
    esac
}

safety_arm() {
    local LABEL="$1" SNAP SCRIPT ROOTS_FILE SYSCTL_FILE IPTABLES_FILE IP6TABLES_FILE
    local BASE ROLLBACK_DELAY LOCK_DIR
    local SNAP_Q SCRIPT_Q ROOTS_Q SYSCTL_Q IPTABLES_Q IP6TABLES_Q
    local STATE_Q LABEL_Q LOCK_Q RESTORE_Q
    local UFW_STATE="inactive" FIREWALLD_STATE="inactive" NFTABLES_STATE="inactive"
    local FIREWALL_BACKEND="none" FIREWALL_ACTIVE_COUNT=0 UFW_STATUS=""
    local FIREWALLD_ENABLED_STATE="unavailable" NFTABLES_ENABLED_STATE="unavailable"
    local RC_UPDATE_STATE=""
    local PROFILE_FIREWALL=no PROFILE_RESTART_SSH=no
    local PROFILE_RESTART_FAIL2BAN=no PROFILE_RESTART_DNS=no
    local PROFILE_RESTART_NETWORK=no NETWORK_BACKEND="" NETWORK_IFACE="" NETWORK_NM_UUID=""
    local TAR_ACLS=no TAR_XATTRS=no TAR_SELINUX=no TAR_PAX_VOLATILE=no TAR_OPTION
    local STATE_TMP="" READY=no
    local STATE_FILE="${SAFETY_STATE_FILE:-${VPS_DATA_DIR}/rollback.active}"
    local RESTORE_ROOT="${SAFETY_RESTORE_ROOT:-/}"
    ROLLBACK_DELAY="${SAFETY_ROLLBACK_DELAY:-180}"
    case "$ROLLBACK_DELAY" in ''|*[!0-9]*) ROLLBACK_DELAY=180 ;; esac
    [ "$ROLLBACK_DELAY" -ge 1 ] 2>/dev/null || ROLLBACK_DELAY=180
    mkdir -p "$VPS_DATA_DIR" 2>/dev/null || return 1
    chmod 700 "$VPS_DATA_DIR" 2>/dev/null || true
    if ! safety_lock_acquire; then
        error "另一个防断联保护操作正在进行，请稍后重试"
        return 1
    fi
    if safety_load_pending; then
        safety_lock_release
        error "已有防断联回滚任务正在计时，请先确认上一项变更或等待其完成"
        return 1
    fi
    BASE="$VPS_DATA_DIR/rollback_$$_$(date +%s)_${RANDOM}"
    SNAP="${BASE}.tar.gz"
    SCRIPT="${BASE}.sh"
    ROOTS_FILE="${BASE}.roots"
    SYSCTL_FILE="${BASE}.sysctl"
    IPTABLES_FILE="${BASE}.iptables"
    IP6TABLES_FILE="${BASE}.ip6tables"
    LOCK_DIR="${STATE_FILE}.lock"
    SAFETY_IPTABLES_SNAPSHOT_AVAILABLE=unknown
    SAFETY_IP6TABLES_SNAPSHOT_AVAILABLE=unknown
    case "$LABEL" in
        ssh_login|ssh_revoke_login|ssh_strict_login)
            PROFILE_RESTART_SSH=yes
            ;;
        ssh_port)
            PROFILE_FIREWALL=yes
            PROFILE_RESTART_SSH=yes
            PROFILE_RESTART_FAIL2BAN=yes
            ;;
        dns|dns_manual)
            PROFILE_RESTART_DNS=yes
            ;;
        network_interface)
            PROFILE_RESTART_NETWORK=yes
            NETWORK_BACKEND="${NETWORK_ROLLBACK_BACKEND:-}"
            NETWORK_IFACE="${NETWORK_ROLLBACK_IFACE:-}"
            NETWORK_NM_UUID="${NETWORK_ROLLBACK_NM_UUID:-}"
            case "$NETWORK_BACKEND" in
                netplan|networkmanager|networkd|ifupdown|ifcfg) ;;
                *) safety_lock_release; error "无法记录网卡回滚后端"; return 1 ;;
            esac
            network_iface_valid "$NETWORK_IFACE" \
                || { safety_lock_release; error "无法记录网卡回滚目标"; return 1; }
            case "$NETWORK_NM_UUID" in
                "") ;;
                *[!A-Fa-f0-9-]*)
                    safety_lock_release
                    error "无法记录 NetworkManager 回滚连接"
                    return 1
                    ;;
            esac
            ;;
        ufw|firewalld|firewall_install_ufw|firewall_install_firewalld)
            PROFILE_FIREWALL=yes
            ;;
        config_restore)
            PROFILE_FIREWALL=yes
            PROFILE_RESTART_SSH=yes
            PROFILE_RESTART_FAIL2BAN=yes
            PROFILE_RESTART_DNS=yes
            ;;
    esac
    while IFS= read -r TAR_OPTION; do
        case "$TAR_OPTION" in
            --acls) TAR_ACLS=yes ;;
            --xattrs) TAR_XATTRS=yes ;;
            --selinux) TAR_SELINUX=yes ;;
            --pax-option=delete=atime,delete=ctime) TAR_PAX_VOLATILE=yes ;;
        esac
    done < <(safety_tar_metadata_options)
    if ! safety_snapshot_restore_paths "$ROOTS_FILE" "$LABEL" \
        || ! safety_snapshot_create "$SNAP" "$ROOTS_FILE" \
        || ! safety_snapshot_sysctl_state "$SYSCTL_FILE" "$LABEL" \
        || ! safety_snapshot_iptables_state "$IPTABLES_FILE" "$LABEL" \
        || ! safety_snapshot_ip6tables_state "$IP6TABLES_FILE" "$LABEL"; then
        safety_artifact_remove "$SNAP"
        safety_artifact_remove "$ROOTS_FILE"
        safety_artifact_remove "$SYSCTL_FILE"
        safety_artifact_remove "$IPTABLES_FILE"
        safety_artifact_remove "$IP6TABLES_FILE"
        safety_lock_release
        error "无法保存防断联运行状态"
        return 1
    fi
    if [ "$PROFILE_FIREWALL" = yes ] \
        && [ "${SAFETY_IPTABLES_SNAPSHOT_AVAILABLE:-unknown}" = no ] \
        && command -v iptables-save >/dev/null 2>&1; then
        safety_artifact_remove "$SNAP"
        safety_artifact_remove "$ROOTS_FILE"
        safety_artifact_remove "$SYSCTL_FILE"
        safety_artifact_remove "$IPTABLES_FILE"
        safety_artifact_remove "$IP6TABLES_FILE"
        safety_lock_release
        error "无法读取 iptables 运行状态，拒绝启动不完整的防断联保护"
        return 1
    fi
    if [ "$PROFILE_FIREWALL" = yes ] \
        && [ "${SAFETY_IP6TABLES_SNAPSHOT_AVAILABLE:-unknown}" = no ] \
        && command -v ip6tables-save >/dev/null 2>&1; then
        safety_artifact_remove "$SNAP"
        safety_artifact_remove "$ROOTS_FILE"
        safety_artifact_remove "$SYSCTL_FILE"
        safety_artifact_remove "$IPTABLES_FILE"
        safety_artifact_remove "$IP6TABLES_FILE"
        safety_lock_release
        error "无法读取 ip6tables 运行状态，拒绝启动不完整的防断联保护"
        return 1
    fi
    if [ "$PROFILE_FIREWALL" = yes ]; then
    if command -v ufw >/dev/null 2>&1; then
        UFW_STATUS=$(LC_ALL=C ufw status 2>/dev/null) || {
            safety_artifact_remove "$SNAP"
            safety_artifact_remove "$ROOTS_FILE"
            safety_artifact_remove "$SYSCTL_FILE"
            safety_artifact_remove "$IPTABLES_FILE"
            safety_artifact_remove "$IP6TABLES_FILE"
            safety_lock_release
            error "无法可靠读取 UFW 状态，拒绝启动不完整的防断联保护"
            return 1
        }
        case "$UFW_STATUS" in
            *"Status: active"*) UFW_STATE=active ;;
            *"Status: inactive"*) ;;
            *)
                safety_artifact_remove "$SNAP"
                safety_artifact_remove "$ROOTS_FILE"
                safety_artifact_remove "$SYSCTL_FILE"
                safety_artifact_remove "$IPTABLES_FILE"
                safety_artifact_remove "$IP6TABLES_FILE"
                safety_lock_release
                error "UFW 返回未知状态，拒绝启动不完整的防断联保护"
                return 1
                ;;
        esac
    fi
    svc_is_active firewalld && FIREWALLD_STATE="active"
    svc_is_active nftables && NFTABLES_STATE="active"
    if systemd_available; then
        FIREWALLD_ENABLED_STATE=$(LC_ALL=C systemctl is-enabled firewalld.service 2>/dev/null) \
            || true
        NFTABLES_ENABLED_STATE=$(LC_ALL=C systemctl is-enabled nftables.service 2>/dev/null) \
            || true
        case "$FIREWALLD_ENABLED_STATE" in
            enabled|enabled-runtime|disabled|static|indirect|masked|masked-runtime|not-found) ;;
            *) FIREWALLD_ENABLED_STATE=unavailable ;;
        esac
        case "$NFTABLES_ENABLED_STATE" in
            enabled|enabled-runtime|disabled|static|indirect|masked|masked-runtime|not-found) ;;
            *) NFTABLES_ENABLED_STATE=unavailable ;;
        esac
    elif command -v rc-update >/dev/null 2>&1; then
        RC_UPDATE_STATE=$(rc-update show 2>/dev/null) || {
            safety_artifact_remove "$SNAP"
            safety_artifact_remove "$ROOTS_FILE"
            safety_artifact_remove "$SYSCTL_FILE"
            safety_artifact_remove "$IPTABLES_FILE"
            safety_artifact_remove "$IP6TABLES_FILE"
            safety_lock_release
            error "无法可靠读取 OpenRC 服务启用状态，拒绝启动不完整的防断联保护"
            return 1
        }
        if [ -e /etc/init.d/firewalld ]; then
            FIREWALLD_ENABLED_STATE=$(printf '%s\n' "$RC_UPDATE_STATE" \
                | awk '$1 == "firewalld" {
                    for (i=3; i<=NF; i++) {
                        if ($i == "|") continue
                        out=out (out == "" ? "" : ",") $i
                    }
                } END {print "openrc:" (out == "" ? "none" : out)}')
        else
            FIREWALLD_ENABLED_STATE=not-found
        fi
        if [ -e /etc/init.d/nftables ]; then
            NFTABLES_ENABLED_STATE=$(printf '%s\n' "$RC_UPDATE_STATE" \
                | awk '$1 == "nftables" {
                    for (i=3; i<=NF; i++) {
                        if ($i == "|") continue
                        out=out (out == "" ? "" : ",") $i
                    }
                } END {print "openrc:" (out == "" ? "none" : out)}')
        else
            NFTABLES_ENABLED_STATE=not-found
        fi
    fi
    [ "$UFW_STATE" != active ] || FIREWALL_ACTIVE_COUNT=$((FIREWALL_ACTIVE_COUNT + 1))
    [ "$FIREWALLD_STATE" != active ] || FIREWALL_ACTIVE_COUNT=$((FIREWALL_ACTIVE_COUNT + 1))
    [ "$NFTABLES_STATE" != active ] || FIREWALL_ACTIVE_COUNT=$((FIREWALL_ACTIVE_COUNT + 1))
    if [ "$FIREWALL_ACTIVE_COUNT" -gt 1 ]; then
        safety_artifact_remove "$SNAP"
        safety_artifact_remove "$ROOTS_FILE"
        safety_artifact_remove "$SYSCTL_FILE"
        safety_artifact_remove "$IPTABLES_FILE"
        safety_artifact_remove "$IP6TABLES_FILE"
        safety_lock_release
        error "检测到多个同时活跃的防火墙服务，无法生成无歧义的自动回滚"
        return 1
    fi
    if [ "$UFW_STATE" = active ]; then
        FIREWALL_BACKEND=ufw
    elif [ "$FIREWALLD_STATE" = active ]; then
        FIREWALL_BACKEND=firewalld
    elif [ "$NFTABLES_STATE" = active ]; then
        FIREWALL_BACKEND=nftables
    elif [ -s "$IPTABLES_FILE" ] || [ -s "$IP6TABLES_FILE" ]; then
        FIREWALL_BACKEND=iptables
    fi
    fi
    printf -v SNAP_Q '%q' "$SNAP"
    printf -v SCRIPT_Q '%q' "$SCRIPT"
    printf -v ROOTS_Q '%q' "$ROOTS_FILE"
    printf -v SYSCTL_Q '%q' "$SYSCTL_FILE"
    printf -v IPTABLES_Q '%q' "$IPTABLES_FILE"
    printf -v IP6TABLES_Q '%q' "$IP6TABLES_FILE"
    printf -v STATE_Q '%q' "$STATE_FILE"
    printf -v LABEL_Q '%q' "$LABEL"
    printf -v LOCK_Q '%q' "$LOCK_DIR"
    printf -v RESTORE_Q '%q' "$RESTORE_ROOT"
    if ! cat > "$SCRIPT" <<ROLLBACK_EOF
#!/bin/bash
SNAP=$SNAP_Q
SCRIPT=$SCRIPT_Q
ROOTS_FILE=$ROOTS_Q
SYSCTL_FILE=$SYSCTL_Q
IPTABLES_FILE=$IPTABLES_Q
IP6TABLES_FILE=$IP6TABLES_Q
STATE_FILE=$STATE_Q
LABEL=$LABEL_Q
LOCK_DIR=$LOCK_Q
RESTORE_ROOT=$RESTORE_Q
FIREWALL_BACKEND='$FIREWALL_BACKEND'
UFW_ORIGINAL_STATE='$UFW_STATE'
FIREWALLD_ORIGINAL_STATE='$FIREWALLD_STATE'
NFTABLES_ORIGINAL_STATE='$NFTABLES_STATE'
FIREWALLD_ENABLED_STATE='$FIREWALLD_ENABLED_STATE'
NFTABLES_ENABLED_STATE='$NFTABLES_ENABLED_STATE'
PROFILE_FIREWALL='$PROFILE_FIREWALL'
PROFILE_RESTART_SSH='$PROFILE_RESTART_SSH'
PROFILE_RESTART_FAIL2BAN='$PROFILE_RESTART_FAIL2BAN'
PROFILE_RESTART_DNS='$PROFILE_RESTART_DNS'
PROFILE_RESTART_NETWORK='$PROFILE_RESTART_NETWORK'
NETWORK_BACKEND='$NETWORK_BACKEND'
NETWORK_IFACE='$NETWORK_IFACE'
NETWORK_NM_UUID='$NETWORK_NM_UUID'
TAR_ACLS='$TAR_ACLS'
TAR_XATTRS='$TAR_XATTRS'
TAR_SELINUX='$TAR_SELINUX'
TAR_PAX_VOLATILE='$TAR_PAX_VOLATILE'
APPLIED_SNAPSHOT="\${SCRIPT%.sh}.applied.tar"
APPLIED_ROOTS="\${SCRIPT%.sh}.applied.roots"
FAILED=no
RESTORE_ROOTS=()
RESTORE_DESTS=()
RESTORE_OLDS=()
RESTORE_NEWS=()
RESTORE_HAD_OLD=()
RESTORE_ORIGINAL_IDS=()
RESTORE_INSTALLED=()
RESTORE_INSTALLED_ID=()
RESTORE_COUNT=0
COMMITTED_COUNT=0
RUNTIME_STARTED=no
ROLLBACK_LOCK_OWNER=""
APPLIED_STAGE=""
VERIFY_STAGE=""
TAR_EXTRA=()
[ "\$TAR_ACLS" = yes ] && TAR_EXTRA+=(--acls)
[ "\$TAR_XATTRS" = yes ] && TAR_EXTRA+=(--xattrs)
[ "\$TAR_SELINUX" = yes ] && TAR_EXTRA+=(--selinux)
[ "\$TAR_PAX_VOLATILE" = yes ] \
    && TAR_EXTRA+=(--pax-option=delete=atime,delete=ctime)
rollback_systemd_available() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}
rollback_ssh_socket_active() {
    rollback_systemd_available && systemctl is-active --quiet ssh.socket 2>/dev/null
}
rollback_service_start() {
    local SERVICE_NAME="\$1"
    if rollback_systemd_available; then
        systemctl start "\$SERVICE_NAME" >/dev/null 2>&1
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "\$SERVICE_NAME" start >/dev/null 2>&1
    elif command -v service >/dev/null 2>&1; then
        service "\$SERVICE_NAME" start >/dev/null 2>&1
    else
        return 1
    fi
}
rollback_service_stop() {
    local SERVICE_NAME="\$1"
    if rollback_systemd_available; then
        systemctl stop "\$SERVICE_NAME" >/dev/null 2>&1
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "\$SERVICE_NAME" stop >/dev/null 2>&1
    elif command -v service >/dev/null 2>&1; then
        service "\$SERVICE_NAME" stop >/dev/null 2>&1
    else
        return 1
    fi
}
rollback_service_restart() {
    local SERVICE_NAME="\$1"
    if rollback_systemd_available; then
        systemctl restart "\$SERVICE_NAME" >/dev/null 2>&1
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "\$SERVICE_NAME" restart >/dev/null 2>&1
    elif command -v service >/dev/null 2>&1; then
        service "\$SERVICE_NAME" restart >/dev/null 2>&1
    else
        return 1
    fi
}
rollback_service_restart_if_present() {
    local SERVICE_NAME="\$1" UNIT_FILES=""
    if rollback_systemd_available; then
        UNIT_FILES=\$(systemctl list-unit-files "\${SERVICE_NAME}.service" \
            --no-legend 2>/dev/null) || return 1
        printf '%s\n' "\$UNIT_FILES" \
            | awk -v unit="\${SERVICE_NAME}.service" \
                '\$1 == unit {found=1} END {exit !found}' || return 0
    elif [ ! -e "/etc/init.d/\$SERVICE_NAME" ]; then
        return 0
    fi
    rollback_service_restart "\$SERVICE_NAME"
}
rollback_process_start_token() {
    local PROCESS_PID="\$1" PROCESS_STAT="" PROCESS_REST="" TOKEN=""
    [[ "\$PROCESS_PID" =~ ^[1-9][0-9]*$ ]] || return 1
    if [ -r "/proc/\${PROCESS_PID}/stat" ]; then
        IFS= read -r PROCESS_STAT < "/proc/\${PROCESS_PID}/stat" || return 1
        PROCESS_REST=\${PROCESS_STAT##*) }
        TOKEN=\$(printf '%s\n' "\$PROCESS_REST" | awk '{print \$20}') || return 1
    elif command -v ps >/dev/null 2>&1; then
        TOKEN=\$(LC_ALL=C ps -p "\$PROCESS_PID" -o lstart= 2>/dev/null) || return 1
        TOKEN=\$(printf '%s\n' "\$TOKEN" | awk '{\$1=\$1; print}')
    fi
    [ -n "\$TOKEN" ] || return 1
    printf '%s\n' "\$TOKEN"
}
rollback_lock_owner_valid() {
    local OWNER="\$1" OWNER_PID OWNER_TOKEN CURRENT_TOKEN
    case "\$OWNER" in *'|'*) ;; *) return 1 ;; esac
    OWNER_PID=\${OWNER%%|*}
    OWNER_TOKEN=\${OWNER#*|}
    [[ "\$OWNER_PID" =~ ^[1-9][0-9]*$ ]] && [ -n "\$OWNER_TOKEN" ] \
        && kill -0 "\$OWNER_PID" 2>/dev/null || return 1
    CURRENT_TOKEN=\$(rollback_process_start_token "\$OWNER_PID") || return 1
    [ "\$CURRENT_TOKEN" = "\$OWNER_TOKEN" ]
}
release_rollback_lock() {
    if [ -f "\$LOCK_DIR/pid" ] \
        && [ "\$(cat "\$LOCK_DIR/pid" 2>/dev/null)" = "\$ROLLBACK_LOCK_OWNER" ]; then
        rm -f "\$LOCK_DIR/pid" >/dev/null 2>&1 || true
        rmdir "\$LOCK_DIR" >/dev/null 2>&1 || true
    fi
}
acquire_rollback_lock() {
    local LOCK_OWNER="" LOCK_OWNER_AFTER="" SELF_TOKEN=""
    while true; do
        if mkdir "\$LOCK_DIR" 2>/dev/null; then
            SELF_TOKEN=\$(rollback_process_start_token "\$\$") || SELF_TOKEN=""
            ROLLBACK_LOCK_OWNER="\$\$|\$SELF_TOKEN"
            if [ -n "\$SELF_TOKEN" ] \
                && printf '%s\n' "\$ROLLBACK_LOCK_OWNER" > "\$LOCK_DIR/pid" 2>/dev/null; then
                return 0
            fi
            rm -f "\$LOCK_DIR/pid" >/dev/null 2>&1 || true
            rmdir "\$LOCK_DIR" >/dev/null 2>&1 || true
            sleep 1
            continue
        fi
        LOCK_OWNER=\$(cat "\$LOCK_DIR/pid" 2>/dev/null || true)
        if rollback_lock_owner_valid "\$LOCK_OWNER"; then
            sleep 1
            continue
        fi
        # Do not remove a lock in the tiny interval between mkdir and PID write.
        sleep 1
        LOCK_OWNER_AFTER=\$(cat "\$LOCK_DIR/pid" 2>/dev/null || true)
        if rollback_lock_owner_valid "\$LOCK_OWNER_AFTER"; then
            continue
        fi
        if [ "\$LOCK_OWNER" = "\$LOCK_OWNER_AFTER" ]; then
            rm -f "\$LOCK_DIR/pid" >/dev/null 2>&1 || true
            rmdir "\$LOCK_DIR" >/dev/null 2>&1 || true
        fi
    done
}
write_rollback_state() {
    local NEXT_STATUS="\$1" STATE_TMP
    local CURRENT_PID CURRENT_SCRIPT CURRENT_ROOTS CURRENT_SYSCTL CURRENT_SNAP CURRENT_STATUS
    IFS='|' read -r CURRENT_PID CURRENT_SCRIPT CURRENT_ROOTS CURRENT_SYSCTL \
        CURRENT_SNAP CURRENT_STATUS < "\$STATE_FILE" 2>/dev/null || return 1
    [ "\$CURRENT_PID" = "\$\$" ] && [ "\$CURRENT_SCRIPT" = "\$SCRIPT" ] \
        && [ "\$CURRENT_ROOTS" = "\$ROOTS_FILE" ] \
        && [ "\$CURRENT_SYSCTL" = "\$SYSCTL_FILE" ] \
        && [ "\$CURRENT_SNAP" = "\$SNAP" ] || return 1
    case "\$CURRENT_STATUS" in armed|applied|restoring) ;; *) return 1 ;; esac
    STATE_TMP=\$(mktemp "\${STATE_FILE}.tmp.XXXXXX") || return 1
    if printf '%s|%s|%s|%s|%s|%s\n' \
        "\$\$" "\$SCRIPT" "\$ROOTS_FILE" "\$SYSCTL_FILE" "\$SNAP" \
        "\$NEXT_STATUS" > "\$STATE_TMP" \
        && chmod 600 "\$STATE_TMP" 2>/dev/null \
        && mv -f -- "\$STATE_TMP" "\$STATE_FILE"; then
        return 0
    fi
    rm -f -- "\$STATE_TMP"
    return 1
}
mark_rollback_failed() {
    write_rollback_state failed || true
    logger -t vps-tools "自动恢复 \$LABEL 配置失败，快照已保留：\$SNAP" >/dev/null 2>&1 || true
}
rollback_path_identity() {
    # Identify the directory entry itself.  Do not dereference symlinks:
    # resolv.conf may legitimately be a dangling link during recovery.
    stat -c '%d:%i' -- "\$1" 2>/dev/null
}
rollback_roots_match() {
    local ROOT="\$1" LEFT_ROOT="\$2" RIGHT_ROOT="\$3"
    local LEFT_TAR="" RIGHT_TAR="" RESULT=1
    LEFT_TAR=\$(mktemp "\${TMPDIR:-/tmp}/vps-tools-compare-left.XXXXXX") \
        || LEFT_TAR=""
    RIGHT_TAR=\$(mktemp "\${TMPDIR:-/tmp}/vps-tools-compare-right.XXXXXX") \
        || RIGHT_TAR=""
    if [ -n "\$LEFT_TAR" ] && [ -n "\$RIGHT_TAR" ] \
        && tar "\${TAR_EXTRA[@]}" -cf "\$LEFT_TAR" \
            -C "\$LEFT_ROOT" "\$ROOT" 2>/dev/null \
        && tar "\${TAR_EXTRA[@]}" -cf "\$RIGHT_TAR" \
            -C "\$RIGHT_ROOT" "\$ROOT" 2>/dev/null \
        && cmp -s "\$LEFT_TAR" "\$RIGHT_TAR"; then
        RESULT=0
    fi
    [ -z "\$LEFT_TAR" ] || rm -f -- "\$LEFT_TAR"
    [ -z "\$RIGHT_TAR" ] || rm -f -- "\$RIGHT_TAR"
    return "\$RESULT"
}
cleanup_prepared_news() {
    local INDEX=0 NEW RESULT=0
    while [ "\$INDEX" -lt "\$RESTORE_COUNT" ]; do
        NEW="\${RESTORE_NEWS[\$INDEX]}"
        if { [ -e "\$NEW" ] || [ -L "\$NEW" ]; } \
            && ! rm -rf -- "\$NEW" >/dev/null 2>&1; then
            RESULT=1
        fi
        INDEX=\$((INDEX + 1))
    done
    return "\$RESULT"
}
rollback_committed_files() {
    local INDEX DEST OLD HAD_OLD INSTALLED EXPECTED_ID CURRENT_ID RESULT=0
    INDEX=\$((COMMITTED_COUNT - 1))
    while [ "\$INDEX" -ge 0 ]; do
        DEST="\${RESTORE_DESTS[\$INDEX]}"
        OLD="\${RESTORE_OLDS[\$INDEX]}"
        HAD_OLD="\${RESTORE_HAD_OLD[\$INDEX]:-no}"
        INSTALLED="\${RESTORE_INSTALLED[\$INDEX]:-no}"
        EXPECTED_ID="\${RESTORE_INSTALLED_ID[\$INDEX]:-}"
        if [ "\$INSTALLED" = yes ]; then
            CURRENT_ID=\$(rollback_path_identity "\$DEST") || CURRENT_ID=""
            if [ -z "\$EXPECTED_ID" ] || [ "\$CURRENT_ID" != "\$EXPECTED_ID" ] \
                || ! rollback_roots_match \
                    "\${RESTORE_ROOTS[\$INDEX]}" "\$STAGE" "\$RESTORE_ROOT"; then
                RESULT=1
                INDEX=\$((INDEX - 1))
                continue
            fi
            if ! rm -rf -- "\$DEST" >/dev/null 2>&1; then
                RESULT=1
                INDEX=\$((INDEX - 1))
                continue
            fi
        elif [ -e "\$DEST" ] || [ -L "\$DEST" ]; then
            # A path appeared after the transaction began.  Preserve it and
            # retain OLD for manual recovery instead of overwriting it.
            RESULT=1
            INDEX=\$((INDEX - 1))
            continue
        fi
        if [ "\$HAD_OLD" = yes ]; then
            if { [ -e "\$OLD" ] || [ -L "\$OLD" ]; } \
                && mv "\$OLD" "\$DEST" >/dev/null 2>&1; then
                :
            else
                RESULT=1
            fi
        fi
        INDEX=\$((INDEX - 1))
    done
    cleanup_prepared_news || RESULT=1
    return "\$RESULT"
}
cleanup_committed_backups() {
    local INDEX=0 OLD NEW RESULT=0
    while [ "\$INDEX" -lt "\$RESTORE_COUNT" ]; do
        OLD="\${RESTORE_OLDS[\$INDEX]}"
        NEW="\${RESTORE_NEWS[\$INDEX]}"
        if { [ -e "\$OLD" ] || [ -L "\$OLD" ]; } \
            && ! rm -rf -- "\$OLD" >/dev/null 2>&1; then
            RESULT=1
        fi
        if { [ -e "\$NEW" ] || [ -L "\$NEW" ]; } \
            && ! rm -rf -- "\$NEW" >/dev/null 2>&1; then
            RESULT=1
        fi
        INDEX=\$((INDEX + 1))
    done
    return "\$RESULT"
}
rollback_interrupted() {
    trap - TERM INT HUP
    if [ "\$RUNTIME_STARTED" = no ] && rollback_committed_files; then
        COMMITTED_COUNT=0
    fi
    [ -z "\${STAGE:-}" ] || rm -rf -- "\$STAGE"
    [ -z "\$APPLIED_STAGE" ] || rm -rf -- "\$APPLIED_STAGE"
    [ -z "\$VERIFY_STAGE" ] || rm -rf -- "\$VERIFY_STAGE"
    mark_rollback_failed
    release_rollback_lock
    exit 1
}
sleep $ROLLBACK_DELAY
acquire_rollback_lock
trap release_rollback_lock EXIT
trap rollback_interrupted TERM INT HUP
IFS='|' read -r STATE_PID STATE_SCRIPT STATE_ROOTS STATE_SYSCTL STATE_SNAP STATE_STATUS \
    < "\$STATE_FILE" 2>/dev/null || exit 1
if [ "\$STATE_PID" != "\$\$" ] || [ "\$STATE_SCRIPT" != "\$SCRIPT" ] \
    || [ "\$STATE_ROOTS" != "\$ROOTS_FILE" ] \
    || [ "\$STATE_SYSCTL" != "\$SYSCTL_FILE" ] \
    || [ "\$STATE_SNAP" != "\$SNAP" ]; then
    exit 1
fi
if [ "\$STATE_STATUS" = cancelled ]; then
    rm -f -- "\$SNAP" "\$ROOTS_FILE" "\$SYSCTL_FILE" \
        "\$IPTABLES_FILE" "\$IP6TABLES_FILE" \
        "\$APPLIED_SNAPSHOT" "\$APPLIED_ROOTS" \
        "\$SCRIPT" "\$STATE_FILE" >/dev/null 2>&1 || true
    exit 0
fi
case "\$STATE_STATUS" in
    armed) ;;
    applied)
        [ -f "\$APPLIED_SNAPSHOT" ] && [ -f "\$APPLIED_ROOTS" ] || {
            mark_rollback_failed
            exit 1
        }
        CURRENT_APPLIED=\$(mktemp "\${TMPDIR:-/tmp}/vps-tools-current.XXXXXX") || {
            mark_rollback_failed
            exit 1
        }
        CURRENT_ROOTS=\$(mktemp "\${TMPDIR:-/tmp}/vps-tools-current-roots.XXXXXX") || {
            rm -f -- "\$CURRENT_APPLIED"
            mark_rollback_failed
            exit 1
        }
        : > "\$CURRENT_ROOTS" || {
            rm -f -- "\$CURRENT_APPLIED" "\$CURRENT_ROOTS"
            mark_rollback_failed
            exit 1
        }
        while IFS= read -r ROOT; do
            case "\$ROOT" in
                etc/*|root/*|var/spool/cron/*) ;;
                *)
                    rm -f -- "\$CURRENT_APPLIED" "\$CURRENT_ROOTS"
                    mark_rollback_failed
                    exit 1
                    ;;
            esac
            [ -e "\${RESTORE_ROOT%/}/\$ROOT" ] \
                || [ -L "\${RESTORE_ROOT%/}/\$ROOT" ] || continue
            printf '%s\n' "\$ROOT" >> "\$CURRENT_ROOTS" || {
                rm -f -- "\$CURRENT_APPLIED" "\$CURRENT_ROOTS"
                mark_rollback_failed
                exit 1
            }
        done < "\$ROOTS_FILE"
        if ! tar "\${TAR_EXTRA[@]}" -cf "\$CURRENT_APPLIED" -C "\$RESTORE_ROOT" \
                -T "\$CURRENT_ROOTS" 2>/dev/null \
            || ! cmp -s "\$APPLIED_ROOTS" "\$CURRENT_ROOTS" \
            || ! cmp -s "\$APPLIED_SNAPSHOT" "\$CURRENT_APPLIED"; then
            rm -f -- "\$CURRENT_APPLIED" "\$CURRENT_ROOTS"
            mark_rollback_failed
            exit 1
        fi
        rm -f -- "\$CURRENT_APPLIED" "\$CURRENT_ROOTS"
        APPLIED_STAGE=\$(mktemp -d "\${TMPDIR:-/tmp}/vps-tools-applied.XXXXXX") || {
            mark_rollback_failed
            exit 1
        }
        VERIFY_STAGE=\$(mktemp -d "\${TMPDIR:-/tmp}/vps-tools-verify.XXXXXX") || {
            rm -rf -- "\$APPLIED_STAGE"
            mark_rollback_failed
            exit 1
        }
        if ! tar "\${TAR_EXTRA[@]}" -xf "\$APPLIED_SNAPSHOT" \
            -C "\$APPLIED_STAGE" >/dev/null 2>&1; then
            rm -rf -- "\$APPLIED_STAGE" "\$VERIFY_STAGE"
            mark_rollback_failed
            exit 1
        fi
        ;;
    *)
        mark_rollback_failed
        exit 1
        ;;
esac
write_rollback_state restoring || {
        mark_rollback_failed
        exit 1
    }
STAGE=\$(mktemp -d "\${TMPDIR:-/tmp}/vps-tools-rollback.XXXXXX") || {
    mark_rollback_failed
    exit 1
}
TXN_ID="\${STAGE##*/}"
if tar "\${TAR_EXTRA[@]}" -xzf "\$SNAP" -C "\$STAGE" >/dev/null 2>&1; then
    while IFS= read -r ROOT; do
        case "\$ROOT" in
            etc/*|root/*|var/spool/cron/*)
                SRC="\$STAGE/\$ROOT"
                DEST="\${RESTORE_ROOT%/}/\$ROOT"
                OLD="\${DEST}.vps-tools-old.\${TXN_ID}"
                NEW="\${DEST}.vps-tools-new.\${TXN_ID}"
                if [ -e "\$OLD" ] || [ -L "\$OLD" ] \
                    || [ -e "\$NEW" ] || [ -L "\$NEW" ]; then
                    FAILED=yes
                    break
                fi
                ORIGINAL_ID=""
                if [ -e "\$DEST" ] || [ -L "\$DEST" ]; then
                    ORIGINAL_ID=\$(rollback_path_identity "\$DEST") || {
                        FAILED=yes
                        break
                    }
                fi
                if [ -e "\$SRC" ] || [ -L "\$SRC" ]; then
                    if ! mkdir -p "\$(dirname "\$DEST")" >/dev/null 2>&1 \
                        || ! cp -a "\$SRC" "\$NEW" >/dev/null 2>&1; then
                        rm -rf -- "\$NEW" >/dev/null 2>&1 || true
                        FAILED=yes
                        break
                    fi
                fi
                RESTORE_ROOTS[\$RESTORE_COUNT]="\$ROOT"
                RESTORE_DESTS[\$RESTORE_COUNT]="\$DEST"
                RESTORE_OLDS[\$RESTORE_COUNT]="\$OLD"
                RESTORE_NEWS[\$RESTORE_COUNT]="\$NEW"
                RESTORE_HAD_OLD[\$RESTORE_COUNT]=no
                RESTORE_ORIGINAL_IDS[\$RESTORE_COUNT]="\$ORIGINAL_ID"
                RESTORE_INSTALLED[\$RESTORE_COUNT]=no
                RESTORE_INSTALLED_ID[\$RESTORE_COUNT]=""
                RESTORE_COUNT=\$((RESTORE_COUNT + 1))
                ;;
            *) FAILED=yes; break ;;
        esac
    done < "\$ROOTS_FILE"
else
    FAILED=yes
fi
if [ "\$FAILED" = no ] && [ "\$STATE_STATUS" = applied ]; then
    CURRENT_APPLIED=\$(mktemp "\${TMPDIR:-/tmp}/vps-tools-current.XXXXXX") \
        || CURRENT_APPLIED=""
    CURRENT_ROOTS=\$(mktemp "\${TMPDIR:-/tmp}/vps-tools-current-roots.XXXXXX") \
        || CURRENT_ROOTS=""
    if [ -z "\$CURRENT_APPLIED" ] || [ -z "\$CURRENT_ROOTS" ]; then
        FAILED=yes
    else
        : > "\$CURRENT_ROOTS" || FAILED=yes
        if [ "\$FAILED" = no ]; then
            while IFS= read -r ROOT; do
                case "\$ROOT" in
                    etc/*|root/*|var/spool/cron/*) ;;
                    *) FAILED=yes; break ;;
                esac
                [ -e "\${RESTORE_ROOT%/}/\$ROOT" ] \
                    || [ -L "\${RESTORE_ROOT%/}/\$ROOT" ] || continue
                printf '%s\n' "\$ROOT" >> "\$CURRENT_ROOTS" \
                    || { FAILED=yes; break; }
            done < "\$ROOTS_FILE"
        fi
        if [ "\$FAILED" = no ] \
            && { ! tar "\${TAR_EXTRA[@]}" -cf "\$CURRENT_APPLIED" \
                    -C "\$RESTORE_ROOT" -T "\$CURRENT_ROOTS" 2>/dev/null \
                || ! cmp -s "\$APPLIED_ROOTS" "\$CURRENT_ROOTS" \
                || ! cmp -s "\$APPLIED_SNAPSHOT" "\$CURRENT_APPLIED"; }; then
            FAILED=yes
        fi
    fi
    [ -z "\$CURRENT_APPLIED" ] || rm -f -- "\$CURRENT_APPLIED"
    [ -z "\$CURRENT_ROOTS" ] || rm -f -- "\$CURRENT_ROOTS"
fi
if [ "\$FAILED" = no ]; then
    INDEX=0
    while [ "\$INDEX" -lt "\$RESTORE_COUNT" ]; do
        SRC="\$STAGE/\${RESTORE_ROOTS[\$INDEX]}"
        DEST="\${RESTORE_DESTS[\$INDEX]}"
        OLD="\${RESTORE_OLDS[\$INDEX]}"
        NEW="\${RESTORE_NEWS[\$INDEX]}"
        EXPECTED_ORIGINAL_ID="\${RESTORE_ORIGINAL_IDS[\$INDEX]}"
        if [ -n "\$EXPECTED_ORIGINAL_ID" ]; then
            CURRENT_ORIGINAL_ID=\$(rollback_path_identity "\$DEST") \
                || CURRENT_ORIGINAL_ID=""
            if [ "\$CURRENT_ORIGINAL_ID" != "\$EXPECTED_ORIGINAL_ID" ]; then
                FAILED=yes
                break
            fi
            if ! mv "\$DEST" "\$OLD" >/dev/null 2>&1; then
                FAILED=yes
                break
            fi
            CURRENT_ORIGINAL_ID=\$(rollback_path_identity "\$OLD") \
                || CURRENT_ORIGINAL_ID=""
            if [ "\$CURRENT_ORIGINAL_ID" != "\$EXPECTED_ORIGINAL_ID" ]; then
                [ -e "\$DEST" ] || [ -L "\$DEST" ] \
                    || mv "\$OLD" "\$DEST" >/dev/null 2>&1 || true
                FAILED=yes
                break
            fi
            if [ "\$STATE_STATUS" = applied ]; then
                VERIFY_PATH="\$VERIFY_STAGE/\${RESTORE_ROOTS[\$INDEX]}"
                rm -rf -- "\$VERIFY_PATH" >/dev/null 2>&1 || {
                    [ -e "\$DEST" ] || [ -L "\$DEST" ] \
                        || mv "\$OLD" "\$DEST" >/dev/null 2>&1 || true
                    FAILED=yes
                    break
                }
                mkdir -p "\$(dirname "\$VERIFY_PATH")" >/dev/null 2>&1 \
                    && cp -a "\$OLD" "\$VERIFY_PATH" >/dev/null 2>&1 \
                    && rollback_roots_match \
                        "\${RESTORE_ROOTS[\$INDEX]}" \
                        "\$APPLIED_STAGE" "\$VERIFY_STAGE" || {
                    rm -rf -- "\$VERIFY_PATH" >/dev/null 2>&1 || true
                    [ -e "\$DEST" ] || [ -L "\$DEST" ] \
                        || mv "\$OLD" "\$DEST" >/dev/null 2>&1 || true
                    FAILED=yes
                    break
                }
                rm -rf -- "\$VERIFY_PATH" >/dev/null 2>&1 || true
            fi
            RESTORE_HAD_OLD[\$INDEX]=yes
        elif [ -e "\$DEST" ] || [ -L "\$DEST" ]; then
            FAILED=yes
            break
        fi
        COMMITTED_COUNT=\$((INDEX + 1))
        if [ -e "\$SRC" ] || [ -L "\$SRC" ]; then
            if [ -e "\$DEST" ] || [ -L "\$DEST" ] \
                || ! mv "\$NEW" "\$DEST" >/dev/null 2>&1; then
                FAILED=yes
                break
            fi
            RESTORE_INSTALLED[\$INDEX]=yes
            RESTORE_INSTALLED_ID[\$INDEX]=\$(rollback_path_identity "\$DEST") || {
                FAILED=yes
                break
            }
        elif [ -e "\$DEST" ] || [ -L "\$DEST" ]; then
            FAILED=yes
            break
        fi
        INDEX=\$((INDEX + 1))
    done
fi
if [ "\$FAILED" = yes ]; then
    if [ "\$COMMITTED_COUNT" -gt 0 ]; then
        if rollback_committed_files; then
            COMMITTED_COUNT=0
        fi
    else
        cleanup_prepared_news || true
    fi
fi
if [ "\$FAILED" = no ]; then
    RUNTIME_STARTED=yes
fi
rm -rf -- "\$STAGE"
rm -rf -- "\$APPLIED_STAGE" "\$VERIFY_STAGE"
if [ "\$FAILED" = no ] && [ "\$RESTORE_ROOT" = / ]; then
if [ "\$PROFILE_RESTART_SSH" = yes ] && command -v sshd >/dev/null 2>&1; then
    if ! sshd -t >/dev/null 2>&1; then
        FAILED=yes
    elif rollback_ssh_socket_active \
        && { ! systemctl daemon-reload >/dev/null 2>&1 \
            || ! systemctl restart ssh.socket >/dev/null 2>&1; }; then
        FAILED=yes
    elif ! (rollback_service_restart ssh || rollback_service_restart sshd); then
        FAILED=yes
    fi
fi
if [ "\$PROFILE_RESTART_FAIL2BAN" = yes ] \
    && command -v fail2ban-client >/dev/null 2>&1; then
    rollback_service_restart_if_present fail2ban || FAILED=yes
fi
if [ "\$PROFILE_RESTART_DNS" = yes ]; then
    rollback_service_restart_if_present systemd-resolved || FAILED=yes
    rollback_service_restart_if_present NetworkManager || FAILED=yes
fi
if [ "\$PROFILE_RESTART_NETWORK" = yes ]; then
    case "\$NETWORK_BACKEND" in
        netplan)
            command -v netplan >/dev/null 2>&1 \
                && netplan generate >/dev/null 2>&1 \
                && netplan apply >/dev/null 2>&1 || FAILED=yes
            ;;
        networkmanager)
            if command -v nmcli >/dev/null 2>&1 \
                && nmcli connection reload >/dev/null 2>&1; then
                if [ -n "\$NETWORK_NM_UUID" ]; then
                    nmcli connection up uuid "\$NETWORK_NM_UUID" \
                        ifname "\$NETWORK_IFACE" >/dev/null 2>&1 || FAILED=yes
                else
                    nmcli device disconnect "\$NETWORK_IFACE" >/dev/null 2>&1 || true
                    nmcli device connect "\$NETWORK_IFACE" >/dev/null 2>&1 || FAILED=yes
                fi
            else
                FAILED=yes
            fi
            ;;
        networkd)
            if command -v networkctl >/dev/null 2>&1; then
                networkctl reload >/dev/null 2>&1 \
                    && { networkctl reconfigure "\$NETWORK_IFACE" >/dev/null 2>&1 \
                        || rollback_service_restart systemd-networkd; } \
                    || FAILED=yes
            else
                rollback_service_restart systemd-networkd || FAILED=yes
            fi
            ;;
        ifupdown)
            if command -v ifdown >/dev/null 2>&1 && command -v ifup >/dev/null 2>&1; then
                ifdown --force "\$NETWORK_IFACE" >/dev/null 2>&1 || true
                ifup "\$NETWORK_IFACE" >/dev/null 2>&1 || FAILED=yes
            else
                FAILED=yes
            fi
            ;;
        ifcfg)
            if command -v nmcli >/dev/null 2>&1; then
                nmcli connection reload >/dev/null 2>&1 \
                    && { nmcli connection up "\$NETWORK_IFACE" \
                            ifname "\$NETWORK_IFACE" >/dev/null 2>&1 \
                        || nmcli device connect "\$NETWORK_IFACE" >/dev/null 2>&1; } \
                    || FAILED=yes
            elif command -v ifup >/dev/null 2>&1; then
                ifdown "\$NETWORK_IFACE" >/dev/null 2>&1 || true
                ifup "\$NETWORK_IFACE" >/dev/null 2>&1 || FAILED=yes
            else
                rollback_service_restart network || FAILED=yes
            fi
            ;;
        *) FAILED=yes ;;
    esac
fi
if [ "\$PROFILE_FIREWALL" = yes ]; then
if command -v ufw >/dev/null 2>&1 && [ "\$UFW_ORIGINAL_STATE" = inactive ]; then
    UFW_CURRENT=\$(LC_ALL=C ufw status 2>/dev/null) || UFW_CURRENT=""
    case "\$UFW_CURRENT" in
        *"Status: active"*) ufw --force disable >/dev/null 2>&1 || FAILED=yes ;;
        *"Status: inactive"*) ;;
        *) FAILED=yes ;;
    esac
fi
if rollback_systemd_available \
    || command -v rc-service >/dev/null 2>&1 \
    || command -v service >/dev/null 2>&1; then
    if [ "\$FIREWALLD_ORIGINAL_STATE" = inactive ]; then
        case "\$FIREWALLD_ENABLED_STATE" in
            not-found|unavailable) ;;
            *) rollback_service_stop firewalld || FAILED=yes ;;
        esac
    fi
    if [ "\$NFTABLES_ORIGINAL_STATE" = inactive ]; then
        case "\$NFTABLES_ENABLED_STATE" in
            not-found|unavailable) ;;
            *) rollback_service_stop nftables || FAILED=yes ;;
        esac
    fi
fi
case "\$FIREWALL_BACKEND" in
    ufw)
        command -v ufw >/dev/null 2>&1 \
            && ufw --force enable >/dev/null 2>&1 || FAILED=yes
        ;;
    firewalld)
        command -v firewall-cmd >/dev/null 2>&1 \
            && rollback_service_start firewalld \
            && firewall-cmd --reload >/dev/null 2>&1 || FAILED=yes
        ;;
    nftables)
        if rollback_systemd_available \
            || command -v rc-service >/dev/null 2>&1 \
            || command -v service >/dev/null 2>&1; then
            rollback_service_restart nftables || FAILED=yes
        elif command -v nft >/dev/null 2>&1 && [ -f /etc/nftables.conf ]; then
            nft -f /etc/nftables.conf >/dev/null 2>&1 || FAILED=yes
        else
            FAILED=yes
        fi
        ;;
    iptables)
        if [ -s "\$IPTABLES_FILE" ]; then
            if command -v iptables-restore >/dev/null 2>&1; then
                iptables-restore < "\$IPTABLES_FILE" >/dev/null 2>&1 || FAILED=yes
            else
                FAILED=yes
            fi
        fi
        if [ -s "\$IP6TABLES_FILE" ]; then
            if command -v ip6tables-restore >/dev/null 2>&1; then
                ip6tables-restore < "\$IP6TABLES_FILE" >/dev/null 2>&1 || FAILED=yes
            else
                FAILED=yes
            fi
        fi
        ;;
esac
restore_unit_enabled_state() {
    local UNIT="\$1" ORIGINAL="\$2" SERVICE_NAME="\${1%.service}"
    if rollback_systemd_available; then
        case "\$ORIGINAL" in
            enabled) systemctl enable "\$UNIT" >/dev/null 2>&1 ;;
            enabled-runtime) systemctl enable --runtime "\$UNIT" >/dev/null 2>&1 ;;
            disabled) systemctl disable "\$UNIT" >/dev/null 2>&1 ;;
            masked) systemctl mask "\$UNIT" >/dev/null 2>&1 ;;
            masked-runtime) systemctl mask --runtime "\$UNIT" >/dev/null 2>&1 ;;
            static|indirect|not-found|unavailable) return 0 ;;
            *) return 1 ;;
        esac
    elif command -v rc-update >/dev/null 2>&1; then
        case "\$ORIGINAL" in
            openrc:*)
                ORIGINAL_LEVELS="\${ORIGINAL#openrc:}"
                RC_STATE=\$(rc-update show 2>/dev/null) || return 1
                CURRENT_LEVELS=\$(printf '%s\n' "\$RC_STATE" \
                    | awk -v service="\$SERVICE_NAME" '
                        \$1 == service {
                            for (i=3; i<=NF; i++) {
                                if (\$i == "|") continue
                                out=out (out == "" ? "" : ",") \$i
                            }
                        }
                        END {print (out == "" ? "none" : out)}
                    ')
                if [ "\$CURRENT_LEVELS" != none ]; then
                    rc-update del "\$SERVICE_NAME" >/dev/null 2>&1 || return 1
                fi
                if [ "\$ORIGINAL_LEVELS" != none ]; then
                    OLD_IFS="\$IFS"
                    IFS=,
                    for RUNLEVEL in \$ORIGINAL_LEVELS; do
                        case "\$RUNLEVEL" in
                            ""|*[!A-Za-z0-9_.-]*) IFS="\$OLD_IFS"; return 1 ;;
                        esac
                        rc-update add "\$SERVICE_NAME" "\$RUNLEVEL" \
                            >/dev/null 2>&1 || {
                            IFS="\$OLD_IFS"
                            return 1
                        }
                    done
                    IFS="\$OLD_IFS"
                fi
                RC_STATE=\$(rc-update show 2>/dev/null) || return 1
                CURRENT_LEVELS=\$(printf '%s\n' "\$RC_STATE" \
                    | awk -v service="\$SERVICE_NAME" '
                        \$1 == service {
                            for (i=3; i<=NF; i++) {
                                if (\$i == "|") continue
                                out=out (out == "" ? "" : ",") \$i
                            }
                        }
                        END {print (out == "" ? "none" : out)}
                    ')
                [ "\$CURRENT_LEVELS" = "\$ORIGINAL_LEVELS" ] || return 1
                ;;
            not-found|unavailable) return 0 ;;
            *) return 1 ;;
        esac
    else
        case "\$ORIGINAL" in not-found|unavailable) return 0 ;; *) return 1 ;; esac
    fi
}
if rollback_systemd_available || command -v rc-update >/dev/null 2>&1; then
    restore_unit_enabled_state firewalld.service "\$FIREWALLD_ENABLED_STATE" \
        || FAILED=yes
    restore_unit_enabled_state nftables.service "\$NFTABLES_ENABLED_STATE" \
        || FAILED=yes
fi
fi
if command -v sysctl >/dev/null 2>&1 && [ -f "\$SYSCTL_FILE" ]; then
    while IFS='=' read -r KEY VALUE; do
        case "\$VALUE" in ''|*[!0-9-]*) continue ;; esac
        case "\$KEY" in
            net.ipv6.conf.all.disable_ipv6|\
            net.ipv6.conf.default.disable_ipv6|\
            net.ipv6.conf.lo.disable_ipv6|\
            net.ipv4.conf.all.promote_secondaries)
                sysctl -w "\$KEY=\$VALUE" >/dev/null 2>&1 || FAILED=yes
                ;;
        esac
    done < "\$SYSCTL_FILE"
fi
fi
if [ "\$FAILED" = no ]; then
    COMMITTED_COUNT=0
    cleanup_committed_backups || FAILED=yes
fi
if [ "\$FAILED" = yes ]; then
    mark_rollback_failed
    exit 1
fi
logger -t vps-tools "未确认连接，已自动恢复 \$LABEL 配置" >/dev/null 2>&1 || true
rm -f -- "\$SNAP" "\$ROOTS_FILE" "\$SYSCTL_FILE" \
    "\$IPTABLES_FILE" "\$IP6TABLES_FILE" \
    "\$APPLIED_SNAPSHOT" "\$APPLIED_ROOTS" "\$SCRIPT" >/dev/null 2>&1 || true
rm -f -- "\$STATE_FILE" >/dev/null 2>&1 || true
ROLLBACK_EOF
    then
        safety_artifact_remove "$SCRIPT"
        safety_artifact_remove "$ROOTS_FILE"
        safety_artifact_remove "$SYSCTL_FILE"
        safety_artifact_remove "$IPTABLES_FILE"
        safety_artifact_remove "$IP6TABLES_FILE"
        safety_artifact_remove "$SNAP"
        safety_lock_release
        return 1
    fi
    if ! chmod 700 "$SCRIPT"; then
        safety_artifact_remove "$SCRIPT"
        safety_artifact_remove "$ROOTS_FILE"
        safety_artifact_remove "$SYSCTL_FILE"
        safety_artifact_remove "$IPTABLES_FILE"
        safety_artifact_remove "$IP6TABLES_FILE"
        safety_artifact_remove "$SNAP"
        safety_lock_release
        return 1
    fi
    nohup bash "$SCRIPT" >/dev/null 2>&1 &
    SAFETY_PID=$!
    SAFETY_SCRIPT="$SCRIPT"
    SAFETY_ROOTS_FILE="$ROOTS_FILE"
    SAFETY_SYSCTL_FILE="$SYSCTL_FILE"
    SAFETY_IPTABLES_FILE="$IPTABLES_FILE"
    SAFETY_IP6TABLES_FILE="$IP6TABLES_FILE"
    SAFETY_APPLIED_SNAPSHOT="${SCRIPT%.sh}.applied.tar"
    SAFETY_APPLIED_ROOTS="${SCRIPT%.sh}.applied.roots"
    SAFETY_SNAPSHOT="$SNAP"
    SAFETY_STATUS=armed
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if safety_worker_identity_valid "$SAFETY_PID" "$SAFETY_SCRIPT"; then
            READY=yes
            break
        fi
        kill -0 "$SAFETY_PID" 2>/dev/null || break
        sleep 0.05
    done
    if [ "$READY" != yes ]; then
        kill "$SAFETY_PID" 2>/dev/null || true
        wait "$SAFETY_PID" 2>/dev/null || true
        safety_artifact_remove "$SAFETY_SCRIPT"
        safety_artifact_remove "$SAFETY_ROOTS_FILE"
        safety_artifact_remove "$SAFETY_SYSCTL_FILE"
        safety_artifact_remove "$SAFETY_IPTABLES_FILE"
        safety_artifact_remove "$SAFETY_IP6TABLES_FILE"
        safety_artifact_remove "$SAFETY_SNAPSHOT"
        SAFETY_PID="" SAFETY_SCRIPT="" SAFETY_ROOTS_FILE="" SAFETY_SYSCTL_FILE=""
        SAFETY_IPTABLES_FILE="" SAFETY_IP6TABLES_FILE=""
        SAFETY_APPLIED_SNAPSHOT="" SAFETY_APPLIED_ROOTS=""
        SAFETY_SNAPSHOT="" SAFETY_STATUS=""
        safety_lock_release
        error "自动回滚进程未能可靠启动"
        return 1
    fi
    STATE_TMP=$(mktemp "${STATE_FILE}.tmp.XXXXXX") || STATE_TMP=""
    if [ -z "$STATE_TMP" ] \
        || ! printf '%s|%s|%s|%s|%s|armed\n' \
        "$SAFETY_PID" "$SAFETY_SCRIPT" "$SAFETY_ROOTS_FILE" \
        "$SAFETY_SYSCTL_FILE" "$SAFETY_SNAPSHOT" > "$STATE_TMP" \
        || ! chmod 600 "$STATE_TMP" 2>/dev/null \
        || ! mv -f -- "$STATE_TMP" "$STATE_FILE"; then
        [ -z "$STATE_TMP" ] || rm -f -- "$STATE_TMP"
        kill "$SAFETY_PID" 2>/dev/null || true
        wait "$SAFETY_PID" 2>/dev/null || true
        safety_artifact_remove "$SAFETY_SCRIPT"
        safety_artifact_remove "$SAFETY_ROOTS_FILE"
        safety_artifact_remove "$SAFETY_SYSCTL_FILE"
        safety_artifact_remove "$SAFETY_IPTABLES_FILE"
        safety_artifact_remove "$SAFETY_IP6TABLES_FILE"
        safety_artifact_remove "$SAFETY_SNAPSHOT"
        SAFETY_PID="" SAFETY_SCRIPT="" SAFETY_ROOTS_FILE="" SAFETY_SYSCTL_FILE=""
        SAFETY_IPTABLES_FILE="" SAFETY_IP6TABLES_FILE=""
        SAFETY_SNAPSHOT="" SAFETY_STATUS=""
        safety_lock_release
        error "无法保存防断联任务状态"
        return 1
    fi
    safety_lock_release
    audit_action "启动防断联保护 $LABEL" SUCCESS
    warn "防断联保护已启动：${ROLLBACK_DELAY} 秒内未确认将自动恢复。"
}

safety_confirm() {
    local EXPECTED_PID EXPECTED_SCRIPT EXPECTED_ROOTS EXPECTED_SYSCTL EXPECTED_SNAPSHOT
    safety_mark_applied || return 1
    EXPECTED_PID="${SAFETY_PID:-}"
    EXPECTED_SCRIPT="${SAFETY_SCRIPT:-}"
    EXPECTED_ROOTS="${SAFETY_ROOTS_FILE:-}"
    EXPECTED_SYSCTL="${SAFETY_SYSCTL_FILE:-}"
    EXPECTED_SNAPSHOT="${SAFETY_SNAPSHOT:-}"
    echo ""
    warn "请保持当前连接，并用新终端确认 SSH 和网络正常。"
    read -rp "  确认连接正常，取消自动回滚？(y/N): " OK
    if echo "$OK" | grep -qiE '^y(es)?$'; then
        if ! cancel_safety_timer \
            "$EXPECTED_PID" "$EXPECTED_SCRIPT" "$EXPECTED_ROOTS" \
            "$EXPECTED_SYSCTL" "$EXPECTED_SNAPSHOT"; then
            error "未能安全取消自动回滚；请保持当前连接并检查回滚状态"
            return 1
        fi
        audit_action "确认连接正常，取消自动回滚" SUCCESS
        info "已取消自动回滚"
    else
        warn "自动回滚仍在计时，请勿关闭旧连接。"
    fi
}

security_password_auth_effective() {
    local PASSWORD_AUTH AUTH_METHODS METHOD
    PASSWORD_AUTH=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    AUTH_METHODS=$(printf '%s' "${2:-any}" | tr '[:upper:]' '[:lower:]')
    [ "$PASSWORD_AUTH" = yes ] || return 1
    case "$AUTH_METHODS" in
        ""|any) return 0 ;;
    esac
    while IFS= read -r METHOD; do
        [ "$METHOD" != password ] || return 0
    done < <(printf '%s\n' "$AUTH_METHODS" | tr ' ,' '\n')
    return 1
}

security_password_methods_disabled() {
    local PASSWORD_AUTH KBD_AUTH AUTH_METHODS METHOD
    PASSWORD_AUTH=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    KBD_AUTH=$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')
    AUTH_METHODS=$(printf '%s' "${3:-any}" | tr '[:upper:]' '[:lower:]')
    [ "$PASSWORD_AUTH" = no ] && [ "$KBD_AUTH" = no ] && return 0
    case "$AUTH_METHODS" in
        ""|any) return 1 ;;
    esac
    while IFS= read -r METHOD; do
        case "$METHOD" in
            password)
                [ "$PASSWORD_AUTH" != yes ] || return 1
                ;;
            keyboard-interactive|keyboard-interactive:*)
                [ "$KBD_AUTH" != yes ] || return 1
                ;;
        esac
    done < <(printf '%s\n' "$AUTH_METHODS" | tr ' ,' '\n')
    return 0
}

security_root_password_restricted() {
    local ROOT_LOGIN PASSWORD_AUTH KBD_AUTH AUTH_METHODS
    ROOT_LOGIN=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    PASSWORD_AUTH="${2:-}"
    KBD_AUTH="${3:-}"
    AUTH_METHODS="${4:-any}"
    case "$ROOT_LOGIN" in
        no|prohibit-password|without-password|forced-commands-only)
            return 0
            ;;
        yes)
            security_password_methods_disabled "$PASSWORD_AUTH" "$KBD_AUTH" "$AUTH_METHODS"
            ;;
        *)
            return 1
            ;;
    esac
}

security_audit() {
    print_header "系统安全体检"
    local WARNINGS=0 PORT PASSWORD_AUTH KBD_AUTH ROOT_LOGIN EMPTY_PASSWORDS AUTH_METHODS USE_PAM
    echo -e "  ${BOLD}SSH${NC}"
    PASSWORD_AUTH=$(get_config PasswordAuthentication)
    KBD_AUTH=$(get_config KbdInteractiveAuthentication)
    [ -n "$KBD_AUTH" ] || KBD_AUTH=$(get_config ChallengeResponseAuthentication)
    ROOT_LOGIN=$(get_config PermitRootLogin)
    EMPTY_PASSWORDS=$(get_config PermitEmptyPasswords)
    AUTH_METHODS=$(get_config AuthenticationMethods)
    USE_PAM=$(get_config UsePAM)
    PASSWORD_AUTH=$(printf '%s' "$PASSWORD_AUTH" | tr '[:upper:]' '[:lower:]')
    KBD_AUTH=$(printf '%s' "$KBD_AUTH" | tr '[:upper:]' '[:lower:]')
    ROOT_LOGIN=$(printf '%s' "$ROOT_LOGIN" | tr '[:upper:]' '[:lower:]')
    EMPTY_PASSWORDS=$(printf '%s' "$EMPTY_PASSWORDS" | tr '[:upper:]' '[:lower:]')

    if security_password_methods_disabled "$PASSWORD_AUTH" "$KBD_AUTH" "$AUTH_METHODS"; then
        info "有效密码及键盘交互登录已关闭"
    else
        warn "密码或键盘交互登录仍启用"
        WARNINGS=$((WARNINGS+1))
    fi

    if security_root_password_restricted "$ROOT_LOGIN" "$PASSWORD_AUTH" "$KBD_AUTH" "$AUTH_METHODS"; then
        case "$ROOT_LOGIN" in
            no) info "root SSH 登录已关闭" ;;
            forced-commands-only) info "root 仅允许强制命令密钥登录" ;;
            prohibit-password|without-password) info "root 密码登录已限制（$ROOT_LOGIN）" ;;
            yes) info "root 有效密码登录已关闭（受全局认证策略限制）" ;;
        esac
    else
        warn "root 密码或键盘交互登录可能允许（PermitRootLogin=${ROOT_LOGIN:-未知}）"
        WARNINGS=$((WARNINGS+1))
    fi

    if ! security_password_auth_effective "$PASSWORD_AUTH" "$AUTH_METHODS"; then
        info "空密码认证未生效（有效密码认证已关闭）"
    elif [ "$EMPTY_PASSWORDS" = yes ]; then
        warn "允许空密码登录"
        WARNINGS=$((WARNINGS+1))
    else
        info "未允许空密码登录"
    fi
    ui_hint "有效配置：PasswordAuthentication=${PASSWORD_AUTH:-未知} · KbdInteractiveAuthentication=${KBD_AUTH:-未知}"
    ui_hint "root=${ROOT_LOGIN:-未知} · AuthenticationMethods=${AUTH_METHODS:-未知} · UsePAM=${USE_PAM:-未知}"
    if command -v sshd >/dev/null 2>&1 && sshd -t 2>/dev/null; then info "sshd 配置语法正常"; else warn "无法通过 sshd 配置检查"; WARNINGS=$((WARNINGS+1)); fi
    echo ""; echo -e "  ${BOLD}网络与服务${NC}"
    PORT=$(get_config Port); PORT=${PORT:-22}
    echo -e "  SSH 端口：${BOLD}$PORT${NC}"
    local FW_CHECK; FW_CHECK=$(fw_detect)
    if [ "$FW_CHECK" != none ] && [ "$(fw_running "$FW_CHECK")" = active ]; then info "防火墙运行中"; else warn "防火墙未运行"; WARNINGS=$((WARNINGS+1)); fi
    if [ "$(f2b_status)" = running ]; then info "Fail2ban 运行中"; else warn "Fail2ban 未运行"; WARNINGS=$((WARNINGS+1)); fi
    command -v ss >/dev/null 2>&1 && { echo -e "  ${DIM}公网监听端口：${NC}"; ss -H -lntup 2>/dev/null | awk '$5 ~ /(^|\]):[0-9]+$/ {print "    " $5 "  " $7}' | sort -u | head -20; }
    echo ""; echo -e "  ${BOLD}账户与更新${NC}"
    local UID0; UID0=$(awk -F: '$3==0 {print $1}' /etc/passwd | paste -sd, -)
    if [ "$UID0" = root ]; then info "未发现额外 UID 0 账户"; else warn "UID 0 账户：$UID0"; WARNINGS=$((WARNINGS+1)); fi
    if command -v apt-get >/dev/null 2>&1; then
        local UPDATES; UPDATES=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)
        if [ "$UPDATES" -eq 0 ]; then info "未发现待更新软件包"; else warn "有 $UPDATES 个软件包可更新"; WARNINGS=$((WARNINGS+1)); fi
    fi
    echo ""; menu_div
    if [ "$WARNINGS" -eq 0 ]; then info "未发现明显风险"; else warn "发现 $WARNINGS 项需要关注"; fi
    audit_action "执行系统安全体检，警告 $WARNINGS 项" SUCCESS
}

login_security_logs() {
    while true; do
        print_header "登录记录与安全日志"
        menu_pair "1" "最近成功登录" "2" "最近失败登录"
        menu_pair "3" "当前在线会话" "4" "SSH 安全日志"
        menu_pair "5" "Fail2ban 封禁状态" "0" "返回上级" "$GREEN" "$RED"
        read -rp "$(ui_prompt '选择记录 [0-5]: ')" CH
        case "$CH" in
            1) last -ai 2>/dev/null | head -30 ;;
            2) if command -v lastb >/dev/null 2>&1; then lastb -ai 2>/dev/null | head -30; else warn "系统没有 lastb 数据"; fi ;;
            3) who -uH 2>/dev/null; echo ""; w 2>/dev/null ;;
            4) if command -v journalctl >/dev/null 2>&1; then journalctl -u ssh -u sshd --since '24 hours ago' --no-pager 2>/dev/null | tail -80; else grep -Ei 'sshd.*(accepted|failed|invalid)' /var/log/auth.log /var/log/secure 2>/dev/null | tail -80; fi ;;
            5) fail2ban-client status 2>/dev/null || warn "Fail2ban 未运行" ;;
            0) return ;;
            *) warn "无效选项"; continue ;;
        esac
        audit_action "查看登录安全日志选项 $CH" SUCCESS
        ui_pause
    done
}

network_diagnostics() {
    print_header "网络诊断工具箱"
    local TARGET
    read -rp "  目标域名或 IP（默认 1.1.1.1）: " TARGET
    TARGET=${TARGET:-1.1.1.1}
    echo ""; echo -e "  ${BOLD}地址与默认路由${NC}"
    ip -brief address 2>/dev/null || ip addr 2>/dev/null | head -40
    ip route 2>/dev/null | head -10
    ip -6 route 2>/dev/null | head -10
    echo ""; echo -e "  ${BOLD}DNS 解析${NC}"
    if command -v getent >/dev/null 2>&1; then getent ahosts "$TARGET" 2>/dev/null | head -8; else nslookup "$TARGET" 2>/dev/null | head -15; fi
    echo ""; echo -e "  ${BOLD}连通性${NC}"
    ping -c 4 -W 2 "$TARGET" 2>/dev/null || warn "IPv4/默认协议 Ping 失败"
    command -v ping6 >/dev/null 2>&1 && ping6 -c 2 -W 2 "$TARGET" 2>/dev/null || true
    echo ""; echo -e "  ${BOLD}公网出口${NC}"
    command -v curl >/dev/null 2>&1 && { printf '  IPv4: '; curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "不可用"; echo ""; printf '  IPv6: '; curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || echo "不可用"; echo ""; }
    echo ""; echo -e "  ${BOLD}MTU 探测${NC}"
    if ping -c 1 -W 2 -M "do" -s 1472 "$TARGET" >/dev/null 2>&1; then info "路径 MTU 至少为 1500"; else warn "1500 MTU 探测失败，可能需要降低 MTU"; fi
    audit_action "网络诊断 $TARGET" SUCCESS
}

audit_log_view() {
    print_header "脚本操作记录"
    if [ -s "$VPS_AUDIT_LOG" ]; then
        tail -100 "$VPS_AUDIT_LOG" | column -t -s $'\t' 2>/dev/null || tail -100 "$VPS_AUDIT_LOG"
    else
        warn "暂无操作记录"
    fi
}

resource_health_check() {
    print_header "系统资源与健康检查"
    local CPU_COUNT LOAD MEM_TOTAL MEM_AVAIL MEM_USED
    CPU_COUNT=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)
    LOAD=$(awk '{print $1, $2, $3}' /proc/loadavg 2>/dev/null || uptime)
    MEM_TOTAL=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
    MEM_AVAIL=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null)
    MEM_TOTAL=${MEM_TOTAL:-0}; MEM_AVAIL=${MEM_AVAIL:-0}; MEM_USED=$((MEM_TOTAL-MEM_AVAIL))

    echo -e "  ${BOLD}概览${NC}"
    echo -e "  运行时间：$(uptime -p 2>/dev/null || uptime 2>/dev/null)"
    echo -e "  CPU：${CPU_COUNT} 核   负载：${LOAD}"
    if [ "$MEM_TOTAL" -gt 0 ]; then
        printf '  内存：%.1f / %.1f MiB（%.0f%%）\n' \
            "$(awk "BEGIN {print $MEM_USED/1024}")" "$(awk "BEGIN {print $MEM_TOTAL/1024}")" \
            "$(awk "BEGIN {print $MEM_USED*100/$MEM_TOTAL}")"
    fi
    echo ""; echo -e "  ${BOLD}磁盘空间${NC}"
    df -hP 2>/dev/null | awk 'NR==1 || $1 ~ /^\/dev\// {print "  " $0}'
    echo ""; echo -e "  ${BOLD}inode 使用${NC}"
    df -iP 2>/dev/null | awk 'NR==1 || $1 ~ /^\/dev\// {print "  " $0}'
    echo ""; echo -e "  ${BOLD}网络连接${NC}"
    if command -v ss >/dev/null 2>&1; then ss -s 2>/dev/null | sed 's/^/  /'; else netstat -s 2>/dev/null | head -12 | sed 's/^/  /'; fi
    echo ""; echo -e "  ${BOLD}资源占用最高的进程${NC}"
    ps aux 2>/dev/null | awk 'NR==1 {print; next} {print}' | sort -rk3 | head -6 | sed 's/^/  /'
    if command -v systemctl >/dev/null 2>&1; then
        echo ""; echo -e "  ${BOLD}失败的 systemd 服务${NC}"
        systemctl --failed --no-pager --plain 2>/dev/null | sed -n '1,15p' | sed 's/^/  /'
    fi
    audit_action "执行系统资源健康检查" SUCCESS
}

config_health_check() {
    print_header "配置体检"
    local WARNINGS=0
    echo -e "  ${BOLD}脚本基础${NC}"
    if [ -x "${LOCAL_SCRIPT:-/usr/local/bin/vps-tools}" ]; then info "本地脚本可执行"; else warn "本地脚本不可执行或不存在"; WARNINGS=$((WARNINGS+1)); fi
    if [ -f "$VPS_AUDIT_LOG" ]; then info "审计日志存在"; else warn "审计日志尚未生成"; fi
    if command -v bash >/dev/null 2>&1; then info "bash 已可用"; else warn "未检测到 bash"; WARNINGS=$((WARNINGS+1)); fi

    echo ""; echo -e "  ${BOLD}系统服务${NC}"
    if command -v sshd >/dev/null 2>&1 && sshd -t 2>/dev/null; then info "SSH 配置语法正常"; else warn "SSH 配置语法检查失败"; WARNINGS=$((WARNINGS+1)); fi
    if systemd_available; then
        if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then info "SSH 服务运行中"; else warn "SSH 服务未运行"; WARNINGS=$((WARNINGS+1)); fi
        if command -v fail2ban-client >/dev/null 2>&1; then
            if [ "$(f2b_status 2>/dev/null || echo stopped)" = running ]; then info "Fail2ban 正常"; else warn "Fail2ban 未运行"; WARNINGS=$((WARNINGS+1)); fi
        fi
    fi

    echo ""; echo -e "  ${BOLD}监控配置${NC}"
    if [ -f "$(monitor_alert_cfg 2>/dev/null)" ]; then
        monitor_alert_load_cfg
        if [ -n "${MON_BOT_TOKEN:-}" ] && [ -n "${MON_CHAT_ID:-}" ]; then info "监控 Bot 已配置"; else warn "监控 Bot 未完整配置"; WARNINGS=$((WARNINGS+1)); fi
        if [ "$MON_ENABLED" = yes ]; then info "监控告警已启用"; else warn "监控告警未启用"; fi
        if [ "$MON_TRAFFIC_ENABLED" = yes ]; then info "流量监控已启用"; else warn "流量监控未启用"; fi
        if [ "$MON_DAILY_REPORT_ENABLED" = yes ]; then info "每日日报已启用"; else warn "每日日报未启用"; fi
    else
        warn "尚未配置监控中心"
        WARNINGS=$((WARNINGS+1))
    fi

    echo ""; echo -e "  ${BOLD}更新与备份${NC}"
    if [ -f "${LOCAL_SCRIPT:-/usr/local/bin/vps-tools}.sha256" ]; then info "更新校验文件存在"; else warn "本地校验文件不存在"; fi
    if [ -d "$VPS_VERSION_DIR" ]; then info "历史版本目录存在"; else warn "历史版本目录不存在"; fi
    if [ -d "$VPS_BACKUP_DIR" ]; then info "配置备份目录存在"; else warn "配置备份目录不存在"; fi

    echo ""; menu_div
    if [ "$WARNINGS" -eq 0 ]; then info "未发现明显配置问题"; else warn "发现 $WARNINGS 项需要关注"; fi
    audit_action "执行配置体检，警告 $WARNINGS 项" SUCCESS
}

diagnostic_bundle_create() {
    print_header "生成诊断包"
    local OUTDIR TMPDIR BUNDLE
    OUTDIR="$VPS_DATA_DIR/diagnostics"
    TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/vps-diagnostic.XXXXXX") || return 1
    mkdir -p "$OUTDIR" 2>/dev/null || { rm -rf "$TMPDIR"; error "无法创建诊断包目录"; return 1; }
    BUNDLE="$OUTDIR/diagnostic_$(date +%Y%m%d_%H%M%S).tar.gz"

    {
        echo "VPS-Hardening diagnostic bundle"
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Host: $(hostname 2>/dev/null || echo unknown)"
        echo "Kernel: $(uname -a 2>/dev/null || true)"
        echo
        echo "[Services]"
        if systemd_available; then
            systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || true
            systemctl is-active fail2ban 2>/dev/null || true
            systemctl is-active caddy 2>/dev/null || true
            systemctl is-active nftables 2>/dev/null || true
        fi
        echo
        echo "[Disk]"
        df -hP 2>/dev/null || true
        echo
        echo "[Memory]"
        free -h 2>/dev/null || true
        echo
        echo "[Network]"
        ip route 2>/dev/null || true
        ip -6 route 2>/dev/null || true
        echo
        echo "[Recent audit]"
        tail -100 "$VPS_AUDIT_LOG" 2>/dev/null || true
    } > "$TMPDIR/summary.txt"

    [ -f "$SSHD_CONFIG" ] && cp "$SSHD_CONFIG" "$TMPDIR/sshd_config" 2>/dev/null || true
    [ -d /etc/ssh/sshd_config.d ] && { mkdir -p "$TMPDIR/ssh" && cp -a /etc/ssh/sshd_config.d "$TMPDIR/ssh/" 2>/dev/null || true; }
    [ -f /etc/caddy/Caddyfile ] && cp /etc/caddy/Caddyfile "$TMPDIR/" 2>/dev/null || true
    [ -f /etc/nftables.conf ] && cp /etc/nftables.conf "$TMPDIR/" 2>/dev/null || true
    [ -f /etc/sysctl.d/99-vps-bbr.conf ] && cp /etc/sysctl.d/99-vps-bbr.conf "$TMPDIR/" 2>/dev/null || true
    [ -d "$VPS_VERSION_DIR" ] && ls -1 "$VPS_VERSION_DIR" > "$TMPDIR/version-files.txt" 2>/dev/null || true
    [ -d "$VPS_BACKUP_DIR" ] && ls -1 "$VPS_BACKUP_DIR" > "$TMPDIR/backup-files.txt" 2>/dev/null || true
    if [ -f "$TMPDIR/summary.txt" ]; then
        sed -E 's/((BOT_TOKEN|CHAT_ID|PASSWORD|SECRET|PRIVATE_KEY|API_TOKEN)[[:space:]]*[:=][[:space:]]*).*/\1[REDACTED]/I' "$TMPDIR/summary.txt" > "$TMPDIR/summary.redacted" 2>/dev/null || cp "$TMPDIR/summary.txt" "$TMPDIR/summary.redacted"
        mv "$TMPDIR/summary.redacted" "$TMPDIR/summary.txt"
    fi

    tar -czf "$BUNDLE" -C "$TMPDIR" . >/dev/null 2>&1 || { rm -rf "$TMPDIR"; error "诊断包打包失败"; return 1; }
    rm -rf "$TMPDIR"
    chmod 600 "$BUNDLE" 2>/dev/null || true
    audit_action "生成诊断包 $(basename "$BUNDLE")" SUCCESS
    info "诊断包已生成：$BUNDLE"
    printf '%s\n' "$BUNDLE"
}

system_hostname_current() {
    hostnamectl --static 2>/dev/null || cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo unknown
}

system_hostname_valid() {
    local NAME="$1" PART
    local -a HOSTNAME_PARTS
    [ -n "$NAME" ] || return 1
    [ "${#NAME}" -le 253 ] || return 1
    [[ "$NAME" != .* && "$NAME" != *. ]] || return 1
    [[ "$NAME" != *..* ]] || return 1
    [[ "$NAME" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    IFS='.' read -r -a HOSTNAME_PARTS <<< "$NAME"
    for PART in "${HOSTNAME_PARTS[@]}"; do
        [ -n "$PART" ] || return 1
        [ "${#PART}" -le 63 ] || return 1
        [[ "$PART" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
    return 0
}

system_hostname_sed_escape() {
    printf '%s' "$1" | sed 's/[][\/.^$*+?{}|()]/\\&/g'
}

system_hostname_sync_hosts() {
    local OLD_NAME="$1" NEW_NAME="$2" OLD_ESC NEW_ESC
    [ -f /etc/hosts ] || printf '127.0.0.1 localhost\n' > /etc/hosts
    if [ -n "$OLD_NAME" ] && [ "$OLD_NAME" != "$NEW_NAME" ]; then
        OLD_ESC=$(system_hostname_sed_escape "$OLD_NAME")
        NEW_ESC=$(system_hostname_sed_escape "$NEW_NAME")
        sed -i.vps-hostname.bak -E "s/(^|[[:space:]])${OLD_ESC}([[:space:]#]|$)/\\1${NEW_NAME}\\2/g" /etc/hosts 2>/dev/null || true
    fi
    NEW_ESC=$(system_hostname_sed_escape "$NEW_NAME")
    if grep -Eq "(^|[[:space:]])${NEW_ESC}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
        return 0
    fi
    if grep -qE '^[[:space:]]*127\.0\.1\.1[[:space:]]' /etc/hosts 2>/dev/null; then
        sed -i.vps-hostname.bak -E "/^[[:space:]]*127\.0\.1\.1[[:space:]]/s/$/ ${NEW_NAME}/" /etc/hosts 2>/dev/null \
            || printf '127.0.1.1 %s\n' "$NEW_NAME" >> /etc/hosts
    else
        printf '127.0.1.1 %s\n' "$NEW_NAME" >> /etc/hosts
    fi
}

system_hostname_apply() {
    local OLD_NAME NEW_NAME
    OLD_NAME=$(system_hostname_current)
    print_header "修改系统 Hostname"
    echo -e "  当前 hostname：${BOLD}${OLD_NAME}${NC}"
    echo -e "  示例：${DIM}GreenCloud.HK6666 / ali-hkg-01 / relay01${NC}"
    menu_div
    read -rp "$(ui_prompt '新的系统 hostname: ')" NEW_NAME
    NEW_NAME=${NEW_NAME//[[:space:]]/}
    [ -n "$NEW_NAME" ] || { warn "已取消"; return; }
    if ! system_hostname_valid "$NEW_NAME"; then
        error "hostname 格式不合法：仅支持字母、数字、点和短横线；不能以点/短横线开头或结尾"
        return 1
    fi
    if [ "$OLD_NAME" = "$NEW_NAME" ]; then
        info "hostname 未变化"
        return 0
    fi
    confirm_change_preview "修改系统 hostname" \
        "当前：$OLD_NAME" \
        "修改为：$NEW_NAME" \
        "写入 /etc/hostname，并同步 /etc/hosts 中的本机映射" \
        "SSH 连接不会因此断开，但新终端提示符、日志和 hostname 命令会显示新名称" || { warn "已取消"; return; }
    [ "$(id -u)" = "0" ] || { error "需要 root 权限"; return 1; }
    config_backup_create before_hostname_change true >/dev/null || warn "配置备份失败，仍继续尝试修改"
    if command -v hostnamectl >/dev/null 2>&1; then
        hostnamectl set-hostname "$NEW_NAME" 2>/dev/null || {
            printf '%s\n' "$NEW_NAME" > /etc/hostname || return 1
            hostname "$NEW_NAME" 2>/dev/null || true
        }
    else
        printf '%s\n' "$NEW_NAME" > /etc/hostname || return 1
        hostname "$NEW_NAME" 2>/dev/null || true
    fi
    system_hostname_sync_hosts "$OLD_NAME" "$NEW_NAME"
    audit_action "修改系统 hostname：$OLD_NAME -> $NEW_NAME" SUCCESS
    info "系统 hostname 已修改为：$NEW_NAME"
    warn "已打开的 SSH 会话提示符可能不会立刻刷新，重新登录后会看到新名称"
}

system_update_manager() {
    while true; do
        print_header "系统更新管理"
        local PM="unknown" PENDING="未知"
        if command -v apt-get >/dev/null 2>&1; then PM="apt"; PENDING=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)
        elif command -v dnf >/dev/null 2>&1; then PM="dnf"; PENDING=$(dnf -q check-update 2>/dev/null | awk 'NF>=3 {n++} END {print n+0}')
        elif command -v yum >/dev/null 2>&1; then PM="yum"; PENDING=$(yum -q check-update 2>/dev/null | awk 'NF>=3 {n++} END {print n+0}')
        elif command -v apk >/dev/null 2>&1; then PM="apk"; PENDING=$(apk version -l '<' 2>/dev/null | wc -l)
        elif command -v opkg >/dev/null 2>&1; then PM="opkg"; PENDING=$(opkg list-upgradable 2>/dev/null | wc -l)
        fi
        echo -e "  包管理器：${BOLD}$PM${NC}   待更新：${BOLD}$PENDING${NC}"
        menu_div
        menu_pair "1" "刷新并检查更新" "2" "安装安全更新"
        menu_pair "3" "安装全部更新" "4" "自动安全更新" "$YELLOW" "$GREEN"
        menu_pair "5" "清理软件包缓存" "0" "返回上级" "$GREEN" "$RED"
        read -rp "$(ui_prompt '选择操作 [0-5]: ')" CH
        case "$CH" in
            1)
                case "$PM" in
                    apt) apt-get update ;;
                    dnf) dnf check-update || [ "$?" -eq 100 ] ;;
                    yum) yum check-update || [ "$?" -eq 100 ] ;;
                    apk) apk update ;;
                    opkg) opkg update; opkg list-upgradable ;;
                    *) error "不支持当前包管理器" ;;
                esac
                audit_action "刷新系统软件包索引" SUCCESS
                ;;
            2)
                confirm_change_preview "安全更新" "包管理器：$PM" "仅安装安全修复（Alpine 安装仓库可用更新）" || { warn "已取消"; continue; }
                case "$PM" in
                    apt) pkg_install unattended-upgrades && unattended-upgrade -d ;;
                    dnf) dnf upgrade --security -y ;;
                    yum) yum update --security -y ;;
                    apk) apk upgrade ;;
                    opkg) warn "OpenWrt 不区分安全更新，请按包逐项升级"; continue ;;
                    *) error "不支持当前包管理器"; continue ;;
                esac
                audit_action "安装系统安全更新" SUCCESS
                ;;
            3)
                confirm_change_preview "全部系统更新" "将更新所有已安装软件包" "可能需要重启服务器" || { warn "已取消"; continue; }
                case "$PM" in
                    apt) apt-get update && DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y ;;
                    dnf) dnf upgrade -y ;;
                    yum) yum update -y ;;
                    apk) apk update && apk upgrade ;;
                    opkg) warn "OpenWrt 不建议无差别升级全部基础包，请使用固件升级或逐包维护"; continue ;;
                    *) error "不支持当前包管理器"; continue ;;
                esac
                audit_action "安装全部系统更新" SUCCESS
                ;;
            4)
                confirm_change_preview "自动安全更新" "启用发行版提供的定时安全更新" "更新行为由系统包管理器维护" || { warn "已取消"; continue; }
                case "$PM" in
                    apt)
                        pkg_install unattended-upgrades
                        mkdir -p /etc/apt/apt.conf.d
                        printf '%s\n' 'APT::Periodic::Update-Package-Lists "1";' 'APT::Periodic::Unattended-Upgrade "1";' > /etc/apt/apt.conf.d/20auto-upgrades
                        ;;
                    dnf)
                        pkg_install dnf-automatic
                        sed -i 's/^apply_updates[[:space:]]*=.*/apply_updates = yes/' /etc/dnf/automatic.conf 2>/dev/null
                        systemctl enable --now dnf-automatic.timer
                        ;;
                    yum) pkg_install yum-cron; svc_enable yum-cron; svc_start yum-cron ;;
                    apk) warn "Alpine 未自动写入定时更新，请使用系统 cron 按维护窗口安排"; continue ;;
                    opkg) warn "OpenWrt 未自动写入更新任务，请按固件维护策略安排"; continue ;;
                    *) error "不支持当前包管理器"; continue ;;
                esac
                audit_action "启用自动安全更新" SUCCESS
                info "自动安全更新已启用"
                ;;
            5)
                case "$PM" in
                    apt) apt-get autoremove -y && apt-get clean ;;
                    dnf) dnf autoremove -y; dnf clean all ;;
                    yum) yum autoremove -y; yum clean all ;;
                    apk) rm -rf /var/cache/apk/* ;;
                    opkg) rm -rf /tmp/opkg-lists/* ;;
                    *) error "不支持当前包管理器"; continue ;;
                esac
                audit_action "清理软件包缓存" SUCCESS
                info "清理完成"
                ;;
            0) return ;;
            *) warn "无效选项"; continue ;;
        esac
        ui_pause
    done
}

system_toolbox_menu() {
    while true; do
        print_header "安全与诊断工具箱"
        menu_pair "1" "系统安全体检" "2" "登录与安全日志"
        menu_pair "3" "网络诊断" "4" "配置备份与恢复"
        menu_pair "5" "脚本操作记录" "6" "系统资源健康"
        menu_pair "7" "系统更新管理" "8" "配置导出 / 导入"
        menu_pair "9" "统一回滚中心" "10" "监控告警中心" "$CYAN" "$CYAN"
        menu_pair "11" "配置体检中心" "12" "生成诊断包" "$GREEN" "$YELLOW"
        menu_item "13" "修改系统 Hostname" "$CYAN"
        menu_item "14" "STUN / NAT 检测" "$GREEN"
        menu_item "0" "返回主菜单" "$RED"
        menu_div
        ui_hint "Hostname 是系统名，会影响 root@主机名 提示符；推送显示名仍在监控通知设置中配置"
        echo ""
        read -rp "$(ui_prompt '选择工具 [0-14]: ')" CH
        case "$CH" in
            1) security_audit ;;
            2) login_security_logs; continue ;;
            3) network_diagnostics ;;
            4) config_backup_menu; continue ;;
            5) audit_log_view ;;
            6) resource_health_check ;;
            7) system_update_manager; continue ;;
            8) config_transfer_menu; continue ;;
            9) rollback_center_menu; continue ;;
            10) monitor_alert_home_menu ;;
            11) config_health_check ;;
            12) diagnostic_bundle_create ;;
            13) system_hostname_apply ;;
            14) stun_nat_menu; continue ;;
            0) return ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac
        ui_pause
    done
}
