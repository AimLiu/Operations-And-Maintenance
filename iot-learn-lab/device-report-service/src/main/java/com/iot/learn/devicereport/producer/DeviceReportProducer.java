package com.iot.learn.devicereport.producer;

import com.iot.learn.devicereport.dto.DeviceReportEvent;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.SendResult;
import org.springframework.stereotype.Service;

import java.util.concurrent.CompletableFuture;

@Service
public class DeviceReportProducer {

    @Value("${app.kafka.topic:device-report-events}")
    private String DEVICE_REPORT_TOPIC;
    private final KafkaTemplate<String, DeviceReportEvent> kafkaTemplate;

    public DeviceReportProducer(KafkaTemplate<String, DeviceReportEvent> kafkaTemplate) {
        this.kafkaTemplate = kafkaTemplate;
    }

    public CompletableFuture<SendResult<String, DeviceReportEvent>> send(DeviceReportEvent event) {
        return kafkaTemplate.send(DEVICE_REPORT_TOPIC, event.deviceId(), event);
    }
}
