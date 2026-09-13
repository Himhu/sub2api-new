# 独立维护与新服务器部署

本项目采用“官方上游源码 + 独立维护分支”的方式维护。官方 Sub2API 源码通过
Git 的 `upstream` 远程保留，我们的余额、倍率、全模型测试和蓝绿部署提交保存在
自己的 GitHub 仓库 `Himhu/sub2api-new` 中。

## 仓库关系

```text
Wei-Shaw/sub2api.git       upstream/main（官方基线）
            │
            └── Himhu/sub2api-new.git  origin/main（我们的发行分支）
```

当前分支可以随时查看官方基线与二开提交的差异：

```bash
git fetch upstream
git log --oneline upstream/main..main
git diff --stat upstream/main...main
```

`upstream/main` 不应直接提交业务修改。需要跟进官方更新时，先创建备份分支，再
在 `main` 上合并官方基线并运行完整测试：

```bash
git fetch upstream
git switch main
git branch backup/before-upstream-$(date -u +%Y%m%d)
git merge --no-ff upstream/main
go test ./backend/internal/service -count=1
pnpm --dir frontend run build
git push origin main --follow-tags
```

如果合并产生冲突，保留二开功能需要的迁移、API 字段和前端组件，并在合并完成后
检查数据库迁移是否仍然按顺序执行。`tools/sync-upstream.sh` 可以执行上述流程的
检查和备份步骤。

## 新服务器部署边界

新服务器使用独立的工作目录、Docker Compose 项目名、数据目录和域名。不要把新服
务器加入现有 `new-api` 的 PostgreSQL 或 Redis 网络，也不要复用现有服务器的
`sub2api` 数据目录。这样升级、回滚和数据库迁移都不会触碰线上旧实例。

建议目录：

```text
/opt/sub2api-new/
├── deploy/.env                 # 仅服务器保存，权限 600
├── deploy/data/                # Sub2API 数据
├── deploy/postgres_data/       # 新实例 PostgreSQL
└── deploy/redis_data/          # 新实例 Redis
```

在新服务器上使用独立 Compose 项目启动：

```bash
cd /opt/sub2api-new/deploy
cp .env.example .env
chmod 600 .env
# 设置随机 POSTGRES_PASSWORD、JWT_SECRET、TOTP_ENCRYPTION_KEY 和域名
docker compose -p sub2api-new -f docker-compose.local.yml up -d
docker compose -p sub2api-new -f docker-compose.local.yml ps
```

生产环境建议先构建并验证镜像，再切换反向代理。蓝绿脚本的 `BASE_DIR`、数据卷、
Docker 网络和 Nginx 配置都可以通过环境变量指定；新服务器不要使用旧服务器的
默认值：

```bash
BASE_DIR=/opt/sub2api-new \
DATA_VOLUME=sub2api-new_sub2api_data \
APP_NETWORK=sub2api-new_sub2api-network \
SHARED_NETWORK=sub2api-new_sub2api-network \
./blue-green-deploy.sh sub2api-new:<版本标签>
```

## 数据迁移

若需要把旧实例迁移到新服务器，先在旧服务器生成 PostgreSQL 备份并停止写入，传输
备份文件后在新实例恢复，再启动新 Sub2API。不要直接复制正在使用的 PostgreSQL
数据目录，也不要把旧服务器的 `.env` 提交到 GitHub。

迁移完成后，用健康检查、管理员登录、账号余额/倍率探测和一条低成本模型请求
验证新实例，确认无误后再把下游（例如 newAPI）切换到新域名或地址。

