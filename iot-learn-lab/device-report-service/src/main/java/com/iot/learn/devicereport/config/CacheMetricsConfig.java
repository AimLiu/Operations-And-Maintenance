package com.iot.learn.devicereport.config;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class CacheMetricsConfig {

    @Bean
    public Counter cacheHitCounter(MeterRegistry registry) {
        return Counter.builder("cache.access.total")
                .tag("result", "hit")
                .description("Device stats cache hit")
                .register(registry);
    }

    @Bean
    public Counter cacheMissCounter(MeterRegistry registry) {
        return Counter.builder("cache.access.total")
                .tag("result", "miss")
                .description("Device stats cache miss")
                .register(registry);
    }

    @Bean
    public Counter cacheNullHitCounter(MeterRegistry registry) {
        return Counter.builder("cache.access.total")
                .tag("result", "null_hit")
                .description("Device stats null placeholder hit (penetration guard)")
                .register(registry);
    }
}
