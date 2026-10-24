# ThuNet-AutoLogin

清华大学校园网 srun 门户（`auth4.tsinghua.edu.cn`）的**无人值守自动登录 + 持续检测重连**小工具。

给一台放在机房/自习室、人不常在场的有线口主机用：开机、休眠唤醒、掉线之后自己把网重新认证上；也可以放在自己的笔记本上用。

- 零依赖：只用 PowerShell 5.1 内建 + .NET 内建。不装模块、不装 Python、不调外部程序（安装脚本里会调 `schtasks` 和 `wscript`，那是 Windows 自带的）。
- 单文件可用：把 `ThuNet-Login.ps1` 单独拷走也能跑。
- 口令不落明文：账号名放明文文件，口令用 Windows DPAPI（`CurrentUser` 作用域）加密后另存一个文件。
- 静默运行：计划任务经 `wscript RunHidden.vbs` 启动，不弹黑框。

> 许可证 MIT。这个工具只做一件事：把你的校园网账号送到学校自己的认证接口上。它不代理流量、不改系统代理、不动别人的计划任务。

## 快速开始（双击一个脚本）

把整个仓库目录拷到目标机器上，**双击 `Setup-ThuNetAutoLogin.cmd`** 就行。它会一口气做完：

1. 问你的**学号**和**校园网口令**（口令输入不回显，存法见下文）；
2. 注册「登录时自动启动」的计划任务；
3. **立刻把看守启动起来**，不用等下次登录；
4. 当场验证并打印结论：任务在不在、看守进程在不在、链路通不通。

想先看它会做什么、不实际改动任何东西：

```
Setup-ThuNetAutoLogin.cmd -WhatIf
```

以后**改了校园网口令**，双击 `Change-ThuNetCredential.cmd`（详见下文「改了口令或账号之后」）。

### 想手动做 / 用命令行

在**你自己的** PowerShell 窗口里，`cd` 到这个目录，下面的三步与上面等价：

**第 1 步 · 存账号**（会交互式问你账号和口令，口令输入不回显）

```powershell
.\Set-ThuNetCredential.ps1
```

**第 2 步 · 先手动验一次**（这一步只读，不登录，改不了任何东西）

```powershell
.\ThuNet-Login.ps1 -Status
```

看到 `link : authenticated, direct internet works` 就说明链路是通的、`ac_id` 也认出来了。如果 `link` 是 `NOT authenticated`，跑一次真正登录：

```powershell
.\ThuNet-Login.ps1 -Once
```

**第 3 步 · 挂成计划任务**（登录时自动启动，之后它自己看着）

```powershell
.\Install-ThuNetAutoLogin.ps1
```

装完可以立刻试跑一次，不用等下次登录：

```powershell
schtasks /run /tn ThuNet-Login
```

装之前想先看看它要注册什么，加 `-WhatIf` 就只打印任务 XML、什么都不改：

```powershell
.\Install-ThuNetAutoLogin.ps1 -WhatIf
```

## 日常会用到的命令

| 命令 | 干什么 |
|---|---|
| `Setup-ThuNetAutoLogin.cmd` | **双击入口**：存凭据 → 装任务 → 立刻启动 → 验证。幂等，可重复运行；加 `-WhatIf` 只看不做 |
| `Change-ThuNetCredential.cmd` | **改了校园网口令就双击这个**：重输凭据 → 重启看守 → 当场验证一次登录 |
| `.\ThuNet-Login.ps1 -Status` | 只读：报账号、链路状态、识别到的 ac_id、绑定的本机地址。不写日志、不登录 |
| `.\ThuNet-Login.ps1 -SelfTest` | 只读：拿一组固定测试向量验 srun SRBX1 编码器，不联网。换机器/换 PowerShell 版本后先跑这个 |
| `.\ThuNet-Login.ps1 -Once` | 登录一次（链路已经通就什么都不做） |
| `.\ThuNet-Login.ps1 -Watch -IntervalSeconds 60` | 常驻，每 60 秒查一次，掉了就重登 |
| `.\ThuNet-Login.ps1 -Watch -MaxRuns 2 -IntervalSeconds 3` | 限次常驻，跑 2 轮就退。`-MaxRuns 0`（默认）是不限次 |
| `.\ThuNet-Login.ps1 -TestLogin` | 试登一次并打印服务端原始返回，排查认证问题时用 |
| `.\ThuNet-Probe.ps1 -Watch` | 只做探测、记录门户拦截现场（默认 120 秒一次），登录脚本行为不对时用来取证 |
| `.\Set-ThuNetCredential.ps1 -Show` | 只显示账号名与「口令已设置」，**不显示口令** |
| `.\Uninstall-ThuNetAutoLogin.ps1` | 删掉自己装的那个计划任务 |

常用参数：

- `-CredentialDir <路径>`：凭据目录。默认 `%LOCALAPPDATA%\ThuNetAutoLogin\creds`。
- `-LogDir <路径>`：日志目录。默认 `%LOCALAPPDATA%\ThuNetAutoLogin\logs`。
- `-IntervalSeconds <秒>`：watch 间隔。
- `-RunLevel LeastPrivilege`（默认）/ `HighestAvailable`：任务用普通令牌还是完整令牌。**这两个是 XML 里的写法**；PowerShell cmdlet 里对应的词是 `Limited` / `Highest`——两者不是一套词表，写错会得到 `The task XML contains a value which is incorrectly formatted or out of range`。脚本两种拼写都收，XML 里落的永远是 schema 的值。

## 凭据是怎么存的（换机器一定要看这段）

存了两个文件，都在凭据目录里：

| 文件 | 内容 | 保护方式 |
|---|---|---|
| `ThuNet-user.txt` | 账号（学号/用户名） | 明文。它不是秘密，而且必须不解密就能读出来给 `-Show` 和登录脚本用 |
| `ThuNet-pass.dpapi` | 口令 | Windows DPAPI 加密（`CurrentUser` 作用域）后的十六进制串 |

DPAPI 加密的事实：

- **只有加密它的那个 Windows 用户能解开**。其他用户拿到文件也解不开。
- **绑定这一台机器**。把 `ThuNet-pass.dpapi` 拷到笔记本上，在笔记本上解不开。
- **不需要、也没有任何密钥文件**要保管——密钥由 Windows 自己按用户/机器派生。
- 口令**不进日志、不上控制台、不走命令行参数**（命令行参数别的进程看得见，还会进 shell 历史）。设置脚本用 `Read-Host -AsSecureString` 读两次做确认；**两次不一致会重问（最多 3 次）**，三次都没对上就明确打印「未保存」并退出——不会静默作废一次操作。

所以：

> **换机器（笔记本）必须重新跑一遍 `Set-ThuNetCredential.ps1`。** 不是可选步骤，DPAPI 就是按机器/用户来的。
> 同一台机器上换 Windows 用户也一样，要为新用户重跑。

登录脚本 `ThuNet-Login.ps1` **只读凭据，从不写**。整个仓库里唯一会写凭据的是 `Set-ThuNetCredential.ps1`。凭据缺失时登录脚本只会让你去跑那个脚本。

兼容旧目录：`-CredentialDir` 指到一个用别的名字存过凭据的目录时，除了 `ThuNet-*.txt` / `ThuNet-*.dpapi`，也会认 `portal-user.txt` / `portal-pass.dpapi` 这两个旧名字（只读，不会往旧名字上写）。

## 远控/联通的路径选择（局域网优先，Tailscale 兜底）

机器同时能被两种地址访问时，**不需要在客户端里手动切换**，但也不是客户端自动帮你切：

- **Moonlight 不会自动切换**。它连的是你在客户端里填的那一个地址，那个地址不通就直接失败，不会去试另一个。
- **用 Tailscale 地址就能达到「自动最优」的效果**：两台机器在同一局域网/校园网内时，Tailscale 会自动建立**直连**（`direct`，实测 1–3 ms，与局域网直连没有差别）；设备离开该网络后自动改走中继。全程不需要你操作。
- 所以推荐填 MagicDNS 名（如 `host.tailnet.ts.net`）或 Tailscale IP；把局域网 IP 留作备用条目，只在 Tailscale 没开时用。

判断当前实际走哪条：`tailscale ping <peer>` 输出里带 `via DERP` 就是绕中继了；主机侧 `tailscale status` 的 peer 行显示 `direct` 即直连。

## 改了口令或账号之后

双击 **`Change-ThuNetCredential.cmd`**（等价于 `Setup-ThuNetAutoLogin.ps1 -ForceCredential`）：重输账号与口令 → 覆盖凭据文件 → 重启看守 → **真的尝试一次登录，并用 204 连通性探测确认结果**。

判断标准只有一个：结尾打印 `now online - the stored credential works` 才算成功。若打印 `STILL OFFLINE`，这次运行就是**失败**——多半是口令不对（注意：**srun 门户口令不是 Tsinghua-secure 的 WiFi 口令**），或者这个墙口需要先用浏览器手动登录一次。

若打印 `already online - no login needed`，说明机器当时本来就通着，**这次并没有验证到口令**。

不需要重启机器，也不需要重装计划任务：

- 看守**每一轮都重新读凭据文件**（没有内存缓存），所以新口令在下一个轮询周期（默认 60 秒）内就生效；
- 凭据文件一旦被改写，看守会**清空失败计数与退避窗口**——否则改完口令还要等旧口令挣来的退避，看起来就像「工具没理我」。

**如果口令改了却忘了更新这里**（你在门户改了密码，这台机器还留着旧的）：看守不会无限硬试。同一个接口**前两次失败各等 5 分钟，连续第 3 次起升到 30 分钟**，并在第 3 次时往日志里单独写一行，明确提示用 `Set-ThuNetCredential.ps1` / `Change-ThuNetCredential.cmd` 更新口令。这条退避的意义是**不拿你的机器去撞门户的失败计数**。

## 安装脚本到底装了什么

`Install-ThuNetAutoLogin.ps1` 注册一个计划任务（默认名 `ThuNet-Login`）：

- **触发器**：该用户登录时（延迟 15 秒，等网卡拿到地址）+ 每天 09:00 一次。
  加每日触发器是因为**登录触发器在休眠/唤醒时不会触发**，而休眠唤醒正是会掉认证的场景之一。
- **动作**：`wscript.exe //B //Nologo RunHidden.vbs "<脚本路径>" -NoLogo ... -File "<脚本路径>" -Watch -IntervalSeconds 60`
  必须经 `wscript`，不能直接写一个 `powershell.exe` 动作：后者会创建控制台窗口，`-WindowStyle Hidden` 也还是会闪一下黑框。
- **主体**：当前用户，`LogonType InteractiveToken`。这一条是硬要求——只有跑在用户自己的会话与令牌里，DPAPI 口令文件才解得开。也正因为如此，注册普通的按用户任务**不需要管理员权限**。
- **`MultipleInstancesPolicy IgnoreNew`**：任务层面保证只有一个实例；脚本内部还有一个 `Local\ThuNetAutoLoginWatcher` 互斥体，用来挡住手动重复启动。
- **`ExecutionTimeLimit PT0S`**（不限时）：它就是一个常驻看守，给它设时限等于定时把自己杀掉。
- **`RestartOnFailure`**：进程崩了 1 分钟后最多拉起 3 次，不用等到下次登录。

加 `-WithProbe` 会多注册一个 `ThuNet-Probe`，只做探测取证。不需要就别装。

为什么用 `schtasks /create /xml` 而不用 `Register-ScheduledTask`：

> `Register-ScheduledTask` 的失败是**非终止错误**，`try/catch` 抓不到。围着它写 try/catch 的安装脚本会在什么都没装上的情况下打印「安装成功」。`schtasks` 是外部程序，结果是真实的进程退出码（`$LASTEXITCODE`），能诚实地检查。安装脚本里每次 `schtasks` 调用之后都查了退出码，装完还会 `schtasks /query` 读回来确认。

## 两个容易读错的语义

### 1. `msg=ip_already_online_error` 不代表我们登录成功了

服务端成功时回 `error=ok` / `msg=login_ok`。它也可能回：

```json
{"error":"ok","msg":"ip_already_online_error", ...}
```

这句话的意思是「**这个 IP 本来就在线**」，也就是**在这次请求之前就已经认证过了**——它不说明这次请求登录成功。本脚本不把 `ip_already_online_error` 当成功判据；要判断「到底通没通」，看的是真实连通性探测（`generate_204` 返回 204 且响应体符合预期，等等），而不是服务端那句话。

把两者混为一谈，是这类工具能一直报「已登录」而端口其实是封的最常见原因。

### 2. ac_id 属于墙口，不要硬编码

`ac_id` 是**你插的那个网口所属的接入控制器编号**，换个楼、换个口就不一样。脚本靠「发现 + 缓存」拿它：

1. 先读缓存（上次成功的值）；
2. 再看当前门户拦截暴露了什么——拦截会把浏览器导向 `.../srun_portal_pc?ac_id=<口>&theme=pro` 或 `.../index_<口>.html`，尾号就是这个口的 ac_id；
3. 再扫浏览器历史里出现过的 ac_id（第一次在新墙口上时，浏览器访问门户的 URL 已经在磁盘上了）；
4. 最后才是一组兜底值。

**脚本里出现的 `173` 是开发者实测那个墙口的真值，只作为兜底示例，不是「清华的 ac_id」。** 换环境以发现结果为准。

试错代价很低：错的 ac_id 只会换回一个 `E2808 Control policy not found`，值一次请求。拿到 `E2808` 时会自动换下一个候选，成功的那个会被缓存下来。

## 排错

### 症状：脚本什么都没干，日志里是 `no usable interface address - nothing to do`

解析本机网卡**不能解析 `netsh` 的本地化输出**。同一份脚本，从交互式窗口跑能认出两块网卡，被计划任务以无控制台方式拉起就一块都认不出来——差别就在控制台：交互式窗口下 `netsh` 输出英文的 `Configuration for interface "..."` / `IP Address:` 行，没有控制台的进程拿到的是本地化（中文）的，英文正则一条都匹配不上，于是看守什么都不做。

本脚本用 `[System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()` 拿同样的数据，**任何语言环境都一样，也不需要解析文本**。别把它改回 `netsh`。

### 症状：门户回 `auth_info_error`

构造 JSON 时**不要用 PowerShell 的 `-f` 格式化运算符**。`info` 字段是一个 JSON 对象，里面全是字面的 `{}`，而 `-f` 会把 `{...}` 当格式项：

```
Input string was not in a correct format.
```

结果是 `$infoJson` 变成空串，服务端回 `auth_info_error`。脚本里用字符串拼接就是为了绕开这一整类问题。JSON 必须和 Python `json.dumps` 的默认写法**逐字节一致**（`":"` 后有空格、`", "` 后有空格），因为编码器输出是跟 Python 参考实现逐字节比对过的。

### 症状：`-Status` 卡住几分钟，或者 CPU 被占满一个核

请求**不能走系统代理，也不能让绑定委托无限重试**。两件事：

- 校园门户走本地链路。让它穿过本机的 HTTP 代理（比如某些客户端监听在 `127.0.0.1:7890`）是错的——而且**代理客户端不在的时候正好就是它该工作的时候**。所以每个请求都设 `$req.Proxy = $null`。
- 把请求源地址绑到有线网卡（`Set-BindDelegate`）是必要的：`get_challenge` 会把它看到的地址回显回来，登录认证的正是那个地址。如果请求从 WiFi 兜底出口出去，认证上的就是 WiFi 地址，有线口依然是封的——而所有连通性探测都会说「在线」，因为 WiFi 那条路是通的。
  但 `BindIPEndPointDelegate` 只要返回值，框架就会**一直重试**；只有返回 `$null` 才放弃。原来无条件返回端点，于是每一次失败连接都变成一个占满一个核的忙重试循环（这就是 `-Status` 会挂住的原因）。脚本里重试 2 次后返回 `$null`，让请求正常报错。

### 症状：改了分辨率/…（不适用）—— 本工具不动显示设置

如果你是从一台同时跑着别的看守脚本的机器上把它抽出来的：**这个仓库和那些脚本没有任何依赖关系**，也不要把它混进同一个计划任务里。

### 症状：`-SelfTest` 报 `MISMATCH`

编码器被改过了。`-SelfTest` 的判据是一组固定测试向量（token + info 字符串 → 期望的十六进制与 `{SRBX1}` 串），这组向量录自 Python 参考实现 `github.com/WhymustIhaveaname/TsinghuaTunet` 的 `connect.py`，现在被**内嵌成常量**了，所以自检**不需要 Python、不需要联网**。要么把改动退回去，要么重新生成向量并同时更新 `$SelfTestExpectedHex` / `$SelfTestExpectedInfo`。

### 症状：任务装了但什么都没发生

按顺序查：

```powershell
schtasks /query /tn ThuNet-Login /v /fo LIST
Get-Content "$env:LOCALAPPDATA\ThuNetAutoLogin\logs\thunet-login.log" -Tail 30
.\ThuNet-Login.ps1 -Status
```

- 任务「上次运行结果」非 0：多半是路径里有空格但引号没包好，或者 `RunHidden.vbs` 不在原处了。
- 日志里是 `no credential found`：跑 `Set-ThuNetCredential.ps1`。**注意凭据目录要对上**——如果你当初用 `-CredentialDir` 存到了别处，安装时也要带同样的 `-CredentialDir`，否则任务会用默认目录、找不到凭据。
- 日志里是 `no usable interface address`：见上面那条。
- 日志里是 `blocked-backing-off(300s)` 或 `blocked-backing-off(1800s)`：某个网卡连续登录失败，脚本正在退避（防止一个永远不通的口每分钟发一次登录请求）。**前两次失败各等 5 分钟，连续第 3 次起等 30 分钟**，第 3 次时会单独写一行提示口令可能已改。这是设计行为，不是卡死；**更新了口令就会被立刻清空**（见「改了校园网口令或账号之后」）。

## 关于 `.ps1` 必须是纯 ASCII

仓库里所有 `.ps1` 和 `.vbs` 都是**纯 ASCII**（英文注释、英文控制台输出）。这不是风格偏好：

> 目标机只有 PowerShell 5.1。**没有 BOM 的 `.ps1` 会被按 cp936（GBK）解码**。中文注释一旦出现，某个字的多字节序列里会带出引号字节，字符串提前结束，**整个文件加载失败**——而且报出的行号还是错的，因为它是按解码错了的文本算的。

同样地，用编辑器改这些脚本时**不要给它加 BOM、也不要把编码存成别的**：这份仓库刻意保持 ASCII 就是为了让「有没有 BOM」不再成为变量。

`README.md` 和 `docs/*.md` 是中文——Markdown 没有这个限制。

## 卸载

```powershell
.\Uninstall-ThuNetAutoLogin.ps1            # 删计划任务（装了 probe 就加 -WithProbe）
.\Set-ThuNetCredential.ps1 -Remove         # 再删凭据文件
```

卸载脚本**只删自己装的任务**：它会先 `schtasks /query /tn <名字> /xml` 读回来，确认那个任务的动作确实指向本仓库目录，才删。名字相同但指向别处的任务会原样留着并提示你。

它**不动凭据和日志**。这是刻意的：分开两步，重装任务就不用重新输口令；而一次「顺手清理任务」也不会把看守还要用的凭据删掉。

## 文件清单

| 文件 | 作用 |
|---|---|
| `Setup-ThuNetAutoLogin.cmd` | **双击入口**：跑 `Setup-ThuNetAutoLogin.ps1`，跑完停住让你看结果 |
| `Setup-ThuNetAutoLogin.ps1` | 一键端到端：凭据 → 注册任务 → 立刻启动 → 验证。幂等 |
| `Change-ThuNetCredential.cmd` | 改了口令后双击：等于 `Setup-ThuNetAutoLogin.ps1 -ForceCredential` |
| `ThuNet-Login.ps1` | 主脚本。登录 + 看守。入口：`-Once` / `-Watch` / `-MaxRuns` / `-Status` / `-SelfTest` / `-TestLogin` / `-CredentialDir` / `-LogDir` / `-IntervalSeconds` |
| `Set-ThuNetCredential.ps1` | **本仓库唯一的凭据写入者**。交互式存账号与 DPAPI 口令；`-Show` / `-Remove` |
| `ThuNet-Probe.ps1` | 持续探测门户拦截并记录现场。`-Watch`（默认 120 秒）/ `-MaxRuns` / `-LogDir` |
| `RunHidden.vbs` | 无窗口启动器（`wscript`，`CREATE_NO_WINDOW`） |
| `ThuNet-TaskXml.ps1` | 生成计划任务 XML 定义。被安装脚本 dot-source；单独放是为了能单独检查 |
| `Install-ThuNetAutoLogin.ps1` | 注册「登录时启动」的计划任务。`-WhatIf` / `-Force` / `-WithProbe` / `-RunLevel` |
| `Uninstall-ThuNetAutoLogin.ps1` | 删除上述任务（只删指向本仓库的） |
| `docs/EVOLUTION.md` | 来历与关键决策：从哪抽出来、为什么这么存凭据、踩过哪些坑 |
| `docs/KNOWN_ISSUES.md` | 已知限制与没做的事 |

运行时会用到的目录（都不在仓库里）：

```
%LOCALAPPDATA%\ThuNetAutoLogin\
├── creds\                    凭据目录（-CredentialDir 可改）
│   ├── ThuNet-user.txt       明文账号
│   └── ThuNet-pass.dpapi     DPAPI 加密口令
├── logs\                     日志目录（-LogDir 可改）
│   ├── thunet-login.log
│   └── thunet-probe.log / thunet-probe-capture.txt
└── ThuNet-ac_id.txt          学到的 ac_id 缓存（机器本地状态，不是凭据）
```

`.gitignore` 把这些、以及 `*.dpapi` / `*.log` 都挡在提交之外。
