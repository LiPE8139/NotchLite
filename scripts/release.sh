#!/bin/bash
#
# Release helper for NotchLite's two lines:
#
#   desktop (本机日常版)   分支 desktop-multisource   → 构建、安装到 /Applications、存快照、打标签
#   public  (GitHub 公开版) 分支 public-release         → 构建、打 DMG、推送、发 Release
#
# 用法:
#   scripts/release.sh desktop 0.2.4        # 日常版：装到本机并固化
#   scripts/release.sh public 1.1.2         # 公开版：构建打包并发布到 GitHub
#   scripts/release.sh sync <commit>        # 把某个提交 cherry-pick 到另一条线
#   scripts/release.sh sync --to desktop <commit>
#
# 公开版发布需要 token：默认读取仓库上一级目录的 token.txt
#   （亦可 TOKEN_FILE=/path/to/token.txt 覆盖），发布完成后请手动撤销该 token。
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

DESKTOP_BRANCH="desktop-multisource"
PUBLIC_BRANCH="public-release"
REMOTE_SSH="ssh://git@ssh.github.com:443/LiPE8139/NotchLite.git"
GH_REPO="LiPE8139/NotchLite"
TOKEN_FILE="${TOKEN_FILE:-$(dirname "$REPO")/token.txt}"

# The build needs a workspace-local cache; the paths contain a space, so they stay quoted.
export TMPDIR="$REPO/.tmp"
export CLANG_MODULE_CACHE_PATH="$REPO/.mc"
export SWIFT_BUILD_FLAGS="--disable-sandbox --scratch-path .build --cache-path .cache"

info()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
ok()    { printf '    ✅ %s\n' "$*"; }
warn()  { printf '    ⚠️  %s\n' "$*"; }
die()   { printf '    ❌ %s\n' "$*" >&2; exit 1; }

need_branch() {
    local current
    current="$(git branch --show-current)"
    [ "$current" = "$1" ] || die "需要先切到分支 $1（当前是 ${current:-detached}）"
    # Tags must point at the code that was actually built, so refuse an uncommitted tree.
    [ -z "$(git status --porcelain)" ] || die "工作区有未提交改动，先 commit 再发布（否则标签会指向旧代码）"
}

# Git over ssh.github.com:443 — github.com:22 is blocked on this network.
git_ssh() {
    local key="$REPO/.deploy/github_key"
    [ -f "$key" ] || die "缺少部署密钥 $key"
    # GIT_SSH_COMMAND splits on spaces, and this repo path has one, so stage a copy.
    local tmp_key="/tmp/notchlite-deploy-key"
    cp "$key" "$tmp_key" && chmod 600 "$tmp_key"
    GIT_SSH_COMMAND="ssh -i $tmp_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" "$@"
}

api() {  # api <method> <path> [curl args...]
    local method="$1" path="$2"; shift 2
    local token; token="$(tr -d ' \n\r' < "$TOKEN_FILE")"
    curl -sS -m 60 -X "$method" \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com$path" "$@"
}

require_token() {
    [ -f "$TOKEN_FILE" ] || die "缺少 token：把 GitHub PAT 存到 $TOKEN_FILE"
    local login
    login="$(api GET /user | python3 -c 'import sys,json;print(json.load(sys.stdin).get("login",""))' 2>/dev/null || true)"
    [ -n "$login" ] || die "token 无效或 API 不可达"
    ok "GitHub 账号 $login"
}

# ---------------------------------------------------------------------------

release_desktop() {
    local version="$1"
    need_branch "$DESKTOP_BRANCH"
    info "构建日常版 $version"
    VERSION="$version" bash scripts/build-app.sh | tail -1
    info "安装到 /Applications"
    VERSION="$version" bash scripts/install.sh | tail -1
    sleep 3
    local pid; pid="$(pgrep -x NotchLite | head -1 || true)"
    [ -n "$pid" ] && ok "运行中 pid=$pid"

    info "保存应用快照"
    mkdir -p backups
    rm -rf "backups/NotchLite-$version-daily.app"
    ditto /Applications/NotchLite.app "backups/NotchLite-$version-daily.app"
    ok "backups/NotchLite-$version-daily.app"

    info "打标签"
    git tag -f "desktop-$version" HEAD >/dev/null
    git -c user.name=NotchLite -c user.email=local@notchlite \
        tag -f -a "v$version-desktop" -m "日常版 $version" HEAD >/dev/null
    ok "desktop-$version / v$version-desktop"
    printf '\n回滚: git checkout desktop-%s && bash scripts/install.sh\n' "$version"
}

release_public() {
    local version="$1"
    need_branch "$PUBLIC_BRANCH"
    require_token

    info "构建公开版 $version"
    VERSION="$version" bash scripts/build-app.sh | tail -1
    local app="build/NotchLite.app"
    [ -d "$app" ] || die "构建产物缺失"

    info "生成安装包"
    rm -rf build/dmg && mkdir -p build/dmg
    ditto "$app" build/dmg/NotchLite.app
    ln -s /Applications build/dmg/Applications
    local dmg="build/NotchLite-$version.dmg" zip="build/NotchLite-$version.zip"
    rm -f "$dmg" "$zip"
    hdiutil create -volname NotchLite -srcfolder build/dmg -ov -format UDZO "$dmg" >/dev/null
    ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
    ok "$(basename "$dmg") $(du -h "$dmg" | cut -f1) / $(basename "$zip") $(du -h "$zip" | cut -f1)"
    shasum -a 256 "$dmg" | awk '{print "    SHA256:", $1}'

    info "推送 main"
    git push origin "$PUBLIC_BRANCH:main" | tail -1
    git tag -f "v$version" HEAD >/dev/null
    git push -f origin "v$version" | tail -1

    info "创建 Release"
    local body; body="$(mktemp)"
    cat > "$body" <<MD
A deliberately small macOS notch app: **Now Playing + a file shelf**.

## 安装

1. 下载 \`NotchLite-$version.dmg\`
2. 打开后把 NotchLite 拖进 Applications
3. 从「应用程序」启动

> 未经 Apple 公证，首次打开若被拦，请右键 → 打开。

需要 macOS 14 或更高。完整说明见仓库 README。
MD
    local payload; payload="$(mktemp)"
    python3 - "$version" "$body" "$payload" <<'PY'
import json, sys
version, body_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump({"tag_name": f"v{version}", "name": f"NotchLite {version}",
           "body": open(body_path).read()}, open(out, "w"))
PY
    local release_id
    release_id="$(api POST /repos/$GH_REPO/releases -d @"$payload" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))')"
    [ -n "$release_id" ] || die "Release 创建失败"
    ok "Release id=$release_id"

    info "上传资源"
    local token; token="$(tr -d ' \n\r' < "$TOKEN_FILE")"
    local asset
    for asset in "$dmg" "$zip"; do
        curl -sS -m 300 -X POST \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/octet-stream" \
            --data-binary "@$asset" \
            "https://uploads.github.com/repos/$GH_REPO/releases/$release_id/assets?name=$(basename "$asset")" \
            | python3 -c 'import sys,json;d=json.load(sys.stdin);print("    ", d.get("name"), d.get("state") or d.get("message"))'
    done
    rm -f "$body" "$payload"

    printf '\n完成: https://github.com/%s/releases/tag/v%s\n' "$GH_REPO" "$version"
    warn "发布完成后请撤销 token：https://github.com/settings/tokens"
    warn "本机 /Applications 未改动（公开版只构建不安装）"
}

sync_commit() {
    local target="$1" commit="$2"
    local branch
    if [ "$target" = "public" ]; then branch="$PUBLIC_BRANCH"; else branch="$DESKTOP_BRANCH"; fi
    info "把 $commit cherry-pick 到 $branch"
    git checkout "$branch"
    git -c user.name=NotchLite -c user.email=local@notchlite cherry-pick "$commit"
    ok "已应用；确认无误后用 release.sh 发布 ${branch}"
}

# ---------------------------------------------------------------------------

case "${1:-}" in
    desktop)
        [ $# -ge 2 ] || die "用法: scripts/release.sh desktop <version>"
        release_desktop "$2"
        ;;
    public)
        [ $# -ge 2 ] || die "用法: scripts/release.sh public <version>"
        release_public "$2"
        ;;
    sync)
        shift
        target="public"
        if [ "${1:-}" = "--to" ]; then target="$2"; shift 2; fi
        [ $# -ge 1 ] || die "用法: scripts/release.sh sync [--to public|desktop] <commit>"
        sync_commit "$target" "$1"
        ;;
    *)
        awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}" 
        exit 0
        ;;
esac
