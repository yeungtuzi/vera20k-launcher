# VERA20K Launcher

A small macOS map launcher for [VERA20K](https://github.com/YuriPlanet/vera20k), the
Rust rewrite of *Command & Conquer: Red Alert 2 — Yuri's Revenge*.

It browses **every campaign chapter (original Red Alert 2 and Yuri's Revenge) and
any custom map**, shows the mission briefing, renders a real map preview, and
starts the game straight from the list.

<img src="docs/images/launcher.png" alt="VERA20K Launcher: campaign list, mission briefing and a rendered map preview" width="100%">

> Selecting a Yuri's Revenge chapter: mission title, briefing text and the
> engine-rendered map preview, with one-click launch.

[中文说明](#中文说明)

---

## What it does

- **Lists the original Red Alert 2 campaigns.** The RA2 install keeps each
  chapter's identity inside the map (`[Basic] Briefing=Brief:ALL01`,
  `NextScenario=…`), so the launcher names them from `ra2.csf` — Allied 12
  chapters, Soviet 10 — and orders them by mission number.
- **Lists Yuri's Revenge chapters**, split into Allied / Soviet / co-op, named
  from the YR `MISSIONMD.INI` + `ra2md.csf` tables.
- **Lists custom maps** from any folder you add, plus maps packed inside retail
  MIX archives (`mapsmd03.mix`, `multimd.mix`).
- **Mission text**: title and briefing for the selected chapter, from the table
  that belongs to that chapter's origin (RA2 → `ra2.csf`, YR → `ra2md.csf`,
  a mod → the mod's own tables).
- **Real map previews.** Campaign maps ship no `[PreviewPack]`; the launcher asks
  the engine to dump the radar terrain surface it builds for the in-game minimap
  (whole map, CPU-generated, shroud-free) and caches it as a PNG.
- **Launch** writes a `spawn.ini` and starts the game with `-SPAWN`; campaign vs
  skirmish is decided from the map's own name, so there is no mode or side picker.
  A fullscreen toggle is included.

## Requirements

1. **macOS 13 or newer** on Apple silicon.
2. A **[VERA20K](https://github.com/YuriPlanet/vera20k) checkout** with its
   `map-tool` built:
   ```sh
   cargo build --release --locked -p vera20k --bin map-tool
   ```
   Every archive lookup, mission table read, preview render and launch runs
   through that binary — this project holds no duplicate parser.
3. **Retail game data**: your own *Red Alert 2* and/or *Yuri's Revenge* install.
   No game files are included or redistributed.

## Quick start

```sh
git clone https://github.com/yeungtuzi/vera20k-launcher.git
cd vera20k-launcher

# 1. Build the map library from your installs (one time, re-run when they change)
VERA20K_ROOT=/path/to/vera20k bash prepare_library.sh \
    --yr  "/path/to/Yuris Revenge" \
    --ra2 "/path/to/Red Alert 2" \
    --mod "/path/to/map-or-mod-folder"      # optional

# 2. Build and install the app
VERA20K_ROOT=/path/to/vera20k bash build.sh
```

`build.sh` installs `VERA20K Launcher.app` into `/Applications` (pass a directory to
change that). Without `VERA20K_ROOT` it looks for `../vera20k`.

## The map library

`prepare_library.sh` builds everything the launcher reads under
`~/Library/Application Support/VERA20K-Maps/`:

| Path | Contents |
|---|---|
| `base/` | APFS clone of the YR install — shares blocks with the source, ~no extra space |
| `base-mod/` | the clone plus a mod pack's files on top (when `--mod` is given) |
| `meta-base/` | `MISSIONMD.INI` + `ra2md.csf` from the YR install |
| `meta-ra2/` | `ra2.csf` from the Red Alert 2 install |
| `meta/` | the mod's mission table and CSF |
| `campaign/` | YR chapters, extracted by retail file name |
| `ra2-campaign/` | RA2 chapters, extracted by MIX entry id |
| `packs/` | retail map packs for the "packed" section |
| `previews/` | cached map previews written by the launcher |

Keeping the library outside `~/Downloads` matters: macOS blocks the first access
to protected folders until a human approves it, which hangs any process that
tries.

`prepare_library.sh` also points the engine at `base-mod/` (or `base/`) by writing
`ra2_dir` into the game's `config.toml`, so mod text and rules resolve without
copying files into your install.

## How it works

The window is only a browser. Each action shells out to `map-tool`:

| Launcher action | Command |
|---|---|
| scan folders | `map-tool list <dirs> --mission-ini … --csf …` |
| scan map packs | `map-tool mix <pack>` |
| mission title/briefing | `map-tool info <map> …` |
| packed thumbnail | `map-tool preview <map> --out png` |
| real map preview | `map-tool radar-preview <map> --out png` |
| start a chapter | `map-tool launch <map> …` |

`radar-preview` starts the map once with `RA2_DUMP_RADAR=<path>`; the engine writes
the radar terrain surface (the in-game minimap source) and the launcher stops the
game. No reveal cheats and no screenshot stitching are involved. The cost is one
game launch per map, which is why previews are cached.

## Ordering and naming

1. Original Red Alert 2 chapters (Allied, then Soviet), by mission number.
2. Yuri's Revenge chapters (Allied, Soviet, co-op).
3. Folders and map packs you add, newest folder last.

Maps are deduplicated by mission id: retail ships each chapter twice (in
`Maps01.mix` and `Maps02.mix`). Pack entries with no name are hidden behind the
"unnamed packs" checkbox, because retail stores them under hash ids only.

## Known limits

- Preview generation takes 20–40 s and briefly opens the game window.
- Packed maps have no names in retail data; the launcher shows `map #<id>` for
  them unless the pack is a named custom one.
- The training chapters are hidden: all nine maps carry the same `Brief:TRN01`
  key, so they cannot be told apart.
- Windows and Linux would need their own window layer; this app is macOS only.

## License

GPL-3.0, matching VERA20K — see [LICENSE](LICENSE). The app icon is composed from
the VERA20K project icon (GPL-3.0). *Command & Conquer*, *Red Alert 2* and
*Yuri's Revenge* are trademarks of Electronic Arts; this project is not affiliated
with or endorsed by EA.

---

## 中文说明

macOS 上的 **VERA20K 地图启动器**：浏览原版红警 2 与尤里复仇的**全部战役关卡**和任意
自定义地图，显示任务简报、渲染真实地图预览，并可一键开局。

### 功能

- **原版红警 2 战役**：RA2 的地图自带 `[Basic] Briefing=Brief:ALL01`、`NextScenario=…`，
  启动器据此从 `ra2.csf` 取名并按关卡编号排序（盟军 12 关、苏军 10 关）。
- **尤里复仇战役**：按盟军 / 苏军 / 合作分组，名称来自 YR 的 `MISSIONMD.INI` + `ra2md.csf`。
- **自定义地图**：任意文件夹，以及零售 MIX 包（`mapsmd03.mix`、`multimd.mix`）内的地图。
- **任务文本**：按关卡来源选择对应字符串表（RA2 → `ra2.csf`，YR → `ra2md.csf`，mod → 自己的表）。
- **真实预览**：战役图没有 `[PreviewPack]`；启动器让引擎导出它给小地图用的雷达地形缓冲
  （整图、CPU 生成、无迷雾）并缓存成 PNG。
- **启动**：写 `spawn.ini` 后用 `-SPAWN` 拉起游戏；战役/遭遇战由地图文件名自动判定，
  不需要选模式或阵营，另有全屏开关。

### 使用

```sh
VERA20K_ROOT=/path/to/vera20k bash prepare_library.sh \
    --yr "/path/to/尤里的复仇" --ra2 "/path/to/红警2" --mod "/path/to/地图或mod目录"
VERA20K_ROOT=/path/to/vera20k bash build.sh
```

需要：macOS 13+（Apple silicon）、已编译 `map-tool` 的 vera20k 检出、你自己的正版游戏文件
（本仓库不含任何游戏资源）。

### 说明

- 预览生成会启动一次游戏，约 20–40 秒，之后走缓存。
- 包内地图在零售数据里没有名字（只有哈希 id），默认隐藏。
- 训练关九张图共用同一个 `Brief:TRN01` 键，无法区分，已隐藏。
- 许可证 GPL-3.0，与 VERA20K 一致。
