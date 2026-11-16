"""PhotoFlow local video engine.

Runs Wan (Apache 2.0) video diffusion models through Hugging Face diffusers on PyTorch
(Metal/MPS on Apple Silicon, CPU elsewhere). Started by PhotoFlow as a separate process and
driven over JSON lines (see worker.py). Nothing here touches the network: models are loaded
from local folders that PhotoFlow downloaded and verified, and HF_HUB_OFFLINE is forced.
"""

__version__ = "1.0.0"
