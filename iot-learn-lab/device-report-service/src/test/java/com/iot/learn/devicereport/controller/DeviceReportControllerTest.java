package com.iot.learn.devicereport.controller;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.iot.learn.devicereport.dto.DeviceReportRequest;
import com.iot.learn.devicereport.dto.DeviceReportResponse;
import com.iot.learn.devicereport.service.DeviceReportService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

import java.time.Instant;
import java.util.Map;

import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(DeviceReportController.class)
class DeviceReportControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private ObjectMapper objectMapper;

    @MockBean
    private DeviceReportService service;

    @Test
    void postReport_returns201() throws Exception {
        DeviceReportRequest request = new DeviceReportRequest();
        request.setPayload(Map.of("temperature", 25.5));

        when(service.saveReport(eq("device-001"), org.mockito.ArgumentMatchers.any()))
                .thenReturn(new DeviceReportResponse(1L, "device-001", Instant.parse("2026-07-02T08:00:00Z")));

        mockMvc.perform(post("/api/v1/devices/device-001/reports")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(objectMapper.writeValueAsString(request)))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.id").value(1))
                .andExpect(jsonPath("$.deviceId").value("device-001"));
    }
}