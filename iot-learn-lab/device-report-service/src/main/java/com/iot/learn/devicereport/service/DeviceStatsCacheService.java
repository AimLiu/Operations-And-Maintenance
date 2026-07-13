package com.iot.learn.devicereport.service;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.iot.learn.devicereport.dto.DeviceStatsResponse;
import com.iot.learn.devicereport.repository.DeviceStatsAggregation;
import com.iot.learn.devicereport.repository.DeviceReportRepository;
import io.micrometer.core.instrument.Counter;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Service;

import java.time.Duration;
import java.time.Instant;
import java.util.concurrent.ThreadLocalRandom;

@Service
public class DeviceStatsCacheService {

    private static final Logger log = LoggerFactory.getLogger(DeviceStatsCacheService.class);
    private static final String KEY_PREFIX = "device:stats:";
    private static final String LOCK_PREFIX = "device:stats:lock:";
    private static final String NULL_PLACEHOLDER = "__NULL__";

    private final StringRedisTemplate redisTemplate;
    private final ObjectMapper objectMapper;
    private final DeviceReportRepository repository;
    private final Counter cacheHitCounter;
    private final Counter cacheMissCounter;
    private final Counter cacheNullHitCounter;

    private final int statsTtlSeconds;
    private final int statsTtlJitterSeconds;
    private final boolean nullCacheEnabled;
    private final int nullCacheTtlSeconds;
    private final boolean breakdownLockEnabled;
    private final long lockWaitMillis;

    public DeviceStatsCacheService(
            StringRedisTemplate redisTemplate,
            ObjectMapper objectMapper,
            DeviceReportRepository repository,
            // 击中缓存数
            @Qualifier("cacheHitCounter") Counter cacheHitCounter,
            // 缓存穿透数
            @Qualifier("cacheMissCounter") Counter cacheMissCounter,
            // 击中缓存空值数
            @Qualifier("cacheNullHitCounter") Counter cacheNullHitCounter,
            @Value("${app.cache.stats-ttl-seconds:60}") int statsTtlSeconds,
            @Value("${app.cache.stats-ttl-jitter-seconds:30}") int statsTtlJitterSeconds,
            @Value("${app.cache.null-cache-enabled:true}") boolean nullCacheEnabled,
            @Value("${app.cache.null-cache-ttl-seconds:30}") int nullCacheTtlSeconds,
            @Value("${app.cache.breakdown-lock-enabled:true}") boolean breakdownLockEnabled,
            @Value("${app.cache.lock-wait-millis:3000}") long lockWaitMillis) {
        this.redisTemplate = redisTemplate;
        this.objectMapper = objectMapper;
        this.repository = repository;
        this.cacheHitCounter = cacheHitCounter;
        this.cacheMissCounter = cacheMissCounter;
        this.cacheNullHitCounter = cacheNullHitCounter;
        this.statsTtlSeconds = statsTtlSeconds;
        this.statsTtlJitterSeconds = statsTtlJitterSeconds;
        this.nullCacheEnabled = nullCacheEnabled;
        this.nullCacheTtlSeconds = nullCacheTtlSeconds;
        this.breakdownLockEnabled = breakdownLockEnabled;
        this.lockWaitMillis = lockWaitMillis;
    }

    /**
     * Cache-Aside 读取设备统计，含穿透（空值缓存）、击穿（Redis 互斥锁）、雪崩（TTL 随机抖动）。
     */
    public DeviceStatsResponse getStats(String deviceId) {
        String cacheKey = cacheKey(deviceId);
        String cached = redisTemplate.opsForValue().get(cacheKey);

        if (cached != null) {
            // 击中空值
            if (NULL_PLACEHOLDER.equals(cached)) {
                cacheNullHitCounter.increment();
                return emptyResponse(deviceId, "redis-null");
            }
            // 击中缓存
            cacheHitCounter.increment();
            return deserialize(cached).withSource("redis");
        }

        // 未击中缓存
        cacheMissCounter.increment();
        // 允许缓存穿透
        if (breakdownLockEnabled) {
            return loadWithBreakdownLock(deviceId);
        }
        return loadFromDbAndCache(deviceId);
    }

    /**
     * 同一时刻，只允许 1 个线程查库并回填缓存，其余线程等待或读已回填的缓存
     * @param deviceId 设备Id
     * @return
     */
    private DeviceStatsResponse loadWithBreakdownLock(String deviceId) {
        String lockKey = LOCK_PREFIX + deviceId;
        Boolean locked = redisTemplate.opsForValue()
                .setIfAbsent(lockKey, "1", Duration.ofSeconds(10));

        if (Boolean.TRUE.equals(locked)) {
            try {
                DeviceStatsResponse doubleCheck = readCacheAfterWait(deviceId, 0);
                if (doubleCheck != null) {
                    return doubleCheck;
                }
                return loadFromDbAndCache(deviceId);
            } finally {
                redisTemplate.delete(lockKey);
            }
        }

        DeviceStatsResponse waited = readCacheAfterWait(deviceId, lockWaitMillis);
        if (waited != null) {
            return waited;
        }
        log.warn("Breakdown lock wait timeout, fallback query DB, deviceId={}", deviceId);
        return loadFromDbAndCache(deviceId);
    }

    private DeviceStatsResponse readCacheAfterWait(String deviceId, long waitMillis) {
        long deadline = System.currentTimeMillis() + waitMillis;
        do {
            String cached = redisTemplate.opsForValue().get(cacheKey(deviceId));
            if (cached != null) {
                if (NULL_PLACEHOLDER.equals(cached)) {
                    cacheNullHitCounter.increment();
                    return emptyResponse(deviceId, "redis-null");
                }
                cacheHitCounter.increment();
                return deserialize(cached).withSource("redis");
            }
            if (waitMillis <= 0) {
                break;
            }
            try {
                Thread.sleep(50);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
        } while (System.currentTimeMillis() < deadline);
        return null;
    }

    private DeviceStatsResponse loadFromDbAndCache(String deviceId) {
        // 查询出当前设备的状态更新数量，以及最后更新时间
        DeviceStatsAggregation aggregation = repository.aggregateByDeviceId(deviceId);
        long count = aggregation.getReportCount();

        // 数据库中没有此设备数据
        if (count == 0) {
            if (nullCacheEnabled) {
                redisTemplate.opsForValue().set(
                        cacheKey(deviceId),
                        NULL_PLACEHOLDER,
                        Duration.ofSeconds(nullCacheTtlSeconds));
            }
            return emptyResponse(deviceId, "db");
        }

        DeviceStatsResponse stats = new DeviceStatsResponse(
                deviceId,
                count,
                aggregation.getLastReportedAt(),
                "db");
        // 存入空值缓存
        redisTemplate.opsForValue().set(
                cacheKey(deviceId),
                serialize(stats),
                Duration.ofSeconds(ttlWithJitter()));
        return stats;
    }

    private int ttlWithJitter() {
        if (statsTtlJitterSeconds <= 0) {
            return statsTtlSeconds;
        }
        return statsTtlSeconds + ThreadLocalRandom.current().nextInt(statsTtlJitterSeconds + 1);
    }

    private DeviceStatsResponse emptyResponse(String deviceId, String source) {
        return new DeviceStatsResponse(deviceId, 0, null, source);
    }

    private String cacheKey(String deviceId) {
        return KEY_PREFIX + deviceId;
    }

    private String serialize(DeviceStatsResponse stats) {
        try {
            return objectMapper.writeValueAsString(new CachedStats(stats.deviceId(), stats.reportCount(), stats.lastReportedAt()));
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Failed to serialize device stats cache", e);
        }
    }

    private DeviceStatsResponse deserialize(String json) {
        try {
            CachedStats cached = objectMapper.readValue(json, CachedStats.class);
            return new DeviceStatsResponse(cached.deviceId(), cached.reportCount(), cached.lastReportedAt(), "redis");
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Failed to deserialize device stats cache", e);
        }
    }

    private record CachedStats(String deviceId, long reportCount, Instant lastReportedAt) {}
}
