"""
V2 컴포넌트 유닛 테스트

새로운 아키텍처의 각 컴포넌트를 테스트합니다.
"""

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest
import asyncio


class TestWavUtils:
    """WAV 헤더 유틸리티 테스트."""

    def test_add_wav_header_basic(self):
        """기본 WAV 헤더 추가 테스트."""
        from src.audio.wav_utils import add_wav_header

        # 1초 분량의 더미 PCM 데이터 (16kHz, 16-bit, mono)
        pcm_data = bytes(16000 * 2)  # 32000 bytes

        wav_data = add_wav_header(pcm_data)

        # 헤더 크기 확인
        assert len(wav_data) == len(pcm_data) + 44

        # RIFF 헤더 확인
        assert wav_data[:4] == b'RIFF'
        assert wav_data[8:12] == b'WAVE'
        assert wav_data[12:16] == b'fmt '
        assert wav_data[36:40] == b'data'

    def test_get_wav_duration(self):
        """WAV 재생 시간 계산 테스트."""
        from src.audio.wav_utils import add_wav_header, get_wav_duration

        # 2초 분량의 PCM 데이터
        pcm_data = bytes(16000 * 2 * 2)  # 64000 bytes = 2 seconds

        wav_data = add_wav_header(pcm_data)
        duration = get_wav_duration(wav_data)

        assert abs(duration - 2.0) < 0.01

    def test_get_pcm_duration(self):
        """PCM 재생 시간 계산 테스트."""
        from src.audio.wav_utils import get_pcm_duration

        # 5초 분량의 PCM 데이터
        pcm_data = bytes(16000 * 2 * 5)

        duration = get_pcm_duration(pcm_data)
        assert abs(duration - 5.0) < 0.01


class TestPrompts:
    """프롬프트 및 스키마 테스트."""

    def test_system_prompt_exists(self):
        """시스템 프롬프트 존재 확인."""
        from src.translator.prompts import SYSTEM_PROMPT

        assert SYSTEM_PROMPT
        assert "simultaneous interpreter" in SYSTEM_PROMPT.lower()
        assert "korean" in SYSTEM_PROMPT.lower()

    def test_response_schema_structure(self):
        """응답 스키마 구조 확인."""
        from src.translator.prompts import RESPONSE_SCHEMA

        assert RESPONSE_SCHEMA["type"] == "OBJECT"
        assert "transcript" in RESPONSE_SCHEMA["properties"]
        assert "translation" in RESPONSE_SCHEMA["properties"]
        assert "is_complete" in RESPONSE_SCHEMA["properties"]

    def test_build_context_prompt_empty(self):
        """빈 컨텍스트 프롬프트 테스트."""
        from src.translator.prompts import build_context_prompt

        result = build_context_prompt([])
        assert "[No previous context]" in result

    def test_build_context_prompt_with_history(self):
        """히스토리가 있는 컨텍스트 프롬프트 테스트."""
        from src.translator.prompts import build_context_prompt

        history = [
            {"en": "Hello", "kr": "안녕하세요", "complete": True},
            {"en": "How are you", "kr": "어떻게 지내세요", "complete": False}
        ]

        result = build_context_prompt(history)
        assert "Turn 1" in result
        assert "Turn 2" in result
        assert "Hello" in result
        assert "안녕하세요" in result


class TestContextManager:
    """컨텍스트 매니저 테스트."""

    def test_add_complete_turn(self):
        """완전한 턴 추가 테스트."""
        from src.translator.context_manager import ContextManager

        cm = ContextManager(max_turns=5)
        cm.add_turn("Hello", "안녕하세요", is_complete=True)

        history = cm.get_history()
        assert len(history) == 1
        assert history[0]["en"] == "Hello"
        assert history[0]["kr"] == "안녕하세요"
        assert history[0]["complete"] is True

    def test_add_incomplete_turns_merge(self):
        """불완전한 턴 병합 테스트."""
        from src.translator.context_manager import ContextManager

        cm = ContextManager(max_turns=5)
        cm.add_turn("I went to", "저는 가게에", is_complete=False)
        cm.add_turn("the store", "갔습니다", is_complete=True)

        # 병합된 결과 확인
        history = cm.get_history()
        assert len(history) == 1
        assert "I went to" in history[0]["en"]
        assert "the store" in history[0]["en"]

    def test_audio_overlap(self):
        """오디오 오버랩 테스트."""
        from src.translator.context_manager import ContextManager

        cm = ContextManager(overlap_duration=0.5, sample_rate=16000)

        # 1초 분량의 오디오
        audio_data = bytes(16000 * 2)
        cm.set_audio_overlap(audio_data)

        # 새 오디오에 오버랩 적용
        new_audio = bytes(16000 * 2)
        result = cm.get_audio_with_overlap(new_audio)

        # 오버랩이 적용되어 더 길어야 함
        assert len(result) > len(new_audio)

    def test_max_turns_limit(self):
        """최대 턴 수 제한 테스트."""
        from src.translator.context_manager import ContextManager

        cm = ContextManager(max_turns=3)

        for i in range(5):
            cm.add_turn(f"Turn {i}", f"턴 {i}", is_complete=True)

        history = cm.get_history()
        assert len(history) == 3


class TestVADSegmenter:
    """VAD 세그멘터 테스트."""

    def test_simple_segmenter_basic(self):
        """단순 시간 기반 세그멘터 테스트."""
        from src.audio.vad_segmenter import SimpleTimeBasedSegmenter

        segments = []
        segmenter = SimpleTimeBasedSegmenter(
            chunk_duration=1.0,
            on_segment_ready=lambda s: segments.append(s)
        )

        # 1초 분량의 오디오 추가 (32ms 단위로)
        frame_size = 512 * 2  # 512 samples * 2 bytes
        total_bytes = 16000 * 2  # 1 second

        for i in range(0, total_bytes, frame_size):
            chunk = bytes(min(frame_size, total_bytes - i))
            result = segmenter.add_audio(chunk)

        # 시간이 지나면 세그먼트가 생성되어야 함
        # (테스트 환경에서는 시간 기반이므로 바로 flush)
        final = segmenter.force_flush()
        if final:
            segments.append(final)

        assert len(segments) >= 1

    def test_vad_state_machine_initial(self):
        """VAD 상태 머신 초기 상태 테스트."""
        from src.audio.vad_segmenter import SileroVADSegmenter, VADState

        segmenter = SileroVADSegmenter(model_path=None)
        assert segmenter._state == VADState.IDLE

    def test_vad_stats(self):
        """VAD 통계 테스트."""
        from src.audio.vad_segmenter import SileroVADSegmenter

        segmenter = SileroVADSegmenter(model_path=None)
        stats = segmenter.get_stats()

        assert "state" in stats
        assert "total_frames" in stats
        assert "segments_created" in stats


class TestGeminiClient:
    """Gemini 클라이언트 테스트 (API 키 없이)."""

    def test_parse_translation_response_valid(self):
        """유효한 번역 응답 파싱 테스트."""
        from src.translator.gemini_client import parse_translation_response

        response = '{"transcript": "Hello", "translation": "안녕하세요", "is_complete": true}'
        result = parse_translation_response(response)

        assert result is not None
        assert result["transcript"] == "Hello"
        assert result["translation"] == "안녕하세요"
        assert result["is_complete"] is True

    def test_parse_translation_response_invalid(self):
        """유효하지 않은 응답 파싱 테스트."""
        from src.translator.gemini_client import parse_translation_response

        # 잘못된 JSON
        result = parse_translation_response("not json")
        assert result is None

        # 필수 필드 누락
        result = parse_translation_response('{"transcript": "Hello"}')
        assert result is None


class TestTranslationPipeline:
    """번역 파이프라인 테스트."""

    @pytest.mark.asyncio
    async def test_pipeline_queue_operations(self):
        """파이프라인 큐 작업 테스트."""
        from src.translator.gemini_client import TranslationPipeline

        # Mock 클라이언트
        class MockClient:
            is_connected = True
            async def translate_audio(self, data):
                return {"transcript": "test", "translation": "테스트", "is_complete": True}

        pipeline = TranslationPipeline(MockClient())

        # 세그먼트 추가 (시작 전)
        await pipeline.add_segment(b"test_audio")
        # 시작 전이므로 큐에 추가되지 않아야 함

        # 시작
        await pipeline.start()
        assert pipeline._running is True

        # 중지
        await pipeline.stop()
        assert pipeline._running is False


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
