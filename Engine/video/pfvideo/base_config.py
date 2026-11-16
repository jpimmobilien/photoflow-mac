import inspect
from enum import Enum
from typing import Any


class BaseModelConfig:
    """Copied from pfvideo.base_config (MIT)."""

    @classmethod
    def from_dict(cls, params: dict[str, Any]) -> "BaseModelConfig":
        return cls(**{k: v for k, v in params.items() if k in inspect.signature(cls).parameters})

    def to_dict(self) -> dict[str, Any]:
        result = {}
        for k, v in self.__dict__.items():
            if v is not None:
                if isinstance(v, Enum):
                    result[k] = v.value
                elif hasattr(v, "to_dict"):
                    result[k] = v.to_dict()
                else:
                    result[k] = v
        return result
