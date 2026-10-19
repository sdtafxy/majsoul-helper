# 雀魂助手 · MajsoulHelper

macOS 菜单栏工具：从雀魂（Mahjong Soul）对局窗口实时读牌，给出当前最优打牌建议。

不是插件、不注入游戏、不读协议——只截屏和本地识牌，模型只做牌理分析。

## 功能

| | |
|---|---|
| **实时识别** | 自家手牌（暗牌/摸牌/副露/暗杠）、四家牌河、宝牌；一张截图约 1 秒 |
| **打牌建议** | 基于局面的向听、打点、危险牌分析，输出推荐打牌 + 理由 + 危险提示 + 备选 |
| **两档分析** | 快速档（关思考，约 2 秒）/ 深度档（完整推演，1~2 分钟） |
| **Overlay 标注** | 把识别结果画在游戏窗口上：手牌、牌河逐张框 + 牌名 |
| **自动选窗** | 一键找到标题含「雀魂 / Majsoul / Mahjong Soul」的窗口 |
| **标注配色** | 4 套预设主题 + 自定义配色（四家颜色、低置信、识别失败） |
| **识别结果浮窗** | 独立的识别清单窗口，暗杠显示为「背 / 明 / 明 / 背」四张占位 |

## 系统要求

- macOS 14（Sonoma）及以上，Apple Silicon
- 首次启动需要「屏幕录制」权限（系统设置 → 隐私与安全性 → 屏幕录制）

## 安装

1. 从 [Releases](https://github.com/sdtafxy/majsoul-helper/releases) 下载最新的 `MajsoulHelper-x.y.z.zip`
2. 解压后把 `MajsoulHelper.app` 拖进「应用程序」
3. 首次打开：右键 → 打开（未签名发行版），按提示到系统设置授予**屏幕录制**权限
4. 重启 App

识别引擎已内置（含运行时，无需安装 Python 或任何依赖）。

## 使用

1. 打开雀魂对局窗口（网页版或客户端）
2. 菜单栏点雀魂图标 → **快速** 或 **分析**；或点主浮窗的对应按钮
3. 主浮窗显示建议卡：推荐打出的牌、把握度、理由、危险、备选、要点
4. 点「**自动选窗**」自动锁定雀魂窗口；「选择窗口」可手动挑选
5. 菜单栏「识别结果」打开识别清单；「设置」调整模型、档位、配色、截图质量

## 打牌建议怎么来

打牌分析由 **通用大模型**（DeepSeek、GLM、Kimi、MiniMax 或任意 OpenAI 兼容服务）完成。识别全部在本地，只有局面文本（手牌/牌河/副露/宝牌的牌名）与你配置的局部裁剪图会发送给你选择的模型 API。

本项目**没有内置 Akagi / Mortal 这类专用麻将模型**——它们需要 CUDA 环境与模型权重，门槛较高。这里用通用 LLM 替代：配置 API Key 即可用，中文牌理讲解也更自然。若你已有自己的推理服务，可在设置→模型配置里选「自定义」，填入任意 OpenAI 兼容地址即可。

## 识别引擎

牌面识别来自独立项目 [majsoul-vision](https://github.com/sdtafxy/majsoul-vision)：纯本地算法，无联网、无模型。发布版已把它的可执行产物打进 App（`Contents/Resources/vision/`），开箱即用；该项目也可以独立使用（见其 README）。

## 隐私

- 截图**只在本机**处理；不会上传到除你配置的模型 API 之外的任何地方
- API Key 只存本机（`~/Library/Application Support/MajsoulHelper/config.json`，仅本机可读），不写入日志
- 不采集遥测、不联网检查更新之外的任何请求（更新检查可关闭）

## 从源码构建

需要 Xcode 15+（Swift 5.9）与 macOS 14 SDK：

```bash
git clone https://github.com/sdtafxy/majsoul-helper
cd majsoul-helper

# 1. 识别引擎（二选一）
#    a) 下载 release 的 vision zip 解压到 Resources/vision/
#    b) 或从 majsoul-vision 仓库自行打包（PyInstaller），输出到 Resources/vision/

# 2. 构建
./scripts/build_app.sh          # 产物在 dist/MajsoulHelper.app
```

构建脚本会嵌入识别引擎并完成签名（自签或用 `scripts/setup_signing.sh` 生成稳定证书，避免每次编译都要重新授权屏幕录制）。

## 许可

MIT
