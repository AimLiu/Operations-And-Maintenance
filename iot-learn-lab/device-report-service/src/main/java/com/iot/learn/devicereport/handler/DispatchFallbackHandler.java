package com.iot.learn.devicereport.handler;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.iot.learn.devicereport.client.CommandDispatchClient;
import com.iot.learn.devicereport.dto.DispatchAckRequest;
import com.iot.learn.devicereport.dto.DispatchAckResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

import java.util.UUID;

@Component
public class DispatchFallbackHandler implements CommandDispatchClient {

    private static final Logger log = LoggerFactory.getLogger(DispatchFallbackHandler.class);
    private static final String CACHE_KEY_PREFIX = "dispatch:ack:";

    private final StringRedisTemplate redisTemplate;
    private final ObjectMapper objectMapper;

    public DispatchFallbackHandler(StringRedisTemplate redisTemplate, ObjectMapper objectMapper) {
        this.redisTemplate = redisTemplate;
        this.objectMapper = objectMapper;
    }

    @Override
    public DispatchAckResponse ack(DispatchAckRequest request) {
        log.info("DispatchFallbackHandler 触发, deviceId={}", request.getDeviceId());
        String cacheKey = CACHE_KEY_PREFIX + request.getDeviceId();
        String cached = redisTemplate.opsForValue().get(cacheKey);
        if (cached != null && !cached.isBlank()) {
            try {
                DispatchAckResponse fromCache = objectMapper.readValue(cached, DispatchAckResponse.class);
                log.info("Redis 缓存命中, deviceId={}, ackId={}", request.getDeviceId(), fromCache.ackId());
                return new DispatchAckResponse(
                        fromCache.ackId(),
                        fromCache.deviceId(),
                        "redis-cache",
                        true);
            } catch (JsonProcessingException e) {
                log.warn("Redis 缓存反序列化失败, key={}, 回退静态降级", cacheKey, e);
            }
        }
        log.info("Redis 无缓存, 使用静态 fallback, deviceId={}", request.getDeviceId());
        return new DispatchAckResponse(
                "fallback-" + UUID.randomUUID(),
                request.getDeviceId(),
                "DEGRADED",
                true);
    }
}
