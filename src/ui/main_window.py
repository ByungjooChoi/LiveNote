"""
메인 윈도우 - VAD 기반 실시간 번역 UI

새로운 아키텍처 (Deep Research V2):
- Silero VAD로 지능적 오디오 세그멘테이션
- streamGenerateContent API로 빠른 응답
- 컨텍스트 캐리오버로 연속성 유지

Based on: Deep Research V2 - Section 6
"""

import asyncio
import time
from PyQt6.QtWidgets import (QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
                             QTextEdit, QPushButton, QLabel, QStatusBar, QSlider,
                             QComboBox, QProgressBar, QCheckBox, QSpinBox)
from PyQt6.QtCore import Qt, QTimer
from qasync import asyncSlot

from src.ui.settings_dialog import SettingsDialog
from src.ui.audio_selector import AudioSelector
from src.audio.capture import AudioCapture
from src.translator.gemini_client import GeminiClient, TranslationPipeline
from src.audio.vad_segmenter import SileroVADSegmenter, SimpleTimeBasedSegmenter
from src.config.secure_storage import SecureStorage
from src.utils.file_writer import FileWriter
from src.config.settings_manager import settings
from src.audio.playback import AudioPlayback
from src.audio.device_manager import DeviceManager


class MainWindow(QMainWindow):
    """
    LiveNote 메인 윈도우.

    Features:
    - VAD 기반 지능적 세그멘테이션
    - 실시간 번역 표시
    - 오디오 레벨 모니터링
    - 설정 관리
    """

    def __init__(self):
        super().__init__()
        self.setWindowTitle("LiveNote - AI Translator (V2)")
        self.resize(900, 700)
        self.setStyleSheet("background-color: #1E1E1E; color: #FFFFFF;")

        # 상태
        self.is_running = False
        self.audio_capture = None
        self.gemini_client = None
        self.pipeline = None
        self.vad_segmenter = None
        self.file_writer = FileWriter()
        self.process_task = None
        self.vad_task = None
        self.ui_update_task = None
        self.audio_playback = AudioPlayback()

        # 타이머
        self.last_audio_time = None
        self.silence_check_timer = QTimer()
        self.silence_check_timer.timeout.connect(self._check_silence)

        # 통계
        self.stats_timer = QTimer()
        self.stats_timer.timeout.connect(self._update_stats_display)

        self.init_ui()

        # API Key 확인
        if not SecureStorage.get_api_key():
            self.open_settings()

    def init_ui(self):
        """UI 초기화."""
        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        layout = QVBoxLayout(central_widget)

        # 1. Input Source & Level Meter
        input_layout = QHBoxLayout()
        self.audio_selector = AudioSelector()
        input_layout.addWidget(self.audio_selector)

        # Level Meter
        self.level_meter = QProgressBar()
        self.level_meter.setRange(0, 100)
        self.level_meter.setValue(0)
        self.level_meter.setTextVisible(False)
        self.level_meter.setFixedHeight(10)
        self.level_meter.setStyleSheet("""
            QProgressBar { background-color: #2D2D2D; border: none; border-radius: 5px; }
            QProgressBar::chunk { background-color: #00FF00; border-radius: 5px; }
        """)
        input_layout.addWidget(self.level_meter)

        # Preview Button
        self.preview_btn = QPushButton("🔊 Preview")
        self.preview_btn.setFixedWidth(80)
        self.preview_btn.setStyleSheet("background-color: #3E3E3E; border-radius: 4px;")
        self.preview_btn.clicked.connect(self._preview_audio_source)
        input_layout.addWidget(self.preview_btn)

        layout.addLayout(input_layout)

        # 2. VAD Settings Row
        vad_layout = QHBoxLayout()

        # VAD Enable Checkbox
        self.vad_enabled = QCheckBox("VAD Segmentation")
        self.vad_enabled.setChecked(True)
        self.vad_enabled.setStyleSheet("color: #AAAAAA;")
        self.vad_enabled.setToolTip("음성 감지 기반 지능적 세그멘테이션 (권장)")
        vad_layout.addWidget(self.vad_enabled)

        # Buffer Duration (VAD off일 때만 사용)
        buffer_label = QLabel("Fixed Buffer:")
        buffer_label.setStyleSheet("color: #AAAAAA;")
        vad_layout.addWidget(buffer_label)

        self.buffer_duration = QSpinBox()
        self.buffer_duration.setRange(3, 10)
        self.buffer_duration.setValue(5)
        self.buffer_duration.setSuffix("s")
        self.buffer_duration.setStyleSheet("background-color: #3E3E3E; color: white;")
        self.buffer_duration.setToolTip("VAD 비활성화 시 고정 버퍼 길이")
        vad_layout.addWidget(self.buffer_duration)

        vad_layout.addStretch()

        # Stats Display
        self.stats_label = QLabel("Segments: 0 | Latency: --")
        self.stats_label.setStyleSheet("color: #888888; font-size: 11px;")
        vad_layout.addWidget(self.stats_label)

        layout.addLayout(vad_layout)

        # 3. Output Device & Volume
        output_layout = QHBoxLayout()

        output_label = QLabel("Audio Output:")
        output_label.setStyleSheet("color: #AAAAAA;")
        output_layout.addWidget(output_label)

        self.output_selector = QComboBox()
        self.output_selector.setStyleSheet("background-color: #3E3E3E; color: white; padding: 5px;")
        self.output_selector.currentIndexChanged.connect(self._on_output_device_changed)
        output_layout.addWidget(self.output_selector, 1)

        volume_label = QLabel("Volume:")
        volume_label.setStyleSheet("color: #AAAAAA;")
        output_layout.addWidget(volume_label)

        self.volume_slider = QSlider(Qt.Orientation.Horizontal)
        self.volume_slider.setRange(0, 100)
        self.volume_slider.setValue(50)
        self.volume_slider.setFixedWidth(100)
        self.volume_slider.valueChanged.connect(self._on_volume_changed)
        output_layout.addWidget(self.volume_slider)

        self.volume_value_label = QLabel("50%")
        self.volume_value_label.setFixedWidth(40)
        output_layout.addWidget(self.volume_value_label)

        self.mute_btn = QPushButton("🔊")
        self.mute_btn.setFixedWidth(30)
        self.mute_btn.setStyleSheet("background-color: #3E3E3E; border-radius: 4px;")
        self.mute_btn.clicked.connect(self._toggle_mute)
        output_layout.addWidget(self.mute_btn)

        layout.addLayout(output_layout)

        # 4. Status Indicator
        self.status_indicator = QLabel("⏸️ Ready")
        self.status_indicator.setStyleSheet("color: #AAAAAA; font-size: 14px; font-weight: bold; margin: 5px 0;")
        layout.addWidget(self.status_indicator)

        # 5. Control Buttons
        btn_layout = QHBoxLayout()

        self.start_btn = QPushButton("Start Translation")
        self.start_btn.setStyleSheet("""
            QPushButton { background-color: #007ACC; color: white; padding: 10px 20px; border-radius: 4px; border: none; font-weight: bold; font-size: 14px; }
            QPushButton:hover { background-color: #0098FF; }
            QPushButton:checked { background-color: #FF5555; }
        """)
        self.start_btn.setCheckable(True)
        self.start_btn.clicked.connect(self.toggle_translation)
        btn_layout.addWidget(self.start_btn, 1)

        self.settings_btn = QPushButton("⚙️")
        self.settings_btn.setFixedSize(40, 40)
        self.settings_btn.setStyleSheet("background-color: #3E3E3E; border-radius: 4px; border: none; font-size: 18px;")
        self.settings_btn.clicked.connect(self.open_settings)
        btn_layout.addWidget(self.settings_btn)

        layout.addLayout(btn_layout)

        # Populate output devices
        self._populate_output_devices()

        # 6. Text Display Area
        self.text_area = QTextEdit()
        self.text_area.setReadOnly(True)
        self.text_area.setStyleSheet("""
            QTextEdit {
                background-color: #2D2D2D;
                color: #FFFFFF;
                border: 1px solid #3E3E3E;
                font-size: 16px;
                padding: 10px;
                font-family: 'Noto Sans KR', 'Malgun Gothic', sans-serif;
            }
        """)
        self.text_area.setPlaceholderText("Translation will appear here...\n\n번역 결과가 여기에 표시됩니다...")
        layout.addWidget(self.text_area)

        # 7. Status Bar
        self.status_bar = QStatusBar()
        self.status_bar.setStyleSheet("background-color: #007ACC; color: white;")
        self.setStatusBar(self.status_bar)
        self.status_bar.showMessage("Ready - V2 (VAD + streamGenerateContent)")

    def _populate_output_devices(self):
        """출력 장치 목록 채우기."""
        self.output_selector.clear()
        devices = DeviceManager.get_output_devices()
        for device in devices:
            self.output_selector.addItem(device['name'], device['id'])

    def _on_output_device_changed(self, index):
        """출력 장치 변경 핸들러."""
        device_id = self.output_selector.currentData()
        if device_id is not None:
            self.audio_playback.set_device(device_id)

    def _on_volume_changed(self, value):
        """볼륨 변경 핸들러."""
        self.volume_value_label.setText(f"{value}%")
        self.audio_playback.set_volume(value / 100.0)

    def _toggle_mute(self):
        """음소거 토글."""
        muted = self.audio_playback.toggle_mute()
        self.mute_btn.setText("🔇" if muted else "🔊")

    def _update_status(self, status_code, message=None):
        """상태 표시 업데이트."""
        status_map = {
            "ready": "⏸️ Ready",
            "capturing": "🎤 Capturing",
            "vad_active": "🎯 VAD Active",
            "sending": "📤 Sending",
            "receiving": "📥 Receiving",
            "translating": "✅ Translating",
            "no_audio": "⚠️ No Audio (Check Mic)",
            "error": "❌ Error"
        }

        text = status_map.get(status_code, status_code)
        if message:
            text += f" - {message}"

        self.status_indicator.setText(text)

        colors = {
            "ready": "#AAAAAA",
            "capturing": "#00AAFF",
            "vad_active": "#00FFAA",
            "sending": "#FFAA00",
            "receiving": "#00FFAA",
            "translating": "#00FF00",
            "no_audio": "#FFAA00",
            "error": "#FF5555"
        }
        self.status_indicator.setStyleSheet(
            f"color: {colors.get(status_code, '#FFFFFF')}; "
            f"font-size: 14px; font-weight: bold; margin: 5px 0;"
        )

    def _update_stats_display(self):
        """통계 표시 업데이트."""
        if self.gemini_client:
            stats = self.gemini_client.get_stats()
            avg_latency = stats.get('avg_latency', 0)
            req_count = stats.get('request_count', 0)

            vad_info = ""
            if self.vad_segmenter:
                vad_stats = self.vad_segmenter.get_stats()
                vad_info = f" | VAD: {vad_stats.get('state', 'N/A')}"

            self.stats_label.setText(
                f"Segments: {req_count} | Latency: {avg_latency:.2f}s{vad_info}"
            )

    def _on_audio_level_update(self, level):
        """오디오 레벨 업데이트 콜백."""
        self.level_meter.setValue(int(level))
        if level > 5:
            self.last_audio_time = time.time()
            if "No Audio" in self.status_indicator.text():
                self._update_status("capturing")

    def _check_silence(self):
        """무음 체크."""
        if self.last_audio_time and self.is_running:
            silence_duration = time.time() - self.last_audio_time
            if silence_duration > 5:
                self._update_status("no_audio")

    @asyncSlot()
    async def _preview_audio_source(self):
        """오디오 소스 미리보기."""
        device_id = self.audio_selector.get_selected_device_id()
        if device_id is None:
            return

        self.preview_btn.setEnabled(False)
        self.preview_btn.setText("Testing...")

        max_level = 0

        def on_level(level):
            nonlocal max_level
            max_level = max(max_level, level)
            self.level_meter.setValue(int(level))

        try:
            temp_capture = AudioCapture(device_id=device_id, on_level_update=on_level)
            await temp_capture.start()

            await asyncio.sleep(2)

            temp_capture.stop()

            if max_level > 10:
                self.preview_btn.setText("✅ OK")
            else:
                self.preview_btn.setText("❌ Silent")
        except Exception as e:
            self.preview_btn.setText("❌ Error")
            print(f"Preview error: {e}")

        await asyncio.sleep(1)
        self.preview_btn.setText("🔊 Preview")
        self.preview_btn.setEnabled(True)
        self.level_meter.setValue(0)

    def open_settings(self):
        """설정 다이얼로그 열기."""
        dialog = SettingsDialog(self)
        if dialog.exec():
            # 설정 저장 후 클라이언트 재초기화
            self.status_bar.showMessage("Settings saved.")

    @asyncSlot()
    async def toggle_translation(self):
        """번역 시작/중지 토글."""
        if self.start_btn.isChecked():
            await self.start_translation()
        else:
            await self.stop_translation()

    async def start_translation(self):
        """번역 시작."""
        device_id = self.audio_selector.get_selected_device_id()
        if device_id is None:
            self.status_bar.showMessage("No audio device selected.")
            self.start_btn.setChecked(False)
            return

        self.start_btn.setText("Stop Translation")
        self.start_btn.setStyleSheet(
            "background-color: #FF5555; color: white; padding: 10px 20px; "
            "border-radius: 4px; border: none; font-weight: bold; font-size: 14px;"
        )
        self.text_area.clear()
        self.status_bar.showMessage("Connecting...")
        self._update_status("ready", "Initializing...")

        try:
            # 1. Gemini 클라이언트 초기화
            self.gemini_client = GeminiClient()

            # 콜백 설정
            self.gemini_client.on_transcription = self._on_transcription
            self.gemini_client.on_translation = self._on_translation
            self.gemini_client.on_error = self._on_error

            await self.gemini_client.connect()

            # 2. 오디오 캡처 시작
            self.audio_capture = AudioCapture(
                device_id=device_id,
                on_level_update=self._on_audio_level_update
            )
            await self.audio_capture.start()

            # 3. 오디오 재생 시작
            await self.audio_playback.start()

            # 4. 파일 저장 시작
            if settings.get("output", "auto_save", True):
                self.file_writer.start_session()

            # 5. VAD 세그멘터 또는 시간 기반 세그멘터 초기화
            use_vad = self.vad_enabled.isChecked()

            if use_vad:
                # Silero VAD 사용 시도
                from src.audio.vad_segmenter import ONNX_AVAILABLE, get_default_model_path

                model_path = get_default_model_path()
                if ONNX_AVAILABLE and model_path:
                    self.vad_segmenter = SileroVADSegmenter(
                        model_path=model_path,
                        on_segment_ready=None
                    )
                    self._update_status("vad_active", "VAD initialized")
                    print(f"[MAIN] Using Silero VAD: {model_path}")
                else:
                    # VAD 사용 불가 → 폴백
                    if not ONNX_AVAILABLE:
                        print("[MAIN] WARNING: onnxruntime not installed, falling back to time-based segmentation")
                    elif not model_path:
                        print("[MAIN] WARNING: VAD model not found, falling back to time-based segmentation")
                    use_vad = False

            if not use_vad:
                # 고정 시간 세그멘터
                chunk_duration = self.buffer_duration.value()
                self.vad_segmenter = SimpleTimeBasedSegmenter(
                    chunk_duration=chunk_duration,
                    on_segment_ready=None
                )
                self._update_status("capturing", f"{chunk_duration}s buffers")
                print(f"[MAIN] Using time-based segmentation: {chunk_duration}s")

            # 6. 파이프라인 시작
            self.pipeline = TranslationPipeline(self.gemini_client)
            await self.pipeline.start()

            # 7. is_running을 먼저 True로 설정 (태스크가 루프를 돌 수 있도록)
            self.is_running = True

            # 8. 태스크 시작
            self.vad_task = asyncio.create_task(self._process_audio_with_vad())
            self.ui_update_task = asyncio.create_task(self._update_ui_from_results())
            print("[MAIN] VAD and UI update tasks started")

            self.status_bar.showMessage("Translating...")
            self._update_status("capturing")

            self.last_audio_time = time.time()
            self.silence_check_timer.start(1000)
            self.stats_timer.start(500)

        except Exception as e:
            print(f"Start Error: {e}")
            import traceback
            traceback.print_exc()
            self.status_bar.showMessage(f"Error: {e}")
            self._update_status("error", str(e))
            await self.stop_translation()

    async def stop_translation(self):
        """번역 중지."""
        self.is_running = False
        self.status_bar.showMessage("Stopping...")
        self.silence_check_timer.stop()
        self.stats_timer.stop()

        # 태스크 취소
        for task in [self.vad_task, self.ui_update_task]:
            if task:
                task.cancel()
                try:
                    await task
                except asyncio.CancelledError:
                    pass
        self.vad_task = None
        self.ui_update_task = None

        # 파이프라인 중지
        if self.pipeline:
            await self.pipeline.stop()
            self.pipeline = None

        # 오디오 캡처 중지
        if self.audio_capture:
            self.audio_capture.stop()
            self.audio_capture = None

        # 오디오 재생 중지
        await self.audio_playback.stop()

        # 파일 저장 종료
        self.file_writer.close_session()

        # Gemini 클라이언트 종료
        if self.gemini_client:
            self.gemini_client.disconnect()
            self.gemini_client = None

        # VAD 세그멘터 초기화
        if self.vad_segmenter:
            self.vad_segmenter.reset()
            self.vad_segmenter = None

        self.start_btn.setText("Start Translation")
        self.start_btn.setChecked(False)
        self.start_btn.setStyleSheet("""
            QPushButton { background-color: #007ACC; color: white; padding: 10px 20px; border-radius: 4px; border: none; font-weight: bold; font-size: 14px; }
            QPushButton:hover { background-color: #0098FF; }
        """)
        self.status_bar.showMessage("Stopped")
        self._update_status("ready")
        self.level_meter.setValue(0)

    async def _process_audio_with_vad(self):
        """VAD를 사용하여 오디오를 처리합니다."""
        import numpy as np

        FRAME_SIZE = 512  # 32ms @ 16kHz
        BYTES_PER_FRAME = FRAME_SIZE * 2  # 16-bit = 2 bytes per sample

        frame_buffer = bytearray()
        frames_processed = 0
        segments_sent = 0

        print(f"[VAD_TASK] Started, is_running={self.is_running}, segmenter={type(self.vad_segmenter).__name__}")
        print(f"[VAD_TASK] Queue object: {self.audio_capture.queue}")

        items_received = 0

        try:
            while self.is_running:
                try:
                    # 오디오 큐에서 데이터 가져오기
                    item = await asyncio.wait_for(
                        self.audio_capture.queue.get(),
                        timeout=0.1
                    )
                    items_received += 1
                    if items_received <= 5 or items_received % 100 == 0:
                        print(f"[VAD_TASK] Received item #{items_received}, type={type(item)}")
                except asyncio.TimeoutError:
                    continue
                except Exception as e:
                    print(f"[VAD_TASK] Queue error: {e}")
                    import traceback
                    traceback.print_exc()
                    continue

                # 오디오 데이터 추출
                try:
                    audio_data = item[0] if isinstance(item, tuple) else item

                    # float32 → int16 bytes 변환
                    if hasattr(audio_data, 'tobytes'):
                        if getattr(audio_data, 'dtype', None) == np.float32:
                            # numpy 연산을 안전하게 수행
                            audio_data = audio_data.copy()  # 원본 보호
                            audio_data = np.clip(audio_data, -1.0, 1.0)
                            audio_data = (audio_data * 32767).astype(np.int16)
                        audio_data = audio_data.tobytes()

                    if items_received <= 5:
                        print(f"[VAD_TASK] Converted audio: {len(audio_data)} bytes")

                    # 프레임 버퍼에 추가
                    frame_buffer.extend(audio_data)
                except Exception as e:
                    print(f"[VAD_TASK] Audio conversion error: {e}")
                    import traceback
                    traceback.print_exc()
                    continue

                # 완전한 프레임 처리
                while len(frame_buffer) >= BYTES_PER_FRAME:
                    frame = bytes(frame_buffer[:BYTES_PER_FRAME])
                    frame_buffer = frame_buffer[BYTES_PER_FRAME:]
                    frames_processed += 1

                    # VAD 또는 시간 기반 세그멘터에 프레임 전달
                    if isinstance(self.vad_segmenter, SileroVADSegmenter):
                        segment = self.vad_segmenter.process_frame(frame)
                    else:
                        # SimpleTimeBasedSegmenter
                        segment = self.vad_segmenter.add_audio(frame)

                    # 세그먼트가 준비되면 파이프라인에 추가
                    if segment:
                        segments_sent += 1
                        print(f"[VAD_TASK] Segment #{segments_sent}: {len(segment)} bytes after {frames_processed} frames")
                        self._update_status("sending", f"{len(segment)} bytes")
                        await self.pipeline.add_segment(segment)

                # 주기적 상태 로그
                if frames_processed > 0 and frames_processed % 500 == 0:
                    print(f"[VAD_TASK] Progress: {frames_processed} frames, {segments_sent} segments, buffer={len(frame_buffer)}")

        except asyncio.CancelledError:
            print("[VAD_TASK] Cancelled")
            # 남은 버퍼 플러시
            if self.vad_segmenter:
                final_segment = self.vad_segmenter.force_flush()
                if final_segment and self.pipeline:
                    await self.pipeline.add_segment(final_segment)
            raise
        except Exception as e:
            print(f"[VAD_TASK] ERROR: {e}")
            import traceback
            traceback.print_exc()

    async def _update_ui_from_results(self):
        """파이프라인 결과를 UI에 반영합니다."""
        try:
            while self.is_running:
                result = await self.pipeline.get_result(timeout=0.5)

                if result is None:
                    continue

                transcript = result.get('transcript', '')
                translation = result.get('translation', '')
                is_complete = result.get('is_complete', True)

                if transcript or translation:
                    self._update_status("translating")

                    # 텍스트 영역에 추가
                    self.text_area.moveCursor(
                        self.text_area.textCursor().MoveOperation.End
                    )

                    # 완전한 문장인지에 따라 다르게 표시
                    suffix = "" if is_complete else "..."

                    if transcript:
                        self.text_area.insertPlainText(f"\n[EN] {transcript}{suffix}")
                        self.file_writer.write_line(f"[EN] {transcript}")

                    if translation:
                        self.text_area.insertPlainText(f"\n[KO] {translation}{suffix}")
                        self.file_writer.write_line(f"[KO] {translation}")

                    # 스크롤 맨 아래로
                    self.text_area.moveCursor(
                        self.text_area.textCursor().MoveOperation.End
                    )

        except asyncio.CancelledError:
            raise

    def _on_transcription(self, text: str):
        """영어 원문 콜백."""
        # 실시간 업데이트용 (현재는 _update_ui_from_results에서 처리)
        pass

    def _on_translation(self, text: str):
        """한국어 번역 콜백."""
        # 실시간 업데이트용 (현재는 _update_ui_from_results에서 처리)
        pass

    def _on_error(self, error: str):
        """에러 콜백."""
        self._update_status("error", error)
        self.status_bar.showMessage(f"Error: {error}")
