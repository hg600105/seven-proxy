#!/bin/bash
# seven-proxy-daemon.sh - Seven Proxy 守护进程管理脚本

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 路径定义
WORKDIR="$HOME/.seven-proxy"
BIN_DIR="$WORKDIR/bin"
CONFIG_DIR="$WORKDIR/config"
LOG_DIR="$WORKDIR/logs"
PID_DIR="$WORKDIR/pid"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 软件版本
SINGBOX_VERSION="1.8.11"
CLOUDFLARED_VERSION="latest"

# 初始化目录
init_dirs() {
    mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$LOG_DIR" "$PID_DIR"
}

# 检查架构
check_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l) echo "arm" ;;
        *) echo "unsupported" ;;
    esac
}

# 检查依赖
check_dependencies() {
    echo -e "${CYAN}检查系统依赖...${NC}"
    
    local missing=()
    for cmd in curl wget tar; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}需要安装: ${missing[*]}${NC}"
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update
            sudo apt-get install -y "${missing[@]}"
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y "${missing[@]}"
        fi
    fi
    echo -e "${GREEN}依赖检查完成${NC}"
}

# 下载二进制文件
download_binary() {
    local name=$1
    local url=$2
    local output="$BIN_DIR/$name"
    
    if [ -f "$output" ]; then
        echo -e "${GREEN}$name 已存在${NC}"
        return
    fi
    
    echo -e "${CYAN}下载 $name...${NC}"
    echo "URL: $url"
    
    if [[ "$url" == *.tar.gz ]] || [[ "$url" == *.tgz ]]; then
        # 压缩包格式
        local temp_dir="/tmp/${name}_$$"
        mkdir -p "$temp_dir"
        curl -L -o "/tmp/${name}.tar.gz" "$url"
        tar -xzf "/tmp/${name}.tar.gz" -C "$temp_dir"
        find "$temp_dir" -name "$name" -type f -executable | head -1 | xargs -I {} cp {} "$output"
        chmod +x "$output"
        rm -rf "$temp_dir" "/tmp/${name}.tar.gz"
    else
        # 直接二进制文件
        curl -L -o "$output" "$url"
        chmod +x "$output"
    fi
    
    if [ -f "$output" ]; then
        echo -e "${GREEN}$name 下载完成${NC}"
    else
        echo -e "${RED}$name 下载失败${NC}"
        return 1
    fi
}

# 检查服务状态
check_service() {
    local service=$1
    local pid_file="$PID_DIR/$service.pid"
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if ps -p "$pid" >/dev/null 2>&1; then
            echo "running"
        else
            echo "dead"
        fi
    else
        echo "stopped"
    fi
}

# 启动服务
start_service() {
    local service=$1
    shift
    local cmd="$@"
    local pid_file="$PID_DIR/$service.pid"
    local log_file="$LOG_DIR/$service.log"
    
    # 检查是否已在运行
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if ps -p "$pid" >/dev/null 2>&1; then
            echo -e "${YELLOW}$service 已在运行 (PID: $pid)${NC}"
            return 0
        fi
    fi
    
    echo -e "${CYAN}启动 $service...${NC}"
    
    # 使用 nohup 在后台运行
    nohup $cmd > "$log_file" 2>&1 &
    local pid=$!
    
    # 等待确认启动
    sleep 2
    if ps -p "$pid" >/dev/null 2>&1; then
        echo "$pid" > "$pid_file"
        echo -e "${GREEN}$service 启动成功 (PID: $pid)${NC}"
        return 0
    else
        echo -e "${RED}$service 启动失败${NC}"
        echo -e "${YELLOW}查看日志: $log_file${NC}"
        return 1
    fi
}

# 停止服务
stop_service() {
    local service=$1
    local pid_file="$PID_DIR/$service.pid"
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        echo -e "${CYAN}停止 $service (PID: $pid)...${NC}"
        
        if ps -p "$pid" >/dev/null 2>&1; then
            kill "$pid"
            sleep 1
            if ps -p "$pid" >/dev/null 2>&1; then
                kill -9 "$pid"
                sleep 1
            fi
        fi
        
        rm -f "$pid_file"
        echo -e "${GREEN}$service 已停止${NC}"
    else
        echo -e "${YELLOW}$service 未在运行${NC}"
    fi
}

# 重启服务
restart_service() {
    local service=$1
    stop_service "$service"
    sleep 1
    eval "start_$service"
}

# 生成UUID
generate_uuid() {
    if [ -f "$BIN_DIR/sing-box" ]; then
        "$BIN_DIR/sing-box" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null || {
            python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null ||
            echo "$(od -x /dev/urandom | head -1 | awk '{print $2$3$4$5$6$7$8$9}' | sed 's/../&-/g;s/-$//')"
        }
    fi
}

# 极速安装模式
fast_install() {
    echo -e "${GREEN}=== 极速安装模式 ===${NC}"
    echo -e "${YELLOW}自动配置临时隧道...${NC}"
    
    # 生成UUID
    local uuid=$(generate_uuid)
    echo -e "UUID: ${CYAN}$uuid${NC}"
    
    # 检查依赖
    check_dependencies
    
    # 下载二进制文件
    local arch=$(check_arch)
    download_binary "sing-box" "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${arch}.tar.gz"
    
    if [ "$arch" = "amd64" ]; then
        download_binary "cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
    elif [ "$arch" = "arm64" ]; then
        download_binary "cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
    else
        download_binary "cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm"
    fi
    
    # 配置sing-box
    configure_singbox "$uuid"
    
    # 启动sing-box
    start_singbox
    
    # 启动cloudflared临时隧道
    start_cloudflared_temp
    
    # 显示结果
    show_results "$uuid" "临时隧道"
}

# 引导式安装
guided_install() {
    echo -e "${GREEN}=== 引导式安装模式 ===${NC}"
    
    # UUID配置
    echo -e "\n${CYAN}UUID配置${NC}"
    echo -e "${YELLOW}是否自动生成UUID? (y/n)[y]: ${NC}\c"
    read -r auto_uuid
    auto_uuid=${auto_uuid:-y}
    
    if [[ "$auto_uuid" =~ ^[Yy]$ ]]; then
        local uuid=$(generate_uuid)
        echo -e "已生成 UUID: ${CYAN}$uuid${NC}"
    else
        echo -e "${YELLOW}请输入UUID: ${NC}\c"
        read -r uuid
        if [ -z "$uuid" ]; then
            uuid=$(generate_uuid)
            echo -e "使用自动生成的 UUID: ${CYAN}$uuid${NC}"
        fi
    fi
    
    # 隧道模式
    echo -e "\n${CYAN}隧道模式选择${NC}"
    echo "1) 临时隧道 (自动域名)"
    echo "2) 固定隧道 (自定义域名)"
    echo -e "${YELLOW}请选择[1]: ${NC}\c"
    read -r mode
    mode=${mode:-1}
    
    # 检查依赖
    check_dependencies
    
    # 下载二进制文件
    local arch=$(check_arch)
    download_binary "sing-box" "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${arch}.tar.gz"
    
    if [ "$arch" = "amd64" ]; then
        download_binary "cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
    elif [ "$arch" = "arm64" ]; then
        download_binary "cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
    else
        download_binary "cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm"
    fi
    
    # 配置sing-box
    configure_singbox "$uuid"
    
    # 启动sing-box
    start_singbox
    
    if [ "$mode" = "1" ]; then
        # 临时隧道
        echo -e "${GREEN}使用临时隧道模式${NC}"
        start_cloudflared_temp
        show_results "$uuid" "临时隧道"
    else
        # 固定隧道
        echo -e "\n${CYAN}固定隧道配置${NC}"
        echo -e "${YELLOW}请输入 Cloudflare Token: ${NC}"
        echo -e "${BLUE}(在 Cloudflare Zero Trust -> Access -> Tunnels 创建)${NC}"
        echo -e "${YELLOW}Token: ${NC}\c"
        read -r token
        
        echo -e "\n${YELLOW}请输入域名 (如: tunnel.example.com): ${NC}\c"
        read -r domain
        
        if [ -z "$token" ] || [ -z "$domain" ]; then
            echo -e "${RED}Token 和域名都不能为空${NC}"
            exit 1
        fi
        
        # 保存token
        echo "$token" > "$CONFIG_DIR/token.txt"
        chmod 600 "$CONFIG_DIR/token.txt"
        
        # 启动固定隧道
        start_cloudflared_fixed "$token"
        
        # 显示结果
        show_results "$uuid" "$domain"
    fi
}

# 配置sing-box
configure_singbox() {
    local uuid=$1
    
    cat > "$CONFIG_DIR/seven.json" <<EOF
{
  "log": { "disabled": false, "level": "info", "timestamp": true },
  "inbounds": [
    { "type": "vless", "tag": "proxy", "listen": "::", "listen_port": 2777,
      "users": [ { "uuid": "${uuid}", "flow": "" } ],
      "transport": { "type": "ws", "path": "/${uuid}", "max_early_data": 2048, "early_data_header_name": "Sec-WebSocket-Protocol" }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
    
    echo -e "${GREEN}sing-box 配置已生成${NC}"
}

# 启动sing-box
start_singbox() {
    start_service "sing-box" "$BIN_DIR/sing-box" run -c "$CONFIG_DIR/seven.json"
}

# 启动cloudflared临时隧道
start_cloudflared_temp() {
    start_service "cloudflared" "$BIN_DIR/cloudflared" tunnel --url http://localhost:2777 --edge-ip-version auto --no-autoupdate
}

# 启动cloudflared固定隧道
start_cloudflared_fixed() {
    local token=$1
    start_service "cloudflared" "$BIN_DIR/cloudflared" tunnel --no-autoupdate run --token "$token"
}

# 显示结果
show_results() {
    local uuid=$1
    local domain=$2
    local links_file="$CONFIG_DIR/vless_links.txt"
    local path_encoded="%2F${uuid}%3Fed%3D2048"
    
    echo -e "\n${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}🎉 Seven Proxy 启动成功！${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}UUID:${NC} $uuid"
    echo -e "${CYAN}域名:${NC} $domain"
    echo -e "${CYAN}本地端口:${NC} 2777"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    
    # 等待隧道准备就绪（如果是临时隧道需要获取域名）
    if [ "$domain" = "临时隧道" ]; then
        echo -e "${YELLOW}正在获取临时隧道域名...${NC}"
        for i in {1..15}; do
            sleep 2
            local temp_domain=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' "$LOG_DIR/cloudflared.log" 2>/dev/null | head -1 | sed 's#https://##')
            if [ -n "$temp_domain" ]; then
                domain="$temp_domain"
                echo -e "${GREEN}获取到域名: $domain${NC}"
                break
            fi
            echo -n "."
        done
    fi
    
    # 生成链接
    cat > "$links_file" <<EOF
vless://${uuid}@www.visa.com.tw:443?encryption=none&security=tls&sni=${domain}&host=${domain}&fp=chrome&type=ws&path=${path_encoded}#seven_visa_tw_443
vless://${uuid}@www.visa.com.hk:2053?encryption=none&security=tls&sni=${domain}&host=${domain}&fp=chrome&type=ws&path=${path_encoded}#seven_visa_hk_2053
vless://${uuid}@www.visa.com.br:8443?encryption=none&security=tls&sni=${domain}&host=${domain}&fp=chrome&type=ws&path=${path_encoded}#seven_visa_br_8443
vless://${uuid}@www.visaeurope.ch:443?encryption=none&security=tls&sni=${domain}&host=${domain}&fp=chrome&type=ws&path=${path_encoded}#seven_visa_ch_443
vless://${uuid}@usa.visa.com:2053?encryption=none&security=tls&sni=${domain}&host=${domain}&fp=chrome&type=ws&path=${path_encoded}#seven_visa_us_2053
vless://${uuid}@icook.hk:8443?encryption=none&security=tls&sni=${domain}&host=${domain}&fp=chrome&type=ws&path=${path_encoded}#seven_icook_hk_8443
vless://${uuid}@icook.tw:443?encryption=none&security=tls&sni=${domain}&host=${domain}&fp=chrome&type=ws&path=${path_encoded}#seven_icook_tw_443
EOF
    
    echo -e "${CYAN}📋 单个节点链接:${NC}"
    echo -e "${YELLOW}────────────────────────────────────────────────────${NC}"
    cat "$links_file"
    echo -e "${YELLOW}────────────────────────────────────────────────────${NC}"
    
    echo -e "\n${CYAN}🔗 聚合链接 (一键导入):${NC}"
    echo -e "${YELLOW}────────────────────────────────────────────────────${NC}"
    base64 -w 0 "$links_file"
    echo -e "\n${YELLOW}────────────────────────────────────────────────────${NC}"
    
    echo -e "\n${GREEN}📖 使用方法:${NC}"
    echo -e "1. ${CYAN}单个节点:${NC} 从上方选择复制"
    echo -e "2. ${CYAN}全部节点:${NC} 复制聚合链接（三次点击全选）"
    echo -e "3. ${CYAN}导入:${NC} 客户端选择「从剪贴板导入」"
    echo -e "\n${YELLOW}💡 提示:${NC}"
    echo -e "- 服务将在后台持续运行"
    echo -e "- 使用 'seven status' 查看状态"
    echo -e "- 使用 'seven stop' 停止服务"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    
    # 不再tail日志，直接返回
    echo -e "\n${YELLOW}✅ 服务已启动，即将返回...${NC}"
    sleep 2
}

# 查看状态
show_status() {
    echo -e "${CYAN}=== Seven Proxy 状态 ===${NC}"
    
    # 检查sing-box
    local singbox_status=$(check_service "sing-box")
    if [ "$singbox_status" = "running" ]; then
        local pid=$(cat "$PID_DIR/sing-box.pid")
        echo -e "sing-box: ${GREEN}运行中 (PID: $pid)${NC}"
        
        # 显示配置信息
        if [ -f "$CONFIG_DIR/seven.json" ]; then
            local uuid=$(grep -o '"uuid": "[^"]*"' "$CONFIG_DIR/seven.json" | head -1 | cut -d'"' -f4)
            if [ -n "$uuid" ]; then
                echo -e "UUID: ${CYAN}$uuid${NC}"
            fi
        fi
    else
        echo -e "sing-box: ${RED}未运行${NC}"
    fi
    
    # 检查cloudflared
    local cf_status=$(check_service "cloudflared")
    if [ "$cf_status" = "running" ]; then
        local pid=$(cat "$PID_DIR/cloudflared.pid")
        echo -e "cloudflared: ${GREEN}运行中 (PID: $pid)${NC}"
        
        # 显示域名信息
        if [ -f "$CONFIG_DIR/token.txt" ]; then
            # 固定隧道
            echo -e "模式: ${CYAN}固定隧道${NC}"
            if [ -f "$CONFIG_DIR/domain.txt" ]; then
                local domain=$(cat "$CONFIG_DIR/domain.txt")
                echo -e "域名: ${CYAN}$domain${NC}"
            fi
        else
            # 临时隧道，尝试获取域名
            local domain=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' "$LOG_DIR/cloudflared.log" 2>/dev/null | head -1 | sed 's#https://##')
            if [ -n "$domain" ]; then
                echo -e "模式: ${CYAN}临时隧道${NC}"
                echo -e "域名: ${CYAN}$domain${NC}"
            else
                echo -e "模式: ${CYAN}临时隧道${NC}"
                echo -e "域名: ${YELLOW}获取中...${NC}"
            fi
        fi
    else
        echo -e "cloudflared: ${RED}未运行${NC}"
    fi
    
    # 显示端口占用
    echo -e "\n${CYAN}端口状态:${NC}"
    if netstat -tuln | grep -q ":2777 "; then
        echo -e "2777端口: ${GREEN}已监听${NC}"
    else
        echo -e "2777端口: ${RED}未监听${NC}"
    fi
    
    # 显示日志大小
    echo -e "\n${CYAN}日志信息:${NC}"
    for log in "$LOG_DIR"/*.log; do
        if [ -f "$log" ]; then
            local size=$(du -h "$log" | cut -f1)
            echo -e "$(basename "$log"): ${size}"
        fi
    done
}

# 查看日志
view_logs() {
    local service=$1
    
    if [ -z "$service" ]; then
        echo -e "${CYAN}=== 日志查看 ===${NC}"
        echo "1) sing-box 日志"
        echo "2) cloudflared 日志"
        echo "3) 实时查看所有日志"
        echo -e "${YELLOW}请选择[1]: ${NC}\c"
        read -r choice
        choice=${choice:-1}
        
        case $choice in
            1) service="sing-box" ;;
            2) service="cloudflared" ;;
            3) 
                echo -e "${YELLOW}实时日志 (Ctrl+C退出)...${NC}"
                tail -f "$LOG_DIR/sing-box.log" "$LOG_DIR/cloudflared.log"
                return
                ;;
        esac
    fi
    
    local log_file="$LOG_DIR/$service.log"
    if [ -f "$log_file" ]; then
        echo -e "${CYAN}=== $service 日志 ===${NC}"
        echo -e "${YELLOW}最后50行 (Ctrl+C退出):${NC}"
        tail -50 "$log_file"
    else
        echo -e "${RED}日志文件不存在: $log_file${NC}"
    fi
}

# 停止所有服务
stop_all() {
    echo -e "${CYAN}=== 停止服务 ===${NC}"
    stop_service "cloudflared"
    stop_service "sing-box"
    echo -e "${GREEN}所有服务已停止${NC}"
}

# 重启所有服务
restart_all() {
    echo -e "${CYAN}=== 重启服务 ===${NC}"
    
    # 读取现有配置
    if [ ! -f "$CONFIG_DIR/seven.json" ]; then
        echo -e "${RED}配置文件不存在，请先安装${NC}"
        return 1
    fi
    
    local uuid=$(grep -o '"uuid": "[^"]*"' "$CONFIG_DIR/seven.json" | head -1 | cut -d'"' -f4)
    if [ -z "$uuid" ]; then
        echo -e "${RED}无法读取UUID配置${NC}"
        return 1
    fi
    
    stop_all
    sleep 2
    
    start_singbox
    sleep 1
    
    # 判断隧道类型
    if [ -f "$CONFIG_DIR/token.txt" ]; then
        # 固定隧道
        local token=$(cat "$CONFIG_DIR/token.txt")
        start_cloudflared_fixed "$token"
    else
        # 临时隧道
        start_cloudflared_temp
    fi
    
    echo -e "${GREEN}服务已重启${NC}"
}

# 一键卸载
uninstall_all() {
    echo -e "${RED}=== 一键卸载 ===${NC}"
    echo -e "${YELLOW}这将完全移除 Seven Proxy 及其所有文件${NC}"
    echo -e "${YELLOW}是否继续? (y/n): ${NC}\c"
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}取消卸载${NC}"
        return
    fi
    
    # 停止服务
    stop_all
    
    # 移除目录
    if [ -d "$WORKDIR" ]; then
        rm -rf "$WORKDIR"
        echo -e "${GREEN}已移除配置目录: $WORKDIR${NC}"
    fi
    
    # 移除命令链接
    if [ -L "/usr/local/bin/seven" ]; then
        sudo rm -f /usr/local/bin/seven
        echo -e "${GREEN}已移除命令链接${NC}"
    fi
    
    echo -e "\n${GREEN}✅ Seven Proxy 已完全卸载${NC}"
}

# 显示菜单
show_menu() {
    clear
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}              Seven Proxy 管理脚本 (守护进程版)             ${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}1. 极速安装模式 (临时隧道，全自动)${NC}"
    echo -e "${CYAN}2. 引导式安装模式 (自定义配置)${NC}"
    echo -e "${CYAN}3. 查看状态${NC}"
    echo -e "${CYAN}4. 查看日志${NC}"
    echo -e "${CYAN}5. 重启服务${NC}"
    echo -e "${CYAN}6. 停止服务${NC}"
    echo -e "${RED}7. 一键卸载${NC}"
    echo -e "${YELLOW}8. 退出${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}请选择 [1-8]: ${NC}\c"
}

# 主函数
main() {
    # 初始化目录
    init_dirs
    
    # 命令行参数处理
    if [ $# -gt 0 ]; then
        case "$1" in
            fast)
                fast_install
                exit 0
                ;;
            guided)
                guided_install
                exit 0
                ;;
            status)
                show_status
                exit 0
                ;;
            logs)
                view_logs "$2"
                exit 0
                ;;
            restart)
                restart_all
                exit 0
                ;;
            stop)
                stop_all
                exit 0
                ;;
            uninstall)
                uninstall_all
                exit 0
                ;;
            help|--help|-h)
                echo -e "${GREEN}使用方法:${NC}"
                echo "  seven                   # 交互式菜单"
                echo "  seven fast              # 极速安装"
                echo "  seven guided            # 引导式安装"
                echo "  seven status            # 查看状态"
                echo "  seven logs [service]    # 查看日志"
                echo "  seven restart           # 重启服务"
                echo "  seven stop              # 停止服务"
                echo "  seven uninstall         # 一键卸载"
                exit 0
                ;;
            *)
                echo -e "${RED}未知参数: $1${NC}"
                echo "使用: seven help 查看帮助"
                exit 1
                ;;
        esac
    fi
    
    # 交互式菜单
    while true; do
        show_menu
        read -r choice
        
        case $choice in
            1)
                fast_install
                echo -e "\n${YELLOW}按 Enter 返回菜单...${NC}"
                read
                ;;
            2)
                guided_install
                echo -e "\n${YELLOW}按 Enter 返回菜单...${NC}"
                read
                ;;
            3)
                show_status
                echo -e "\n${YELLOW}按 Enter 返回菜单...${NC}"
                read
                ;;
            4)
                view_logs ""
                echo -e "\n${YELLOW}按 Enter 返回菜单...${NC}"
                read
                ;;
            5)
                restart_all
                echo -e "\n${YELLOW}按 Enter 返回菜单...${NC}"
                read
                ;;
            6)
                stop_all
                echo -e "\n${YELLOW}按 Enter 返回菜单...${NC}"
                read
                ;;
            7)
                uninstall_all
                exit 0
                ;;
            8)
                echo -e "${GREEN}再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择${NC}"
                sleep 1
                ;;
        esac
    done
}

# 运行主函数
main "$@"