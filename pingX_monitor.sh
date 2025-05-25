#!/bin/sh

# PingX Monitor Script v1.1.7
# Purpose: Monitor host ping status and send notifications via Telegram or DingTalk
# Author: TheX
# GitHub: https://github.com/MEILOI/ping-x
# License: MIT
# Version: 1.1.7 (2025-05-25)
# Changelog:
# - v1.1.7: Fixed eval syntax error, restored settings menu, enhanced DingTalk validation
# - v1.1.6: Added DingTalk keyword, enhanced monitor logs, fixed offline notification
# - v1.1.5: Simplified to Chinese with English translations, fixed CRLF

# Detect OpenWrt/iStoreOS environment
if [ -f /etc/openwrt_release ]; then
    CRONTAB_PATH="/etc/crontabs/root"
    echo "檢測到 OpenWrt/iStoreOS，使用 $CRONTAB_PATH 配置計劃任務 (Detected OpenWrt/iStoreOS, using $CRONTAB_PATH)"
else
    CRONTAB_PATH="/etc/crontab"
fi

CONFIG_FILE="/etc/pingX_monitor.conf"
SCRIPT_PATH="/usr/local/bin/pingX_monitor.sh"
STATE_FILE="/etc/pingX_monitor.state"
LOCK_FILE="/var/lock/pingX_monitor.lock"
CRON_JOB="*/1 * * * * /usr/local/bin/pingX_monitor.sh monitor >> /var/log/pingX_monitor.log 2>&1"
LOG_FILE="/var/log/pingX_monitor.log"
LOG_MAX_SIZE=$((5*1024*1024)) # 5MB
MAX_LOG_FILES=5
TG_API="https://api.telegram.org/bot"
DINGTALK_KEYWORD="PingX" # Change to your DingTalk keyword if different

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Ensure log file exists
mkdir -p /var/log
touch "$LOG_FILE"

# Logging function
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" >> "$LOG_FILE"
    if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE")" -gt "$LOG_MAX_SIZE" ]; then
        for i in $(seq $((MAX_LOG_FILES-1)) -1 1); do
            [ -f "$LOG_FILE.$i" ] && mv "$LOG_FILE.$i" "$LOG_FILE.$((i+1))"
        done
        mv "$LOG_FILE" "$LOG_FILE.1"
        touch "$LOG_FILE"
        log "日誌已輪替，因超出大小限制 (Log rotated due to size limit)"
    fi
}

# Load configuration
load_config() {
    [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
    log "已載入配置: NOTIFY_TYPE=$NOTIFY_TYPE, HOSTS_LIST=$HOSTS_LIST (Loaded config)"
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
    log "配置已保存至 $CONFIG_FILE (Configuration saved)"
}

# Load state
load_state() {
    if [ -f "$STATE_FILE" ]; then
        log "載入狀態文件: $STATE_FILE (Loading state)"
        while IFS='=' read -r key value; do
            case "$key" in
                FAILURE_COUNTS_*|HOST_STATUS_*)
                    eval "$key=$value"
                    ;;
            esac
        done < "$STATE_FILE"
    fi
}

# Save state
save_state() {
    : > "$STATE_FILE"
    local hosts=$(echo "$HOSTS_LIST" | tr ',' ' ')
    for host in $hosts; do
        local safe_host=$(echo "$host" | tr '.' '_')
        eval "count=\${FAILURE_COUNTS_$safe_host:-0}"
        eval "status=\${HOST_STATUS_$safe_host:-0}"
        echo "FAILURE_COUNTS_$safe_host=$count" >> "$STATE_FILE"
        echo "HOST_STATUS_$safe_host=$status" >> "$STATE_FILE"
    done
    chmod 600 "$STATE_FILE"
    log "狀態已保存 (Saved state)"
}

# Validate Telegram configuration
validate_telegram() {
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_IDS" ]; then
        ping -c 1 api.telegram.org >/dev/null 2>&1 || log "警告：無法連接到 Telegram 伺服器 (Cannot reach Telegram server)"
        local response=$(curl -s -m 5 "${TG_API}${TG_BOT_TOKEN}/getMe")
        if echo "$response" | grep -q '"ok":true'; then
            log "Telegram Bot 驗證成功 (Validation succeeded)"
            return 0
        else
            log "錯誤：Telegram 驗證失敗: $response (Validation failed)"
            return 1
        fi
    else
        log "錯誤：Telegram 配置不完整 (Configuration incomplete)"
        return 1
    fi
}

# Validate DingTalk Webhook
validate_dingtalk() {
    local webhook="$1"
    ping -c 1 oapi.dingtalk.com >/dev/null 2>&1 || log "警告：無法連接到釘釘伺服器 (Cannot reach DingTalk server)"
    local message="$DINGTALK_KEYWORD: 測試訊息 (Test message)"
    local response=$(curl -s -m 5 -X POST "$webhook" \
        -H "Content-Type: application/json" \
        -d "{\"msgtype\": \"text\", \"text\": {\"content\": \"$message\"}}")
    if [ $? -eq 0 ] && echo "$response" | grep -q '"errcode":0'; then
        log "釘釘 Webhook 驗證成功 (Validation succeeded)"
        return 0
    else
        log "錯誤：釘釘 Webhook 驗證失敗: $response (Validation failed)"
        return 1
    fi
}

# Send Telegram notification
send_tg_notification() {
    local message="$1"
    if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_IDS" ]; then
        log "錯誤：Telegram 配置不完整 (Configuration incomplete)"
        return 1
    fi
    local IDS=$(echo "$TG_CHAT_IDS" | tr ',' ' ')
    local success=0
    for id in $IDS; do
        response=$(curl -s -m 5 -X POST "${TG_API}${TG_BOT_TOKEN}/sendMessage" \
            -H "Content-Type: application/json" \
            -d "{\"chat_id\": \"$id\", \"text\": \"$message\", \"parse_mode\": \"Markdown\"}")
        if echo "$response" | grep -q '"ok":true'; then
            log "Telegram 通知已發送至 $id (Notification sent)"
            success=1
        else
            log "錯誤：發送 Telegram 通知失敗: $response (Failed to send)"
        fi
    done
    [ $success -eq 1 ] && return 0 || return 1
}

# Send DingTalk notification
send_dingtalk_notification() {
    local message="$DINGTALK_KEYWORD: $1"
    if [ -z "$DINGTALK_WEBHOOK" ]; then
        log "錯誤：釘釘 Webhook 未配置 (Webhook not configured)"
        return 1
    fi
    local response=$(curl -s -m 5 -X POST "$DINGTALK_WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "{\"msgtype\": \"text\", \"text\": {\"content\": \"$message\"}}")
    if [ $? -eq 0 ] && echo "$response" | grep -q '"errcode":0'; then
        log "釘釘通知已發送: $message (Notification sent)"
        return 0
    else
        log "錯誤：發送釘釘通知失敗: $response (Failed to send)"
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
    local PING_RESULT=$(ping -c 1 -W 2 "$HOST" 2>&1)
    local PING_EXIT=$?
    local STATUS=""
    local LOG_ENTRY=""
    local safe_host=$(echo "$HOST" | tr '.' '_')

    log "對 $HOST ($REMARK) 進行 Ping，退出碼: $PING_EXIT (Ping attempt, exit code: $PING_EXIT)"

    eval "FAILURE_COUNTS=\${FAILURE_COUNTS_$safe_host:-0}"
    eval "HOST_STATUS=\${HOST_STATUS_$safe_host:-0}"
    log "當前狀態: $HOST ($REMARK), 失敗次數=$FAILURE_COUNTS, 狀態=$HOST_STATUS (Current state)"

    if [ $PING_EXIT -eq 0 ] && echo "$PING_RESULT" | grep -q "1 packets transmitted, 1 packets received"; then
        local RESPONSE_TIME=$(echo "$PING_RESULT" | grep "time=" | awk -F"time=" '{print $2}' | awk '{print $1}')
        STATUS="Ping 成功，響應時間: ${RESPONSE_TIME}ms (Ping successful)"
        if [ "$HOST_STATUS" = "1" ]; then
            HOST_STATUS=0
            FAILURE_COUNTS=0
            local message="✅ *主機上線通知 (Host Online Notification)*\n\n📍 *主機*: $HOST\n📝 *備註*: $REMARK\n🕒 *時間*: $CURRENT_TIME"
            send_notification "$message" && LOG_ENTRY="$CURRENT_TIME - $HOST ($REMARK) - $STATUS - 上線通知已發送 (Online notification sent)" || LOG_ENTRY="$CURRENT_TIME - $HOST ($REMARK) - $STATUS - 上線通知失敗 (Online notification failed)"
        else
            LOG_ENTRY="$CURRENT_TIME - $HOST ($REMARK) - $STATUS"
            FAILURE_COUNTS=0
        fi
    else
        STATUS="Ping 失敗: $PING_RESULT (Ping failed)"
        FAILURE_COUNTS=$((FAILURE_COUNTS + 1))
        LOG_ENTRY="$CURRENT_TIME - $HOST ($REMARK) - $STATUS - 失敗次數=$FAILURE_COUNTS"
        if [ "$FAILURE_COUNTS" -ge "$OFFLINE_THRESHOLD" ] && [ "$HOST_STATUS" = "0" ]; then
            HOST_STATUS=1
            local message="🛑 *主機離線通知 (Host Offline Notification)*\n\n📍 *主機*: $HOST\n📝 *備註*: $REMARK\n🕒 *時間*: $CURRENT_TIME\n⚠️ *連續失敗*: ${FAILURE_COUNTS}次 (Consecutive Failures)"
            send_notification "$message" && LOG_ENTRY="$LOG_ENTRY - 離線通知已發送 (Offline notification sent)" || LOG_ENTRY="$LOG_ENTRY - 離線通知失敗 (Offline notification failed)"
        fi
    fi

    eval "FAILURE_COUNTS_$safe_host=$FAILURE_COUNTS"
    eval "HOST_STATUS_$safe_host=$HOST_STATUS"

    echo "$LOG_ENTRY"
    echo "$LOG_ENTRY" >> "$LOG_FILE"
}

# Monitor function
monitor() {
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        log "另一個監控實例正在運行，退出 (Another instance running, exiting)"
        return 1
    fi

    load_config
    log "開始監控: HOSTS_LIST=$HOSTS_LIST, INTERVAL=$INTERVAL, OFFLINE_THRESHOLD=$OFFLINE_THRESHOLD (Starting monitor)"

    if [ "$NOTIFY_TYPE" = "telegram" ]; then
        validate_telegram || log "Telegram 驗證失敗，繼續監控 (Validation failed, continuing)"
    elif [ "$NOTIFY_TYPE" = "dingtalk" ]; then
        validate_dingtalk "$DINGTALK_WEBHOOK" || log "釘釘驗證失敗，繼續監控 (Validation failed, continuing)"
    fi

    if [ -z "$HOSTS_LIST" ]; then
        log "錯誤：無主機配置，退出監控 (No hosts configured, exiting)"
        return 1
    fi

    local HOSTS=$(echo "$HOSTS_LIST" | tr ',' ' ')
    local REMARKS="$REMARKS_LIST"
    local i=1
    for HOST in $HOSTS; do
        local safe_host=$(echo "$HOST" | tr '.' '_')
        eval "FAILURE_COUNTS_$safe_host=\${FAILURE_COUNTS_$safe_host:-0}"
        eval "HOST_STATUS_$safe_host=\${HOST_STATUS_$safe_host:-0}"
        log "初始化 $HOST: 失敗次數=$FAILURE_COUNTS_$safe_host, 狀態=$HOST_STATUS_$safe_host (Initialized)"
        i=$((i+1))
    done

    load_state

    local attempts=$((60 / INTERVAL))
    [ $attempts -lt 1 ] && attempts=1

    i=1
    while [ $i -le $attempts ]; do
        log "監控嘗試 $i/$attempts (Monitor attempt)"
        local j=1
        for HOST in $HOSTS; do
            REMARK=$(echo "$REMARKS" | cut -d',' -f$j)
            ping_host "$HOST" "$REMARK"
            j=$((j+1))
        done
        save_state
        i=$((i+1))
        [ $i -le $attempts ] && sleep "$INTERVAL"
    done

    flock -u 200
}

# Check dependencies
check_dependencies() {
    for cmd in curl ping flock; do
        if ! command -v $cmd >/dev/null 2>&1; then
            echo -e "${RED}缺少依賴: $cmd (Missing dependency)${NC}"
            if [ -f /etc/openwrt_release ]; then
                opkg update >/dev/null 2>&1
                opkg install curl iputils-ping util-linux >/dev/null 2>&1
            else
                echo -e "${RED}未檢測到 OpenWrt/iStoreOS，請手動安裝 $cmd (Please install manually)${NC}"
                log "錯誤：無包管理器支持 $cmd (No package manager)${NC}"
                exit 1
            fi
            if ! command -v $cmd >/dev/null 2>&1; then
                echo -e "${RED}安裝 $cmd 失敗，請手動安裝 (Failed to install)${NC}"
                exit 1
            fi
        fi
    done
    log "依賴檢查完成: curl ping flock (Dependencies checked)"
}

# Validate IP or domain
validate_host() {
    local host="$1"
    if echo "$host" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' >/dev/null || \
       echo "$host" | grep -E '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$' >/dev/null; then
        return 0
    else
        return 1
    fi
}

# Print menu header
print_menu_header() {
    clear
    log "顯示菜單頭部 (Displaying menu header)"
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo -e "${CYAN}║     ${YELLOW}PingX Monitor System (v1.1.7)     ${CYAN}║${NC}"
    echo -e "${CYAN}║     ${YELLOW}作者: TheX (Author: TheX)         ${CYAN}║${NC}"
    echo -e "${CYAN}║     ${YELLOW}GitHub: https://github.com/MEILOI/ping-x ${CYAN}║${NC}"
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    if [ -f /etc/openwrt_release ]; then
        echo -e "${YELLOW}提示：請確保 WAN 連線和 DNS 正常 (Tip: Ensure WAN and DNS are working)${NC}"
        echo -e "${YELLOW}檢查日誌：/var/log/pingX_monitor.log (Check log)${NC}"
    fi
    echo ""
}

# Show current configuration
show_config() {
    echo -e "${CYAN}當前配置 (Current Configuration):${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
        echo -e "${CYAN}通知方式 (Notification Type):${NC} ${NOTIFY_TYPE:-未設置 (Not set)}"
        if [ "$NOTIFY_TYPE" = "telegram" ]; then
            if [ -n "$TG_BOT_TOKEN" ]; then
                token_prefix=$(echo $TG_BOT_TOKEN | cut -d':' -f1)
                echo -e "${CYAN}Telegram Bot Token:${NC} $token_prefix:****"
            else
                echo -e "${CYAN}Telegram Bot Token:${NC} ${RED}未設置 (Not set)${NC}"
            fi
            echo -e "${CYAN}Telegram Chat IDs:${NC} ${TG_CHAT_IDS:-未設置 (Not set)}"
        else
            if [ -n "$DINGTALK_WEBHOOK" ]; then
                webhook_masked=$(echo "$DINGTALK_WEBHOOK" | cut -c1-10)****
                echo -e "${CYAN}釘釘 Webhook (DingTalk Webhook):${NC} $webhook_masked"
            else
                echo -e "${CYAN}釘釘 Webhook (DingTalk Webhook):${NC} ${RED}未設置 (Not set)${NC}"
            fi
        fi
        echo -e "${CYAN}監控間隔 (Monitor Interval):${NC} ${INTERVAL:-60} 秒 (seconds)"
        echo -e "${CYAN}離線閾值 (Offline Threshold):${NC} ${OFFLINE_THRESHOLD:-3} 次 (times)"
        echo -e "${CYAN}主機列表 (Host List):${NC}"
        if [ -n "$HOSTS_LIST" ]; then
            local HOSTS=$(echo "$HOSTS_LIST" | tr ',' ' ')
            local REMARKS="$REMARKS_LIST"
            local i=1
            for host in $HOSTS; do
                remark=$(echo "$REMARKS" | cut -d',' -f$i)
                echo -e "  $i. $host ($remark)"
                i=$((i+1))
            done
        else
            echo -e "${RED}未配置任何主機 (No hosts configured)${NC}"
        fi
    else
        echo -e "${RED}未找到配置文件，請先安裝腳本 (Config file not found, please install)${NC}"
    fi
    echo ""
}

# View log
view_log() {
    print_menu_header
    echo -e "${CYAN}[查看日誌 (View Log)]${NC} 顯示最新 20 行 (Showing last 20 lines):\n"
    if [ -f "$LOG_FILE" ]; then
        tail -n 20 "$LOG_FILE"
    else
        echo -e "${RED}日誌文件不存在 (Log file does not exist)${NC}"
    fi
    echo ""
    read -p "按 Enter 鍵繼續... (Press Enter to continue...)"
}

# Install script
install_script() {
    print_menu_header
    echo -e "${CYAN}[安裝 (Install)] ${GREEN}安裝 PingX 監控系統... (Installing PingX Monitor System...)${NC}"
    echo ""

    check_dependencies

    echo -e "${CYAN}[1/5]${NC} 選擇通知方式 (Select notification type):"
    echo -e "${CYAN}1.${NC} Telegram"
    echo -e "${CYAN}2.${NC} 釘釘 (DingTalk)"
    read -p "請選擇 [1-2] (Choose [1-2]): " notify_choice
    case $notify_choice in
        1) NOTIFY_TYPE="telegram"; log "通知方式設置為 Telegram (Set to Telegram)" ;;
        2) NOTIFY_TYPE="dingtalk"; log "通知方式設置為釘釘 (Set to DingTalk)" ;;
        *) echo -e "${RED}無效選擇，默認 Telegram (Invalid choice, default Telegram)${NC}"; NOTIFY_TYPE="telegram"; log "無效選擇，默認 Telegram (Invalid choice)" ;;
    esac

    if [ "$NOTIFY_TYPE" = "telegram" ]; then
        echo -e "\n${CYAN}[2/5]${NC} 輸入 Telegram Bot Token (Enter Telegram Bot Token):"
        read -p "Token (格式如123456789:ABCDEF...) (Format like 123456789:ABCDEF...): " TG_BOT_TOKEN
        echo -e "\n${CYAN}[3/5]${NC} 輸入 Telegram Chat ID (Enter Telegram Chat ID):"
        read -p "Chat ID (支持多個，逗號分隔) (Multiple IDs, comma-separated): " TG_CHAT_IDS
        if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_IDS" ]; then
            validate_telegram && echo -e "${GREEN}Token 有效 (Token valid)${NC}" || echo -e "${RED}Token 無效，請檢查日誌 (Token invalid, check log)${NC}"
        fi
        DINGTALK_WEBHOOK=""
    else
        echo -e "\n${CYAN}[2/5]${NC} 輸入釘釘 Webhook URL (Enter DingTalk Webhook URL):"
        read -p "Webhook: " DINGTALK_WEBHOOK
        if [ -n "$DINGTALK_WEBHOOK" ]; then
            validate_dingtalk "$DINGTALK_WEBHOOK"
        fi
        TG_BOT_TOKEN=""
        TG_CHAT_IDS=""
    fi

    echo -e "\n${CYAN}[3/5]${NC} 輸入要監控的 IP 或域名 (Enter IPs or domains to monitor):"
    echo -e "${YELLOW}示例: 192.168.1.1 或 example.com (Example: 192.168.1.1 or example.com)${NC}"
    HOSTS_LIST=""
    REMARKS_LIST=""
    while true; do
        read -p "IP 或域名 (空行結束) (IP or domain, empty to finish): " host
        if [ -z "$host" ]; then
            [ -z "$HOSTS_LIST" ] && echo -e "${YELLOW}警告: 未添加任何主機 (No hosts added)${NC}"
            break
        fi
        if ! validate_host "$host"; then
            echo -e "${RED}錯誤：無效的 IP 或域名 (Invalid IP or domain)${NC}"
            continue
        fi
        read -p "請輸入備註 (Enter remark for $host): " remark
        if [ -z "$remark" ]; then
            echo -e "${RED}錯誤：備註不能為空 (Remark cannot be empty)${NC}"
            continue
        fi
        [ -n "$HOSTS_LIST" ] && HOSTS_LIST="$HOSTS_LIST,"
        [ -n "$REMARKS_LIST" ] && REMARKS_LIST="$REMARKS_LIST,"
        HOSTS_LIST="$HOSTS_LIST$host"
        REMARKS_LIST="$REMARKS_LIST$remark"
        echo -e "${GREEN}已添加: $host ($remark) (Added)${NC}"
    done

    echo -e "\n${CYAN}[4/5]${NC} 輸入監控間隔 (Enter monitor interval):"
    read -p "間隔 (秒，默認60) (Seconds, default 60): " INTERVAL
    INTERVAL=${INTERVAL:-60}
    echo -e "\n${CYAN}[5/5]${NC} 輸入離線閾值 (Enter offline threshold):"
    read -p "閾值 (連續失敗次數，默認3) (Consecutive failures, default 3): " OFFLINE_THRESHOLD
    OFFLINE_THRESHOLD=${OFFLINE_THRESHOLD:-3}

    save_config

    mkdir -p /usr/local/bin
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"

    sed -i '/pingX_monitor.sh monitor/d' "$CRONTAB_PATH"
    echo "$CRON_JOB" >> "$CRONTAB_PATH"
    if [ -f /etc/openwrt_release ]; then
        /etc/init.d/cron restart >/dev/null 2>&1
        if grep -q "pingX_monitor.sh monitor" "$CRONTAB_PATH"; then
            log "計劃任務配置成功 (Crontab configured)"
        else
            log "錯誤：計劃任務配置失敗 (Crontab failed)"
            echo -e "${RED}錯誤：計劃任務配置失敗 (Crontab configuration failed)${NC}"
            exit 1
        fi
    fi

    rm -f "$STATE_FILE"
    log "安裝時清除狀態文件 (Cleared state file)"

    echo -e "\n${GREEN}✅ 安裝完成！(Installation complete!)${NC}"
    echo -e "${YELLOW}提示: 可以從菜單選擇'測試通知'驗證配置 (Tip: Test notifications from menu)${NC}"
    log "安裝完成 (Installation completed)"
    sleep 2
}

# Uninstall script
uninstall_script() {
    print_menu_header
    echo -e "${CYAN}[卸載 (Uninstall)] ${YELLOW}卸載 PingX 監控系統... (Uninstalling PingX Monitor System...)${NC}\n"

    sed -i '/pingX_monitor.sh monitor/d' "$CRONTAB_PATH"
    if [ -f /etc/openwrt_release ]; then
        /etc/init.d/cron restart >/dev/null 2>&1
    fi
    rm -f "$SCRIPT_PATH" "$CONFIG_FILE" "$STATE_FILE" "$LOCK_FILE"
    rm -f "$LOG_FILE" "${LOG_FILE}".*
    rmdir /var/log 2>/dev/null || true

    echo -e "\n${GREEN}✅ 卸載完成！(Uninstallation complete!)${NC}"
    echo -e "${YELLOW}所有配置文件和腳本已刪除 (All configs and scripts removed)${NC}"
    log "卸載完成 (Uninstallation completed)"
    sleep 2
    exit 0
}

# Test notifications
test_notifications() {
    load_config
    while true; do
        print_menu_header
        echo -e "${CYAN}[測試通知 (Test Notifications)]${NC} 選擇要測試的通知類型 (Select notification type):\n"
        echo -e "${CYAN}1.${NC} 測試離線通知 (Test offline notification)"
        echo -e "${CYAN}2.${NC} 測試上線通知 (Test online notification)"
        echo -e "${CYAN}0.${NC} 返回主菜單 (Return to main menu)"
        echo ""
        read -p "請選擇 [0-2] (Choose [0-2]): " choice
        case $choice in
            1)
                echo -e "\n${YELLOW}正在發送離線通知... (Sending offline notification...)${NC}"
                local test_host="192.168.1.100"
                local test_remark="測試主機 (Test Host)"
                local time=$(date '+%Y-%m-%d %H:%M:%S')
                local message="🛑 *主機離線通知 (Host Offline Notification)*\n\n📍 *主機*: $test_host\n📝 *備註*: $test_remark\n🕒 *時間*: $time\n⚠️ *連續失敗*: ${OFFLINE_THRESHOLD}次 (Consecutive Failures)"
                send_notification "$message" && echo -e "\n${GREEN}通知已發送，請檢查通知渠道 (Notification sent, check channel)${NC}" || echo -e "\n${RED}通知發送失敗，請檢查日誌 (Notification failed, check log)${NC}"
                read -p "按 Enter 鍵繼續... (Press Enter to continue...)"
                ;;
            2)
                echo -e "\n${YELLOW}正在發送上線通知... (Sending online notification...)${NC}"
                local test_host="192.168.1.100"
                local test_remark="測試主機 (Test Host)"
                local time=$(date '+%Y-%m-%d %H:%M:%S')
                local message="✅ *主機上線通知 (Host Online Notification)*\n\n📍 *主機*: $test_host\n📝 *備註*: $test_remark\n🕒 *時間*: $time"
                send_notification "$message" && echo -e "\n${GREEN}通知已發送，請檢查通知渠道 (Notification sent, check channel)${NC}" || echo -e "\n${RED}通知發送失敗，請檢查日誌 (Notification failed, check log)${NC}"
                read -p "按 Enter 鍵繼續... (Press Enter to continue...)"
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}無效選擇，請重試 (Invalid choice, try again)${NC}"
                sleep 1
                ;;
        esac
    done
}

# Settings menu
settings_menu() {
    load_config
    while true; do
        print_menu_header
        echo -e "${CYAN}[設置 (Settings)]${NC} 選擇要修改的配置 (Select configuration to modify):\n"
        echo -e "${CYAN}1.${NC} 修改通知方式 (Change notification type)"
        echo -e "${CYAN}2.${NC} 修改監控間隔 (Change monitor interval)"
        echo -e "${CYAN}3.${NC} 修改離線閾值 (Change offline threshold)"
        echo -e "${CYAN}4.${NC} 添加主機 (Add host)"
        echo -e "${CYAN}5.${NC} 刪除主機 (Remove host)"
        echo -e "${CYAN}0.${NC} 返回主菜單 (Return to main menu)"
        echo ""
        read -p "請選擇 [0-5] (Choose [0-5]): " choice
        case $choice in
            1)
                echo -e "\n${CYAN}選擇通知方式 (Select notification type):${NC}"
                echo -e "${CYAN}1.${NC} Telegram"
                echo -e "${CYAN}2.${NC} 釘釘 (DingTalk)"
                read -p "請選擇 [1-2] (Choose [1-2]): " notify_choice
                case $notify_choice in
                    1)
                        NOTIFY_TYPE="telegram"
                        log "通知方式設置為 Telegram (Set to Telegram)"
                        echo -e "\n${CYAN}輸入 Telegram Bot Token:${NC}"
                        read -p "Token: " TG_BOT_TOKEN
                        echo -e "\n${CYAN}輸入 Telegram Chat ID:${NC}"
                        read -p "Chat ID (支持多個，逗號分隔): " TG_CHAT_IDS
                        if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_IDS" ]; then
                            validate_telegram && echo -e "${GREEN}Token 有效${NC}" || echo -e "${RED}Token 無效，請檢查日誌${NC}"
                        fi
                        DINGTALK_WEBHOOK=""
                        ;;
                    2)
                        NOTIFY_TYPE="dingtalk"
                        log "通知方式設置為釘釘 (Set to DingTalk)"
                        echo -e "\n${CYAN}輸入釘釘 Webhook URL:${NC}"
                        read -p "Webhook: " DINGTALK_WEBHOOK
                        if [ -n "$DINGTALK_WEBHOOK" ]; then
                            validate_dingtalk "$DINGTALK_WEBHOOK"
                        fi
                        TG_BOT_TOKEN=""
                        TG_CHAT_IDS=""
                        ;;
                    *)
                        echo -e "${RED}無效選擇，保持原設置${NC}"
                        ;;
                esac
                save_config
                echo -e "\n${GREEN}通知方式已更新${NC}"
                read -p "按 Enter 鍵繼續..."
                ;;
            2)
                echo -e "\n${CYAN}輸入監控間隔:${NC}"
                read -p "間隔 (秒，當前 ${INTERVAL:-60}): " new_interval
                if [ -n "$new_interval" ] && echo "$new_interval" | grep -E '^[0-9]+$' >/dev/null; then
                    INTERVAL="$new_interval"
                    save_config
                    echo -e "${GREEN}監控間隔已更新為 $INTERVAL 秒${NC}"
                else
                    echo -e "${RED}無效輸入，保持原間隔${NC}"
                fi
                read -p "按 Enter 鍵繼續..."
                ;;
            3)
                echo -e "\n${CYAN}輸入離線閾值:${NC}"
                read -p "閾值 (連續失敗次數，當前 ${OFFLINE_THRESHOLD:-3}): " new_threshold
                if [ -n "$new_threshold" ] && echo "$new_threshold" | grep -E '^[0-9]+$' >/dev/null; then
                    OFFLINE_THRESHOLD="$new_threshold"
                    save_config
                    echo -e "${GREEN}離線閾值已更新為 $OFFLINE_THRESHOLD 次${NC}"
                else
                    echo -e "${RED}無效輸入，保持原閾值${NC}"
                fi
                read -p "按 Enter 鍵繼續..."
                ;;
            4)
                echo -e "\n${CYAN}添加主機:${NC}"
                read -p "IP 或域名 (例如 192.168.1.1 或 example.com): " host
                if [ -n "$host" ] && validate_host "$host"; then
                    read -p "請輸入備註: " remark
                    if [ -n "$remark" ]; then
                        [ -n "$HOSTS_LIST" ] && HOSTS_LIST="$HOSTS_LIST,"
                        [ -n "$REMARKS_LIST" ] && REMARKS_LIST="$REMARKS_LIST,"
                        HOSTS_LIST="$HOSTS_LIST$host"
                        REMARKS_LIST="$REMARKS_LIST$remark"
                        save_config
                        echo -e "${GREEN}已添加: $host ($remark)${NC}"
                    else
                        echo -e "${RED}備註不能為空${NC}"
                    fi
                else
                    echo -e "${RED}無效的 IP 或域名${NC}"
                fi
                read -p "按 Enter 鍵繼續..."
                ;;
            5)
                if [ -z "$HOSTS_LIST" ]; then
                    echo -e "${RED}無主機可刪除${NC}"
                    read -p "按 Enter 鍵繼續..."
                    continue
                fi
                echo -e "\n${CYAN}選擇要刪除的主機:${NC}"
                local HOSTS=$(echo "$HOSTS_LIST" | tr ',' ' ')
                local REMARKS="$REMARKS_LIST"
                local i=1
                for host in $HOSTS; do
                    remark=$(echo "$REMARKS" | cut -d',' -f$i)
                    echo -e "${CYAN}$i.${NC} $host ($remark)"
                    i=$((i+1))
                done
                read -p "請輸入編號 (0 取消): " index
                if [ "$index" = "0" ] || [ -z "$index" ]; then
                    echo -e "${YELLOW}取消刪除${NC}"
                    read -p "按 Enter 鍵繼續..."
                    continue
                fi
                if echo "$index" | grep -E '^[0-9]+$' >/dev/null && [ "$index" -ge 1 ] && [ "$index" -lt "$i" ]; then
                    local new_hosts=""
                    local new_remarks=""
                    local j=1
                    for host in $HOSTS; do
                        if [ "$j" != "$index" ]; then
                            [ -n "$new_hosts" ] && new_hosts="$new_hosts,"
                            new_hosts="$new_hosts$host"
                            remark=$(echo "$REMARKS" | cut -d',' -f$j)
                            [ -n "$new_remarks" ] && new_remarks="$new_remarks,"
                            new_remarks="$new_remarks$remark"
                        fi
                        j=$((j+1))
                    done
                    HOSTS_LIST="$new_hosts"
                    REMARKS_LIST="$new_remarks"
                    save_config
                    echo -e "${GREEN}主機已刪除${NC}"
                else
                    echo -e "${RED}無效編號${NC}"
                fi
                read -p "按 Enter 鍵繼續..."
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}無效選擇，請重試${NC}"
                sleep 1
                ;;
        esac
    done
}

# Main menu
show_menu() {
    while true; do
        print_menu_header
        if [ -f "$CONFIG_FILE" ]; then
            echo -e "${GREEN}● 監控系統已安裝 (Monitor system installed)${NC}\n"
            show_config
        else
            echo -e "${RED}● 監控系統未安裝 (Monitor system not installed)${NC}\n"
        fi

        echo -e "請選擇操作 (Select operation):"
        echo -e "${CYAN}1.${NC} 安裝/重新安裝 (Install/Reinstall)"
        echo -e "${CYAN}2.${NC} 測試通知 (Test notifications)"
        echo -e "${CYAN}3.${NC} 設置 (Settings)"
        echo -e "${CYAN}4.${NC} 卸載 (Uninstall)"
        echo -e "${CYAN}5.${NC} 查看日誌 (View log)"
        echo -e "${CYAN}0.${NC} 退出 (Exit)"
        echo ""
        read -p "請選擇 [0-5] (Choose [0-5]): " choice
        case $choice in
            1)
                install_script
                ;;
            2)
                test_notifications
                ;;
            3)
                settings_menu
                ;;
            4)
                echo -e "\n${YELLOW}警告: 此操作將刪除所有配置和腳本！(This will delete all configs and scripts!)${NC}"
                read -p "確認卸載? [y/N] (Confirm uninstall? [y/N]): " confirm
                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                    uninstall_script
                fi
                ;;
            5)
                view_log
                ;;
            0)
                echo -e "\n${GREEN}感謝使用 PingX 監控系統！(Thank you for using PingX Monitor!)${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}無效選擇，請重試 (Invalid choice, try again)${NC}"
                sleep 1
                ;;
        esac
    done
}

main() {
    if [ "$1" = "monitor" ]; then
        monitor
    elif [ "$1" = "install" ]; then
        install_script
    elif [ "$1" = "uninstall" ]; then
        uninstall_script
    else
        show_menu
    fi
}

main "$1"
