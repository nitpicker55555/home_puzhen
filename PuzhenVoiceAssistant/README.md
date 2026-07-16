# Puzhen 语音助手 (macOS)

一个原生的 macOS 菜单栏语音助手。你喊 **「puzhen puzhen（普真普真）」**，它就会「叮」一声开始听，
然后把你的问题交给最快的大模型，再用 macOS 自带的语音朗读答案出来。可以连续对话。

全部用 macOS 自带能力，不依赖任何第三方库：

| 功能 | 用的 macOS 自带 API |
|------|---------------------|
| 唤醒词识别 | `Speech` 框架（`SFSpeechRecognizer`，支持离线识别） |
| 语音转文字 | `Speech` 框架 |
| 大模型 | AiHubMix（OpenAI 兼容接口，流式返回，默认 `gpt-4.1-nano`） |
| 文字转语音 | `AVSpeechSynthesizer`（系统内置人声） |
| 提示音 | `NSSound`（系统声音） |

## 一、编译

```bash
cd PuzhenVoiceAssistant
./build.sh
```

会生成 `build/PuzhenAssistant.app`。

## 二、配置 API key（放在 .env，不写进代码）

```bash
cp .env.example .env      # 然后编辑 .env，填入你的 AIHUBMIX_API_KEY
```

`.env` 已被 `.gitignore` 忽略，永远不会提交到 git。key 只存在你本地。

## 三、第一次运行（重要）

**第一次请在终端里用 `run.sh` 运行**，它会自动读取 `.env`，你也能看到日志、并弹出麦克风/语音识别授权框：

```bash
./run.sh
```

> 想双击运行 `.app` 也可以：程序启动时会自动去读 `PuzhenVoiceAssistant/.env`、
> `~/.puzhen-assistant.env`、`~/.config/puzhen-assistant/.env`。把 `.env` 放到其中之一即可。

- 会弹出两个授权框：**麦克风** 和 **语音识别**，都点「允许」。
- 授权后它会说一句「你好，我是普真语音助手」，菜单栏右上角出现一个 🎙️ 图标。
- 之后直接双击 `PuzhenAssistant.app` 或 `open build/PuzhenAssistant.app` 就能后台运行。

> 如果没弹授权框或识别一直不可用：打开「系统设置 › 隐私与安全性」，在
> **麦克风** 和 **语音识别** 里手动把 PuzhenAssistant 打开，然后重新运行。

## 四、怎么用

1. 说 **「普真普真」**（或英文 puzhen puzhen）。
2. 听到「叮」一声后，直接说你的问题，例如「今天写代码累不累」。
3. 停顿约 1 秒后它就会思考并朗读答案。可接着再喊「普真普真」继续问。

菜单栏图标表示当前状态：🎙️ 待命 · 🔴 正在听你说 · 💭 思考中 · 🗣️ 正在说话。
点图标可以「退出」。

## 五、可调参数

都可以写进 `.env`，或运行前设为环境变量：

```bash
# 例：换个模型（都在 AiHubMix 上验证过可用）
echo "ASSISTANT_MODEL=gemini-2.5-flash" >> .env && ./run.sh
```

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `AIHUBMIX_API_KEY` | 无（必填） | AiHubMix 的 key，放在 `.env` 里 |
| `ASSISTANT_MODEL` | `gpt-4.1-nano` | 大模型。可选 `gemini-2.5-flash` / `gpt-4o-mini` / `qwen-turbo` / `deepseek-chat` |
| `ASSISTANT_LOCALE` | `zh-CN` | 语音识别语言。主要说英文就设 `en-US` |
| `ASSISTANT_VOICE` | 自动 | 强制朗读语音，如 `zh-CN` 或 `en-US`；留空则按内容自动选 |
| `AIHUBMIX_BASE_URL` | `https://aihubmix.com/v1` | 接口地址 |

## 六、唤醒词识别不准怎么办

"puzhen" 不是标准英文词，Apple 的识别器可能把它转成别的拼写。
终端运行时会打印它听到的文字（`👤 ...`）。如果发现某个固定的错误拼写，
把它加到 `Sources/main.swift` 里的 `Config.chineseWake` 列表或 `wakeRegex` 正则，再 `./build.sh` 即可。
默认的正则已经覆盖 puzhen / pu zhen / pujen / puchen 等常见情况，中文覆盖 普真 / 普珍 / 布真 等。

## 七、已知限制

- 它**说话时不听你说话**（避免自己听到自己），所以现在还不能打断它。等它说完再喊唤醒词。
- 识别质量取决于 Apple 的语音识别；建议在「系统设置 › 键盘 › 听写」里保留中文，
  这样能用离线识别，更快也更稳。

## 八、开机自启（可选）

「系统设置 › 通用 › 登录项」里点 `+`，选中 `PuzhenAssistant.app` 即可开机自动运行。
