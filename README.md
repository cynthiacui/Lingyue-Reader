# 灵阅书屋 (Lingyue)

一款专为中文小说打造的精致 iOS 阅读器。聚合多个书源，一键导入整本书，用钱包式堆叠分类管理书库；五种页面底色、五种字体、三种翻页动画，状态栏和工具栏的显隐遵循 Apple Books 的交互习惯。

iOS 17+ · SwiftUI · 单窗口应用 · 包名 `com.lingyue.reader`

---

## 使用指南

App Store 上架的灵阅是一个「空壳」阅读器——不自带任何书源，需要你导入一份书源配置文件后才能搜索和下载小说。

### 下载书源文件

点击下面的下载链接，把 `lingyue-sources.json` 保存到 iPhone 的「文件」App（iCloud Drive、本机或任意位置都可以）：

### 📥 [下载 lingyue-sources.json](https://github.com/cynthiacui/Lingyue-Reader/releases/latest/download/lingyue-sources.json)

链接来自 GitHub Releases，iPhone Safari 点击会直接弹出「下载」对话框，无需长按。

> 该文件包含若干公开书源的解析规则。规则只描述「如何解析网页」，不包含任何受版权保护的小说内容。

### 在 App 内导入

1. 打开灵阅，切到底部「**发现**」标签
2. 点击右上角的「**地球**」图标进入「**书源**」页面
3. 点击右上角的「**＋**」，选择「**从 JSON 导入**」
4. 在文件选择器里找到刚刚保存的 `lingyue-sources.json`
5. 确认对话框会提示「新增 / 覆盖 / 未变更」的条数，点击「**导入**」完成

导入完成后，「**发现**」页的搜索框就能跨所有已启用的书源搜索小说了。

### 导入本地 TXT 文件

除了从书源搜索下载，也可以把手头已有的 TXT 小说直接导入书架：

1. 把 `.txt` 文件保存到 iPhone 的「文件」App（AirDrop、邮件附件、iCloud Drive 等任意方式均可）
2. 打开灵阅，切到底部「**书架**」标签
3. 点击左上角的「**文档加号**」按钮（图标 `doc.badge.plus`）
4. 在文件选择器里选中要导入的 `.txt` 文件

App 会自动识别 `第 N 章 / 节 / 回 / 卷 / 页` 的章节标题（支持阿拉伯数字与「一二三十百千万」中文数字）拆分章节；没有识别到任何章节标题时则作为单章导入。文件名（去掉扩展名）会作为书名，作者默认显示「未知作者」。支持的文件编码：**UTF-8 / GB18030 / Big5**。

> 同名书籍再次导入会**覆盖**原书的章节内容，可用于更新或修正本地小说。

### 常见问题

**Q：为什么 App Store 版本不自带书源？**
A：为了把「阅读器」和「书源规则」解耦——书源规则在第三方网站结构变化时需要频繁更新，独立放在 GitHub 上更新更快，也让 App 本身保持「干净」。

**Q：可以自定义书源吗？**
A：可以。同样在「书源」页面，点击「＋」选择「**从 URL 分析**」或「**手动新建**」，按照向导填写解析规则即可。导出自己的书源也是同一个 JSON 格式，可以分享给他人。

**Q：导入失败 / 搜索没结果？**
A：网站结构变更可能让旧规则失效。请来 [Issues](https://github.com/cynthiacui/Lingyue-Reader/issues) 反馈具体的书源名称和搜索关键词，仓库会更新 Release 中的 `lingyue-sources.json`，重新下载导入即可。

---

## 功能

### 书架

<p>
  <img src="docs/screenshots/library.png" alt="书架" width="280">
  <img src="docs/screenshots/download-manager.png" alt="下载管理" width="280">
</p>

书架采用「钱包堆叠」式分类布局：每个分类默认收成一叠书脊，轻点展开，再点收回。顶部固定「最近阅读」横排，按打开时间倒序展示当前阅读进度；导航栏下方的搜索框可跨分类按书名或作者搜索全部书籍。书本左滑展示「下载 / 清理缓存」，右滑展示「删除」；长按可指定或调整分类。右上角的下载按钮可调出「下载管理」弹层，集中查看正在下载或已暂停的章节任务。

### 发现

<p>
  <img src="docs/screenshots/discovery.png" alt="发现书源" width="280">
  <img src="docs/screenshots/discovery-results.png" alt="搜索结果" width="280">
</p>

「发现」页用同一个搜索框聚合所有已启用的书源：每个书源返回结果后即刻流式展示，多个书源同时收录的同一本书会合并成一行，并以小标签列出来源。「历史记录」保留最近搜索词，可一键重搜；点击任意书源磁贴可在内置浏览器中打开其首页。右上角的「地球」按钮进入书源管理页面，可启用 / 禁用、导入、导出书源。

### 阅读器

阅读器提供 5 种页面底色（纸张 / 米黄 / 护眼 / 雅蓝 / 夜读，夜读可跟随系统深色模式自动切换）、5 种字体（苹方、宋体、楷体（内置 LXGW 文楷 Screen）、黑体、圆体）、以及 3 种翻页动画（无动画 / 滑动 / 仿真翻页）。轻点页面即可仿照 Apple Books 同时显示顶部与底部工具栏及状态栏，正文位置在显隐切换时保持不动，不会重新分页。自动滚读、阅读页内的实时偏好弹层、简繁切换以及带进度条的章节列表都触手可及。

### 统计

「统计」页用日历热力图展示连续阅读天数，按时段、按书籍汇总阅读时长，并把最近读完的章节和总阅读量做成可分享的小卡片。

### 内置浏览器

可在内置浏览器中打开任一书源首页，自动识别书籍页并提供「导入到书架」一键导入。浏览器的顶栏、底部控制栏与背景跟随当前外观主题；网页本身使用透明背景，加载过程中也能透出主题色。

### 我

<p>
  <img src="docs/screenshots/settings-reader.png" alt="阅读偏好" width="280">
  <img src="docs/screenshots/settings-theme-storage.png" alt="外观主题与缓存" width="280">
</p>

顶部是「阅读身份卡」，显示当前连续阅读天数和累计读完字数，轻点即可跳到「统计」标签；下方依次是「阅读偏好」（字号、行距、字体、翻页效果、背景颜色、跟随系统深色模式、繁体中文、自动滚读）、「外观主题」（5 套全局主题：纸张 / 樱粉 / 叶绿 / 水墨 / 星夜）、「数据与缓存」（自动预载、累计下载数据、一键清理），以及「关于」（版本号、使用指南、GitHub 链接）。

## 技术栈

- **语言 / UI**：Swift、SwiftUI，必要处与 UIKit 互通（仿真翻页基于自定义 `UIPageViewController`，内置浏览器基于 `WKWebView`）。
- **持久化**：偏好用 `@AppStorage`；书库与下载章节落到本地 JSON 文件。
- **主题**：环境值 `AppTheme` 驱动同一个 `ThemeBackgroundView`，所有顶层页面在其之上叠加内容；阅读器另有 `ReadingTheme` 控制页面底色。
- **字体**：内置开源 `LXGWWenKaiScreen.ttf`，通过 `UIAppFonts` 注册；其余字体回退到系统 Hiragino 字族。
- **部署目标**：iOS 17.0。

## 构建

```bash
open lingyue.xcodeproj
```

打开 `lingyue.xcodeproj`，选择 `LingyueAppStore` scheme，针对 iOS 17 模拟器或真机构建即可。无第三方依赖，无包管理工具，所有源码均在仓库内。

```bash
xcodebuild -project lingyue.xcodeproj \
           -scheme LingyueAppStore -configuration Debug -sdk iphonesimulator \
           -destination 'generic/platform=iOS Simulator' build
```

---

# Lingyue Reader (English Overview)

A polished, theme-rich Chinese-language novel reader for iOS. The App Store build ships as a "thin shell" — bring your own source-rules JSON (see [使用指南](#使用指南) above), then aggregate-search and import books from multiple sites.

iOS 17+ · SwiftUI · Bundle id `com.lingyue.reader`

## Tabs at a glance

- **Library (书架)** — wallet-stacked categorized shelves: collapse to spines, tap to fan out. A pinned 最近阅读 row tracks recently opened books; mail-style swipes expose download / cache-clear / delete; long-press to reassign category. A toolbar download-manager sheet centralizes active and paused chapter downloads. The top-left `doc.badge.plus` button imports a local `.txt` file (UTF-8 / GB18030 / Big5) and auto-splits it on `第 N 章` chapter headings.

- **Discovery (发现)** — one search box aggregates every enabled source; results stream in as each source replies, and the same book found on multiple sources collapses into one row with provenance chips. The toolbar's globe icon opens **Sources** for enable/disable, JSON import/export, URL-analyze, and from-scratch rule editing.

- **Stats (统计)** — calendar heatmap of consecutive reading days, time-spent breakdowns by book and by hour, and shareable cards for recently finished chapters and lifetime totals.

- **Me (我)** — reading-identity hero card (streak + lifetime characters read, taps over to Stats), plus reading preferences, app themes, data & cache management, and the About page (version, usage guide, GitHub).

## Reader

Five page tints (纸张 / 米黄 / 护眼 / 雅蓝 / 夜读, with optional system-dark follow), five Chinese typefaces (苹方 / 宋体 / 楷体 via bundled LXGW WenKai Screen / 黑体 / 圆体), three page-turn animations (none / slide / page-curl). Apple-Books-style reveal of status bar and chrome on tap, with the body text pinned across the reveal so paragraphs never reflow. Auto-scroll, an in-reader preferences popover, 简↔繁 toggle, and a progress-aware chapter list overlay are all one tap away.

## In-app browser

Opens any source homepage with theme-matched chrome; auto-detects book pages and offers a one-tap **导入到书架** action.

## Tech

Swift + SwiftUI with selective UIKit interop (`UIPageViewController` for page-curl, `WKWebView` for the in-app browser). Preferences via `@AppStorage`; library and downloaded chapters persisted as on-disk JSON. Theming flows through an `AppTheme` environment value plus a single `ThemeBackgroundView`. Bundles `LXGWWenKaiScreen.ttf` (open-source) via `UIAppFonts`; other faces resolve to system Hiragino fallbacks. iOS 17.0 deployment target. No package manager, no external dependencies — everything is in-tree.

## Build

```bash
xcodebuild -project lingyue.xcodeproj \
           -scheme LingyueAppStore -configuration Debug -sdk iphonesimulator \
           -destination 'generic/platform=iOS Simulator' build
```
