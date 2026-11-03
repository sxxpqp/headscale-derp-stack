#!/usr/bin/env bash
# 仅使用虚构凭据在 .generated 下验证，不部署或连接集群。
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
for cmd in bash kubectl docker openssl; do command -v "$cmd" >/dev/null; done
if command -v shellcheck >/dev/null; then shellcheck server/docker/configure.sh server/k8s/configure.sh client/docker/configure.sh client/k8s/configure.sh lib/configure-common.sh tests/test-configure.sh; fi
for entry in server/docker/configure.sh server/k8s/configure.sh client/docker/configure.sh client/k8s/configure.sh lib/configure-common.sh; do bash -n "$entry"; done
umask 077
RUN="smoke-$$"
TEST_ROOT="$PWD/.generated/$RUN"
mkdir -p "$TEST_ROOT"
KEY=hskey-auth-smoke-only
COOKIE=0123456789abcdef0123456789abcdef
declare -A MODES=() ROLES=()

settings() {
  local label="$1" role="$2" mode="$3" tls_cert="" tls_key=""
  if [[ "$mode" == docker ]]; then tls_cert="/etc/certs/full chain.pem"; tls_key="/etc/certs/privkey.pem"; fi
  MODES["$label"]="$mode"
  ROLES["$label"]="$role"
  cat > "$TEST_ROOT/$label.env" <<EOF
INSTANCE=$RUN-$label
PUBLIC_URL=https://vpn.test.example:8443
PUBLIC_IPV4=8.8.8.8
MAGIC_DOMAIN=ts.corp.internal
COOKIE_SECRET=$COOKIE
NODE=node-a
STORAGE_CLASS=fast-storage
INGRESS_CLASS=nginx
TLS_SECRET=existing-tls
TLS_IMPORT=n
TLS_CERT=$tls_cert
TLS_KEY=$tls_key
CLIENT_NAME=router-a
AUTH_KEY=$KEY
ROUTES=172.16.0.0/24
ACCEPT_ROUTES=y
EXIT_NODE=n
EOF
}
run() {
  local label="$1"
  printf 'Checking %s\n' "$label"
  bash "${ROLES[$label]}/${MODES[$label]}/configure.sh" "$TEST_ROOT/$label.env" > "$TEST_ROOT/$label.log"
  if grep -q -e "$KEY" -e "$COOKIE" "$TEST_ROOT/$label.log"; then
    printf 'Secret leaked into output\n' >&2; exit 1
  fi
}
reject() {
  local label="$1"
  if bash "${ROLES[$label]}/${MODES[$label]}/configure.sh" "$TEST_ROOT/$label.env" > "$TEST_ROOT/$label.log" 2>&1; then
    printf 'Invalid settings were accepted: %s\n' "$label" >&2; exit 1
  fi
}
settings sd server docker
run sd
SD="$PWD/.generated/server-docker/$RUN-sd"
docker compose -f "$SD/compose.yaml" config --quiet
grep -q 'listen 8443 ssl;' "$SD/nginx/headscale.conf"
# shellcheck disable=SC2016
grep -Fq 'https://$host:8443$request_uri' "$SD/nginx/headscale.conf"
grep -Fq 'ssl_certificate "/etc/certs/full chain.pem";' "$SD/nginx/headscale.conf"

settings sk server k8s
# 旧开关即使为 y，本地路径为空也必须正常引用已有 Secret。
sed -i 's/^TLS_IMPORT=.*/TLS_IMPORT=y/' "$TEST_ROOT/sk.env"
run sk
SK="$PWD/.generated/server-k8s/$RUN-sk"
rendered="$(kubectl kustomize "$SK")"
grep -q 'secretName: headplane-config-' <<< "$rendered"
grep -q 'secretName: existing-tls' <<< "$rendered"
grep -q 'storageClassName: fast-storage' <<< "$rendered"
if grep -q 'host: vpn.test.example:8443' <<< "$rendered"; then exit 1; fi

settings cd client docker
run cd
CD="$PWD/.generated/client-docker/$RUN-cd"
docker compose -f "$CD/compose.yaml" config --quiet

settings ck client k8s
sed -i 's/^ROUTES=.*/ROUTES=/' "$TEST_ROOT/ck.env"
run ck
CK="$PWD/.generated/client-k8s/$RUN-ck"
rendered="$(kubectl kustomize "$CK")"
grep -q 'name: tailscale-auth-' <<< "$rendered"
if grep -q -- '--advertise-exit-node' "$CK/deployment.yaml"; then exit 1; fi

# 同名目录拒绝覆盖。
before="$(cksum "$SD/config/headplane.yaml")"
reject sd
[[ "$before" == "$(cksum "$SD/config/headplane.yaml")" ]]

settings invalid client docker
sed -i 's|^ROUTES=.*|ROUTES=172.16.0.5/24|' "$TEST_ROOT/invalid.env"
reject invalid
[[ ! -e ".generated/client-docker/$RUN-invalid" ]]

settings duplicate client docker
printf 'PUBLIC_URL=https://vpn.test.example\n' >> "$TEST_ROOT/duplicate.env"
reject duplicate
settings unknown client docker
printf 'HOME=/tmp/should-not-be-used\n' >> "$TEST_ROOT/unknown.env"
reject unknown

# 不执行变量文件中的命令替换。
settings injection client docker
# 此处有意把命令替换作为普通文本传入变量文件。
# shellcheck disable=SC2016
printf '%s\n' 'UNSUPPORTED=$(touch SHOULD_NOT_EXIST)' >> "$TEST_ROOT/injection.env"
reject injection
[[ ! -e SHOULD_NOT_EXIST ]]

# 专用入口拒绝变量文件覆盖 MODE。
settings modeoverride client docker
printf "MODE=k8s\n" >> "$TEST_ROOT/modeoverride.env"
reject modeoverride

# 可以完全不写本地证书字段和旧开关。
settings existing server k8s
sed -i '/^TLS_CERT=/d; /^TLS_KEY=/d; /^TLS_IMPORT=/d' "$TEST_ROOT/existing.env"
run existing
existing_render="$(kubectl kustomize ".generated/server-k8s/$RUN-existing")"
grep -q 'secretName: existing-tls' <<< "$existing_render"

# 单独提供一项路径应在生成前拒绝。
settings partial server k8s
sed -i 's|^TLS_CERT=.*|TLS_CERT=/missing/fullchain.pem|' "$TEST_ROOT/partial.env"
reject partial
[[ ! -e ".generated/server-k8s/$RUN-partial" ]]

# 本地 TLS Secret 生成，无集群操作；无需 TLS_IMPORT 开关。
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=vpn.test.example \
  -keyout "$TEST_ROOT/tls.key" -out "$TEST_ROOT/tls.crt" >/dev/null 2>&1
settings tls server k8s
sed -i '/^TLS_IMPORT=/d' "$TEST_ROOT/tls.env"
sed -i "s|^TLS_CERT=.*|TLS_CERT=$TEST_ROOT/tls.crt|" "$TEST_ROOT/tls.env"
sed -i "s|^TLS_KEY=.*|TLS_KEY=$TEST_ROOT/tls.key|" "$TEST_ROOT/tls.env"
run tls
rendered="$(kubectl kustomize ".generated/server-k8s/$RUN-tls")"
grep -q 'type: kubernetes.io/tls' <<< "$rendered"
# 在隔离的模板副本中验证：改过示例值仍可生成；失败不占用最终目录。
FIXTURE="$TEST_ROOT/fixture"
mkdir -p "$FIXTURE/lib" "$FIXTURE/server/k8s/config"
cp lib/configure-common.sh "$FIXTURE/lib/"
for file in configure.sh namespace.yaml storage.yaml services.yaml workloads.yaml ingress.yaml kustomization.yaml; do
  cp "server/k8s/$file" "$FIXTURE/server/k8s/$file"
done
for file in headscale.example.yaml headplane.example.yaml policy.hujson; do
  cp "server/k8s/config/$file" "$FIXTURE/server/k8s/config/$file"
done
sed -i 's/vpn\.example\.com/already.edited.example/g; s/REPLACE_WITH_32_CHAR_RANDOM_VALUE/fedcba9876543210fedcba9876543210/g' "$FIXTURE/server/k8s/config/headplane.example.yaml"
settings edited server k8s
# 回归：首次生成，最终父目录完全不存在。
[[ ! -e "$FIXTURE/.generated/server-k8s" ]]
bash "$FIXTURE/server/k8s/configure.sh" "$TEST_ROOT/edited.env" > "$TEST_ROOT/edited.log"
[[ -d "$FIXTURE/.generated/server-k8s/$RUN-edited" ]]
kubectl kustomize "$FIXTURE/.generated/server-k8s/$RUN-edited" >/dev/null

# 删除目标字段模拟模板损坏，再恢复并用同一 INSTANCE 重试。
settings atomic server k8s
cp "$FIXTURE/server/k8s/config/headplane.example.yaml" "$TEST_ROOT/headplane.saved.yaml"
sed -i '/^[[:space:]]*cookie_secret:/d' "$FIXTURE/server/k8s/config/headplane.example.yaml"
if bash "$FIXTURE/server/k8s/configure.sh" "$TEST_ROOT/atomic.env" > "$TEST_ROOT/atomic.log" 2>&1; then exit 1; fi
[[ ! -e "$FIXTURE/.generated/server-k8s/$RUN-atomic" ]]
if find "$FIXTURE/.generated" -maxdepth 1 -name '.tmp-config-*' | grep -q .; then exit 1; fi
cp "$TEST_ROOT/headplane.saved.yaml" "$FIXTURE/server/k8s/config/headplane.example.yaml"
bash "$FIXTURE/server/k8s/configure.sh" "$TEST_ROOT/atomic.env" > "$TEST_ROOT/atomic-retry.log"
kubectl kustomize "$FIXTURE/.generated/server-k8s/$RUN-atomic" >/dev/null
printf 'Configuration generation, edited values, failure cleanup and retry checks passed.\n'
printf 'Dummy test artifacts: %s\n' "$TEST_ROOT"


