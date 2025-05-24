#!/bin/sh

# PingX Monitor Script v1.1.2
# Purpose: Monitor host ping status and send notifications via Telegram or DingTalk
# Author: TheX
# GitHub: https://github.com/MEILOI/ping-x
# License: MIT
# Version: 1.1.2 (2025-05-24)
# Changelog:
# - v1.1.2: Fixed syntax error in ash (line 896), simplified modify_config loops,
#            replaced eval with sed/grep, enhanced ash compatibility, verified with sh -n
# - v1.1.1: Fixed syntax error in ash (line 880), removed bash associative arrays,
#            used file-based state storage, simplified nested structures
# - v1.1.0: Optimized for iStoreOS/OpenWrt: removed systemd, adapted crontab to /etc/crontabs/root,
#            used /bin/sh, persistent state in /etc/, opkg for dependencies, improved Webhook debug
# - v1.0.8: Added domain name support, renamed to pingX_monitor, updated menu header

# Detect OpenWrt/iStoreOS environment
if [ -f /etc/openwrt_release ]; then
    CRONTAB_PATH="/etc/crontabs/root"
    echo "Detected OpenWrt/iStoreOS, using $CRONTAB_PATH for crontab"
else
    CRONTAB_PATH="/etc/crontab"
fi

CONFIG_FILE="/etc/pingX_monitor.conf"
SCRIPT_PATH="/usr/local/bin/pingX_monitor.sh"
STATE_FILE="/etc/pingX_monitor.state"
LOCK_FILE="/var/lock/pingX_monitor.lock"
CRON_JOB="*/1 * * * * root /usr/local/bin/pingX_monitor.sh monitor >> /var/log/pingX_monitor.log 2>&1"
LOG_FILE="/var/log/pingX_monitor.log"
LOG_MAX_SIZE=$((5*1024*1024)) # 5MB
MAX_LOG_FILES=5
TG_API="https://api.telegram.org/bot"

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
        log "Log rotated due to size limit"
    fi
}

# Load configuration
load_config() {
    [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
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

# Load state (FAILURE_COUNTS and HOST_STATUS from file)
load_state() {
    if [ -f "$STATE_FILE" ]; then
        while IFS='=' read -r key value; do
            case "$key" in
                FAILURE_COUNTS_*)
                    host=$(echo "$key" | sed 's/^FAILURE_COUNTS_//')
                    echo "FAILURE_COUNTS_$host=$value" >> /tmp/pingX_state
                    ;;
                HOST_STATUS_*)
                    host=$(echo "$key" | sed 's/^HOST_STATUS_//')
                    echo "HOST_STATUS_$host=$value" >> /tmp/pingX_state
                    ;;
            esac
        done < "$STATE_FILE"
        [ -f /tmp/pingX_state ] && . /tmp/pingX_state
        rm -f /tmp/pingX_state
        log "Loaded state from $STATE_FILE"
    fi
}

# Save state
save_state() {
    : > "$STATE_FILE"
    for host in $(echo "$HOSTS_LIST" | tr ',' ' '); do
        count=$(grep "^FAILURE_COUNTS_$host=" /tmp/pingX_state 2>/dev/null | cut -d'=' -f2 || echo "0")
        status=$(grep "^HOST_STATUS_$host=" /tmp/pingX_state 2>/dev/null | cut -d'=' -f2 || echo "0")
        echo "FAILURE_COUNTS_$host=$count" >> "$STATE_FILE"
        echo "HOST_STATUS_$host=$status" >> "$STATE_FILE"
    done
    chmod 600 "$STATE_FILE"
    log "Saved state to $STATE_FILE"
}

# Validate Telegram configuration
validate_telegram() {
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_IDS" ]; then
        ping -c 1 api.telegram.org >/dev/null 2>&1 || log "WARNING: Cannot reach Telegram server"
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
    ping -c 1 oapi.dingtalk.com >/dev/null 2>&1 || log "WARNING: Cannot reach DingTalk server"
    local response=$(curl -s -m 5 -X POST "$webhook" \
        -H "Content-Type: application/json" \
        -d '{"msgtype": "text", "text": {"content": "Test message"}}')
    local curl_exit=$?
    if [ $curl_exit -eq 0 ] && echo "$response" | grep -q '"errcode":0'; then
        log "DingTalk Webhook validation succeeded: $(echo "$webhook" | cut -c1-10)****"
        return 0
    else
        log "ERROR: DingTalk Webhook validation failed: $(echo "$webhook" | cut -c1-10)****, curl exit: $curl_exit, response: $response"
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

    local IDS=$(echo "$TG_CHAT_IDS" | tr ',' ' ')
    local success=0
    for id in $IDS; do
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
    if [ $? -eq 0 ] && echo "$response" | grep -q '"errcode":0'; then
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

    PING_RESULT=$(ping -c 1 -W 2 "$HOST" 2>&1)
    local PING_EXIT=$?

    log "Ping attempt for $HOST ($REMARK): $PING_RESULT"

    local FAILURE_COUNTS=$(grep "^FAILURE_COUNTS_$HOST=" /tmp/pingX_state 2>/dev/null | cut -d'=' -f2 || echo "0")
    local HOST_STATUS=$(grep "^HOST_STATUS_$HOST=" /tmp/pingX_state 2>/dev/null | cut -d'=' -f2 || echo "0")

    if [ $PING_EXIT -eq 0 ] && echo "$PING_RESULT" | grep -q "1 packets transmitted, 1 packets received"; then
        local RESPONSE_TIME=$(echo "$PING_RESULT" | grep "time=" | awk -F"time=" '{print $2}' | awk '{print $1}')
        STATUS="Ping successful, response time: ${RESPONSE_TIME}ms"
        if [ "$HOST_STATUS" = "1" ]; then
            HOST_STATUS=0
            FAILURE_COUNTS=0
            local message="✅ *Host Online Notification*\n\n📍 *Host*: $HOST\n📝 *Remark*: $REMARK\n🕒 *Time*: $CURRENT_TIME"
            send_notification "$message" && LOG_ENTRY="$CURRENT_TIME - $HOST ($REMARK) - $STATUS - Online notification sent" || LOG_ENTRY="$CURRENT_TIME - $HOST ($REMARK) - $STATUS - Online notification failed"
            log "Reset $HOST: Failure count=$FAILURE_COUNTS, Status=$HOST_STATUS"
        else
            LOG_ENTRY="$CURRENT_TIME - $HOST ($REMARK) - $STATUS"
            FAILURE_COUNTS=0
            log "Reset $HOST: Failure count=$FAILURE_COUNTS, Status=$HOST_STATUS"
        fi
    else
        STATUS="Ping failed: $PING_RESULT"
        FAILURE_COUNTS=$((FAILURE_COUNTS + 1))
        LOG_ENTRY="$CURRENT_TIME - $HOST ($REMARK) - $STATUS"
        log "Failure count for $HOST: $FAILURE_COUNTS, Threshold: $OFFLINE_THRESHOLD, Status: $HOST_STATUS"
        if [ "$FAILURE_COUNTS" -ge "$OFFLINE_THRESHOLD" ] && [ "$HOST_STATUS" = "0" ]; then
            HOST_STATUS=1
            local message="🛑 *Host Offline Notification*\n\n📍 *Host*: $HOST\n📝 *Remark*: $REMARK\n🕒 *Time*: $CURRENT_TIME\n⚠️ *Consecutive Failures*: ${FAILURE_COUNTS}"
            send_notification "$message" && LOG_ENTRY="$LOG_ENTRY - Offline notification sent" || LOG_ENTRY="$LOG_ENTRY - Offline notification failed"
        fi
    fi

    sed -i "/^FAILURE_COUNTS_$HOST=/d" /tmp/pingX_state 2>/dev/null
    sed -i "/^HOST_STATUS_$HOST=/d" /tmp/pingX_state 2>/dev/null
    echo "FAILURE_COUNTS_$HOST=$FAILURE_COUNTS" >> /tmp/pingX_state
    echo "HOST_STATUS_$HOST=$HOST_STATUS" >> /tmp/pingX_state

    echo "$LOG_ENTRY"
    echo "$LOG_ENTRY" >> "$LOG_FILE"
}

# Monitor function (called by cron)
monitor() {
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        log "Another monitor instance is running, exiting"
        return 1
    fi

    load_config
    load_state

    if [ "$NOTIFY_TYPE" = "telegram" ]; then
        validate_telegram || return 1
    elif [ "$NOTIFY_TYPE" = "dingtalk" ]; then
        validate_dingtalk "$DINGTALK_WEBHOOK" || return 1
    fi

    local HOSTS=$(echo "$HOSTS_LIST" | tr ',' ' ')
    local REMARKS="$REMARKS_LIST"

    for HOST in $HOSTS; do
        grep -q "^FAILURE_COUNTS_$HOST=" /tmp/pingX_state 2>/dev/null || echo "FAILURE_COUNTS_$HOST=0" >> /tmp/pingX_state
        grep -q "^HOST_STATUS_$HOST=" /tmp/pingX_state 2>/dev/null || echo "HOST_STATUS_$HOST=0" >> /tmp/pingX_state
        log "Initialized $HOST: Failure count=$(grep "^FAILURE_COUNTS_$HOST=" /tmp/pingX_state | cut -d'=' -f2), Status=$(grep "^HOST_STATUS_$HOST=" /tmp/pingX_state | cut -d'=' -f2)"
    done

    local attempts=$((60 / INTERVAL))
    [ $attempts -lt 1 ] && attempts=1

    for attempt in $(seq 1 $attempts); do
        log "Monitor attempt $attempt/$attempts"
        i=1
        for HOST in $HOSTS; do
            REMARK=$(echo "$REMARKS" | cut -d',' -f$i)
            ping_host "$HOST" "$REMARK"
            i=$((i+1))
        done
        save_state
        [ $attempt -lt $attempts ] && sleep "$INTERVAL"
    done

    flock -u 200
}

# Check dependencies
check_dependencies() {
    for cmd in curl ping flock; do
        if ! command -v $cmd >/dev/null 2>&1; then
            echo -e "${RED}Missing dependency: $cmd${NC}"
            echo -e "${YELLOW}Attempting to install $cmd...${NC}"
            if [ -f /etc/openwrt_release ]; then
                opkg update >/dev/null 2>&1
                opkg install curl iputils-ping util-linux >/dev/null 2>&1
            else
                echo -e "${RED}Not detected OpenWrt/iStoreOS, please install $cmd manually${NC}"
                log "ERROR: No supported package manager for $cmd"
                exit 1
            fi
            if ! command -v $cmd >/dev/null 2>&1; then
                echo -e "${RED}Failed to install $cmd, please install manually${NC}"
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
    if echo "$host" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' >/dev/null; then
        return 0
    elif echo "$host" | grep -E '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$' >/dev/null; then
        return 0
    else
        return 1
    fi
}

# Print menu header
print_menu_header() {
    clear
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo -e "${CYAN}║     ${YELLOW}PingX Monitor System (v1.1.2)     ${CYAN}║${NC}"
    echo -e "${CYAN}║     ${YELLOW}Author: TheX                  ${CYAN}║${NC}"
    echo -e "${CYAN}║     ${YELLOW}GitHub: https://github.com/MEILOI/ping-x ${CYAN}║${NC}"
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    if [ -f /etc/openwrt_release ]; then
        echo -e "${YELLOW}iStoreOS/OpenWrt Tip: Ensure WAN connectivity and DNS are working${NC}"
        echo -e "${YELLOW}Check log for issues: /var/log/pingX_monitor.log${NC}"
    fi
    echo ""
}

# Show current configuration
show_config() {
    echo -e "${CYAN}Current Configuration:${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
        echo -e "${CYAN}Notification Type:${NC} ${NOTIFY_TYPE:-Not set}"
        if [ "$NOTIFY_TYPE" = "telegram" ]; then
            if [ -n "$TG_BOT_TOKEN" ]; then
                token_prefix=$(echo $TG_BOT_TOKEN | cut -d':' -f1)
                token_masked="$token_prefix:****"
                echo -e "${CYAN}Telegram Bot Token:${NC} $token_masked"
            else
                echo -e "${CYAN}Telegram Bot Token:${NC} ${RED}Not set${NC}"
            fi
            echo -e "${CYAN}Telegram Chat IDs:${NC} ${TG_CHAT_IDS:-Not set}"
        else
            if [ -n "$DINGTALK_WEBHOOK" ]; then
                webhook_masked=$(echo "$DINGTALK_WEBHOOK" | cut -c1-10)****
                echo -e "${CYAN}DingTalk Webhook:${NC} $webhook_masked"
            else
                echo -e "${CYAN}DingTalk Webhook:${NC} ${RED}Not set${NC}"
            fi
        fi
        echo -e "${CYAN}Monitor Interval:${NC} ${INTERVAL:-60} seconds"
        echo -e "${CYAN}Offline Threshold:${NC} ${OFFLINE_THRESHOLD:-3} times"
        echo -e "${CYAN}Host List:${NC}"
        if [ -n "$HOSTS_LIST" ]; then
            local HOSTS=$(echo "$HOSTS_LIST" | tr ',' ' ')
            local REMARKS="$REMARKS_LIST"
            i=1
            for host in $HOSTS; do
                remark=$(echo "$REMARKS" | cut -d',' -f$i)
                echo -e "  $i. $host ($remark)"
                i=$((i+1))
            done
        else
            echo -e "${RED}No hosts configured${NC}"
        fi
    else
        echo -e "${RED}Configuration file not found, please install the script first${NC}"
    fi
    echo ""
}

# View log function
view_log() {
    print_menu_header
    echo -e "${CYAN}[View Log]${NC} Showing last 20 lines of /var/log/pingX_monitor.log:\n"
    if [ -f "$LOG_FILE" ]; then
        tail -n 20 "$LOG_FILE"
    else
        echo -e "${RED}Log file does not exist${NC}"
    fi
    echo ""
    read -p "Press Enter to continue..."
}

# Install script
install_script() {
    print_menu_header
    echo -e "${CYAN}[Install] ${GREEN}Starting PingX Monitor installation...${NC}"
    echo ""

    check_dependencies

    echo -e "${CYAN}[1/5]${NC} Select notification type:"
    echo -e "${CYAN}1.${NC} Telegram"
    echo -e "${CYAN}2.${NC} DingTalk"
    read -p "Choose [1-2]: " notify_choice
    case $notify_choice in
        1) NOTIFY_TYPE="telegram" ;;
        2) NOTIFY_TYPE="dingtalk" ;;
        *) echo -e "${RED}Invalid choice, defaulting to Telegram${NC}"; NOTIFY_TYPE="telegram" ;;
    esac

    if [ "$NOTIFY_TYPE" = "telegram" ]; then
        echo -e "\n${CYAN}[2/5]${NC} Enter Telegram Bot Token:"
        read -p "Token (e.g., 123456789:ABCDEF...): " TG_BOT_TOKEN
        echo -e "\n${CYAN}[3/5]${NC} Enter Telegram Chat ID (multiple IDs separated by commas):"
        read -p "Chat ID(s): " TG_CHAT_IDS
        if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_IDS" ]; then
            validate_telegram && echo -e "${GREEN}Token valid${NC}" || echo -e "${RED}Token invalid, check log${NC}"
        fi
        DINGTALK_WEBHOOK=""
    else
        echo -e "\n${CYAN}[2/5]${NC} Enter DingTalk Webhook URL:"
        read -p "Webhook: " DINGTALK_WEBHOOK
        if [ -n "$DINGTALK_WEBHOOK" ]; then
            validate_dingtalk "$DINGTALK_WEBHOOK"
        fi
        TG_BOT_TOKEN=""
        TG_CHAT_IDS=""
    fi

    echo -e "\n${CYAN}[3/5]${NC} Enter IPs or domains to monitor (one per line, empty line to finish):"
    echo -e "${YELLOW}Example: 192.168.1.1 or example.com${NC}"
    HOSTS_LIST=""
    REMARKS_LIST=""
    while true; do
        read -p "IP or domain (empty to finish): " host
        if [ -z "$host" ]; then
            if [ -z "$HOSTS_LIST" ]; then
                echo -e "${YELLOW}Warning: No hosts added${NC}"
            fi
            break
        fi
        if ! validate_host "$host"; then
            echo -e "${RED}Error: $host is not a valid IP or domain${NC}"
            continue
        fi
        read -p "Enter remark for $host: " remark
        if [ -z "$remark" ]; then
            echo -e "${RED}Error: Remark cannot be empty${NC}"
            continue
        fi
        [ -n "$HOSTS_LIST" ] && HOSTS_LIST="$HOSTS_LIST,"
        [ -n "$REMARKS_LIST" ] && REMARKS_LIST="$REMARKS_LIST,"
        HOSTS_LIST="$HOSTS_LIST$host"
        REMARKS_LIST="$REMARKS_LIST$remark"
        echo -e "${GREEN}Added: $host ($remark)${NC}"
    done

    echo -e "\n${CYAN}[4/5]${NC} Enter monitor interval (seconds, default 60):"
    read -p "Interval: " INTERVAL
    INTERVAL=${INTERVAL:-60}
    echo -e "\n${CYAN}[5/5]${NC} Enter offline threshold (consecutive failures, default 3):"
    read -p "Threshold: " OFFLINE_THRESHOLD
    OFFLINE_THRESHOLD=${OFFLINE_THRESHOLD:-3}

    save_config

    mkdir -p /usr/local/bin
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"

    if ! grep -q "pingX_monitor.sh monitor" "$CRONTAB_PATH"; then
        echo "$CRON_JOB" >> "$CRONTAB_PATH"
        if [ -f /etc/openwrt_release ]; then
            /etc/init.d/cron restart >/dev/null 2>&1
        fi
    fi

    rm -f "$STATE_FILE"
    log "Cleared state file during installation"

    echo -e "\n${GREEN}✅ Installation complete!${NC}"
    echo -e "${YELLOW}Tip: Use the menu to test notifications${NC}"
    log "Installation completed"
    sleep 2
}

# Uninstall script
uninstall_script() {
    print_menu_header
    echo -e "${CYAN}[Uninstall] ${YELLOW}Uninstalling PingX Monitor...${NC}\n"

    sed -i '/pingX_monitor.sh monitor/d' "$CRONTAB_PATH"
    if [ -f /etc/openwrt_release ]; then
        /etc/init.d/cron restart >/dev/null 2>&1
    fi
    rm -f "$SCRIPT_PATH" "$CONFIG_FILE" "$STATE_FILE" "$LOCK_FILE"
    rm -f "$LOG_FILE" "${LOG_FILE}".*
    rmdir /var/log 2>/dev/null || true

    echo -e "\n${GREEN}✅ Uninstallation complete!${NC}"
    echo -e "${YELLOW}All configuration files and scripts removed${NC}"
    log "Uninstallation completed"
    sleep 2
    exit 0
}

# Test notifications
test_notifications() {
    load_config
    while true; do
        print_menu_header
        echo -e "${CYAN}[Test Notifications]${NC} Select notification type to test:\n"
        echo -e "${CYAN}1.${NC} Test offline notification"
        echo -e "${CYAN}2.${NC} Test online notification"
        echo -e "${CYAN}0.${NC} Return to main menu"
        echo ""
        read -p "Choose [0-2]: " choice

        case $choice in
            1)
                echo -e "\n${YELLOW}Sending offline notification...${NC}"
                local test_host="192.168.1.100"
                local test_remark="Test Host"
                local time=$(date '+%Y-%m-%d %H:%M:%S')
                local message="🛑 *Host Offline Notification*\n\n📍 *Host*: $test_host\n📝 *Remark*: $test_remark\n🕒 *Time*: $time\n⚠️ *Consecutive Failures*: ${OFFLINE_THRESHOLD}"
                send_notification "$message" && echo -e "\n${GREEN}Notification sent, check your channel${NC}" || echo -e "\n${RED}Notification failed, check log${NC}"
                read -p "Press Enter to continue..."
                ;;
            2)
                echo -e "\n${YELLOW}Sending online notification...${NC}"
                local test_host="192.168.1.100"
                local test_remark="Test Host"
                local time=$(date '+%Y-%m-%d %H:%M:%S')
                local message="✅ *Host Online Notification*\n\n📍 *Host*: $test_host\n📝 *Remark*: $test_remark\n🕒 *Time*: $time"
                send_notification "$message" && echo -e "\n${GREEN}Notification sent, check your channel${NC}" || echo -e "\n${RED}Notification failed, check log${NC}"
                read -p "Press Enter to continue..."
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}Invalid choice, try again${NC}"
                sleep 1
                ;;
        esac
    done
}

# Modify configuration
modify_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Error: Configuration file not found, please install script first${NC}"
        sleep 2
        return
    fi

    load_config
    while true; do
        print_menu_header
        echo -e "${CYAN}[Configuration Settings]${NC}\n"
        show_config

        echo -e "Select configuration to modify:"
        echo -e "${CYAN}1.${NC} List current configuration"
        echo -e "${CYAN}2.${NC} Change notification type"
        echo -e "${CYAN}3.${NC} Modify Telegram configuration"
        echo -e "${CYAN}4.${NC} Modify DingTalk Webhook"
        echo -e "${CYAN}5.${NC} Modify host list and remarks"
        echo -e "${CYAN}6.${NC} Modify monitor interval"
        echo -e "${CYAN}7.${NC} Modify offline threshold"
        echo -e "${CYAN}0.${NC} Return to main menu"
        echo ""
        read -p "Choose [0-7]: " choice

        case $choice in
            1)
                echo -e "\n${CYAN}Current Configuration:${NC}"
                show_config
                read -p "Press Enter to continue..."
                ;;
            2)
                echo -e "\n${CYAN}Select new notification type:${NC}"
                echo -e "${CYAN}1.${NC} Telegram"
                echo -e "${CYAN}2.${NC} DingTalk"
                read -p "Choose [1-2]: " notify_choice
                case $notify_choice in
                    1)
                        NOTIFY_TYPE="telegram"
                        sed -i "s/NOTIFY_TYPE=.*/NOTIFY_TYPE=\"telegram\"/" "$CONFIG_FILE"
                        echo -e "${GREEN}Notification type set to Telegram${NC}"
                        log "Notification type set to telegram"
                        ;;
                    2)
                        NOTIFY_TYPE="dingtalk"
                        sed -i "s/NOTIFY_TYPE=.*/NOTIFY_TYPE=\"dingtalk\"/" "$CONFIG_FILE"
                        echo -e "${GREEN}Notification type set to DingTalk${NC}"
                        log "Notification type set to dingtalk"
                        ;;
                    *)
                        echo -e "${RED}Invalid choice, notification type unchanged${NC}"
                        ;;
                esac
                ;;
            3)
                if [ "$NOTIFY_TYPE" != "telegram" ]; then
                    echo -e "${RED}Current notification type is not Telegram, please switch first${NC}"
                    sleep 2
                    continue
                fi
                echo -e "\n${YELLOW}Enter new Telegram Bot Token:${NC}"
                read -p "Token: " new_token
                if [ -n "$new_token" ]; then
                    sed -i "s/TG_BOT_TOKEN=.*/TG_BOT_TOKEN=\"$new_token\"/" "$CONFIG_FILE"
                    TG_BOT_TOKEN="$new_token"
                    validate_telegram && echo -e "${GREEN}Telegram Token updated and valid${NC}" || echo -e "${RED}Telegram Token invalid${NC}"
                    log "Telegram Bot Token updated"
                fi
                echo -e "\n${YELLOW}Enter new Telegram Chat ID(s) (comma-separated):${NC}"
                read -p "Chat ID(s): " new_ids
                if [ -n "$new_ids" ]; then
                    sed -i "s/TG_CHAT_IDS=.*/TG_CHAT_IDS=\"$new_ids\"/" "$CONFIG_FILE"
                    echo -e "${GREEN}Telegram Chat IDs updated${NC}"
                    log "Telegram Chat IDs updated: $new_ids"
                fi
                ;;
            4)
                if [ "$NOTIFY_TYPE" != "dingtalk" ]; then
                    echo -e "${RED}Current notification type is not DingTalk, please switch first${NC}"
                    sleep 2
                    continue
                fi
                echo -e "\n${YELLOW}Enter new DingTalk Webhook URL:${NC}"
                read -p "Webhook: " new_webhook
                if [ -n "$new_webhook" ]; then
                    validate_dingtalk "$new_webhook"
                    sed -i "s|DINGTALK_WEBHOOK=.*|DINGTALK_WEBHOOK=\"$new_webhook\"|" "$CONFIG_FILE"
                    echo -e "${GREEN}DingTalk Webhook updated${NC}"
                    log "DingTalk Webhook updated"
                fi
                ;;
            5)
                echo -e "\n${CYAN}Current Host List:${NC}"
                if [ -n "$HOSTS_LIST" ]; then
                    local HOSTS=$(echo "$HOSTS_LIST" | tr ',' ' ')
                    local REMARKS="$REMARKS_LIST"
                    i=1
                    for host in $HOSTS; do
                        remark=$(echo "$REMARKS" | cut -d',' -f$i)
                        echo -e "  $i. $host ($remark)"
                        i=$((i+1))
                    done
                else
                    echo -e "${RED}No hosts configured${NC}"
                fi
                echo ""
                echo -e "${CYAN}Host Management:${NC}"
                echo -e "${CYAN}1.${NC} Add host"
                echo -e "${CYAN}2.${NC} Delete host"
                echo -e "${CYAN}0.${NC} Save and return"
                read -p "Choose [0-2]: " host_choice
                case $host_choice in
                    1)
                        echo -e "\n${YELLOW}Enter new IP or domain:${NC}"
                        read -p "IP or domain: " host
                        if [ -n "$host" ] && validate_host "$host"; then
                            read -p "Enter remark for $host: " remark
                            if [ -n "$remark" ]; then
                                [ -n "$HOSTS_LIST" ] && HOSTS_LIST="$HOSTS_LIST,"
                                [ -n "$REMARKS_LIST" ] && REMARKS_LIST="$REMARKS_LIST,"
                                HOSTS_LIST="$HOSTS_LIST$host"
                                REMARKS_LIST="$REMARKS_LIST$remark"
                                echo -e "${GREEN}Added: $host ($remark)${NC}"
                            else
                                echo -e "${RED}Error: Remark cannot be empty${NC}"
                            fi
                        else
                            echo -e "${RED}Error: Invalid IP or domain${NC}"
                        fi
                        ;;
                    2)
                        if [ -z "$HOSTS_LIST" ]; then
                            echo -e "${RED}Error: Host list is empty${NC}"
                            sleep 2
                            continue
                        fi
                        echo -e "\n${YELLOW}Enter host number to delete:${NC}"
                        local HOSTS=$(echo "$HOSTS_LIST" | tr ',' ' ')
                        local REMARKS="$REMARKS_LIST"
                        i=1
                        for host in $HOSTS; do
                            i=$((i+1))
                        done
                        read -p "Number (1-$((i-1))): " delete_index
                        if echo "$delete_index" | grep -q -v '^[0-9]\+$' || [ "$delete_index" -lt 1 ] || [ "$delete_index" -gt $((i-1)) ]; then
                            echo -e "${RED}Error: Invalid number, enter 1 to $((i-1))${NC}"
                            sleep 2
                            continue
                        fi
                        new_hosts=""
                        new_remarks=""
                        j=1
                        for host in $HOSTS; do
                            remark=$(echo "$REMARKS" | cut -d',' -f$j)
                            if [ "$j" -ne "$delete_index" ]; then
                                [ -n "$new_hosts" ] && new_hosts="$new_hosts,"
                                [ -n "$new_remarks" ] && new_remarks="$new_remarks,"
                                new_hosts="$new_hosts$host"
                                new_remarks="$new_remarks$remark"
                            fi
                            j=$((j+1))
                        done
                        HOSTS_LIST="$new_hosts"
                        REMARKS_LIST="$new_remarks"
                        echo -e "${GREEN}Host deleted${NC}"
                        log "Deleted host: index $delete_index"
                        ;;
                    0)
                        sed -i "s/HOSTS_LIST=.*/HOSTS_LIST=\"$HOSTS_LIST\"/" "$CONFIG_FILE"
                        sed -i "s/REMARKS_LIST=.*/REMARKS_LIST=\"$REMARKS_LIST\"/" "$CONFIG_FILE"
                        echo -e "${GREEN}Host list and remarks updated${NC}"
                        log "Host list and remarks updated"
                        break
                        ;;
                    *)
                        echo -e "${RED}Invalid choice, try again${NC}"
                        sleep 1
                        ;;
                esac
                ;;
            6)
                echo -e "\n${YELLOW}Enter new monitor interval (seconds):${NC}"
                read -p "Interval (default 60): " new_interval
                new_interval=${new_interval:-60}
                sed -i "s/INTERVAL=.*/INTERVAL=\"$new_interval\"/" "$CONFIG_FILE"
                echo -e "${GREEN}Monitor interval updated to ${new_interval} seconds${NC}"
                log "Interval updated to $new_interval seconds"
                ;;
            7)
                echo -e "\n${YELLOW}Enter new offline threshold (consecutive failures):${NC}"
                read -p "Threshold (default 3): " new_threshold
                new_threshold=${new_threshold:-3}
                sed -i "s/OFFLINE_THRESHOLD=.*/OFFLINE_THRESHOLD=\"$new_threshold\"/" "$CONFIG_FILE"
                echo -e "${GREEN}Offline threshold updated to ${new_threshold} times${NC}"
                log "Offline threshold updated to $new_threshold"
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}Invalid choice, try again${NC}"
                sleep 1
                ;;
        esac
        sleep 1
        load_config
    done
}

# Show usage help
show_usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  install   Install the script"
    echo "  uninstall Uninstall the script"
    echo "  monitor   Run monitoring (called by cron)"
    echo "  menu      Show interactive menu (default)"
    echo ""
}

# Main menu
show_menu() {
    while true; do
        print_menu_header
        if [ -f "$CONFIG_FILE" ]; then
            echo -e "${GREEN}● Monitor system installed${NC}\n"
            show_config
        else
            echo -e "${RED}● Monitor system not installed${NC}\n"
        fi

        echo -e "Select operation:"
        echo -e "${CYAN}1.${NC} Install/Reinstall"
        echo -e "${CYAN}2.${NC} Configuration settings"
        echo -e "${CYAN}3.${NC} Test notifications"
        echo -e "${CYAN}4.${NC} Uninstall"
        echo -e "${CYAN}5.${NC} View log"
        echo -e "${CYAN}0.${NC} Exit"
        echo ""
        read -p "Choose [0-5]: " choice

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
                echo -e "\n${YELLOW}Warning: This will delete all configurations and scripts!${NC}"
                read -p "Confirm uninstall? [y/N]: " confirm
                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                    uninstall_script
                fi
                ;;
            5)
                view_log
                ;;
            0)
                echo -e "\n${GREEN}Thank you for using PingX Monitor!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid choice, try again${NC}"
                sleep 1
                ;;
        esac
    done
}

main() {
    if [ "$1" = "menu" ] || [ -z "$1" ]; then
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
                echo -e "${RED}Error: Unknown command '$1'${NC}"
                show_usage
                exit 1
                ;;
        esac
    fi
}

main "$1"
