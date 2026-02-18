#!/bin/bash

# ====================== 辅助函数 ======================
format_size() {
    local size_mb=$1
    if [ "$size_mb" -ge 1024 ]; then
        awk "BEGIN {printf \"%.1fG\", $size_mb/1024}"
    else
        echo "${size_mb}MB"
    fi
}

check_disk_space_mb() {
    local required_mb=$1
    local avail_kb=$(df / | awk 'NR==2 {print $4}')
    local avail_mb=$((avail_kb / 1024))
    if [ $avail_mb -lt $required_mb ]; then
        echo "❌ 磁盘空间不足！至少需要 $(format_size $required_mb)，当前可用 $(format_size $avail_mb)"
        return 1
    fi
    echo "✅ 磁盘空间充足（可用 $(format_size $avail_mb)）"
    return 0
}

get_physical_memory_mb() {
    grep MemTotal /proc/meminfo | awk '{print int($2/1024)}'
}

set_swappiness() {
    local current_val=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "40")
    echo -e "\n【Swappiness 设置】"
    echo "📌 当前系统值: $current_val | 推荐范围: 0-200 (默认40)"
    echo "💡 说明: 值越高系统越积极使用 Swap (0=尽量不用, 40=保守策略, 100=积极使用)"
    
    while true; do
        read -p "👉 请输入 Swappiness 值 (直接回车使用默认 40): " swp_input
        if [ -z "$swp_input" ]; then
            swp_input=40
            break
        elif [[ "$swp_input" =~ ^[0-9]+$ ]] && [ "$swp_input" -ge 0 ] && [ "$swp_input" -le 200 ]; then
            break
        else
            echo "⚠️ 无效输入！请输入 0-200 之间的整数"
        fi
    done
    
    sudo sed -i '/^vm.swappiness=/d' /etc/sysctl.conf 2>/dev/null
    echo "vm.swappiness=$swp_input" | sudo tee -a /etc/sysctl.conf > /dev/null
    sudo sysctl -w vm.swappiness=$swp_input > /dev/null 2>&1
    echo "✅ Swappiness 已设置为: $swp_input"
}

remove_existing_swap() {
    if [ -f /swapfile ]; then
        echo "🔍 检测到现有 Swap 文件..."
        if sudo swapon --show | grep -q '/swapfile'; then
            echo "📴 正在禁用 Swap..."
            sudo swapoff /swapfile || { echo "❌ 禁用失败"; exit 1; }
        fi
        sudo rm -f /swapfile
        sudo sed -i '/\/swapfile swap swap/d' /etc/fstab
        echo "✅ 已清理现有 Swap 配置"
    else
        echo "ℹ️  未检测到现有 Swap 文件"
    fi
}

create_swap_file() {
    local size_mb=$1
    echo "⚙️  正在创建 $(format_size $size_mb) Swap 文件..."
    sudo dd if=/dev/zero of=/swapfile bs=1M count=$size_mb status=progress 2>&1 | grep -q "copied"
    [ $? -ne 0 ] && { echo "❌ 创建 Swap 文件失败"; exit 1; }
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile > /dev/null 2>&1
    sudo swapon /swapfile || { echo "❌ 启用 Swap 失败"; exit 1; }
    grep -q "/swapfile" /etc/fstab || echo "/swapfile swap swap defaults 0 0" | sudo tee -a /etc/fstab > /dev/null
    echo "✅ Swap 文件已启用并配置开机自启"
}

# ====================== 主功能 ======================
add_swap_manual() {
    echo -e "\n【手动添加 Swap】"
    local mem_mb=$(get_physical_memory_mb)
    local mem_fmt=$(format_size $mem_mb)
    local recommended_size=$((mem_mb * 2))
    
    echo "💡 物理内存: ${mem_fmt} | 建议 Swap 范围: ${mem_fmt} ~ $(format_size $recommended_size)"
    
    # ✅ 极简提示：通过"建议值 XXXMB"自然传递单位，移除冗余"单位: MB"
    read -p "👉 请输入 Swap 大小 (建议值 ${recommended_size}MB, 回车直接使用): " size_mb
    if [ -z "$size_mb" ]; then
        size_mb=$recommended_size
        echo -e "📌 已自动采用建议值: ${size_mb}MB"
    fi
    
    if ! [[ "$size_mb" =~ ^[0-9]+$ ]] || [ "$size_mb" -le 0 ]; then
        echo "⚠️  请输入大于 0 的整数"
        return
    fi
    
    if ! check_disk_space_mb $size_mb; then return; fi
    remove_existing_swap
    create_swap_file $size_mb
    set_swappiness
    
    echo -e "\n🎉 Swap 配置完成！系统状态如下："
    echo "========================================"
    free -h
    echo "========================================"
    echo "📌 当前 Swappiness 值: $(cat /proc/sys/vm/swappiness) (范围: 0-200 | 默认40)"
    echo "========================================"
    echo ""
    read -p "👉 配置信息已完整显示，按回车键返回主菜单..."
}

remove_swap_only() {
    echo -e "\n【删除 Swap】"
    read -p "⚠️  确认删除所有 Swap 配置？(默认Y, 回车即确认) [Y/n]: " confirm
    if [ -z "$confirm" ] || [[ "$confirm" =~ ^[Yy]$ ]]; then
        remove_existing_swap
        echo -e "\n✅ Swap 已完全移除！感谢使用。"
        echo "👋 脚本即将退出..."
        exit 0
    else
        echo -e "\n❌ 操作已取消，返回主菜单。"
        sleep 1
        return
    fi
}

auto_swap_setup() {
    echo -e "\n【自动配置 Swap】"
    local mem_mb=$(get_physical_memory_mb)
    local mem_fmt=$(format_size $mem_mb)
    local auto_size=$((mem_mb * 2))
    
    echo "💡 物理内存: ${mem_fmt} | 按推荐规则创建: $(format_size $auto_size) (物理内存 × 2)"
    
    if ! check_disk_space_mb $auto_size; then return; fi
    remove_existing_swap
    create_swap_file $auto_size
    set_swappiness
    
    echo -e "\n🎉 Swap 配置完成！系统状态如下："
    echo "========================================"
    free -h
    echo "========================================"
    echo "📌 当前 Swappiness 值: $(cat /proc/sys/vm/swappiness) (范围: 0-200 | 默认40)"
    echo "========================================"
    echo ""
    read -p "👉 配置信息已完整显示，按回车键返回主菜单..."
}

# ====================== 菜单系统 ======================
show_menu() {
    clear
    cat <<EOF
=======================================
        🔄 Swap 管理工具 (智能单位)
=======================================
1. 添加 Swap          (自定义大小 + Swappiness)
2. 删除现有 Swap      (回车默认确认删除)
3. 自动配置 Swap      (物理内存 × 2)
4. 退出
=======================================
EOF
    read -p "👉 请选择操作 (1-4): " choice
    case $choice in
        1) add_swap_manual ;;
        2) remove_swap_only ;;
        3) auto_swap_setup ;;
        4) echo -e "\n👋 感谢使用！"; exit 0 ;;
        *) echo "⚠️  无效选项"; sleep 1; show_menu ;;
    esac
}

# ====================== 启动 ======================
main() {
    [ "$EUID" -ne 0 ] && { 
        echo "⚠️  请使用 sudo 运行 (例如: sudo bash swap.sh)"; 
        exit 1; 
    }
    echo "🛡️  Swap 管理工具已启动 (单位智能切换)"
    while true; do show_menu; done
}

main