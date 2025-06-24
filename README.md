Server Monitoring Panel / 服务器监控面板
English Version
🚀 Overview
This Server Monitoring Panel is a lightweight and efficient solution for real-time monitoring of your server's key performance metrics. It provides an intuitive web interface to help you easily track CPU usage, memory consumption, disk space, network traffic, and server uptime.

✨ Features
Real-time Metrics: Monitor CPU, memory, disk, and network (upload/download speed and total traffic) in real-time.

Online/Offline Status: Instantly know the status of your servers with quick online/offline indicators.

Traffic Reset: Customizable monthly traffic reset day for easy bandwidth management.

Secure Server Management: Safely add and delete servers from your panel.

Ubuntu-Style UI: Clean and modern interface for a pleasant user experience.

📋 Prerequisites
Before you begin, ensure your server meets the following requirements:

Ubuntu/Debian-based OS (for install.sh compatibility)

sudo privileges

For Server (Frontend + Backend): Nginx, Node.js, npm, Certbot

For Agent: sysstat, bc

🚀 Usage / Installation
The install.sh script provides a convenient way to set up both the monitoring server (frontend + backend) and the agent on your target servers.

1. Server (Frontend + Backend) Installation
Run this command on your monitoring server:

bash <(curl -sL https://raw.githubusercontent.com/cjap111/vps-monitor-panel/main/install.sh)

Follow the prompts:

Enter your domain name (e.g., monitor.yourdomain.com).

Set a strong password for web panel server deletion.

Set a strong password for agent installation verification.

Enter your email for Certbot.

After successful installation, your monitoring panel will be accessible via the domain you provided.

2. Agent Installation
Run this command on each server you want to monitor:

curl -sL https://raw.githubusercontent.com/cjap111/vps-monitor-panel/main/install.sh | bash

Follow the prompts:

Select option 2 for "Install Agent".

Enter your backend API domain (e.g., https://monitor.yourdomain.com).

Enter the agent installation password you set during server installation.

Provide a unique ID, name, and location for the server.

The agent will start reporting data to your monitoring panel.

3. Uninstallation (Server / Agent)
To uninstall either the server or agent, run the install.sh script again and select the appropriate uninstallation option from the menu.

⚠️ Important Security & Legal Considerations
By using this software, you acknowledge and agree to the following:

"AS IS" Basis: This software is provided "AS IS," without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and non-infringement.

User Responsibility: You are solely responsible for the installation, configuration, security, and operation of this software. You assume all risks associated with its use.

Compliance with Laws: You are solely responsible for ensuring that your use of this monitoring software complies with all applicable local, national, and international laws, regulations, and privacy policies. This includes, but is not limited to, laws regarding data collection, privacy (e.g., GDPR, CCPA), cybersecurity, and unauthorized access to computer systems.

No Unauthorized Monitoring: You must obtain explicit consent from all relevant parties (e.g., system owners, users) before monitoring their systems or collecting their data. Unauthorized monitoring or data collection may have serious legal consequences.

No Malicious Use: This software is intended for legitimate system administration and monitoring purposes only. It must not be used for any illegal, unethical, or malicious activities, including but not limited to hacking, unauthorized data exfiltration, or any form of cybercrime.

Data Security: While efforts have been made to provide basic security features (e.g., password protection), ensuring comprehensive data security (e.g., strong passwords, firewall rules, timely updates, secure network configurations) is your responsibility. We are not liable for any data breaches or security incidents resulting from your improper use or configuration of the software.

🤝 Contributing
Contributions are welcome! Please feel free to open issues or submit pull requests.

📄 License
This project is licensed under the MIT License - see the LICENSE file for details.

中文版
🚀 概览
本服务器监控面板是一款轻量级、高效的解决方案，用于实时监控您服务器的关键性能指标。它提供一个直观的网页界面，帮助您轻松追踪 CPU 使用率、内存占用、磁盘空间、网络流量和服务器运行时间。

✨ 功能特性
实时指标： 实时监控 CPU、内存、磁盘和网络（上传/下载速度及总流量）数据。

在线/离线状态： 即时了解服务器状态，在线/离线指示器让您快速发现异常。

流量重置： 可自定义每月流量重置日期，轻松管理带宽使用。

安全服务器管理： 安全地从面板添加和删除服务器。

Ubuntu 风格界面： 简洁、现代的界面设计，提供愉悦的用户体验。

📋 前置条件
在开始之前，请确保您的服务器满足以下要求：

基于 Ubuntu/Debian 的操作系统（为了兼容 install.sh 脚本）

sudo 权限

服务端 (前端 + 后端)： Nginx, Node.js, npm, Certbot

被控端 (Agent)： sysstat, bc

🚀 使用 / 安装
install.sh 脚本提供了一种便捷的方式来设置监控服务器（前端 + 后端）以及目标服务器上的 Agent。

1. 服务端 (前端 + 后端) 安装
在您的监控服务器上运行此命令：

curl -sL https://raw.githubusercontent.com/cjap111/vps-monitor-panel/main/install.sh | bash

按照提示操作：

输入您的域名（例如：monitor.yourdomain.com）。

为网页面板删除功能设置一个强密码。

为被控端安装验证设置一个强密码。

输入您的 Certbot 邮箱地址。

成功安装后，您的监控面板将通过您提供的域名访问。

2. 被控端 (Agent) 安装
在每台您希望监控的服务器上运行此命令：

bash <(curl -sL https://raw.githubusercontent.com/cjap111/vps-monitor-panel/main/install.sh)

按照提示操作：

选择选项 2，即“安装被控端 (Agent)”。

输入您的后端 API 域名（例如：https://monitor.yourdomain.com）。

输入您在服务端安装时设置的被控端安装密码。

为该服务器提供一个唯一的 ID、名称和位置。

Agent 将开始向您的监控面板报告数据。

3. 卸载 (服务端 / 被控端)
要卸载服务端或被控端，请再次运行 install.sh 脚本，并从菜单中选择相应的卸载选项。

⚠️ 重要安全与法律注意事项
使用本软件，即表示您已阅读、理解并同意以下条款：

“按原样”提供： 本软件按“原样”提供，不作任何明示或暗示的保证，包括但不限于适销性、特定用途适用性和不侵权的保证。

用户责任： 您全权负责本软件的安装、配置、安全和操作。您承担因使用本软件而产生的所有风险。

遵守法律： 您全权负责确保您对本监控软件的使用符合所有适用的地方、国家和国际法律、法规和隐私政策。这包括但不限于与数据收集、隐私（例如：GDPR、CCPA）、网络安全以及未经授权访问计算机系统相关的法律。

禁止未经授权的监控： 在监控他方系统或收集其数据之前，您必须获得所有相关方（例如：系统所有者、用户）的明确同意。未经授权的监控或数据收集可能导致严重的法律后果。

禁止恶意使用： 本软件仅用于合法的系统管理和监控目的。它不得用于任何非法、不道德或恶意的活动，包括但不限于黑客攻击、未经授权的数据外泄或任何形式的网络犯罪。

数据安全： 尽管已努力提供基本安全功能（例如：密码保护），但确保全面的数据安全（例如：强密码、防火墙规则、及时更新、安全的网络配置）是您的责任。对于因您不当使用或配置本软件而导致的任何数据泄露或安全事件，我们概不负责。

🤝 贡献
欢迎贡献！请随时提出问题或提交拉取请求。

📄 许可证
本项目采用 MIT 许可证 - 详情请参阅 LICENSE 文件。
