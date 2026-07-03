package com.iot.learn.devicereport.service;

import com.iot.learn.devicereport.dto.DeviceReportRequest;
import com.iot.learn.devicereport.dto.DeviceReportResponse;
import com.iot.learn.devicereport.entity.DeviceReport;
import com.iot.learn.devicereport.repository.DeviceReportRepository;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.Mockito;
import org.mockito.junit.jupiter.MockitoExtension;

import java.time.Instant;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

@ExtendWith(MockitoExtension.class)
public class DeviceReportServiceTest {
    @Mock
    private DeviceReportRepository repository;

    @InjectMocks  // ← 创建真实的 DeviceReportService，并注入上面的 mock repository
    private DeviceReportService service;

    @Test
    void saveReport_persistsDeviceIdAndPayload() {
        DeviceReportRequest request = new DeviceReportRequest();
        request.setPayload(Map.of("temperature", 25.5, "humidity", 60));

        DeviceReport saved = new DeviceReport();
        saved.setId(1L);
        saved.setDeviceId("device-oo1");
        saved.setPayload(request.getPayload());
        saved.setReportedAt(Instant.now());

        Mockito.when(repository.save(Mockito.any(DeviceReport.class)))
                .thenReturn(saved);
        DeviceReportResponse response = service.saveReport("device-001", request);

        ArgumentCaptor<DeviceReport> captor = ArgumentCaptor.forClass(DeviceReport.class);
        Mockito.verify(repository).save(captor.capture());

        assertThat(captor.getValue().getDeviceId()).isEqualTo("device-001");
        assertThat(captor.getValue().getPayload()).containsEntry("temperature", 25.5);
        assertThat(response.getId()).isEqualTo(1L);
        assertThat(response.getDeviceId()).isEqualTo("device-001");
    }
}
