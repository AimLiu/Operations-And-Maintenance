package com.iot.learn.devicereport.controller;

import com.iot.learn.devicereport.service.DeviceReportService;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

@RestController
@RequestMapping("/api/v1/debug")
public class DebugController {

    private final DeviceReportService service;

    public DebugController(DeviceReportService service) {
        this.service = service;
    }

    @PostMapping("/error")
    public void triggerError() {
        throw new ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR, "Simulated error for observability lab");
    }

    @PostMapping("/slow-query")
    public void triggerSlowQuery(@RequestParam(defaultValue = "3") double seconds) {
        if (seconds < 0 || seconds > 30) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "seconds must be 0-30");
        }
        service.simulateSlowQuery(seconds);
    }
}
