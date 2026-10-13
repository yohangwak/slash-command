#!/bin/sh
# "Slash Command.app" 을 dist/ 에 만든다. `--install` 을 주면 ~/Applications 에 복사하고 다시 띄운다.
set -eu
cd "$(dirname "$0")/.."

# SLASHCOMMAND_UNIVERSAL=1 이면 Apple silicon · Intel 둘 다 든 실행 파일을 만든다(릴리스용 — Xcode 가 있어야 한다).
if [ "${SLASHCOMMAND_UNIVERSAL:-}" = 1 ]; then
    swift build -c release --arch arm64 --arch x86_64
    bin=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
else
    swift build -c release
    bin=$(swift build -c release --show-bin-path)
fi

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
# 번역: Resources/<언어>.lproj 를 그대로 넣는다. 시스템이 이 폴더들을 보고 앱의 언어를 고른다(앱별 언어 설정에도 뜬다).
cp -R Resources/*.lproj "$app/Contents/Resources/"

# 개발 인증서가 있으면 그걸로 서명한다 — 다시 빌드해도 Ghostty 제어 권한(자동화)이 유지된다.
# 없으면 임시 서명으로 떨어지고, 그때는 빌드마다 권한을 다시 묻는다.
# SLASHCOMMAND_SIGN_IDENTITY 로 인증서를 정할 수 있다(릴리스는 "Developer ID Application: …" — scripts/release.sh).
identity=${SLASHCOMMAND_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}
if [ -n "$identity" ]; then
    # 인증서로 서명할 때는 Hardened Runtime 을 켠다(공증의 조건이고, 개발 빌드도 릴리스와 같은 조건에서 돌게).
    # 안에 든 명령줄 도구는 따로 서명해야 한다 — 묶음 서명은 그 파일을 다시 서명하지 않는다.
    for item in "$app/Contents/MacOS/slashcommand-cli" "$app"; do
        codesign --force --options runtime --timestamp --entitlements scripts/SlashCommand.entitlements --sign "$identity" "$item"
    done
else
    codesign --force --sign - "$app"
fi
echo "서명: ${identity:-임시(ad-hoc)}"

if [ "${1:-}" = "--install" ]; then
    dest="$HOME/Applications/Slash Command.app"
    mkdir -p "$HOME/Applications"
    # 옛 이름(ModelSwitch)으로 깔린 것을 먼저 치운다 — 같이 떠 있으면 같은 단축키를 두고 다툰다.
    # 프리셋(~/.config/modelswitch)은 새 앱이 처음 뜰 때 복사해 가므로 그대로 둔다.
    old="$HOME/Applications/ModelSwitch.app"
    if [ -d "$old" ]; then
        # 옛 실행 파일의 `off` 는 «켜짐» 일 때만 해제하고, «승인 대기» 로 등록된 항목은 그대로 둔 채 `off` 라고 답한다.
        # 그래서 켜져 있던 것을 끈 경우에만 해제했다고 말하고, 나머지는 확인하지 못했다고 알린다.
        oldbin="$old/Contents/MacOS/ModelSwitch"
        was=$("$oldbin" --login-item status 2>/dev/null || echo "알 수 없음")
        if [ "$was" = on ]; then
            if [ "$("$oldbin" --login-item off 2>/dev/null || true)" = off ]; then
                echo "옛 로그인 항목 해제"
            else
                echo "옛 로그인 항목을 해제하지 못했습니다 — 시스템 설정 → 일반 → 로그인 항목에서 ModelSwitch 를 지워 주세요."
            fi
        else
            echo "옛 로그인 항목: 켜져 있지 않음($was). 승인 대기로 남아 있었다면 시스템 설정 → 일반 → 로그인 항목에서 ModelSwitch 를 지워 주세요."
        fi
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
