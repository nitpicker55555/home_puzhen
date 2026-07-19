from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Any

from homeassistant.components.cover import CoverEntity, CoverDeviceClass, CoverEntityFeature
from homeassistant.const import STATE_OPEN, STATE_CLOSED
from homeassistant.helpers.restore_state import RestoreEntity

from .coordinator import TantronDeviceEntity

if TYPE_CHECKING:
    from typing import Optional
    from homeassistant.core import HomeAssistant
    from homeassistant.config_entries import ConfigEntry
    from homeassistant.helpers.entity_platform import AddEntitiesCallback
    from .coordinator import TantronCoordinator, TantronDevice
    from .typing import EntryRuntimeData

_LOGGER = logging.getLogger(__name__)


async def async_setup_entry(hass: HomeAssistant,
                            entry: ConfigEntry[EntryRuntimeData],
                            async_add_entities: AddEntitiesCallback):
    coordinator = entry.runtime_data['coordinator']
    entities = []
    for device_id, device in coordinator.devices.items():
        if device['type'] == 'curtain':
            entities.append(TantronCurtain(coordinator, device))
    async_add_entities(entities)


class TantronCurtain(TantronDeviceEntity, CoverEntity, RestoreEntity):

    _attr_device_class = CoverDeviceClass.CURTAIN
    _attr_supported_features = CoverEntityFeature.OPEN | CoverEntityFeature.CLOSE | CoverEntityFeature.STOP
    # Many Tantron curtains only expose control addresses, no status-feedback address,
    # so the cloud never reports their open/closed state. Treat the state as "assumed":
    # HA remembers the last commanded position locally instead of relying on the cloud.
    _attr_assumed_state = True

    def __init__(self, coordinator: TantronCoordinator, device: TantronDevice):
        super().__init__(coordinator, device)
        self._optimistic_closed: Optional[bool] = None

    @property
    def available(self) -> bool:
        # Unlike other devices, a curtain without status feedback reports no values,
        # yet it is still controllable. Keep it available while the cloud is reachable.
        return self.coordinator.last_update_success and self.coordinator.get_device(self.device_id) is not None

    @property
    def is_closed(self) -> Optional[bool]:
        # prefer the real cloud-reported state when the device actually provides one
        # (this household's curtains use switch '0' = closed, '1' = open)
        if self.function_state is not None and 'switch' in self.function_state:
            return self.function_state['switch'] == '0'
        # otherwise fall back to the locally maintained (assumed) state
        return self._optimistic_closed

    async def async_added_to_hass(self) -> None:
        await super().async_added_to_hass()
        # restore the last known state across restarts
        last_state = await self.async_get_last_state()
        if last_state is not None and last_state.state in (STATE_OPEN, STATE_CLOSED):
            self._optimistic_closed = last_state.state == STATE_CLOSED
        elif self._optimistic_closed is None:
            # no history yet: assume closed (the curtain's usual resting position)
            self._optimistic_closed = True

    async def async_close_cover(self, **kwargs: Any) -> None:
        await self._send_values({
            'switch': '0'
        })
        self._optimistic_closed = True
        self.async_write_ha_state()

    async def async_open_cover(self, **kwargs: Any) -> None:
        await self._send_values({
            'switch': '1'
        })
        self._optimistic_closed = False
        self.async_write_ha_state()

    async def async_stop_cover(self, **kwargs: Any) -> None:
        await self._send_values({
            'stop': '1'
        })
