#!/bin/bash
set -e

echo "=== 批量替换所有 VM 的 Standard SKU 公网 IP 为 Basic 动态 IP ==="

# 获取当前订阅下所有 VM 列表（名称 + 资源组）
VMS=$(az vm list --query '[].{name:name,rg:resourceGroup}' -o tsv)

if [[ -z "$VMS" ]]; then
    echo "未找到任何虚拟机！"
    exit 1
fi

# 用于存储所有需要重启的 VM
RESTART_LIST=()

while read -r VM_NAME RG; do
    echo "------------------------------------------------------------"
    echo "处理虚拟机：$VM_NAME (资源组: $RG)"

    # 获取 VM 网卡
    NIC_ID=$(az vm show -g "$RG" -n "$VM_NAME" --query "networkProfile.networkInterfaces[0].id" -o tsv)
    if [[ -z "$NIC_ID" ]]; then
        echo "⚠️ 未找到网卡，跳过 $VM_NAME"
        continue
    fi
    NIC_NAME=$(basename "$NIC_ID")

    # 获取网卡的公网 IP
    PIP_ID=$(az network nic show -g "$RG" -n "$NIC_NAME" --query "ipConfigurations[0].publicIPAddress.id" -o tsv)
    if [[ -z "$PIP_ID" ]]; then
        echo "❌ 无公网 IP，跳过 $VM_NAME"
        continue
    fi

    PIP_NAME=$(basename "$PIP_ID")
    PIP_SKU=$(az network public-ip show -g "$RG" -n "$PIP_NAME" --query "sku.name" -o tsv)

    if [[ "$PIP_SKU" != "Standard" ]]; then
        echo "✅ 公网 IP $PIP_NAME 已经是 Basic SKU，无需更改"
        continue
    fi

    # 解绑并删除 Standard 公网 IP
    echo "🔄 解绑 Standard 公网 IP $PIP_NAME ..."
    az network nic ip-config update \
        -g "$RG" \
        --nic-name "$NIC_NAME" \
        -n ipconfig1 \
        --remove publicIpAddress || true

    echo "🗑️ 删除 Standard 公网 IP $PIP_NAME ..."
    az network public-ip delete -g "$RG" -n "$PIP_NAME" || true

    # 创建新的 Basic SKU 动态公网 IP
    NEW_PIP_NAME="${NIC_NAME}-pip-$RANDOM"
    echo "✨ 创建新的动态 Basic 公网 IP: $NEW_PIP_NAME"
    az network public-ip create \
        -g "$RG" \
        -n "$NEW_PIP_NAME" \
        --sku Basic \
        --allocation-method Dynamic

    # 绑定新的公网 IP
    echo "🔗 绑定新的公网 IP..."
    az network nic ip-config update \
        -g "$RG" \
        --nic-name "$NIC_NAME" \
        -n ipconfig1 \
        --public-ip-address "$NEW_PIP_NAME"

    NEW_IP=$(az network public-ip show -g "$RG" -n "$NEW_PIP_NAME" --query "ipAddress" -o tsv)
    echo "✅ $VM_NAME 新公网 IP：$NEW_IP"

    # 添加到重启列表
    RESTART_LIST+=("$VM_NAME|$RG")

done <<< "$VMS"

echo "------------------------------------------------------------"
echo "所有虚拟机公网 IP 替换完成 ✅"
echo "开始统一重启虚拟机..."

for VM in "${RESTART_LIST[@]}"; do
    VM_NAME="${VM%%|*}"
    RG="${VM##*|}"
    echo "🔄 重启虚拟机: $VM_NAME (资源组: $RG)"
    az vm restart -g "$RG" -n "$VM_NAME"
done

echo "------------------------------------------------------------"
echo "所有虚拟机重启完成 ✅"
