package com.iot.learn.devicereport.config;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.cloud.context.config.annotation.RefreshScope;
import org.springframework.stereotype.Component;

import java.util.concurrent.ThreadLocalRandom;

/**
 * v2 金丝雀缺陷模拟：在 Service 层抛错，确保 Spring MVC / Micrometer 记录 5xx 指标。
 * 配合 Nacos refreshEnabled=true + @RefreshScope，app.canary-bug-enabled 可热更新。
 */
@Component
@RefreshScope
public class CanaryBugConfig {

    private static final Logger log = LoggerFactory.getLogger(CanaryBugConfig.class);

    private final boolean enabled;

    public CanaryBugConfig(@Value("${app.canary-bug-enabled:false}") boolean enabled) {
        this.enabled = enabled;
        log.info("Canary bug config loaded: app.canary-bug-enabled={}", enabled);
    }

    public void maybeFail() {
        if (enabled && ThreadLocalRandom.current().nextBoolean()) {
            log.warn("Canary bug triggered — simulating 500");
            throw new CanaryBugException("canary-bug-simulated");
        }
    }

    public static class CanaryBugException extends RuntimeException {
        public CanaryBugException(String message) {
            super(message);
        }
    }
}
