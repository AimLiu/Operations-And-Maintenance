package com.iot.learn.devicereport.client;

import com.iot.learn.devicereport.dto.DispatchAckRequest;
import com.iot.learn.devicereport.dto.DispatchAckResponse;
import com.iot.learn.devicereport.handler.DispatchFallbackHandler;
import org.springframework.cloud.openfeign.FeignClient;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;

@FeignClient(name = "command-dispatch-service",
        url = "${dispatch.base-url:http://localhost:8767}"
        , fallback = DispatchFallbackHandler.class)
public interface CommandDispatchClient {

    @PostMapping("/api/v1/commands/ack")
    DispatchAckResponse ack(@RequestBody DispatchAckRequest request);
}
