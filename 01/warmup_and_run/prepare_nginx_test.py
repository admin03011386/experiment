#!/usr/bin/env python3
"""
prepare_nginx_test.py
=====================
准备 3 个 NGINX 镜像的 layer 数据，并生成 trace 文件（test_data.json）。

用法（在 Linux 服务器上运行）：
    python3 prepare_nginx_test.py

功能：
    1. 从 Docker Hub 拉取 3 个 NGINX 镜像（不同 tag）
    2. 导出为 tar，解压获取每一层的 layer.tar（即 blob）
    3. 按照 warmup_run.py 期望的目录结构存放 blob
    4. 自动生成 test_data_nginx.json（trace 文件）
"""

import os
import sys
import json
import subprocess
import hashlib
import time
import shutil

# ============ 配置区 ============

# 3 个 NGINX 镜像（使用不同 tag，层之间有大量共享，非常适合测试 dedup）
NGINX_IMAGES = [
    "library/nginx:1.26",
    "library/nginx:1.27",
    "library/nginx:latest",
]

# layer blob 存放路径（和 warmup_run.py 中的 our_data_path_prefix 对应）
DATA_DIR = "/home/simenc3/nginx_test_data"

# 输出 trace 文件名
TRACE_OUTPUT = "test_data_nginx.json"

# ================================


def run_cmd(cmd, check=True):
    """运行 shell 命令"""
    print(f"  [CMD] {cmd}")
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if check and result.returncode != 0:
        print(f"  [ERROR] {result.stderr}")
    return result


def sha256_of_file(filepath):
    """计算文件的 SHA256"""
    h = hashlib.sha256()
    with open(filepath, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()


def prepare_images():
    """
    拉取、导出、解压 NGINX 镜像，提取每层 blob。
    返回: [(repo_name, sha256_hex, blob_path, size), ...]
    """
    all_layers = []

    for image_ref in NGINX_IMAGES:
        # image_ref = "library/nginx:1.24"
        repo_full, tag = image_ref.rsplit(":", 1)
        # repo_name 用于 registry（去掉 library/ 前缀）
        repo_name = repo_full.replace("library/", "") + "_" + tag.replace(".", "-")
        # e.g., "nginx_1-24"

        print(f"\n{'='*60}")
        print(f"处理镜像: {image_ref}  (repo_name={repo_name})")
        print(f"{'='*60}")

        # 1. docker pull
        print(f"[1/4] 拉取镜像 {image_ref} ...")
        run_cmd(f"docker pull {image_ref}")

        # 2. docker save 导出
        tar_path = f"/tmp/{repo_name}.tar"
        print(f"[2/4] 导出镜像到 {tar_path} ...")
        run_cmd(f"docker save {image_ref} -o {tar_path}")

        # 3. 解压提取 layer
        extract_dir = f"/tmp/{repo_name}_extract"
        os.makedirs(extract_dir, exist_ok=True)
        print(f"[3/4] 解压到 {extract_dir} ...")
        run_cmd(f"tar xf {tar_path} -C {extract_dir}")

        # 4. 遍历子目录，找到每一层的 layer.tar
        # Docker save 格式: manifest.json + <layer_hash>/layer.tar
        manifest_path = os.path.join(extract_dir, "manifest.json")
        if not os.path.exists(manifest_path):
            print(f"  [WARN] manifest.json 不存在，尝试 OCI 格式解析...")
            continue

        with open(manifest_path) as f:
            manifest = json.load(f)

        layers = manifest[0].get("Layers", [])
        print(f"[4/4] 发现 {len(layers)} 层")

        for layer_rel_path in layers:
            layer_tar_path = os.path.join(extract_dir, layer_rel_path)
            if not os.path.exists(layer_tar_path):
                print(f"  [SKIP] 层文件不存在: {layer_tar_path}")
                continue

            # 计算该 layer.tar 的 sha256
            digest_hex = sha256_of_file(layer_tar_path)
            file_size = os.path.getsize(layer_tar_path)

            # 放到 DATA_DIR 下按 warmup 期望的结构存放
            # warmup_run.py 期望: {DATA_DIR}/{repo_name}/blobs/sha256/{digest_hex}
            dest_dir = os.path.join(DATA_DIR, repo_name, "blobs", "sha256")
            os.makedirs(dest_dir, exist_ok=True)
            dest_path = os.path.join(dest_dir, digest_hex)

            if not os.path.exists(dest_path):
                shutil.copy2(layer_tar_path, dest_path)
                print(f"  层: sha256:{digest_hex[:16]}... size={file_size} -> {dest_path}")
            else:
                print(f"  层: sha256:{digest_hex[:16]}... size={file_size} (已存在)")

            all_layers.append((repo_name, digest_hex, dest_path, file_size))

        # 清理临时文件
        run_cmd(f"rm -rf {extract_dir} {tar_path}", check=False)

    return all_layers


def generate_trace(all_layers, output_file):
    """生成 test_data_nginx.json trace 文件"""
    trace = []
    base_time = "2026-02-24T10:00:00.000Z"
    from datetime import datetime, timedelta
    t = datetime.strptime(base_time, '%Y-%m-%dT%H:%M:%S.%fZ')

    for i, (repo_name, digest_hex, blob_path, size) in enumerate(all_layers):
        entry = {
            "j_http.request.uri": f"v2/{repo_name}/blobs/sha256:{digest_hex}",
            "j_repo": repo_name,
            "sha_256": f"sha256_{digest_hex}",
            "http.response.written": size,
            "timestamp": (t + timedelta(seconds=i)).strftime('%Y-%m-%dT%H:%M:%S.%fZ'),
            "http.request.duration": 0.1,
            "http.request.remoteaddr": "127.0.0.1",
            "http.request.method": "GET"
        }
        trace.append(entry)

    # 为模拟重复拉取，再追加一遍（测 dedup 效果 + 缓存命中）
    for i, (repo_name, digest_hex, blob_path, size) in enumerate(all_layers):
        entry = {
            "j_http.request.uri": f"v2/{repo_name}/blobs/sha256:{digest_hex}",
            "j_repo": repo_name,
            "sha_256": f"sha256_{digest_hex}",
            "http.response.written": size,
            "timestamp": (t + timedelta(seconds=len(all_layers) + i)).strftime('%Y-%m-%dT%H:%M:%S.%fZ'),
            "http.request.duration": 0.1,
            "http.request.remoteaddr": "127.0.0.1",
            "http.request.method": "GET"
        }
        trace.append(entry)

    with open(output_file, 'w') as f:
        json.dump(trace, f, indent=2)

    print(f"\n✅ Trace 文件已生成: {output_file}")
    print(f"   总请求数: {len(trace)} ({len(all_layers)} 层 × 2 轮)")
    total_size = sum(l[3] for l in all_layers)
    print(f"   总数据量: {total_size / 1024 / 1024:.2f} MB")


def generate_summary(all_layers):
    """打印数据总结"""
    repos = {}
    for repo_name, digest_hex, _, size in all_layers:
        if repo_name not in repos:
            repos[repo_name] = []
        repos[repo_name].append((digest_hex, size))

    print(f"\n{'='*60}")
    print(f"数据准备总结")
    print(f"{'='*60}")

    all_digests = set()
    unique_digests = set()

    for repo_name, layers in repos.items():
        print(f"\n  📦 {repo_name}: {len(layers)} 层")
        for digest_hex, size in layers:
            dup_mark = ""
            if digest_hex in all_digests:
                dup_mark = " ⬅️ 重复(跨镜像共享)"
            else:
                unique_digests.add(digest_hex)
            all_digests.add(digest_hex)
            print(f"     sha256:{digest_hex[:16]}...  {size/1024:.1f} KB{dup_mark}")

    total_layers = len(all_layers)
    unique_layers = len(unique_digests)
    dup_layers = total_layers - unique_layers

    print(f"\n  📊 统计:")
    print(f"     总层数:     {total_layers}")
    print(f"     唯一层数:   {unique_layers}")
    print(f"     重复层数:   {dup_layers} (跨镜像共享)")
    print(f"     理论去重率: {dup_layers/total_layers*100:.1f}%")


if __name__ == "__main__":
    print("🚀 NGINX 镜像测试数据准备工具")
    print(f"   镜像列表: {NGINX_IMAGES}")
    print(f"   数据目录: {DATA_DIR}")
    print()

    # 确保数据目录存在且当前用户有写权限
    if not os.path.exists(DATA_DIR):
        print(f"[INIT] 创建数据目录: {DATA_DIR}")
        ret = os.system(f"sudo mkdir -p {DATA_DIR} && sudo chown $(whoami):$(whoami) {DATA_DIR}")
        if ret != 0:
            print(f"❌ 无法创建数据目录 {DATA_DIR}，请手动执行:")
            print(f"   sudo mkdir -p {DATA_DIR} && sudo chown $(whoami) {DATA_DIR}")
            sys.exit(1)

    # Step 1: 拉取并提取镜像层
    all_layers = prepare_images()

    if not all_layers:
        print("❌ 未提取到任何层，请检查 Docker 是否可用。")
        sys.exit(1)

    # Step 2: 生成 trace 文件
    generate_trace(all_layers, TRACE_OUTPUT)

    # Step 3: 打印总结
    generate_summary(all_layers)

    print(f"\n{'='*60}")
    print(f"✅ 准备完成！后续步骤:")
    print(f"{'='*60}")
    print(f"""
1. 确认 config-nginx.yml 中 data_path_prefix 指向: {DATA_DIR}
2. 启动 Redis:        redis-server
3. 清空旧数据:        redis-cli FLUSHALL && rm -rf /home/simenc3/docker_v2/*
4. 编译 registry:     cd ../simenc && make
5. 启动 registry:     cd bin && ./registry serve config.yaml
6. Warmup (推送):     python3 warmup_run.py -c warmup -i config-nginx.yml
7. 记录存储空间:      du -sh /home/simenc3/docker_v2/
8. 启动客户端代理:    python3 client.py -i 127.0.0.1 -p 8081
9. Run (拉取测试):    python3 warmup_run.py -c run -i config-nginx.yml
10. 查看结果:         cat result_nginx.json
""")
