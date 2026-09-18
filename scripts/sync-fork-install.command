#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT"

# 记录当前仓库路径至用户配置，方便应用随时定位脚本
mkdir -p "$HOME/.config/pebrel"
echo "$REPO_ROOT" > "$HOME/.config/pebrel/source_repo"

echo "========================================================"
echo "         Pebrel 一键同步 Fork 仓库并打包安装"
echo "========================================================"
echo "📂 仓库根目录: $REPO_ROOT"
echo ""

# 1. 检查并添加 upstream 远端
if ! git remote | grep -q "^upstream$"; then
    echo "⚙️  正在添加上游源仓库 (upstream: https://github.com/Kuddev/pebrel.git)..."
    git remote add upstream https://github.com/Kuddev/pebrel.git
fi

# 2. 拉取上游最新更新
echo "📥 [1/4] 正在拉取上游源仓库最新更新 (git fetch upstream)..."
git fetch upstream

CURRENT_BRANCH="$(git branch --show-current)"
if [[ -z "$CURRENT_BRANCH" ]]; then
    CURRENT_BRANCH="main"
fi

# 检查工作区是否有未暂存的修改，如有则自动 stash
STASHED=0
if [[ -n "$(git status --porcelain)" ]]; then
    echo "📦 检测到本地工作区有修改，正在临时暂存 (git stash)..."
    git stash push -m "pebrel-auto-sync-stash"
    STASHED=1
fi

echo "🔄 [2/4] 正在变基合并上游代码到当前分支 ($CURRENT_BRANCH)..."
if git rebase upstream/main; then
    echo "✅ 上游代码同步成功！"
    if [[ $STASHED -eq 1 ]]; then
        echo "📦 正在恢复本地暂存的修改 (git stash pop)..."
        git stash pop || echo "⚠️ 恢复本地修改遇到冲突，请留意！"
    fi
else
    echo "⚠️  检测到代码冲突，正在中止变基并恢复现场..."
    git rebase --abort || true
    if [[ $STASHED -eq 1 ]]; then
        git stash pop || true
    fi
    echo ""
    echo "❌ 同步失败：存在代码冲突，请在终端手动解决冲突后重试。"
    read -p "按回车键退出..."
    exit 1
fi

# 3. 同步推送到用户的 Fork 仓库 (origin)
echo "🚀 正在推送到您的 GitHub Fork 仓库 (git push origin $CURRENT_BRANCH)..."
git push origin "$CURRENT_BRANCH" || echo "⚠️ 推送至 origin 失败或无需推送，继续本地编译打包..."

# 4. 编译 Release
echo ""
echo "🔨 [3/4] 正在编译 Release 版本 (cargo build --release -p nebula --bin pebrel)..."
cargo build --release -p nebula --bin pebrel

# 5. 打包 macOS 应用
echo ""
echo "📦 [4/4] 正在打包 macOS 应用 (scripts/package-macos.sh)..."
VERSION=$(grep -m1 '^version =' "$REPO_ROOT/Cargo.toml" | sed -E 's/.*"([^"]+)".*/\1/' || echo "1.8.2")
ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" ]]; then
    PKG_ARCH="aarch64"
    DMG_ARCH="arm64"
else
    PKG_ARCH="x86_64"
    DMG_ARCH="x86_64"
fi

bash "$REPO_ROOT/scripts/package-macos.sh" --binary "$REPO_ROOT/target/release/pebrel" --version "$VERSION" --channel stable --architecture "$PKG_ARCH" --build-number 1 --output-directory "$REPO_ROOT/dist" --force

# 6. 安装至 /Applications/Pebrel.app
echo ""
echo "💻 正在安装至系统应用程序目录 (/Applications/Pebrel.app)..."
DMG_PATH="$REPO_ROOT/dist/Pebrel-v${VERSION}-macos-${DMG_ARCH}.dmg"
TMP_MOUNT="/tmp/pebrel_mount_$$"
mkdir -p "$TMP_MOUNT"
if [[ -f "$DMG_PATH" ]] && hdiutil attach "$DMG_PATH" -mountpoint "$TMP_MOUNT" -nobrowse -quiet; then
    if [[ -d "$TMP_MOUNT/Pebrel.app" ]]; then
        rm -rf /Applications/Pebrel.app
        cp -R "$TMP_MOUNT/Pebrel.app" /Applications/
        hdiutil detach "$TMP_MOUNT" -quiet || true
        rm -rf "$TMP_MOUNT"
        echo "✅ 已成功安装替换 /Applications/Pebrel.app！"
    else
        hdiutil detach "$TMP_MOUNT" -quiet || true
        rm -rf "$TMP_MOUNT"
        if [[ -d "$REPO_ROOT/dist/Pebrel.app" ]]; then
            rm -rf /Applications/Pebrel.app
            cp -R "$REPO_ROOT/dist/Pebrel.app" /Applications/
            echo "✅ 已成功安装替换 /Applications/Pebrel.app！"
        fi
    fi
else
    if [[ -d "$REPO_ROOT/dist/Pebrel.app" ]]; then
        rm -rf /Applications/Pebrel.app
        cp -R "$REPO_ROOT/dist/Pebrel.app" /Applications/
        echo "✅ 已成功安装至 /Applications/Pebrel.app！"
    fi
fi

# 发送桌面通知
osascript -e 'display notification "Pebrel 已成功同步并重新安装至系统应用程序！" with title "Pebrel 更新完成"' 2>/dev/null || true

echo ""
echo "========================================================"
echo "🎉 全部完成！最新版 Pebrel 已安装至 /Applications/Pebrel.app"
echo "💡 请重新启动 Pebrel 应用以加载最新版本。"
echo "========================================================"
echo ""
read -p "按回车键退出窗口..."
