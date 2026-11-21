# ClipNest

一个美观、简洁、好用的 macOS 剪贴板历史工具。常驻菜单栏，按 **⌘⇧V** 呼出，搜索、预览、回车即可粘贴。

![ClipNest 浅色](docs/screenshot-light.png)
![ClipNest 深色](docs/screenshot-dark.png)

## 功能

- 自动记录复制过的**文本、图片和文件**，重复内容自动合并并移到最前。
- 左侧列表、右侧预览：长文本、代码、图片、文件路径都能先看清再粘贴。
- 识别链接、颜色值（如 `#5B8CFF`）和代码，并显示复制来源 App。
- 即时搜索（多个关键词用空格分隔），按分类筛选：全部 / 文本 / 图片 / 文件 / 固定。
- 固定常用条目，固定的条目始终在最前，且不会被清理。
- 跳过密码管理器标记为“机密”或“临时”的内容（`org.nspasteboard.ConcealedType` 等）。
- 默认保留最近 500 条，数据只存在本机：`~/Library/Application Support/ClipNest/`。
- 菜单栏可暂停记录、设置登录时启动、清空历史。

## 快捷键

| 按键 | 作用 |
| --- | --- |
| ⌘⇧V | 呼出 / 收起面板 |
| ↑ ↓ | 选择条目 |
| ↩ | 粘贴到当前 App |
| ⌘↩ | 只复制，不粘贴 |
| ⌘1 … ⌘9 | 直接粘贴第 1–9 条 |
| ⌘P | 固定 / 取消固定 |
| ⌘⌫ | 删除条目 |
| ⇥ / ⇧⇥ | 切换分类 |
| Esc | 清空搜索；再按一次关闭 |

双击条目也可粘贴，右键有更多操作。

## 安装

1. 从 [Releases](https://github.com/ergt10/Clipboard-mac/releases) 下载 `ClipNest.dmg`（或 `ClipNest.zip`），把 ClipNest 拖进“应用程序”。
2. App 没有 Apple 开发者签名，首次打开会被拦截。任选一种方式放行：
   - 在 Finder 中右键 ClipNest →“打开”；或
   - 终端执行 `xattr -dr com.apple.quarantine /Applications/ClipNest.app`。
3. 第一次按回车粘贴时，系统会请求**辅助功能**权限（系统设置 → 隐私与安全性 → 辅助功能，打开 ClipNest）。没有这个权限时，回车只会把内容复制到剪贴板，需要自己按 ⌘V。

需要 macOS 14 或更高版本，支持 Apple 芯片和 Intel。

## 从源码构建

只需要 Xcode Command Line Tools：

```bash
./build.sh            # 生成 build/ClipNest.app
./build.sh --release  # 额外生成 build/ClipNest.zip 和 build/ClipNest.dmg
```

源码在 `Sources/`：`Store.swift` 负责历史存储，`Pasteboard.swift` 负责监听剪贴板、写回和全局快捷键，`Views.swift` 是界面，`Panel.swift` 是浮动面板和键盘操作。

## 许可

MIT
