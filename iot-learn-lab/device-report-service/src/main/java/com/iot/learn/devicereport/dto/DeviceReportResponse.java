package com.iot.learn.devicereport.dto;

import com.fasterxml.jackson.annotation.JsonFormat;

import java.time.Instant;

public class DeviceReportResponse {
    private Long id;
    private String deviceId;

    @JsonFormat(shape = JsonFormat.Shape.STRING, pattern = "yyyy-MM-dd'T'HH:mm:ss.SSSXXX", timezone = "Asia/Shanghai")
    private Instant reportedAt;

    public DeviceReportResponse(Long id, String deviceId, Instant reportedAt) {
        this.id = id;
        this.deviceId = deviceId;
        this.reportedAt = reportedAt;
    }

    public Long getId() { return id; }
    public String getDeviceId() { return deviceId; }
    public Instant getReportedAt() { return reportedAt; }
}