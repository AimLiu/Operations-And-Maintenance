package com.iot.learn.devicereport.dto;

public record DispatchAckResponse(
        String ackId,
        String deviceId,
        String result,
        boolean success) {
}

