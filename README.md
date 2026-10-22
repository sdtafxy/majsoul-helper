![雀魂助手](docs/intro.jpg)

# 雀魂助手

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black?style=for-the-badge&logo=apple)
![Swift](https://img.shields.io/badge/swift-5.9-orange?style=for-the-badge&logo=swift)
![Release](https://img.shields.io/badge/release-v0.1.1-4B8BBE?style=for-the-badge)
![License](https://img.shields.io/badge/license-MIT-3DA639?style=for-the-badge)
[![Engine](https://img.shields.io/badge/engine-majsoul--vision-8A2BE2?style=for-the-badge)](https://github.com/sdtafxy/majsoul-vision)

打雀魂的时候，总有几张牌让人犹豫半天。这张要不要留？立直还是默听？对面那张立直是真的还是唬人？

雀魂助手只做一件事：把当前局面读出来，交给大模型分析，然后把该打的牌、理由和危险提示摆在你面前。读牌全在本地，一秒内完成；分析用你自己配的 Key，模型随你挑。

它不注入游戏、不改客户端、不碰协议——只是看一眼屏幕，像旁边坐着个懂牌的朋友。

## 它能帮你做什么

**读牌**

- 自家手牌、四家牌河、副露、宝牌，全都认出来
- 牌河按各家视角排序，横着摆的立直牌也不会认错
- 认不准的牌会标出来，扫一眼就知道哪里要自己看

**给建议**

- 推荐打哪张，把握有多大
- 讲清理由：向听、打点、危险牌
- 附两三个备选，以及各自的取舍
- 快速档两秒出结果，深度档让它慢慢想

**贴着游戏看**

- 识别结果直接叠在游戏画面上，逐张标注
- 另有一个识别清单窗口，手牌牌河一目了然
- 「自动选窗」一键锁定雀魂窗口，不用每次手动找

## 安装

需要 macOS 14 以上，Apple Silicon。

1. 到 [Releases](https://github.com/sdtafxy/majsoul-helper/releases) 下载最新的 zip
2. 解压，把 `MajsoulHelper.app` 拖进「应用程序」
3. 第一次打开：右键 →「打开」，按提示到系统设置里授予「屏幕录制」，然后重启 App

识别引擎已经打进 App，不用装 Python，不用装任何依赖。

## 用起来

开着雀魂对局，点菜单栏的图标：

- **快速** —— 一两秒出建议，日常够用
- **分析** —— 让模型多想一会儿，复杂局面更稳
- 也可以直接在主浮窗里点按钮

设置里可以换模型、调分析档位、改标注配色。想换个窗口截图，点「选择窗口」；懒得找就点「自动选窗」。

## 打牌建议是怎么来的

用的是通用大模型：DeepSeek、GLM、Kimi、MiniMax 都行，只要兼容 OpenAI 接口。填上你自己的 API Key 就能用；自建的兼容服务也可以接。

没有内置 Akagi / Mortal 这类专用麻将模型——它们要 CUDA、要模型权重，门槛不低。通用模型配好 Key 就能跑，中文讲牌理反而更自然。

## 关于识别

读牌来自 [majsoul-vision](https://github.com/sdtafxy/majsoul-vision)，纯本地算法，不联网、不加载模型。想在自己的脚本里用，也可以单独拿它跑：

```bash
python recognize.py 截图.png
```

## 隐私

- 截图只在本机处理，不上传
- 发给你配置的模型 API 的，只有牌局文本；要不要附带局部截图，你可以自己关掉
- API Key 只存在本机（`~/Library/Application Support/MajsoulHelper/config.json`），不写进日志
- 没有遥测，没有后台上报

## 自己构建

需要 Xcode 15 以上（Swift 5.9）：

```bash
git clone https://github.com/sdtafxy/majsoul-helper
cd majsoul-helper

# 识别引擎：从 majsoul-vision 仓库打包一份放到 Resources/vision/
# （或者下载 release 里的产物）
./scripts/build_app.sh          # 产物在 dist/MajsoulHelper.app
```

`scripts/release.sh` 负责发版：自动加 build 号、打包、签名、生成 appcast。

## 许可

MIT
