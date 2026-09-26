# 可选：随 Codex App 自动启停 Work Conversation Tunnel

先按仓库根目录的 README 完成 Tunnel 配置，并确认手动运行正常。此功能只管理当前仓库的 Work Conversation Tunnel，不管理其他 MCP。

在**管理员 PowerShell** 中进入仓库根目录，运行：

```powershell
& .\app-lifecycle\install.ps1
```

脚本查找当前安装的官方 Codex App，为其 `ChatGPT.exe` 创建 Windows 进程启动和退出事件任务。安装时会开启 Windows 的进程创建和终止审计，并在 `.runtime/data` 备份原审计策略及已有同名任务。任务运行在隐藏后台；当 App 完全退出后，约 12 秒停止 Work Conversation Tunnel。

若还要监测其他安装位置的 Codex App，可额外指定该程序的完整路径：

```powershell
& .\app-lifecycle\install.ps1 -AdditionalAppPaths 'D:\Apps\Codex\ChatGPT.exe'
```

**每次 App 更新导致安装路径变化后，重新运行安装命令。**旧版本的任务只匹配安装时发现的路径。

查看任务状态：

```powershell
Get-ScheduledTask -TaskName WorkConversationTunnelEvent
Get-Content .\.runtime\data\app-lifecycle.log -Tail 20
```

卸载此自动启停任务：

```powershell
Unregister-ScheduledTask -TaskName WorkConversationTunnelEvent -Confirm:$false
```

卸载任务不会自动恢复 Windows 的审计策略。安装前的审计策略备份位于 `.runtime/data/audit-policy-before-*.csv`，应先确认电脑上其他程序是否也依赖进程审计，再决定是否恢复。

网页端要使用该服务需要本机 Codex App 的Tunnel保持运行。
