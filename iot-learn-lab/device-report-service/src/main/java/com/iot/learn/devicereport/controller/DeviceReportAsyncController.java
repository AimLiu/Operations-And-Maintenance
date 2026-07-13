package com.iot.learn.devicereport.controller;

import com.iot.learn.devicereport.dto.DeviceReportEvent;
import com.iot.learn.devicereport.dto.DeviceReportRequest;
import com.iot.learn.devicereport.producer.DeviceReportProducer;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;

@RestController
@RequestMapping("/api/v1/devices/{deviceId}/reports-async")
public class DeviceReportAsyncController {

    private final DeviceReportProducer producer;

    public DeviceReportAsyncController(DeviceReportProducer producer) {
        this.producer = producer;
    }

    @PostMapping
    @ResponseStatus(HttpStatus.ACCEPTED)
    public Map<String, String> postReportAsync(
            @PathVariable String deviceId,
            @Valid @RequestBody DeviceReportRequest request) {
        String eventId = UUID.randomUUID().toString();
        DeviceReportEvent event = new DeviceReportEvent(
                eventId,
                deviceId,
                request.getPayload(),
                Instant.now());
        producer.send(event);
        return Map.of("eventId", eventId, "status", "ACCEPTED");
    }
}
