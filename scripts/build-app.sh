#!/bin/sh
# ModelSwitch.app 을 dist/ 에 만든다. `--install` 을 주면 ~/Applications 에 복사하고 다시 띄운다.
set -eu
cd "$(dirname "$0")/.."

swift build -c release
bin=$(swift build -c release --show-bin-path)

app=dist/ModelSwitch.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/ModelSwitchApp" "$app/Contents/MacOS/ModelSwitch"
# macOS 기본 파일 시스템은 대소문자를 구분하지 않아 `modelswitch` 로 두면 위의 `ModelSwitch` 를 덮어쓴다.
cp "$bin/modelswitch" "$app/Contents/MacOS/modelswitch-cli"
cp scripts/Info.plist "$app/Contents/Info.plist"

# 개발 인증서가 있으면 그걸로 서명한다 — 다시 빌드해도 Ghostty 제어 권한(자동화)이 유지된다.
# 없으면 임시 서명으로 떨어지고, 그때는 빌드마다 권한을 다시 묻는다.
identity=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
codesign --force --sign "${identity:--}" "$app"
echo "서명: ${identity:-임시(ad-hoc)}"

if [ "${1:-}" = "--install" ]; then
    dest="$HOME/Applications/ModelSwitch.app"
    mkdir -p "$HOME/Applications"
    osascript -e 'tell application id "com.yohangwak.modelswitch" to quit' >/dev/null 2>&1 || true
    rm -rf "$dest"
    cp -R "$app" "$dest"
    # 터미널에서도 `modelswitch` 로 쓸 수 있게 링크를 건다(다른 파일이 이미 있으면 건드리지 않는다).
    link="$HOME/.local/bin/modelswitch"
    if [ -d "$HOME/.local/bin" ] && { [ -L "$link" ] || [ ! -e "$link" ]; }; then
        ln -sf "$dest/Contents/MacOS/modelswitch-cli" "$link"
    fi
    # 방금 끈 앱을 바로 다시 열면 가끔 실패한다(-600). 잠깐 두고 한 번 더 연다.
    open "$dest" 2>/dev/null || { sleep 2; open "$dest"; }
    echo "설치: $dest"
else
    echo "완료: $app"
fi
