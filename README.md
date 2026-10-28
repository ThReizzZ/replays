# gokz-replays 可编译工程

仓库：<https://github.com/ThReizzZ/replays>

GOKZ Replays 插件（CS:GO KZ 服务器）的源码工程，对应上游
[KZGlobalTeam/gokz](https://github.com/KZGlobalTeam/gokz) v3.8.0（commit `3a601e1`）。
入口文件与子文件基于上游 v3.8.0，并在此基础上做了以下功能修改。

## 对上游的修改

**界面调整**：回放菜单模式顺序改为 **KZT → SKZ → VNL**；回放控制菜单新增 **前进 1 秒 / 回退 1 秒**。

1. **保存所有玩家的个人最快录像**
   - 每名玩家在每个槽位（地图 + 课程 + 模式 + 风格 + Pro/Nub）只保留最新 PB，新 PB 覆盖旧文件。
   - 破服务器纪录时，同时更新服务器纪录录像和该玩家的 PB 录像。
   - PB 追不上的判定按 Pro/Nub 分别追踪，结束时按最终时间类型决定保存哪一份。

2. **录像存储与旧文件完全隔离**（旧录像不读、不写、不显示）
   ```
   data/gokz-replays/_v3/server/<地图>/<课程>_<模式>_<风格>_<PRO|NUB>.replay
   data/gokz-replays/_v3/players/<地图>/<SteamID>/<课程>_<模式>_<风格>_<PRO|NUB>.replay
   data/gokz-replays/_v3/temp/<地图>/...
   ```
   旧的 `data/gokz-replays/_runs/` 保持原样，留给服务器上其它功能使用。二进制格式仍是 v2，无需迁移。
   `_cheaters`、`_jumps` 行为不变。

3. **新菜单**：`sm_replay` → 选择模式（KZT/SKZ/VNL）→ 主菜单
   - **服务器记录**：各课程的 Pro / Nub 服务器纪录。
   - **个人记录**：自己的各课程 Pro / Nub 最快录像。
   - **服务器所有记录**：Pro / Nub 二级菜单，列出该模式所有玩家的 PB，按时间排序。
   - 条目显示玩家名 + 时间；选中后复用原回放 bot 逻辑。

4. 新增菜单翻译（英文 + 简体中文），位于 `translations/gokz-replays.phrases.txt`。

## 目录结构

| 路径 | 说明 |
| --- | --- |
| `gokz-replays.sp` | 插件入口（全局状态 + 事件分发） |
| `gokz-replays/` | 8 个功能子文件：recording、playback、controls、replay_menu、replay_cache、nav、api、commands |
| `include/` | GOKZ 公共 API 与第三方头文件（dhooks、movementapi、json、GlobalAPI 等，来自上游仓库） |
| `tools/sourcemod/` | SourceMod 1.11.0.6970 的 `spcomp64` 与官方 include（仅编译用） |
| `gamedata/gokz-replays.games.txt` | 运行时签名：`CCSGameRules::TeamFull` detour、`BotDuck` 补丁 |
| `translations/` | 插件加载的翻译文件（gokz-common、gokz-replays） |
| `maps/gokz-replays.nav` | 地图缺少 `.nav` 时复制过去，保证回放 bot 能出生 |
| `build/` | 编译输出目录 |
| `build.sh` | 构建脚本 |

## 构建

```sh
./build.sh
```

输出 `build/gokz-replays.smx`。编译器是 64 位的 `spcomp64`，**不需要 i386 运行库**。
脚本可以在任意目录执行，路径按脚本所在目录解析；也可用 `OUT_DIR=... ./build.sh` 指定输出目录。

## 部署到服务器

| 工程文件 | 服务器位置 |
| --- | --- |
| `build/gokz-replays.smx` | `addons/sourcemod/plugins/` |
| `gamedata/gokz-replays.games.txt` | `addons/sourcemod/gamedata/` |
| `translations/*.phrases.txt` | `addons/sourcemod/translations/` |
| `maps/gokz-replays.nav` | `maps/` |

运行依赖：128 tick、SourceMod >= 1.11、DHooks >= 2.2.0、MovementAPI >= 2.4.2，
以及 GOKZ 插件套件（本插件依赖 gokz-localranks，配合 gokz-localdb、gokz-hud、gokz-jumpstats 使用）。

## 升级上游

用上游对应版本的 `gokz-replays.sp`、`gokz-replays/`、`include/`、`gamedata/`、`translations/`
覆盖即可。工程保持平铺结构，编译时通过 `-i` 显式指定 `include/` 和 SourceMod 官方 include。
