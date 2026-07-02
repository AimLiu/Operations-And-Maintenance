create database iot_learn;

CREATE TABLE IF NOT EXISTS device_report
(
    id          BIGSERIAL PRIMARY KEY,
    device_id   VARCHAR(64) NOT NULL,
    payload     JSONB       NOT NULL,
    reported_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

CREATE INDEX idx_device_report_device_id ON device_report (device_id);
CREATE INDEX idx_device_report_reported_at ON device_report (reported_at DESC);

COMMENT ON TABLE device_report IS 'IoT 设备遥测上报记录（Phase 1 实验表）';