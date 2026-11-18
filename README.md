# KeyType Dev

KeyType Dev 是 macOS 菜单栏里的输入补全工具。在光标处停一下，它会显示一小段可以直接接在正文后的灰字。按 Tab 可以分段接受中文词组或英文单词，接受整条建议的快捷键也可以在设置中更改。

这个独立开发版基于 KeyType 1.8，使用单独的应用标识 `com.pattonium.KeyType.dev`、设置和数据目录，可以与原版并存。[上游源码及对应版本](https://github.com/johnbean393/KeyType/tree/0f9dfe8aa5cff3076addc26b7262ea8f1f60f52c)

## 使用

- **API 或本地模型**。在「模型」设置中可以填写 OpenAI 兼容接口的 Base URL、API Key 和模型 ID，内置 OpenAI 与 DeepSeek 预设。选择 API 时无需下载本地模型。API Key 保存在 macOS 钥匙串。
- **中文和英文补全**。微信输入法选拼音候选时暂停灰字，汉字上屏后继续。英文直输也能触发补全。开发版会读取正文的字号，或根据编辑器提供的相邻字符尺寸校准灰字。实际效果取决于输入框开放的辅助功能信息。
- **可选文档记忆**。默认关闭。启用后，对能识别的已保存文档分开加密存储上下文。使用官方 DeepSeek 接口时，每次补全最多附带当前文档的三条相关片段。使用远程 API 时，生成补全所需的上下文会发送给所配置的服务。
- **权限**。灰字和快捷键需要辅助功能与输入监控。屏幕文字识别和截图校准可以另行开启，需要屏幕录制权限。

## 从源码构建

需要 macOS、支持 Swift 6 的 Xcode 或 Command Line Tools，以及 Python 3。以下命令在仓库根目录执行。

1. 获取本版本使用的 llama.cpp 二进制依赖。即使只用远程 API，当前构建仍会链接这个框架。

   ```sh
   mkdir -p Packages/ModelRuntime/Vendor
   curl -fL https://github.com/ggml-org/llama.cpp/releases/download/b9402/llama-b9402-xcframework.zip -o /tmp/llama-b9402-xcframework.zip
   echo 'ac9adcabf4638eced651010ff8280df98b9bb094d2ba882d89823bbd3c63b895  /tmp/llama-b9402-xcframework.zip' | shasum -a 256 -c - &&
     ditto -x -k /tmp/llama-b9402-xcframework.zip Packages/ModelRuntime/Vendor &&
     mv Packages/ModelRuntime/Vendor/build-apple/llama.xcframework Packages/ModelRuntime/Vendor/
   ```

2. 编译 Release 可执行文件。

   ```sh
   swift build -c release --sdk "$(xcrun --sdk macosx --show-sdk-path)" \
     -Xlinker -rpath -Xlinker '@executable_path/../Frameworks'
   ```

3. 要在本机安装，用 Xcode 的「Settings → Apple Accounts → 你的团队 → Manage Certificates」创建自己的 **Apple Development** 证书。首次安装时固定其指纹，后续构建沿用同一签名身份，以便 macOS 在更新后识别同一款应用。

   ```sh
   security find-identity -v -p codesigning
   Scripts/dev-signing-identity.sh --pin <你的40位大写证书指纹>
   Scripts/package-keytype-dev.zsh
   open '/Applications/KeyType Dev.app'
   ```

## 许可证

本项目沿用上游 MIT 许可证和原作者的版权声明。[LICENSE](LICENSE)
