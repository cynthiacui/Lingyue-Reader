# 灵阅书屋 (Lingyue)

A polished, theme-rich Chinese-language novel reader for iOS. Browse 16 source sites, import full books with one tap, organize them in a wallet-stacked library, and read with typography that matches the platform — five page tints, five fonts, three page-turn animations, and Apple Books-style reveal of the status bar and chrome.

iOS 17+ · SwiftUI · Single-window app · Bundle id `com.lingyue.reader`

## Features

### 书架 — Library
- Wallet-stacked categories: each shelf collapses to a stack of cover spines, tap to fan out, tap again to collapse. Long-press a category for rename / delete / reorder.
- 最近在读 strip pinned at the top — most-recently-opened books, recent-first.
- Search across every imported book by title or author from the navigation drawer (results render as a flat list with the same swipe + long-press affordances).
- Mail-style left swipe on a book row exposes 下载 (download all chapters) and 清理缓存 (clear downloaded data); right swipe exposes 删除.
- Long-press a book to assign or move it across categories.
- Tap a book to push straight into the reader at the last-read position.

### 发现 — Discovery
- Aggregated search across **16 source sites** in a single query, results streamed in as each source replies:
  破万卷小说 · 大尾笔趣阁 · ESJ轻小说 · 思兔閱讀 · 就爱读小说 · 同人圈 · 笔趣阁小说 · 52书库 · 努努书坊 · 宙斯小说 · 同人小说网 · 台灣小說網 · 黄金屋中文 · 半夏小说 · 52书库2 · 无忧书城.
- 搜索历史 list with one-tap re-run.
- Tap any source tile to open it in the in-app browser.

### 阅读器 — Reader
- Five page themes: 纸张 (warm cream), 米黄, 护眼 (light green), 雅蓝, 夜读. The night theme can follow the system appearance automatically.
- Five Chinese fonts: 苹方 (system), 宋体, 楷体 (bundled LXGW WenKai Screen), 黑体, 圆体.
- Three page-turn animations: 无动画 / 滑动 / 仿真翻页 (real page-curl).
- Auto-scroll mode with adjustable speed; tap to pause, tap again to resume.
- Apple Books-style chrome: tap the page to reveal the top/bottom bars and the status bar together; tap again to hide. Page layout stays pinned across reveal/hide so paragraphs never reflow.
- In-reader preferences popup for size, line spacing, font, theme, and page-turn style — every change applies live.
- 简/繁 toggle — render the same book in either Simplified or Traditional Chinese without re-importing.
- Chapter list overlay with progress bar and most-recently-read jump.

### In-app browser
- Open any source homepage in the built-in browser — auto-detects book pages and offers a one-tap "导入到书架" import.
- Themed chrome (controls and background follow the selected app theme), transparent web view so the theme reads through during loading.

### Per-book download manager
- Queue every chapter of a book for offline reading; pause, resume, or clear at any time.
- Download progress and storage size visible in Settings.

### 设置 — Settings
- Five app themes: 纸张 (paper green), 樱粉 (pink), 叶绿 (leaf green), 水墨 (ink — image pattern), 星夜 (starry night dark).
- Reader defaults (font, size, theme, page transition) editable from the same surface as in-reader.
- Storage management: per-book download size, bulk clear, cache totals.

## Tech

- **Language / UI**: Swift, SwiftUI, UIKit interop where needed (custom `UIPageViewController` for page-curl, `WKWebView` for the in-app browser).
- **Persistence**: `@AppStorage` for preferences, file-system JSON for the library + downloaded chapters.
- **Theming**: `AppTheme` environment value drives a single `ThemeBackgroundView` that all top-level scenes layer their content over; reader has its own `ReadingTheme` for page tints.
- **Fonts**: Bundled `LXGWWenKaiScreen.ttf` (open-source) registered via `UIAppFonts`; other faces resolve to on-device Hiragino fallbacks.
- **Deployment target**: iOS 17.0.

## Build

```bash
open lingyue.xcodeproj
```

Build the `lingyue` scheme against an iOS 17 simulator or device. No external dependencies, no package manager — everything is in-tree.

```bash
xcodebuild -project lingyue.xcodeproj \
           -scheme lingyue -configuration Debug -sdk iphonesimulator \
           -destination 'generic/platform=iOS Simulator' build
```
