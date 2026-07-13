package com.iot.learn.listener;

import com.iot.learn.event.DeviceReportEvent;
import com.iot.learn.service.DeviceReportBatchWriter;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.support.Acknowledgment;
import org.springframework.stereotype.Component;

import java.util.List;

@Component
public class DeviceReportBatchListener {

    private static final Logger log = LoggerFactory.getLogger(DeviceReportBatchListener.class);

    private final DeviceReportBatchWriter batchWriter;

    public DeviceReportBatchListener(DeviceReportBatchWriter batchWriter) {
        this.batchWriter = batchWriter;
    }

    @KafkaListener(topics = "${app.kafka.topic}", containerFactory = "batchFactory", concurrency = "3")
    public void onMessages(List<ConsumerRecord<String, DeviceReportEvent>> records, Acknowledgment ack) {
        log.debug("Received kafka batch, size={}", records.size());
        batchWriter.writeBatch(records);
        ack.acknowledge();
    }
}
