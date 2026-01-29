#!/usr/bin/env python3
"""
Silero VAD ONNX 모델 다운로드 스크립트

사용법:
    python scripts/download_vad_model.py

또는 수동 다운로드:
    1. 브라우저에서 아래 URL 접속
    2. models/ 폴더에 silero_vad.onnx로 저장

URL: https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx
"""

import os
import sys
from pathlib import Path

# 프로젝트 루트 찾기
PROJECT_ROOT = Path(__file__).parent.parent
MODELS_DIR = PROJECT_ROOT / "models"
MODEL_PATH = MODELS_DIR / "silero_vad.onnx"

# Silero VAD v4 ONNX 모델 URL
MODEL_URL = "https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx"

# 대체 URL (huggingface)
ALT_MODEL_URL = "https://huggingface.co/onnx-community/silero-vad/resolve/main/silero_vad.onnx"


def download_with_requests():
    """requests 라이브러리로 다운로드."""
    try:
        import requests
        print(f"Downloading from: {MODEL_URL}")

        response = requests.get(MODEL_URL, stream=True, timeout=30)
        response.raise_for_status()

        total_size = int(response.headers.get('content-length', 0))
        downloaded = 0

        with open(MODEL_PATH, 'wb') as f:
            for chunk in response.iter_content(chunk_size=8192):
                f.write(chunk)
                downloaded += len(chunk)
                if total_size:
                    pct = downloaded * 100 // total_size
                    print(f"\rProgress: {pct}% ({downloaded}/{total_size} bytes)", end='')

        print(f"\n✅ Downloaded to: {MODEL_PATH}")
        return True

    except Exception as e:
        print(f"❌ requests download failed: {e}")
        return False


def download_with_urllib():
    """urllib로 다운로드."""
    try:
        from urllib.request import urlretrieve
        print(f"Downloading from: {MODEL_URL}")

        def progress_hook(count, block_size, total_size):
            if total_size > 0:
                pct = count * block_size * 100 // total_size
                print(f"\rProgress: {pct}%", end='')

        urlretrieve(MODEL_URL, MODEL_PATH, progress_hook)
        print(f"\n✅ Downloaded to: {MODEL_PATH}")
        return True

    except Exception as e:
        print(f"❌ urllib download failed: {e}")
        return False


def download_with_torch_hub():
    """torch.hub로 다운로드 (PyTorch 필요)."""
    try:
        import torch
        print("Downloading via torch.hub...")

        model, utils = torch.hub.load(
            repo_or_dir='snakers4/silero-vad',
            model='silero_vad',
            force_reload=False,
            onnx=True
        )

        # ONNX 모델 경로 찾기
        hub_dir = torch.hub.get_dir()
        onnx_path = Path(hub_dir) / "snakers4_silero-vad_master" / "src" / "silero_vad" / "data" / "silero_vad.onnx"

        if onnx_path.exists():
            import shutil
            shutil.copy(onnx_path, MODEL_PATH)
            print(f"✅ Copied to: {MODEL_PATH}")
            return True
        else:
            print(f"❌ ONNX file not found at: {onnx_path}")
            return False

    except ImportError:
        print("❌ PyTorch not installed")
        return False
    except Exception as e:
        print(f"❌ torch.hub download failed: {e}")
        return False


def verify_model():
    """모델 파일 검증."""
    if not MODEL_PATH.exists():
        return False

    size = MODEL_PATH.stat().st_size
    print(f"Model size: {size:,} bytes")

    # 대략적인 크기 검증 (Silero VAD v4는 약 2.3MB)
    if size < 1_000_000:
        print("⚠️ Warning: Model file seems too small")
        return False

    if size > 10_000_000:
        print("⚠️ Warning: Model file seems too large")
        return False

    # 정상 범위 (2-3MB)
    print("✅ Model file size looks correct")
    return True


def main():
    print("=" * 50)
    print("Silero VAD ONNX Model Downloader")
    print("=" * 50)

    # models 디렉토리 생성
    MODELS_DIR.mkdir(parents=True, exist_ok=True)

    # 이미 존재하는지 확인
    if MODEL_PATH.exists():
        print(f"Model already exists: {MODEL_PATH}")
        if verify_model():
            print("✅ Model is valid")
            return 0
        else:
            print("Removing invalid model and re-downloading...")
            MODEL_PATH.unlink()

    # 다운로드 시도 (여러 방법)
    methods = [
        ("requests", download_with_requests),
        ("urllib", download_with_urllib),
        ("torch.hub", download_with_torch_hub),
    ]

    for name, method in methods:
        print(f"\n--- Trying {name} ---")
        if method():
            if verify_model():
                print(f"\n✅ Successfully downloaded using {name}")
                return 0

    # 모든 방법 실패
    print("\n" + "=" * 50)
    print("❌ Automatic download failed")
    print("=" * 50)
    print("\n수동 다운로드 방법:")
    print(f"1. 브라우저에서 다음 URL 접속:")
    print(f"   {MODEL_URL}")
    print(f"2. 다운로드한 파일을 다음 경로에 저장:")
    print(f"   {MODEL_PATH}")
    print("\n또는 pip로 silero-vad 패키지 설치:")
    print("   pip install silero-vad")

    return 1


if __name__ == "__main__":
    sys.exit(main())
