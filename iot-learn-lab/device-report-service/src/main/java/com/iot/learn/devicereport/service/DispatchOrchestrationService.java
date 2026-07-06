package com.iot.learn.devicereport.service;

import com.alibaba.csp.sentinel.annotation.SentinelResource;
import com.iot.learn.devicereport.client.CommandDispatchClient;
import com.iot.learn.devicereport.dto.DeviceReportRequest;
import com.iot.learn.devicereport.dto.DeviceReportResponse;
import com.iot.learn.devicereport.dto.DeviceReportWithDispatchResponse;
import com.iot.learn.devicereport.dto.DispatchAckRequest;
import com.iot.learn.devicereport.dto.DispatchAckResponse;
import jakarta.validation.Valid;
import org.springframework.stereotype.Service;

import java.util.UUID;

@Service
public class DispatchOrchestrationService {

    private final DeviceReportService deviceReportService;
    private final CommandDispatchClient client;

    public DispatchOrchestrationService(DeviceReportService deviceReportService, CommandDispatchClient client) {
        this.deviceReportService = deviceReportService;
        this.client = client;
    }

    @SentinelResource(value = "dispatchAck", fallback = "dispatchFallback")
    public DeviceReportWithDispatchResponse saveAndDispatch(String deviceId, @Valid DeviceReportRequest request) {
        DeviceReportResponse reportResponse = deviceReportService.saveReport(deviceId, request);
        DispatchAckRequest ackRequest = new DispatchAckRequest(deviceId, UUID.randomUUID().toString());
        DispatchAckResponse ackResponse = client.ack(ackRequest);
        return new DeviceReportWithDispatchResponse(reportResponse, ackResponse);
    }
}
