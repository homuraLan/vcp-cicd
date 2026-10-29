# 服务端部署

`update-server.sh` 使用镜像内代码和依赖，不再重置宿主 Git checkout 或删除宿主文件。需要 Python 3、Docker Compose 2.24.4+。脚本先检查配置并创建缺失的知识库目录，再切换镜像；已有文件内容、目录所有者和权限保持原样。

| 环境变量 | 默认值 | 用途 |
| --- | --- | --- |
| `DEPLOY_DIR` | 必填 | 现有生产部署目录 |
| `TARGET_IMAGE` | 必填 | 镜像引用；同标签重新构建也比较实际镜像 ID |
| `KNOWLEDGE_SOURCE_DIR` | `DEPLOY_DIR/knowledge` | 宿主知识库原文目录 |
| `TDB_STORE_DIR` | `DEPLOY_DIR/VectorStoreTDB` | 宿主冷知识库数据库目录 |
| `RAG_PARAMS_FILE` | `DEPLOY_DIR/rag_params.json` | 已存在的 RAG JSON 配置文件 |
| `TDB_KNOWLEDGE_ROOT_PATH` | 生产 `config.env` 同名值，否则 `/usr/src/app/knowledge` | 容器知识库目录 |
| `TDB_KNOWLEDGE_STORE_PATH` | 生产 `config.env` 同名值，否则 `/usr/src/app/VectorStoreTDB` | 容器数据库目录 |
| `HEALTH_URL` | 不设置 | 可选外部入口检查；容器内主服务、管理服务和知识库挂载始终检查 |
| `INTERVAL_H` | `168` | 自动更新间隔，`0` 关闭自动更新 |
| `FORCE` | `0` | `1` 忽略间隔并重建容器，也用于重新加载修改后的生产 `config.env` |

宿主相对路径以 `DEPLOY_DIR` 为基准；容器相对路径以 `/usr/src/app` 为基准。容器路径优先使用显式环境变量，再读生产 `config.env`；渲染后的挂载目标和容器环境变量使用同一个值，普通 `docker compose up` 也不需要重新提供这些变量。原文与数据库目录不能相互嵌套，容器挂载也不能遮盖代码、依赖或已有配置/数据挂载。

`TDB_KNOWLEDGE_ENABLED`、`TDB_KNOWLEDGE_MODEL`、`TDB_KNOWLEDGE_DIMENSION`、`API_URL`、`API_Key` 均来自生产 `config.env`。部署脚本不设置模型、维度或凭据。

修改模型时，`TDB_KNOWLEDGE_DIMENSION` 必须匹配该 embedding 接口实际返回的维度。已有数据库更换模型或维度时，请指定新的 `TDB_STORE_DIR` 重建，并保留旧库用于回退，避免混用不同模型或维度的向量。然后使用 `FORCE=1` 部署重新加载配置。

通过 GitHub Actions 部署时，可在仓库 **Settings → Secrets and variables → Actions → Variables** 配置可选的 `VCP_KNOWLEDGE_SOURCE_DIR`、`VCP_TDB_STORE_DIR`、`VCP_RAG_PARAMS_FILE`、`VCP_TDB_KNOWLEDGE_ROOT_PATH`、`VCP_TDB_KNOWLEDGE_STORE_PATH`；工作流分别转发给表中对应的无 `VCP_` 前缀变量。留空使用上述默认值。

新增目录继承已有 `knowledge` 目录的所有者和权限；原文目录也不存在时参考 `dailynote`，再回退至部署目录。已有目录不修改权限。`rag_params.json` 必须是已存在且有效的 JSON 对象；缺失时部署中止，Docker 不会把文件路径创建成目录。

每次部署把原 override 和旧镜像 ID/本地回滚标签保留在 `.deploy-backup/server-*`。拉取前先固定旧镜像，避免同标签新镜像覆盖回滚目标。重建或健康检查失败会恢复原 override、旧镜像标签并重新启动旧版本；不会回滚或删除用户数据。备份和本地回滚标签保留供人工清理。

`HEALTH_ATTEMPTS`（默认 40）和 `HEALTH_DELAY_SECONDS`（默认 3）可调整就绪等待。健康检查要求主服务与管理服务都可响应，不能仅凭管理页的 302 判定部署成功。

冷知识库启用时，健康检查还会使用生产 `AdminUsername` / `AdminPassword` 在容器内读取主服务的内存状态接口，要求 `tdbKnowledge.enabled`、`initialized` 和 `metaDb.open` 均为真，且维度与配置一致。因此启用冷库时需配置这两个管理员字段；凭据只在容器内存中用于认证，不会打印或写入部署模板。
