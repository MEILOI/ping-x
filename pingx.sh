#!/bin/bash

# 检查是否提供了主机地址参数
if [ "$#" -lt 1 ]; then
    echo "使用方法: $0 <主机地址1> [<主机地址2> ... <主机地址N>]"
    exit 1
fi

# 提取主机地址列表
HOSTS="$@"
# 设置 ping 的时间间隔（秒）
INTERVAL=60
# 日志文件路径
LOG_FILE="ping_log.txt"
# 最大日志文件大小（字节）
MAX_LOG_SIZE=1048576  # 1MB

# 创建或清空日志文件
> "$LOG_FILE"

while true
do
    # 获取当前时间
    CURRENT_TIME=$(date +"%Y-%m-%d %H:%M:%S")

    for HOST in $HOSTS
    do
        # 执行 ping 命令并提取响应时间
        PING_RESULT=$(ping -c 1 "$HOST" 2>&1)
        
        # 检查 ping 命令是否成功
        if echo "$PING_RESULT" | grep -q "1 packets transmitted, 1 packets received"; then
            # 提取响应时间
            RESPONSE_TIME=$(echo "$PING_RESULT" | grep "time=" | awk -F"time=" '{print $2}' | awk '{print $1}')
            STATUS="Ping successful, response time: ${RESPONSE_TIME}ms"
        else
            STATUS="Ping failed"
        fi

        # 记录到日志文件并显示在控制台
        LOG_ENTRY="$CURRENT_TIME - $HOST - $STATUS"
        echo "$LOG_ENTRY"
        echo "$LOG_ENTRY" >> "$LOG_FILE"
    done

    # 检查日志文件大小并截断文件
    LOG_SIZE=$(stat -c%s "$LOG_FILE")
    if [ "$LOG_SIZE" -ge "$MAX_LOG_SIZE" ]; then
        echo "Log file size limit reached, truncating log file."
        > "$LOG_FILE"
    fi

    # 等待指定的时间间隔
    sleep "$INTERVAL"
done
