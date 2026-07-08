package com.iot.learn.devicereport.service;

import com.alibaba.csp.sentinel.annotation.SentinelResource;
import com.alibaba.csp.sentinel.slots.block.BlockException;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.iot.learn.devicereport.client.CommandDispatchClient;
import com.iot.learn.devicereport.dto.DeviceReportRequest;
import com.iot.learn.devicereport.dto.DeviceReportResponse;
import com.iot.learn.devicereport.dto.DeviceReportWithDispatchResponse;
import com.iot.learn.devicereport.dto.DispatchAckRequest;
import com.iot.learn.devicereport.dto.DispatchAckResponse;
import jakarta.validation.Valid;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.web.server.ResponseStatusException;

import java.time.Duration;
import java.util.UUID;

@Service
public class DispatchOrchestrationService {

    private static final String CACHE_KEY_PREFIX = "dispatch:ack:";
    private static final Duration CACHE_TTL = Duration.ofMinutes(60);

    private final Logger log = LoggerFactory.getLogger(DispatchOrchestrationService.class);
    private final ObjectMapper objectMapper;
    private final DeviceReportService deviceReportService;
    private final CommandDispatchClient client;
    private final StringRedisTemplate redisTemplate;

    public DispatchOrchestrationService(
            ObjectMapper objectMapper,
            DeviceReportService deviceReportService,
            CommandDispatchClient client,
            StringRedisTemplate redisTemplate) {
        this.objectMapper = objectMapper;
        this.deviceReportService = deviceReportService;
        this.client = client;
        this.redisTemplate = redisTemplate;
    }

    @SentinelResource(
            value = "dispatchAck",
            blockHandler = "dispatchBlockHandler",
            fallback = "dispatchFallback")
    public DeviceReportWithDispatchResponse saveAndDispatch(String deviceId, @Valid DeviceReportRequest request) {
        try {
            DeviceReportResponse reportResponse = deviceReportService.saveReport(deviceId, request);
            DispatchAckRequest ackRequest = new DispatchAckRequest(deviceId, UUID.randomUUID().toString());
            DispatchAckResponse ackResponse = client.ack(ackRequest);
            redisTemplate.opsForValue().set(
                    CACHE_KEY_PREFIX + deviceId,
                    objectMapper.writeValueAsString(ackResponse),
                    CACHE_TTL);
            return new DeviceReportWithDispatchResponse(reportResponse, ackResponse);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Failed to serialize dispatch ack for Redis cache", e);
        }
    }

    /** 流控 block（R2）：Sentinel flow 规则触发，返回 HTTP 429 */
    public DeviceReportWithDispatchResponse dispatchBlockHandler(
            String deviceId, DeviceReportRequest request, BlockException ex) {
        log.info("Sentinel flow 规则触发，返回 HTTP 429");
        throw new ResponseStatusException(HttpStatus.TOO_MANY_REQUESTS, "Sentinel flow block: dispatchAck");
    }

    /** 熔断/业务异常降级（R5）：资源执行失败时的兜底 */
    public DeviceReportWithDispatchResponse dispatchFallback(
            String deviceId, DeviceReportRequest request, Throwable t) {
        log.info("dispatchFallback 规则触发，返回 HTTP 201");
        DeviceReportResponse reportResponse = deviceReportService.saveReport(deviceId, request);
        DispatchAckResponse ackResponse = new DispatchAckResponse(
                "fallback-" + UUID.randomUUID(),
                deviceId,
                "DEGRADED",
                true);
        return new DeviceReportWithDispatchResponse(reportResponse, ackResponse);
    }
}
