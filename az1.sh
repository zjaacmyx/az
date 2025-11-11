#!/bin/bash
set -e

echo "=== 批量替换所有 VM 的 Standard SKU 公网 IP 为 Basic 动态 IP（若无则自动创建） ==="

# 日志文件
LOG_FILE="az_replace_ip_$(date +%F_%H-%M).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# 确认提示
read -p "⚠️ 确认要修改当前订阅下所有虚拟机的公网 IP 吗？(yes/no): " confirm
[[ "$confirm" == "yes" ]] || { echo "已取消操作"; exit 0; }

# 获取当前订阅下所有 VM（名称 + 资源组）
VMS=$(az vm list --query '[].{name:name,rg:resourceGroup}' -o tsv)

if [[ -z "$VMS" ]]; then
    echo "未找到任何虚拟机！"
    exit 1
fi

# 存储需重启的 VM 列表
RESTART_LIST=()

while read -r VM_NAME RG; do
    echo "------------------------------------------------------------"
    echo "处理虚拟机：$VM_NAME (资源组: $RG)"

    # 获取网卡 ID
    NIC_ID=$(az vm show -g "$RG" -n "$VM_NAME" --query "networkProfile.networkInterfaces[0].id" -o tsv)
    if [[ -z "$NIC_ID" ]]; then
        echo "⚠️ 未找到网卡，跳过 $VM_NAME"
        continue
    fi
    NIC_NAME=$(basename "$NIC_ID")

    # 获取 IP 配置名称（避免硬编码 ipconfig1）
    IPCONFIG_NAME=$(az network nic show -g "$RG" -n "$NIC_NAME" --query "ipConfigurations[0].name" -o tsv)
    if [[ -z "$IPCONFIG_NAME" ]]; then
        echo "⚠️ 未找到 IP 配置，跳过 $VM_NAME"
        continue
    fi

    # 获取公网 IP 信息
    PIP_ID=$(az network nic show -g "$RG" -n "$NIC_NAME" --query "ipConfigurations[0].publicIPAddress.id" -o tsv)

    # 无公网 IP → 自动创建并绑定新的 Basic 动态 IP
    if [[ -z "$PIP_ID" ]]; then
        echo "🌐 $VM_NAME 当前无公网 IP，自动创建 Basic 动态公网 IP..."

        NEW_PIP_NAME="${NIC_NAME}-pip-$RANDOM"
        az network public-ip create \
            -g "$RG" \
            -n "$NEW_PIP_NAME" \
            --sku Basic \
            --allocation-method Dynamic

        az network nic ip-config update \
            -g "$RG" \
            --nic-name "$NIC_NAME" \
            -n "$IPCONFIG_NAME" \
            --public-ip-address "$NEW_PIP_NAME"

        NEW_IP=$(az network public-ip show -g "$RG" -n "$NEW_PIP_NAME" --query "ipAddress" -o tsv)
        echo "✅ 已为 $VM_NAME 创建并绑定新公网 IP：$NEW_IP"
        RESTART_LIST+=("$VM_NAME|$RG")
        continue
    fi

    # 有公网 IP → 检查 SKU 类型
    PIP_NAME=$(basename "$PIP_ID")
    PIP_SKU=$(az network public-ip show -g "$RG" -n "$PIP_NAME" --query "sku.name" -o tsv)

    if [[ "$PIP_SKU" != "Standard" ]]; then
        echo "✅ 公网 IP $PIP_NAME 已是 Basic SKU，无需更改"
        continue
    fi

    echo "🔄 检测到 Standard SKU 公网 IP：$PIP_NAME，准备替换..."

    # 解绑旧 IP
    az network nic ip-config update \
        -g "$RG" \
        --nic-name "$NIC_NAME" \
        -n "$IPCONFIG_NAME" \
        --remove publicIpAddress || true

    # 删除旧 IP
    echo "🗑️ 删除旧的 Standard 公网 IP：$PIP_NAME"
    if az network public-ip show -g "$RG" -n "$PIP_NAME" &>/dev/null; then
        az network public-ip delete -g "$RG" -n "$PIP_NAME" || true
    fi

    # 创建新的 Basic 动态 IP
    NEW_PIP_NAME="${NIC_NAME}-pip-$RANDOM"
    echo "✨ 创建新的 Basic 动态公网 IP：$NEW_PIP_NAME"
    az network public-ip create \
        -g "$RG" \
        -n "$NEW_PIP_NAME" \
        --sku Basic \
        --allocation-method Dynamic

    # 绑定新 IP
    echo "🔗 绑定新的公网 IP..."
    az network nic ip-config update \
        -g "$RG" \
        --nic-name "$NIC_NAME" \
        -n "$IPCONFIG_NAME" \
        --public-ip-address "$NEW_PIP_NAME"

    NEW_IP=$(az network public-ip show -g "$RG" -n "$NEW_PIP_NAME" --query "ipAddress" -o tsv)
    echo "✅ $VM_NAME 新公网 IP：$NEW_IP"

    RESTART_LIST+=("$VM_NAME|$RG")
done <<< "$VMS"

echo "------------------------------------------------------------"
echo "所有虚拟机公网 IP 处理完成 ✅"
echo "开始统一重启虚拟机..."

# 并行重启（提升速度）
for VM in "${RESTART_LIST[@]}"; do
    VM_NAME="${VM%%|*}"
    RG="${VM##*|}"
    echo "🔄 重启虚拟机: $VM_NAME (资源组: $RG)"
    az vm restart -g "$RG" -n "$VM_NAME" &
done
wait

echo "------------------------------------------------------------"
echo "所有虚拟机重启完成 ✅"
echo "日志文件：$LOG_FILE"
