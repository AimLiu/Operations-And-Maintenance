package com.iot.learn.devicereport.handler;

import com.iot.learn.devicereport.client.CommandDispatchClient;
import com.iot.learn.devicereport.dto.DispatchAckRequest;
import com.iot.learn.devicereport.dto.DispatchAckResponse;
import org.springframework.stereotype.Component;

import java.util.UUID;

@Component
public class DispatchFallbackHandler implements CommandDispatchClient {

    @Override
    public DispatchAckResponse ack(DispatchAckRequest request) {
        return new DispatchAckResponse(
                "fallback-" + UUID.randomUUID(),
                request.getDeviceId(),
                "DEGRADED",
                true
        );
    }
}
