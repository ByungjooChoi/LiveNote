<p align="center">
  <img src="livenote2/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="livenote2 아이콘 (건곤감리)" />
</p>

<h1 align="center">livenote2</h1>

<p align="center">
봇 없이 회의를 기록하는 로컬 우선 macOS 노트테이커.<br/>
영어 회의를 실시간 전사하고, 한국어로 번역하고, 화자를 구분하고, 끝나면 요약합니다.
</p>

---

## 왜 만들었나

Granola(클라우드 처리·유료)와 Alt(화자구분이 Pro 유료)의 개인용 대체입니다. 회의 오디오가 기본적으로 Mac 밖으로 나가지 않고, 무료·무제한이며, 화자구분과 한국어 실시간 번역까지 한 번에 됩니다. 전신인 LiveNote v1(Python + Gemini S2ST, `legacy-livenote1` 브랜치)을 완전히 갈아엎은 네이티브 재작성입니다.

## 주요 기능

| 기능 | 구현 |
|---|---|
| 봇 없는 회의 캡처 | 마이크 = 나, 시스템 오디오 = 상대방. 2채널 동시 캡처 (Core Audio Process Tap, 가상 드라이버 불필요) |
| 실시간 영어 전사 | Parakeet TDT v2 (CoreML/ANE, 100% 로컬) + 잠정/확정 2단계 표시 |
| 화자구분 | LS-EEND 스트리밍 (상대방 1/2/3…, 칩 클릭으로 이름 편집) |
| 한국어 번역 | 로컬(Apple Translation, 기본) / 클라우드(Gemini 3.5 Live Translate, 옵션) 선택 |
| 회의 요약 | Qwen3.5-4B 4bit 로컬 (요약할 때만 로드, 한국어 출력) |
| 캘린더 연동 | 회의 시작 1분 전 팝업, Zoom 딥링크로 브라우저 없이 바로 참가 + 기록 자동 시작 |
| 에코 방어 | 마이크 뮤트 버튼(⌘⇧M) + 3층 자동 필터 (포락선 상관 게이트, 세그먼트 폐기, 텍스트 dedup) |
| 회의 자동화 | Zoom/Teams/Webex 실행·종료 감지, 4분 무음 자동 저장, 메뉴바 상주 |
| 아카이브 | 회의별 `session.json` + `en.md` / `ko.md` / `combined.md` / `summary.md` |

## 파이프라인

```
마이크(나) ─┐
            ├→ 16kHz 변환 → 에너지 VAD 문장 분리 → Parakeet 전사 ─→ 행(EN)
시스템 탭(상대방) ─┘                └→ LS-EEND 화자 슬롯 매핑          ↓
                                                     번역 (Apple 로컬 / Gemini 클라우드)
                                                                     ↓
                                             ~/Documents/livenote2/ 저장 + Qwen 요약
```

## 요구사항

- Apple Silicon Mac, macOS 15 이상 (개발·검증은 26.x)
- Xcode 26 (빌드 시)
- 모델은 최초 실행 시 자동 다운로드: Parakeet 약 460MB, LS-EEND, 요약 최초 사용 시 Qwen 약 2.3GB
- 클라우드 번역을 쓸 때만 [Gemini API 키](https://aistudio.google.com/apikey) 필요 (macOS 키체인에만 저장)

## 빌드와 설치

```bash
git clone https://github.com/ByungjooChoi/LiveNote.git
cd LiveNote
open livenote2.xcodeproj   # Xcode에서 ⌘R
```

배포용 패키징(DMG + sha256 + 설치 가이드)은 한 줄입니다:

```bash
./script/package.sh 1.0.2   # 결과물: dist/
```

첫 시작 시 권한을 허용하세요: 마이크, 화면 및 시스템 오디오 녹음, 캘린더(회의 알림용, 선택). ad-hoc 서명 빌드라서 재설치 때마다 마이크·시스템 오디오 권한을 다시 허용해야 합니다.

## 사용법

1. **시작**을 누르면 전사가 올라오고, 확정 문장은 2~3초 안에 한국어가 붙습니다.
2. 헤더의 **마이크 아이콘**을 누르면 뮤트됩니다. 말하지 않는 회의에서 켜 두면 스피커 에코가 "나"로 잘못 잡히는 일이 없습니다.
3. **번역** 메뉴에서 로컬/클라우드를 고릅니다. 클라우드는 품질이 더 좋지만 회의 오디오가 Google로 전송됩니다.
4. **중지**하면 자동 저장되고, 요약 카드에서 **요약 생성**을 누르면 한국어 회의 요약이 만들어집니다.
5. 캘린더에 Zoom 링크가 있는 일정이 있으면 시작 1분 전에 우상단 팝업이 뜨고, **Zoom 참가**를 누르면 참가와 동시에 기록이 시작됩니다.

## 프라이버시

기본 설정에서 모든 처리(전사·화자구분·번역·요약)는 Mac 안에서 끝납니다. 네트워크는 최초 모델 다운로드에만 쓰입니다. 오디오는 어떤 형태로도 저장하지 않으며 텍스트만 남습니다. 예외는 하나: 클라우드 번역을 직접 켠 경우에만 회의 오디오가 Google Gemini API로 전송됩니다.

## 문서

- [`livenote2-개발스펙.md`](livenote2-개발스펙.md): 이 문서만 보고 동일한 앱을 재구축할 수 있는 수준의 전체 스펙 (아키텍처, 튜닝 상수, 밟았던 함정 전부)
- [`AirTranslate-비교분석-리포트.md`](AirTranslate-비교분석-리포트.md): 유사 프로젝트 AirTranslate와의 상세 비교
- [`참조프로젝트-7종-분석리포트.md`](참조프로젝트-7종-분석리포트.md): Gemini Live Translate 생태계 7개 프로젝트 분석과 채택 내역

## 기술 스택

Swift/SwiftUI · [FluidAudio](https://github.com/FluidInference/FluidAudio) (Parakeet TDT v2, LS-EEND) · Apple Translation · [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) (Qwen3.5-4B) · Core Audio Process Tap · EventKit · Gemini Live API (옵션)

개인 프로젝트입니다. AI 페어(Claude)와 함께 개발했습니다.
