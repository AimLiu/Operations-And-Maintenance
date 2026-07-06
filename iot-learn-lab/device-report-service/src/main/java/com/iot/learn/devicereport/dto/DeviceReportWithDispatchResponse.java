package com.iot.learn.devicereport.dto;

public record DeviceReportWithDispatchResponse(
        DeviceReportResponse reportResponse,
        DispatchAckResponse ackResponse
) {
}
