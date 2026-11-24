# 5muahzc：双路 Gold 6138 / 128 GB / 中国大陆单机生产配置

## 1. 适用前提

- 单台 Linux 服务器运行一个 Discourse 一体化容器，PostgreSQL、Redis、Nginx 与 Rails 同机。
- 40 个物理核心 / 80 个逻辑 CPU、128 GB 内存、1 TB SSD。
- 服务器直接监听 80/443，未叠加宿主机 Nginx、Cloudflare 或其他反向代理。
- 域名已解析到服务器，公网可访问 80/443；使用中国大陆机房时先确认域名备案要求。
- 将本目录完整放在 Discourse Docker 仓库的 `deploy/5muahzc` 下。
- 下文实例名为 `5muawww`，因此实际配置是 `containers/5muawww.yml`。

已有生产实例必须先备份数据库、上传文件和 `containers/5muawww.yml`，再替换配置或重建。不要改变现有实例的数据卷路径。

## 2. 文件清单与可持续升级结构

```text
app.yml                         硬件参数、域名、SMTP、容器资源限制
overlays/
  postgres.tuning.template.yml  PostgreSQL SSD/WAL/并行度调优
  web.tuning.template.yml       Nginx Worker 数调优
  china.mirrors.template.yml    国内包镜像与可选 GitHub 镜像
validate.rb                     配置、资源预算与升级兼容性校验
test_validate.rb                11 个回归测试（含 Pups、Bundler 与覆盖层行为测试）
README.md                       部署、升级和故障处理说明
```

配置由 **7 个官方模板 + 3 个轻量覆盖层**组成，不复制整份官方模板：

- `postgres.template.yml`
- `redis.template.yml`
- `web.template.yml`
- `web.ratelimited.template.yml`
- `web.ssl.template.yml`
- `web.letsencrypt.ssl.template.yml`
- `enable-ruby-yjit.yml`

### 基础镜像如何更新

`base_image` 只由官方模板提供。执行 `./launcher rebuild 5muawww` 时，官方仓库和模板按 `launcher` 的规则更新，构建使用官方当前指定的日期标签。`params.version: latest` 控制 Discourse 应用代码版本，并不控制基础镜像。

本地覆盖层不声明 `base_image`，因此不会把官方基础镜像锁死在某个日期。也不要将其改为浮动的 `discourse/base:latest`。

PostgreSQL 覆盖层自动选择最高版本的 `/etc/postgresql/*/main/postgresql.conf`，不固定 PostgreSQL 18 路径。若未来官方配置缺少目标参数，覆盖层会让构建明确失败，而不是静默跳过调优；此时应检查兼容性，不要绕过报错。

## 3. 资源与可靠性基线

| 项目 | 值 | 说明 |
| --- | --- | --- |
| 容器 CPU / 内存 | 72 / 112 GB | 给宿主机预留 8 个逻辑 CPU 和 16 GB 内存 |
| Web / Sidekiq | 16 / 4 进程 | 每个 Sidekiq 进程 5 个任务线程 |
| Web DB 连接池 | 每进程 8 | 与 PostgreSQL 连接预算联动校验 |
| PostgreSQL 连接预算 | 178 / 200 | `16×8 + 4×5 + 30`，预留 22 个未用额度 |
| Nginx | 16 Worker，每 Worker 8192 连接 | 不按 80 个逻辑 CPU 无节制创建进程 |
| PostgreSQL shared buffers | 16 GB | 配合操作系统页缓存，而非越大越好 |
| PostgreSQL work mem | 16 MB | 每个排序/哈希操作可使用，不是固定预分配 |
| PostgreSQL effective cache | 64 GB | 仅供规划器估算，不会直接分配这些内存 |
| PostgreSQL WAL | 2–8 GB | 减少 SSD 上的检查点峰值 |
| PostgreSQL synchronous commit | on | 优先避免崩溃丢失近期已提交内容 |
| PostgreSQL parallel workers | 16 / 每次查询最多 4 | 避免 Pups 参数名前缀替换冲突 |
| Redis | 4 个 I/O 线程 | 未配置会驱逐 Sidekiq 队列任务的 LRU |
| Docker 日志 | 100 MB × 5 | 防止 json-file 日志无限增长 |

这些数值是中大型社区的初始生产基线，不是所有访问量下永远固定的最优值。

## 4. 必填修改

编辑 `deploy/5muahzc/app.yml`，至少替换：

1. `DISCOURSE_HOSTNAME`：真实论坛域名，不能使用裸 IP。
2. `DISCOURSE_DEVELOPER_EMAILS`：管理员邮箱，多个邮箱用英文逗号分隔。
3. `DISCOURSE_SMTP_ADDRESS`、`DISCOURSE_SMTP_USER_NAME`、`DISCOURSE_SMTP_PASSWORD`。
4. `DISCOURSE_NOTIFICATION_EMAIL`：通知发件地址，并完成 SMTP 服务商要求的发件域名验证。

默认按 SMTP **587/STARTTLS** 配置。若服务商明确要求 **465 隐式 TLS**，将端口改为 465，并启用 `DISCOURSE_SMTP_FORCE_TLS: true`。校验器会检查这一组合。不要设置 `DISCOURSE_SKIP_EMAIL_SETUP` 来绕过生产邮件校验。

### 国内网络

- RubyGems 使用清华镜像，pnpm 使用 npmmirror。
- `GITHUB_MIRROR` 默认留空，使用 GitHub 官方源。可填写自己信任的 HTTPS 完整替换前缀，例如 `https://your-mirror.example/https://github.com/`。
- 若日志出现 `GnuTLS, handshake failed` 或 `TLS connection was non-properly terminated`，说明当前 Git 连接或代理的 TLS 会话中断。先改用直连；直连不可用时换自己可控的稳定代理，不要反复重试同一故障镜像。
- `GITHUB_MIRROR` 只影响 Git 地址替换，**不影响 Docker Hub，也不影响官方 Let’s Encrypt 模板从 `raw.githubusercontent.com` 下载文件**。
- Docker Hub 或 raw GitHub 无法访问时，应在宿主机/构建网络中配置可信镜像或出站代理，不要使用来源不明的第三方代理，也不要重新复制整份官方模板。

## 5. 新实例或此前 bootstrap 失败的实例

以下命令在 Discourse Docker 仓库根目录执行，例如 `~/discourse_docker`：

```bash
# 1. 先编辑 app.yml，填好真实域名和 SMTP，再运行检查
ruby deploy/5muahzc/test_validate.rb
ruby deploy/5muahzc/validate.rb --source

# 2. 生成实例实际读取的配置
cp deploy/5muahzc/app.yml containers/5muawww.yml
chmod 600 containers/5muawww.yml
ruby deploy/5muahzc/validate.rb --app containers/5muawww.yml

# 3. Redis 需要宿主机启用内存 overcommit
sysctl -w vm.overcommit_memory=1

# 4. 构建并启动
./launcher bootstrap 5muawww
./launcher start 5muawww
```

并在 `/etc/sysctl.conf` 中添加或修改以下已有项，避免重启后失效；不要重复追加同名配置：

```conf
vm.overcommit_memory = 1
```

- `--source` 强制检查源目录中的 `app.yml`，不会误查已有实例配置。
- `--app containers/5muawww.yml` 检查实例真正读取的文件。
- `--allow-placeholders` 只用于编辑前的静态检查；正式部署不能使用它跳过必填值。
- Ruby 命令只检查配置，不会启动服务。
- 如果这是已有生产实例，不要重复 bootstrap，按下一节执行 rebuild。

## 6. 已有实例更新与日常升级

先备份，再将填写好真实生产值的源配置复制到实例配置，然后执行：

```bash
ruby deploy/5muahzc/test_validate.rb
ruby deploy/5muahzc/validate.rb --app containers/5muawww.yml
./launcher rebuild 5muawww
```

更新后检查：

```bash
docker stats 5muawww
./launcher logs 5muawww
curl -I https://你的真实域名
```

还应在容器内确认 PostgreSQL 与 Nginx 的实际生效值：

```bash
./launcher enter 5muawww
su - postgres -c 'psql discourse -c "SHOW shared_buffers; SHOW max_connections; SHOW max_parallel_workers_per_gather; SHOW random_page_cost;"'
nginx -T | grep -E 'worker_processes|worker_connections'
exit
```

其中 `max_parallel_workers_per_gather` 应为 `4`，Nginx `worker_processes` 应为 `16`。

静态校验无法替代真实构建、SMTP 发信、DNS、证书签发和运行时检查。

## 7. 中文搜索

默认语言为 `zh_CN`，Discourse 会自动采用相应的中文站点默认值。在管理后台搜索设置中启用 `search_tokenize_chinese`，不要仅为中文把 PostgreSQL 默认检索配置改为 `simple`。

若对已有内容启用或更改中文分词，需要重建索引：

```bash
./launcher enter 5muawww
rake search:reindex
exit
```

## 8. 上线后调优与备份

先观察 Web 排队、Sidekiq 队列、进程 RSS、PostgreSQL 连接数和磁盘延迟，再每次小幅调整。

- Web 排队且 CPU 有余量：可从 16 增至 20 或 24，但必须同时调整 `db_max_connections` 并重新通过连接预算校验。
- Sidekiq 队列持续增长而 Web 空闲：优先增加 Sidekiq，不要只增加 Web Worker。
- 内存持续增长：先检查插件和单个 Worker RSS，不要取消 Docker 内存上限来规避 OOM。
- 上传文件、数据库备份和 PostgreSQL 大版本升级临时文件都需预留磁盘空间。
- 备份必须异地保存并定期做恢复演练；1 TB SSD 本身不是备份策略。
