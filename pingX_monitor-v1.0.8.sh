#!/bin/bash

# PingX Monitor Script v1.0.8
# Purpose: Monitor host ping status and send notifications via Telegram or DingTalk
# Author: TheX
# GitHub: https://github.com/MEILOI/ping-x
# License: MIT
# Version: 1.0.8 (2025-05-23)
# Changelog:
# - v1.0.8: Added domain name support, renamed to pingX_monitor, updated menu header with author and GitHub
# - v1.0.7: Fixed FAILURE_COUNTS accumulation with state persistence, added flock, sequential ping
# - v1.0.6: Fixed notification trigger, added view log option, improved crontab logging
# - v1.0.5: Optimized ping detection, added multi-ping per crontab run, enhanced logging
# - v1.0.4: Optimized host list display with numbering, added add/delete host operations
# - v1.0.3: Improved host list input: enter IP then remark separately
# - v1.0.2: Added 'list current config' option, updated notification type to TG/DingTalk
# - v1.0.1: Added Telegram notification support with Bot Token and Chat ID

CONFIG_FILE="/etc/pingX_monitor.conf"
SCRIPT_PATH="/usr/local/bin/pingX_monitor.sh"
SERVICE_PATH="/etc/systemd/system/pingX_monitor.service"
STATE_FILE="/var/run/pingX_monitor.state"
LOCK_FILE="/var/lock/pingX_monitor.lock"
CRON_JOB="*/1 * * * * root /usr/local/bin/pingX_monitor.sh monitor >> /var/log/pingX_monitor.log 2>&1"
LOG_FILE="/var/log/pingX_monitor.log"
LOG_MAX_SIZE=$((1024*1024)) # 1MB
MAX_LOG_FILES=5
TG_API="https://api.telegram.org/bot"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Ensure log file exists
mkdir -p /var/log
touch "$LOG_FILE"

# Logging function
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" >> "$LOG_FILE"
    # Rotate log if exceeds max size
    if [[ -f "$LOG_FILE" && $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE") -gt $LOG_MAX_SIZE ]]; then
        for ((i=$MAX_LOG_FILES-1; i>=1; i--)); do
            if [ -f "$LOG_FILE.$i" ]; then
                mv "$LOG_FILE.$i" "$LOG_FILE.$((i+1))"
            fi
        done
        mv "$LOG_FILE" "$LOG_FILE.1"
        touch "$LOG_FILE"
        log "Log rotated due to size limit"
    fi
}

# Load configuration
load_config() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
}

# Save configuration
save_config() {
    cat <<EOF > "$CONFIG_FILE"
# PingX Monitor Configuration
NOTIFY_TYPE="$NOTIFY_TYPE"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_IDS="$TG_CHAT_IDS"
DINGTALK_WEBHOOK="$DINGTALK_WEBHOOK"
HOSTS_LIST="$HOSTS_LIST"
REMARKS_LIST="$REMARKS_LIST"
INTERVAL="$INTERVAL"
OFFLINE_THRESHOLD="$OFFLINE_THRESHOLD"
EOF
    chmod 600 "$CONFIG_FILE"
    log "Configuration saved to $CONFIG_FILE"
}

# Load state (FAILURE_COUNTS and HOST_STATUS)
load_state() {
    if [ -f "$STATE_FILE" ]; then
        while IFS='=' read -r key value; do
            if [[ $key == FAILURE_COUNTS_* ]]; then
                host=${key#FAILURE_COUNTS_}
                FAILURE_COUNTS["$host"]=$value
            elif [[ $key == HOST_STATUS_* ]]; then
                host=${key#HOST_STATUS_}
                HOST_STATUS["$host"]=$value
            fi
        done < "$STATE_FILE"
        log "Loaded state from $STATE_FILE"
    fi
}

# Save state
save_state() {
    : > "$STATE_FILE"
    for host in "${!FAILURE_COUNTS[@]}"; do
        echo "FAILURE_COUNTS_$host=${FAILURE_COUNTS[$host]}" >> "$STATE_FILE"
        echo "HOST_STATUS_$host=${HOST_STATUS[$host]}" >> "$STATE_FILE"
    done
    chmod 600 "$STATE_FILE"
    log "Saved state to $STATE_FILE"
}

# Validate Telegram configuration
validate_telegram() {
    if [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_IDS" ]]; then
        local response=$(curl -s -m 5 "${TG_API}${TG_BOT_TOKEN}/getMe")
        if echo "$response" | grep -q '"ok":true'; then
            log "Telegram Bot validation succeeded"
            return 0
        else
            log "ERROR: Telegram validation failed: $response"
            return 1
        fi
    else
        log "ERROR: Telegram configuration incomplete"
        return 1
    fi
}

# Validate DingTalk Webhook
validate_dingtalk() {
    local webhook="$1"
    local response=$(curl -s -m 5 -X POST "$webhook" \
        -H "Content-Type: application/json" \
        -d '{"msgtype": "text", "text": {"content": "测试消息"}}')
    if [[ $? -eq 0 && $(echo "$response" | grep -o '"errcode":0') ]]; then
        log "DingTalk Webhook validation succeeded: $(echo "$webhook" | cut -c1-10)****"
        return 0
    else
        log "ERROR: DingTalk Webhook validation failed: $(echo "$webhook" | cut -c1-10)****"
        return 1
    fi
}

# Send Telegram notification
send_tg_notification() {
    local message="$1"
    if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_IDS" ]; then
        log "ERROR: Telegram configuration incomplete"
        return 1
    fi

    IFS=',' read -ra IDS <<< "$TG_CHAT_IDS"
    local success=0
    for id in "${IDS[@]}"; do
        response=$(curl -s -m 5 -w "\nHTTP_CODE:%{http_code}" -X POST "${TG_API}${TG_BOT_TOKEN}/sendMessage" \
            -H "Content-Type: application/json" \
            -d "{\"chat_id\": \"$id\", \"text\": \"$message\", \"parse_mode\": \"Markdown\"}")
        http_code=$(echo "$response" | grep "HTTP_CODE" | cut -d':' -f2)
        response_body=$(echo "$response" | grep -v "HTTP_CODE")
        if echo "$response_body" | grep -q '"ok":true'; then
            log "Telegram notification sent to $id: $message"
            success=1
        else
            log "ERROR: Failed to send Telegram message to $id (HTTP $http_code): $response_body"
        fi
    done
    [ $success -eq 1 ] && return 0 || return 1
}

# Send DingTalk Webhook notification
send_dingtalk_notification() {
    local message="$1"
    if [ -z "$DINGTALK_WEBHOOK" ]; then
        log "ERROR: DingTalk Webhook not configured"
        return 1
    fi
    local response=$(curl -s -m 5 -X POST "$DINGTALK_WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "{\"msgtype\": \"text\", \"text\": {\"content\": \"$message\"}}")
    if [[ $? -eq 0 && $(echo "$response" | grep -o '"errcode":0') ]]; then
        log "DingTalk notification sent: $message"
        return 0
    else
        log "ERROR: Failed to send DingTalk notification: $response"
        return 1
    fi
}

# Unified notification sending
send_notification() {
    local message="$1"
    if [ "$NOTIFY_TYPE" = "telegram" ]; then
        send_tg_notification "$message"
    else
        send_dingtalk_notification "$message"
    fi
}

# Ping host function
ping_host() {
    local HOST="$1"
    local REMARK="$2"
    local CURRENT_TIME=$(date +"%Y-%m-%d %H:%M:%S")
    local PING_RESULT
    local STATUS=""
    local LOG_ENTRY=""

    # Execute ping and capture output and exit status
    PING_RESULT=$(ping -c 1 -W 2 "$HOST" 2>&1)
    local PING_EXIT=$?

    log "Ping attempt for $HOST ($REMARK): $PING_RESULT"

    if [ $PING_EXIT -eq 0 ] && echo "$PING_RESULT" | grep -q "1 packets transmitted, 1 packets received"; then
        local RESPONSE_TIME=$(echo "$PING_RESULT" | grep "time=" | awk -F"time=" '{print $2}' | awk '{print $1}')
        STATUS="Ping successful, response time: ${RESPONSE_TIME}ms"
        # If host was offline, send online notification
        if [ "${HOST_STATUS[$HOST]}" -eq 1 ]; then
            HOST_STATUS["$HOST"]=0
            FAILURE_COUNTS["$HOST"]=0
            local message="✅ *主机上线通知*\n\n📍 *主机*: $HOST\n📝 *备注*: $REMARK\n🕒 *时间*: $CURRENT_TIME"
            send_notification "$message" && LOG_ENTRY="$CURRENT_TIME - $HOST ($REMARK) - $STATUS - 上线通知已发送" || LOG_ENTRY="$CURRENT_TIME - $HOST ($REMARK) - $STATUS - 上线通知发送失败"
            log "Reset $HOST: Failure count=${FAILURE_COUNTS[$HOST]}, Status=${HOST_STATUS[$HOST]}"
        else
            LOG_ENTRY="$CURRENT_TIME - $HOST ($REMARK) - $STATUS"
            FAILURE_COUNTS["$HOST"]=0
            log "Reset $HOST: Failure count=${FAILURE_COUNTS[$HOST]}, Status=${HOST_STATUS[$HOST]}"
        fi
    else
        STATUS="Ping failed: $PING_RESULT"
        ((FAILURE_COUNTS["$HOST"]++))
        LOG_ENTRY="$CURRENT_TIME - $HOST ($REMARK) - $STATUS"
        log "Failure count for $HOST: ${FAILURE_COUNTS[$HOST]}, Threshold: $OFFLINE_THRESHOLD, Status: ${HOST_STATUS[$HOST]}"
        # Check if offline threshold is reached
        if [ "${FAILURE_COUNTS[$HOST]}" -ge "$OFFLINE_THRESHOLD" ] && [ "${HOST_STATUS[$HOST]}" -eq 0 ]; then
            HOST_STATUS["$HOST"]=1
            local message="🛑 *主机离线通知*\n\n📍 *主机*: $HOST\n📝 *备注*: $REMARK\n🕒 *时间*: $CURRENT_TIME\n⚠️ *连续失败*: ${FAILURE_COUNTS[$HOST]}次"
            send_notification "$message" && LOG_ENTRY="$LOG_ENTRY - 离线通知已发送" || LOG_ENTRY="$LOG_ENTRY - 离线通知发送失败"
        fi
    fi

    echo "$LOG_ENTRY"
    echo "$LOG_ENTRY" >> "$LOG_FILE"
}

# Monitor function (called by cron)
monitor() {
    # Use flock to prevent concurrent execution
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        log "Another monitor instance is running, exiting"
        return 1
    fi

    load_config
    load_state

    # Validate notification configuration
    if [ "$NOTIFY_TYPE" = "telegram" ]; then
        validate_telegram || return 1
    elif [ "$NOTIFY_TYPE" = "dingtalk" ]; then
        validate_dingtalk "$DINGTALK_WEBHOOK" || return 1
    fi

    IFS=',' read -ra HOSTS <<< "$HOSTS_LIST"
    IFS=',' read -ra REMARKS <<< "$REMARKS_LIST"

    # Initialize host status and failure counts for new hosts
    for i in "${!HOSTS[@]}"; do
        HOST="${HOSTS[$i]}"
        if [ -z "${FAILURE_COUNTS[$HOST]}" ]; then
            FAILURE_COUNTS["$HOST"]=0
            HOST_STATUS["$HOST"]=0
            log "Initialized $HOST: Failure count=${FAILURE_COUNTS[$HOST]}, Status=${HOST_STATUS[$HOST]}"
        fi
    done

    # Calculate number of ping attempts within 60 seconds (cron runs every minute)
    local attempts=$((60 / INTERVAL))
    [ $attempts -lt 1 ] && attempts=1

    # Run pings sequentially within one cron execution
    for (( attempt=1; attempt<=attempts; attempt++ )); do
        log "Monitor attempt $attempt/$attempts"
        for i in "${!HOSTS[@]}"; do
            ping_host "${HOSTS[$i]}" "${REMARKS[$i]}"
        done
        save_state
        # Sleep for INTERVAL seconds, unless it's the last attempt
        [ $attempt -lt $attempts ] && sleep "$INTERVAL"
    done

    flock -u 200
}

# Check dependencies
check_dependencies() {
    for cmd in curl ping flock; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}缺少依赖: $cmd${NC}"
            echo -e "${YELLOW}正在尝试安装 $cmd...${NC}"
            if command -v apt &> /dev/null; then
                apt update -y >/dev/null 2>&1 && apt install -y curl iputils-ping util-linux >/dev/null 2>&1
            elif command -v yum &> /dev/null; then
                yum install -y curl iputils util-linux >/dev/null 2>&1
            elif command -v dnf &> /dev/null; then
                dnf install -y curl iputils util-linux >/dev/null 2>&1
            else
                echo -e "${RED}不支持的包管理器，请手动安装 $cmd${NC}"
                log "ERROR: No supported package manager found for installing $cmd"
                exit 1
            fi
            if ! command -v $cmd &> /dev/null; then
                echo -e "${RED}安装 $cmd 失败，请手动安装${NC}"
                log "ERROR: Failed to install dependency: $cmd"
                exit 1
            fi
        fi
    done
    log "Dependencies checked: curl ping flock"
}

# Validate IP or domain
validate_host() {
    local host="$1"
    # Validate IPv4
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    # Validate domain (basic regex for domain names)
    elif [[ "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$ ]]; then
        return 0
    else
        return 1
    fi
}

# Print menu header
print_menu_header() {
    clear
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo -e "${CYAN}║     ${YELLOW}PingX 监控系统 (v1.0.8)     ${CYAN}║${NC}"
    echo -e "${CYAN}║     ${YELLOW}作者: TheX                  ${CYAN}║${NC}"
    echo -e "${CYAN}║     ${YELLOW}GitHub: https://github.com/MEILOI/ping-x ${CYAN}║${NC}"
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo ""
}

# Show current configuration
show_config() {
    echo -e "${CYAN}当前配置:${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo -e "${CYAN}通知方式:${NC} ${NOTIFY_TYPE:-未设置}"
        if [ "$NOTIFY_TYPE" = "telegram" ]; then
            if [ -n "$TG_BOT_TOKEN" ]; then
                token_prefix=$(echo $TG_BOT_TOKEN | cut -d':' -f1)
                token_masked="$token_prefix:****"
                echo -e "${CYAN}Telegram Bot Token:${NC} $token_masked"
            else
                echo -e "${CYAN}Telegram Bot Token:${NC} ${RED}未设置${NC}"
            fi
            echo -e "${CYAN}Telegram Chat IDs:${NC} ${TG_CHAT_IDS:-未设置}"
        else
            if [ -n "$DINGTALK_WEBHOOK" ]; then
                webhook_masked=$(echo "$DINGTALK_WEBHOOK" | cut -c1-10)****
                echo -e "${CYAN}钉钉 Webhook:${NC} $webhook_masked"
            else
                echo -e "${CYAN}钉钉 Webhook:${NC} ${RED}未设置${NC}"
            fi
        fi
        echo -e "${CYAN}监控间隔:${NC} ${INTERVAL:-60}秒"
        echo -e "${CYAN}离线阈值:${NC} ${OFFLINE_THRESHOLD:-3}次"
        echo -e "${CYAN}主机列表:${NC}"
        if [ -n "$HOSTS_LIST" ]; then
            IFS=',' read -ra HOSTS <<< "$HOSTS_LIST"
            IFS=',' read -ra REMARKS <<< "$REMARKS_LIST"
            for i in "${!HOSTS[@]}"; do
                echo -e "  $((i+1)). ${HOSTS[$i]} (${REMARKS[$i]})"
            done
        else
            echo -e "${RED}未配置任何主机${NC}"
        fi
    else
        echo -e "${RED}未找到配置文件，请先安装脚本${NC}"
    fi
    echo ""
}

# View log function
view_log() {
    print_menu_header
    echo -e "${CYAN}[查看日志]${NC} 显示 /var/log/pingX_monitor.log 的最新 20 行:\n"
    if [ -f "$LOG_FILE" ]; then
        tail -n 20 "$LOG_FILE"
    else
        echo -e "${RED}日志文件不存在${NC}"
    fi
    echo ""
    read -rp "按 Enter 键继续..."
}

# Install script
install_script() {
    print_menu_header
    echo -e "${CYAN}[安装] ${GREEN}开始安装 PingX 监控系统...${NC}"
    echo ""

    check_dependencies

    # Notification type
    echo -e "${CYAN}[1/5]${NC} 选择通知方式:"
    echo -e "${CYAN}1.${NC} TG"
    echo -e "${CYAN}2.${NC} 钉钉"
    read -rp "请选择 [1-2]: " notify_choice
    case $notify_choice in
        1)
            NOTIFY_TYPE="telegram"
            ;;
        2)
            NOTIFY_TYPE="dingtalk"
            ;;
        *)
            echo -e "${RED}无效选择，默认使用 TG${NC}"
            NOTIFY_TYPE="telegram"
            ;;
    esac

    # Telegram configuration
    if [ "$NOTIFY_TYPE" = "telegram" ]; then
        echo -e "\n${CYAN}[2/5]${NC} 输入 Telegram Bot Token:"
        read -rp "Token (格式如123456789:ABCDEF...): " TG_BOT_TOKEN
        echo -e "\n${CYAN}[3/5]${NC} 输入 Telegram Chat ID (支持多个，逗号分隔):"
        read -rp "Chat ID(s): " TG_CHAT_IDS
        if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_IDS" ]; then
            validate_telegram && echo -e "${GREEN}Token 有效${NC}" || echo -e "${RED}Token 无效${NC}"
        fi
        DINGTALK_WEBHOOK=""
    else
        echo -e "\n${CYAN}[2/5]${NC} 输入钉钉 Webhook URL:"
        read -rp "Webhook: " DINGTALK_WEBHOOK
        if [ -n "$DINGTALK_WEBHOOK" ]; then
            validate_dingtalk "$DINGTALK_WEBHOOK"
        fi
        TG_BOT_TOKEN=""
        TG_CHAT_IDS=""
    fi

    # Host and remark configuration
    echo -e "\n${CYAN}[3/5]${NC} 输入要监控的 IP 或域名 (每次输入一个，空行结束):"
    echo -e "${YELLOW}示例: 192.168.1.1 或 example.com${NC}"
    HOSTS_LIST=""
    REMARKS_LIST=""
    while true; do
        read -rp "IP 或域名 (空行结束): " host
        if [ -z "$host" ]; then
            if [ -z "$HOSTS_LIST" ]; then
                echo -e "${YELLOW}警告: 未添加任何主机${NC}"
            fi
            break
        fi
        if ! validate_host "$host"; then
            echo -e "${RED}错误: $host 不是有效的 IP 或域名${NC}"
            continue
        fi
        read -rp "请输入 $host 的备注: " remark
        if [ -z "$remark" ]; then
            echo -e "${RED}错误: 备注不能为空${NC}"
            continue
        fi
        [ -n "$HOSTS_LIST" ] && HOSTS_LIST+=","
        [ -n "$REMARKS_LIST" ] && REMARKS_LIST+=","
        HOSTS_LIST+="$host"
        REMARKS_LIST+="$remark"
        echo -e "${GREEN}已添加: $host ($remark)${NC}"
    done

    # Interval and threshold
    echo -e "\n${CYAN}[4/5]${NC} 输入监控间隔 (秒，默认60):"
    read -rp "间隔: " INTERVAL
    INTERVAL=${INTERVAL:-60}
    echo -e "\n${CYAN}[5/5]${NC} 输入离线阈值 (连续失败次数，默认3):"
    read -rp "阈值: " OFFLINE_THRESHOLD
    OFFLINE_THRESHOLD=${OFFLINE_THRESHOLD:-3}

    # Save configuration
    save_config

    # Install script
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"

    # Set up systemd service
    cat <<EOF > "$SERVICE_PATH"
[Unit]
Description=PingX Monitor Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $SCRIPT_PATH monitor

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable pingX_monitor.service

    # Set up crontab
    if ! grep -q "pingX_monitor.sh monitor" /etc/crontab; then
        echo "$CRON_JOB" >> /etc/crontab
    fi

    # Clear previous state
    rm -f "$STATE_FILE"
    log "Cleared state file during installation"

    echo -e "\n${GREEN}✅ 安装完成!${NC}"
    echo -e "${YELLOW}提示: 可以从菜单选择'测试通知'选项验证配置${NC}"
    log "Installation completed"
    sleep 2
}

# Uninstall script
uninstall_script() {
    print_menu_header
    echo -e "${CYAN}[卸载] ${YELLOW}正在卸载 PingX 监控系统...${NC}\n"

    systemctl disable pingX_monitor.service 2>/dev/null
    rm -f "$SERVICE_PATH" "$SCRIPT_PATH" "$CONFIG_FILE" "$STATE_FILE" "$LOCK_FILE"
    sed -i '/pingX_monitor.sh monitor/d' /etc/crontab
    rm -f "$LOG_FILE" "${LOG_FILE}".*
    rmdir /var/log 2>/dev/null || true

    echo -e "\n${GREEN}✅ 卸载完成!${NC}"
    echo -e "${YELLOW}所有配置文件和脚本已删除${NC}"
    log "Uninstallation completed"
    sleep 2
    exit 0
}

# Test notifications
test_notifications() {
    load_config
    while true; do
        print_menu_header
        echo -e "${CYAN}[测试通知]${NC} 请选择要测试的通知类型:\n"
        echo -e "${CYAN}1.${NC} 测试离线通知"
        echo -e "${CYAN}2.${NC} 测试上线通知"
        echo -e "${CYAN}0.${NC} 返回主菜单"
        echo ""
        read -rp "请选择 [0-2]: " choice

        case $choice in
            1)
                echo -e "\n${YELLOW}正在发送离线通知...${NC}"
                local test_host="192.168.1.100"
                local test_remark="测试主机"
                local time=$(date '+%Y-%m-%d %H:%M:%S')
                local message="🛑 *主机离线通知*\n\n📍 *主机*: $test_host\n📝 *备注*: $test_remark\n🕒 *时间*: $time\n⚠️ *连续失败*: ${OFFLINE_THRESHOLD}次"
                send_notification "$message" && echo -e "\n${GREEN}通知已发送，请检查通知渠道${NC}" || echo -e "\n${RED}通知发送失败，请检查日志${NC}"
                read -rp "按 Enter 键继续..."
                ;;
            2)
                echo -e "\n${YELLOW}正在发送上线通知...${NC}"
                local test_host="192.168.1.100"
                local test_remark="测试主机"
                local time=$(date '+%Y-%m-%d %H:%M:%S')
                local message="✅ *主机上线通知*\n\n📍 *主机*: $test_host\n📝 *备注*: $test_remark\n🕒 *时间*: $time"
                send_notification "$message" && echo -e "\n${GREEN}通知已发送，请检查通知渠道${NC}" || echo -e "\n${RED}通知发送失败，请检查日志${NC}"
                read -rp "按 Enter 键继续..."
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选择，请重试${NC}"
                sleep 1
                ;;
        esac
    done
}

# Modify configuration
modify_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}错误: 配置文件不存在，请先安装脚本${NC}"
        sleep 2
        return
    fi

    load_config
    while true; do
        print_menu_header
        echo -e "${CYAN}[配置设置]${NC}\n"
        show_config

        echo -e "请选择要修改的配置项:"
        echo -e "${CYAN}1.${NC} 列出当前配置"
        echo -e "${CYAN}2.${NC} 修改通知方式"
        echo -e "${CYAN}3.${NC} 修改 Telegram 配置"
        echo -e "${CYAN}4.${NC} 修改钉钉 Webhook"
        echo -e "${CYAN}5.${NC} 修改主机列表和备注"
        echo -e "${CYAN}6.${NC} 修改监控间隔"
        echo -e "${CYAN}7.${NC} 修改离线阈值"
        echo -e "${CYAN}0.${NC} 返回主菜单"
        echo ""
        read -rp "请选择 [0-7]: " choice

        case $choice in
            1)
                echo -e "\n${CYAN}当前配置:${NC}"
                show_config
                read -rp "按 Enter 键继续..."
                ;;
            2)
                echo -e "\n${CYAN}选择新的通知方式:${NC}"
                echo -e "${CYAN}1.${NC} TG"
                echo -e "${CYAN}2.${NC} 钉钉"
                read -rp "请选择 [1-2]: " notify_choice
                case $notify_choice in
                    1)
                        NOTIFY_TYPE="telegram"
                        sed -i "s/NOTIFY_TYPE=.*$/NOTIFY_TYPE=\"telegram\"/" "$CONFIG_FILE"
                        echo -e "${GREEN}通知方式已设置为 TG${NC}"
                        log "Notification type set to telegram"
                        ;;
                    2)
                        NOTIFY_TYPE="dingtalk"
                        sed -i "s/NOTIFY_TYPE=.*$/NOTIFY_TYPE=\"dingtalk\"/" "$CONFIG_FILE"
                        echo -e "${GREEN}通知方式已设置为钉钉${NC}"
                        log "Notification type set to dingtalk"
                        ;;
                    *)
                        echo -e "${RED}无效选择，通知方式未更改${NC}"
                        ;;
                esac
                ;;
            3)
                if [ "$NOTIFY_TYPE" != "telegram" ]; then
                    echo -e "${RED}当前通知方式不是 TG，请先将通知方式切换为 TG${NC}"
                    sleep 2
                    continue
                fi
                echo -e "\n${YELLOW}请输入新的 Telegram Bot Token:${NC}"
                read -rp "Token: " new_token
                if [ -n "$new_token" ]; then
                    sed -i "s/TG_BOT_TOKEN=.*$/TG_BOT_TOKEN=\"$new_token\"/" "$CONFIG_FILE"
                    TG_BOT_TOKEN="$new_token"
                    validate_telegram && echo -e "${GREEN}Telegram Token 已更新且有效${NC}" || echo -e "${RED}Telegram Token 无效${NC}"
                    log "Telegram Bot Token updated"
                fi
                echo -e "\n${YELLOW}请输入新的 Telegram Chat ID(s) (多个 ID 用逗号分隔):${NC}"
                read -rp "Chat ID(s): " new_ids
                if [ -n "$new_ids" ]; then
                    sed -i "s/TG_CHAT_IDS=.*$/TG_CHAT_IDS=\"$new_ids\"/" "$CONFIG_FILE"
                    echo -e "${GREEN}Telegram Chat ID 已更新${NC}"
                    log "Telegram Chat IDs updated: $new_ids"
                fi
                ;;
            4)
                if [ "$NOTIFY_TYPE" != "dingtalk" ]; then
                    echo -e "${RED}当前通知方式不是钉钉，请先将通知方式切换为钉钉${NC}"
                    sleep 2
                    continue
                fi
                echo -e "\n${YELLOW}请输入新的钉钉 Webhook URL:${NC}"
                read -rp "Webhook: " new_webhook
                if [ -n "$new_webhook" ]; then
                    validate_dingtalk "$new_webhook"
                    sed -i "s|DINGTALK_WEBHOOK=.*$|DINGTALK_WEBHOOK=\"$new_webhook\"|" "$CONFIG_FILE"
                    echo -e "${GREEN}钉钉 Webhook 已更新${NC}"
                    log "DingTalk Webhook updated"
                fi
                ;;
            5)
                while true; do
                    echo -e "\n${CYAN}当前主机列表:${NC}"
                    if [ -n "$HOSTS_LIST" ]; then
                        IFS=',' read -ra HOSTS <<< "$HOSTS_LIST"
                        IFS=',' read -ra REMARKS <<< "$REMARKS_LIST"
                        for i in "${!HOSTS[@]}"; do
                            echo -e "  $((i+1)). ${HOSTS[$i]} (${REMARKS[$i]})"
                        done
                    else
                        echo -e "${RED}未配置任何主机${NC}"
                    fi
                    echo ""
                    echo -e "${CYAN}主机管理操作:${NC}"
                    echo -e "${CYAN}1.${NC} 添加主机"
                    echo -e "${CYAN}2.${NC} 删除主机"
                    echo -e "${CYAN}0.${NC} 返回"
                    read -rp "请选择 [0-2]: " host_choice
                    case $host_choice in
                        1)
                            echo -e "\n${YELLOW}请输入新的 IP 或域名 (每次输入一个，空行结束):${NC}"
                            echo -e "${YELLOW}示例: 192.168.1.1 或 example.com${NC}"
                            while true; do
                                read -rp "IP 或域名 (空行结束): " host
                                if [ -z "$host" ]; then
                                    break
                                fi
                                if ! validate_host "$host"; then
                                    echo -e "${RED}错误: $host 不是有效的 IP 或域名${NC}"
                                    continue
                                fi
                                read -rp "请输入 $host 的备注: " remark
                                if [ -z "$remark" ]; then
                                    echo -e "${RED}错误: 备注不能为空${NC}"
                                    continue
                                fi
                                [ -n "$HOSTS_LIST" ] && HOSTS_LIST+=","
                                [ -n "$REMARKS_LIST" ] && REMARKS_LIST+=","
                                HOSTS_LIST+="$host"
                                REMARKS_LIST+="$remark"
                                echo -e "${GREEN}已添加: $host ($remark)${NC}"
                            done
                            ;;
                        2)
                            if [ -z "$HOSTS_LIST" ]; then
                                echo -e "${RED}错误: 主机列表为空，无法删除${NC}"
                                sleep 2
                                continue
                            fi
                            echo -e "\n${YELLOW}请输入要删除的主机编号:${NC}"
                            IFS=',' read -ra HOSTS <<< "$HOSTS_LIST"
                            IFS=',' read -ra REMARKS <<< "$REMARKS_LIST"
                            read -rp "编号 (1-${#HOSTS[@]}): " delete_index
                            if [[ ! "$delete_index" =~ ^[0-9]+$ ]] || [ "$delete_index" -lt 1 ] || [ "$delete_index" -gt "${#HOSTS[@]}" ]; then
                                echo -e "${RED}错误: 无效的编号，请输入 1 到 ${#HOSTS[@]}${NC}"
                                sleep 2
                                continue
                            fi
                            delete_idx=$((delete_index-1))
                            echo -e "${YELLOW}将删除: ${HOSTS[$delete_idx]} (${REMARKS[$delete_idx]})${NC}"
                            read -rp "确认删除? [y/N]: " confirm
                            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                                echo -e "${YELLOW}取消删除${NC}"
                                sleep 2
                                continue
                            fi
                            new_hosts=""
                            new_remarks=""
                            for i in "${!HOSTS[@]}"; do
                                if [ "$i" -ne "$delete_idx" ]; then
                                    [ -n "$new_hosts" ] && new_hosts+=","
                                    [ -n "$new_remarks" ] && new_remarks+=","
                                    new_hosts+="${HOSTS[$i]}"
                                    new_remarks+="${REMARKS[$i]}"
                                fi
                            done
                            HOSTS_LIST="$new_hosts"
                            REMARKS_LIST="$new_remarks"
                            echo -e "${GREEN}主机已删除${NC}"
                            log "Deleted host: ${HOSTS[$delete_idx]} (${REMARKS[$delete_idx]})"
                            ;;
                        0)
                            sed -i "s/HOSTS_LIST=.*$/HOSTS_LIST=\"$HOSTS_LIST\"/" "$CONFIG_FILE"
                            sed -i "s/REMARKS_LIST=.*$/REMARKS_LIST=\"$REMARKS_LIST\"/" "$CONFIG_FILE"
                            echo -e "${GREEN}主机列表和备注已更新${NC}"
                            log "Host list and remarks updated"
                            break
                            ;;
                        *)
                            echo -e "${RED}无效选择，请重试${NC}"
                            sleep 1
                            ;;
                    esac
                done
                ;;
            6)
                echo -e "\n${YELLOW}请输入新的监控间隔 (秒):${NC}"
                read -rp "间隔 (默认60): " new_interval
                new_interval=${new_interval:-60}
                sed -i "s/INTERVAL=.*$/INTERVAL=\"$new_interval\"/" "$CONFIG_FILE"
                echo -e "${GREEN}监控间隔已更新为 ${new_interval}秒${NC}"
                log "Interval updated to $new_interval seconds"
                ;;
            7)
                echo -e "\n${YELLOW}请输入新的离线阈值 (连续失败次数):${NC}"
                read -rp "阈值 (默认3): " new_threshold
                new_threshold=${new_threshold:-3}
                sed -i "s/OFFLINE_THRESHOLD=.*$/OFFLINE_THRESHOLD=\"$new_threshold\"/" "$CONFIG_FILE"
                echo -e "${GREEN}离线阈值已更新为 ${new_threshold}次${NC}"
                log "Offline threshold updated to $new_threshold"
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选择，请重试${NC}"
                sleep 1
                ;;
        esac
        sleep 1
        load_config
    done
}

# Show usage help
show_usage() {
    echo -e "用法: $0 [命令]"
    echo ""
    echo -e "命令:"
    echo -e "  install   安装脚本"
    echo -e "  uninstall 卸载脚本"
    echo -e "  monitor   运行监控 (由cron调用)"
    echo -e "  menu      显示交互式菜单 (默认)"
    echo ""
}

# Main menu
show_menu() {
    while true; do
        print_menu_header
        if [ -f "$CONFIG_FILE" ]; then
            echo -e "${GREEN}● 监控系统已安装${NC}\n"
            show_config
        else
            echo -e "${RED}● 监控系统未安装${NC}\n"
        fi

        echo -e "请选择操作:"
        echo -e "${CYAN}1.${NC} 安装/重新安装"
        echo -e "${CYAN}2.${NC} 配置设置"
        echo -e "${CYAN}3.${NC} 测试通知"
        echo -e "${CYAN}4.${NC} 卸载"
        echo -e "${CYAN}5.${NC} 查看日志"
        echo -e "${CYAN}0.${NC} 退出"
        echo ""
        read -rp "请选择 [0-5]: " choice

        case $choice in
            1)
                install_script
                ;;
            2)
                modify_config
                ;;
            3)
                test_notifications
                ;;
            4)
                echo -e "\n${YELLOW}警告: 此操作将删除所有配置和脚本!${NC}"
                read -rp "确认卸载? [y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    uninstall_script
                fi
                ;;
            5)
                view_log
                ;;
            0)
                echo -e "\n${GREEN}感谢使用 PingX 监控系统!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择，请重试${NC}"
                sleep 1
                ;;
        esac
    done
}

main() {
    if [[ "$1" == "menu" || -z "$1" ]]; then
        if [ -x "$SCRIPT_PATH" ] && [ "$0" != "$SCRIPT_PATH" ]; then
            exec "$SCRIPT_PATH" menu
        else
            show_menu
        fi
    else
        case "$1" in
            monitor)
                monitor
                ;;
            install)
                install_script
                ;;
            uninstall)
                uninstall_script
                ;;
            help|--help|-h)
                show_usage
                ;;
            *)
                echo -e "${RED}错误: 未知命令 (Unknown command '$1')${NC}"
                show_usage
                exit 1
                ;;
        esac
    fi
}

# Global arrays for host status and failure counts
declare -A FAILURE_COUNTS
declare -A HOST_STATUS

main "$1"
