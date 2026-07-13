package com.iot.learn.event;

import java.time.Instant;
import java.util.Map;

public record DeviceReportEvent(
        String eventId,
        String deviceId,
        Map<String, Object> payload,
        Instant reportedAt
) {}