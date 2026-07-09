package com.iot.learn.devicereport.web;

import com.iot.learn.devicereport.config.CanaryBugConfig;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

import java.util.Map;

@RestControllerAdvice
public class CanaryBugExceptionHandler {

    @ExceptionHandler(CanaryBugConfig.CanaryBugException.class)
    public ResponseEntity<Map<String, String>> handleCanaryBug(CanaryBugConfig.CanaryBugException ex) {
        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR)
                .body(Map.of("error", ex.getMessage()));
    }
}
