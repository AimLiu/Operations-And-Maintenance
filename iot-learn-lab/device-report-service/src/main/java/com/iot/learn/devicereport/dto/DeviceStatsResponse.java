package com.iot.learn.devicereport.dto;

import java.time.Instant;

public record DeviceStatsResponse(
        String deviceId,
        long reportCount,
        Instant lastReportedAt,
        String source
) {
    public DeviceStatsResponse withSource(String newSource) {
        return new DeviceStatsResponse(deviceId, reportCount, lastReportedAt, newSource);
    }
}
