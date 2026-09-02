#!/bin/zsh
# livenote2 배포 패키징: Release 아카이브 → DMG + sha256 + 설치 가이드
# 사용법: ./script/package.sh [버전]   (기본 1.0.0)
set -euo pipefail

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "$(dirname "$0")/.."

VERSION=${1:-1.0.0}
ARCHIVE=/tmp/livenote2.xcarchive
DIST=dist
APP_NAME=LiveNote

echo "==> Release 아카이브 빌드"
rm -rf "$ARCHIVE"
xcodebuild -project livenote2.xcodeproj -scheme livenote2 -configuration Release \
  archive -archivePath "$ARCHIVE" -allowProvisioningUpdates | tail -3

APP="$ARCHIVE/Products/Applications/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "아카이브 실패: $APP 없음"; exit 1; }

# BUNDLE_MODELS=1이면 FluidAudio 모델(약 0.5GB)을 앱에 동봉 — 첫 실행 다운로드 생략.
# Qwen(2.3GB+)은 GitHub 릴리스 2GB 한도로 동봉하지 않음.
if [[ "${BUNDLE_MODELS:-0}" == "1" ]]; then
  MODEL_SRC="$HOME/Library/Application Support/FluidAudio/Models"
  if [[ -d "$MODEL_SRC" ]]; then
    echo "==> 모델 동봉 (FluidAudio, $(du -sh "$MODEL_SRC" | cut -f1))"
    mkdir -p "$APP/Contents/Resources/BundledModels"
    cp -R "$MODEL_SRC/." "$APP/Contents/Resources/BundledModels/"
    codesign --force --deep -s - "$APP"   # 리소스 추가 후 ad-hoc 재서명
  else
    echo "==> 모델 동봉 건너뜀 (캐시 없음: $MODEL_SRC)"
  fi
fi

echo "==> DMG 생성"
mkdir -p "$DIST"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> 체크섬"
( cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )

cat > "$DIST/INSTALL.md" <<'EOF'
# LiveNote 설치 가이드

1. DMG를 열고 `LiveNote.app`을 `Applications` 폴더로 드래그합니다.
2. 첫 실행: Applications에서 `LiveNote.app`을 우클릭 → 열기 → 경고 대화상자에서 다시 열기.
   (Personal Team 서명 빌드라 최초 1회 필요. Developer ID 서명·노터라이즈는 추후 단계)
3. 첫 시작 시 권한 허용 (모두 1회):
   - 마이크
   - 화면 및 시스템 오디오 녹음
   - 캘린더 (회의 1분 전 참가 알림용, 선택)
4. 체크섬 검증 (선택):
   shasum -a 256 livenote2-*.dmg 결과를 .sha256 파일과 대조

주의: 앱을 업데이트(재설치)하면 macOS 정책상 마이크·시스템 오디오 권한을 다시 허용해야 합니다.
EOF

echo "==> 완료"
ls -lh "$DIST"
