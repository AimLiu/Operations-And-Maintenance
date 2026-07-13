package com.iot.learn.devicereport.repository;

import java.time.Instant;

public interface DeviceStatsAggregation {

    long getReportCount();

    Instant getLastReportedAt();
}
