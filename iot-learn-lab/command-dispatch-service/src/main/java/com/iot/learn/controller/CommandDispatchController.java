package com.iot.learn.controller;

import com.iot.learn.dto.DispatchAckRequest;
import com.iot.learn.dto.DispatchAckResponse;
import com.iot.learn.service.CommandDispatchService;
import jakarta.validation.Valid;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/v1/commands")
public class CommandDispatchController {

    private final CommandDispatchService service;
    private final Logger log = LoggerFactory.getLogger(CommandDispatchController.class);

    public CommandDispatchController(CommandDispatchService service) {
        this.service = service;
    }

    @PostMapping("/ack")
    public DispatchAckResponse ack(@Valid @RequestBody DispatchAckRequest request) {
        log.info("CommandDispatchController::ack has been called, the device id is [{}]", request.getDeviceId());
        return service.ack(request);
    }
}