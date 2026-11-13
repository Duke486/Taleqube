# SQLite 存储与备份（2026-11-02）

## 当前实现

主存储为 Application Support/AniShelf/library.sqlite（保留升级前的数据目录），使用 WAL、外键约束和 FULL 同步。日常保存不再覆盖 tracking-v1.json，也不再生成整库 .previous 副本。

存储采用关系索引与不可变内容图结合的结构。业务 Swift 模型继续供现有匹配、同步和界面使用，持久化时拆成独立集合：items、deliveries、associations、drafts、snapshots、titles、overviews、translations、history、recommendations。每条根记录引用不可变节点；节点正文使用 SHA-256 内容标识，相同元数据、映射、证据、请求正文与历史状态只保存一次。不同内容的同一平台作品保留不同版本，不以较新元数据覆盖历史。

- roots(collection, key, node)：各业务集合的当前记录。
- nodes(id, payload)：不可变对象、数组、长文本和连续集对应区间。
- edges(parent, child)：对象依赖，受外键约束。
- item_identity(identity, item_id)：跨平台身份对应的稳定本地 UUID。
- state(key, value)：数据库事务代际、迁移完成状态、导入提交标识。

TrackingStore 仍持有业务模型，写入前按 Equatable 比较单条作品、同步任务等内容，只编码变动记录。SQLite 只改动相关根与新增节点；已完成同步历史继续保留。无引用的旧节点在事务内递归回收，历史仍引用的节点保留。连接间通过 data_version 失效节点缓存，资料库提交还校验代际，防止旧窗口覆盖新状态。

连续一对一集对应只有在逐集坐标、证据引用和字段集合完全一致时才编码为区间；读取时还原原数组。特殊对应不压缩为区间。多轮匹配、自动补全集对应、人工锁定和观看规则不变。

诊断迁入 DiagnosticStore/library.sqlite，按事件记录，仍执行现有 24 小时规则。图片仍使用独立缓存，不写入作品数据库正文或默认备份。

## 启动与进度编辑

启动直接打开 SQLite。进度编辑只保留在当前详情中，显式保存才写入资料库和同步队列。放弃、关闭或退出应用会丢弃未保存的编辑。

## 备份格式

系统注册类型 app.anishelf.archive，首选扩展名 .taleqube，兼容 .anishelf。文件打开后进入设置的数据导入确认；若详情正在编辑，先保留详情，关闭后继续导入。

未加密文件是 ZIP：

- manifest.json：格式版本 3、最低读取版本、文件摘要。
- data/roots.jsonl：业务集合索引。
- data/nodes.jsonl：仅被引用的去重内容。

归档格式与 SQLite 的 user_version 独立。归档不包含迁移原文件、废弃节点或重复的顶层历史／推荐，诊断以结构化值保存，不再嵌套 Base64。

可选密码加密整个 ZIP：PBKDF2-HMAC-SHA256、600,000 次、随机 16 字节盐、AES-256-GCM。无密码时保留原有完整备份的明文凭据行为，并在界面说明。错误密码、压缩数据错误、校验不符和截断文件在导入前拒绝。

导出先取得一致的业务快照，在后台生成归档。导入接受 .taleqube 与旧版 .anishelf。备份包含资料库、平台片单、投递与云同步队列、冲突和删除恢复数据、偏好、诊断、平台与 S3 凭据以及加密资料库密钥。恢复云连接后由用户手动启用同步，目标设备使用自己的设备标识。

## 导入恢复

所有数据库内容在同一事务中替换。Keychain 与诊断文件不能加入该事务，因此另有加密的 import-recovery.sealed：恢复密钥写入 Keychain，日志保存导入前凭据、诊断及目标偏好。

启动恢复检查数据库的 import.committed：未提交时还原外部状态；已提交时完成偏好与 AniList 登录镜像。完成后移除恢复日志及密钥。密钥不可读时阻止继续修改资料库，保留恢复文件。

## 验证

Scripts/check-storage.sh 覆盖无损迁移、原文件保留、重复启动、去重、区间还原、历史不可变、新旧格式、密码、损坏文件、迁移失败重试、导入中断恢复及旧节点回收。

StorageChecks 可传 --benchmark，构造 100 部作品、800 条已完成任务与大段匹配证据，比较旧 JSON 与新备份体积，并逐条校验还原结果。这是合成样本，不是用户的 40MB 实际文件。
