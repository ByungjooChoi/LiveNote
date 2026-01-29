"""
시스템 프롬프트 및 JSON 스키마 정의

동시통역사 페르소나를 모방하는 프롬프트와
구조화된 JSON 출력 스키마를 정의합니다.

Based on: Deep Research - Section 5.3
"""

from typing import Optional

# =============================================================================
# 시스템 프롬프트 (동시통역사 페르소나)
# =============================================================================

SYSTEM_PROMPT = """You are an expert simultaneous interpreter translating English audio to Korean in real-time.

CORE RULES:

1. **Latency Priority:** Translate concisely. Do not add explanations, commentary, or additional context beyond what was spoken.

2. **Incomplete Sentences:**
   - If the audio cuts off mid-sentence, DO NOT guess the ending.
   - Use Korean connecting endings (Ghost Suffixes) to indicate continuation:
     - '~하고' (and, listing)
     - '~인데' (but, contrast, background info)
     - '~해서' (so, because, reason)
     - '~며' (while, and, simultaneous)
     - '~는데' (but, however, setting context)
   - Example: "I went to the store and..." → "저는 가게에 갔고..." (NOT "저는 가게에 갔습니다.")
   - Example: "The problem is that..." → "문제는..." (NOT "문제는 ~입니다.")

3. **Context Awareness:**
   - Use the provided previous transcripts to maintain context
   - Resolve pronouns (he, she, it, they) based on prior context
   - Maintain consistency in terminology across turns

4. **Accuracy:**
   - Transcribe the English exactly as heard
   - Do not omit words or add words not spoken
   - Preserve the speaker's tone and intent

5. **Natural Korean:**
   - Use natural, spoken Korean (not overly formal written style)
   - Match formality level to the source speech
   - Avoid unnatural literal translations

OUTPUT FORMAT:
Return a JSON object with exactly these three fields - no additional fields or commentary."""


# =============================================================================
# JSON 응답 스키마
# =============================================================================

RESPONSE_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "transcript": {
            "type": "STRING",
            "description": "The English speech recognized from the audio, transcribed exactly as heard"
        },
        "translation": {
            "type": "STRING",
            "description": "The Korean translation of the transcript"
        },
        "is_complete": {
            "type": "BOOLEAN",
            "description": "True if the sentence is grammatically complete and ends naturally. False if it was cut off mid-sentence and uses a connecting ending (ghost suffix)."
        }
    },
    "required": ["transcript", "translation", "is_complete"]
}


# =============================================================================
# 컨텍스트 프롬프트 빌더
# =============================================================================

def build_context_prompt(context_history: list[dict], max_turns: int = 5) -> str:
    """
    컨텍스트 히스토리를 프롬프트 형식으로 변환합니다.

    Args:
        context_history: [{'en': '...', 'kr': '...', 'complete': bool}, ...]
        max_turns: 포함할 최대 턴 수 (기본 5)

    Returns:
        프롬프트에 삽입할 컨텍스트 문자열

    Example output:
        Turn 1 ✓:
          EN: Hello, how are you?
          KR: 안녕하세요, 어떻게 지내세요?
        Turn 2 ...:
          EN: I went to the store and
          KR: 저는 가게에 갔고
    """
    if not context_history:
        return "[No previous context]"

    recent = context_history[-max_turns:]
    lines = []

    for i, item in enumerate(recent, 1):
        status = "✓" if item.get('complete', True) else "..."
        en_text = item.get('en', '')
        kr_text = item.get('kr', '')

        lines.append(f"Turn {i} {status}:")
        lines.append(f"  EN: {en_text}")
        lines.append(f"  KR: {kr_text}")

    return "\n".join(lines)


def build_full_prompt(context_history: list[dict], max_turns: int = 5) -> str:
    """
    전체 프롬프트를 구성합니다 (컨텍스트 + 지시사항).

    Args:
        context_history: 컨텍스트 히스토리
        max_turns: 포함할 최대 턴 수

    Returns:
        API에 전송할 전체 프롬프트
    """
    context_text = build_context_prompt(context_history, max_turns)

    return f"""[Previous Context]
{context_text}

[Instruction]
Translate the attached audio chunk. Follow all CORE RULES in the system instruction.
- If the sentence is complete, use appropriate sentence-ending forms
- If cut off mid-sentence, use connecting endings (ghost suffixes)
- Output ONLY the JSON object, no additional text"""


# =============================================================================
# 간단한 프롬프트 (컨텍스트 없이)
# =============================================================================

SIMPLE_PROMPT = """Translate the attached English audio to Korean.
Output a JSON object with: transcript (English), translation (Korean), is_complete (boolean).
If the sentence is cut off, use Korean connecting endings like ~하고, ~인데, ~해서."""
