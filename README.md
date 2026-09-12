# singbox-lite

> 一个面向 **Alpine Linux** 的 sing-box 极简一键部署脚本：自动拉取最新 musl 静态构建，交互式配置 **AnyTLS** 或 **Shadowsocks(aes-256-gcm)** 服务端，自签 TLS 证书，OpenRC 开机自启，执行完直接吐出可导入客户端的分享链接和证书全文。

单文件 POSIX sh 脚本，无第三方依赖，不写复杂配置，装完即用。

---

## 项目简介

在 Alpine Linux（VPS / 容器 / 软路由）上手工部署 sing-box 需要处理一堆繁琐事情：区分 musl 与 glibc 构建、找对 CPU 架构的压缩包、生成带 SAN 的自签证书、手写 inbound 配置、注册 OpenRC 服务、最后还得自己把参数拼成分享链接——每一步都容易踩坑。

`singbox-lite` 把这些揉进一个脚本里：

- **下载最新版**：从 GitHub Release 查询最新 tag，按本机架构匹配 **musl** 构建（Alpine 用的是 musl libc，直接用 glibc 版本会跑不起来）；
- **只问四个问题**：服务器地址、SNI、端口、节点名，其余留空回车即可；
- **协议二选一**：AnyTLS（抗 TLS-in-TLS 指纹识别）或 Shadowsocks `aes-256-gcm`（客户端兼容性最好）；
- **自动收尾**：签发自签证书 → 生成配置 → 语法校验 → 注册并启动 OpenRC 服务 → 打印分享链接 + 证书/私钥全文。

---

## 一键安装

在 Alpine Linux 上以 root 身份执行（推荐 wget）：

```sh
wget -O install-singbox.sh https://raw.githubusercontent.com/habazazaz/singbox-lite/main/install-singbox.sh && sh install-singbox.sh
```

curl 版本（Alpine 需先安装 curl：`apk add --no-cache curl`）：

```sh
curl -fsSL -o install-singbox.sh https://raw.githubusercontent.com/habazazaz/singbox-lite/main/install-singbox.sh && sh install-singbox.sh
```

也可以直接管道执行：

```sh
wget -qO- https://raw.githubusercontent.com/habazazaz/singbox-lite/main/install-singbox.sh | sh
```

> 脚本会从 `/dev/tty` 读取交互输入，因此用管道方式执行也不会出问题。
> 若 `raw.githubusercontent.com` 访问不畅，把域名换成本地可达的 GitHub 代理即可。

---

## 功能特性

| 特性 | 说明 |
| --- | --- |
| 最新版自动安装 | 通过 GitHub API 获取最新 release tag，失败时自动回退解析 `releases/latest` 的 302 跳转 |
| musl 构建匹配 | 自动识别 `x86_64 / aarch64 / armv7l / i386 / loongarch64 / riscv64 / mipsle` 并选择对应 musl 包 |
| 双协议支持 | `AnyTLS`（含官方默认 `padding_scheme`）与 `Shadowsocks` `aes-256-gcm` |
| 智能默认值 | 服务器地址回车即自动探测公网 IP（多源探测 + 本机地址兜底）；SNI 默认 `www.samsung.com`；端口回车随机分配；节点名默认 `singbox-<主机名>` |
| 自签证书 | 自动生成 10 年期证书，SAN 同时写入 `DNS:<SNI>` 与 `IP:<服务器地址>`；EC P-256 优先，兼容性不足时自动降级 RSA / 配置文件写法 |
| 配置安全 | 配置与私钥权限 `600/644`，覆盖前自动带时间戳备份；启动前执行 `sing-box check` 语法校验 |
| OpenRC 集成 | 生成 `/etc/init.d/sing-box`，设置开机自启，启动失败自动输出最近日志 |
| 结果直出 | 结束时打印分享链接、`cert.pem` 与 `key.pem` 全文、常用运维命令 |
| 非交互模式 | 支持 `SB_*` 环境变量一键批量部署，无需人工应答 |
| 幂等可重跑 | 重复执行会重新签发证书、备份旧配置并重启服务 |

---

## 系统要求

- **操作系统**：Alpine Linux（OpenRC），脚本按 Alpine 环境编写；其他 OpenRC 发行版理论可用但未测试
- **权限**：必须 `root`（需要写 `/usr/local/bin`、`/etc/sing-box`、`/etc/init.d` 并绑定端口）
- **Shell**：`/bin/sh`（busybox ash 即可，**不依赖 bash**）
- **架构**：`amd64` / `arm64` / `armv7` / `386` / `loong64` / `riscv64` / `mipsle(softfloat)`
- **依赖**：`wget`（或 `curl`）、`tar`、`openssl`、`ca-certificates`
  - 缺失时脚本会尝试 `apk add --no-cache` 自动补齐；若 `apk` 不可用会提示手动安装命令
- **网络**：需要能访问 GitHub Release 与 `api.github.com`
- **磁盘**：约 50 MB（含解压临时文件）

---

## 使用说明

### 交互流程

执行脚本后按提示依次输入，**直接回车即使用方括号中的默认值**：

```
请选择协议:
  1) AnyTLS         —— 基于 TLS 的代理协议，抗 TLS-in-TLS 指纹识别（推荐）
  2) Shadowsocks    —— 传统 AEAD 加密，客户端兼容性最好（aes-256-gcm）
输入序号 [1]: 1
[+] 协议: anytls
[*] 正在探测本机公网地址 ...
服务器地址（客户端连接地址） [203.0.113.10]:      ← 回车用自动探测到的公网 IP
TLS SNI 域名 [www.samsung.com]:                    ← 回车用默认值
监听端口 [41875]:                                  ← 回车用随机端口，也可指定 8443
节点名称 [singbox-vps01]:
[*] 已自动生成随机口令: 9f2c1ab7d3e84560b1c7ff0a2e6d9b31
```

### 脚本执行阶段

1. 检查并补齐系统依赖
2. 识别架构 → 查询最新版本 → 下载 musl 构建 → 安装到 `/usr/local/bin/sing-box`
3. 交互收集 4 项参数（协议 / 地址 / SNI / 端口 / 节点名）
4. 生成自签名证书 `/etc/sing-box/cert.pem`、`/etc/sing-box/key.pem`
5. 写入 `/etc/sing-box/config.json`（权限 600）并执行 `sing-box check`
6. 生成 OpenRC 服务、设置开机自启并启动
7. 输出分享链接 + 证书/私钥全文 + 运维命令

### 执行结果示例

```
部署完成
----------------------------------------------------------------------
  协议      : anytls
  服务器    : 203.0.113.10
  端口      : 8443
  SNI       : www.samsung.com
  节点名称  : singbox-vps01
  口令      : 9f2c1ab7d3e84560b1c7ff0a2e6d9b31

分享链接（可直接导入客户端）
----------------------------------------------------------------------
anytls://9f2c1ab7d3e84560b1c7ff0a2e6d9b31@203.0.113.10:8443/?sni=www.samsung.com&insecure=1#singbox-vps01

自签名证书全文  cert.pem
----------------------------------------------------------------------
-----BEGIN CERTIFICATE-----
MIIB8DCCAZegAwIBAgIUId9Lw9Gih8qWsl9QU8UnZjY8FX0wCgYIKoZIzj0EAwIw
...（略）
-----END CERTIFICATE-----
```

把上面的链接复制到客户端即可导入节点。

---

## 使用示例

### 1. AnyTLS（推荐，走 TLS，抗指纹识别）

```sh
wget -O install-singbox.sh https://raw.githubusercontent.com/habazazaz/singbox-lite/main/install-singbox.sh && sh install-singbox.sh
# 协议选 1，SNI 回车默认 www.samsung.com，端口填 8443
```

生成的分享链接形态：

```
anytls://<口令>@<服务器>:<端口>/?sni=<SNI>&insecure=1#<节点名>
```

### 2. Shadowsocks（兼容性最好）

```sh
sh install-singbox.sh
# 协议选 2，端口填 8388
```

生成的分享链接形态（SIP002）：

```
ss://base64url(aes-256-gcm:<口令>)@<服务器>:<端口>#<节点名>
```

### 3. 非交互批量部署

所有交互项都可用环境变量预置，填写后该项不再提问：

```sh
SB_PROTOCOL=anytls \
SB_SERVER=203.0.113.10 \
SB_SNI=www.samsung.com \
SB_PORT=8443 \
SB_NAME=Tokyo-01 \
SB_PASSWORD=YourStrongPassword \
sh install-singbox.sh
```

SS 版本：

```sh
SB_PROTOCOL=ss SB_SERVER=203.0.113.10 SB_PORT=8388 SB_NAME=SS-01 sh install-singbox.sh
```

### 4. 只生成配置，不下载二进制 / 不注册服务

```sh
SB_SKIP_INSTALL=1 SB_SKIP_SERVICE=1 SB_PROTOCOL=anytls SB_SERVER=203.0.113.10 sh install-singbox.sh
```

### 5. 服务运维

```sh
rc-service sing-box start      # 启动
rc-service sing-box restart    # 重启
rc-service sing-box stop       # 停止
rc-service sing-box status     # 状态
rc-update add sing-box default # 开机自启
tail -f /var/log/sing-box/sing-box.log   # 实时日志
sing-box check -c /etc/sing-box/config.json   # 校验配置
```

---

## 环境变量一览

| 变量 | 说明 |
| --- | --- |
| `SB_PROTOCOL` | `anytls` 或 `ss`，预设后跳过协议选择 |
| `SB_SERVER` | 服务器地址（客户端连接地址），预设后跳过探测与提问 |
| `SB_SNI` | TLS SNI，仅 AnyTLS 使用 |
| `SB_PORT` | 监听端口，1–65535 |
| `SB_NAME` | 节点名称（分享链接备注名） |
| `SB_PASSWORD` | 连接口令，不填则随机生成 32 位十六进制 |
| `SB_SKIP_INSTALL` | 置 `1` 跳过下载安装，仅生成配置 |
| `SB_SKIP_SERVICE` | 置 `1` 跳过 OpenRC 服务注册与启动 |
| `SB_BIN_DIR` | 二进制目录，默认 `/usr/local/bin` |
| `SB_CONF_DIR` | 配置目录，默认 `/etc/sing-box` |
| `SB_LOG_DIR` | 日志目录，默认 `/var/log/sing-box` |
| `SB_INIT_DIR` | init 脚本目录，默认 `/etc/init.d` |

---

## 文件布局

安装完成后，系统上的相关路径：

```
/usr/local/bin/sing-box          # sing-box 主程序（最新 musl 构建）
/etc/sing-box/config.json        # 服务端配置（权限 600）
/etc/sing-box/cert.pem           # 自签名证书
/etc/sing-box/key.pem            # 证书私钥（权限 600）
/etc/sing-box/*.bak              # 覆盖前的自动备份
/etc/init.d/sing-box             # OpenRC 服务脚本
/var/log/sing-box/sing-box.log   # 运行日志
/var/log/sing-box/stdout.log     # 进程标准输出
/var/log/sing-box/error.log      # 进程错误输出
```

对应的服务端配置结构（AnyTLS 示例，字段值与脚本生成的一致）：

```json
{
  "log": { "level": "warn", "timestamp": true, "output": "/var/log/sing-box/sing-box.log" },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": 8443,
      "users": [{ "name": "singbox-vps01", "password": "9f2c...b31" }],
      "padding_scheme": [
        "stop=8",
        "0=30-30",
        "1=100-400",
        "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000",
        "3=9-9,500-1000",
        "4=500-1000",
        "5=500-1000",
        "6=500-1000",
        "7=500-1000"
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.samsung.com",
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/key.pem"
      }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
```

Shadowsocks 模式的 inbound 部分：

```json
{
  "type": "shadowsocks",
  "tag": "ss-in",
  "listen": "::",
  "listen_port": 8388,
  "method": "aes-256-gcm",
  "password": "9f2c...b31"
}
```

---

## 客户端支持

| 协议 | 支持的客户端 |
| --- | --- |
| AnyTLS | sing-box（SFA / SFI / CLI）、NekoBox、NekoRay、Hiddify、Mihomo Party、Shadowrocket 2.2.65+ |
| Shadowsocks | 几乎所有客户端（v2rayN、Clash 系列、Shadowrocket、sing-box 全家桶等） |

> AnyTLS 是较新的协议，客户端覆盖面窄于 SS；v2rayNG、Streisand、V2Box 等不支持 AnyTLS，导入会失败。AnyTLS 仅走 TCP。
> sing-box 服务端要求 **≥ 1.12.0** 才支持 AnyTLS，本脚本始终安装最新版，无需担心。

### 关于自签名证书

脚本使用自签证书（没有域名和 Let's Encrypt 的情况下最省事），因此：

- 分享链接里已带 `insecure=1`，客户端会自动跳过证书校验；
- 若客户端不识别该参数，请手动勾选「允许不安全 / 跳过证书校验（allowInsecure）」；
- 也可以把输出的 `cert.pem` 导入客户端信任，之后把链接里的 `insecure=1` 改为 `0`，或者换成正式域名证书（把 `certificate_path` / `key_path` 指向 `fullchain.pem` / `privkey.pem` 即可）。

---

## 常见问题

**Q：脚本报「请以 root 身份运行」**
A：用 `sudo -i` 或 `su -` 切到 root 再执行。

**Q：下载失败 / 卡住**
A：脚本需要访问 GitHub Release 和 `api.github.com`。先确认网络可达，必要时在服务器上配置代理后再运行：
`export https_proxy=http://<your-proxy>:<port>`

**Q：`暂不支持的 CPU 架构`**
A：sing-box 官方没有为 armv5 / armv6 / mips / mips64 / ppc64le 提供 musl 构建。可改用 glibc 版本或自行编译。

**Q：服务没起来**
A：先看日志 `tail -n 50 /var/log/sing-box/sing-box.log`。常见原因是端口被占用（`netstat -tlnp | grep <端口>`）或 IPv6 被内核禁用（脚本会自动回退监听 `0.0.0.0`，如仍有问题请检查 `/proc/sys/net/ipv6/conf/all/disable_ipv6`）。

**Q：客户端连不上**
A：逐项排查：① 云厂商安全组 / 本机防火墙是否放行了对应 **TCP** 端口；② 服务器地址是否是客户端可达的公网地址（不是内网 IP）；③ 链接里的 SNI、端口、口令是否与服务端一致；④ 客户端是否支持 AnyTLS。

**Q：想换端口 / 换协议 / 换 SNI**
A：直接重新运行脚本，旧配置和旧证书会自动备份为 `*.bak`，然后在客户端重新导入新链接。

**Q：想删除 / 卸载**
A：

```sh
rc-service sing-box stop
rc-update del sing-box default
rm -f /etc/init.d/sing-box /usr/local/bin/sing-box
rm -rf /etc/sing-box /var/log/sing-box
```

---

## 目录结构

```
singbox-lite/
└── install-singbox.sh    # 一键安装配置脚本（POSIX sh，单文件）
```

---

## 免责声明

本项目仅供学习与自建网络服务的技术研究使用。请遵守你所在国家/地区的法律法规以及服务器提供商的服务条款，使用者需自行承担因使用本脚本产生的一切后果。

## License

未指定（如需开源协议请自行补充，例如 MIT）。
