# B 站本地归档 · 数据包（{{PERIOD}}）

这份数据包由 `share.ps1` 从本地归档导出，**只读**，不含私信、不含登录态、不含任何凭据。

## 文件

| 文件 | 内容 |
|---|---|
| `watch.jsonl` | 本段时间窗内的观看记录，一行一条 |
| `favorites.jsonl` | 本段时间窗内收藏的条目（仅在导出时开启该选项才存在） |
| `summary.json` | 聚合统计（小时数、Top UP、分区分布） |
| `manifest.json` | 文件清单与 SHA256，用于校验完整性 |
| `README.md` | 本文件 |

## 字段

### watch.jsonl

| 字段 | 类型 | 说明 |
|---|---|---|
| `time` | int | 观看时刻，Unix 秒 |
| `bvid` / `aid` | string / int | 视频标识 |
| `title` | string | 标题（失效后可能是"已失效视频"） |
| `up` / `up_mid` | string / int | UP 主昵称与 UID |
| `tag` | string | 分区名 |
| `duration` | int | **视频总长**（秒），不是观看时长 |
| `progress` | int | 看到第几秒；`null` 表示未知 |
| `completion` | float | `progress / duration`，上限 1；未知为 `null` |
| `completed` | bool | `completion >= 0.9` |

### favorites.jsonl

| 字段 | 类型 | 说明 |
|---|---|---|
| `time` | int | 收藏时间，Unix 秒 |
| `bvid` / `aid` / `title` / `up` / `up_mid` | — | 同 watch.jsonl |
| `folder` | string | 所在收藏夹 |
| `invalid` | bool | 导出时该条目是否已失效 |

## 读取建议

1. 用 `bvid` 作主键，缺失时退回 `aid`，再退回 `title`。
2. `duration` 求和**不是**观看时长；观看时长用 `progress` 求和。
3. 数组不保证按时间排序，读取方自行排序。
4. 同一 `bvid` 可能出现多条，那是真看了多次，不是重复数据。

## 不含什么

- 私信内容（本工具设计上不外带）
- 浏览器登录态、cookie、SESSDATA
- 封面图片（版权归原作者，不随包分发）

生成时间：{{GENERATED}}
