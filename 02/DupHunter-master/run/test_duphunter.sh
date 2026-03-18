#!/bin/bash
###############################################################################
# DupHunter 单机测试脚本 — 在 Ubuntu (192.168.7.5) 上测量去重率、延迟、吞吐量
# 实验数据: 5 个连续版本的 mysql 镜像
###############################################################################

set -e
HOST_IP="192.168.7.5"

echo "============================================================"
echo "  DupHunter 单机实验  (宿主机: $HOST_IP)"
echo "============================================================"

###############################################################################
# 第 0 步: 前置检查
###############################################################################
echo ""
echo ">>> 步骤 0: 前置检查"
command -v docker >/dev/null 2>&1 || { echo "请先安装 docker"; exit 1; }
command -v redis-cli >/dev/null 2>&1 || { echo "请先安装 redis-tools: sudo apt install redis-tools"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "请先安装 curl"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "请先安装 python3"; exit 1; }
echo "前置检查通过 ✓"

###############################################################################
# 第 1 步: 拉取 5 个 MySQL 镜像到本地
###############################################################################
echo ""
echo ">>> 步骤 1: 拉取 5 个 MySQL 镜像"
MYSQL_VERSIONS=("8.0.32" "8.0.33" "8.0.34" "8.0.35" "8.0.36")
for ver in "${MYSQL_VERSIONS[@]}"; do
    echo "  拉取 mysql:${ver} ..."
    docker pull mysql:${ver}
done
echo "拉取完成 ✓"

###############################################################################
# 第 2 步: 搭建 Redis 集群 (单机 2 节点最小集群)
###############################################################################
echo ""
echo ">>> 步骤 2: 搭建 Redis 集群"

# 清理旧容器
docker rm -f redis-7000 redis-7001 2>/dev/null || true

# 创建配置目录
mkdir -p /tmp/redis-cluster/7000 /tmp/redis-cluster/7001

# 生成 Redis 配置
for PORT in 7000 7001; do
cat > /tmp/redis-cluster/${PORT}/redis.conf <<EOF
port ${PORT}
cluster-enabled yes
cluster-config-file nodes-${PORT}.conf
cluster-node-timeout 5000
appendonly yes
bind 0.0.0.0
protected-mode no
EOF
done

# 启动 Redis 节点
docker run -d --name redis-7000 --net=host \
  -v /tmp/redis-cluster/7000:/data \
  redis:6 redis-server /data/redis.conf

docker run -d --name redis-7001 --net=host \
  -v /tmp/redis-cluster/7001:/data \
  redis:6 redis-server /data/redis.conf

sleep 3

# 创建集群 (至少需要 meet 并手动分配 slot)
# 单机 2 节点无法用 --cluster create，需要手动操作
redis-cli -p 7000 CLUSTER MEET ${HOST_IP} 7001
sleep 2

# 给 7000 分配所有 16384 个 slot
echo "  分配 slots 到 7000 ..."
SLOTS=""
for i in $(seq 0 16383); do
    SLOTS="${SLOTS} ${i}"
done
redis-cli -p 7000 CLUSTER ADDSLOTS ${SLOTS}
sleep 2

echo "  验证集群状态 ..."
redis-cli -p 7000 CLUSTER INFO | head -3

# 同时启动一个普通 Redis 实例给 redigo 连接池使用 (端口 6379)
docker rm -f redis-single 2>/dev/null || true
docker run -d --name redis-single --net=host \
  redis:6 redis-server --port 6379 --protected-mode no --bind 0.0.0.0
sleep 2

echo "Redis 集群搭建完成 ✓"

###############################################################################
# 第 3 步: 构建 DupHunter Registry Docker 镜像
###############################################################################
echo ""
echo ">>> 步骤 3: 构建 DupHunter Registry 镜像"
DUPHUNTER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${DUPHUNTER_DIR}"

echo "  工作目录: ${DUPHUNTER_DIR}"
echo "  开始构建 (这可能需要几分钟) ..."
docker build -t duphunter-registry:latest .
echo "DupHunter Registry 镜像构建完成 ✓"

###############################################################################
# 第 4 步: 启动 DupHunter Registry 容器 (D-server 模式)
###############################################################################
echo ""
echo ">>> 步骤 4: 启动 DupHunter Registry"

# 创建存储和缓存目录
mkdir -p /tmp/duphunter-storage /tmp/duphunter-tmpfs

docker rm -f duphunter-reg 2>/dev/null || true

docker run -d --name duphunter-reg \
  --net=host \
  --mount type=bind,source=/tmp/duphunter-tmpfs,target=/var/lib/registry/docker/registry/v2/pull_tars/ \
  -v /tmp/duphunter-storage:/var/lib/registry \
  -e "REGISTRY_STORAGE_CACHE_HOSTIP=${HOST_IP}" \
  duphunter-registry:latest

sleep 5

# 检查 registry 是否正常运行
echo "  检查 registry 健康状态 ..."
curl -s http://${HOST_IP}:5000/v2/ && echo "  Registry 运行正常 ✓" || echo "  Registry 未就绪，请检查日志: docker logs duphunter-reg"

###############################################################################
# 第 5 步: 配置 Docker daemon 允许 insecure registry
###############################################################################
echo ""
echo ">>> 步骤 5: 配置 Docker daemon (如尚未配置)"
echo "  请确保 /etc/docker/daemon.json 包含:"
echo '  { "insecure-registries": ["192.168.7.5:5000"] }'
echo "  如果修改了，需要 sudo systemctl restart docker"
echo "  (按回车继续，或 Ctrl+C 退出去配置)"
read -r

###############################################################################
# 第 6 步: 推送 5 个 MySQL 镜像到 DupHunter (D-server 模式，带去重)
###############################################################################
echo ""
echo ">>> 步骤 6: 推送 5 个 MySQL 镜像 (D-server 模式 = reqtype slice)"
echo "============================================================"
echo "  记录推送前的存储空间"
echo "------------------------------------------------------------"
du -sh /tmp/duphunter-storage/ 2>/dev/null || echo "  (空目录)"

PUSH_START=$(date +%s%N)

for ver in "${MYSQL_VERSIONS[@]}"; do
    echo ""
    echo "  ---- 推送 mysql:${ver} ----"
    
    # 编码 repo name: typesliceusraddr<addr>reponame<repo>
    # 这会让 DupHunter 服务端解析出 reqtype=SLICE → 执行去重
    ENCODED_REPO="typesliceusraddr${HOST_IP}reponamemysql${ver}"
    
    # tag 镜像
    docker tag mysql:${ver} ${HOST_IP}:5000/${ENCODED_REPO}:${ver}
    
    # 推送并记录时间
    LAYER_START=$(date +%s%N)
    docker push ${HOST_IP}:5000/${ENCODED_REPO}:${ver} 2>&1
    LAYER_END=$(date +%s%N)
    
    LAYER_MS=$(( (LAYER_END - LAYER_START) / 1000000 ))
    echo "  推送 mysql:${ver} 耗时: ${LAYER_MS} ms"
done

PUSH_END=$(date +%s%N)
PUSH_TOTAL_MS=$(( (PUSH_END - PUSH_START) / 1000000 ))

echo ""
echo "============================================================"
echo "  全部 5 个镜像推送完成，总耗时: ${PUSH_TOTAL_MS} ms"
echo "============================================================"

###############################################################################
# 第 7 步: 采集去重率指标
###############################################################################
echo ""
echo ">>> 步骤 7: 采集去重率指标"
echo "============================================================"

# 7a. 计算 原始镜像总大小
echo ""
echo "  [A] 原始镜像大小 (docker images):"
TOTAL_ORIGINAL=0
for ver in "${MYSQL_VERSIONS[@]}"; do
    SIZE_BYTES=$(docker inspect mysql:${ver} --format='{{.Size}}')
    SIZE_MB=$((SIZE_BYTES / 1024 / 1024))
    echo "      mysql:${ver} = ${SIZE_MB} MB"
    TOTAL_ORIGINAL=$((TOTAL_ORIGINAL + SIZE_BYTES))
done
TOTAL_ORIGINAL_MB=$((TOTAL_ORIGINAL / 1024 / 1024))
echo "      原始总大小: ${TOTAL_ORIGINAL_MB} MB"

# 7b. 计算 DupHunter 去重后实际存储
echo ""
echo "  [B] DupHunter 去重后存储 (磁盘上的实际占用):"
DEDUP_SIZE=$(du -sb /tmp/duphunter-storage/ | awk '{print $1}')
DEDUP_SIZE_MB=$((DEDUP_SIZE / 1024 / 1024))
echo "      去重后存储: ${DEDUP_SIZE_MB} MB"

# 7c. 计算去重率
echo ""
echo "  [C] 去重率计算:"
if [ "$TOTAL_ORIGINAL" -gt 0 ]; then
    # 去重率 = 1 - (去重后大小 / 原始总大小)
    DEDUP_RATIO=$(python3 -c "print(f'{(1 - ${DEDUP_SIZE}/${TOTAL_ORIGINAL}) * 100:.2f}')")
    STORAGE_SAVING=$(python3 -c "print(f'{(${TOTAL_ORIGINAL} - ${DEDUP_SIZE}) / 1024 / 1024:.1f}')")
    echo "      去重率: ${DEDUP_RATIO}%"
    echo "      节省空间: ${STORAGE_SAVING} MB"
    echo "      压缩比: $(python3 -c "print(f'{${TOTAL_ORIGINAL}/${DEDUP_SIZE}:.2f}')") : 1"
fi

###############################################################################
# 第 8 步: 采集延迟指标 (拉取延迟)
###############################################################################
echo ""
echo ">>> 步骤 8: 采集拉取延迟指标"
echo "============================================================"

PULL_START=$(date +%s%N)

for ver in "${MYSQL_VERSIONS[@]}"; do
    ENCODED_REPO="typelayerusraddr${HOST_IP}reponamemysql${ver}"
    
    # 先删除本地缓存的已推送镜像
    docker rmi ${HOST_IP}:5000/typesliceusraddr${HOST_IP}reponamemysql${ver}:${ver} 2>/dev/null || true

    # tag一个layer类型的镜像名用于拉取 (需要先推送一个layer版本)
    # 实际上对于拉取，客户端用 typelayer 编码即可
    # 但标准docker pull无法指定repo name格式，所以我们使用curl直接测量
    
    echo ""
    echo "  ---- 拉取 mysql:${ver} 延迟测试 ----"
    
    # 使用 docker 日志中的 NANNAN 指标来获取精确延迟
    # 触发一次 manifest 拉取来获取该镜像的所有层 digest
    MANIFEST_URL="http://${HOST_IP}:5000/v2/typelayerusraddr${HOST_IP}reponamemysql${ver}/manifests/${ver}"
    
    LAYER_PULL_START=$(date +%s%N)
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        "${MANIFEST_URL}")
    LAYER_PULL_END=$(date +%s%N)
    LAYER_PULL_MS=$(( (LAYER_PULL_END - LAYER_PULL_START) / 1000000 ))
    
    echo "      manifest 拉取: HTTP ${HTTP_CODE}, 耗时 ${LAYER_PULL_MS} ms"
done

PULL_END=$(date +%s%N)
PULL_TOTAL_MS=$(( (PULL_END - PULL_START) / 1000000 ))

echo ""
echo "  总拉取测试耗时: ${PULL_TOTAL_MS} ms"

###############################################################################
# 第 9 步: 从 Docker 容器日志中提取精确指标
###############################################################################
echo ""
echo ">>> 步骤 9: 从 Registry 日志提取精确指标"
echo "============================================================"

echo ""
echo "  [推送阶段 - 去重耗时]"
echo "  (Dedup 函数的 Printf 输出):"
docker logs duphunter-reg 2>&1 | grep "NANNAN: Dedup:" | tail -20

echo ""
echo "  [拉取阶段 - 读取耗时明细]"
echo "  (ServeBlob 的 Debugf 输出: mem/ssd/transfer time):"
docker logs duphunter-reg 2>&1 | grep "NANNAN: primary:" | tail -20

echo ""
echo "  [缓存命中/未命中]:"
docker logs duphunter-reg 2>&1 | grep -c "NANNAN: layer cache hit" || echo "0"
echo "  次 cache hit"
docker logs duphunter-reg 2>&1 | grep -c "NANNAN: layer cache miss" || echo "0"
echo "  次 cache miss"

###############################################################################
# 第 10 步: 存储详细分析
###############################################################################
echo ""
echo ">>> 步骤 10: 存储详细分析"
echo "============================================================"

echo ""
echo "  [层级目录结构]:"
du -sh /tmp/duphunter-storage/docker/registry/v2/blobs/ 2>/dev/null || echo "  blobs 目录不存在"
du -sh /tmp/duphunter-storage/docker/registry/v2/repositories/ 2>/dev/null || echo "  repositories 目录不存在"

echo ""
echo "  [Redis 键数统计 - 去重元数据量]:"
echo "    单实例 Redis (6379):"
redis-cli -p 6379 DBSIZE 2>/dev/null || echo "    连接失败"
echo "    集群 Redis (7000):"
redis-cli -p 7000 DBSIZE 2>/dev/null || echo "    连接失败"

echo ""
echo "  [各层大小明细]:"
if [ -d "/tmp/duphunter-storage/docker/registry/v2/blobs/sha256" ]; then
    find /tmp/duphunter-storage/docker/registry/v2/blobs/sha256 -name "data" -exec ls -lh {} \; | \
        awk '{print $5, $NF}' | sort -rh | head -20
fi

###############################################################################
# 汇总报告
###############################################################################
echo ""
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║            DupHunter 实验结果汇总报告                   ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║ 实验配置                                                ║"
echo "║   宿主机: ${HOST_IP}                              ║"
echo "║   镜像: mysql 8.0.32 ~ 8.0.36 (5个版本)                ║"
echo "║   模式: D-server (文件级去重)                           ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║ 1. 去重率                                               ║"
echo "║    原始总大小:    ${TOTAL_ORIGINAL_MB} MB"
echo "║    去重后存储:    ${DEDUP_SIZE_MB} MB"
if [ "$TOTAL_ORIGINAL" -gt 0 ]; then
echo "║    去重率:        ${DEDUP_RATIO}%"
fi
echo "╠══════════════════════════════════════════════════════════╣"
echo "║ 2. 推送延迟                                             ║"
echo "║    5个镜像总推送耗时: ${PUSH_TOTAL_MS} ms"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║ 3. 拉取延迟                                             ║"
echo "║    5个镜像总拉取耗时: ${PULL_TOTAL_MS} ms"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║ 4. 详细日志请查看:                                      ║"
echo "║    docker logs duphunter-reg 2>&1 | grep NANNAN         ║"
echo "╚══════════════════════════════════════════════════════════╝"

echo ""
echo ">>> 实验完成! <<<"
