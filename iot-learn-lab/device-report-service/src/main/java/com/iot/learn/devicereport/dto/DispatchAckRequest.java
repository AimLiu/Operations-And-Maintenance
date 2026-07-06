package com.iot.learn.devicereport.dto;

public class DispatchAckRequest {
    private String deviceId;
    private String reportId;

    public DispatchAckRequest(String deviceId, String reportId) {
        this.deviceId = deviceId;
        this.reportId = reportId;
    }

    public String getDeviceId() {
        return deviceId;
    }

    public void setDeviceId(String deviceId) {
        this.deviceId = deviceId;
    }

    public String getReportId() {
        return reportId;
    }

    public void setReportId(String reportId) {
        this.reportId = reportId;
    }
}
