# LiveNote v2 제품 개선 기획서

작성일 2026-09-02. 기준 버전 v1.3.0. 범위: 경쟁 분석(docs/feature-plan-jamie-granola-2026-09.md)에서 수용한 C(Recipes), B(사전 브리핑), A(Speaker Memory), D(액션아이템/Tasks), F(전사 편집·용어 학습), G(소소한 개선 + 알림 분할 버튼). E(Scratchpad·템플릿)는 제외.

이 문서는 "무엇을, 왜, 어떤 사용성으로" 만들지를 정한다. "어떤 순서로, 어떤 파일을" 고칠지는 구현 기획서(docs/implementation-plan-v2-2026-09.md)에 따로 둔다.

---

## 0. 설계 원칙

1. **실시간 경로 불변**: 회의 중 라이브 전사·번역·채팅의 지연과 안정성을 해치는 기능은 회의 종료 후(2-pass 이후) 또는 회의 전(브리핑)으로 옮긴다.
2. **로컬 우선, 파일 소유**: 모든 산출물은 ~/Documents/LiveNote 아래 사람이 읽을 수 있는 md/json으로 남는다. 클라우드는 백엔드가 Cloud일 때만, 그것도 텍스트만 나간다(오디오는 번역 스트림 외 불송신).
3. **자동화 우선, 수동은 보정**: Jamie 철학. 사용자가 아무것도 안 해도 이름·태스크·브리핑이 나오고, 수동 입력은 자동 결과를 고치는 용도다.
4. **기존 파이프라인 재사용**: 요약(SummaryService/GeminiSummarizer), 채팅(GeminiChat/LocalChatEngine), 컨텍스트 조립(buildChatContext), 2-pass(TranscriptRefiner)를 새 기능의 엔진으로 쓴다. 새 LLM 호출 경로를 만들지 않는다.
5. **UI는 Granola 문법 유지**: 좌측 레일(Home/Chat/Live/Settings), 카드, 한지 캔버스·쪽빛 액센트. 새 화면은 최대 두 개(Tasks, Speakers는 Settings 카드).

---

## 1. Recipes (C)

### 1.1 목표
아카이브를 "다시 읽는" 대신 "돌리는" 것. 저장된 프롬프트를 선택한 회의 집합에 실행해 문서를 만든다. 첫 번째 킬러 레시피는 금요일 주간보고 초안이다.

### 1.2 사용 시나리오
- 금요일 오후: Chat 화면 Recipes 행에서 "Weekly Update" 클릭 → 범위 기본값 "이번 주(월~금)" → 실행 → 계정별 단락으로 정리된 한국어 주간보고 초안이 대화로 나타남 → 복사해 이메일에 붙임.
- 고객 콜 직후: 회의 상세 화면에서 "Follow-up email" 레시피 → 이 회의 하나를 범위로 영문 후속 이메일 초안.
- 월요일: "Open commitments" 레시피 → 최근 2주 회의에서 내가 약속한 것 목록.

### 1.3 기술 분석

**레시피 정의**: `~/Documents/LiveNote/recipes/<slug>.json`
```json
{
  "id": "weekly-update",
  "title": "Weekly Update",
  "icon": "doc.text",
  "builtin": true,
  "scopeDefault": "thisWeek",        // thisWeek | lastNDays:14 | currentMeeting | manual
  "modelHint": "thinking",           // standard | thinking (Auto 라우팅 힌트)
  "outputLanguage": "Korean",
  "system": "…주간보고 규칙…",
  "prompt": "…{{meetings}} 자리표시자 포함…"
}
```
내장 레시피는 앱 번들에 두고 첫 실행 시 recipes/ 폴더로 복사한다(사용자가 수정 가능, 삭제하면 다음 실행에 원본 복원). 사용자 레시피는 같은 폴더에 `builtin:false`로 추가.

**내장 레시피 5종**
| 레시피 | 범위 기본 | 출력 |
|---|---|---|
| Weekly Update | 이번 주 | 한국어, 계정별 단락. CLAUDE.md의 주간보고 규칙을 시스템 프롬프트에 내장: 1인칭 주어 생략, 판단·논리 흐름 서술("[사람]과의 논의 결과 … 설명하였다"), SA 행위 중심, 이메일·슬라이드 나열 금지, 배정 경위 미기재, 인과를 한 문장으로 압축 |
| Follow-up email | 현재 회의 | 영문 이메일 초안 (수신자 = 참석자, 결정·다음 단계·질문) |
| Open commitments | 최근 14일 | 내가/상대가 약속한 항목, 회의·날짜 출처 |
| Customer call brief (EN) | 현재 회의 | 영문 내부 공유용 요약 (Situation / Asks / Risks / Next) |
| Korean digest | 현재 회의 | 한국어 3문단 요약 (팀 공유용) |

**범위 선택기**: thisWeek(월요일 00:00 기준), lastNDays, currentMeeting, manual(회의 다중 선택 시트). 회의 목록은 MeetingStore.meetings 메타데이터(startedAt, title)만으로 필터한다. 검색 불필요.

**컨텍스트 조립**: 회의당 summary.md 우선, 없으면 전사 앞 6,000자. 회의 헤더(제목·날짜·참석자·소요시간)를 붙인다. 총 상한 120K자(Gemini 3.7 Flash 1M 컨텍스트 기준 여유). 상한 초과 시 최신 회의부터 채우고 잘린 회의 수를 UI에 표시. 기존 `buildChatContext(.archive)`를 일반화한 `ContextBuilder.build(meetings:[MeetingSummary], budget:)`로 승격.

**모델 라우팅**: 레시피 `modelHint`가 thinking이면 채팅 모델 선택과 무관하게 3.7 Flash Thinking(medium) 기본, 사용자가 실행 시트에서 덮어쓸 수 있다. 로컬 백엔드(API 키 없음)면 Qwen으로 실행(품질 경고 표시).

**실행·저장**: 실행은 새 채팅 대화로 생성된다(ChatStore에 저장, 제목 = 레시피명 + 범위). 결과에 "회의 N개 사용" 배지와 사용 회의 목록(접힘)이 붙는다. 결과는 md로 `~/Documents/LiveNote/recipes-output/<date> <recipe>.md`에도 저장(주간보고 파일 보관 규칙과 연결: 2주 경과 파일은 사용자 규칙대로 정리 대상, 앱은 삭제하지 않음).

**후속 대화**: 결과가 채팅이므로 "Intuit 단락을 더 짧게" 같은 수정 요청이 그대로 이어진다. 레시피 컨텍스트는 대화 첫 턴에 주입돼 있으므로 재조립 불필요.

### 1.4 UI
- Chat 홈(히어로 아래 Recents 위)에 **Recipes 칩 행**: 내장 5개 + 사용자 레시피 + "See all". Granola 캡처와 같은 배치.
- 칩 클릭 → **실행 시트**: 범위 세그먼트(This week / Last 14 days / This meeting / Choose…), 선택된 회의 수와 목록 미리보기, 모델 선택(기본값 표시), 출력 언어, [Run]. 실행 중 진행 표시 후 대화로 전환.
- 회의 상세 화면 툴바에 "Recipes" 메뉴(현재 회의 범위 레시피만 노출).
- Settings > Recipes 카드: 목록, 편집(JSON 편집 대신 제목/시스템/프롬프트/범위 폼), 복제, 삭제, "Reset built-ins".

### 1.5 엣지·리스크
- 이번 주 회의가 0개: 실행 버튼 비활성 + 안내.
- 요약 없는 회의(15행 미만)는 전사 발췌로 대체하며 결과 신뢰도 낮음을 헤더에 명시.
- 주간보고 규칙 프롬프트는 사용자 CLAUDE.md의 사본이 아니라 레시피 파일에 내장(앱은 CLAUDE.md를 읽지 않는다). 규칙이 바뀌면 레시피를 편집한다.
- 성공 지표: 금요일 주간보고 작성 시간(현재 Claude 대화로 30분 내외) → 10분 이내.

---

## 2. 사전 브리핑 (B)

### 2.1 목표
회의에 들어가기 전에 "지난번에 무슨 얘기 했고, 뭐가 안 끝났고, 이번에 뭘 꺼낼지"를 30초 안에 읽게 한다. Granola 2026의 핵심 기능이며, 아카이브가 실제로 쓰이는 첫 지점.

### 2.2 트리거
1. **아침 일괄**: 앱이 떠 있으면 매일 07:00(로컬)에 오늘 일정 전체에 대해 생성. 잠자기 중이었으면 깨어난 직후 1회.
2. **회의 10분 전**: 아직 없으면 즉시 생성(캘린더 폴링 루프에서 감지).
3. **수동**: Coming up 카드의 새로고침 버튼.

### 2.3 후보 회의 선정 (검색 없이)
캘린더 이벤트에서 참석자 이메일·이름, 제목을 얻는다(CalendarMonitor는 이미 attendees와 title 접근). 과거 회의 중 다음 점수로 상위 5개, 최근 90일:
- 참석자 겹침: 저장된 회의의 `attendees`(신규 필드, session.json) 또는 화자명(speakerNames·speakerName)과 이메일 로컬파트/이름 토큰이 일치하면 +3/명
- 제목 유사도: 정규화 후 토큰 Jaccard ≥ 0.5면 +2 (반복 회의 "Philip / Craig" 잡기)
- 최근성: 30일 내 +1
- 동점이면 최신 우선. 점수 0이면 브리핑 생성 안 함(첫 회의).

### 2.4 컨텍스트와 출력
컨텍스트: 후보 회의의 summary.md(없으면 전사 앞 4,000자) + Tasks 저장소에서 참석자·회의와 연결된 **미완료 태스크**(D 기능 의존, 없으면 생략) + 오늘 이벤트의 제목·설명(notes 필드 앞 1,000자).

출력(고정 3섹션, 200~350단어, 회의 언어 자동: 참석자가 영어권이면 영어, 요약 언어 설정을 따름):
```
# Last time
- 핵심 결정·상태 3~5줄 (날짜 표기)
# Open items
- 미완료 태스크 (담당자) [출처 회의]
# Suggested agenda
- 이번 회의에서 꺼낼 것 3개, 질문형 가능
```
저장: `~/Documents/LiveNote/briefs/<eventKey>.md` + 생성 시각. 같은 이벤트는 재생성 안 함(수동 새로고침 제외). 회의가 저장될 때 그 회의 폴더에 `brief.md` 사본을 넣어 사후 맥락으로 남긴다.

모델: Gemini 3.7 Flash(standard). 회의당 1회, 하루 5~8회 → 비용 무시 가능. 로컬 백엔드면 Qwen(아침 일괄 시 모델 로드 1회 후 연속 생성).

### 2.5 UI
- **Coming up 카드**: 브리핑이 있는 일정에 "Brief" 배지. 행 클릭으로 펼침(인라인 렌더, SummaryRenderView 재사용). 없으면 "Preparing…" 또는 "No history".
- **라이브 뷰**: 회의 시작 시 상단에 접힌 "Brief" 패널(제목 줄만, 클릭 펼침). 전사가 쌓이기 시작하면 자동으로 접힘 유지.
- **알림 팝업(1분 전)**: 브리핑의 Suggested agenda 첫 줄을 부제로 표시.
- Settings > Meetings: "Pre-meeting briefs" 토글, 생성 시각(07:00), 언어.

### 2.6 엣지·리스크
- 참석자 이름이 캘린더에만 있고 과거 회의엔 화자명이 없던 경우(초기 데이터): 제목 유사도로 보완. 저장 시 attendees 필드가 쌓이면 자연 개선.
- 내부 반복 회의(All Hands)엔 브리핑 가치가 낮음: 참석자 8명 이상이면 생성 건너뜀(설정 가능).
- 성공 지표: 브리핑 펼침 비율, 사용자가 "도움됨/아님" 한 번 클릭 피드백(선택).

---

## 3. Speaker Memory (A)

### 3.1 목표
한 번 이름이 붙은 목소리는 다음 회의에서 플랫폼과 무관하게 자동으로 이름이 붙는다. Zoom AX 태그가 없는 Teams·Meet·대면·발표자 보기 상황을 커버하고, Zoom 태그가 있을 때는 그것으로 성문을 무료로 학습한다.

### 3.2 기술 분석

**임베딩 소스 (FluidAudio 0.15.5에서 확인)**
1. 오프라인 `DiarizerManager.performCompleteDiarization(samples)` → `DiarizationResult.segments: [TimedSpeakerSegment]`, 각 세그먼트에 `embedding: [Float]`(256차원, wespeaker 계열)과 `qualityScore`. `speakerDatabase: [String:[Float]]`로 클러스터 중심도 준다. `initializeKnownSpeakers([Speaker])`로 알려진 성문을 미리 등록하면 클러스터 ID가 그 이름으로 나온다. `extractSpeakerEmbedding(from:)`로 임의 구간 임베딩 추출 가능.
2. 라이브 `LSEENDDiarizer`(현재 사용) 세그먼트도 `embedding256`을 노출한다(DiarizerTypes.swift 확인). 다만 온라인 모델의 임베딩 공간이 오프라인 wespeaker와 동일하다는 보장은 없어, **성문 DB는 오프라인 임베딩 기준으로 통일**하고 라이브 임베딩은 별도 공간으로 취급한다(필요 시 라이브 전용 성문을 따로 저장).
3. `SpeakerManager.findSpeaker(with:speakerThreshold:)`가 코사인 거리 기반 최근접 탐색을 제공한다(threshold 기본값 존재).

**핵심 설계: 2-pass 시점에 오프라인 다이어라이제이션을 붙인다.**
v1.2.0의 2-pass가 세션 전체 WAV를 이미 갖고 있으므로, 재디코딩과 같은 시점에 them 채널 WAV로 `performCompleteDiarization`을 돌린다(47분 회의 기준 수십 초, ANE). 이 결과가 두 가지에 쓰인다:
- **매칭**: 클러스터 중심 임베딩을 성문 DB와 대조해 이름을 붙이고, 정제된 행(TranscriptRefiner 출력)에 시간 겹침으로 화자명을 부여한다. 우선순위: Zoom 태그 이름 > 성문 매칭 > LS-EEND 슬롯.
- **등록(enrollment)**: 이 회의에서 이름이 확정된 화자(Zoom 태그, 1:1 폴백, 사용자 수동 지정)의 세그먼트 임베딩을 모아 성문 DB에 병합한다.

**성문 DB**: `~/Documents/LiveNote/voiceprints.json`
```json
{
  "version": 1,
  "people": [{
    "name": "Craig Angulo",
    "aliases": ["Craig"],
    "centroids": [{"v": [256 floats], "n": 37, "quality": 0.82, "updated": "2026-09-01"}],
    "meetings": 6, "lastSeen": "2026-09-01",
    "sources": ["zoom", "manual"]
  }]
}
```
사람당 최대 5개 중심(마이크·환경 변화 대응). 새 임베딩이 기존 중심과 거리 < 병합 임계면 가중 평균으로 흡수, 아니면 새 중심 추가(5개 초과 시 가장 오래된 것 교체). 등록 최소 조건: 해당 화자 발화 합계 ≥ 20초, 평균 qualityScore ≥ 0.6.

**매칭 규칙**: 클러스터 중심 c에 대해 모든 중심과 코사인 거리 계산. 최근접 d1, 차근접 d2. `d1 ≤ T`(초기 T = SpeakerManager 기본값에서 시작해 실측 튜닝) 이고 `d2 - d1 ≥ 0.08`(마진)이면 확정. 마진 미달이면 "후보 2명"을 UI에 제안만 하고 자동 명명은 하지 않는다.

**충돌 처리**: Zoom 태그 이름과 성문 매칭 이름이 다르면 Zoom을 채택하고, 그 회의의 임베딩은 Zoom 이름으로 등록한다(성문이 틀렸다는 뜻이므로 기존 중심에 카운트만 남기고 갱신 보류). 3회 연속 충돌하면 해당 중심을 폐기.

**내 목소리**: 마이크 채널은 항상 me이므로 별도 성문이 필요 없다. 단, 내 성문을 저장해두면 them 채널(시스템 오디오)에 내 목소리가 섞였을 때(에코 재유입) 그 세그먼트를 식별해 버릴 수 있다. 에코 방어 보너스로 Phase 후반에 포함.

**라이브 승격(2단계)**: 회의 중 LS-EEND 슬롯이 30초 이상 쌓이면 그 슬롯 오디오로 오프라인 임베딩을 1회 추출(`extractSpeakerEmbedding`, 백그라운드)해 성문과 대조, 매칭되면 슬롯 라벨을 즉시 이름으로 바꾼다. 실시간 경로 부하는 30초당 1회 추출이라 무시 가능. 실패해도 2-pass가 잡는다.

### 3.3 UI
- 라이브·상세 화면의 화자 칩: 성문으로 붙은 이름은 작은 파형 아이콘, Zoom 태그는 Zoom 아이콘, 슬롯은 아이콘 없음. 칩 클릭 → 이름 후보(성문 후보 2명, 캘린더 참석자) 선택 또는 직접 입력 → "이 목소리 기억하기" 체크(기본 켬).
- Settings > **Speakers** 카드: 등록된 사람 목록(이름, 회의 수, 마지막 회의), 이름 변경, 병합(같은 사람 두 항목 드래그), 삭제, "Forget all voices". 프라이버시 문구: 성문은 이 Mac에만 저장되며 오디오는 보관하지 않음.
- 회의 상세: "Speakers in this meeting" 요약 줄(누가 몇 분 말했는지) — 성문 결과의 부산물.

### 3.4 엣지·리스크
- 같은 이름 다른 사람(예: 두 명의 James): 이름 + 이메일(캘린더)로 person 키를 만들고 이름만 표시.
- 스피커폰 회의실(여러 명이 한 채널): 오프라인 다이어라이제이션이 분리하지만 성문 품질이 낮음 → 등록 최소 조건이 걸러줌.
- 모델 다운로드: 오프라인 다이어라이저 모델(pyannote 세그멘테이션 + wespeaker 임베딩, 수십 MB)이 추가된다. 첫 2-pass 때 다운로드, BUNDLE_MODELS에 포함 검토.
- 성공 지표: Zoom 외 플랫폼 회의에서 이름 붙은 행 비율, 잘못 붙은 이름 수정 횟수.

---

## 4. 액션아이템 · Tasks (D)

### 4.1 목표
"Next Steps" 텍스트를 구조화해 회의를 넘나드는 할 일 목록으로 만들고, 브리핑(B)과 레시피(C)의 데이터 원천으로 쓴다.

### 4.2 기술 분석
- 요약 프롬프트 끝에 기계 판독 블록을 요구한다:
  ```
  <!-- tasks
  [{"title":"…","owner":"Craig","due":"2026-09-05"|null,"quote":"…원문 한 줄…"}]
  -->
  ```
  `cleaned()`가 이 블록을 분리해 summary.md에는 남기지 않고 `tasks.json`으로 저장한다. 파싱 실패 시 태스크 없이 요약만 저장(요약 품질에 영향 없음).
- 담당자 정규화: 참석자·화자명·myName과 토큰 매칭, 없으면 원문 유지. "me/I/나"는 myName.
- 저장: 회의 폴더 `tasks.json` + 전역 인덱스 `~/Documents/LiveNote/tasks/index.json`(id, meetingURL, title, owner, due, status, createdAt, completedAt). 상태 변경은 인덱스에만 쓰고 회의 폴더 파일은 원본 보존.
- 2-pass 이후 자동 요약이 도는 현재 흐름에 그대로 얹힌다(추가 LLM 호출 없음).
- 브리핑(B)은 인덱스에서 owner 또는 meeting 참석자와 겹치는 미완료 항목을 읽는다.

### 4.3 UI
- 사이드바에 **Tasks** 메뉴(Chat 아래). 화면: 필터(Open / Done / Mine / All), 그룹(회의별 또는 담당자별), 행 = 체크박스, 제목, 담당자 칩, 기한, 출처 회의 링크(클릭 시 회의 상세로 이동해 인용 문장 하이라이트).
- 회의 상세: 요약 아래 "Action items" 카드(체크 가능, 여기서의 체크도 인덱스에 반영).
- Home Coming up: 오늘 회의 참석자와 연결된 미완료 태스크 수를 배지로.
- 수동 추가: Tasks 화면 상단 입력줄(회의 연결 없음).

### 4.4 엣지·리스크
- LLM이 태스크를 과잉 생성: 프롬프트에 "명시적 약속·요청만, 최대 8개" 제한.
- 기한 파싱: 상대 표현("next Wednesday")은 회의 날짜 기준 절대 날짜로 변환하도록 프롬프트에 회의 날짜 제공.
- 기존 회의 소급: "Extract tasks" 레시피로 과거 회의에 사후 적용 가능(C 재사용).

---

## 5. 전사 편집 · 찾아바꾸기 · 용어 학습 (F)

### 5.1 목표
고유명사·약어 오류를 사용자가 한 번 고치면 그 회의 전체에 반영되고, 다음 회의부터는 STT 단계에서 맞게 나오는 학습 루프.

### 5.2 기술 분석
- **인라인 편집**: 회의 상세 전사 행 더블클릭 → TextField. 저장 시 `rows[i].english` 갱신, md 재생성(persist), `edits.json`에 (rowID, before, after, at) 기록(되돌리기·감사용).
- **찾아바꾸기**: 상세 화면 ⌘F 패널. 대소문자 옵션, 단어 단위 옵션, 일치 수 미리보기, "Replace all". 요약 텍스트에도 같은 치환을 적용할지 체크(기본 켬, 요약 파일도 재저장).
- **용어 학습**: 치환이 "오인식 → 고유명사" 패턴(대상이 대문자 시작 또는 약어)이면 "Internal jargon에 'Harvinder' 추가할까요?" 토스트. 수락 시 설정 문자열에 추가되고 기존 편집거리 교정 풀에 즉시 반영. 
- **디코더 반영(후속)**: FluidAudio `SlidingWindowAsrManager`의 vocabulary rescoring(로그에서 "Vocabulary rescoring applied" 확인)을 라이브 경로에 붙일 때 jargon 목록을 그대로 공급한다. 이 항목은 라이브 경로 교체 작업(Nemotron/슬라이딩 윈도우 전환)과 묶어 별도 진행.
- 재요약 제안: 편집 건수가 5건 이상이면 "요약을 다시 생성할까요?" 배너.

### 5.3 UI
- 상세 화면 툴바: Find & Replace 아이콘, "Edited N" 배지(edits.json 기반), 되돌리기 메뉴.
- 편집된 행은 좌측에 연한 점 표시(원문 보기는 호버 툴팁).

### 5.4 엣지·리스크
- 2-pass 정제가 편집 후에 도는 일은 없다(정제는 stop 직후 1회). 정제 이후 편집만 허용되므로 충돌 없음.
- 한국어 번역 행은 편집 대상 아님(원문 편집 후 번역 재요청은 하지 않음, 필요 시 사용자가 번역도 직접 편집 가능하게 같은 UI 적용).

---

## 6. 소소한 개선 (G)

### 6.1 알림 팝업 분할 버튼 (Granola 캡처 반영)
현재 팝업: 제목·시간·카운트다운·[Join Zoom]·[닫기]. 개선:
- 주 버튼 **"Join Zoom & start LiveNote"** (플랫폼에 따라 Join Teams / Join Meet / Open meeting link). 클릭 = 링크 열기 + 기록 시작(현재 동작).
- 우측 **▾ 드롭다운**: "Join meeting only"(링크만, 기록 안 함), "Start LiveNote only"(기록만, 링크 안 열음: 이미 회의 중이거나 대면일 때), "Change notification settings"(Settings > Meetings로 이동).
- 부제 줄에 브리핑(B) Suggested agenda 첫 항목 표시(있을 때).
- 주 버튼 라벨은 링크 플랫폼 아이콘 포함(zoom/teams/meet 심볼은 SF Symbol 대체 아이콘 사용).

### 6.2 임시 회의 자동 제목
캘린더 제목이 없는 세션은 stop 후 요약과 함께 제목을 생성한다(요약 프롬프트에 "첫 줄 H1 = 제목" 규칙이 이미 있으므로 H1을 제목으로 채택). 폴더명·목록에 즉시 반영(폴더 rename은 저장 직후 1회만).

### 6.3 대면 회의 모드
Home의 Start 버튼을 분할: "Start" (온라인, 현재) / "Start in-person". 대면 모드는 시스템 오디오 탭을 열지 않고 마이크만 캡처하며, 마이크 채널을 them으로도 취급해 다이어라이저를 강제 기동한다(내 목소리 = 성문 매칭으로 me 식별, A 의존; A 이전에는 Speaker N 슬롯).

### 6.4 자동 시작 카운트다운
"Auto-start with meeting apps"가 켜져 있을 때 즉시 시작 대신 5초 카운트다운 오버레이(NSPanel, 우상단)에 [Cancel]. 캘린더 회의 시작 시각에도 같은 오버레이(옵션).

### 6.5 녹음 안 켠 발화 알림
회의 앱(Zoom/Teams/Meet 창)이 활성이고 마이크가 다른 앱에서 사용 중인데(CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`) LiveNote가 기록 중이 아니면 60초 후 1회 알림 "회의 중인 것 같은데 기록하지 않고 있어요 [Start]". 세션당 1회, 설정에서 끔.

### 6.6 내보내기
회의 상세 툴바 "Copy summary" (md), "Export…" (md/HTML 파일 저장). Weekly Update 결과에도 동일 버튼.

### 6.7 People / Accounts 뷰
Home 상단 세그먼트 "Meetings | People". People: 참석자별 카드(회의 수, 마지막 회의, 열린 태스크). 클릭 시 그 사람과의 회의 타임라인. 데이터는 session.json의 attendees(신규)와 화자명. 검색 프로젝트의 메타데이터 기반이 된다.

---

## 7. 데이터 모델 변경 총괄

| 위치 | 변경 |
|---|---|
| session.json (SavedMeeting) | `attendees: [{name, email?}]` 추가(캘린더에서 start 시 캡처), `briefRef`, `autoTitle` |
| 회의 폴더 | `tasks.json`, `edits.json`, `brief.md`(사본) 추가 |
| ~/Documents/LiveNote/ | `recipes/`, `recipes-output/`, `briefs/`, `tasks/index.json`, `voiceprints.json` |
| UserDefaults | briefsEnabled, briefTime, autoStartCountdown, recordingReminder, recipeDefaultModel |
| 로그 카테고리 | `brief`, `recipe`, `voice`, `tasks` |

모든 새 파일은 없으면 무시(하위 호환). session.json 디코딩은 optional 필드로 처리.

---

## 8. 리스크와 오픈 이슈

1. **성문 임계값**: FluidAudio 기본값이 우리 오디오(시스템 탭 16kHz 다운믹스)에 맞는지 실측 필요. Phase 시작 시 과거 2-pass WAV가 없으므로(삭제 정책) 새 회의 3~5개로 튜닝한다.
2. **오프라인 다이어라이저 시간**: 1시간 회의 기준 목표 60초 이내. 초과 시 them 채널만, 또는 발화 구간만 처리.
3. **브리핑 오탐**: 제목 유사도만으로 잘못된 과거 회의를 끌어오면 오히려 해롭다. 후보 회의 목록을 브리핑 하단에 항상 표시해 사용자가 검증할 수 있게 한다.
4. **레시피 프롬프트 유지보수**: 주간보고 규칙이 바뀌면 사용자가 레시피를 직접 편집해야 한다. Settings에서 편집 가능하게 하되, 내장 원본 복원 버튼을 둔다.
5. **UI 밀도**: Tasks 화면과 People 뷰가 추가되면 레일 항목이 5개가 된다. Tasks만 레일에 두고 People은 Home 세그먼트로 넣어 밀도를 억제한다.
