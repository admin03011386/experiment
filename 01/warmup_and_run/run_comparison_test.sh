#!/bin/bash
#
# run_comparison_test.sh
# ======================
# SimEnc (04) vs New-File-as-Layer (01) 性能对比测试
#
# 测试项:
#   1. 推送耗时 (Warmup time)
#   2. 拉取耗时 (Run time)
#   3. 存储空间占用 / 去重率
#   4. 吞吐量 & 平均延迟
#
# 用法:
#   bash run_comparison_test.sh
#
# 前提:
#   1. 已运行 prepare_nginx_test.py 生成 test_data_nginx.json
#   2. 两个 registry 二进制均已编译
#   3. Redis 已启动
#

set -e

# ============================================================
# 配置区
# ============================================================
WARMUP_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- SimEnc (04) ---
SIMENC04_DIR="/home/user/go/src/github.com/docker/simenc"
STORAGE_SIMENC="/home/simenc2/docker_v2"
LOG_SIMENC="/tmp/registry_simenc.log"
PUSHLOG_SIMENC="/tmp/warmup_simenc.log"
RUNLOG_SIMENC="/tmp/run_simenc.log"

# --- New / File-as-Layer (01) ---
NEW01_DIR="/home/user/go/src/github.com/docker2/new"
STORAGE_NEW="/home/simenc3/docker_v2"
LOG_NEW="/tmp/registry_new.log"
PUSHLOG_NEW="/tmp/warmup_new.log"
RUNLOG_NEW="/tmp/run_new.log"

REGISTRY_PORT=5009
CLIENT_PORT=8081

RESULT_FILE="comparison_$(date +%Y%m%d_%H%M%S).log"
# ============================================================

cd "$WARMUP_DIR"

# -------- 工具函数 --------
get_dir_size() {
    du -sb "$1" 2>/dev/null | awk '{print $1}' || echo "0"
}
get_dir_size_human() {
    du -sh "$1" 2>/dev/null | awk '{print $1}' || echo "N/A"
}
bold() { printf "\033[1m%s\033[0m\n" "$*"; }
sep()  { echo "----------------------------------------------"; }

# -------- 前提检查 --------
echo ""
bold "=============================================="
bold "  SimEnc vs New (File-as-Layer) 对比测试"
bold "  $(date)"
bold "=============================================="
echo ""

echo "📋 前提检查..."

if [ ! -f "test_data_nginx.json" ]; then
    echo "❌ test_data_nginx.json 不存在，请先运行:"
    echo "   python3 prepare_nginx_test.py"
    exit 1
fi

if [ ! -f "$SIMENC04_DIR/bin/registry" ]; then
    echo "⚠️  SimEnc registry 不存在: $SIMENC04_DIR/bin/registry"
    echo "   正在编译 04/simenc ..."
    (cd "$SIMENC04_DIR" && go build -mod=vendor -o ./bin/registry ./cmd/registry)
    echo "   ✅ 编译完成"
fi

if [ ! -f "$NEW01_DIR/bin/registry" ]; then
    echo "⚠️  New registry 不存在: $NEW01_DIR/bin/registry"
    echo "   正在编译 01/new ..."
    (cd "$NEW01_DIR" && go build -mod=vendor -o ./bin/registry ./cmd/registry)
    echo "   ✅ 编译完成"
fi

echo "✅ 前提检查通过"
echo ""

# ================================================================
# 通用测试函数
# run_single_test <label> <registry_dir> <storage_root> <reg_log> <push_log> <run_log> <config_yml>
# ================================================================
run_single_test() {
    local LABEL="$1"
    local REG_DIR="$2"
    local STORAGE="$3"
    local REG_LOG="$4"
    local PUSH_LOG="$5"
    local RUN_LOG="$6"
    local CONFIG_YML="$7"

    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    bold "  测试: $LABEL"
    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Step A: 清空数据
    echo "🧹 清空旧数据和 Redis..."
    redis-cli FLUSHALL > /dev/null 2>&1 || true
    sudo mkdir -p "$STORAGE"
    sudo chown -R "$(whoami):$(whoami)" "$STORAGE"
    rm -rf "${STORAGE:?}"/*
    pkill -f "registry serve" 2>/dev/null || true
    sleep 1
    echo "   ✅ 清空完成"
    echo ""

    # Step B: 启动 Registry
    echo "🚀 启动 Registry..."
    (cd "$REG_DIR/bin" && ./registry serve config.yaml > "$REG_LOG" 2>&1) &
    local REG_PID=$!
    sleep 3
    if ! kill -0 $REG_PID 2>/dev/null; then
        echo "❌ Registry 启动失败，日志: $REG_LOG"
        return 1
    fi
    echo "   PID: $REG_PID"
    echo "   ✅ Registry 已启动"
    echo ""

    # Step C: Warmup (Push)
    echo "📤 Warmup (推送)..."
    sep
    local PUSH_START PUSH_END PUSH_MS
    PUSH_START=$(date +%s%N)
    # 设置存储路径环境变量，让 warmup_run.py 读取正确的 blobs 目录
    DEDUP_STORAGE_PATH="$STORAGE/docker/registry/v2/blobs" \
        python3 warmup_run.py -c warmup -i "$CONFIG_YML" 2>&1 | tee "$PUSH_LOG"
    PUSH_END=$(date +%s%N)
    PUSH_MS=$(( (PUSH_END - PUSH_START) / 1000000 ))

    echo ""
    echo "⏳ 等待 dedup 处理完成..."
    local PREV_SIZE=0 CURR_SIZE=1 STABLE_COUNT=0
    for i in $(seq 1 24); do
        sleep 5
        CURR_SIZE=$(get_dir_size "$STORAGE" 2>/dev/null || echo 0)
        if [ "$CURR_SIZE" = "$PREV_SIZE" ]; then
            STABLE_COUNT=$((STABLE_COUNT + 1))
            if [ "$STABLE_COUNT" -ge 2 ]; then
                echo "   ✅ 存储已稳定 ($((i*5))秒)"
                break
            fi
        else
            STABLE_COUNT=0
        fi
        PREV_SIZE=$CURR_SIZE
        echo "   ... 等待中 ($((i*5))s, 当前 $(get_dir_size_human "$STORAGE"))"
    done
    echo "   ✅ Warmup 完成 (${PUSH_MS}ms)"
    echo ""

    # Step D: 存储统计
    echo "💾 存储空间..."
    local BLOBS_SIZE FILEBLOBS_SIZE PARTIALS_SIZE TOTAL_SIZE TOTAL_BYTES
    BLOBS_SIZE=$(get_dir_size_human "$STORAGE/docker/registry/v2/blobs" 2>/dev/null || echo "N/A")
    FILEBLOBS_SIZE=$(get_dir_size_human "$STORAGE/docker/registry/v2/fileblobs" 2>/dev/null || echo "N/A")
    PARTIALS_SIZE=$(get_dir_size_human "$STORAGE/docker/registry/v2/partials" 2>/dev/null || echo "N/A")
    TOTAL_SIZE=$(get_dir_size_human "$STORAGE")
    TOTAL_BYTES=$(get_dir_size "$STORAGE")

    local WARMUP_SIZE
    WARMUP_SIZE=$(grep "warmup size" "$PUSH_LOG" | tail -1 | grep -oP '\d+' | tail -1 || echo "0")

    local DEDUP_RATIO="N/A"
    if [ "$WARMUP_SIZE" -gt 0 ] && [ "$TOTAL_BYTES" -gt 0 ]; then
        DEDUP_RATIO=$(echo "scale=2; $WARMUP_SIZE / $TOTAL_BYTES" | bc 2>/dev/null || echo "N/A")
    fi

    echo "   原始blobs:     $BLOBS_SIZE"
    echo "   文件blobs:     $FILEBLOBS_SIZE"
    echo "   partials:      $PARTIALS_SIZE"
    echo "   总存储:        $TOTAL_SIZE ($TOTAL_BYTES bytes)"
    echo "   推送数据量:    $WARMUP_SIZE bytes"
    echo "   去重率:        ${DEDUP_RATIO}x"
    echo ""

    # Step E: Run (Pull)
    echo "📥 Run (拉取)..."
    sep
    python3 client.py -i 127.0.0.1 -p $CLIENT_PORT &
    local CLIENT_PID=$!
    sleep 2

    local RUN_START RUN_END RUN_MS
    RUN_START=$(date +%s%N)
    python3 warmup_run.py -c run -i "$CONFIG_YML" 2>&1 | tee "$RUN_LOG"
    RUN_END=$(date +%s%N)
    RUN_MS=$(( (RUN_END - RUN_START) / 1000000 ))

    kill $CLIENT_PID 2>/dev/null || true
    echo "   ✅ Run 完成 (${RUN_MS}ms)"
    echo ""

    # Step F: 停止 Registry
    kill $REG_PID 2>/dev/null || true
    sleep 1

    # Step G: 保存结果到全局变量（通过临时文件传递）
    local AVG_LAT THROUGHPUT SUCC_REQ FAIL_REQ
    AVG_LAT=$(grep "Average Latency" "$RUN_LOG" | grep -oP '[\d.]+' | head -1 || echo "N/A")
    THROUGHPUT=$(grep "Throughput" "$RUN_LOG" | grep -oP '[\d.]+' | head -1 || echo "N/A")
    SUCC_REQ=$(grep "Successful Requests" "$RUN_LOG" | grep -oP '\d+' | head -1 || echo "0")
    FAIL_REQ=$(grep "Failed Requests" "$RUN_LOG" | grep -oP '\d+' | head -1 || echo "0")

    cat > "/tmp/result_${LABEL// /_}.env" <<EOF
LABEL="$LABEL"
PUSH_MS=$PUSH_MS
RUN_MS=$RUN_MS
BLOBS_SIZE="$BLOBS_SIZE"
FILEBLOBS_SIZE="$FILEBLOBS_SIZE"
PARTIALS_SIZE="$PARTIALS_SIZE"
TOTAL_SIZE="$TOTAL_SIZE"
TOTAL_BYTES=$TOTAL_BYTES
WARMUP_SIZE=$WARMUP_SIZE
DEDUP_RATIO=$DEDUP_RATIO
AVG_LAT=$AVG_LAT
THROUGHPUT=$THROUGHPUT
SUCC_REQ=$SUCC_REQ
FAIL_REQ=$FAIL_REQ
EOF

    echo ""
}

# ================================================================
# 执行两轮测试
# ================================================================

# config-nginx.yml 中 output 字段要区分，避免互相覆盖
# 01/new 用 config-nginx.yml (output: result_nginx.json)
# 04/simenc 用 config-nginx-simenc.yml (output: result_nginx_simenc.json)

# 为 04/simenc 创建专用 config
SIMENC_CONFIG="config-nginx-simenc.yml"
cat > "$WARMUP_DIR/$SIMENC_CONFIG" <<'YMLEOF'
verbose: true
client_info:
    client_list:
    - localhost:8081
    port: 8080
    threads: 1
    wait: false
trace:
    location: ./
    traces:
        - test_data_nginx.json
    limit: 
        type: requests
        amount: 5000
    output: result_nginx_simenc.json

registry:
    - localhost:5009

warmup:
    output: interm_nginx_simenc.json
    threads: 1
    random: false
YMLEOF

# 为 01/new 也强制生成 config，确保线程数=1
NEW_CONFIG="config-nginx.yml"
cat > "$WARMUP_DIR/$NEW_CONFIG" <<'YMLEOF'
verbose: true
client_info:
    client_list:
    - localhost:8081
    port: 8080
    threads: 1
    wait: false
trace:
    location: ./
    traces:
        - test_data_nginx.json
    limit: 
        type: requests
        amount: 5000
    output: result_nginx.json

registry:
    - localhost:5009

warmup:
    output: interm_nginx.json
    threads: 1
    random: false
YMLEOF

# 运行 SimEnc (04)
run_single_test "SimEnc_04" \
    "$SIMENC04_DIR" \
    "$STORAGE_SIMENC" \
    "$LOG_SIMENC" \
    "$PUSHLOG_SIMENC" \
    "$RUNLOG_SIMENC" \
    "$SIMENC_CONFIG"

# 运行 New / File-as-Layer (01)
run_single_test "New_FileAsLayer_01" \
    "$NEW01_DIR" \
    "$STORAGE_NEW" \
    "$LOG_NEW" \
    "$PUSHLOG_NEW" \
    "$RUNLOG_NEW" \
    "config-nginx.yml"

# ================================================================
# 汇总对比
# ================================================================
bold ""
bold "=============================================="
bold "  📊 性能对比汇总"
bold "=============================================="
echo ""

# 加载两组结果
source /tmp/result_SimEnc_04.env
S_PUSH=$PUSH_MS; S_RUN=$RUN_MS; S_TOT_H=$TOTAL_SIZE; S_BLOBS=$BLOBS_SIZE; S_FBLOBS=$FILEBLOBS_SIZE; S_TOT_B=$TOTAL_BYTES; S_DATA=$WARMUP_SIZE; S_RATIO=$DEDUP_RATIO
S_LAT=$AVG_LAT; S_TP=$THROUGHPUT; S_SUCC=$SUCC_REQ; S_FAIL=$FAIL_REQ; S_PARTS=$PARTIALS_SIZE

source /tmp/result_New_FileAsLayer_01.env
N_PUSH=$PUSH_MS; N_RUN=$RUN_MS; N_TOT_H=$TOTAL_SIZE; N_BLOBS=$BLOBS_SIZE; N_FBLOBS=$FILEBLOBS_SIZE; N_TOT_B=$TOTAL_BYTES; N_DATA=$WARMUP_SIZE; N_RATIO=$DEDUP_RATIO
N_LAT=$AVG_LAT; N_TP=$THROUGHPUT; N_SUCC=$SUCC_REQ; N_FAIL=$FAIL_REQ; N_PARTS=$PARTIALS_SIZE

printf "%-30s %-20s %-20s\n" "指标" "SimEnc (04)" "New File-as-Layer (01)"
printf "%-30s %-20s %-20s\n" "------------------------------" "--------------------" "--------------------"
printf "%-30s %-20s %-20s\n" "推送总耗时 (ms)"        "${S_PUSH}"   "${N_PUSH}"
printf "%-30s %-20s %-20s\n" "拉取总耗时 (ms)"        "${S_RUN}"    "${N_RUN}"
printf "%-30s %-20s %-20s\n" "平均拉取延迟 (s)"       "${S_LAT}"    "${N_LAT}"
printf "%-30s %-20s %-20s\n" "吞吐量 (req/s)"         "${S_TP}"     "${N_TP}"
printf "%-30s %-20s %-20s\n" "成功请求数"              "${S_SUCC}"   "${N_SUCC}"
printf "%-30s %-20s %-20s\n" "失败请求数"              "${S_FAIL}"   "${N_FAIL}"
printf "%-30s %-20s %-20s\n" "总存储空间"              "${S_TOT_H}"  "${N_TOT_H}"
printf "%-30s %-20s %-20s\n" "  原始blobs目录"         "${S_BLOBS}"  "${N_BLOBS}"
printf "%-30s %-20s %-20s\n" "  文件blobs目录"         "${S_FBLOBS}" "${N_FBLOBS}"
printf "%-30s %-20s %-20s\n" "  partials目录"          "${S_PARTS}"  "${N_PARTS}"
printf "%-30s %-20s %-20s\n" "推送数据量 (bytes)"      "${S_DATA}"   "${N_DATA}"
printf "%-30s %-20s %-20s\n" "去重率 (x)"              "${S_RATIO}"  "${N_RATIO}"
echo ""

# 拉取统计
echo "--- SimEnc 拉取统计 ---"
grep -E "Statistics|Successful|Failed|Duration|Transfered|Latency|Throughput|on time" "$RUNLOG_SIMENC" 2>/dev/null | sed 's/^/  /'
echo ""
echo "--- New 拉取统计 ---"
grep -E "Statistics|Successful|Failed|Duration|Transfered|Latency|Throughput|on time" "$RUNLOG_NEW" 2>/dev/null | sed 's/^/  /'
echo ""

# FileDedup 清理统计（只有 New 有）
echo "--- New FileDedup 清理统计 ---"
CLEANUP_OK=$(grep -c "FileDedup_Cleanup_OK"     "$LOG_NEW" 2>/dev/null || echo "0")
CLEANUP_FAIL=$(grep -c "FileDedup_CleanupFailed" "$LOG_NEW" 2>/dev/null || echo "0")
DEDUP_OK=$(grep -c "FileDedup_Success"           "$LOG_NEW" 2>/dev/null || echo "0")
PARTIAL_OK=$(grep -c "hasPartial:true"           "$LOG_NEW" 2>/dev/null || echo "0")
PARTIAL_FAIL=$(grep -c "hasPartial:false"        "$LOG_NEW" 2>/dev/null || echo "0")
echo "  FileDedup 成功: $DEDUP_OK 层"
echo "  Partial decode 成功: $PARTIAL_OK 层"
echo "  Partial decode 失败: $PARTIAL_FAIL 层"
echo "  原始blob删除成功: $CLEANUP_OK 个"
echo "  原始blob删除失败: $CLEANUP_FAIL 个"
echo ""

# 保存到文件
{
    echo "=============================================="
    echo "  SimEnc vs New 对比测试"
    echo "  $(date)"
    echo "=============================================="
    echo ""
    printf "%-30s %-20s %-20s\n" "指标" "SimEnc (04)" "New File-as-Layer (01)"
    printf "%-30s %-20s %-20s\n" "------------------------------" "--------------------" "--------------------"
    printf "%-30s %-20s %-20s\n" "推送总耗时 (ms)"        "${S_PUSH}"   "${N_PUSH}"
    printf "%-30s %-20s %-20s\n" "拉取总耗时 (ms)"        "${S_RUN}"    "${N_RUN}"
    printf "%-30s %-20s %-20s\n" "平均拉取延迟 (s)"       "${S_LAT}"    "${N_LAT}"
    printf "%-30s %-20s %-20s\n" "吞吐量 (req/s)"         "${S_TP}"     "${N_TP}"
    printf "%-30s %-20s %-20s\n" "成功请求数"              "${S_SUCC}"   "${N_SUCC}"
    printf "%-30s %-20s %-20s\n" "失败请求数"              "${S_FAIL}"   "${N_FAIL}"
    printf "%-30s %-20s %-20s\n" "总存储空间"              "${S_TOT_H}"  "${N_TOT_H}"
    printf "%-30s %-20s %-20s\n" "  原始blobs目录"         "${S_BLOBS}"  "${N_BLOBS}"
    printf "%-30s %-20s %-20s\n" "  文件blobs目录"         "${S_FBLOBS}" "${N_FBLOBS}"
    printf "%-30s %-20s %-20s\n" "  partials目录"          "${S_PARTS}"  "${N_PARTS}"
    printf "%-30s %-20s %-20s\n" "推送数据量 (bytes)"      "${S_DATA}"   "${N_DATA}"
    printf "%-30s %-20s %-20s\n" "去重率 (x)"              "${S_RATIO}"  "${N_RATIO}"
    echo ""
    echo "--- SimEnc 拉取统计 ---"
    grep -E "Statistics|Successful|Failed|Duration|Transfered|Latency|Throughput|on time" "$RUNLOG_SIMENC" 2>/dev/null
    echo ""
    echo "--- New 拉取统计 ---"
    grep -E "Statistics|Successful|Failed|Duration|Transfered|Latency|Throughput|on time" "$RUNLOG_NEW" 2>/dev/null
} > "$RESULT_FILE"

echo "📝 对比结果已保存: $RESULT_FILE"
echo ""
echo "✅ 对比测试全部完成！"
