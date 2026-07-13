package com.iot.learn.devicereport.service;

import com.iot.learn.devicereport.config.CanaryBugConfig;
import com.iot.learn.devicereport.dto.DeviceReportRequest;
import com.iot.learn.devicereport.dto.DeviceReportResponse;
import com.iot.learn.devicereport.entity.DeviceReport;
import com.iot.learn.devicereport.repository.DeviceReportRepository;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.Map;

@Service
public class DeviceReportService {

    private final DeviceReportRepository repository;
    private final CanaryBugConfig canaryBugConfig;

    public DeviceReportService(DeviceReportRepository repository, CanaryBugConfig canaryBugConfig) {
        this.repository = repository;
        this.canaryBugConfig = canaryBugConfig;
    }

    @Transactional
    public DeviceReportResponse saveReport(String deviceId, DeviceReportRequest request) {
        canaryBugConfig.maybeFail();
        DeviceReport report = new DeviceReport();
        report.setDeviceId(deviceId);
        report.setPayload(request.getPayload());
        report.setReportedAt(Instant.now());

        DeviceReport saved = repository.save(report);
        return new DeviceReportResponse(saved.getId(), saved.getDeviceId(), saved.getReportedAt());
    }

    @Transactional
    public void simulateSlowQuery(double seconds) {
        repository.sleepSeconds(seconds);
    }
}
