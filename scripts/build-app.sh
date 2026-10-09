#!/bin/sh
# "Slash Command.app" 을 dist/ 에 만든다. `--install` 을 주면 ~/Applications 에 복사하고 다시 띄운다.
set -eu
cd "$(dirname "$0")/.."

swift build -c release
bin=$(swift build -c release --show-bin-path)

app="dist/Slash Command.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/SlashCommandApp" "$app/Contents/MacOS/SlashCommand"
# macOS 기본 파일 시스템은 대소문자를 구분하지 않아 `slashcommand` 로 두면 위의 `SlashCommand` 를 덮어쓴다.
cp "$bin/slashcommand" "$app/Contents/MacOS/slashcommand-cli"
cp scripts/Info.plist "$app/Contents/Info.plist"
# 아이콘은 scripts/make-icon.swift 로 다시 만든다.
mkdir -p "$app/Contents/Resources"
cp scripts/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# 개발 인증서가 있으면 그걸로 서명한다 — 다시 빌드해도 Ghostty 제어 권한(자동화)이 유지된다.
# 없으면 임시 서명으로 떨어지고, 그때는 빌드마다 권한을 다시 묻는다.
identity=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
codesign --force --sign "${identity:--}" "$app"
echo "서명: ${identity:-임시(ad-hoc)}"

if [ "${1:-}" = "--install" ]; then
    dest="$HOME/Applications/Slash Command.app"
    mkdir -p "$HOME/Applications"
    # 옛 이름(ModelSwitch)으로 깔린 것을 먼저 치운다 — 같이 떠 있으면 같은 단축키를 두고 다툰다.
    # 프리셋(~/.config/modelswitch)은 새 앱이 처음 뜰 때 복사해 가므로 그대로 둔다.
    old="$HOME/Applications/ModelSwitch.app"
    if [ -d "$old" ]; then
        "$old/Contents/MacOS/ModelSwitch" --login-item off >/dev/null 2>&1 || true
        osascript -e 'tell application id "com.yohangwak.modelswitch" to quit' >/dev/null 2>&1 || true
        rm -rf "$old"
        oldlink="$HOME/.local/bin/modelswitch"
        if [ -L "$oldlink" ]; then rm -f "$oldlink"; fi
        echo "옛 설치 정리: $old"
    fi
    osascript -e 'tell application id "com.yohangwak.slashcommand" to quit' >/dev/null 2>&1 || true
    rm -rf "$dest"
    cp -R "$app" "$dest"
    # 터미널에서도 `slashcommand` 로 쓸 수 있게 링크를 건다(다른 파일이 이미 있으면 건드리지 않는다).
    link="$HOME/.local/bin/slashcommand"
    if [ -d "$HOME/.local/bin" ] && { [ -L "$link" ] || [ ! -e "$link" ]; }; then
        ln -sf "$dest/Contents/MacOS/slashcommand-cli" "$link"
    fi
    # 방금 끈 앱을 바로 다시 열면 가끔 실패한다(-600). 잠깐 두고 한 번 더 연다.
    open "$dest" 2>/dev/null || { sleep 2; open "$dest"; }
    echo "설치: $dest"
else
    echo "완료: $app"
fi
