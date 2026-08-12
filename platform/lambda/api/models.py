"""
Data models for the T-POT Booking Platform.
"""

from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from enum import Enum
from typing import List, Optional
import uuid


class BookingStatus(str, Enum):
    PENDING = "pending"
    POLLING = "polling"
    LAUNCHING = "launching"
    DEPLOYING = "deploying"
    READY = "ready"
    TERMINATED = "terminated"
    FAILED = "failed"


@dataclass
class Booking:
    bookingId: str = field(default_factory=lambda: str(uuid.uuid4()))
    instanceType: str = ""
    deploymentPlan: str = ""
    status: str = BookingStatus.PENDING.value
    endpoint: str = ""
    whitelistIps: List[str] = field(default_factory=list)
    createdAt: str = field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat()
    )
    updatedAt: str = field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat()
    )
    instanceId: str = ""
    region: str = ""
    az: str = ""
    ssmCommandId: str = ""
    confirmOverride: bool = False

    def to_dict(self) -> dict:
        d = asdict(self)
        # Remove confirmOverride from stored data
        d.pop("confirmOverride", None)
        return d

    @classmethod
    def from_dict(cls, data: dict) -> "Booking":
        # Filter out unexpected keys
        valid_fields = {f.name for f in cls.__dataclass_fields__.values()}
        filtered = {k: v for k, v in data.items() if k in valid_fields}
        return cls(**filtered)


@dataclass
class DeploymentPlan:
    id: str = ""
    name: str = ""
    instanceType: str = ""
    composeFile: str = ""
    recipe: str = ""
    description: str = ""
    modelName: str = "deepseek-ai/DeepSeek-V4-Flash"

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class NotificationConfig:
    configId: str = "global"
    email: str = ""
    feishuWebhook: str = ""
    enabled: bool = True

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict) -> "NotificationConfig":
        valid_fields = {f.name for f in cls.__dataclass_fields__.values()}
        filtered = {k: v for k, v in data.items() if k in valid_fields}
        return cls(**filtered)
