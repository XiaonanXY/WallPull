<div align="center">

# WallPull

**Wallpaper Engine（小红车）壁纸提取、壁纸下载与本地管理、PKG/TEX 壁纸解析解包、视频原图导出、图层拆解与 iPad 互传工具**

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](./LICENSE)
![Platform](https://img.shields.io/badge/Platform-Windows%2010%2F11%20x64%20%7C%20iPadOS%2015.4%2B-0078D6)
![Stack](https://img.shields.io/badge/Stack-Rust%20%2B%20React%2019%20%7C%20SwiftUI-7C3AED)
![Author](https://img.shields.io/badge/Author-Xiaonan-18181B)
[![交流反馈](https://img.shields.io/badge/交流反馈-471426180-12B7F5)](https://qm.qq.com/q/aYrBqaDlDi)

</div>

> [!WARNING]
> **永久免费开源 · 严禁倒卖声明**
>
> 本项目（WallPull）由作者 **Xiaonan** 基于 **GNU GPL-3.0** 协议在 GitHub 免费开源发布，**作者从未且永不授权任何个人或商家在闲鱼、淘宝、拼多多、QQ/微信付费群、网盘代下等渠道倒卖、捆绑或修改后闭源售卖**。
>
> 如果你是花钱买到本软件的，请**立刻申请退款并举报卖家**！欢迎在 GitHub 点亮 Star 防止迷路。

---

## 核心亮点一眼看懂

- **绿色单文件，双击即用**：Rust 原生桌面底座 + 内嵌前端资源，Windows 端单文件约 `12 MB`，无需安装 .NET 等繁重运行库，自动全盘识别本机 Steam 创意工坊目录。
- **纯 Rust 原生硬核解包**：无需借助外部工具，直接解析 `scene.pkg` 与 `.tex` 贴图（含 LZ4 / DXT 解码与精灵图集切分），甚至能在**透视拆解台**里单独开关人物/背景图层、一键去背景导出纯透明立绘 PNG。
- **零中转复制发图发视频**：卡片右键「复制原图 / 复制原视频」，直接在微信、QQ 等聊天窗口 `Ctrl+V` 粘贴发出原片，不用再打开导出文件夹翻找。
- **内置超级工具箱（3 套工作台形态）**：集成了收藏一键本地永久典藏（防原作者删库跑路）、重复壁纸安全清理、创意工坊跨盘 `mklink /J` 无感迁移、图片/音视频全格式转换，以及大视频 H.265 瘦身压缩。
- **WallPull iPad 原生随身端（iPadOS 15.4+）**：同仓内置纯净 SwiftUI + UIKit 原生平板客户端（`ipad/`），通过独立高速局域网频段与 Windows 端互联（与 LocalSend 彻底隔离），支持一键全部收入、无损剪贴板直推送微信、壁纸配乐电台及 2D 透视离线拆图。

---

## 界面与功能全览

> 以下全部画面均来自 **WallPull 正式版实机运行截图与录屏**，按「画廊总览 → 检索与动效 → 快捷分享 → 详情与格式导出 → 透视拆解 → 超级工具箱 → 设置与布局」顺序带你完整过一遍所有功能：

### 01 · 本机壁纸画廊总览

<p align="center">
  <img src="./docs/showcase/01-library-overview.png" alt="WallPull 本机壁纸主界面总览" width="100%" />
</p>

启动后自动发现本机所有 Steam 库下的 Wallpaper Engine（App ID `431960`）工坊壁纸并完成分类计数。列表卡片自动打上 **「可拆图层」**、**「多张原画」**、**「配乐」** 及视频时长角标；顶部右侧为默认的 **「胶囊工具岛」**，一排直达「工具箱」、「扫描」、明暗外观切换与「设置」。

---

### 02 · 多维筛选与排序浮层

<p align="center">
  <img src="./docs/showcase/02-filter-and-sort.png" alt="多维筛选与排序面板" width="100%" />
</p>

配合顶部 `Ctrl+F` 标题/工坊 ID 即时搜索，展开 **「筛选与排序」** 后支持按占用空间/分辨率/名称排序，以及 **4K+ 超清、横屏宽幅、竖屏立绘、含配乐、可拆图层、全年龄安全/限制级分级、六色主色调** 进行组合定位，海量壁纸库也能一秒找到目标。

---

### 03 · 悬浮交互模式一：全息 3D 倾斜与视频预览

<p align="center">
  <img src="./docs/showcase/03-card-holo-tilt.gif" alt="全息 3D 倾斜卡片动效与四角准星锁定" width="402" />
</p>

指针移入壁纸卡片时，四角准星框自动吸附锁定卡片；**「全息 3D 倾斜」** 会随光标位置产生细腻的立体倾角与镜面高光追踪。视频卡片会在悬停时无缝预览画面，切页或点开大图继续从当前进度续播。

---

### 04 · 悬浮交互模式二：磁吸弹性跟随与点击火花微交互

<p align="center">
  <img src="./docs/showcase/04-card-magnet-spark.gif" alt="磁吸跟随、点击火花与左上多选右上收藏交互" width="580" />
</p>

不喜欢 3D 旋转时可在设置中切为 **「磁吸弹性跟随」**，卡片随鼠标柔和牵引并弹性回弹。画面任意点击触发可自定义尺寸与主题色的粒子火花；卡片左上角支持弹簧多选打勾（`Shift` 连选 / `Ctrl` 跨页多选），右上角红心按钮一键收藏。

---

### 05 · 选中边框动画一：环绕流光

<p align="center">
  <img src="./docs/showcase/05-selection-border-snake.gif" alt="选中壁纸后的环绕流光边框动画" width="466" />
</p>

多选勾选壁纸准备批量导出或删除时，默认启用 **「环绕流光」** 边框特效——流光沿着卡片圆角边界顺时针持续游走，既醒目又不遮挡预览画面。

---

### 06 · 选中边框动画二：旋转边框

<p align="center">
  <img src="./docs/showcase/06-selection-border-orbit.gif" alt="选中壁纸后的旋转边框动画" width="450" />
</p>

也可随时在设置里切换为 **「旋转边框」** 模式，高对比度旋转光环让当前选中项一目了然；下方浮起简洁的批量操作胶囊栏，可一键全选当前页、取消收藏、另存或导出全部。

---

### 07 · 卡片右键快捷菜单

<p align="center">
  <img src="./docs/showcase/07-context-menu.png" alt="卡片右键快捷菜单" width="100%" />
</p>

在任意壁纸上右键即可弹出全功能快捷面板：**加入多选、加入/取消收藏、复制原图/原视频、设为桌面壁纸、直接导出原文件、透视拆解台（2D Scene 适用）、打开原文件位置、打开 Steam 创意工坊页面、安全删除壁纸**，常用高频操作一步到位。

---

### 08 · 复制原图 / 原视频直接粘贴发聊天软件

<p align="center">
  <img src="./docs/showcase/08-copy-paste-chat.gif" alt="右键复制原图和原视频直接粘贴发微信演示" width="640" />
</p>

看上一张高清壁纸或动态视频想发给朋友，不用先导出到桌面再打开文件夹拖拽！右键点击 **「复制原图」** 或 **「复制原视频」** 写入系统原生文件剪贴板，切到微信、QQ 或任意聊天输入框按 `Ctrl+V` 直接弹出原件发送（上百 MB 的 4K 原视频同样一秒贴出）。

---

### 09 · 壁纸详情页：内置 BGM 试听导出 & 隐藏差分开关

<p align="center">
  <img src="./docs/showcase/09-detail-bgm-and-switches.png" alt="壁纸详情弹窗：内置配乐播放器与作者隐藏开关面板" width="100%" />
</p>

单击卡片随 3D 翻转进入全比例自适应详情画框（`21:9` 带鱼屏、`16:9`、`4:3`、`1:1`、`9:16` 竖屏均自动贴合零留白）：
- 自动嗅探并列出壁纸内嵌 **BGM 配乐**，支持原地切曲、进度拖动试听，点击 **「导出 BGM / 导出全部」** 直接提取音频原文件；
- 对于带有作者隐藏控制项的壁纸，点开右上 **「隐藏开关」** 面板就能改文字/音效/换装差分，并一键 **「同步到 Wallpaper Engine」** 生效。

---

### 10 · 视频壁纸导出：支持直拷与转码 MP4 / WebM / GIF

<p align="center">
  <img src="./docs/showcase/10-detail-export-video.png" alt="视频壁纸导出格式菜单" width="100%" />
</p>

视频类壁纸除了无损直拷原视频文件外，左下角导出格式菜单直接内置 **MP4（H.264）**、**WebM（VP9）** 以及 **GIF 动图** 选项，拿来发群表情包或留档都非常顺手。

---

### 11 · 图片壁纸导出：无损原图与常见格式自由转换

<p align="center">
  <img src="./docs/showcase/11-detail-export-image.png" alt="图片壁纸导出格式菜单" width="100%" />
</p>

图片与 Scene 解包原画默认提供 **原格式无损提取**，同时支持按需直接转出为 **PNG（无损）**、**JPG（轻量）** 或 **WebP（高压缩）**；详情舞台内还支持滚轮无级放大、鼠标拖拽看局部原画细节，以及多图切换与左右翻页。

---

### 12 · 2D 透视拆解台（Scene Layer Studio）

<p align="center">
  <img src="./docs/showcase/12-scene-layer-studio.png" alt="透视拆解台：百层 2D 图层实时开关与去背景纯立绘导出" width="100%" />
</p>

WallPull 独有的纯 Rust **2D 透视拆解台**（直接解析 `scene.pkg` 图层与骨骼网格，毫秒级开图）：
- 支持切换 **透明棋盘 / 纯黑底 / 纯白底**，右侧可按角色/主体/光效/背景分组开关、独显或逐层勾选（轻松驾驭上百图层的复杂人物包）；
- 点一下 **「去背景纯立绘」** 即可自动剥离背景和氛围特效遮罩；开启左下 **「导出透明立绘时自动裁切周围空白」** 后，可 **一键批量导出全部角色立绘（透明 PNG）**、**导出当前拆解 PNG** 或直接 **复制透明图** 进 PS 等设计软件。

---

### 13 · 超级工具箱（默认 · 全景工作台）

<p align="center">
  <img src="./docs/showcase/13-toolbox-bento.png" alt="工具箱全景工作台界面" width="100%" />
</p>

右上角打开 **工具箱**，默认的 **「全景工作台」** 将六大壁纸库运维与本地媒体工具平铺在一屏内：
1. **收藏典藏（防跑路）**：将 `♥ 收藏` 的壁纸一键脱壳写入独立本地工程（通常位于 `projects/myprojects`），**即便原作者日后下架或自己取消订阅也能长期离线保留**；可随时打开典藏目录，并自由开关主画廊卡片上的 **「已典藏」** 角标。
2. **格式转换**：拖入外部任意图片/视频/音频批量转换（支持 PNG / JPG / WebP / AVIF / ICO 多尺寸图标、MP4 H.264 / H.265 / GIF / 静音视频、MP3 / FLAC / WAV / OGG 提取互转）。
3. **解包 `.pkg` / `.tex` 文件**：不用打开整库，直接选硬盘里单独的 `.pkg` 或 `.tex` 贴图文件快速提取原图与音频。
4. **重复壁纸清理**：智能排查同 ID 或同画面低清冗余订阅，确认后安全移入 **系统回收站**，错删可随时找回。
5. **工坊目录迁移**：当原盘空间告急时，基于 NTFS 目录联接（`mklink /J`）把海量创意工坊壁纸无感搬家到大容量硬盘，Steam 与 Wallpaper Engine 原路径零感知照常读取。
6. **视频体积压缩**：自动筛出超过 35 MB 的高码率大视频壁纸，一键重编码为画质无损感 **H.265 / HEVC** 节省数 GB 磁盘空间（替换前原大视频自动进回收站备份）。

---

### 14 · 超级工具箱（形态二 · 双页工作台）

<p align="center">
  <img src="./docs/showcase/14-toolbox-dual.png" alt="工具箱双页工作台模式" width="100%" />
</p>

顶部可随时免重启热切换至 **「双页工作台」**，把工具箱逻辑清晰地划分为 **「壁纸库管理」** 与 **「外部文件处理」** 两大独立页签，小屏笔记本下也能保持舒展排版。

---

### 15 · 超级工具箱（形态三 · 侧面工作台）

<p align="center">
  <img src="./docs/showcase/15-toolbox-sidebar.png" alt="工具箱侧面工作台模式" width="100%" />
</p>

也可以切换为 **「侧面工作台」**：左侧提供直观的分类导航与任务计数徽标（`收藏典藏`、`空间清理`、`格式转换`、`文件解包`），右侧只聚焦展示当前正在使用的一项功能，界面干净克制。

---

### 16 · 设置中心（上）：目录自动探测、缓存清理与主题配色

<p align="center">
  <img src="./docs/showcase/16-settings-general.png" alt="设置页目录管理、缓存统计与外观主题配置" width="100%" />
</p>

提供全盘 **「自动检测」** 创意工坊路径、`默认导出路径` 自定义、实时的 **本地预览与解包缓存占用统计及一键清理**；外观上支持 **浅色 / 暗色** 切换与 **6 套精选主题强调色**，文字对比度自动适配可读标准。

---

### 17 · 设置中心（下）：动效手感、系统托盘与硬件加速

<p align="center">
  <img src="./docs/showcase/17-settings-performance.png" alt="设置页交互手感与独立显卡硬件加速配置" width="100%" />
</p>

可在设置下方细调 **点击火花尺寸**、**选中边框动画**、**顶栏与设置样式**、**卡片悬浮物理手感** 以及 **关闭窗口时最小化到系统托盘**。内置显卡硬件侦测可识别本机 GPU 与显存容量，默认启用 **独立显卡（GPU）** 渲染与视频硬解，并在显卡驱动异常时提供 **CPU 软件渲染** 兜底。

---

### 18 · 设置形态二：分立按钮 + 右侧常驻抽屉（实时预览对照）

<p align="center">
  <img src="./docs/showcase/18-settings-drawer-layout.png" alt="分立按钮与右侧设置抽屉同屏对照模式" width="100%" />
</p>

在设置中把「顶栏与设置样式」切换为 **「分立按钮 + 右侧抽屉」** 后，右侧无遮罩抽屉常驻打开，左边画廊会自动避让重排——你可以一边调主题色、改 3D 倾斜手感，一边直接对着左边的壁纸实时看变化，所见即所得。

### 19 · 全新毛玻璃视频悬浮 HUD（v1.0.3）

<p align="center">
  <img src="./docs/showcase/34-win-video-player-hud.png" alt="WallPull Windows 新版悬浮毛玻璃视频播放器与独立音量滑块" width="100%" />
</p>

v1.0.3 重写了详情页视频播放器控件：悬浮式 `rgba(15,15,20,0.72)` 磨砂深色胶囊内置高对比进度条、倍速切换（`0.5x`–`2x`）、单键全屏与**鼠标悬停上方垂直展开的静音/音量滑块**，支持滚轮、键盘方向键快进与 `Space` 暂停，全程不遮挡画面边缘。

---

### 20 · 2D 透视拆解台 · 左右拖动原图对比（v1.0.3）

<p align="center">
  <img src="./docs/showcase/35-win-studio-compare.png" alt="WallPull Windows 2D 透视拆解台左右分隔原图对比滑块" width="100%" />
</p>

Windows 与 iPad 双端 **2D 透视拆解台** 同步新增 **「原图对比 / 退出对比」** 可拖动分界滑块，左侧实时对照工坊原图、右侧直观检视当前保留的透明立绘或隐藏开关效果；开启「导出透明立绘时自动裁切周围空白」后仍可一键导出纯净无白边立绘 PNG。

---

## WallPull iPad 随身端实机界面全览（21–41）

> 以下画面全部截取自 **WallPull iPad v1.0.3 实机运行效果**（支持 `iPadOS 15.4+`），覆盖画廊三套画幅布局、4 位配对码跨端鉴权、配乐电台、全屏视频 BGM 提取、2D 透视拆解原图对比与设置中心：

### 21 · iPad 画廊总览（`16:10` 横屏卡片与 `WallPull PC` 实时连接态）

<p align="center">
  <img src="./docs/showcase/21-ipad-gallery-widescreen.png" alt="WallPull iPad 16:10 横屏画廊主界面总览" width="100%" />
</p>

### 22 · iPad 画廊（`原图比例` 按同画幅占比自动聚类对齐）

<p align="center">
  <img src="./docs/showcase/22-ipad-gallery-adaptive-ratio.png" alt="WallPull iPad 原图比例按占比排序聚类" width="100%" />
</p>

### 23 · iPad 画廊（`1:1` 方形五列高密度网格）

<p align="center">
  <img src="./docs/showcase/23-ipad-gallery-square-grid.png" alt="WallPull iPad 1:1 方形五列高密度网格" width="100%" />
</p>

### 24 · 跨端互联「从电脑挑图」（独立高速频段、年龄分级过滤与一键全部收入）

<p align="center">
  <img src="./docs/showcase/24-ipad-lan-pc-catalog.png" alt="WallPull iPad 跨端互联从电脑挑图与年龄分级筛选" width="100%" />
</p>

### 25 · 多维筛选与主色调检索浮层

<p align="center">
  <img src="./docs/showcase/25-ipad-filter-and-sort.png" alt="WallPull iPad 多维规格与主色调筛选浮层" width="100%" />
</p>

### 26 · 壁纸配乐电台浮动迷你胶囊

<p align="center">
  <img src="./docs/showcase/26-ipad-bgm-radio-player.png" alt="WallPull iPad 底部毛玻璃配乐电台播放胶囊" width="100%" />
</p>

### 27 · 静态原画沉浸预览与「复制原图（贴微信）」

<p align="center">
  <img src="./docs/showcase/27-ipad-detail-image-copy.png" alt="WallPull iPad 静态原画详情与复制原图发微信" width="100%" />
</p>

### 28 · Scene 壁纸详情：多曲目 BGM 导出与 2D 透视拆图入口

<p align="center">
  <img src="./docs/showcase/28-ipad-detail-bgm-and-layers.png" alt="WallPull iPad Scene 壁纸详情、BGM 导出与透视拆图" width="100%" />
</p>

### 29 · 动态视频规格与来源元数据详情卡

<p align="center">
  <img src="./docs/showcase/29-ipad-detail-video-info.png" alt="WallPull iPad 动态视频壁纸元数据卡片" width="100%" />
</p>

### 30 · 动态视频全屏播放倍速控制与原生系统分享菜单

<p align="center">
  <img src="./docs/showcase/30-ipad-detail-video-share.png" alt="WallPull iPad 动态视频全屏倍速控制与原生分享菜单" width="100%" />
</p>

### 31 · 相似与重复壁纸离线智能体检

<p align="center">
  <img src="./docs/showcase/31-ipad-duplicate-inspector.png" alt="WallPull iPad 相似与重复壁纸智能体检对比清理" width="100%" />
</p>

### 32 · 设置中心（上）：外观模式、卡片比例、自定义 `#RRGGBB` 主题色与未连接署名

<p align="center">
  <img src="./docs/showcase/32-ipad-settings-general.png" alt="WallPull iPad 设置中心外观与未连接顶栏署名配置" width="100%" />
</p>

### 33 · 设置中心（下）：剪贴板推送、离线存储维护与开源关于卡片

<p align="center">
  <img src="./docs/showcase/33-ipad-settings-storage-about.png" alt="WallPull iPad 设置中心离线存储与 GPL-3.0 关于卡片" width="100%" />
</p>

### 34 · 跨端互联 · 4 位随机配对码安全鉴权（v1.0.3）

<p align="center">
  <img src="./docs/showcase/36-ipad-lan-pin-pairing.png" alt="WallPull iPad 4 位数字配对码弹窗与局域网双向令牌配对" width="100%" />
</p>

### 35 · 全屏视频播放器 · 内嵌音轨无损提取 BGM（v1.0.3）

<p align="center">
  <img src="./docs/showcase/37-ipad-video-player-bgm.png" alt="WallPull iPad 全屏视频播放器与一键提取视频内嵌 BGM 分享" width="100%" />
</p>

### 36 · iPad 2D 透视拆解台 · 双指缩放与原图实时对比（v1.0.3）

<p align="center">
  <img src="./docs/showcase/38-ipad-studio-compare.png" alt="WallPull iPad 2D 透视拆解台实时原图对比滑块" width="100%" />
</p>

### 37 · 多维筛选与排序浮层（v1.0.3）

<p align="center">
  <img src="./docs/showcase/39-ipad-filter-and-sort-v103.png" alt="WallPull iPad v1.0.3 多维规格与主色调筛选浮层" width="100%" />
</p>

### 38 · 设置中心与 `v1.0.3` 版本信息（v1.0.3）

<p align="center">
  <img src="./docs/showcase/40-ipad-settings-v103.png" alt="WallPull iPad v1.0.3 设置中心与版本号信息" width="100%" />
</p>

### 39 · 从电脑挑图入库 · 真瀑布流与差分量级同步（v1.0.3）

<p align="center">
  <img src="./docs/showcase/41-ipad-pc-catalog-v103.png" alt="WallPull iPad v1.0.3 从电脑挑图与同步状态角标" width="100%" />
</p>

---

## v1.0.4 双端新特性实机预览（40–45）

### 40 · Windows 智能比例裁切工作台（原图无损像素直出，v1.0.4）

<p align="center">
  <img src="./docs/showcase/42-win-image-crop-studio.png" alt="WallPull Windows 智能比例裁切工作台" width="100%" />
</p>

### 41 · iPad 智能比例裁切工作台（双指/触控拖框与相册直存，v1.0.4）

<p align="center">
  <img src="./docs/showcase/43-ipad-image-crop-studio.png" alt="WallPull iPad 智能比例裁切台" width="100%" />
</p>

### 42 · Windows 视频高清截帧预览与微调（v1.0.4）

<p align="center">
  <img src="./docs/showcase/44-win-video-frame-capture.png" alt="WallPull Windows 视频高清截帧预览" width="100%" />
</p>

### 43 · iPad 视频高清截帧预览（暂停定格与高画质 PNG 导出，v1.0.4）

<p align="center">
  <img src="./docs/showcase/45-ipad-video-frame-capture.png" alt="WallPull iPad 视频高清截帧预览" width="100%" />
</p>

### 44 · Windows 筛选排序与 4 列对齐画廊卡片（v1.0.4）

<p align="center">
  <img src="./docs/showcase/46-win-filter-and-sort-v104.png" alt="WallPull Windows 筛选排序面板与 4 列自适应画廊" width="100%" />
</p>

### 45 · Windows 全新自绘高 DPI 系统托盘菜单（v1.0.4）

<p align="center">
  <img src="./docs/showcase/47-win-tray-menu.png" alt="WallPull Windows 自绘高清亮暗双色系统托盘菜单" width="100%" />
</p>

---

## 下载与使用（普通用户）

### Windows 桌面端
1. 前往仓库右侧的 **[Releases](../../releases)** 页面，下载最新版本的 **`WallPull.exe`**（单文件约 `12 MB`，下载后放到任意路径双击即可运行，无需安装）。
2. **运行环境要求**：
   - Windows 10 / Windows 11（64 位）
   - Microsoft Edge WebView2 Runtime（Windows 11 默认自带，绝大多数 Windows 10 已自动安装）
3. **可选增强组件（`ffmpeg`）**：
   - 浏览图片/视频壁纸、解包 `.pkg` / `.tex` 贴图、Scene 图层拆解、复制原图原视频、导出 PNG / JPG / WebP / ICO 均**完全内置、开箱即用**。
   - 仅当你需要使用「视频转 MP4 / WebM / GIF」「H.265 瘦身压缩」「音频转 MP3 / FLAC / OGG」或跨端 iPad 预览流转码功能时，才需准备 `ffmpeg.exe` 与 `ffprobe.exe`，放入以下任意位置之一即可自动识别：
     - 与 `WallPull.exe` 同级目录，或同级的 `Tools/` 文件夹
     - `%LOCALAPPDATA%\WallpaperVault\Tools\` 目录
     - 系统环境变量 `PATH` 中已配置的任意目录

### iPadOS 随身端
1. 前往 **[Releases](../../releases)** 页面下载 **`WallPull-iPad.ipa`**（无签名通用包，支持 `iPadOS 15.4+`）。
2. **安装方式**：通过 **TrollStore（巨魔）** 永久免签安装，或使用 **SideStore / AltStore / Sideloadly / 爱思助手** 等工具侧载到 iPad（也可直接通过 AirDrop 传到平板安装）。
3. **跨端直连**：确认电脑端 `WallPull.exe` 与 iPad 连在同一个 Wi-Fi 局域网下，顶栏绿点亮起即可浏览电脑壁纸库、一键批量收入平板或推送原图至 iPad 剪贴板。

---

## 从源码编译（开发者）

### Windows 桌面端编译
- **环境准备**：[Rust](https://www.rust-lang.org/) stable 工具链（`x86_64-pc-windows-msvc`）、[Node.js](https://nodejs.org/) 20+（推荐 22 LTS）、Visual Studio Build Tools（Desktop development with C++ 与 Windows SDK）。

```powershell
# 1. 安装前端依赖并构建打包静态资源（Rust 会通过 include_dir 内嵌 frontend/dist）
cd frontend
npm ci
npm run lint
npm run build
cd ..

# 2. 运行 Rust 核心单元测试并编译单文件 Release 成品（输出位于 target/release/WallPull.exe）
cargo test
cargo build --release
```

### iPadOS 客户端编译
- **方式一 · 没有 Mac 的 Windows 用户（推荐）**：Fork 本仓库后，直接在 GitHub 仓库顶部进入 **Actions → Build & Release → Run workflow**，即可免费使用云端 macOS Runner 自动编译产出 `WallPull-iPad.ipa`（也同时会打包 Windows 版 `WallPull.exe`）。
- **方式二 · macOS 本地编译**（需 Xcode 16+ 与 Homebrew）：

```bash
cd ipad
brew install xcodegen
xcodegen generate
xcodebuild -project WallPullIPad.xcodeproj -scheme WallPullIPad -configuration Release -sdk iphoneos CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

> 仓库内已配置 `.github/workflows/release.yml`：推送 `main` 分支或手动触发 workflow 后，GitHub Actions 会并行构建路径脱敏版 Windows `WallPull.exe` 与 iPadOS `WallPull-iPad.ipa`，并自动产出附带 `SHA-256` 校验文件的构建制品。

---

## 项目目录结构

```text
WallPull/
├── .github/
│   ├── ISSUE_TEMPLATE/    # Bug 反馈与功能建议模板
│   └── workflows/
│       └── release.yml    # Windows + iPadOS 双端并行构建与 Release 工作流
├── Assets/
│   ├── AppIcon.ico        # 桌面与主窗口应用图标
│   └── TrayIcon.ico       # 系统托盘常驻图标
├── docs/showcase/         # README 功能展示高清截图与动图素材
├── frontend/              # React 19 + Vite + Tailwind CSS v4 前端界面源码
│   ├── public/            # 图标与浏览器预览模式演示图
│   └── src/               # 组件、交互动效、状态管理与样式
├── ipad/                  # WallPull iPad 原生端（SwiftUI + UIKit, iPadOS 15.4+）
│   ├── project.yml        # XcodeGen 工程描述配置
│   └── WallPullIPad/      # 离线壁纸库、跨端直连、配乐电台与 2D 透视拆图源码
├── src/                   # Windows 端 Rust 原生内核与跨端服务端
│   ├── main.rs            # 入口与命令行诊断（--self-test / --bench-studio）
│   ├── window.rs          # 原生 Win32 无边框窗口、暗色标题栏与 DPI 适配
│   ├── bridge.rs          # WebView2 桥接、自定义虚拟域名媒体流与消息路由
│   ├── localsend.rs       # 独立 WallPull 局域网频段发现、双向传输与资产/拆图 API
│   ├── scanner.rs         # Steam/工坊目录探测、project.json 解析与增量索引缓存
│   ├── pkg.rs             # 纯 Rust Wallpaper Engine .pkg 拆包器
│   ├── tex.rs             # 纯 Rust .tex 贴图解码器（RGBA/DXT/LZ4/精灵图集）
│   ├── scene_studio.rs    # Scene 场景工程解析与多图层透明合成引擎
│   ├── actions.rs         # 本地典藏、跨盘 NTFS 联接迁移与外部媒体操作
│   ├── duplicates.rs      # 重复壁纸识别与系统回收站安全删除
│   ├── media.rs           # FFmpeg 调用与多尺寸 ICO 图标编码
│   ├── settings.rs        # 本机配置持久化与显卡硬件信息读取
│   ├── tray.rs            # 系统托盘驻留支持
│   ├── clipboard.rs       # Windows 原生剪贴板文件与文本复制
│   ├── process_runner.rs  # 无黑框子进程封装
│   ├── we_bridge.rs       # Wallpaper Engine 本地路径识别
│   └── models.rs          # 前后端共享数据结构定义
├── app.manifest           # Windows DPI 感知与 Common Controls 6 清单
├── build.rs               # 图标与文件版本资源嵌入脚本
├── Cargo.toml             # Rust 依赖与 Release LTO/Strip 配置
├── LICENSE                # GNU GPL-3.0 完整协议文本
└── README.md
```

---

## 技术栈与开源致谢

- **Windows 桌面内核（Rust）**：`windows-rs`、`webview2-com`、`include_dir`、`image`、`lewton`、`rayon`、`serde`、`rustls`、`ureq`、`rfd`
- **前端与视觉交互**：React 19、Vite、Tailwind CSS v4、DaisyUI 5、Motion、Appica UI、[React Bits](https://github.com/DavidHDev/react-bits) 交互组件灵感、Phosphor Icons、Hugeicons、MiSans 字体
- **iPad 原生随身端（Apple）**：Swift 5、SwiftUI、UIKit、AVFoundation、CoreGraphics、ImageIO、CryptoKit、XcodeGen
- **跨端传输协议致谢**：双端局域网发现与两阶段文件传输模型的设计灵感参考并致敬开源项目 **[LocalSend](https://github.com/localsend/localsend)**（Apache-2.0，[LocalSend Protocol v2](https://github.com/localsend/protocol)），由 Rust 与 Swift 原生独立实现并运行于 WallPull 专属隔离频段，与原版 LocalSend 互不干扰。

---

## 交流与反馈

- **GitHub 主页**：[XiaonanXY/WallPull](https://github.com/XiaonanXY/WallPull)
- **问题反馈 / 建议**：欢迎前往 [GitHub Issues](https://github.com/XiaonanXY/WallPull/issues) 提交 Bug 反馈或新功能建议
- **交流反馈（群号 `471426180`）**：[点击打开交流反馈链接](https://qm.qq.com/q/aYrBqaDlDi)（在软件 **设置 → 关于与反馈** 中点击「交流反馈」也会自动打开链接并复制群号）

---

## 开源协议

Copyright (C) 2026 Xiaonan

本项目采用 **[GNU General Public License v3.0 (GPL-3.0)](./LICENSE)** 开源协议。

通俗来说：
- 你可以免费下载、研究、个人使用或二次修改本项目代码；
- **任何基于本项目的修改版本、二次打包或衍生分发行为，都必须同样使用 GPL-3.0 协议并免费公开全部修改后的源码**，且必须完整保留原版权声明与协议文件，不得闭源垄断或套壳商用倒卖。
