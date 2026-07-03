package com.iot.learn.devicereport.config;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.env.EnvironmentPostProcessor;
import org.springframework.core.Ordered;
import org.springframework.core.env.ConfigurableEnvironment;
import org.springframework.core.env.MapPropertySource;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Map;

/**
 * 在 Logback 初始化前解析日志目录，固定输出到模块目录下的 {@code log/}。
 * <p>
 * 解析优先级：
 * <ol>
 *   <li>环境变量 {@code LOGGING_FILE_PATH}（显式覆盖）</li>
 *   <li>{@code iot-learn-lab/device-report-service/log}（从仓库根目录启动）</li>
 *   <li>{@code device-report-service/log}（从 iot-learn-lab 目录启动）</li>
 *   <li>{@code ./log}（已在模块目录内启动）</li>
 * </ol>
 */
public class ModuleLogPathEnvironmentPostProcessor implements EnvironmentPostProcessor, Ordered {

    private static final String MODULE_NAME = "device-report-service";
    private static final String IOT_LEARN_LAB = "iot-learn-lab";
    private static final String LOGGING_FILE_PATH = "logging.file.path";
    private static final String LOGGING_FILE_PATH_ENV = "LOGGING_FILE_PATH";

    @Override
    public void postProcessEnvironment(ConfigurableEnvironment environment, SpringApplication application) {
        if (hasExplicitLogPathFromEnv()) {
            return;
        }
        Path logDir = resolveModuleLogDir();
        String logPath = logDir.toString();
        environment.getPropertySources().addFirst(
                new MapPropertySource("moduleLogPath", Map.of(LOGGING_FILE_PATH, logPath)));
        System.setProperty(LOGGING_FILE_PATH, logPath);
    }

    @Override
    public int getOrder() {
        return Ordered.LOWEST_PRECEDENCE;
    }

    private boolean hasExplicitLogPathFromEnv() {
        String fromEnv = System.getenv(LOGGING_FILE_PATH_ENV);
        return fromEnv != null && !fromEnv.isBlank();
    }

    static Path resolveModuleLogDir() {
        Path cwd = Paths.get(System.getProperty("user.dir")).toAbsolutePath().normalize();

        if (MODULE_NAME.equals(cwd.getFileName().toString())) {
            return cwd.resolve("log");
        }

        Path moduleInIotLearnLab = cwd.resolve(IOT_LEARN_LAB).resolve(MODULE_NAME);
        if (Files.isDirectory(moduleInIotLearnLab)) {
            return moduleInIotLearnLab.resolve("log");
        }

        Path moduleUnderCwd = cwd.resolve(MODULE_NAME);
        if (Files.isDirectory(moduleUnderCwd)) {
            return moduleUnderCwd.resolve("log");
        }

        return cwd.resolve("log");
    }
}
