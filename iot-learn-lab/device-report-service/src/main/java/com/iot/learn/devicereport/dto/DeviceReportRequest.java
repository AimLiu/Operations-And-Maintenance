package com.iot.learn.devicereport.dto;

import jakarta.validation.constraints.NotNull;

import java.util.Map;

public class DeviceReportRequest {

    @NotNull
    private Map<String, Object> payload;

    public Map<String, Object> getPayload() { return payload; }
    public void setPayload(Map<String, Object> payload) { this.payload = payload; }
}