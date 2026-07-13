package com.iot.learn.repository;

import com.iot.learn.entity.DeviceReport;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

@Repository
public interface DeviceReportRepository extends JpaRepository<DeviceReport, Long> {

    @Query(value = "SELECT pg_sleep(CAST(:seconds AS double precision)) IS NOT NULL", nativeQuery = true)
    void sleepSeconds(@Param("seconds") double seconds);
}