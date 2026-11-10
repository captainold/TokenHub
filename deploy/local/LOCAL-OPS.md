# TokenHub 本机运维手册（LOCAL-OPS）

> **给 AI / 运维的人：动这台机器上的 TokenHub 之前，先读完本文件。**
> 机器：`DELL_7680`（Windows 11 + Docker Desktop）　最后核对：2026-11-10

## 0. 一句话

本机 TokenHub 是**手工 `docker run` 起来的单容器**，**不是** docker compose 管理的服务。
启动只有两条正确路径：

```bash
docker start tokenhub-backend        # 容器还在（99% 的情况）
bash deploy/local/ops.sh start       # 容器被删了，按环境文件重建
```

## 1. 现状快照

| 项目 | 值 |
| --- | --- |
| 容器名 | `tokenhub-backend` |
| 镜像 | `ghcr.io/astaxie/tokenhub-backend:0.10.0` |
| 版本 | 0.10.0（官方 release 镜像） |
| API 端口 | 宿主机 `8080` → 容器 `8080` |
| 控制台端口 | 宿主机 `3001` → 容器 `3000` |
| 网络 | `tokenhub` |
| 数据卷 | `tokenhub-data` → `/app/data`（SQLite `tokenhub.db`，约 2.2 GB） |
| 插件卷 | `tokenhub-plugins` → `/app/plugins` |
| 发布卷 | `tokenhub-releases` → `/opt/tokenhub` |
| 环境文件 | `C:\Users\wenyu\.tokenhub\local.env`（含密钥，**不要进 git**） |
| 重启策略 | `unless-stopped` |
| 自动升级 | **已关闭**（`TOKENHUB_MANAGED_UPDATES=false`） |
| 对外入口 | LobeHub provider `tokenhub` → `http://127.0.0.1:8080/v1` |

环境变量里没有 `TOKENHUB_IMAGE_TAG`/compose 相关项——镜像版本由 `ops.sh` 顶部的 `IMAGE` 决定。

## 2. 绝对不要做的事（都踩过）

1. **不要在 `deploy/` 下执行 `docker compose up -d` / `down` / `restart`。**
   `deploy/docker-compose.yml` + `docker-compose.override.yml` 会按 `deploy/.env` 重建一个同名容器、
   并把现有容器改名成 `tokenhub-backend-<版本>-bak`。结果是第二套配置（端口映射、密钥、目录都可能不同），
   和本文件描述的运行态不一致，排查会被带偏。
2. **不要 `docker compose down`**：会删容器。
3. **不要两个 AI 会话 / 两个脚本同时操作容器。**
   2026-11-09 就出现过一个会话跑 `th-switch.sh` 停掉容器后没启动新版本，服务空窗 3 小时。
4. **不要在容器运行时直接拷/改 `tokenhub.db`**：先 `ops.sh stop`，再备份，再启动。
5. 不要手工 `docker rename`，除非按第 6 节的回滚流程。

## 3. 常用命令

在仓库根目录（`C:\Users\wenyu\Platform\net\tokenhub`）用 Git Bash 执行：

```bash
bash deploy/local/ops.sh status     # 容器状态 + /healthz
bash deploy/local/ops.sh start      # 启动（容器不存在则按 env 重建）
bash deploy/local/ops.sh stop       # 优雅停止（等待 150s）
bash deploy/local/ops.sh restart    # 重启 + 等健康
bash deploy/local/ops.sh recreate   # 改完 local.env 后重建（数据卷保留）
bash deploy/local/ops.sh verify     # 三件套验收
bash deploy/local/ops.sh logs 120   # 最近 120 行日志
```

## 4. 什么叫「正常」

1. `curl http://127.0.0.1:8080/healthz` → `{"service":"tokenhub-backend","status":"ok"}`
2. 控制台 `http://127.0.0.1:3001` → HTTP 200
3. `ops.sh verify` 的版本接口 → `current_version` 是当前版本
4. 真正跑一次模型（需要用户 API Key）：`POST /v1/chat/completions`，不要只信 `/healthz`

## 5. 升级流程（0.8.0 → 0.10.0 的实战）

1. **先备份**（第 7 节），并保留旧容器：
   `docker rename tokenhub-backend tokenhub-backend-<旧版本>-bak`
2. `docker pull ghcr.io/astaxie/tokenhub-backend:<新版本>`
3. 改 `deploy/local/ops.sh` 顶部 `IMAGE=`，或临时 `TOKENHUB_IMAGE=... bash deploy/local/ops.sh recreate`
4. 等健康检查通过，再 `ops.sh verify`
5. 验收成功后，更新本文件「现状快照」和「变更日志」

> 注意：0.10.0 的入口脚本会把新 release 装到 `tokenhub-releases` 卷并重指 `current`，
> 升级后 `current` 指向 `releases/<版本>`，模型目录也会刷新。旧版本目录会保留在卷里。

## 6. 回滚

0.10.0 可能已改过 SQLite 结构，**回滚要连数据库一起还原**（只换容器不够）：

```bash
bash deploy/local/ops.sh stop
docker rm -f tokenhub-backend

# 用停机备份还原数据卷
MSYS_NO_PATHCONV=1 docker run --rm -v tokenhub-data:/dst -v "C:/Users/wenyu/tmp:/backup" alpine \
  sh -c 'rm -rf /dst/* && tar xzf /backup/tokenhub-data-PRE-SWITCH.tar.gz -C /dst'

docker rename tokenhub-backend-0.8.0-bak tokenhub-backend
docker start tokenhub-backend
```

## 7. 备份

- 数据库本体：卷 `tokenhub-data` 里的 `tokenhub.db`
- 停机备份命令（容器停止状态下执行）：

```bash
MSYS_NO_PATHCONV=1 docker run --rm -v tokenhub-data:/src:ro -v "C:/Users/wenyu/tmp:/backup" alpine \
  sh -c 'cd /src && tar czf /backup/tokenhub-data-<日期>.tar.gz .'
```

- 2026-11-10 现状：升级前的 `tokenhub-data-PRE-SWITCH.tar.gz` 已按老温要求清理，
  回滚锚点只剩容器 `tokenhub-backend-0.8.0-bak`；**下次升级前必须重新做停机备份。**

## 8. 已知外部问题（不是本机故障）

- `ShareAPI`（provider `prv_n4hbBVFheEg9gVgc`，`https://share-api.com/v1`）从本机不可达。
  0.10.0 的主动探测每 5 分钟打印
  `provider monitoring probe failed for prv_n4hbBVFheEg9gVgc: provider_models_timeout`。
  其他 provider 正常；不需要修本机，忽略或在控制台禁用该 provider 即可。

## 9. 变更日志

- 2026-11-10：关闭自动升级（`TOKENHUB_MANAGED_UPDATES=false`）；环境文件迁到 `~/.tokenhub/local.env`；
  新增 `deploy/local/ops.sh` 与本手册；清理升级前备份。
- 2026-11-09：升级到 0.10.0（`th-switch2.sh`），旧容器保留为 `tokenhub-backend-0.8.0-bak`。
- 2026-11-09 上午：`th-switch.sh` 执行到「停容器 + 备份 + 改名」后中断，0.10.0 未启动，服务空窗约 3 小时。