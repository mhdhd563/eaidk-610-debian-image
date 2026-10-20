#!/bin/bash
# 把本仓库推送到 GitHub，并把镜像上传为 Release 资产
#
# 安全设计：
#   - token 只从 $GH_TOKEN 或文件（默认 /workspace/.gh_token）读取
#   - 命令行里不出现 token，不写进 .git/config（用 git -c http.extraheader 临时注入）
#   - 脚本不会 echo token
#
# 用法：
#   OWNER=你的用户名 GH_TOKEN_FILE=/workspace/.gh_token ./tools/publish-to-github.sh
#
# 可选环境变量：
#   REPO=eaidk-610-debian-image   仓库名
#   VISIBILITY=public|private     可见性
#   TAG=v3  TITLE="..."           Release 标签与标题
#   IMAGE=/path/to/xxx.img.gz     要上传的镜像（默认 v3）
set -euo pipefail

OWNER="${OWNER:?必须指定 OWNER=你的GitHub用户名}"
REPO="${REPO:-eaidk-610-debian-image}"
VISIBILITY="${VISIBILITY:-public}"
TAG="${TAG:-v3}"
TITLE="${TITLE:-v3 · Debian 12 + XFCE + 中文输入法 + NetworkManager + RT5651 音频修复}"
IMAGE="${IMAGE:-/workspace/rk3399-eaidk-610-debian12-xfce-v3-6.1.0-53-arm64.img.gz}"
GH_TOKEN_FILE="${GH_TOKEN_FILE:-/workspace/.gh_token}"

TOKEN="${GH_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f "$GH_TOKEN_FILE" ]; then
  TOKEN="$(tr -d ' \t\r\n' < "$GH_TOKEN_FILE")"
fi
[ -n "$TOKEN" ] || { echo "!! 没有拿到 token（设 GH_TOKEN 或把 token 写进 $GH_TOKEN_FILE）"; exit 1; }

api() { curl -sS -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" "$@"; }
REPO_DESC="RK3399 EAIDK-610 Debian 12 bootable image (mainline kernel, XFCE, Chinese IME, NetworkManager). Docs, reproducible build scripts and the upstream DTS fix."

echo "==> 1/4 检查/创建仓库 $OWNER/$REPO"
if api "https://api.github.com/repos/$OWNER/$REPO" | grep -q '"full_name"'; then
  echo "    仓库已存在，直接用"
else
  if [ "$VISIBILITY" = "private" ]; then PRIV=true; else PRIV=false; fi
  api -X POST https://api.github.com/user/repos \
      -d "{\"name\":\"$REPO\",\"private\":$PRIV,\"description\":$(python3 -c "import json,sys;print(json.dumps('$REPO_DESC'))")}" \
    | grep -E '"full_name"|"message"' || true
fi

cd "$(cd "$(dirname "$0")/.." && pwd)"

echo "==> 2/4 配置 remote 并推送 main"
git remote remove origin 2>/dev/null || true
git remote add origin "https://github.com/$OWNER/$REPO.git"
# 注意：git 的传输层**不认** Bearer，必须用 Basic（用户名随意，密码位置放 token），
# 否则会退化成"提示输入用户名"而在无 TTY 环境直接失败。
B64=$(printf 'x-access-token:%s' "$TOKEN" | base64 -w0)
git -c http.extraheader="Authorization: Basic $B64" push -u origin main
git remote set-url origin "https://github.com/$OWNER/$REPO.git"   # 确保 remote 里没有凭据

echo "==> 3/4 创建 Release $TAG"
REL_JSON=$(api -X POST "https://api.github.com/repos/$OWNER/$REPO/releases" \
  -d "{\"tag_name\":\"$TAG\",\"name\":\"$TITLE\",\"body\":\"可直接烧录的镜像资产见下方。\\n\\n- 解压后 5136 MiB，写入 32G microSD 后首启自动扩容\\n- 账号：debian/debian（sudo）、root/root（串口/本地终端）\\n- 串口：ttyS2 @1500000 8N1\\n- SHA256 见 .sha256 文件\\n\\n构建文档与复现脚本见仓库 README。\"}" )
echo "$REL_JSON" | grep -E '"tag_name"|"message"' || true
REL_ID=$(echo "$REL_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("id",""))')
[ -n "$REL_ID" ] || { echo "!! 创建 Release 失败（标签可能已存在），请检查上面输出"; exit 1; }

echo "==> 4/4 上传资产（镜像约 1 GB，可能要几分钟到几十分钟）"
[ -f "$IMAGE" ] || { echo "!! 找不到镜像：$IMAGE"; exit 1; }
# 注意：**必须**用 -T（从磁盘流式上传）而不是 --data-binary @file。
# 后者会把整个文件读进内存，1 GB 的镜像在内存紧张的机器上会直接
# "curl: option --data-binary: out of memory" 失败。
curl -sS --no-progress-meter -X POST -T "$IMAGE" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/gzip" \
  "https://uploads.github.com/repos/$OWNER/$REPO/releases/$REL_ID/assets?name=$(basename "$IMAGE")" \
  -o /tmp/gh-asset.json -w '  HTTP %{http_code} | 上传 %{size_upload} 字节 | %{time_total}s\n'
python3 -c "import json;d=json.load(open('/tmp/gh-asset.json'));print('  ✓',d.get('name'),f\"{d.get('size',0):,}\",'bytes',d.get('state'))" 2>/dev/null || head -c 300 /tmp/gh-asset.json

for f in "$IMAGE" "$IMAGE.sha256"; do
  case "$f" in *.sha256) [ -f "$f" ] || continue; CT="text/plain";; *) continue;; esac
  curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: $CT" \
    --data-binary "@$f" \
    "https://uploads.github.com/repos/$OWNER/$REPO/releases/$REL_ID/assets?name=$(basename "$f")" \
    | grep -E '"name"|"message"' || true
done

echo
echo "完成 → https://github.com/$OWNER/$REPO/releases/tag/$TAG"
echo "建议随后撤销该 token，并删除 $GH_TOKEN_FILE"