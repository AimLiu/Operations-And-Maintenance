package com.iot.learn.devicereport.config;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ModuleLogPathEnvironmentPostProcessorTest {

    @TempDir
    Path tempDir;

    @Test
    void resolveModuleLogDir_fromRepoRoot_usesIotLearnLabModulePath() throws Exception {
        Path repoRoot = tempDir.resolve("Operations-And-Maintenance");
        Path moduleDir = repoRoot.resolve("iot-learn-lab").resolve("device-report-service");
        Files.createDirectories(moduleDir);

        Path logDir = withUserDir(repoRoot, () -> ModuleLogPathEnvironmentPostProcessor.resolveModuleLogDir());

        assertThat(logDir).isEqualTo(moduleDir.resolve("log").toAbsolutePath().normalize());
    }

    @Test
    void resolveModuleLogDir_fromModuleRoot_usesLocalLog() throws Exception {
        Path moduleDir = tempDir.resolve("device-report-service");
        Files.createDirectories(moduleDir);

        Path logDir = withUserDir(moduleDir, () -> ModuleLogPathEnvironmentPostProcessor.resolveModuleLogDir());

        assertThat(logDir).isEqualTo(moduleDir.resolve("log").toAbsolutePath().normalize());
    }

    private Path withUserDir(Path userDir, java.util.concurrent.Callable<Path> action) throws Exception {
        String original = System.getProperty("user.dir");
        try {
            System.setProperty("user.dir", userDir.toAbsolutePath().toString());
            return action.call();
        } finally {
            System.setProperty("user.dir", original);
        }
    }
}
