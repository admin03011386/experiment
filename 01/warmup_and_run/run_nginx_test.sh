#!/bin/bash
#
# run_nginx_test.sh
# =================
# 一键式 NGINX 镜像去重测试脚本
# 测试项: 存储空间、推送延迟、拉取延迟、吞吐量
#
# 用法: bash run_nginx_test.sh
#
# 前提条件:
#   1. Docker 已安装并可运行
#   2. Redis 已安装
#   3. Go 编译环境已配置
#   4. Python3 + dxf + pyyaml + bottle + hashring 已安装
#   5. 已运行 prepare_nginx_test.py 生成测试数据
#

set -e

# ============ 配置区 ============
SIMENC_DIR="$(cd "$(dirname "$0")/../new" && pwd)"
WARMUP_DIR="$(cd "$(dirname "$0")" && pwd)"
STORAGE_ROOT="/home/simenc3/docker_v2"
REGISTRY_PORT=5009
CLIENT_PORT=8081
RESULT_LOG="test_results_$(date +%Y%m%d_%H%M%S).log"
# ================================

cd "$WARMUP_DIR"

echo "=============================================="
echo "  NGINX 镜像去重测试 (File-as-Layer)"
echo "  $(date)"
echo "=============================================="
echo ""

# 函数: 获取目录大小 (字节)
get_dir_size() {
    du -sb "$1" 2>/dev/null | awk '{print $1}' || echo "0"
}

get_dir_size_human() {
    du -sh "$1" 2>/dev/null | awk '{print $1}' || echo "0"
}

# ========== Step 0: 检查前提 ==========
echo "📋 Step 0: 检查前提条件..."

if [ ! -f "test_data_nginx.json" ]; then
    echo "❌ test_data_nginx.json 不存在，请先运行:"
    echo "   python3 prepare_nginx_test.py"
    exit 1
fi

if [ ! -f "$SIMENC_DIR/bin/registry" ]; then
    echo "⚠️  registry 二进制不存在，尝试编译..."
    cd "$SIMENC_DIR"
    go build -mod=vendor -o ./bin/registry ./cmd/registry
    cd "$WARMUP_DIR"
fi

echo "✅ 前提检查通过"
echo ""

# ========== Step 1: 清空旧数据 ==========
echo "🧹 Step 1: 清空旧存储数据和 Redis..."

redis-cli FLUSHALL > /dev/null 2>&1 || true

# 先用 sudo 确保存储目录存在并归当前用户所有
sudo mkdir -p "$STORAGE_ROOT"
sudo chown -R "$(whoami):$(whoami)" "$STORAGE_ROOT"

# 清空内容
rm -rf "${STORAGE_ROOT:?}"/*

echo "✅ 数据已清空"
echo ""

# ========== Step 2: 启动 Registry ==========
echo "🚀 Step 2: 启动 Registry (端口 $REGISTRY_PORT)..."

cd "$SIMENC_DIR/bin"
# 杀掉旧进程
pkill -f "registry serve" 2>/dev/null || true
sleep 1

./registry serve config.yaml > /tmp/registry_test.log 2>&1 &
REGISTRY_PID=$!
echo "   Registry PID: $REGISTRY_PID"
sleep 3

# 检查是否启动成功
if ! kill -0 $REGISTRY_PID 2>/dev/null; then
    echo "❌ Registry 启动失败，查看日志: /tmp/registry_test.log"
    exit 1
fi

echo "✅ Registry 已启动"
echo ""

cd "$WARMUP_DIR"

# ========== Step 3: Warmup (Push) — 测推送延迟 ==========
echo "📤 Step 3: Warmup (推送 NGINX 镜像层)..."
echo "-------------------------------------------"

SIZE_BEFORE=$(get_dir_size "$STORAGE_ROOT")
PUSH_START=$(date +%s%N)

python3 warmup_run.py -c warmup -i config-nginx.yml 2>&1 | tee /tmp/warmup_output.log

PUSH_END=$(date +%s%N)
PUSH_DURATION=$(( (PUSH_END - PUSH_START) / 1000000 ))  # 毫秒

# 等待 dedup 处理完成
echo ""
echo "⏳ 等待 dedup 处理完成 (10秒)..."
sleep 10

echo "✅ Warmup 完成"
echo ""

# ========== Step 4: 测量存储空间 ==========
echo "💾 Step 4: 存储空间统计..."
echo "-------------------------------------------"

BLOBS_SIZE=$(get_dir_size_human "$STORAGE_ROOT/docker/registry/v2/blobs" 2>/dev/null || echo "N/A")
FILEBLOBS_SIZE=$(get_dir_size_human "$STORAGE_ROOT/docker/registry/v2/fileblobs" 2>/dev/null || echo "N/A")
TOTAL_SIZE=$(get_dir_size_human "$STORAGE_ROOT")
TOTAL_SIZE_BYTES=$(get_dir_size "$STORAGE_ROOT")

echo "   原始 blobs 目录:     $BLOBS_SIZE"
echo "   文件级 blobs 目录:   $FILEBLOBS_SIZE"
echo "   总存储空间:          $TOTAL_SIZE"

# 从 registry 日志中分析 FileDedup 执行情况
echo ""
echo "   [FileDedup 执行统计 (来自 registry 日志)]:"
CLEANUP_OK=$(grep -c "FileDedup_Cleanup_OK" /tmp/registry_test.log 2>/dev/null || echo "0")
CLEANUP_FAIL=$(grep -c "FileDedup_CleanupFailed" /tmp/registry_test.log 2>/dev/null || echo "0")
DEDUP_SUCCESS=$(grep -c "FileDedup_Success" /tmp/registry_test.log 2>/dev/null || echo "0")
echo "   FileDedup 成功:       $DEDUP_SUCCESS 层"
echo "   原始blob删除成功:     $CLEANUP_OK 个"
echo "   原始blob删除失败:     $CLEANUP_FAIL 个"
if [ "$CLEANUP_FAIL" -gt "0" ]; then
    echo "   [删除失败详情]:"
    grep "FileDedup_CleanupFailed" /tmp/registry_test.log | sed 's/^/     /'
fi

# 从 warmup 输出中提取原始数据量
WARMUP_SIZE=$(grep "warmup size" /tmp/warmup_output.log | tail -1 | grep -o '[0-9]*' | tail -1)
if [ -n "$WARMUP_SIZE" ] && [ "$TOTAL_SIZE_BYTES" -gt 0 ]; then
    DEDUP_RATIO=$(echo "scale=2; $WARMUP_SIZE / $TOTAL_SIZE_BYTES" | bc 2>/dev/null || echo "N/A")
    echo "   原始数据量:          $WARMUP_SIZE bytes"
    echo "   去重率:              ${DEDUP_RATIO}x"
fi

echo ""

# ========== Step 5: Run (Pull) — 测拉取延迟和吞吐量 ==========
echo "📥 Step 5: Run (拉取测试)..."
echo "-------------------------------------------"

# 启动客户端代理
python3 client.py -i 127.0.0.1 -p $CLIENT_PORT &
CLIENT_PID=$!
sleep 2

PULL_START=$(date +%s%N)

python3 warmup_run.py -c run -i config-nginx.yml 2>&1 | tee /tmp/run_output.log

PULL_END=$(date +%s%N)
PULL_DURATION=$(( (PULL_END - PULL_START) / 1000000 ))

# 关闭客户端代理
kill $CLIENT_PID 2>/dev/null || true

echo ""
echo "✅ Run 完成"
echo ""

# ========== Step 6: 汇总结果 ==========
echo "=============================================="
echo "  📊 测试结果汇总"
echo "=============================================="
echo ""
echo "  🕐 推送 (Warmup):"
echo "     总耗时: ${PUSH_DURATION}ms"
echo ""
echo "  🕐 拉取 (Run):"
echo "     总耗时: ${PULL_DURATION}ms"
echo ""
echo "  💾 存储空间:"
echo "     总存储: $TOTAL_SIZE"
echo "     原始blobs: $BLOBS_SIZE"
echo "     文件blobs: $FILEBLOBS_SIZE"
echo ""
echo "  📄 详细拉取统计见: result_nginx.json"
echo ""

# 解析 run 输出中的统计信息
if [ -f /tmp/run_output.log ]; then
    echo "  📈 拉取统计 (从 warmup_run.py 输出):"
    grep -E "Statistics|Successful|Failed|Duration|Transfered|Latency|Throughput|on time" /tmp/run_output.log | sed 's/^/     /'
fi

echo ""

# 保存结果到日志文件
{
    echo "测试时间: $(date)"
    echo "镜像: nginx:1.26, nginx:1.27, nginx:latest"
    echo ""
    echo "推送总耗时: ${PUSH_DURATION}ms"
    echo "拉取总耗时: ${PULL_DURATION}ms"
    echo "总存储空间: $TOTAL_SIZE"
    echo "blobs目录: $BLOBS_SIZE"
    echo "fileblobs目录: $FILEBLOBS_SIZE"
    echo ""
    grep -E "Statistics|Successful|Failed|Duration|Transfered|Latency|Throughput|on time" /tmp/run_output.log 2>/dev/null || true
} > "$RESULT_LOG"

echo "📝 结果已保存到: $RESULT_LOG"

# ========== 清理 ==========
echo ""
echo "🛑 关闭 Registry..."
kill $REGISTRY_PID 2>/dev/null || true

echo ""
echo "✅ 测试全部完成！"
