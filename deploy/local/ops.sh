#!/usr/bin/env bash
# TokenHub 本机运维脚本（Windows + Docker Desktop，在 Git Bash 中运行）。
# 手册：deploy/local/LOCAL-OPS.md  ← 操作这个实例前先读
# 设计原则：本实例由手工 docker run 管理，本脚本绝不调用 docker compose。
set -euo pipefail
export MSYS_NO_PATHCONV=1

NAME="${TOKENHUB_CONTAINER:-tokenhub-backend}"
IMAGE="${TOKENHUB_IMAGE:-ghcr.io/astaxie/tokenhub-backend:0.10.0}"
ENVF="${TOKENHUB_ENV_FILE:-$HOME/.tokenhub/local.env}"
NETWORK="${TOKENHUB_NETWORK:-tokenhub}"
PORTS=(-p 8080:8080 -p 3001:3000)
VOLUMES=(-v tokenhub-data:/app/data -v tokenhub-plugins:/app/plugins -v tokenhub-releases:/opt/tokenhub)

die() { echo "错误: $*" >&2; exit 1; }
exists()  { docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; }
running() { docker ps    --format '{{.Names}}' | grep -qx "$NAME"; }

load_env() {
  [ -f "$ENVF" ] || die "找不到环境文件 $ENVF（见 LOCAL-OPS.md 第 1 节）"
  ENVARGS=()
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    case "$line" in *=*) ENVARGS+=(-e "$line") ;; esac
  done < "$ENVF"
  [ "${#ENVARGS[@]}" -gt 0 ] || die "环境文件为空: $ENVF"
}

wait_healthy() {
  local i
  for i in $(seq 1 90); do
    if curl -fsS -m 3 http://127.0.0.1:8080/healthz 2>/dev/null | grep -q '"ok"'; then
      echo "✅ 健康检查通过（第 ${i} 次尝试）"
      return 0
    fi
    sleep 2
  done
  echo "❌ 180 秒内未就绪，最近日志：" >&2
  docker logs --tail 60 "$NAME" >&2 || true
  return 1
}

create() {
  load_env
  docker run -d --name "$NAME" --restart unless-stopped --network "$NETWORK" \
    "${PORTS[@]}" "${ENVARGS[@]}" "${VOLUMES[@]}" "$IMAGE"
}

case "${1:-status}" in
  start)
    if running; then echo "$NAME 已在运行"; exit 0; fi
    if exists; then docker start "$NAME"; else echo "容器不存在，按 $ENVF 重建"; create; fi
    wait_healthy ;;
  stop)
    exists || die "容器 $NAME 不存在"
    docker stop -t 150 "$NAME" ;;
  restart)
    exists || die "容器 $NAME 不存在"
    docker stop -t 150 "$NAME"; docker start "$NAME"; wait_healthy ;;
  recreate)
    echo "将用镜像 $IMAGE 和环境文件 $ENVF 重建 $NAME（数据卷不动）"
    if exists; then docker rm -f "$NAME" >/dev/null; fi
    create; wait_healthy ;;
  status)
    docker ps -a --filter "name=^/${NAME}$" --format '{{.Names}} | {{.Image}} | {{.Status}}' || true
    curl -fsS -m 5 http://127.0.0.1:8080/healthz || echo "健康检查未通过" ;;
  verify)
    echo "[1/3] 后端 /healthz"; curl -fsS -m 5 http://127.0.0.1:8080/healthz || { echo; die "健康检查失败"; }; echo
    echo "[2/3] 控制台 3001"
    code=000
    for i in 1 2 3 4 5 6; do
      code=$(curl -s -m 5 -w '%{http_code}' http://127.0.0.1:3001 | tail -c 3 || true)
      if [ "$code" = "200" ]; then break; fi
      sleep 2
    done
    echo "HTTP $code"
    if [ "$code" != "200" ]; then die "控制台未就绪（$code）"; fi
    echo "[3/3] 版本信息"
    token=$(grep -E '^TOKENHUB_ADMIN_TOKEN=' "$ENVF" | head -1 | cut -d= -f2-)
    curl -fsS -m 10 -H "Authorization: Bearer $token" http://127.0.0.1:8080/api/admin/system/version | cut -c1-400; echo ;;
  logs) docker logs --tail "${2:-80}" "$NAME" ;;
  *)
    cat <<EOF
用法: bash ops.sh <命令>
  status    容器状态 + /healthz
  start     启动（容器不存在则按环境文件重建）
  stop      优雅停止（150s）
  restart   stop + start + 等健康
  recreate  删除并按环境文件重建（数据卷保留）
  verify    健康 + 控制台 + 版本 三件套
  logs [n]  最近 n 行日志（默认 80）
禁止: docker compose up/down（见 LOCAL-OPS.md 第 2 节）
EOF
    exit 1 ;;
esac