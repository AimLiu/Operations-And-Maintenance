package com.iot.learn.service;

import com.iot.learn.dto.DispatchAckRequest;
import com.iot.learn.dto.DispatchAckResponse;
import jakarta.validation.Valid;
import org.springframework.stereotype.Service;

import java.util.UUID;

@Service
public class CommandDispatchService {
    public DispatchAckResponse ack(@Valid DispatchAckRequest request) {
        DispatchAckResponse response = new DispatchAckResponse(UUID.randomUUID().toString(),
                request.getDeviceId(), request.getReportId());
        return response;
    }
}
