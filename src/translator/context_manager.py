"""
컨텍스트 캐리오버 관리자

번역 히스토리를 관리하고 프롬프트에 삽입할 컨텍스트를 생성합니다.
오디오 오버랩도 관리하여 단어 잘림을 방지합니다.

Based on: Deep Research - Section 5.2
"""

from collections import deque
from dataclasses import dataclass, field
from typing import Optional
import time


@dataclass
class TranslationTurn:
    """
    단일 번역 턴을 나타내는 데이터 클래스.

    v0.4.0 확장:
    - confidence: 번역 신뢰도
    - untranslated_suffix: 미번역 접미사 (다음 턴에 전달)
    """
    transcript: str          # 영어 원문
    translation: str         # 한국어 번역
    is_complete: bool        # 문장 완성 여부
    confidence: float = 0.5  # v0.4.0: 번역 신뢰도
    untranslated_suffix: str = ""  # v0.4.0: 미번역 접미사
    timestamp: float = field(default_factory=time.time)  # 생성 시간

    def to_dict(self) -> dict:
        """딕셔너리로 변환 (프롬프트 빌더 호환)."""
        result = {
            'en': self.transcript,
            'kr': self.translation,
            'complete': self.is_complete
        }
        # v0.4.0: 미번역 접미사가 있으면 포함
        if self.untranslated_suffix:
            result['suffix'] = self.untranslated_suffix
        return result


class ContextManager:
    """
    번역 컨텍스트 관리자.

    Features:
    - 최근 N개 턴의 번역 히스토리 유지 (기본 5턴)
    - 오디오 오버랩 관리 (단어 잘림 방지)
    - 불완전 문장 병합 지원
    - 통계 추적
    """

    # 기본 설정
    DEFAULT_MAX_TURNS = 5
    DEFAULT_OVERLAP_DURATION = 0.5  # 0.5초 오버랩

    def __init__(
        self,
        max_turns: int = DEFAULT_MAX_TURNS,
        overlap_duration: float = DEFAULT_OVERLAP_DURATION,
        sample_rate: int = 16000
    ):
        """
        컨텍스트 매니저 초기화.

        Args:
            max_turns: 유지할 최대 턴 수 (기본 5)
            overlap_duration: 오디오 오버랩 시간 (초, 기본 0.5)
            sample_rate: 오디오 샘플 레이트 (기본 16000)
        """
        self.max_turns = max_turns
        self.overlap_duration = overlap_duration
        self.sample_rate = sample_rate

        # 오버랩 바이트 크기 계산 (16-bit audio = 2 bytes per sample)
        self.overlap_bytes = int(sample_rate * overlap_duration * 2)

        # 번역 히스토리 (deque로 자동 크기 제한)
        self._history: deque[TranslationTurn] = deque(maxlen=max_turns)

        # 오디오 오버랩 버퍼 (다음 청크에 붙일 이전 청크 끝부분)
        self._audio_overlap: Optional[bytes] = None

        # 불완전 문장 버퍼 (연속 불완전 문장 병합용)
        self._pending_incomplete: Optional[TranslationTurn] = None

        # v0.4.0: 미번역 접미사 버퍼 (다음 턴에 붙일 suffix)
        self._pending_suffix: str = ""

        # 통계
        self._total_turns = 0
        self._incomplete_count = 0
        self._merged_count = 0

    def add_turn(
        self,
        transcript: str,
        translation: str,
        is_complete: bool,
        confidence: float = 0.5,
        untranslated_suffix: str = ""
    ) -> None:
        """
        새 번역 턴을 추가합니다.

        v0.4.0 확장:
        - confidence, untranslated_suffix 지원
        - 이전 턴의 suffix를 현재 턴에 자동 붙이기

        Args:
            transcript: 영어 원문
            translation: 한국어 번역
            is_complete: 문장 완성 여부
            confidence: 번역 신뢰도 (0.0-1.0)
            untranslated_suffix: 미번역 접미사
        """
        # v0.4.0: 이전 suffix가 있으면 transcript 앞에 붙임
        if self._pending_suffix:
            transcript = self._pending_suffix + " " + transcript
            print(f"[CONTEXT] Prepended pending suffix: '{self._pending_suffix}'")
            self._pending_suffix = ""

        # v0.4.0: 새 suffix가 있으면 저장
        if untranslated_suffix:
            self._pending_suffix = untranslated_suffix
            print(f"[CONTEXT] Saved pending suffix: '{untranslated_suffix}'")

        turn = TranslationTurn(
            transcript=transcript,
            translation=translation,
            is_complete=is_complete,
            confidence=confidence,
            untranslated_suffix=untranslated_suffix
        )

        self._total_turns += 1

        if not is_complete:
            self._incomplete_count += 1

            # 이전에 불완전 문장이 있으면 병합
            if self._pending_incomplete is not None:
                merged_turn = TranslationTurn(
                    transcript=self._pending_incomplete.transcript + " " + transcript,
                    translation=self._pending_incomplete.translation + " " + translation,
                    is_complete=False
                )
                self._pending_incomplete = merged_turn
                self._merged_count += 1
                print(f"[CONTEXT] Merged incomplete turns: {len(merged_turn.transcript)} chars")
            else:
                self._pending_incomplete = turn
        else:
            # 완전한 문장 도착
            if self._pending_incomplete is not None:
                # 이전 불완전 문장과 현재 문장 병합
                merged_turn = TranslationTurn(
                    transcript=self._pending_incomplete.transcript + " " + transcript,
                    translation=self._pending_incomplete.translation + " " + translation,
                    is_complete=True
                )
                self._history.append(merged_turn)
                self._pending_incomplete = None
                self._merged_count += 1
                print(f"[CONTEXT] Completed merged turn: {len(merged_turn.transcript)} chars")
            else:
                self._history.append(turn)
                print(f"[CONTEXT] Added complete turn: {len(transcript)} chars")

    def get_history(self) -> list[dict]:
        """
        프롬프트에 사용할 히스토리를 반환합니다.

        Returns:
            히스토리 딕셔너리 리스트 [{'en': ..., 'kr': ..., 'complete': ...}, ...]
        """
        result = [turn.to_dict() for turn in self._history]

        # 현재 pending 불완전 문장도 포함
        if self._pending_incomplete is not None:
            result.append(self._pending_incomplete.to_dict())

        return result

    def set_audio_overlap(self, audio_data: bytes) -> None:
        """
        다음 청크에 붙일 오디오 오버랩을 설정합니다.

        Args:
            audio_data: 현재 청크의 마지막 부분 (overlap_bytes 만큼)
        """
        if len(audio_data) >= self.overlap_bytes:
            self._audio_overlap = audio_data[-self.overlap_bytes:]
        else:
            self._audio_overlap = audio_data

        print(f"[CONTEXT] Set audio overlap: {len(self._audio_overlap)} bytes")

    def get_audio_with_overlap(self, current_audio: bytes) -> bytes:
        """
        오버랩이 붙은 오디오를 반환합니다.

        Args:
            current_audio: 현재 오디오 청크

        Returns:
            오버랩 + 현재 오디오 (오버랩이 없으면 현재만)
        """
        if self._audio_overlap is not None:
            result = self._audio_overlap + current_audio
            print(f"[CONTEXT] Applied overlap: {len(self._audio_overlap)} + {len(current_audio)} = {len(result)} bytes")
            return result
        return current_audio

    def clear_audio_overlap(self) -> None:
        """오디오 오버랩을 초기화합니다."""
        self._audio_overlap = None

    def get_last_turn(self) -> Optional[TranslationTurn]:
        """마지막 완료된 턴을 반환합니다."""
        if self._history:
            return self._history[-1]
        return None

    def get_pending_incomplete(self) -> Optional[TranslationTurn]:
        """현재 pending 중인 불완전 문장을 반환합니다."""
        return self._pending_incomplete

    def has_incomplete_pending(self) -> bool:
        """불완전 문장이 pending 중인지 확인합니다."""
        return self._pending_incomplete is not None

    def get_stats(self) -> dict:
        """통계를 반환합니다."""
        return {
            "total_turns": self._total_turns,
            "history_size": len(self._history),
            "incomplete_count": self._incomplete_count,
            "merged_count": self._merged_count,
            "has_pending": self._pending_incomplete is not None,
            "has_overlap": self._audio_overlap is not None,
            "overlap_bytes": len(self._audio_overlap) if self._audio_overlap else 0
        }

    def reset(self) -> None:
        """컨텍스트를 완전히 초기화합니다."""
        self._history.clear()
        self._audio_overlap = None
        self._pending_incomplete = None
        self._pending_suffix = ""  # v0.4.0
        self._total_turns = 0
        self._incomplete_count = 0
        self._merged_count = 0
        print("[CONTEXT] Reset complete")

    def __len__(self) -> int:
        """현재 히스토리 크기를 반환합니다."""
        return len(self._history)

    def __repr__(self) -> str:
        return (f"ContextManager(turns={len(self._history)}/{self.max_turns}, "
                f"pending={self._pending_incomplete is not None}, "
                f"overlap={self._audio_overlap is not None})")
