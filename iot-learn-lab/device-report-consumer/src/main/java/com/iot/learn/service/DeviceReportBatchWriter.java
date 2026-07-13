package com.iot.learn.service;

import com.iot.learn.entity.DeviceReport;
import com.iot.learn.event.DeviceReportEvent;
import jakarta.persistence.EntityManager;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.util.StringUtils;

import java.util.List;
import java.util.Map;

@Service
public class DeviceReportBatchWriter {

    private static final Logger log = LoggerFactory.getLogger(DeviceReportBatchWriter.class);

    private final EntityManager entityManager;

    @Value("${app.kafka.batch-insert-size:50}")
    private int batchInsertSize;

    public DeviceReportBatchWriter(EntityManager entityManager) {
        this.entityManager = entityManager;
    }

    /**
     * 批量落库：persist + 按批次 flush/clear，配合 Hibernate jdbc.batch_size 生成 JDBC batch INSERT。
     * 单批事务；失败时不 ack，由 Kafka 重投（at-least-once）。
     */
    @Transactional
    public void writeBatch(List<ConsumerRecord<String, DeviceReportEvent>> records) {
        if (records == null || records.isEmpty()) {
            return;
        }

        int written = 0;
        int skipped = 0;
        int pendingInBatch = 0;

        for (ConsumerRecord<String, DeviceReportEvent> record : records) {
            DeviceReportEvent event = record.value();
            if (!isValid(event)) {
                skipped++;
                log.warn("Skip invalid event: partition={}, offset={}, key={}",
                        record.partition(), record.offset(), record.key());
                continue;
            }

            entityManager.persist(toEntity(event));
            written++;
            pendingInBatch++;

            if (pendingInBatch >= batchInsertSize) {
                entityManager.flush();
                entityManager.clear();
                pendingInBatch = 0;
            }
        }

        if (pendingInBatch > 0) {
            entityManager.flush();
            entityManager.clear();
        }

        log.info("Batch insert completed: pollSize={}, written={}, skipped={}",
                records.size(), written, skipped);
    }

    private boolean isValid(DeviceReportEvent event) {
        return event != null
                && StringUtils.hasText(event.deviceId())
                && event.payload() != null
                && !event.payload().isEmpty()
                && event.reportedAt() != null;
    }

    private DeviceReport toEntity(DeviceReportEvent event) {
        DeviceReport report = new DeviceReport();
        report.setDeviceId(event.deviceId());
        report.setPayload(Map.copyOf(event.payload()));
        report.setReportedAt(event.reportedAt());
        return report;
    }
}
