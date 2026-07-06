package com.iot.learn.devicereport.controller;

import com.iot.learn.devicereport.dto.DeviceReportRequest;
import com.iot.learn.devicereport.dto.DeviceReportWithDispatchResponse;
import com.iot.learn.devicereport.service.DispatchOrchestrationService;
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
@RequestMapping("/api/v1/devices/{deviceId}/reports-with-dispatch")
public class DeviceReportDispatchController {

    private final DispatchOrchestrationService orchestration;
    private final Logger log = LoggerFactory.getLogger(DeviceReportDispatchController.class);

    public DeviceReportDispatchController(DispatchOrchestrationService orchestration) {
        this.orchestration = orchestration;
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public DeviceReportWithDispatchResponse postWithDispatch(
            @PathVariable String deviceId,
            @Valid @RequestBody DeviceReportRequest request) {
        log.info("DeviceReportDispatchController::postWithDispatch has been called, the device id is [{}]", deviceId);
        return orchestration.saveAndDispatch(deviceId, request);
    }
}