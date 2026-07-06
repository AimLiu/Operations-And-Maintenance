package com.iot.learn.controller;

import com.iot.learn.dto.DispatchAckResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/v1/debug")
public class DebugController {

    private Logger log = LoggerFactory.getLogger(DebugController.class);

    @PostMapping("/fail")
    public void fail() {
        log.info("DebugController::fail has been called");
        throw new RuntimeException("simulated dispatch failure");
    }

    @PostMapping("/slow")
    public DispatchAckResponse slow(@RequestParam(defaultValue = "5") int seconds)
            throws InterruptedException {
        log.info("DebugController::slow has been called");
        Thread.sleep(seconds * 1000L);
        return new DispatchAckResponse("slow-ack", "debug", "SLOW");
    }
}
