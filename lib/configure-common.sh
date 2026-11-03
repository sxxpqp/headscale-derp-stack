#!/usr/bin/env bash
# Linux 配置生成器，只写入 .generated，不部署或修改宿主机。
set -euo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
name_ok() { [[ ${#1} -le 63 && "$1" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; }
domain_ok() {
  local label
  local -a labels
  [[ "$1" == *.* && ${#1} -le 253 && "$1" != *.local && "$1" != *. ]] || return 1
  IFS=. read -r -a labels <<< "$1"
  for label in "${labels[@]}"; do
    [[ ${#label} -le 63 && "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}
url_ok() {
  local host_part port_part
  [[ "$1" == https://* && "$1" != *[[:space:]]* ]] || return 1
  host_part="${1#https://}"; host_part="${host_part%/}"
  if [[ "$host_part" == *:* ]]; then
    port_part="${host_part##*:}"; host_part="${host_part%:*}"
    [[ "$port_part" =~ ^[0-9]{1,5}$ ]] || return 1
    ((10#$port_part >= 1 && 10#$port_part <= 65535)) || return 1
  fi
  domain_ok "$host_part"
}
ipv4_ok() {
  local octet
  local -a octets
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a octets <<< "$1"
  for octet in "${octets[@]}"; do
    [[ ${#octet} -le 3 ]] && ((10#$octet <= 255)) || return 1
    [[ "$octet" == 0 || "$octet" != 0* ]] || return 1
  done
}
routes_ok() {
  local route address prefix a b c d value mask bits
  local -a routes
  [[ -z "$1" ]] && return 0
  [[ "$1" != *, && "$1" != ,* && "$1" != *,,* ]] || return 1
  IFS=, read -r -a routes <<< "$1"
  for route in "${routes[@]}"; do
    [[ "$route" == */* ]] || return 1
    address="${route%/*}"; prefix="${route##*/}"
    ipv4_ok "$address" || return 1
    [[ "$prefix" =~ ^[0-9]{1,2}$ ]] && ((10#$prefix <= 32)) || return 1
    IFS=. read -r a b c d <<< "$address"
    value=$(((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d))
    bits=$((10#$prefix))
    mask=$(((0xffffffff << (32 - bits)) & 0xffffffff))
    (( (value & mask) == value )) || return 1
  done
}
yn_ok() { [[ "$1" == y || "$1" == n ]]; }
mode_ok() { [[ "$1" == docker || "$1" == k8s ]]; }
role_ok() { [[ "$1" == server || "$1" == client ]]; }
optional_name() { [[ -z "$1" ]] || name_ok "$1"; }
path_ok() { [[ "$1" == /* && "$1" != *[[:cntrl:]]* && "$1" != *\"* && "$1" != *\\* && "$1" != *\$* && "$1" != *\;* ]]; }
# 变量文件是纯 KEY=value 数据；不使用 source/eval，也不展开命令或变量。
load_settings() {
  local settings_file="$1" line key value line_no=0
  local -A seen=()
  [[ -r "$settings_file" ]] || die "无法读取变量文件：$settings_file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_no+=1))
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *=* ]] || die "变量文件第 $line_no 行不是 KEY=value"
    key="${line%%=*}"; value="${line#*=}"
    case "$key" in
      INSTANCE|PUBLIC_URL|PUBLIC_IPV4|MAGIC_DOMAIN|COOKIE_SECRET|NODE|STORAGE_CLASS|INGRESS_CLASS|TLS_SECRET|TLS_IMPORT|TLS_CERT|TLS_KEY|CLIENT_NAME|AUTH_KEY|ROUTES|ACCEPT_ROUTES|EXIT_NODE) ;;
      *) die "变量文件第 $line_no 行存在不支持的变量名" ;;
    esac
    [[ -z "${seen[$key]:-}" ]] || die "变量重复：$key"
    seen["$key"]=1
    printf -v "$key" '%s' "$value"
  done < "$settings_file"
}
check() { "$2" "${!1}" || die "变量 $1 缺失或格式不正确"; }
secret_ok() { [[ -n "$1" && "$1" != REPLACE_* && "$1" =~ ^[a-zA-Z0-9._-]+$ ]]; }
copy_file() {
  local relative="$1" target="${2:-$1}"
  mkdir -p -- "$OUT/$(dirname -- "$target")"
  cp -- "$ROOT/$ROLE/$MODE/$relative" "$OUT/$target"
  chmod 600 -- "$OUT/$target"
}
replace() {
  local file="$1" old="$2" new="$3"
  grep -q -- "$old" "$file" || die "源模板已被修改，找不到待替换字段：$file；请在干净模板上生成"
  new="${new//\\/\\\\}"; new="${new//&/\\&}"; new="${new//|/\\|}"
  sed -i "s|$old|$new|g" "$file"
}
storage_patch() {
  [[ -n "$STORAGE_CLASS" ]] || return 0
  local pvc
  printf '\npatches:\n' >> "$OUT/kustomization.yaml"
  for pvc in "$@"; do
    cat >> "$OUT/kustomization.yaml" <<EOF
  - target:
      kind: PersistentVolumeClaim
      name: $pvc
    patch: |-
      - op: add
        path: /spec/storageClassName
        value: $STORAGE_CLASS
EOF
  done
}

ROLE="${1:?内部入口需要指定部署侧}"
MODE="${2:?内部入口需要指定部署方式}"
CONFIG_DIR="${3:?内部入口需要指定配置目录}"
shift 3
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  printf '用法：在 %s/%s 目录运行 bash configure.sh [变量文件，默认本目录 setup.env]\n' "$ROLE" "$MODE"
  exit 0
fi
[[ $# -le 1 ]] || die '只接受一个变量文件参数'
(( BASH_VERSINFO[0] >= 4 )) || die '需要 Bash 4 或更新版本'
INSTANCE=default
PUBLIC_URL=https://hb.sxxpqp.top
PUBLIC_IPV4=''; MAGIC_DOMAIN=ts.corp.internal; COOKIE_SECRET=''
NODE=''; STORAGE_CLASS=''; INGRESS_CLASS=''
TLS_SECRET=headscale-tls; TLS_IMPORT=n; TLS_CERT=''; TLS_KEY=''
CLIENT_NAME=site-a-router; AUTH_KEY=''; ROUTES=''; ACCEPT_ROUTES=y; EXIT_NODE=n

load_settings "${1:-$CONFIG_DIR/setup.env}"
check ROLE role_ok
check MODE mode_ok
check INSTANCE name_ok
check PUBLIC_URL url_ok
OUT="$ROOT/.generated/$ROLE-$MODE/$INSTANCE"
[[ ! -e "$OUT" ]] || die "目录已存在，请使用新 INSTANCE，原配置未覆盖：$OUT"
PUBLIC_URL="${PUBLIC_URL%/}"
HOST="${PUBLIC_URL#https://}"; PORT=443
if [[ "$HOST" == *:* ]]; then PORT="${HOST##*:}"; HOST="${HOST%:*}"; fi

if [[ "$ROLE" == server ]]; then
  check PUBLIC_IPV4 ipv4_ok
  check MAGIC_DOMAIN domain_ok
  [[ "$HOST" != "$MAGIC_DOMAIN" && "$HOST" != *."$MAGIC_DOMAIN" ]] ||
    die 'MAGIC_DOMAIN 不能等于控制域名或是其父域'
  COOKIE="$COOKIE_SECRET"
  if [[ -z "$COOKIE" ]]; then
    command -v openssl >/dev/null || die 'COOKIE_SECRET 留空时需要 openssl 自动生成'
    COOKIE="$(openssl rand -hex 16)"
  fi
  secret_ok "$COOKIE" && [[ ${#COOKIE} -eq 32 ]] || die 'COOKIE_SECRET 必须为32字符字母、数字、点、下划线或连字符'
  unset COOKIE_SECRET
fi
if [[ "$MODE" == k8s ]]; then
  check NODE name_ok
  check STORAGE_CLASS optional_name
fi
if [[ "$ROLE" == server && "$MODE" == k8s ]]; then
  check INGRESS_CLASS name_ok
  check TLS_SECRET name_ok
  # 保留对旧 TLS_IMPORT 变量的读取兼容，但不再由它决定是否导入。
  # 未提供本地证书时仅引用现有 Secret，不校验本地证书路径。
  if [[ -z "$TLS_CERT" && -z "$TLS_KEY" ]]; then
    TLS_IMPORT=n
  elif [[ -z "$TLS_CERT" || -z "$TLS_KEY" ]]; then
    die 'TLS_CERT 和 TLS_KEY 需同时填写；使用已有 Secret 时两项都可以不写'
  else
    TLS_IMPORT=y
    command -v kubectl >/dev/null || die '本地证书生成 Secret 需要 kubectl 进行本地 dry-run'
    check TLS_CERT path_ok
    check TLS_KEY path_ok
    [[ -r "$TLS_CERT" && -r "$TLS_KEY" ]] || die 'TLS_CERT 或 TLS_KEY 文件不可读'
  fi
elif [[ "$ROLE" == server ]]; then
  TLS_CERT="${TLS_CERT:-/etc/letsencrypt/live/$HOST/fullchain.pem}"
  TLS_KEY="${TLS_KEY:-/etc/letsencrypt/live/$HOST/privkey.pem}"
  check TLS_CERT path_ok
  check TLS_KEY path_ok
fi
if [[ "$ROLE" == client ]]; then
  check CLIENT_NAME name_ok
  check AUTH_KEY secret_ok
  check ROUTES routes_ok
  check ACCEPT_ROUTES yn_ok
  check EXIT_NODE yn_ok
  EXTRA_ARGS="--login-server=$PUBLIC_URL --accept-routes="
  if [[ "$ACCEPT_ROUTES" == y ]]; then EXTRA_ARGS+=true; else EXTRA_ARGS+=false; fi
  if [[ "$EXIT_NODE" == y ]]; then EXTRA_ARGS+=' --advertise-exit-node'; fi
fi
printf '变量校验通过，生成配置：%s/%s\n' "$ROLE" "$MODE"
mkdir -p -- "$OUT"
if [[ "$ROLE" == server ]]; then
  copy_file config/headscale.example.yaml config/headscale.yaml
  copy_file config/headplane.example.yaml config/headplane.yaml
  copy_file config/policy.hujson
  replace "$OUT/config/headscale.yaml" 'https://vpn\.example\.com' "$PUBLIC_URL"
  replace "$OUT/config/headscale.yaml" '203\.0\.113\.10' "$PUBLIC_IPV4"
  replace "$OUT/config/headscale.yaml" 'ts\.corp\.internal' "$MAGIC_DOMAIN"
  replace "$OUT/config/headplane.yaml" 'https://vpn\.example\.com' "$PUBLIC_URL"
  replace "$OUT/config/headplane.yaml" REPLACE_WITH_32_CHAR_RANDOM_VALUE "$COOKIE"
  unset COOKIE
  if [[ "$MODE" == k8s ]]; then
    for file in namespace.yaml storage.yaml services.yaml workloads.yaml ingress.yaml kustomization.yaml; do copy_file "$file"; done
    replace "$OUT/workloads.yaml" REPLACE_WITH_IDC_NODE "$NODE"
    replace "$OUT/ingress.yaml" REPLACE_WITH_INGRESS_CLASS "$INGRESS_CLASS"
    replace "$OUT/ingress.yaml" 'vpn\.example\.com' "$HOST"
    replace "$OUT/ingress.yaml" 'secretName: headscale-tls' "secretName: $TLS_SECRET"
    storage_patch headscale-data headplane-data
    if [[ "$TLS_IMPORT" == y ]]; then
      kubectl create secret tls "$TLS_SECRET" --cert="$TLS_CERT" --key="$TLS_KEY" \
        --dry-run=client -o yaml > "$OUT/config/tls-secret.yaml"
      sed -i '/^resources:/a\  - config/tls-secret.yaml' "$OUT/kustomization.yaml"
    fi
  else
    copy_file compose.yaml
    copy_file .env.example .env
    copy_file nginx/headscale.conf.example nginx/headscale.conf
    replace "$OUT/nginx/headscale.conf" 'vpn\.example\.com' "$HOST"
    replace "$OUT/nginx/headscale.conf" 'listen 443 ssl;' "listen $PORT ssl;"
    replace "$OUT/nginx/headscale.conf" 'ssl_certificate .*;' "ssl_certificate \"$TLS_CERT\";"
    replace "$OUT/nginx/headscale.conf" 'ssl_certificate_key .*;' "ssl_certificate_key \"$TLS_KEY\";"
    if [[ "$PORT" != 443 ]]; then
      # Nginx 变量必须保持字面值，不能由 shell 展开。
      # shellcheck disable=SC2016
      replace "$OUT/nginx/headscale.conf" 'https://\$host\$request_uri' "https://\$host:$PORT\$request_uri"
    fi
  fi
else
  if [[ "$MODE" == k8s ]]; then
    for file in namespace.yaml storage.yaml deployment.yaml kustomization.yaml; do copy_file "$file"; done
    replace "$OUT/deployment.yaml" REPLACE_WITH_ROUTER_NODE "$NODE"
    replace "$OUT/deployment.yaml" 'value: k8s-router' "value: $CLIENT_NAME"
    replace "$OUT/deployment.yaml" 'value: 172\.16\.0\.0/24' "value: \"$ROUTES\""
    replace "$OUT/deployment.yaml" 'value: --login-server=.*' "value: $EXTRA_ARGS"
    mkdir -p -- "$OUT/config"
    printf '%s' "$AUTH_KEY" > "$OUT/config/authkey"
    cat >> "$OUT/kustomization.yaml" <<'EOF'

secretGenerator:
  - name: tailscale-auth
    files:
      - authkey=config/authkey
EOF
    storage_patch tailscale-state
  else
    copy_file compose.yaml
    grep '^TAILSCALE_VERSION=' "$ROOT/client/docker/.env.example" > "$OUT/.env"
    printf 'TS_HOSTNAME=%s\nTS_AUTHKEY=%s\nTS_ROUTES=%s\nTS_EXTRA_ARGS=%s\n' \
      "$CLIENT_NAME" "$AUTH_KEY" "$ROUTES" "$EXTRA_ARGS" >> "$OUT/.env"
  fi
  unset AUTH_KEY
fi

printf '已生成：%s\n' "$OUT"
printf '模板和现有部署均未修改。生成目录含密钥，不提交或发送完整内容。\n'
printf '检查后执行（以下仅打印，不自动运行）：\n'
printf '  cd %q\n' "$OUT"
if [[ "$MODE" == k8s ]]; then
  printf '  kubectl kustomize . >/dev/null\n'
  printf '  kubectl apply -f namespace.yaml\n'
  printf '  kubectl apply --dry-run=server -k .\n'
  printf '  kubectl apply -k .\n'
  if [[ "$ROLE" == server && "$TLS_IMPORT" == n ]]; then
    printf '请先确保 headscale namespace 中已有 TLS Secret：%s\n' "$TLS_SECRET"
  fi
  if [[ "$ROLE" == server && "$PORT" != 443 ]]; then
    printf '公网端口 %s 需在已有 Ingress Controller/NAT 配置。\n' "$PORT"
  fi
else
  printf '  docker compose config --quiet\n'
  if [[ "$ROLE" == server ]]; then printf '  docker compose run --rm headscale configtest\n'; fi
  printf '  docker compose up -d\n'
  if [[ "$ROLE" == server ]]; then printf '手动合并 nginx/headscale.conf，按既有流程准备证书。\n'; fi
fi
if [[ "$ROLE" == client ]]; then
  printf '启动前按 client/README.md 开启宿主机转发，注册后在 Headscale 批准路由。\n'
fi


