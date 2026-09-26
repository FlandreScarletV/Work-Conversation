## 前言

面向 Windows 用户。

## 🚀 安装和使用

### 1.💻 环境要求

安装 **[Node.js 22](https://nodejs.org/zh-cn)** 或更高版本。
安装 **[PowerShell](https://learn.microsoft.com/zh-cn/powershell/scripting/install/install-powershell?view=powershell-7.6)**。

### 2.📁 指定 Codex 数据目录

指定自己的 `CODEX_HOME`。`CODEX_HOME` 就是你的 Codex 数据根目录。 通常需要包含：

`会话`

`archived_sessions`

`session_index.jsonl`

Work Conversation 会从这些数据中查找、搜索和读取工作会话。

### 3.🔗 连接 ChatGPT

**✅（推荐）✅** 在 ChatGPT / Codex 桌面端中进入 **插件**，点击**添加插件市场**，直接连接本页仓库
<p align="center"><img width="751" alt="image" src="https://github.com/user-attachments/assets/0a2fa86f-d340-4648-bff1-55d528283012" /></p>

```
https://github.com/FlandreScarletV/Work-Conversation.git
```

即可。

另一种方式就是点击**创建MCP应用**，但是这种方式要打开OpenAI的开发者模式，一般不推荐这种方式。tunnel ID获取点击[这里](#tunnel)。名称描述随便，连接方式选择 `Tunnel`，填写`tunnel_id`，身份验证选**无需身份验证**，我已了解，创建。

连接成功后，建议先进行一次简单测试，例如：

```
@Work Conversation 列出我最近的工作会话。确认 ChatGPT 能返回结果。
```


之后就不用命令行@了，可直接使用自然语言，ChatGPT 会根据请求调用相应工具。
- 例如：
    - 列出我最近的工作会话。
    - 搜索「XXX」工作会话。
    - 读取「XXX」工作会话。
    - 搜索哪些工作会话提到了「XXX」。
    - 继续读取这个工作会话。
    - 读取上一个工作会话。
如果存在多个名称相似的工作会话，Work Conversation 会先返回候选结果，让用户选择目标，而不会随意读取其中一个。

---

<span id="tunnel"></span>

### 4.🚇 配置 Tunnel

> ⚠️⚠️⚠️[!WARNING]⚠️⚠️⚠️
> 
> 请注意！！！请注意！！！请注意！！！
> 
> 通过网页端或远程设备访问本机工作会话时，需要通过 ChatGPT 的开发者模式 / 自定义 MCP App 接入；支持本地插件市场的桌面客户端可直接使用本地插件。
> 开发者模式连接未经验证或不可信的 MCP Server / App 会增加安全风险，包括提示词注入、敏感数据泄露以及意外调用工具等。
> 使用本项目产生的账号、数据、安全或配置风险由使用者自行判断和承担。
ChatGPT 不能直接连接运行在用户电脑上的本地 MCP Server，所以运行 `tunnel-client` 需要一个可用于 Secure MCP Tunnel 的运行时 API key。

首先打开👉[ChatGPT 网页版](https://chatgpt.com/)，点击**左下角用户** → **设置** → **账户安全与登录** → **开发人员模式**。
<p align="center">
  <img width="850" alt="image" src="https://github.com/user-attachments/assets/7eba4e97-036c-46eb-aad8-e9cb6d340623" />
</p>

然后打开👉[openai开发者平台](https://platform.openai.com/settings/organization/tunnels)获取tunnel ID，先点击右上角的**Download tunnel-client**，然后点击**create tunnel**创建tunnel ID。
<img width="1967" height="330" alt="image" src="https://github.com/user-attachments/assets/081ce840-06e6-46f4-b848-14b03e4102d5" />

获取👉[openai api key](https://platform.openai.com/)，点击**API Keys**页面 → **Create new secret key** → 选择**Owned by You** → 填入**名字** → Project选择**Default Project**，没有Project就先创建Project → 有效期自己决定 → Permission选**Read only** → **Create new secret key**。

运行 `connect-tunnel.ps1`。
如果要指定 Tunnel 客户端位置，运行：

    ```.\connect-tunnel.ps1 -TunnelClient "D:\path\to\tunnel-client.exe" -CodexDataRoot "D:\path\to\codex-data" ```
    
通过 Tunnel 客户端的 doctor 配置诊断后，API key 会使用当前 Windows 用户的 DPAPI 加密保存，且只保存在你的电脑上。

如果需要替换已经保存的 API key：
    
    ```.\connect-tunnel.ps1 -ReplaceSavedKey -DoctorOnly```
    
首次配置成功后，相关本机配置会保存在 `.runtime` 目录。
`.runtime` 中包含本机路径、Tunnel ID、API Key和日志。
配置完成tunnel后，运行 `start-work-background.ps1`。

该脚本会在后台启动：
- Work Conversation MCP
- Tunnel
- 后台守护进程
如果 Tunnel 意外退出，守护进程会尝试自动恢复。
需要停止时运行：
    ```powershell
    .\stop-work-background.ps1
    ```

---

## 🛠️ 功能列表

| 工具 | 作用 |
| --- | --- |
| `list_work_threads`| 列出最近任务及标题、日期、任务 ID、归档状态 |
| `search_work_threads`| 用近似标题查找；多个结果时先让用户选择 |
| `read_work_thread`| 按任务 ID 分页读取，返回 `nextCursor`（下一页位置） |
| `search_work_messages`| 按短语搜索用户和助手的可见消息 |

---

## ⚖️ 开源说明

Work Conversation 是一个第三方开源项目。不是 OpenAI 官方产品。
项目根据 MIT License 发布。
```
Copyright (c) 2026 FlandreScarletV
```
MIT License 允许：使用、复制、修改、合并、发布、分发、再许可、商业使用。

但复制或发布本软件及其主要部分时，需要保留原有的：
```
Copyright notice
MIT License permission notice
```
完整许可条款请参阅仓库中的：

`LICENSE`

## 📌 其他说明

提交 Issue 或 Pull Request 前，请确保不包含 **.runtime**、不包含 **API key**、不包含 **Tunnel ID**、不包含**会话 JSONL**、不包含个人敏感信息、不包含其他用户的聊天记录、不提交未经授权的第三方代码或资源。
