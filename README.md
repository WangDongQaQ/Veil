# Veil — 桌面实时字幕小组件

戴着降噪耳机工作时，麦克风实时收音并转成文字，显示成一块**无边框的桌面小组件**。
文字平时被 Telegram 式的「尘雾」遮住，**光标移到文字上才会散开**——既不错过别人叫你，也不会被旁边的人瞟到内容。

macOS 26+，原生 Swift / SwiftUI / AppKit，菜单栏常驻（没有 Dock 图标）。

## 构建与运行

```bash
scripts/build.sh --run     # 编译、打包 build/Veil.app、签名并启动
```

- 只装了 Command Line Tools 也能编（脚本会自动选用 CLT 自带的 macOS 26.x SDK，
  因为 27 SDK 的 SwiftUI 宏插件只随完整 Xcode 提供）。
- 脚本优先用本机的 Apple Development 证书签名，这样麦克风授权重新编译后不会丢；
  也可用 `VEIL_SIGN_IDENTITY="…"` 指定。
- 想要「登录时自动启动」，请把 `Veil.app` 放进 `/Applications`。

首次启动会进入**调整模式**（虚线框），拖到合适位置、拖四角改大小，点「完成」。
之后点菜单栏图标 → 「开始听写」（首次会请求麦克风权限）。

## 使用

| 操作 | 方式 |
|---|---|
| 开始 / 暂停听写 | 菜单栏，或 ⌃⌥⌘L |
| 显示 / 隐藏字幕 | 菜单栏，或 ⌃⌥⌘H |
| 调整位置与大小 | 菜单栏，或 ⌃⌥⌘E（拖动移动，拖四角缩放） |
| 查看字幕 | 把光标移到文字上，遮罩从光标处散开；移开后重新遮住 |
| 设置 | 菜单栏 › 设置…，或 ⌘, |

**背景自适应**：文字和尘雾每一粒都带反色描边（白字深描边、白点配深色阴影），白底、黑底、花壁纸上都看得清。
浅色页面多的话，可在 设置 › 字幕 › 配色 选「深色字」，或菜单栏 › 文字配色 一键切换。
设置 › 遮罩 里有「浓淡」滑块和浅/深背景的实时预览，可以把尘雾调到刚好「知道这里有字」的程度。

字幕窗口平时**点击穿透**，不会挡住下面的 App；只有调整模式下才接收鼠标。

## 识别引擎

设置 › 识别 里切换：

1. **Apple 本机识别**（默认）——macOS 26 的 `SpeechAnalyzer`，完全离线、免费，音频不出本机。
2. **豆包语音识别（流式）**——火山引擎「豆包流式语音识别 2.0」，准确率明显更高，带二遍识别。
   在控制台「豆包语音」里创建 API Key 并开通流式识别，粘贴到设置里即可（存钥匙串）。
3. **OpenAI 兼容接口**——任何实现 `POST …/audio/transcriptions` 的服务：OpenAI、Groq、
   硅基流动，或本机的 whisper.cpp / faster-whisper-server / mlx-whisper 服务器。
   接口不是流式的，所以 Veil 自己做 VAD 切句：停顿后请求最终结果，可选说话过程中请求中间结果。

### 豆包怎么最省

豆包 ASR **按音频时长计费**（后付费约 ¥1/小时），不按 token，所以省钱 = 少发音频。Veil 的做法：

| 手段 | 作用 |
|---|---|
| 真流式连接，每段音频只发一次 | 对比「分块重传」的接口：一句 8 秒的话实测会上传约 32 秒（4×） |
| 本地 VAD，只发人声 | 静音一秒都不发；戴降噪耳机时大部分时间没人说话 |
| 连续 0.25 秒有声才建立连接 | 键盘声、咳嗽、鼠标声不会触发（实测敲键盘 0 秒） |
| 句尾静音不发 | 停顿期间的音频先暂存，说话继续才补发，说完就丢（每句省约 0.6 秒） |
| 每句话一个短会话，说完即关 | 不论按「发送时长」还是「连接时长」计费，都≈说话时长 |
| 每日用量上限 | 到上限后自动改用 Apple 本机识别（可关），设置里可看今日用量与估算费用 |

> 蓝牙耳机（AirPods 等）做麦克风会把耳机切到通话音质。设置 › 通用 里可以把输入设备
> 指定为「MacBook 内置麦克风」，耳机继续保持高音质和降噪。

### 接入新的引擎

实现 `TranscriptionEngine`（`Sources/Veil/ASR/TranscriptionEngine.swift`）：`start` / `feed` / `stop`，
把结果以 `.partial` / `.final` 事件回传，然后在 `AppModel.makeEngine()` 里加一个 case。

## 代码结构

```
Sources/Veil
├─ VeilApp.swift             入口、菜单栏
├─ Core/                     AppModel（串联麦克风→引擎→字幕）、偏好设置、CaptionStore
├─ Audio/                    输入设备枚举、AVAudioEngine 采集
├─ ASR/                      引擎协议、VoiceGate（VAD）、Apple 本机、豆包流式、OpenAI 兼容
├─ Caption/                  浮窗、字幕视图、尘雾（DustField）、调整模式覆盖层
├─ Settings/                 设置窗口（通用/识别/字幕/遮罩/窗口）
└─ Support/                  Keychain、全局快捷键、调试快照工具
```

## 开发者工具

不需要任何系统权限，只渲染 Veil 自己的窗口：

```bash
# 把字幕框 / 设置窗口渲染成 PNG
VEIL_SNAPSHOT_DIR=/tmp/veil VEIL_SNAPSHOT_SETTINGS=1 VEIL_SETTINGS_TAB=recognition build/Veil.app/Contents/MacOS/Veil

# 不用麦克风，把一段音频文件喂给识别引擎
# VEIL_FEED_BACKEND=api 测 HTTP 引擎；=doubao 测豆包（key 经 VEIL_DOUBAO_KEY 传入，不会落盘）
say -o speech.aiff "你好，下午的会议改到三点了"
VEIL_FEED_FILE=speech.aiff VEIL_FEED_LANG=zh-CN build/Veil.app/Contents/MacOS/Veil
```

```bash
# 麦克风探针：跑真实采集 N 秒，统计音频引擎「配置变化」次数（只计数，不保存音频）
open -n --env VEIL_MIC_PROBE=20 --env VEIL_MIC_PROBE_DEVICE=BuiltInMicrophoneDevice \
  --env VEIL_PROBE_LOG=/tmp/probe.log build/Veil.app && cat /tmp/probe.log
```

这些模式使用独立的临时偏好域，不会改动真实设置。
