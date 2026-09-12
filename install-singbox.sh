#!/bin/sh
# ============================================================================
#  sing-box 一键安装 / 配置脚本   —— Alpine Linux (musl)
# ----------------------------------------------------------------------------
#   1. 自动从 GitHub Release 拉取【最新】的 musl 静态构建并安装
#   2. 交互式询问：服务器地址 / SNI / 端口 / 节点名称
#   3. 协议由用户二选一：AnyTLS  或  Shadowsocks(aes-256-gcm)
#   4. 自签名 TLS 证书 + OpenRC 开机自启服务
#   5. 结束后打印分享链接 + 证书/私钥全文
# ----------------------------------------------------------------------------
#  用法：
#     chmod +x install-singbox.sh && ./install-singbox.sh
#     # 或（管道方式）
#     wget -O install-singbox.sh <url> && sh install-singbox.sh
#
#  非交互（批量部署）环境变量覆盖，任一项填写后即跳过该项提问：
#     SB_PROTOCOL=anytls|ss   SB_SERVER=1.2.3.4   SB_SNI=www.samsung.com
#     SB_PORT=8443            SB_NAME=MyNode      SB_PASSWORD=xxxx
#     附加开关：SB_SKIP_INSTALL=1（跳过下载安装，仅生成配置）
#               SB_SKIP_SERVICE=1（跳过服务注册与启动）
# ============================================================================

set -eu

# ------------------------------------------------------------------- 常量 --
GITHUB_REPO="SagerNet/sing-box"
DEFAULT_SNI="www.samsung.com"

# 安装路径（可用 SB_* 变量覆盖，便于自定义路径）
BIN_DIR="${SB_BIN_DIR:-/usr/local/bin}"
CONF_DIR="${SB_CONF_DIR:-/etc/sing-box}"
LOG_DIR="${SB_LOG_DIR:-/var/log/sing-box}"
INIT_DIR="${SB_INIT_DIR:-/etc/init.d}"

BIN="${BIN_DIR}/sing-box"
CONFIG="${CONF_DIR}/config.json"
CERT="${CONF_DIR}/cert.pem"
KEY="${CONF_DIR}/key.pem"
INIT_FILE="${INIT_DIR}/sing-box"
SVC="sing-box"

TMP_DIR="$(mktemp -d 2>/dev/null || echo /tmp/singbox-install.$$)"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

# --------------------------------------------------------------- 输出辅助 --
info()  { printf '\033[36m[*]\033[0m %s\n' "$1"; }
ok()    { printf '\033[32m[+]\033[0m %s\n' "$1"; }
warn()  { printf '\033[33m[!]\033[0m %s\n' "$1"; }
die()   { printf '\033[31m[x]\033[0m %s\n' "$1" >&2; exit 1; }
hr()    { printf '%s\n' '----------------------------------------------------------------------'; }
title() { printf '\n\033[1;36m%s\033[0m\n' "$1"; hr; }

# ------------------------------------------------------------------ 前置检查 --
[ "$(id -u)" = "0" ] || die "请以 root 身份运行本脚本（su - 或 sudo -i）。"

if [ ! -r /etc/alpine-release ]; then
	warn "未检测到 /etc/alpine-release，本脚本按 Alpine(OpenRC) 环境编写，请自行确认系统。"
fi

# ------------------------------------------------------------ 网络下载封装 --
HAVE_CURL=0
if command -v curl >/dev/null 2>&1; then
	HAVE_CURL=1
fi

# http_get <url>   -> stdout
http_get() {
	if [ "$HAVE_CURL" = "1" ]; then
		curl -fsSL --max-time 12 "$1" 2>/dev/null || true
	else
		wget -q -O - --timeout=12 "$1" 2>/dev/null || true
	fi
}

# download <url> <dest>
download() {
	if [ "$HAVE_CURL" = "1" ]; then
		curl -fL --retry 2 --connect-timeout 15 -o "$2" "$1"
	else
		wget -q -O "$2" "$1"
	fi
}

# ---------------------------------------------------------------- 依赖安装 --
ensure_deps() {
	_missing=""
	command -v openssl >/dev/null 2>&1 || _missing="$_missing openssl"
	command -v tar     >/dev/null 2>&1 || _missing="$_missing tar"
	if [ "$HAVE_CURL" = "0" ] && ! command -v wget >/dev/null 2>&1; then
		_missing="$_missing curl"
	fi
	if [ ! -f /etc/ssl/certs/ca-certificates.crt ] && [ ! -f /etc/ssl/certs/ca-bundle.crt ]; then
		_missing="$_missing ca-certificates"
	fi

	if [ -n "$_missing" ]; then
		info "安装缺失依赖:$_missing"
		if command -v apk >/dev/null 2>&1; then
			# shellcheck disable=SC2086
			if ! apk add --no-cache $_missing; then
				warn "依赖安装失败，请手动执行:  apk add --no-cache$_missing"
			fi
		else
			warn "未找到 apk，请手动安装:$_missing"
		fi
	fi
}

# ------------------------------------------------------------ 获取最新版本 --
get_latest_version() {
	_tag=""
	# 途径一：GitHub API
	_json="$(http_get "https://api.github.com/repos/${GITHUB_REPO}/releases/latest")"
	_tag="$(printf '%s\n' "$_json" \
		| sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
		| head -n 1)"

	# 途径二：解析 /releases/latest 的 302 跳转
	if [ -z "$_tag" ]; then
		if [ "$HAVE_CURL" = "1" ]; then
			_loc="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
				"https://github.com/${GITHUB_REPO}/releases/latest" 2>/dev/null || true)"
		else
			_loc="$(wget -q -S --spider \
				"https://github.com/${GITHUB_REPO}/releases/latest" 2>&1 \
				| sed -n 's/.*[Ll]ocation:[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' \
				| tail -n 1 || true)"
		fi
		_tag="$(printf '%s' "$_loc" | sed 's#.*/tag/##')"
		case "$_tag" in
			v[0-9]*) : ;;
			*) _tag="" ;;
		esac
	fi

	if [ -z "$_tag" ]; then
		die "无法获取 sing-box 最新版本号，请检查网络后重试。"
	fi
	printf '%s' "$_tag" | sed 's/^v//'
}

# ---------------------------------------------------------------- 架构识别 --
detect_arch() {
	case "$(uname -m)" in
		x86_64|amd64)         printf 'amd64' ;;
		aarch64|arm64)        printf 'arm64' ;;
		armv7l|armv7|armv7a)  printf 'armv7' ;;
		i386|i486|i586|i686)  printf '386' ;;
		loongarch64|loong64)  printf 'loong64' ;;
		riscv64)              printf 'riscv64' ;;
		mipsle)               printf 'mipsle-softfloat' ;;
		*) die "暂不支持的 CPU 架构: $(uname -m)（GitHub 上没有对应的 musl 构建）" ;;
	esac
}

# ------------------------------------------------------------ 本机地址探测 --
detect_server_ip() {
	_ip=""
	for _u in "https://api.ipify.org" "https://ipv4.icanhazip.com" \
	          "https://ifconfig.me/ip" "https://ip.sb"; do
		_t="$(http_get "$_u" | tr -d ' \t\r\n')"
		case "$_t" in
			""|*[!0-9a-fA-F.:]*) : ;;
			*) _ip="$_t"; break ;;
		esac
	done

	if [ -z "$_ip" ]; then
		_t="$(ip -4 route get 1.1.1.1 2>/dev/null \
			| awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
		if [ -z "$_t" ]; then
			_t="$(ip -4 addr show scope global 2>/dev/null \
				| awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}' || true)"
		fi
		_ip="$_t"
	fi
	printf '%s' "$_ip"
}

# ------------------------------------------------------------ 交互输入封装 --
# 优先从终端读取（兼容 wget | sh 的管道执行方式）；无终端时回退到 stdin
read_line() {
	_l=""
	_ok=0
	if [ -r /dev/tty ] 2>/dev/null; then
		if IFS= read -r _l 2>/dev/null < /dev/tty; then
			_ok=1
		fi
	fi
	if [ "$_ok" = "0" ]; then
		_l=""
		IFS= read -r _l 2>/dev/null || _l=""
	fi
	printf '%s' "$_l"
}

# ask <提示语> <默认值>  -> 回车则返回默认值
ask() {
	_p="$1"
	_d="${2:-}"
	if [ -n "$_d" ]; then
		printf '%s [\033[32m%s\033[0m]: ' "$_p" "$_d" >&2
	else
		printf '%s: ' "$_p" >&2
	fi
	_v="$(read_line)"
	if [ -z "$_v" ]; then
		_v="$_d"
	fi
	printf '%s' "$_v"
}

# 清洗输入，剔除会破坏 JSON / URI 的字符
sanitize() {
	printf '%s' "$1" | tr -d '"\\' | tr -d '\r\n\t'
}

# 分享链接 fragment 轻量编码（保留 UTF-8 原文，只处理分隔符）
frag_encode() {
	printf '%s' "$1" | sed -e 's/ /%20/g' -e 's/#/%23/g' -e 's/&/%26/g' -e 's/?/%3F/g'
}

# ------------------------------------------------------------ 随机端口/口令 --
rand_port() {
	_n="$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' \r\n' || true)"
	case "$_n" in
		''|*[!0-9]*) printf '8443' ;;
		*) printf '%s' "$(( (_n % 45000) + 10000 ))" ;;
	esac
}

rand_password() {
	openssl rand -hex 16 2>/dev/null || od -An -N16 -tx1 /dev/urandom | tr -d ' \r\n'
}

# ============================================================================
#                                   主流程
# ============================================================================
title "sing-box 安装配置向导  ·  Alpine Linux"

# ---------------------------------------------------------------- 1 依赖 ----
info "检查系统依赖 ..."
ensure_deps

# ---------------------------------------------------------------- 2 安装 ----
PROTOCOL="${SB_PROTOCOL:-}"
if [ "${SB_SKIP_INSTALL:-0}" = "1" ]; then
	warn "SB_SKIP_INSTALL=1，跳过 sing-box 二进制下载安装。"
else
	ARCH="$(detect_arch)"
	info "系统架构: $(uname -m)  ->  musl 构建: linux-${ARCH}-musl"
	info "查询 sing-box 最新版本 ..."
	VERSION="$(get_latest_version)"
	ok "最新版本: v${VERSION}"

	PKG="sing-box-${VERSION}-linux-${ARCH}-musl.tar.gz"
	URL="https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/${PKG}"
	info "下载: ${URL}"
	download "$URL" "$TMP_DIR/$PKG" || die "下载失败，请检查网络（可先配置代理后重试）。"

	tar -xzf "$TMP_DIR/$PKG" -C "$TMP_DIR" || die "解压失败，压缩包可能不完整。"
	SRC="$(find "$TMP_DIR" -type f -name sing-box | head -n 1)"
	if [ -z "$SRC" ]; then
		die "压缩包中未找到 sing-box 可执行文件。"
	fi

	mkdir -p "$BIN_DIR"
	cp -f "$SRC" "$BIN"
	chmod 0755 "$BIN"
	ok "已安装: $BIN"
	"$BIN" version 2>/dev/null | head -n 1 | while IFS= read -r _l; do printf '    %s\n' "$_l"; done
fi

mkdir -p "$CONF_DIR" "$LOG_DIR"

# ---------------------------------------------------------------- 3 交互 ----
echo

# 3.1 协议
if [ -z "$PROTOCOL" ]; then
	printf '请选择协议:\n'
	printf '  \033[32m1\033[0m) AnyTLS         —— 基于 TLS 的代理协议，抗 TLS-in-TLS 指纹识别（推荐）\n'
	printf '  \033[32m2\033[0m) Shadowsocks    —— 传统 AEAD 加密，客户端兼容性最好（aes-256-gcm）\n'
	PROTOCOL="$(ask '输入序号' '1')"
fi
case "$PROTOCOL" in
	anytls|AnyTLS|ANYTLS|1) PROTOCOL="anytls" ;;
	ss|SS|Shadowsocks|shadowsocks|2) PROTOCOL="ss" ;;
	*) die "无法识别的协议: $PROTOCOL（可选 anytls / ss）" ;;
esac
ok "协议: $PROTOCOL"

# 3.2 服务器地址
if [ -n "${SB_SERVER:-}" ]; then
	SRV="$SB_SERVER"
else
	info "正在探测本机公网地址 ..."
	_auto="$(detect_server_ip)"
	if [ -n "$_auto" ]; then
		SRV="$(ask '服务器地址（客户端连接地址）' "$_auto")"
	else
		warn "未能自动探测公网地址。"
		SRV=""
		while [ -z "$SRV" ]; do
			SRV="$(ask '服务器地址（客户端连接地址，必填）')"
			if [ -z "$SRV" ]; then
				warn "服务器地址不能为空。"
			fi
		done
	fi
fi
SRV="$(sanitize "$SRV")"
[ -n "$SRV" ] || die "服务器地址不能为空。"

# 3.3 SNI（仅 AnyTLS 使用）
if [ "$PROTOCOL" = "anytls" ]; then
	if [ -n "${SB_SNI:-}" ]; then
		SNI="$(sanitize "$SB_SNI")"
	else
		SNI="$(sanitize "$(ask 'TLS SNI 域名' "$DEFAULT_SNI")")"
	fi
	[ -n "$SNI" ] || SNI="$DEFAULT_SNI"
else
	SNI="$DEFAULT_SNI"
fi

# 3.4 端口
if [ -n "${SB_PORT:-}" ]; then
	PORT="$SB_PORT"
else
	_dft_port="$(rand_port)"
	PORT=""
	while :; do
		PORT="$(ask '监听端口' "$_dft_port")"
		case "$PORT" in
			''|*[!0-9]*) warn "端口必须是 1-65535 之间的数字。"; continue ;;
		esac
		if [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
			break
		fi
		warn "端口必须是 1-65535 之间的数字。"
	done
fi
case "$PORT" in
	''|*[!0-9]*) die "端口非法: $PORT" ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
	die "端口超出范围: $PORT"
fi

# 3.5 节点名称
_dft_name="singbox-$(hostname 2>/dev/null || echo node)"
if [ -n "${SB_NAME:-}" ]; then
	NAME="$(sanitize "$SB_NAME")"
else
	NAME="$(sanitize "$(ask '节点名称' "$_dft_name")")"
fi
[ -n "$NAME" ] || NAME="$_dft_name"

# 3.6 口令
if [ -n "${SB_PASSWORD:-}" ]; then
	PASSWORD="$(sanitize "$SB_PASSWORD")"
else
	PASSWORD="$(rand_password)"
	info "已自动生成随机口令: $PASSWORD"
fi
[ -n "$PASSWORD" ] || die "口令不能为空。"

# ------------------------------------------------------------ 4 自签证书 ----
echo
info "生成自签名 TLS 证书（CN=${SNI}，有效期 10 年）..."
_ts="$(date +%Y%m%d%H%M%S 2>/dev/null || echo bak)"
if [ -f "$CERT" ] || [ -f "$KEY" ]; then
	[ -f "$CERT" ] && cp -f "$CERT" "${CERT}.${_ts}.bak"
	[ -f "$KEY" ]  && cp -f "$KEY"  "${KEY}.${_ts}.bak"
	warn "检测到已存在的证书，已备份为 *.${_ts}.bak，并重新签发。"
fi

# 服务器地址若为 IP 字面量，一并写入 SAN
SAN="DNS:${SNI}"
case "$SRV" in
	*[!0-9.]*) : ;;                 # 域名，仅用 DNS SAN
	*)         SAN="${SAN},IP:${SRV}" ;;   # IPv4
esac
case "$SRV" in
	*:*) SAN="${SAN},IP:${SRV}" ;;  # IPv6
esac

_gen_ok=0
# 方式一：OpenSSL 3，EC P-256 + -addext（最快、体积最小）
if openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
	-keyout "$KEY" -out "$CERT" -days 3650 -nodes -sha256 \
	-subj "/C=US/O=Self-Signed/CN=${SNI}" \
	-addext "subjectAltName=${SAN}" >/dev/null 2>&1; then
	_gen_ok=1
fi

# 方式二：RSA 2048 + -addext
if [ "$_gen_ok" = "0" ]; then
	info "EC 方式失败，改用 RSA 2048 重试 ..."
	if openssl req -x509 -newkey rsa:2048 \
		-keyout "$KEY" -out "$CERT" -days 3650 -nodes -sha256 \
		-subj "/C=US/O=Self-Signed/CN=${SNI}" \
		-addext "subjectAltName=${SAN}" >/dev/null 2>&1; then
		_gen_ok=1
	fi
fi

# 方式三：兼容不支持 -addext 的旧版 openssl / LibreSSL，改用配置文件写 SAN
if [ "$_gen_ok" = "0" ]; then
	info "仍失败，改用 openssl 配置文件方式重试 ..."
	cat > "$TMP_DIR/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = ${SNI}
O = Self-Signed
[ext]
basicConstraints = critical,CA:TRUE
subjectAltName = ${SAN}
EOF
	if openssl req -x509 -newkey rsa:2048 \
		-keyout "$KEY" -out "$CERT" -days 3650 -nodes -sha256 \
		-config "$TMP_DIR/openssl.cnf" >/dev/null 2>&1; then
		_gen_ok=1
	fi
fi

if [ "$_gen_ok" = "0" ]; then
	die "证书生成失败，请确认 openssl 已正确安装（apk add openssl）。"
fi
chmod 0644 "$CERT"
chmod 0600 "$KEY"
ok "证书已生成: $CERT / $KEY"

# ------------------------------------------------------------ 5 生成配置 ----
info "写入配置: $CONFIG"
if [ -f "$CONFIG" ]; then
	cp -f "$CONFIG" "${CONFIG}.${_ts}.bak"
	warn "已存在旧配置，备份为 ${CONFIG}.${_ts}.bak"
fi

# IPv6 可用时监听 :: （v4+v6 双栈），否则回退 0.0.0.0
LISTEN="::"
if [ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]; then
	if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" != "0" ]; then
		LISTEN="0.0.0.0"
	fi
fi

if [ "$PROTOCOL" = "anytls" ]; then
	cat > "$CONFIG" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true,
    "output": "${LOG_DIR}/sing-box.log"
  },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "${LISTEN}",
      "listen_port": ${PORT},
      "users": [
        {
          "name": "${NAME}",
          "password": "${PASSWORD}"
        }
      ],
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
        "server_name": "${SNI}",
        "certificate_path": "${CERT}",
        "key_path": "${KEY}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
else
	cat > "$CONFIG" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true,
    "output": "${LOG_DIR}/sing-box.log"
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "${LISTEN}",
      "listen_port": ${PORT},
      "method": "aes-256-gcm",
      "password": "${PASSWORD}"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
fi
chmod 0600 "$CONFIG"
ok "配置已写入（权限 600）"

if [ -x "$BIN" ]; then
	if "$BIN" check -c "$CONFIG" >/dev/null 2>&1; then
		ok "sing-box 配置语法校验通过"
	else
		"$BIN" check -c "$CONFIG" || true
		die "配置校验未通过，请检查上方报错信息。"
	fi
else
	warn "未找到 $BIN，跳过配置校验。"
fi

# ------------------------------------------------------------ 6 服务部署 ----
if [ "${SB_SKIP_SERVICE:-0}" = "1" ]; then
	warn "SB_SKIP_SERVICE=1，跳过服务注册与启动。"
else
	info "注册 OpenRC 服务 ..."
	mkdir -p "$INIT_DIR"
	cat > "$INIT_FILE" <<EOF
#!/sbin/openrc-run

name="${SVC}"
description="sing-box service"

command="${BIN}"
command_args="run -c ${CONFIG}"
command_background="yes"

pidfile="/run/${SVC}.pid"
output_log="${LOG_DIR}/stdout.log"
error_log="${LOG_DIR}/error.log"

depend() {
	need net
	after firewall
}
EOF
	chmod 0755 "$INIT_FILE"

	if command -v rc-update >/dev/null 2>&1; then
		rc-update add "$SVC" default >/dev/null 2>&1 || true
		ok "已设置开机自启（rc-update add ${SVC} default）"
	fi

	if command -v rc-service >/dev/null 2>&1; then
		rc-service "$SVC" restart >/dev/null 2>&1 \
			|| rc-service "$SVC" start >/dev/null 2>&1 || true
		sleep 1
		if rc-service "$SVC" status >/dev/null 2>&1; then
			ok "服务已启动，运行状态正常"
		else
			warn "服务似乎未能正常运行，最近日志如下："
			hr
			tail -n 20 "${LOG_DIR}/sing-box.log" 2>/dev/null || true
			tail -n 20 "${LOG_DIR}/error.log" 2>/dev/null || true
			hr
		fi
	fi
fi

# ------------------------------------------------------------ 7 分享链接 ----
case "$SRV" in
	*:*) _host="[${SRV}]" ;;   # IPv6 需加方括号
	*)   _host="$SRV" ;;
esac
_authority="${_host}:${PORT}"   # 端口始终显式写出，兼容性最好
_frag="$(frag_encode "$NAME")"

if [ "$PROTOCOL" = "anytls" ]; then
	LINK="anytls://${PASSWORD}@${_authority}/?sni=${SNI}&insecure=1#${_frag}"
else
	_b64="$(printf '%s' "aes-256-gcm:${PASSWORD}" | base64 | tr -d '\r\n=' | tr '+/' '-_')"
	LINK="ss://${_b64}@${_authority}#${_frag}"
fi

# ------------------------------------------------------------ 8 结果展示 ----
title "部署完成"
printf '  协议      : %s\n' "$PROTOCOL"
printf '  服务器    : %s\n' "$SRV"
printf '  端口      : %s\n' "$PORT"
if [ "$PROTOCOL" = "anytls" ]; then
	printf '  SNI       : %s\n' "$SNI"
fi
printf '  节点名称  : %s\n' "$NAME"
printf '  口令      : %s\n' "$PASSWORD"

title "分享链接（可直接导入客户端）"
printf '\033[1;32m%s\033[0m\n' "$LINK"

title "自签名证书全文  cert.pem"
cat "$CERT"

title "证书私钥全文  key.pem  （请妥善保管，切勿公开）"
cat "$KEY"

title "服务与文件"
printf '  安装路径  : %s\n' "$BIN"
printf '  配置文件  : %s\n' "$CONFIG"
printf '  日志文件  : %s/sing-box.log\n' "$LOG_DIR"
printf '  启动      : rc-service %s start\n' "$SVC"
printf '  停止      : rc-service %s stop\n' "$SVC"
printf '  重启      : rc-service %s restart\n' "$SVC"
printf '  开机自启  : rc-update add %s default\n' "$SVC"
printf '  查看状态  : rc-service %s status\n' "$SVC"
printf '  实时日志  : tail -f %s/sing-box.log\n' "$LOG_DIR"

title "注意事项"
if [ "$PROTOCOL" = "anytls" ]; then
	printf '  · 证书为自签名，分享链接中已带 insecure=1；若客户端不识别该参数，\n'
	printf '    请手动勾选“允许不安全 / 跳过证书校验（allowInsecure）”。\n'
	printf '  · 也可把上面的 cert.pem 导入客户端信任，之后即可将 insecure 改为 0。\n'
	printf '  · AnyTLS 仅走 TCP；支持的客户端：sing-box(SFA/SFI/CLI)、NekoBox、\n'
	printf '    NekoRay、Hiddify、Mihomo Party、Shadowrocket 2.2.65+ 等。\n'
else
	printf '  · Shadowsocks 使用 aes-256-gcm，本身不需要 TLS 证书；\n'
	printf '    本次生成的 cert.pem / key.pem 已保存在 %s，\n' "$CONF_DIR"
	printf '    日后若切换为 AnyTLS 可直接复用。\n'
fi
printf '  · 请在云厂商安全组 / 本机防火墙放行 TCP %s 端口。\n' "$PORT"
printf '  · 若服务未启动，先看日志：tail -n 50 %s/sing-box.log\n' "$LOG_DIR"
hr
