# PingX Monitor 🚀

🌟 **PingX Monitor** 是一个轻量级、强大的主机监控工具，专为实时检测服务器或设备的在线状态而设计！通过 Ping 检查，支持 IP 和域名，自动发送离线/上线通知到 Telegram 或钉钉，让你随时掌握设备状态！📡

**English**: *PingX Monitor* is a lightweight, powerful host monitoring tool designed for real-time detection of server or device online status! It supports both IP and domain pings, automatically sending offline/online notifications to Telegram or DingTalk, keeping you in control of your devices! 📡

---

## 🎯 功能亮点 | Features

- 🖥️ **多主机监控**: 支持同时监控多个 IP 或域名，动态 IP 的 VPS 也能轻松应对！  
  *Monitor multiple hosts*: Supports simultaneous monitoring of multiple IPs or domains, easily handling dynamic IPs for VPS!
- 📩 **即时通知**: 主机离线/上线时，通过 Telegram 或钉钉发送 Markdown 格式通知，清晰直观！  
  *Instant notifications*: Sends Markdown-formatted notifications via Telegram or DingTalk when hosts go offline/online, clear and intuitive!
- 🔄 **状态持久化**: 失败计数和主机状态保存在文件中，重启不丢失，稳定可靠！  
  *State persistence*: Failure counts and host status are saved to a file, ensuring reliability across restarts!
- 🔒 **并发控制**: 使用 `flock` 防止脚本并发运行，保证状态一致性！  
  *Concurrency control*: Uses `flock` to prevent concurrent script execution, ensuring state consistency!
- 📜 **详细日志**: 自动记录 Ping 结果和通知状态，支持日志轮转，调试更方便！  
  *Detailed logging*: Automatically records Ping results and notification status, with log rotation for easier debugging!
- 🛠️ **交互式菜单**: 提供安装、配置、测试通知、查看日志等功能，操作简单！  
  *Interactive menu*: Offers installation, configuration, notification testing, and log viewing, making operations a breeze!
- 🌐 **开源免费**: MIT 许可，欢迎贡献和定制！  
  *Open-source & free*: MIT license, contributions and customizations are welcome!

---

## 📦 快速开始 | Quick Start

### 一键安装 | One-Click Installation

在 Linux 系统中运行以下命令，快速部署 PingX Monitor！🎉

```bash
wget https://raw.githubusercontent.com/MEILOI/ping-x/main/pingX_monitor.sh -O pingX_monitor.sh && chmod +x pingX_monitor.sh && sudo ./pingX_monitor.sh
```

**English**: Run the following command in a Linux system to quickly deploy PingX Monitor! 🎉

```bash
wget https://raw.githubusercontent.com/MEILOI/ping-x/main/pingX_monitor.sh -O pingX_monitor.sh && chmod +x pingX_monitor.sh && sudo ./pingX_monitor.sh
```

### 安装步骤 | Installation Steps

1. **下载脚本 | Download the Script**:
   ```bash
   wget https://raw.githubusercontent.com/MEILOI/ping-x/main/pingX_monitor.sh -O pingX_monitor.sh
   ```
2. **赋予执行权限 | Make it Executable**:
   ```bash
   chmod +x pingX_monitor.sh
   ```
3. **运行安装 | Run Installation**:
   ```bash
   sudo ./pingX_monitor.sh
   ```
4. **配置 | Configure**:
   - 选择通知方式（Telegram 或钉钉）📩
   - 输入 Telegram Bot Token 和 Chat ID 或钉钉 Webhook
   - 添加要监控的 IP 或域名（如 `192.168.3.3` 或 `example.com`）🌐
   - 设置监控间隔（默认 60 秒）和离线阈值（默认 3 次）⏲️
5. **验证 | Verify**:
   - 使用菜单选项 3 测试通知，确保 Telegram/钉钉收到消息 ✅
   - 使用选项 5 查看日志，确认监控运行 📜

**English**:
1. *Download the Script*:
   ```bash
   wget https://raw.githubusercontent.com/MEILOI/ping-x/main/pingX_monitor.sh -O pingX_monitor.sh
   ```
2. *Make it Executable*:
   ```bash
   chmod +x pingX_monitor.sh
   ```
3. *Run Installation*:
   ```bash
   sudo ./pingX_monitor.sh
   ```
4. *Configure*:
   - Choose notification method (Telegram or DingTalk) 📩
   - Enter Telegram Bot Token and Chat ID or DingTalk Webhook
   - Add IPs or domains to monitor (e.g., `192.168.3.3` or `example.com`) 🌐
   - Set monitoring interval (default 60s) and offline threshold (default 3) ⏲️
5. *Verify*:
   - Use menu option 3 to test notifications, ensuring messages are received ✅
   - Use option 5 to view logs, confirming monitoring is running 📜

---

## 🛠️ 使用说明 | Usage

运行脚本，进入交互式菜单：

```bash
sudo /usr/local/bin/pingX_monitor.sh
```

### 菜单选项 | Menu Options

- **1. 安装/重新安装**: 安装或更新脚本和配置 🚀  
  *Install/Reinstall*: Install or update the script and configuration
- **2. 配置设置**: 修改通知方式、主机列表、间隔等 ⚙️  
  *Configure Settings*: Modify notification method, host list, interval, etc.
- **3. 测试通知**: 发送测试离线/上线通知，验证配置 📩  
  *Test Notifications*: Send test offline/online notifications to verify setup
- **4. 卸载**: 移除脚本和所有配置文件 🗑️  
  *Uninstall*: Remove the script and all configuration files
- **5. 查看日志**: 显示最近 20 行日志，便于调试 📜  
  *View Logs*: Display the last 20 log lines for debugging
- **0. 退出**: 退出菜单 👋  
  *Exit*: Quit the menu

### 示例配置 | Example Configuration

```bash
# /etc/pingX_monitor.conf
NOTIFY_TYPE="telegram"
TG_BOT_TOKEN="987654321:****"
TG_CHAT_IDS="123456789"
HOSTS_LIST="192.168.3.3,example.com"
REMARKS_LIST="ServerX,TestServer"
INTERVAL="5"
OFFLINE_THRESHOLD="2"
```

**通知示例 | Notification Example**:

```
🛑 *主机离线通知*
📍 *主机*: example.com
📝 *备注*: TestServer
🕒 *时间*: 2025-05-23 14:15:10
⚠️ *连续失败*: 2次
```

---

## 🐛 调试与故障排除 | Debugging & Troubleshooting

如果遇到问题，请按照以下步骤排查：

1. **检查日志 | Check Logs**:
   ```bash
   tail -n 50 /var/log/pingX_monitor.log
   ```
   查找 `Ping attempt`、`Failure count` 或 `Telegram notification sent`。

2. **测试域名/IP | Test Domain/IP**:
   ```bash
   ping -c 1 example.com
   ```

3. **验证 Telegram | Verify Telegram**:
   ```bash
   curl -s "https://api.telegram.org/bot<YOUR_TOKEN>/getMe"
   curl -s -X POST "https://api.telegram.org/bot<YOUR_TOKEN>/sendMessage" -d "chat_id=<YOUR_CHAT_ID>&text=Test"
   ```

4. **检查 Crontab | Check Crontab**:
   ```bash
   cat /etc/crontab
   ```
   确保包含：
   ```bash
   */1 * * * * root /usr/local/bin/pingX_monitor.sh monitor >> /var/log/pingX_monitor.log 2>&1
   ```

**English**:
1. *Check Logs*:
   ```bash
   tail -n 50 /var/log/pingX_monitor.log
   ```
   Look for `Ping attempt`, `Failure count`, or `Telegram notification sent`.
2. *Test Domain/IP*:
   ```bash
   ping -c 1 example.com
   ```
3. *Verify Telegram*:
   ```bash
   curl -s "https://api.telegram.org/bot<YOUR_TOKEN>/getMe"
   curl -s -X POST "https://api.telegram.org/bot<YOUR_TOKEN>/sendMessage" -d "chat_id=<YOUR_CHAT_ID>&text=Test"
   ```
4. *Check Crontab*:
   ```bash
   cat /etc/crontab
   ```
   Ensure it includes:
   ```bash
   */1 * * * * root /usr/local/bin/pingX_monitor.sh monitor >> /var/log/pingX_monitor.log 2>&1
   ```

---

## 🤝 贡献 | Contributing

欢迎为 PingX Monitor 贡献代码或建议！💡

1. Fork 本仓库
2. 创建你的功能分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送分支 (`git push origin feature/AmazingFeature`)
5. 提交 Pull Request

**English**:
We welcome contributions to PingX Monitor! 💡
1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

---

## 📜 许可证 | License

本项目采用 [MIT 许可证](LICENSE) 开源，自由使用和修改！📖

**English**: This project is licensed under the [MIT License](LICENSE), free to use and modify! 📖

---

## 📬 联系 | Contact

- **作者 | Author**: TheX
- **GitHub**: [https://github.com/MEILOI/ping-x](https://github.com/MEILOI/ping-x)
- **问题反馈 | Issues**: [提交 Issue](https://github.com/MEILOI/ping-x/issues)

💌 感谢使用 PingX Monitor！让我们一起让监控更简单、更高效！🚀

**English**:
- *Author*: TheX
- *GitHub*: [https://github.com/MEILOI/ping-x](https://github.com/MEILOI/ping-x)
- *Issues*: [Submit an Issue](https://github.com/MEILOI/ping-x/issues)

💌 Thank you for using PingX Monitor! Let’s make monitoring simpler and more efficient together! 🚀
