package com.iot.learn.devicereport.controller;

import com.iot.learn.devicereport.dto.DeviceReportRequest;
import com.iot.learn.devicereport.dto.DeviceReportResponse;
import com.iot.learn.devicereport.service.DeviceReportService;
import jakarta.validation.Valid;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;


@RestController
@RequestMapping("/api/v1/devices/{deviceId}/reports")
public class DeviceReportController {
    final Logger log = LoggerFactory.getLogger(DeviceReportController.class);

    private final DeviceReportService service;

    public DeviceReportController(DeviceReportService service) {
        this.service = service;
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public DeviceReportResponse postReport(
            @PathVariable String deviceId,
            @Valid @RequestBody DeviceReportRequest request) {
        log.info("DeviceReportController postReport has called");
        return service.saveReport(deviceId, request);
    }
}
