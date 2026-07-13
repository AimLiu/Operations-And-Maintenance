package com.iot.learn.devicereport.controller;

import com.iot.learn.devicereport.dto.DeviceStatsResponse;
import com.iot.learn.devicereport.service.DeviceStatsCacheService;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/v1/devices/{deviceId}/stats")
public class DeviceStatsController {

    private final DeviceStatsCacheService cacheService;

    public DeviceStatsController(DeviceStatsCacheService cacheService) {
        this.cacheService = cacheService;
    }

    @GetMapping
    public DeviceStatsResponse getStats(@PathVariable String deviceId) {
        return cacheService.getStats(deviceId);
    }
}
