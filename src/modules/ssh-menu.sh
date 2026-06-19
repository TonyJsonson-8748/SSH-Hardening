# ── SSH 工具集子菜单 ──────────────────────────────────────
ssh_tools_menu() {
    while true; do
        local CUR_PORT CUR_PWD CUR_PUBKEY KEYCOUNT
        CUR_PORT=$(get_config "Port")
        CUR_PWD=$(get_config "PasswordAuthentication")
        CUR_PUBKEY=$(get_config "PubkeyAuthentication")
        KEYCOUNT=$(grep -cE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa|ssh-dss) ' "$AUTH_KEYS" 2>/dev/null || echo 0)

        print_header "SSH 工具集"
        box_line "  端口 ${CUR_PORT:-22}  |  公钥数 ${KEYCOUNT}" \
                 "  端口 ${BOLD}${CUR_PORT:-22}${NC}  |  公钥数 ${BOLD}${KEYCOUNT}${NC}"
        box_line "  密码登录 ${CUR_PWD:-未设置}  |  公钥认证 ${CUR_PUBKEY:-未设置}" \
                 "  密码登录 ${BOLD}${CUR_PWD:-未设置}${NC}  |  公钥认证 ${BOLD}${CUR_PUBKEY:-未设置}${NC}"
        echo ""
        menu_div
        echo -e "  ${GREEN}1${NC}) 查看已有公钥     ${GREEN}2${NC}) 添加公钥"
        echo -e "  ${GREEN}3${NC}) 删除公钥         ${GREEN}4${NC}) 生成密钥对"
        echo -e "  ${GREEN}5${NC}) 设置登录方式     ${GREEN}6${NC}) 修改 SSH 端口"
        echo -e "  ${RED}0${NC}) 返回主菜单        ${RED}00${NC}) 退出脚本"
        menu_div
        echo ""
        read -rp "  请选择 [0-6]: " CHOICE

        local NEED_PAUSE=1
        case "$CHOICE" in
            1) show_keys ;;
            2) add_key ;;
            3) delete_key ;;
            4) generate_key ;;
            5) set_login_mode ;;
            6) change_port ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; NEED_PAUSE=0 ;;
        esac

        [ "$NEED_PAUSE" -eq 1 ] && { echo ""; read -rp "  按 Enter 返回..." _; }
    done
}
