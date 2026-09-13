# Sub2API 蓝绿部署

线上部署使用两个应用容器：`sub2api-blue`（8081）和 `sub2api-green`（8082）。Nginx 只代理当前健康的颜色，更新时备用容器先启动并通过 `/health` 检查，再热加载 Nginx。旧颜色会继续运行，便于快速回滚。

服务器准备好新镜像后执行：

```bash
/opt/sub2api/blue-green-deploy.sh sub2api:<镜像标签>
```

回滚到另一个健康颜色：

```bash
/opt/sub2api/blue-green-rollback.sh
```

脚本会复用 `/opt/sub2api/.env` 和现有 `sub2api_sub2api_data` 数据卷。不要使用原来的 `docker compose up -d sub2api` 启动单容器；服务器 compose 已将该服务标记为 `legacy`，蓝绿容器由脚本管理。PostgreSQL、Redis 仍由原 compose 管理。
